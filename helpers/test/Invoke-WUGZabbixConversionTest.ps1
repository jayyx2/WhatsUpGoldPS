<#
.SYNOPSIS
    Runs offline Zabbix converter tests without external dependencies.
.DESCRIPTION
    Uses synthetic fixtures and a private temporary directory. Optionally reads
    actual Cisco community exports without changing them. Makes no network calls.
.PARAMETER CommunityTemplateRoot
    Optional extracted community-templates root containing Network_Devices.
.EXAMPLE
    .\Invoke-WUGZabbixConversionTest.ps1
.NOTES
    Requires PowerShell 5.1. Exits nonzero on a failed assertion.
.LINK
    https://github.com/zabbix/community-templates
#>
[CmdletBinding()]
param([string]$CommunityTemplateRoot)

$ErrorActionPreference = 'Stop'
$converter = Join-Path $PSScriptRoot '..\converters\Convert-ZabbixTemplateToWUG.ps1'
. (Join-Path $PSScriptRoot '..\converters\ZabbixTemplateConversion.ps1')
$script:Passed = 0
$script:Failed = 0
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("WUGZabbixTest-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temp)
$encoding = [System.Text.UTF8Encoding]::new($true)

function Assert-Conversion {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ConversionThrows {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    if ($null -eq $caught) { throw "Expected an error matching '$Pattern'." }
    if ($caught.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($caught.Exception.Message)" }
}

function Assert-ConversionTree {
    param([AllowNull()]$Expected, [AllowNull()]$Actual)
    if ($null -eq $Expected) { Assert-Conversion ($null -eq $Actual) 'Expected a null node.'; return }
    if ($Expected -is [System.Collections.IDictionary]) {
        Assert-Conversion ($Actual -is [System.Collections.IDictionary] -and $Actual.Count -eq $Expected.Count) 'Mapping shape changed.'
        foreach ($key in $Expected.Keys) {
            Assert-Conversion ($Actual.ContainsKey($key)) "Missing key '$key'."
            Assert-ConversionTree $Expected[$key] $Actual[$key]
        }
        return
    }
    if ($Expected -is [array]) {
        Assert-Conversion ($Actual -is [array] -and $Actual.Count -eq $Expected.Count) 'Sequence shape changed.'
        for ($i = 0; $i -lt $Expected.Count; $i++) { Assert-ConversionTree $Expected[$i] $Actual[$i] }
        return
    }
    Assert-Conversion ($Actual -is [string] -and $Actual -ceq $Expected) 'Scalar text changed.'
}

function Test-Conversion {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:Passed++
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failed++
        Write-Warning "FAIL: $Name - $($_.Exception.Message)"
    }
}

function Invoke-ConversionMockWug {
    param([scriptblock]$Action)
    $oldHeaders = Get-Variable WUGBearerHeaders -Scope Global -ErrorAction SilentlyContinue
    $oldUri = Get-Variable WhatsUpServerBaseURI -Scope Global -ErrorAction SilentlyContinue
    $savedHeaders = $null
    $savedUri = $null
    if ($oldHeaders) { $savedHeaders = $oldHeaders.Value }
    if ($oldUri) { $savedUri = $oldUri.Value }
    $global:WUGBearerHeaders = @{ Authorization = 'test-only' }
    $global:WhatsUpServerBaseURI = 'https://wug.invalid'
    $script:MockLibrary = [System.Collections.Generic.List[object]]::new()
    $script:MockPatches = [System.Collections.Generic.List[object]]::new()
    $script:MockReads = [System.Collections.Generic.List[string]]::new()
    $script:MockFailure = ''
    $script:MockPaginate = $false
    function Get-WUGAPIResponse {
        [CmdletBinding()]
        param([string]$Uri, [string]$Method, [string]$Body, [int]$MaxRetries = 3)
        if ($Method -eq 'GET') {
            $script:MockReads.Add($Uri)
            $entries = @($script:MockLibrary.ToArray())
            $next = ''
            if ($script:MockPaginate -and $entries.Count -gt 1) {
                if ($Uri -notmatch 'pageId=') { $entries = @($entries[0]); $next = 'next&1' }
                else { $entries = @($entries | Select-Object -Skip 1) }
            }
            $data = [ordered]@{ errors = @(); activeMonitors = @(); performanceMonitors = @(); passiveMonitors = @() }
            if ($script:MockFailure -eq 'Read') { $data.errors = @('read denied') }
            foreach ($entry in $entries) {
                $copy = ConvertTo-ZabbixData $entry
                if ($script:MockFailure -eq 'Reconcile' -and $script:MockReads.Count -gt 1) { $copy.propertyBags[0]['value'] = 'changed-by-server' }
                $data["$($copy.monitorTypeInfo.baseType)Monitors"] += $copy
            }
            return [PSCustomObject]@{ data = [PSCustomObject]$data; paging = [PSCustomObject]@{ nextPageId = $next } }
        }
        if ($Method -ne 'PATCH' -or $MaxRetries -ne 0) { throw 'The importer attempted an unexpected method or enabled blind mutation retries.' }
        $request = ConvertFrom-Json -InputObject $Body
        $script:MockPatches.Add($request)
        $map = [System.Collections.Generic.List[object]]::new()
        foreach ($group in @('activeMonitors', 'performanceMonitors', 'passiveMonitors')) {
            foreach ($monitor in @($request.$group)) {
                $id = "library-$($script:MockLibrary.Count + 1)"
                $monitor | Add-Member -NotePropertyName id -NotePropertyValue $id
                $script:MockLibrary.Add($monitor)
                $map.Add([PSCustomObject]@{ templateId = $monitor.templateId; resultId = $id })
            }
        }
        $data = [PSCustomObject]@{ successful = $map.Count; idMap = $map.ToArray(); errors = @() }
        if ($script:MockFailure -eq 'Partial') { $data.errors = @([PSCustomObject]@{ templateId = 'one'; messages = @('failure') }) }
        if ($script:MockFailure -eq 'MissingMap') { $data.idMap = @() }
        return [PSCustomObject]@{ data = $data }
    }
    try { & $Action }
    finally {
        if ($oldHeaders) { $global:WUGBearerHeaders = $savedHeaders } else { Remove-Variable WUGBearerHeaders -Scope Global }
        if ($oldUri) { $global:WhatsUpServerBaseURI = $savedUri } else { Remove-Variable WhatsUpServerBaseURI -Scope Global }
    }
}

$yaml = @'
zabbix_export:
  version: '6.0'
  templates:
    - template: 'Synthetic Cisco SNMP'
      name: 'Synthetic Cisco SNMP'
      items:
        - name: 'CPU'
          type: SNMP_AGENT
          snmp_oid: 'get[1.3.6.1.4.1.9.2.1.57.0]'
          key: cpu
          value_type: UNSIGNED
          delay: 5m
          units: '%'
'@
$xml = @'
<?xml version="1.0" encoding="utf-8"?>
<zabbix_export><version>6.0</version><templates><template><template>Synthetic Cisco SNMP</template><name>Synthetic Cisco SNMP</name><items><item><name>CPU</name><type>SNMP_AGENT</type><snmp_oid>get[1.3.6.1.4.1.9.2.1.57.0]</snmp_oid><key>cpu</key><value_type>UNSIGNED</value_type><delay>5m</delay><units>%</units></item></items></template></templates></zabbix_export>
'@

try {
    $yamlPath = Join-Path $temp 'synthetic.yaml'
    $xmlPath = Join-Path $temp 'synthetic.xml'
    $jsonPath = Join-Path $temp 'synthetic.json'
    [System.IO.File]::WriteAllText($yamlPath, $yaml, $encoding)
    [System.IO.File]::WriteAllText($xmlPath, $xml, $encoding)
    $parsed = Read-ZabbixYaml $yaml
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $parsed -Depth 30), $encoding)

    Test-Conversion 'Equivalent YAML/XML/JSON monitor payloads and singleton arrays' {
        $previous = $null
        foreach ($path in @($yamlPath, $xmlPath, $jsonPath)) {
            $export = Read-ZabbixExport $path
            Assert-Conversion ($export.Data['templates'] -is [array]) 'Templates lost their array shape.'
            $profile = (ConvertFrom-ZabbixExport $export)[0]
            Assert-Conversion ($profile.Counts.Ready -eq 1) 'Expected exactly one ready definition.'
            $candidate = $profile.Definitions[0].Candidate
            Assert-Conversion ($candidate.PollingIntervalMinutes -eq 5) 'Polling interval changed.'
            Assert-Conversion ($candidate.MonitorParams.SnmpOID -eq '1.3.6.1.4.1.9.2.1.57.0') 'OID changed.'
            Assert-Conversion ($candidate.MonitorParams.SnmpInstance -ceq '') 'Instance was guessed.'
            Assert-Conversion ($candidate.Template.monitorTypeInfo.classId -ceq '2f300544-cba3-4341-9b05-2d1786f68e07') 'Wrong performance monitor class.'
            Assert-Conversion ($candidate.Template.monitorTypeInfo.baseType -ceq 'performance') 'Wrong base type.'
            $bags = $candidate.Template.propertyBags
            Assert-Conversion ($bags.Count -eq 5) 'Unexpected SNMP property bag count.'
            Assert-Conversion ($bags[0].name -ceq 'SNMP:OID' -and $bags[0].value -ceq '1.3.6.1.4.1.9.2.1.57.0') 'Incorrect OID bag.'
            Assert-Conversion ($bags[1].name -ceq 'SNMP:Instance' -and $bags[1].value -ceq '') 'Incorrect instance bag.'
            Assert-Conversion ($bags[2].name -ceq 'SNMP:UseRawValues' -and $bags[2].value -ceq '1') 'Incorrect raw-value bag.'
            $current = ConvertTo-Json -InputObject $candidate -Depth 30 -Compress
            if ($null -ne $previous) { Assert-Conversion ($current -ceq $previous) 'Formats produced different candidates.' }
            $previous = $current
        }
    }
    Test-Conversion 'Deterministic conversion' {
        $export = Read-ZabbixExport $yamlPath
        $a = ConvertTo-Json -InputObject (ConvertFrom-ZabbixExport $export) -Depth 100 -Compress
        $b = ConvertTo-Json -InputObject (ConvertFrom-ZabbixExport $export) -Depth 100 -Compress
        Assert-Conversion ($a -ceq $b) 'Repeated conversion changed output.'
    }
    Test-Conversion 'YAML case-sensitive keys, quotes, escapes and scalar lexemes' {
        $doc = Read-ZabbixYaml @'
Key: 00123
key: '7.0'
quote: 'it''s quoted # text'
escape: "\n\N\u0041"
oid: 1.3.6.1
yes: YES
'@
        Assert-Conversion ($doc.Count -eq 6 -and $doc['Key'] -ceq '00123' -and $doc['key'] -ceq '7.0') 'Scalar or key case changed.'
        Assert-Conversion ($doc['quote'] -ceq "it's quoted # text") 'Single quotes changed.'
        Assert-Conversion ($doc['escape'] -ceq ("`n" + [char]0x85 + 'A')) 'Escapes changed.'
        Assert-Conversion ($doc['yes'] -ceq 'YES') 'Implicit typing changed a Zabbix enum.'
    }
    Test-Conversion 'YAML flow and empty collections' {
        $doc = Read-ZabbixYaml "items: [one, 'two, three', {name: four}]`nempty: []`nmap: {}`n"
        Assert-Conversion ($doc['items'].Count -eq 3 -and $doc['items'][1] -eq 'two, three') 'Flow sequence changed.'
        Assert-Conversion ($doc['empty'] -is [array] -and $doc['empty'].Count -eq 0) 'Empty sequence lost.'
        Assert-Conversion ($doc['map'].Count -eq 0) 'Empty map lost.'
    }
    Test-Conversion 'YAML final newline, folded paragraphs and content tabs' {
        $doc = Read-ZabbixYaml "value: |+`n  final`n"
        Assert-Conversion ($doc['value'] -ceq "final`n") 'An extra final newline was added.'
        $doc = Read-ZabbixYaml "value: |+`n  final"
        Assert-Conversion ($doc['value'] -ceq 'final') 'A missing final newline was invented.'
        $doc = Read-ZabbixYaml "value: >-`n  first`n`n  second`n"
        Assert-Conversion ($doc['value'] -ceq "first`nsecond") 'Folded paragraph break changed.'
        $doc = Read-ZabbixYaml "value: |-`n  `tcontent"
        Assert-Conversion ($doc['value'] -ceq "`tcontent") 'A content tab was rejected or removed.'
        $doc = Read-ZabbixYaml @'
value: "join\
  ed"
'@
        Assert-Conversion ($doc['value'] -ceq 'joined') 'Escaped line continuation changed.'
    }
    Test-Conversion 'YAML indentationless sequences and multiline scalars' {
        $doc = Read-ZabbixYaml @'
items:
- name: first
  description: |-
    line one
    line two
- name: 'second
    continued'
folded: >-
  first
  second
'@
        Assert-Conversion ($doc['items'].Count -eq 2) 'Indentationless sequence changed.'
        Assert-Conversion ($doc['items'][0]['description'] -ceq "line one`nline two") 'Literal text changed.'
        Assert-Conversion ($doc['items'][1]['name'] -ceq 'second continued') 'Quoted multiline text changed.'
        Assert-Conversion ($doc['folded'] -ceq 'first second') 'Folded text changed.'
    }
    Test-Conversion 'Malformed and unimplemented YAML fails explicitly' {
        foreach ($inputText in @("a: 1`na: 2", 'a: *missing', 'a: !custom value',
            "? [a, b]`n: value", "a: 1`n---`nb: 2", "a:`n`tbad: value", 'a: [unclosed')) {
            Assert-ConversionThrows { Read-ZabbixYaml $inputText -Source 'fixture.yaml' } 'fixture.yaml:'
        }
    }
    Test-Conversion 'YAML multiline flow, comments, JSON keys and trailing commas' {
        $doc = Read-ZabbixYaml @'
items: [
  one, # separator comment
  "two,# literal",
  {"key":"value", empty:, lone, "": blank, },
  [
    three,
    four,
  ],
  ] # completed collection
next: intact
'@
        Assert-Conversion ($doc['items'].Count -eq 4 -and $doc['items'][1] -ceq 'two,# literal') 'Flow values/comments changed.'
        $map = $doc['items'][2]
        Assert-Conversion ($map['key'] -ceq 'value' -and $map[''] -ceq 'blank') 'JSON-style or empty quoted keys changed.'
        Assert-Conversion ($map.ContainsKey('empty') -and $null -eq $map['empty'] -and $map.ContainsKey('lone') -and $null -eq $map['lone']) 'Empty flow values changed.'
        Assert-Conversion ($doc['items'][3].Count -eq 2 -and $doc['next'] -ceq 'intact') 'Nested flow consumed the following block entry.'
    }
    Test-Conversion 'YAML plain flow punctuation and multiline folding' {
        $doc = Read-ZabbixYaml @'
values: [
  can't,
  a 'quote,
  https://example.invalid/a#fragment,
  first
    second,
  third

    fourth,
  ]
'@
        Assert-Conversion ($doc['values'].Count -eq 5 -and $doc['values'][0] -ceq "can't" -and $doc['values'][1] -ceq "a 'quote") 'Plain apostrophes were treated as quoting.'
        Assert-Conversion ($doc['values'][2] -ceq 'https://example.invalid/a#fragment') 'URL colon/hash was treated as syntax.'
        Assert-Conversion ($doc['values'][3] -ceq 'first second' -and $doc['values'][4] -ceq "third`nfourth") 'Plain flow folding changed.'
        $map = Read-ZabbixYaml '{a:1, "b":2}'
        Assert-Conversion ($map.ContainsKey('a:1') -and $null -eq $map['a:1'] -and $map['b'] -ceq '2') 'Plain and quoted colon separation rules were confused.'
    }
    Test-Conversion 'YAML multiline quoted flow and escaped physical breaks' {
        $doc = Read-ZabbixYaml @'
values: [
  "first
    second",
  'third

    fourth',
  "join\
    ed",
  "keep\

    break",
  ]
'@
        Assert-Conversion ($doc['values'][0] -ceq 'first second' -and $doc['values'][1] -ceq "third`nfourth") 'Quoted flow folding changed.'
        Assert-Conversion ($doc['values'][2] -ceq 'joined' -and $doc['values'][3] -ceq "keep`nbreak") 'Escaped physical breaks changed.'
    }
    Test-Conversion 'YAML directives, standard tags and anchor property order' {
        $doc = Read-ZabbixYaml @'
%YAML 1.2
%TAG !std! tag:yaml.org,2002:
--- # document comment
root: !std!map {
  text: !!str null,
  other: !<tag:yaml.org,2002:str> ~,
  first: &fan.status !!seq [one, two],
  second: !!seq &copy [three],
  alias: *fan.status,
  nullValue: !!null null,
  }
...
'@
        $root = $doc['root']
        Assert-Conversion ($root['text'] -ceq 'null' -and $root['other'] -ceq '~' -and $null -eq $root['nullValue']) 'Explicit scalar tags changed null spelling.'
        Assert-Conversion ($root['alias'].Count -eq 2 -and $root['second'][0] -ceq 'three') 'Tags/anchors did not compose.'
        $root['first'][0] = 'changed'
        Assert-Conversion ($root['alias'][0] -ceq 'one') 'An alias was not independently copied.'
    }
    Test-Conversion 'YAML tagged block nodes, non-specific tags and empty strings' {
        $doc = Read-ZabbixYaml @'
text: !!str
  null
literal: !!str |-
  null
empty: !!str
other: ! null
seq: !!seq
  - first
map: !!map
  name: value
flow: [!!str , ! null, !!str ~]
'@
        Assert-Conversion ($doc['text'] -ceq 'null' -and $doc['literal'] -ceq 'null' -and $doc['empty'] -ceq '' -and $doc['other'] -ceq 'null') 'Tagged block scalars changed.'
        Assert-Conversion ($doc['seq'][0] -ceq 'first' -and $doc['map']['name'] -ceq 'value') 'Tagged block collections changed.'
        Assert-Conversion ($doc['flow'][0] -ceq '' -and $doc['flow'][1] -ceq 'null' -and $doc['flow'][2] -ceq '~') 'Tagged flow null/empty spelling changed.'
    }
    Test-Conversion 'YAML separate-line explicit string keys and quoted merge keys' {
        $doc = Read-ZabbixYaml @'
? 'OID: key'
: value
? !!str null
: string key
"": empty key
can't: apostrophe
defaults: &defaults {name: inherited}
? <<
: *defaults
"<<": literal
'@
        Assert-Conversion ($doc['OID: key'] -ceq 'value' -and $doc['null'] -ceq 'string key' -and $doc[''] -ceq 'empty key') 'Explicit string keys changed.'
        Assert-Conversion ($doc["can't"] -ceq 'apostrophe' -and $doc['name'] -ceq 'inherited' -and $doc['<<'] -ceq 'literal') 'Plain punctuation or merge-key quoting changed.'
    }
    Test-Conversion 'YAML flow pairs and explicit scalar keys' {
        $doc = Read-ZabbixYaml '[name: value, ? other, {? "quoted": yes}]'
        Assert-Conversion ($doc.Count -eq 3 -and $doc[0]['name'] -ceq 'value' -and $doc[1].ContainsKey('other') -and $null -eq $doc[1]['other'] -and $doc[2]['quoted'] -ceq 'yes') 'Flow pairs were not preserved.'
    }
    Test-Conversion 'YAML compact nested sequences and anchored collection entries' {
        $doc = Read-ZabbixYaml @'
items:
  - &entry
    name: first
    other: second
  - *entry
  - {name: flow}
  - - one
    - two
  - !!seq &nested
    - three
    - four
'@
        Assert-Conversion ($doc['items'].Count -eq 5 -and $doc['items'][1]['other'] -ceq 'second' -and $doc['items'][2]['name'] -ceq 'flow') 'Compact mapping/flow entries changed.'
        Assert-Conversion ($doc['items'][3].Count -eq 2 -and $doc['items'][3][1] -ceq 'two') 'Compact nested sequence changed.'
        Assert-Conversion ($doc['items'][4].Count -eq 2 -and $doc['items'][4][0] -ceq 'three') 'Tagged compact sequence changed.'
        $doc['items'][0]['name'] = 'changed'
        Assert-Conversion ($doc['items'][1]['name'] -ceq 'first') 'Compact mapping anchor targeted the key instead of the collection.'
        $keyAnchor = Read-ZabbixYaml "items:`n  - &key name: first`ncopy: *key"
        Assert-Conversion ($keyAnchor['copy'] -ceq 'name') 'A compact mapping key anchor incorrectly targeted the whole mapping.'
        Assert-ConversionThrows { Read-ZabbixYaml "first: &a value`nsecond: !!str`n  *a" } 'Aliases cannot have tags or anchors'
        Assert-ConversionThrows { Read-ZabbixYaml 'items: [!!str *missing]' } 'Aliases cannot have tags or anchors'
        Assert-ConversionThrows { Read-ZabbixYaml "- &entry - one`n  - two" } 'Compact sequences cannot have node properties'
    }
    Test-Conversion 'YAML scalar/collection roots and empty streams' {
        Assert-Conversion ((Read-ZabbixYaml '[]') -is [array]) 'Root flow sequence changed shape.'
        Assert-Conversion ((Read-ZabbixYaml '{"key":"value"}')['key'] -ceq 'value') 'Root flow map failed.'
        Assert-Conversion ((Read-ZabbixYaml "'root'") -ceq 'root') 'Root quoted scalar failed.'
        Assert-Conversion ((Read-ZabbixYaml "first`nsecond") -ceq 'first second') 'Root plain folding failed.'
        Assert-Conversion ($null -eq (Read-ZabbixYaml 'null') -and $null -eq (Read-ZabbixYaml '')) 'Null/empty document changed.'
        $empty = Read-ZabbixYaml '' -AllDocuments
        Assert-Conversion ($empty -is [array] -and $empty.Count -eq 0) 'Empty stream must have zero documents.'
    }
    Test-Conversion 'YAML opt-in streams preserve document boundaries and reset scope' {
        $stream = @'
%YAML 1.2
--- &first [one]
...
%TAG !std! tag:yaml.org,2002:
--- !std!map {name: second}
---
--- null
'@
        $docs = Read-ZabbixYaml $stream -AllDocuments
        Assert-Conversion ($docs.Count -eq 4 -and $docs[0][0] -ceq 'one' -and $docs[1]['name'] -ceq 'second' -and $null -eq $docs[2] -and $null -eq $docs[3]) 'Stream document shapes changed.'
        Assert-ConversionThrows { Read-ZabbixYaml $stream } 'Additional YAML document'
        Assert-ConversionThrows { Read-ZabbixYaml "--- &first [one]`n--- *first" -AllDocuments } 'Unknown YAML alias'
        Assert-ConversionThrows { Read-ZabbixYaml "%TAG !std! tag:yaml.org,2002:`n--- !std!str first`n--- !std!str second" -AllDocuments } 'Undefined YAML tag handle'
    }
    Test-Conversion 'YAML malformed flows, directives, properties and tags fail explicitly' {
        foreach ($inputText in @(
            'a: [one,,two]', 'a: [one}', 'a: {"one":"1" "two":"2"}', 'a: ["one" "two"]',
            'a: []#no-separation', 'a: ["one"#no-separation]', "a: [one`n---",
            "%YAML 1.2`n%YAML 1.2`n---`na: one",
            "%YAML 1.2`na: one", "%TAG !std! tag:yaml.org,2002:`n%TAG !std! tag:yaml.org,2002:`n---`na: one",
            'a: !!map [one]', 'a: !!seq {name: one}', 'a: !!str [one]', 'a: !!null nonnull',
            'a: !std!str one', 'a: !<tag:yaml.org,2002:%ZZ> one', 'a: !!str !!str one',
            'a: &first &second one', 'a: &first *first', 'a: [!!str *missing]',
            'a: !!python/object:NeverConstruct value', 'a: {null: value}', 'a: {[one]: value}',
            "a: one`n... trailing", 'a: |invalid'
        )) {
            Assert-ConversionThrows { Read-ZabbixYaml $inputText -Source 'syntax.yaml' } 'syntax.yaml:'
        }
    }
    Test-Conversion 'YAML invalid printable characters and exact diagnostic lines' {
        foreach ($character in @([char]1, [char]0xd800, [char]0xdc00, [char]0xffff)) {
            Assert-ConversionThrows { Read-ZabbixYaml ("a: okay`nb: " + $character) -Source 'unicode.yaml' } 'unicode.yaml:2:'
        }
        $scalar = [char]::ConvertFromUtf32(0x1f642)
        Assert-Conversion ((Read-ZabbixYaml "a: $scalar")['a'] -ceq $scalar) 'Valid supplementary Unicode was rejected.'
        Assert-ConversionThrows { Read-ZabbixYaml "items: [`n  okay,`n  `"one`" `"two`"`n]" -Source 'flow.yaml' } 'flow.yaml:3:'
    }
    Test-Conversion 'YAML expanded syntax preserves the actual Zabbix monitor payload' {
        $expanded = @'
%YAML 1.2
%TAG !std! tag:yaml.org,2002:
---
zabbix_export: !std!map {
  version: !!str 6.0,
  templates: !!seq [
    {
      "template":"Synthetic Cisco SNMP",
      name: Synthetic Cisco SNMP,
      items: [
        {
          name: CPU,
          type: SNMP_AGENT,
          snmp_oid: 'get[1.3.6.1.4.1.9.2.1.57.0]',
          key: cpu,
          value_type: UNSIGNED,
          delay: 5m,
          units: '%',
        },
      ],
    },
  ],
  }
...
'@
        $path = Join-Path $temp 'expanded-syntax.yaml'
        [System.IO.File]::WriteAllText($path, $expanded, $encoding)
        $profile = (ConvertFrom-ZabbixExport (Read-ZabbixExport $path))[0]
        $baseline = (ConvertFrom-ZabbixExport (Read-ZabbixExport $yamlPath))[0]
        Assert-Conversion ($profile.Counts.Ready -eq 1) 'Expanded YAML no longer produces a ready monitor.'
        $actual = Get-ZabbixMonitorPayload $profile | ConvertTo-Json -Depth 30 -Compress
        $expected = Get-ZabbixMonitorPayload $baseline | ConvertTo-Json -Depth 30 -Compress
        Assert-Conversion ($actual -ceq $expected) 'YAML syntax changed the native WUG payload.'
        [System.IO.File]::WriteAllText($path, ($expanded + "`n---`nother: document"), $encoding)
        Assert-ConversionThrows { Read-ZabbixExport $path } 'Additional YAML document'
    }
    Test-Conversion 'YAML JSON-subset tree parity across deterministic generated documents' {
        $random = [System.Random]::new(271828)
        $texts = @('', 'null', 'true', '00042', 'apostrophe''s', 'quote"value', ':#[],{}',
            "line`nbreak", "tab`tvalue", "zero$([char]0)", [char]::ConvertFromUtf32(0x1f642))
        $generate = {
            param([int]$Depth)
            $choice = $random.Next(4)
            if ($Depth -ge 4) { $choice = $random.Next(2) }
            switch ($choice) {
                0 { return $null }
                1 { return $texts[$random.Next($texts.Count)] }
                2 {
                    $array = [System.Collections.Generic.List[object]]::new()
                    $count = $random.Next(4)
                    for ($i = 0; $i -lt $count; $i++) { $array.Add((& $generate ($Depth + 1))) }
                    return ,$array.ToArray()
                }
                3 {
                    $map = New-ZabbixMap
                    $count = $random.Next(4)
                    for ($i = 0; $i -lt $count; $i++) { $map.Add("key:$i", (& $generate ($Depth + 1))) }
                    return ,$map
                }
            }
        }
        for ($case = 0; $case -lt 60; $case++) {
            $expected = & $generate 0
            foreach ($compact in @($true, $false)) {
                $json = ConvertTo-Json -InputObject $expected -Depth 30 -Compress:$compact
                Assert-ConversionTree $expected (Read-ZabbixYaml $json)
            }
        }
    }
    Test-Conversion 'YAML failsafe and JSON scalar resolution' {
        $safe = (Read-WUGYamlStream '[true, null, 012, quoted]' -Schema Failsafe).Documents[0].Root
        Assert-Conversion (@($safe.Items | Where-Object { $_.ResolvedTag -cne 'tag:yaml.org,2002:str' }).Count -eq 0) 'Failsafe scalars must remain strings.'
        $json = (Read-WUGYamlStream '[true, false, null, 0, -1, 1e2, "text"]' -Schema JSON).Documents[0].Root
        Assert-Conversion ($json.Items[0].ResolvedTag -ceq 'tag:yaml.org,2002:bool' -and $json.Items[2].ResolvedTag -ceq 'tag:yaml.org,2002:null') 'JSON null/boolean resolution changed.'
        Assert-Conversion ($json.Items[3].Canonical -ceq '0' -and $json.Items[5].Canonical -ceq '1e2' -and $json.Items[6].ResolvedTag -ceq 'tag:yaml.org,2002:str') 'JSON numeric/string resolution changed.'
        foreach ($invalid in @('TRUE', '01', '.inf', 'unquoted')) {
            Assert-ConversionThrows { Read-WUGYamlStream $invalid -Schema JSON } 'JSON schema cannot resolve'
        }
    }
    Test-Conversion 'YAML core scalars retain exact large-number canonical forms' {
        $root = (Read-WUGYamlStream '[0o52, 0x2a, +042, -0, 1.20, -0.0, +.Inf, .NaN, 1e999999999999999999999999999999999999]' -Schema Core).Documents[0].Root
        Assert-Conversion ($root.Items[0].Canonical -ceq '42' -and $root.Items[1].Canonical -ceq '42' -and $root.Items[2].Canonical -ceq '42') 'Integer radices/signs were not normalized.'
        Assert-Conversion ($root.Items[3].Canonical -ceq '0' -and $root.Items[4].Canonical -ceq '12e-1' -and $root.Items[5].Canonical -ceq '0e0') 'Finite numeric canonicalization changed.'
        Assert-Conversion ($root.Items[6].Canonical -ceq '.inf' -and $root.Items[7].Canonical -ceq '.nan' -and $root.Items[8].Canonical -ceq '1e999999999999999999999999999999999999') 'Special/large-exponent floats lost information.'
        $large = (Read-WUGYamlStream '99999999999999999999999999999999999999999999').Documents[0].Root
        Assert-Conversion ($large.ResolvedTag -ceq 'tag:yaml.org,2002:int' -and $large.Canonical -ceq $large.Value) 'Large integers lost precision.'
        $distinct = (Read-WUGYamlStream '{9007199254740992.0: first, 9007199254740993.0: second}').Documents[0].Root
        Assert-Conversion ($distinct.Pairs.Count -eq 2) 'Distinct floats were collapsed through double precision.'
    }
    Test-Conversion 'YAML explicit tags are resolved independently of scalar style' {
        $root = (Read-WUGYamlStream '[!!int "0x2a", !!bool "TRUE", !!float "1.00", !!str null, ! null, !!null ""]' -Schema Failsafe).Documents[0].Root
        Assert-Conversion ($root.Items[0].Canonical -ceq '42' -and $root.Items[1].Canonical -ceq 'true' -and $root.Items[2].Canonical -ceq '1e0') 'Explicit typed tags were not resolved.'
        Assert-Conversion ($root.Items[3].ResolvedTag -ceq 'tag:yaml.org,2002:str' -and $root.Items[4].Canonical -ceq 'null' -and $root.Items[5].ResolvedTag -ceq 'tag:yaml.org,2002:null') 'Explicit/non-specific null/string tags changed.'
        foreach ($invalid in @('!!int nope', '!!bool yes', '!!float nope', '!!map scalar', '!!seq scalar', '!!str []')) {
            Assert-ConversionThrows { Read-WUGYamlStream $invalid } 'scalar|tag|Tag|collection'
        }
    }
    Test-Conversion 'YAML complex, null and empty keys are representation nodes' {
        $root = (Read-WUGYamlStream "? [alpha, {beta: gamma}]`n: value`n? {left: x, right: y}`n: another`nnull: nil`n`"null`": literal`n`"`": empty").Documents[0].Root
        Assert-Conversion ($root.Pairs.Count -eq 5 -and $root.Pairs[0].Key.Kind -ceq 'Sequence' -and $root.Pairs[1].Key.Kind -ceq 'Mapping') 'Complex keys were reduced to strings.'
        Assert-Conversion ($root.Pairs[2].Key.ResolvedTag -ceq 'tag:yaml.org,2002:null' -and $root.Pairs[3].Key.Canonical -ceq 'null' -and $root.Pairs[4].Key.Canonical -ceq '') 'Null/string/empty keys were conflated.'
        Assert-ConversionThrows { Read-ZabbixYaml '? [alpha, beta]' } 'Zabbix export validation: complex mapping keys'
        Assert-ConversionThrows { Read-ZabbixYaml '{null: value}' } 'Zabbix export validation: null/typed'
    }
    Test-Conversion 'YAML key equality is schema-aware and structural' {
        foreach ($duplicate in @('{0x2a: first, 42: second}', '{1.00: first, 1e0: second}',
            "? [alpha, beta]`n: first`n? [alpha, beta]`n: second",
            "? {left: x, right: y}`n: first`n? {right: y, left: x}`n: second")) {
            Assert-ConversionThrows { Read-WUGYamlStream $duplicate } 'Duplicate mapping key'
        }
        $differentTags = (Read-WUGYamlStream '{1: integer, 1.0: float, "1": string}').Documents[0].Root
        Assert-Conversion ($differentTags.Pairs.Count -eq 3) 'Keys with different scalar tags were conflated.'
        $left = (Read-WUGYamlStream '{left: x, right: y}').Documents[0].Root
        $right = (Read-WUGYamlStream '{right: y, left: x}').Documents[0].Root
        Assert-Conversion (Test-WUGYamlNodeEqual $left $right) 'Mapping equality incorrectly depends on entry order.'
        $ordinal = (Read-WUGYamlStream '{"a\u0000b": first, "ab": second, "\u00e9": third, "e\u0301": fourth}').Documents[0].Root
        Assert-Conversion ($ordinal.Pairs.Count -eq 4) 'String key equality must compare Unicode code points, not culture-normalized text.'
        Assert-ConversionThrows { Read-WUGYamlStream '!!null "nu\u0000ll"' } 'Invalid explicitly tagged null'
        Assert-ConversionThrows { Read-WUGYamlStream '!!bool "tr\u0000ue"' } 'Invalid boolean scalar'
    }
    Test-Conversion 'YAML graph aliases preserve identity and allow recursion' {
        $root = (Read-WUGYamlStream '&self [*self]').Documents[0].Root
        Assert-Conversion ([object]::ReferenceEquals($root, $root.Items[0].Target)) 'Recursive alias identity was not preserved.'
        $nested = (Read-WUGYamlStream '&parent {child: {back: *parent}}').Documents[0].Root
        Assert-Conversion ([object]::ReferenceEquals($nested, $nested.Pairs[0].Value.Pairs[0].Value.Target)) 'Nested recursive graph identity changed.'
        $shadowed = (Read-WUGYamlStream '[&a first, &a second, *a]').Documents[0].Root
        Assert-Conversion ([object]::ReferenceEquals($shadowed.Items[1], $shadowed.Items[2].Target)) 'Alias did not bind to the latest anchor.'
        Assert-ConversionThrows { Read-ZabbixYaml '&self [*self]' } 'Zabbix export validation: recursive alias'
    }
    Test-Conversion 'YAML opaque tags never instantiate objects' {
        $root = (Read-WUGYamlStream '!<tag:example.invalid,2026:opaque> payload').Documents[0].Root
        Assert-Conversion ($root.ResolvedTag -ceq 'tag:example.invalid,2026:opaque' -and $root.Canonical -ceq 'payload') 'Opaque tags were not retained as data.'
        $set = (Read-WUGYamlStream '!!set {member: null}').Documents[0].Root
        Assert-Conversion ($set.Kind -ceq 'Mapping' -and $set.ResolvedTag -ceq 'tag:yaml.org,2002:set') 'An unrecognized global tag must remain opaque data.'
        Assert-ConversionThrows { Read-ZabbixYaml '!<tag:example.invalid,2026:opaque> payload' } 'Zabbix export validation: unsupported YAML tag'
    }
    Test-Conversion 'YAML compatibility warnings and stricter flow validation are explicit' {
        $compat = Read-ZabbixYaml "%YAML 1.1`n---`na: yes" -WarningAction SilentlyContinue
        Assert-Conversion ($compat['a'] -ceq 'yes') 'Compatibility version changed the selected schema.'
        $reserved = Read-ZabbixYaml "%RESERVED argument`n---`na: value" -WarningAction SilentlyContinue
        Assert-Conversion ($reserved['a'] -ceq 'value') 'Reserved directives were not ignored.'
        Assert-ConversionThrows { Read-ZabbixYaml "a: [`n  value`n]" } 'Flow continuation'
    }
    Test-Conversion 'Nesting limit fails explicitly' {
        $nested = 'end'
        for ($i = 0; $i -lt 70; $i++) { $nested = "[$nested]" }
        Assert-ConversionThrows { Read-ZabbixYaml "a: $nested" } 'depth'
    }
    Test-Conversion 'XML DTDs and non-template roots are rejected' {
        $bad = Join-Path $temp 'bad.xml'
        [System.IO.File]::WriteAllText($bad, '<!DOCTYPE zabbix_export [<!ENTITY x "bad">]><zabbix_export>&x;</zabbix_export>', $encoding)
        Assert-ConversionThrows { Read-ZabbixExport $bad } 'DTD'
        $badYaml = Join-Path $temp 'workflow.yaml'
        [System.IO.File]::WriteAllText($badYaml, "name: workflow`non: push", $encoding)
        Assert-ConversionThrows { Read-ZabbixExport $badYaml } 'Not a Zabbix export'
    }
    Test-Conversion 'Unsafe or unsupported semantics are never ready' {
        foreach ($variant in @(
            @{ Field = 'preprocessing'; Value = @(@{ type = 'MULTIPLIER'; parameters = @('0.1') }); Code = 'PREPROCESSING' },
            @{ Field = 'snmp_oid'; Value = '1.3.6.{$OID}'; Code = 'OID_MACRO' },
            @{ Field = 'delay'; Value = '30s'; Code = 'POLLING_PRECISION' },
            @{ Field = 'delay'; Value = '5m;1m/1-5,09:00-18:00'; Code = 'POLLING_SCHEDULE' },
            @{ Field = 'value_type'; Value = 'TEXT'; Code = 'NON_NUMERIC' },
            @{ Field = 'type'; Value = 'ZABBIX_ACTIVE'; Code = 'ITEM_TYPE' },
            @{ Field = 'status'; Value = 'DISABLED'; Code = 'SOURCE_DISABLED' },
            @{ Field = 'snmp_oid'; Value = '9.3.6.1'; Code = 'OID_INVALID' },
            @{ Field = 'snmp_oid'; Value = '1.9999999999999999999999999999999999999.1'; Code = 'OID_INVALID' },
            @{ Field = 'delay'; Value = '9999999999999999999999999999999999999999999m'; Code = 'POLLING_PRECISION' },
            @{ Field = 'key'; Value = ''; Code = 'ITEM_IDENTITY' }
        )) {
            $export = Read-ZabbixExport $yamlPath
            $export.Data['templates'][0]['items'][0][$variant.Field] = $variant.Value
            $def = (ConvertFrom-ZabbixExport $export)[0].Definitions[0]
            Assert-Conversion ($def.Status -ne 'Ready' -and $null -eq $def.Candidate) "Unsafe candidate for $($variant.Code)."
            Assert-Conversion ($def.Reasons[0].Code -eq $variant.Code) "Wrong reason for $($variant.Code)."
        }
    }
    Test-Conversion 'Table prototypes, triggers and counts are retained' {
        $export = Read-ZabbixExport $yamlPath
        $template = $export.Data['templates'][0]
        $template['items'][0]['triggers'] = @(@{ name = 'History'; expression = 'max(/t/cpu,5m)>90' })
        $template['discovery_rules'] = @(@{
            name = 'Interfaces'; type = 'SNMP_AGENT'; snmp_oid = 'discovery[{#NAME},1.3.6.1.2.1.2.2.1.2]'
            item_prototypes = @(@{ name = 'Traffic'; key = 'traffic[{#SNMPINDEX}]'; type = 'SNMP_AGENT'; snmp_oid = '1.3.6.1.2.1.2.2.1.10.{#SNMPINDEX}' })
        })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Definitions.Count -eq 4 -and $profile.Counts.Deferred -eq 3) 'Definitions were dropped.'
        Assert-Conversion ($profile.Completion -eq 'Partial') 'Partial output reported success.'
    }
    Test-Conversion 'Nested prototype and export-level triggers are counted' {
        $export = Read-ZabbixExport $yamlPath
        $export.Data['triggers'] = @(@{ name = 'Global trigger'; expression = 'last(/t/cpu)>90' })
        $export.Data['templates'][0]['discovery_rules'] = @(@{
            name = 'Fans'
            item_prototypes = @(@{
                name = 'Fan'; key = 'fan[{#SNMPINDEX}]'; type = 'SNMP_AGENT'; snmp_oid = '1.3.6.1.{#SNMPINDEX}'
                trigger_prototypes = @(@{ name = 'Failed fan'; expression = 'last(/t/fan)=0' })
            })
        })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Definitions.Count -eq 5 -and $profile.Counts.Deferred -eq 4) 'Nested/global definition disappeared.'
    }
    Test-Conversion 'Disabled rules disable nested prototypes' {
        $export = Read-ZabbixExport $yamlPath
        $export.Data['templates'][0]['discovery_rules'] = @(@{
            name = 'Disabled fans'; status = 'DISABLED'
            item_prototypes = @(@{
                name = 'Fan'; key = 'fan[{#SNMPINDEX}]'; type = 'SNMP_AGENT'; snmp_oid = '1.3.6.1.{#SNMPINDEX}'
                trigger_prototypes = @(@{ name = 'Fan alert'; expression = 'last(/t/fan)=0' })
            })
        })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Counts.Disabled -eq 3) 'Disabled parent state was not propagated.'
    }
    Test-Conversion 'Template scripts remain data and are not executed' {
        $export = Read-ZabbixExport $yamlPath
        $marker = Join-Path $temp 'must-not-exist.txt'
        $item = $export.Data['templates'][0]['items'][0]
        $item['type'] = 'SCRIPT'
        $item['params'] = "Set-Content -LiteralPath '$marker' -Value executed"
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion (-not (Test-Path -LiteralPath $marker)) 'Template content was executed.'
        Assert-Conversion ($profile.Counts.Unsupported -eq 1) 'Script type was not reported.'
    }
    Test-Conversion 'Unresolved inheritance prevents ready export' {
        $export = Read-ZabbixExport $yamlPath
        $export.Data['templates'][0]['templates'] = @(@{ name = 'Missing parent' })
        $def = (ConvertFrom-ZabbixExport $export)[0].Definitions[0]
        Assert-Conversion ($def.Status -eq 'NeedsInput' -and $null -eq $def.Candidate) 'Unresolved parent was ignored.'
    }
    Test-Conversion 'Known sensitive fields and macro defaults are redacted' {
        $map = ConvertTo-ZabbixData ([PSCustomObject]@{
            snmp_community = 'never-export'; macros = @(@{ macro = '{$API.KEY}'; value = 'macro-secret' })
            description = 'embedded-secret'; nested = @{ password = 'password-secret' }
        })
        $safe = ConvertTo-Json -InputObject (Protect-ZabbixSource $map) -Depth 30
        Assert-Conversion ($safe -notmatch 'never-export|macro-secret|embedded-secret|password-secret') 'Sensitive content escaped redaction.'
    }
    Test-Conversion 'WhatIf writes nothing; exports are BOM encoded; overwrite is explicit' {
        $output = Join-Path $temp 'output'
        & $converter -Path $yamlPath -OutputDirectory $output -WhatIf | Out-Null
        Assert-Conversion (-not (Test-Path -LiteralPath $output)) 'WhatIf created output.'
        & $converter -Path $yamlPath -OutputDirectory $output -ExportMonitorTemplates | Out-Null
        $files = @(Get-ChildItem -LiteralPath $output -File)
        Assert-Conversion ($files.Count -eq 3) 'Expected profile, report and payload.'
        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            Assert-Conversion ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Missing UTF-8 BOM.'
        }
        $payload = Get-Content -LiteralPath ($files | Where-Object { $_.Name -like '*.monitors.json' }).FullName -Raw | ConvertFrom-Json
        Assert-Conversion ($payload.performanceMonitors -is [array] -and $payload.performanceMonitors.Count -eq 1) 'Wrong monitor envelope.'
        Assert-ConversionThrows { & $converter -Path $yamlPath -OutputDirectory $output } 'Output exists'
        & $converter -Path $yamlPath -OutputDirectory $output -Force | Out-Null
    }
    Test-Conversion 'Selection and version errors are explicit' {
        $export = Read-ZabbixExport $yamlPath
        Assert-ConversionThrows { ConvertFrom-ZabbixExport $export -TemplateName 'synthetic cisco snmp' } 'not found'
        $unsupported = Join-Path $temp 'unsupported.yaml'
        [System.IO.File]::WriteAllText($unsupported, $yaml.Replace("'6.0'", "'99.0'"), $encoding)
        Assert-ConversionThrows { Read-ZabbixExport $unsupported } 'Unsupported Zabbix export version'
    }
    Test-Conversion 'YAML anchors, aliases and block merge precedence' {
        $doc = Read-ZabbixYaml @'
defaults: &defaults
  value: original
  list: &items
  - one
  - two
copy: *defaults
merged:
  value: local
  <<: *defaults
later:
  <<: *defaults
  value: later
flow: [*items, *defaults]
flowmerge: {<<: *defaults, value: flow}
plain: first
  second

  third
'@
        Assert-Conversion ($doc['copy']['list'].Count -eq 2) 'Alias sequence lost.'
        Assert-Conversion ($doc['merged']['value'] -ceq 'local' -and $doc['later']['value'] -ceq 'later') 'Merge precedence changed.'
        $doc['copy']['value'] = 'changed'
        Assert-Conversion ($doc['defaults']['value'] -ceq 'original') 'Alias copies share mutable data.'
        Assert-Conversion ($doc['flow'].Count -eq 2) 'Flow aliases failed.'
        Assert-Conversion ($doc['flowmerge']['value'] -ceq 'flow') 'Flow merge precedence failed.'
        Assert-Conversion ($doc['plain'] -ceq "first second`nthird") 'Multiline plain scalar folding changed.'
        Assert-ConversionThrows { Read-ZabbixYaml 'value: &self [*self]' } 'recursive|Unknown'
        $bomb = 'a0: &a0 [x, x, x, x]'
        for ($i = 1; $i -le 10; $i++) {
            $previous = $i - 1
            $bomb += "`na${i}: &a${i} [*a$previous, *a$previous, *a$previous, *a$previous]"
        }
        Assert-ConversionThrows { Read-ZabbixYaml $bomb } 'limit'
    }
    Test-Conversion 'Non-secret default macros and explicit overrides' {
        $export = Read-ZabbixExport $yamlPath
        $template = $export.Data['templates'][0]
        $template['macros'] = @(@{ macro = '{$INTERVAL}'; value = '5m' }, @{ macro = '{$INDEX}'; value = '0' })
        $template['items'][0]['delay'] = '{$INTERVAL}'
        $template['items'][0]['snmp_oid'] = '1.3.6.1.4.1.9.2.1.57.{$INDEX}'
        $profile = (ConvertFrom-ZabbixExport $export -MacroValues @{ '{$INTERVAL}' = '10m' })[0]
        Assert-Conversion ($profile.Counts.Ready -eq 1 -and $profile.Definitions[0].Candidate.PollingIntervalMinutes -eq 10) 'Macro precedence failed.'
        $template['macros'] = @(@{ macro = '{$INTERVAL}'; value = '{$LOOP}' }, @{ macro = '{$LOOP}'; value = '{$INTERVAL}' })
        Assert-ConversionThrows { ConvertFrom-ZabbixExport $export } 'Macro cycle'
        Assert-ConversionThrows { ConvertFrom-ZabbixExport $export -MacroValues @{ '{$COMMUNITY}' = 'forbidden' } } 'Secret-like'
    }
    Test-Conversion 'Local inheritance, child macros, version isolation and cycles' {
        $parent = Read-ZabbixExport $yamlPath
        $child = Read-ZabbixExport $yamlPath
        $childTemplate = $child.Data['templates'][0]
        $childTemplate['template'] = 'Child'
        $childTemplate['items'] = @()
        $childTemplate['templates'] = @(@{ name = 'Synthetic Cisco SNMP' })
        $catalog = New-ZabbixTemplateCatalog @($parent, $child)
        $profile = (ConvertFrom-ZabbixExport $child -Catalog $catalog)[0]
        Assert-Conversion ($profile.Counts.Ready -eq 1 -and $profile.DependencySources.Count -eq 2) 'Inherited item was not resolved.'
        $parent.Data['templates'][0]['templates'] = @(@{ name = 'Child' })
        $catalog = New-ZabbixTemplateCatalog @($parent, $child)
        Assert-ConversionThrows { ConvertFrom-ZabbixExport $child -Catalog $catalog } 'cycle'
        $parent = Read-ZabbixExport $yamlPath
        $parent.Version = '7.0'
        $catalog = New-ZabbixTemplateCatalog @($parent, $child)
        $profile = (ConvertFrom-ZabbixExport $child -Catalog $catalog)[0]
        Assert-Conversion ($profile.ResolutionIssues.Count -eq 1) 'A different version satisfied a dependency.'
    }
    Test-Conversion 'Scalar active equality and healthy/problem polarity' {
        foreach ($comparison in @('=1', '<>1', '>90', '>=90')) {
            $export = Read-ZabbixExport $yamlPath
            $export.Data['templates'][0]['items'][0]['triggers'] = @(@{ name = "CPU $comparison"; expression = "last(/Synthetic Cisco SNMP/cpu)$comparison" })
            $profile = (ConvertFrom-ZabbixExport $export)[0]
            $active = @($profile.Definitions | Where-Object { $_.Kind -eq 'Trigger' })[0]
            Assert-Conversion ($active.Status -eq 'Ready' -and $active.Candidate.MonitorType -eq 'SNMP') "Active comparison $comparison failed."
            $bags = @{}
            foreach ($bag in $active.Candidate.Template.propertyBags) { $bags[$bag.name] = $bag.value }
            switch ($comparison) {
                '=1' { Assert-Conversion ($bags['SNMP:Constant-UpIfMatchValue'] -ceq '0') 'Problem equality was inverted.' }
                '<>1' { Assert-Conversion ($bags['SNMP:Constant-UpIfMatchValue'] -ceq '1') 'Healthy equality was inverted.' }
                '>90' { Assert-Conversion ($bags['SNMP:Range-HighValue'] -ceq '90') 'Strict threshold changed.' }
                '>=90' { Assert-Conversion ($bags['SNMP:Range-HighValue'] -ceq '89') 'Inclusive threshold changed.' }
            }
        }
    }
    Test-Conversion 'Legacy triggers and unsupported recovery/history remain explicit' {
        $export = Read-ZabbixExport $yamlPath
        $item = $export.Data['templates'][0]['items'][0]
        $item['triggers'] = @(@{ name = 'Legacy'; expression = '{Synthetic Cisco SNMP:cpu.last()}<>1' })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Counts.Ready -eq 2) 'Legacy current-value expression failed.'
        $item['triggers'][0]['dependencies'] = @(@{ name = 'Upstream' })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Counts.Deferred -eq 1) 'Trigger dependencies were dropped.'
        $item['triggers'] = @(@{ name = 'History'; expression = 'max(/Synthetic Cisco SNMP/cpu,#3)=0' })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Counts.Deferred -eq 1) 'Time-window behavior was simplified.'
    }
    Test-Conversion 'A missing scalar item yields a diagnostic, not a null-array error' {
        $export = Read-ZabbixExport $yamlPath
        $export.Data['templates'][0]['items'] = @()
        $export.Data['templates'][0]['triggers'] = @(@{ name = 'Missing'; expression = 'last(/Synthetic Cisco SNMP/missing)=1' })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Definitions[0].Reasons[0].Code -eq 'TRIGGER_ITEM') 'Missing item was not diagnosed.'
    }
    Test-Conversion 'Multiple files, dependency globals and opt-in CLI dry-run' {
        $parent = Read-ZabbixExport $yamlPath
        $parent.Data['templates'][0]['macros'] = @(@{ macro = '{$INTERVAL}'; value = '5m' })
        $parent.Data['templates'][0]['items'][0]['delay'] = '{$INTERVAL}'
        $parent.Data['triggers'] = @(@{ name = 'Parent CPU check'; expression = 'last(/Synthetic Cisco SNMP/cpu)>90' })
        $child = Read-ZabbixExport $yamlPath
        $childTemplate = $child.Data['templates'][0]
        $childTemplate['template'] = 'Selected child'
        $childTemplate['items'] = @()
        $childTemplate['templates'] = @(@{ name = 'Synthetic Cisco SNMP' })
        $parentPath = Join-Path $temp 'parent.json'
        $childPath = Join-Path $temp 'child.json'
        [System.IO.File]::WriteAllText($parentPath, (ConvertTo-Json -InputObject @{ zabbix_export = $parent.Data } -Depth 40), $encoding)
        [System.IO.File]::WriteAllText($childPath, (ConvertTo-Json -InputObject @{ zabbix_export = $child.Data } -Depth 40), $encoding)
        $profiles = @(& $converter -Path $childPath -DependencyPath $parentPath -TemplateName 'Selected child' -MacroValues @{ '{$INTERVAL}' = '10m' } -ImportToWUG -WhatIf)
        Assert-Conversion ($profiles.Count -eq 1 -and $profiles[0].Counts.Ready -eq 2) 'Dependency-global active trigger was lost.'
        Assert-Conversion ($profiles[0].LibraryImportResults.Count -eq 2 -and $profiles[0].DependencyGlobals.Count -eq 1) 'Import dry-run or dependency provenance failed.'
        $active = @($profiles[0].Definitions | Where-Object { $_.Candidate.ItemType -eq 'ActiveMonitor' })[0]
        Assert-Conversion ($active.Candidate.PollingIntervalSeconds -eq 600) 'Resolved active polling requirements were lost.'
        $both = @(& $converter -Path @($parentPath, $childPath))
        Assert-Conversion ($both.Count -eq 2) 'Multiple primary input files were not handled.'
    }
    Test-Conversion 'SNMP Table trigger with an exact source LLD selector' {
        $export = Read-ZabbixExport $yamlPath
        $export.Data['templates'][0]['discovery_rules'] = @(@{
            name = 'Fans'; key = 'fans'; type = 'SNMP_AGENT'
            snmp_oid = 'discovery[{#NAME},1.3.6.1.4.1.9.9.13.1.4.1.2]'
            filter = @{ conditions = @(@{ macro = '{#NAME}'; value = '^Fan1$'; operator = 'MATCHES_REGEX' }) }
            item_prototypes = @(@{
                name = 'Fan status'; key = 'fan[{#SNMPINDEX}]'; type = 'SNMP_AGENT'
                snmp_oid = '1.3.6.1.4.1.9.9.13.1.4.1.3.{#SNMPINDEX}'
                trigger_prototypes = @(@{ name = 'Fan failed'; expression = 'last(/Synthetic Cisco SNMP/fan[{#SNMPINDEX}])=3' })
            })
        })
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        $active = @($profile.Definitions | Where-Object { $_.Candidate -and $_.Candidate.MonitorType -eq 'SNMPTable' })
        Assert-Conversion ($active.Count -eq 1 -and $active[0].Status -eq 'Ready') 'SNMP Table template was not emitted.'
        $bags = @{}
        foreach ($bag in $active[0].Candidate.Template.propertyBags) { $bags[$bag.name] = $bag.value }
        Assert-Conversion ($bags['SNMP:Table-Constant-Value'] -ceq 'Fan1' -and $bags['SNMP:Table-CheckType'] -ceq '0') 'LLD selector changed.'
        Assert-Conversion ($bags['SNMP:OID'] -ceq '1.3.6.1.4.1.9.9.13.1.4.1.3' -and $bags['SNMP:Constant-UpIfMatchValue'] -ceq '0') 'Table column/polarity changed.'
        $script:ImportTableProfiles = @($profile)
        $script:TableSource = ConvertTo-ZabbixData $export.Data['templates'][0]['discovery_rules']
        $export.Data['templates'][0]['discovery_rules'][0].Remove('filter') | Out-Null
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion (@($profile.Definitions | Where-Object { $_.Reasons[0].Code -eq 'TABLE_SELECTOR' }).Count -eq 1) 'No-filter selection was guessed.'
        $profile = (ConvertFrom-ZabbixExport $export -TableDiscovery @{ fans = @{ Oid = '1.3.6.1.4.1.9.9.13.1.4.1.3'; Operator = 'gt'; Value = '0' } })[0]
        Assert-Conversion (@($profile.Definitions | Where-Object { $_.Candidate -and $_.Candidate.Semantics -eq 'ExplicitRowSelectionPolicy' }).Count -eq 1) 'Explicit row policy failed.'
    }
    Test-Conversion 'Trap listeners, portable regex, XML escaping and fallback semantics' {
        $export = Read-ZabbixExport $yamlPath
        $item = $export.Data['templates'][0]['items'][0]
        $item['type'] = 'SNMP_TRAP'
        $item['key'] = 'snmptrap["link(Down|Up)[[:space:]]<&"]'
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        $candidate = $profile.Definitions[0].Candidate
        Assert-Conversion ($candidate.MonitorType -eq 'SnmpTrap' -and $candidate.Semantics -eq 'EventFilterOnly') 'Trap filter was not emitted.'
        [xml]$xmlFilter = $candidate.Template.propertyBags[0].value
        Assert-Conversion ($xmlFilter.Expressions.Expression.sExpression -ceq 'link(Down|Up)[\t\n\v\f\r ]<&') 'Trap regex/XML changed.'
        Assert-Conversion ($xmlFilter.Expressions.Expression.bMatchCase -ceq '1') 'Case-sensitive Zabbix match changed.'
        $item['key'] = 'snmptrap.fallback'
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Definitions[0].Reasons[0].Code -eq 'TRAP_FALLBACK') 'Fallback was treated as catch-all.'
        $item['key'] = 'snmptrap["(?<=prefix)value"]'
        $profile = (ConvertFrom-ZabbixExport $export)[0]
        Assert-Conversion ($profile.Definitions[0].Reasons[0].Code -eq 'TRAP_REGEX_DIALECT') 'Unverified PCRE features were accepted.'
    }
    Test-Conversion 'All three WUG payload arrays contain the proper categories' {
        $export = Read-ZabbixExport $yamlPath
        $template = $export.Data['templates'][0]
        $template['items'][0]['triggers'] = @(@{ name = 'CPU threshold'; expression = 'last(/Synthetic Cisco SNMP/cpu)>90' })
        $trap = New-ZabbixMap
        $trap['name'] = 'Trap'; $trap['key'] = 'snmptrap["linkDown"]'; $trap['type'] = 'SNMP_TRAP'
        $template['items'] += $trap
        $profiles = ConvertFrom-ZabbixExport $export
        $payload = Get-ZabbixMonitorPayload $profiles
        Assert-Conversion ($payload.activeMonitors.Count -eq 1 -and $payload.performanceMonitors.Count -eq 1 -and $payload.passiveMonitors.Count -eq 1) 'Payload categories were mixed.'
        $script:ImportProfiles = $profiles
    }
    Test-Conversion 'Opt-in import WhatIf is offline without connection credentials' {
        $results = @(Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -WhatIf)
        Assert-Conversion ($results.Count -eq 3 -and @($results | Where-Object { $_.Action -ne 'PlannedUnverified' }).Count -eq 0) 'Offline import plan is invalid.'
    }
    Test-Conversion 'CLI persists all four monitor classes in the correct JSON arrays' {
        $export = Read-ZabbixExport $yamlPath
        $template = $export.Data['templates'][0]
        $template['items'][0]['triggers'] = @(@{ name = 'CPU threshold'; expression = 'last(/Synthetic Cisco SNMP/cpu)>90' })
        $template['items'] += @{ name = 'Trap'; key = 'snmptrap["linkDown"]'; type = 'SNMP_TRAP' }
        $template['discovery_rules'] = ConvertTo-ZabbixData $script:TableSource
        $inputFile = Join-Path $temp 'all-types.json'
        $output = Join-Path $temp 'all-types-output'
        [System.IO.File]::WriteAllText($inputFile, (ConvertTo-Json -InputObject @{ zabbix_export = $export.Data } -Depth 60), $encoding)
        $profiles = @(& $converter -Path $inputFile -OutputDirectory $output -ExportMonitorTemplates)
        $payloadFile = @(Get-ChildItem -LiteralPath $output -Filter '*.monitors.json')[0]
        $payload = Get-Content -LiteralPath $payloadFile.FullName -Raw | ConvertFrom-Json
        Assert-Conversion ($payload.activeMonitors.Count -eq 2 -and $payload.performanceMonitors.Count -eq 1 -and $payload.passiveMonitors.Count -eq 1) 'Persisted payload arrays have the wrong categories/counts.'
        Assert-Conversion ($profiles[0].Counts.Ready -eq 4) 'Expected exactly four converted monitor definitions.'
        $classes = @($payload.activeMonitors | ForEach-Object { $_.monitorTypeInfo.classId })
        Assert-Conversion ('d6d02d69-a418-483a-93ea-20dd2af2d135' -in $classes -and 'f14ef52e-b9da-4a2f-b48f-56c96a004cf2' -in $classes) 'Scalar/table class IDs are missing.'
    }
    Test-Conversion 'Library import creates, reconciles and reuses all three categories' {
        Invoke-ConversionMockWug {
            $results = @(Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -Confirm:$false)
            Assert-Conversion ($results.Count -eq 3 -and $script:MockLibrary.Count -eq 3 -and $script:MockPatches.Count -eq 1) 'Library creation failed.'
            $body = $script:MockPatches[0]
            Assert-Conversion ($body.activeMonitors.Count -eq 1 -and $body.performanceMonitors.Count -eq 1 -and $body.passiveMonitors.Count -eq 1) 'Wrong import envelope.'
            Assert-Conversion ($script:MockReads.Count -eq 2) 'The library was not reconciled.'
            $script:MockPaginate = $true
            $results = @(Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -Confirm:$false)
            Assert-Conversion (@($results | Where-Object { $_.Action -eq 'Existing' }).Count -eq 3 -and $script:MockPatches.Count -eq 1) 'A rerun created duplicates.'
            Assert-Conversion (@($script:MockReads | Where-Object { $_ -match 'pageId=next%261' }).Count -eq 1) 'Pagination ID was not escaped or followed.'
        }
    }
    Test-Conversion 'SNMP Table templates can be created and reconciled in the library' {
        Invoke-ConversionMockWug {
            $results = @(Invoke-WUGZabbixProfileImport -Profiles $script:ImportTableProfiles -Confirm:$false)
            Assert-Conversion ($results.Count -eq 2) 'Expected one table active monitor plus one performance monitor.'
            $table = $script:MockPatches[0].activeMonitors[0]
            Assert-Conversion ($table.monitorTypeInfo.classId -ceq 'f14ef52e-b9da-4a2f-b48f-56c96a004cf2' -and $table.useInDiscovery) 'Wrong table library template.'
        }
    }
    Test-Conversion 'Import name conflicts fail before writing and prefix avoids conflict' {
        Invoke-ConversionMockWug {
            [void](Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -Confirm:$false)
            $script:MockLibrary[0].propertyBags[0].value = 'different'
            Assert-ConversionThrows { Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -Confirm:$false } 'different configuration'
            Assert-Conversion ($script:MockPatches.Count -eq 1) 'Conflict caused a write.'
            $results = @(Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -NamePrefix 'Converted - ' -Confirm:$false)
            Assert-Conversion (@($results | Where-Object { $_.Action -eq 'Created' }).Count -eq 3) 'Name prefix did not isolate new monitors.'
        }
    }
    Test-Conversion 'Library read failures do not become empty-library writes' {
        Invoke-ConversionMockWug {
            $script:MockFailure = 'Read'
            Assert-ConversionThrows { Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -Confirm:$false } 'read failed'
            Assert-Conversion ($script:MockPatches.Count -eq 0) 'A failed read resulted in creation.'
        }
    }
    Test-Conversion 'Partial creation, missing IDs and failed reconciliation are errors' {
        foreach ($failure in @('Partial', 'MissingMap', 'Reconcile')) {
            Invoke-ConversionMockWug {
                $script:MockFailure = $failure
                Assert-ConversionThrows { Invoke-WUGZabbixProfileImport -Profiles $script:ImportProfiles -Confirm:$false } 'batch|idMap|reconciliation'
                Assert-Conversion ($script:MockPatches.Count -eq 1) 'A failed creation was retried.'
            }
        }
    }
    Test-Conversion 'Bulk creation batches at 50 and confirms every ID' {
        Invoke-ConversionMockWug {
            $definitions = @(
                for ($i = 0; $i -lt 51; $i++) {
                    $candidate = ConvertTo-ZabbixData $script:ImportProfiles[0].Definitions[0].Candidate
                    $candidate.Template['name'] = "Bulk performance $i"
                    [PSCustomObject]@{ Status = 'Ready'; Candidate = $candidate }
                }
            )
            $results = @(Invoke-WUGZabbixProfileImport -Profiles @([PSCustomObject]@{ Definitions = $definitions }) -Confirm:$false)
            Assert-Conversion ($results.Count -eq 51 -and $script:MockPatches.Count -eq 2) 'Wrong bulk operation counts.'
            Assert-Conversion ($script:MockPatches[0].performanceMonitors.Count -eq 50 -and $script:MockPatches[1].performanceMonitors.Count -eq 1) 'Batch size exceeded 50.'
        }
    }
    if ($CommunityTemplateRoot) {
        foreach ($relative in @(
            'Network_Devices\Cisco\template_cisco_1900\5.0\template_cisco_1900.xml',
            'Network_Devices\Cisco\template_cisco_1900\6.0\template_cisco_1900.yaml',
            'Network_Devices\Cisco\template_cisco_2960\5.0\template_cisco_2960.xml',
            'Network_Devices\Cisco\template_cisco_2960\6.0\template_cisco_2960.yaml'
        )) {
            Test-Conversion "Community Cisco export: $relative" {
                $export = Read-ZabbixExport (Join-Path $CommunityTemplateRoot $relative)
                $profiles = ConvertFrom-ZabbixExport $export
                Assert-Conversion ($profiles.Count -gt 0) 'No profiles returned.'
                foreach ($profile in $profiles) {
                    $total = 0
                    foreach ($count in $profile.Counts.Values) { $total += $count }
                    Assert-Conversion ($total -eq $profile.Definitions.Count) 'Status counts do not reconcile.'
                }
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output "Results: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQxCTcFo2/ule5
# JuSvgvFPINnXyCsFP59x6sgWtE5mJaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
# jTanyYqJ1pQWMA0GCSqGSIb3DQEBDAUAMHsxCzAJBgNVBAYTAkdCMRswGQYDVQQI
# DBJHcmVhdGVyIE1hbmNoZXN0ZXIxEDAOBgNVBAcMB1NhbGZvcmQxGjAYBgNVBAoM
# EUNvbW9kbyBDQSBMaW1pdGVkMSEwHwYDVQQDDBhBQUEgQ2VydGlmaWNhdGUgU2Vy
# dmljZXMwHhcNMjEwNTI1MDAwMDAwWhcNMjgxMjMxMjM1OTU5WjBWMQswCQYDVQQG
# EwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0aWdv
# IFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCN55QSIgQkdC7/FiMCkoq2rjaFrEfUI5ErPtx94jGgUW+s
# hJHjUoq14pbe0IdjJImK/+8Skzt9u7aKvb0Ffyeba2XTpQxpsbxJOZrxbW6q5KCD
# J9qaDStQ6Utbs7hkNqR+Sj2pcaths3OzPAsM79szV+W+NDfjlxtd/R8SPYIDdub7
# P2bSlDFp+m2zNKzBenjcklDyZMeqLQSrw2rq4C+np9xu1+j/2iGrQL+57g2extme
# me/G3h+pDHazJyCh1rr9gOcB0u/rgimVcI3/uxXP/tEPNqIuTzKQdEZrRzUTdwUz
# T2MuuC3hv2WnBGsY2HH6zAjybYmZELGt2z4s5KoYsMYHAXVn3m3pY2MeNn9pib6q
# RT5uWl+PoVvLnTCGMOgDs0DGDQ84zWeoU4j6uDBl+m/H5x2xg3RpPqzEaDux5mcz
# mrYI4IAFSEDu9oJkRqj1c7AGlfJsZZ+/VVscnFcax3hGfHCqlBuCF6yH6bbJDoEc
# QNYWFyn8XJwYK+pF9e+91WdPKF4F7pBMeufG9ND8+s0+MkYTIDaKBOq3qgdGnA2T
# OglmmVhcKaO5DKYwODzQRjY1fJy67sPV+Qp2+n4FG0DKkjXp1XrRtX8ArqmQqsV/
# AZwQsRb8zG4Y3G9i/qZQp7h7uJ0VP/4gDHXIIloTlRmQAOka1cKG8eOO7F/05QID
# AQABo4IBEjCCAQ4wHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYD
# VR0OBBYEFDLrkpr/NZZILyhAQnAgNpFcF4XmMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMDMBsGA1UdIAQUMBIwBgYE
# VR0gADAIBgZngQwBBAEwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21v
# ZG9jYS5jb20vQUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEE
# KDAmMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZI
# hvcNAQEMBQADggEBABK/oe+LdJqYRLhpRrWrJAoMpIpnuDqBv0WKfVIHqI0fTiGF
# OaNrXi0ghr8QuK55O1PNtPvYRL4G2VxjZ9RAFodEhnIq1jIV9RKDwvnhXRFAZ/ZC
# J3LFI+ICOBpMIOLbAffNRk8monxmwFE2tokCVMf8WPtsAO7+mKYulaEMUykfb9gZ
# pk+e96wJ6l2CxouvgKe9gUhShDHaMuwV5KZMPWw5c9QLhTkg4IUaaOGnSDip0TYl
# d8GNGRbFiExmfS9jzpjoad+sPKhdnckcW67Y8y90z7h+9teDnRGWYpquRRPaf9xH
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCM+fK7qewdu1cVDYmJCOlo4N+wnYiZ+GngeF1gV426ezANBgkqhkiG9w0BAQEF
# AASCAgCsBDfEm57wtx9fAtZ50sxb4BoYlc8M5TOWFU2GKrUK5zS39JT4oyEM1PyG
# KJaZV2RlYWLUiSlINy4wCZ9MeWfjoRowITNhqogCJQ/yY1CGeMwBZvJxuXkt8JW3
# vgMmqMA6B+yuLd1vI8KSq5DCj9O/gCaNARGTxI22eWj+Y9Zclx7CFlGBff/0TRsk
# UFpj9X8Xp24OF+qbdHlKg4RucuPk3hQNO6TVOT6uEt8TytovoMOpWf/5fhU6J+Ta
# mIAbLULwh8iuJFBER+OD7BsPO++H4HVddbblrf4KV9yKYFBLmyHVjtFNcefb/+sN
# d9ijKoyqiHc03g2mOLOdO5cYHPBRGjIcTzXiOcaT08WQdVQWK/CVY+M2HesSvHjM
# Rjh5nN6Ot4vtp9SR0VeNrCI9s88LzKEWYeIc6Y7v7tNgN3SLslyv2OeLvnI9THOO
# TpUdWJuVPxlr7zyRxGF07jkwYmCBLSau+sJAY7XYzwH6gko88B0dQuT+qNkNaW5U
# tdZ4VKwR7rAugkaHwVLsbOMnFiRXspUXOmZqppTE9jsTbm/vBbl68kY/TQTJX396
# mGr8JuhWbCK6qYnpizMy2I2c8v96iQmmglnmwk2N+F/Gy1byEt3hLxJtZtYBZOBs
# 526lknpNK2Osp8mQ1A80XJ0QasW4J0jyLOUlICDQdNQpje3eHKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjEwMjIwMDM4NDdaMC8GCSqGSIb3DQEJBDEiBCAFmQuB
# b+fS0gScVqdXYiOSjIbixsqHowqp73fyv/CRFzANBgkqhkiG9w0BAQEFAASCAgB7
# a75C/AMHdY9Sd5A/J+u2BlvRlGfsX4Iorj5FaZlHT4TCbvqrfai4Txdy3FUPytWC
# 8IM0+9fWKlk/71PiBLseVohZOWDWr158k5ogs/0N7F6yt4Mq3VhSs72E3ZZBI6Zd
# QUFBWTJTwYbYLKMcnesNhazi2ZxdQ45SfLQGaf82MGKUgeEIv8qG9qNCn6qenag2
# SgtmwFFzTEaUFHNkiTNIPGvFCZlFAb96x2foTkgnDlfO4xL05LS/J5grXQOnyswk
# Jw/pbdNIMdeKNo9ZTSaTvWPeCXL7ZcxYE2f7MQrXuWh9l6rZqwGvRiJZxcd9rGzj
# zprNRiaOoaXjMHV11qvUfvttxVnOyf9/wB6TUpvJ0OyUKdofQ82u74DwBLNsVp+4
# 2woCGJ2pzRdtfgsw4sveIetmPupgkmK3OJRSw5ikU7dFOpCrEtHu4m6PMnEjnNmh
# shUBXhZv0u0wv52NuEzMtLqeFMUhDT+9YsJWwaLwhtZAMspuMQGGNMPr/4p5BE7J
# N6vmJEMRInL5qsfrSI4uqB3wAZcAMH5G1xNNxaat9qusINUvvoKxbP8BBF/eVe85
# xb/9daAxAdINAGK/GcF/y1FiqUygzRoNqpwBwADg3tNRNkK1I7LGBovGJbbiVHzP
# amfLSQ93YGw99J8d0PirCe6RM6kr0bMChiOoQ0+cSA==
# SIG # End signature block
