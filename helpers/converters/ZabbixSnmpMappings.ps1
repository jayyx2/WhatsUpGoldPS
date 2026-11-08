$mappingDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $mappingDir 'ZabbixConversionCommon.ps1')

function Test-ZabbixNumericOid {
    param([string]$Oid)
    if ($Oid -notmatch '^\.?[0-9]+(?:\.[0-9]+)+$') { return $false }
    $arcs = $Oid.TrimStart('.').Split('.')
    foreach ($arc in $arcs) {
        $number = [uint32]0
        if (-not [uint32]::TryParse($arc, [ref]$number)) { return $false }
    }
    return $arcs.Count -ge 3 -and $arcs[0] -match '^[012]$' -and ($arcs[0] -eq '2' -or [uint32]$arcs[1] -le 39)
}

function New-ZabbixMonitorCandidate {
    param($Definition, [string]$Name, [string]$BaseType, [string]$MonitorType, [string]$ClassId,
        [System.Collections.IDictionary]$Bags, [string]$Semantics)
    $properties = @(
        foreach ($key in $Bags.Keys) { [ordered]@{ name = $key; value = [string]$Bags[$key] } }
    )
    $itemType = switch ($BaseType) { 'active' { 'ActiveMonitor' } 'passive' { 'PassiveMonitor' } default { 'PerformanceMonitor' } }
    $nameText = $Name -replace '\{#[A-Za-z0-9_.]+\}', '[row]'
    $Definition.Candidate = [PSCustomObject][ordered]@{
        ItemType = $itemType
        MonitorType = $MonitorType
        Name = $nameText
        Semantics = $Semantics
        Template = [ordered]@{
            templateId = $Definition.Id
            name = $nameText
            description = "WhatsUpGoldPS Zabbix conversion; $Semantics; live validation required."
            monitorTypeInfo = [ordered]@{ classId = $ClassId; baseType = $BaseType }
            propertyBags = $properties
        }
    }
}

function ConvertTo-ZabbixTrapCandidate {
    param($Definition, $Item, [string]$TemplateName, [bool]$Prototype)
    if ($Prototype -or [string]$Item['key'] -match '\{#') {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TRAP_INSTANCE' 'Trap prototype filters require live row expansion before a concrete listener can be created.'
        return
    }
    if ($Item['preprocessing']) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TRAP_PREPROCESSING' 'Trap preprocessing cannot be represented by a passive payload filter.'
        return
    }
    $key = [string]$Item['key']
    if ($key -notmatch '^snmptrap\[(.*)\]$') {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TRAP_FALLBACK' 'Zabbix fallback/unrecognized trap routing is not equivalent to a catch-all WUG listener.'
        return
    }
    $pattern = $Matches[1]
    if ($pattern.StartsWith('"')) {
        if (-not $pattern.EndsWith('"') -or $pattern.Length -lt 2) {
            Set-ZabbixDefinitionState $Definition 'Invalid' 'TRAP_KEY' 'Unterminated quoted trap key parameter.'
            return
        }
        $pattern = $pattern.Substring(1, $pattern.Length - 2).Replace('\"', '"')
    }
    elseif ($pattern.Contains(',')) {
        Set-ZabbixDefinitionState $Definition 'Invalid' 'TRAP_KEY' 'The trap key must contain one filter parameter.'
        return
    }
    if ($pattern -match '\{\$|^@') {
        Set-ZabbixDefinitionState $Definition 'NeedsInput' 'TRAP_REGEX_REFERENCE' 'Resolve user macros or Zabbix global regular expressions before creating this listener.'
        return
    }
    if (-not $pattern) { $pattern = '.*' }
    $posix = [ordered]@{ '[[:space:]]' = '[\t\n\v\f\r ]'; '[[:digit:]]' = '[0-9]'; '[[:alpha:]]' = '[A-Za-z]'; '[[:alnum:]]' = '[A-Za-z0-9]' }
    foreach ($token in $posix.Keys) { $pattern = $pattern.Replace($token, $posix[$token]) }
    if ($pattern -cmatch '\(\?|\\[1-9]|\\[AbBCDEGHKLMNPRSTUVWXZz]|\\[pPkKgG]|[+*?}]\+|\[:|(^|[^\\])\^.*(^|[^\\])\^') {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TRAP_REGEX_DIALECT' 'This filter uses regex features whose PCRE/WUG equivalence is not established.'
        return
    }
    # Avoid differences between PCRE's default ASCII classes and Unicode-aware engines.
    $pattern = $pattern.Replace('\d', '[0-9]').Replace('\w', '[A-Za-z0-9_]').Replace('\s', '[\t\n\v\f\r ]')
    try { [void][regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) }
    catch [System.ArgumentException] {
        Set-ZabbixDefinitionState $Definition 'Invalid' 'TRAP_REGEX_INVALID' 'Invalid trap filter regular expression.'
        return
    }
    $escaped = [System.Security.SecurityElement]::Escape($pattern)
    $expression = "<Expressions>`r`n  <Expression sExpression=`"$escaped`" bMatchCase=`"1`" bInvertResult=`"0`" />`r`n</Expressions>"
    New-ZabbixMonitorCandidate $Definition "$TemplateName - $($Item['name'])" 'passive' 'SnmpTrap' '805ebfde-caad-49d7-a81b-e26ba7725149' `
        ([ordered]@{ sExpressions = $expression; nMajor = '7'; nMinor = '0' }) 'EventFilterOnly'
    Set-ZabbixDefinitionState $Definition 'Ready' 'TRAP_LISTENER' 'Passive event filter only: Zabbix history, nodata windows, recovery and alert dependencies are not implemented by this listener.'
}

function Get-ZabbixSimpleTrigger {
    param($Trigger)
    if ($Trigger['dependencies'] -or [string]$Trigger['recovery_mode'] -notin @('', '0', 'EXPRESSION') -or
        $Trigger['recovery_expression'] -or [string]$Trigger['type'] -notin @('', '0', 'SINGLE') -or
        [string]$Trigger['manual_close'] -notin @('', '0', 'NO', 'DISABLED') -or $Trigger['correlation_tag']) { return $null }
    $expression = [string]$Trigger['expression']
    $pattern = '^last\(/(?<host>[^/]+)/(?<key>.+)\)\s*(?<op><>|>=|<=|=|>|<)\s*(?<value>-?[0-9]+(?:\.[0-9]+)?)$'
    $legacy = '^\{(?<host>[^:]+):(?<key>.+)\.last\((?:0)?\)\}\s*(?<op><>|>=|<=|=|>|<)\s*(?<value>-?[0-9]+(?:\.[0-9]+)?)$'
    if ($expression -notmatch $pattern -and $expression -notmatch $legacy) { return $null }
    return [PSCustomObject]@{ Host = $Matches['host']; Key = $Matches['key']; Operator = $Matches['op']; Value = $Matches['value'] }
}

function Get-ZabbixTableSelector {
    param($Rule, [System.Collections.IDictionary]$Overrides)
    if ([string]$Rule['type'] -notin @('SNMP_AGENT', '1', '4', '6') -or $Rule['preprocessing'] -or $Rule['overrides']) { return $null }
    if ([string]$Rule['snmp_oid'] -notmatch '^discovery\[(.+)\]$') { return $null }
    $parts = $Matches[1].Split(',')
    if ($parts.Count % 2 -ne 0) { return $null }
    $columns = New-ZabbixMap
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $macro = $parts[$i].Trim()
        $oid = $parts[$i + 1].Trim().TrimStart('.')
        if ($macro -notmatch '^\{#[A-Za-z0-9_.]+\}$' -or -not (Test-ZabbixNumericOid $oid) -or $columns.ContainsKey($macro)) { return $null }
        $columns.Add($macro, $oid)
    }
    if ($columns.Count -eq 0) { return $null }
    $commentOid = @($columns.Values)[0]
    if ($Overrides -and $Overrides.ContainsKey([string]$Rule['key'])) {
        $policy = $Overrides[[string]$Rule['key']]
        if ($policy -isnot [System.Collections.IDictionary] -or -not (Test-ZabbixNumericOid ([string]$policy['Oid'])) -or
            [string]$policy['Operator'] -notin @('equals', 'contains', 'gt', 'lt') -or
            $null -eq $policy['Value'] -or [string]$policy['Value'] -eq '') { throw "Invalid explicit table selector for '$($Rule['key'])'." }
        return [PSCustomObject]@{ Oid = ([string]$policy['Oid']).TrimStart('.'); Operator = [string]$policy['Operator']; Value = [string]$policy['Value']; CommentOid = $commentOid; Semantics = 'ExplicitRowSelectionPolicy' }
    }
    $filter = $Rule['filter']
    if ($filter -isnot [System.Collections.IDictionary]) { return $null }
    $conditions = @($filter['conditions'])
    if ($conditions.Count -ne 1 -or [string]$filter['evaltype'] -notin @('', '0', '1', '2', 'AND_OR', 'AND', 'OR')) { return $null }
    $condition = $conditions[0]
    if ($condition -isnot [System.Collections.IDictionary] -or [string]$condition['operator'] -notin @('', '8', 'MATCHES_REGEX') -or
        -not $columns.ContainsKey([string]$condition['macro'])) { return $null }
    $value = [string]$condition['value']
    if ($value -match '^\^([A-Za-z0-9 _/:-]+)\$$') {
        $value = $Matches[1]
        $operator = 'equals'
    }
    elseif ($value -match '^[A-Za-z0-9 _/:-]+$') { $operator = 'contains' }
    else { return $null }
    return [PSCustomObject]@{ Oid = $columns[[string]$condition['macro']]; Operator = $operator; Value = $value; CommentOid = $commentOid; Semantics = 'SourceRowSelection' }
}

function ConvertTo-ZabbixActiveCandidate {
    param($Definition, $Trigger, [string]$TemplateName, $Context, $Rule, $ItemContext)
    if ([string]$Trigger['expression'] -match '\{\$' -or [string]$Trigger['name'] -match '\{\$') {
        Set-ZabbixDefinitionState $Definition 'NeedsInput' 'TRIGGER_MACRO' 'The trigger contains an unresolved user macro.'
        return
    }
    $check = Get-ZabbixSimpleTrigger $Trigger
    if (-not $check) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TRIGGER_SEMANTICS' 'Only a single current-value comparison without history/recovery/dependencies/manual closure is translatable.'
        return
    }
    if ($check.Host -cnotin $Context.Lineage) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TRIGGER_HOST' 'Cross-template/host trigger references outside the resolved lineage are not translated.'
        return
    }
    $items = @($Context.Items | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['key'] -ceq $check.Key })
    if ($Rule) { $items = @($Rule['item_prototypes'] | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['key'] -ceq $check.Key }) }
    if ($ItemContext -and [string]$ItemContext['key'] -ceq $check.Key) { $items = @($ItemContext) }
    if ($items.Count -ne 1) {
        Set-ZabbixDefinitionState $Definition 'NeedsInput' 'TRIGGER_ITEM' 'The trigger must resolve to exactly one local SNMP item.'
        return
    }
    $item = $items[0]
    if ([string]$item['status'] -in @('DISABLED', '1')) {
        Set-ZabbixDefinitionState $Definition 'Disabled' 'SOURCE_DISABLED' 'The referenced item is disabled.'
        return
    }
    if ([string]$item['type'] -notin @('SNMP_AGENT', '1', '4', '6') -or $item['preprocessing'] -or
        [string]$item['delta'] -notin @('', '0', 'AS_IS') -or [string]$item['value_type'] -notin @('', 'FLOAT', 'UNSIGNED', '0', '3')) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'ACTIVE_ITEM_SEMANTICS' 'The active check requires an untransformed SNMP polling item.'
        return
    }
    $oid = [string]$item['snmp_oid']
    if ($oid -match '^get\[(.+)\]$') { $oid = $Matches[1] }
    $isTable = $null -ne $Rule
    if ($isTable) {
        if ($oid -notmatch '^(\.?[0-9]+(?:\.[0-9]+)+)\.\{#SNMPINDEX\}$') {
            Set-ZabbixDefinitionState $Definition 'Deferred' 'TABLE_INDEX' 'Only a whole SNMPINDEX suffix on a numeric column OID is supported.'
            return
        }
        $oid = $Matches[1]
    }
    if (-not (Test-ZabbixNumericOid $oid)) {
        Set-ZabbixDefinitionState $Definition 'NeedsInput' 'ACTIVE_OID' 'Resolve the numeric polling OID before generating the active monitor.'
        return
    }
    $oid = $oid.TrimStart('.')
    $delay = [string]$item['delay']
    if (-not $delay) { $delay = '1m' }
    $seconds = [long]0
    if ($delay -match '^([1-9][0-9]*)([smhd]?)$') {
        $amount = [long]0
        $unit = $Matches[2]
        if ([long]::TryParse($Matches[1], [ref]$amount) -and $amount -le 86400) {
            $factor = switch ($unit) { 'm' { 60 } 'h' { 3600 } 'd' { 86400 } default { 1 } }
            $seconds = $amount * $factor
        }
    }
    if ($seconds -lt 10 -or $seconds -gt 86400) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'ACTIVE_SCHEDULE' 'The active source interval must be a fixed value between 10 and 86400 seconds; no rounding/default substitution was applied.'
        return
    }
    $comparison = switch ($check.Operator) { '=' { '0' } '<>' { '0' } '>' { '3' } '<' { '4' } default { '' } }
    $upIfMatch = if ($check.Operator -eq '<>') { '1' } else { '0' }
    if (-not $isTable) {
        $constant = [int]0
        if ($check.Operator -in @('=', '<>') -and (-not [int]::TryParse($check.Value, [ref]$constant) -or $constant -lt 0)) {
            Set-ZabbixDefinitionState $Definition 'Deferred' 'ACTIVE_CONSTANT' 'Scalar constant checks currently require a nonnegative Int32 value supported by the module.'
            return
        }
        $bags = [ordered]@{ 'SNMP:CheckType' = '0'; 'SNMP:OID' = $oid; 'SNMP:Instance' = ''; 'SNMP:Constant-Value' = $check.Value; 'SNMP:Constant-UpIfMatchValue' = $upIfMatch }
        if ($check.Operator -notin @('=', '<>')) {
            $number = [int]0
            if ([string]$item['value_type'] -notin @('UNSIGNED', '3') -or $check.Operator -notin @('>', '>=') -or
                -not [int]::TryParse($check.Value, [ref]$number) -or $number -lt 1) {
                Set-ZabbixDefinitionState $Definition 'Deferred' 'ACTIVE_RANGE' 'Scalar thresholds currently require unsigned integer > or >= comparisons with a positive Int32 threshold.'
                return
            }
            $high = $number
            if ($check.Operator -eq '>=') { $high-- }
            $bags = [ordered]@{ 'SNMP:CheckType' = '1'; 'SNMP:OID' = $oid; 'SNMP:Instance' = ''; 'SNMP:Range-LowValue' = '0'; 'SNMP:Range-HighValue' = [string]$high }
        }
        New-ZabbixMonitorCandidate $Definition "$TemplateName - $($Trigger['name'])" 'active' 'SNMP' 'd6d02d69-a418-483a-93ea-20dd2af2d135' $bags 'CurrentValueOnly'
    }
    else {
        if (-not $comparison) {
            Set-ZabbixDefinitionState $Definition 'Deferred' 'TABLE_COMPARISON' 'Table checks currently support =, <>, > or < comparisons.'
            return
        }
        $selector = Get-ZabbixTableSelector $Rule $Context.TableDiscovery
        if (-not $selector) {
            Set-ZabbixDefinitionState $Definition 'NeedsInput' 'TABLE_SELECTOR' 'Supply an explicit TableDiscovery selector for this rule, or use a single representable literal LLD condition. No match-all criterion was guessed.'
            return
        }
        $discoveryType = switch ($selector.Operator) { 'equals' { '0' } 'contains' { '4' } 'gt' { '3' } 'lt' { '2' } }
        $bags = [ordered]@{
            'SNMP:Table-DiscOID' = $selector.Oid; 'SNMP:Table-CheckType' = $discoveryType
            'SNMP:Table-Constant-Value' = $selector.Value; 'SNMP:Table-Range-LowValue' = '0'; 'SNMP:Table-Range-HighValue' = '0'
            'SNMP:Table-CommentOID' = $selector.CommentOid; 'SNMP:Table-IndexOID' = $selector.CommentOid
            'SNMP:Table-Match-Creates' = '1'; 'SNMP:OID' = $oid; 'SNMP:CheckType' = $comparison
            'SNMP:Constant-Value' = $check.Value; 'SNMP:Range-LowValue' = '0'; 'SNMP:Range-HighValue' = '0'
            'SNMP:Constant-UpIfMatchValue' = $upIfMatch; 'Cred:Type' = '1,2,4'; 'SNMP:Retries' = '1'; 'SNMP:Timeout' = '3'
        }
        New-ZabbixMonitorCandidate $Definition "$TemplateName - $($Rule['name']) - $($Trigger['name'])" 'active' 'SNMPTable' 'f14ef52e-b9da-4a2f-b48f-56c96a004cf2' $bags $selector.Semantics
        $Definition.Candidate.Template['useInDiscovery'] = $true
    }
    $Definition.Candidate | Add-Member -NotePropertyName PollingIntervalSeconds -NotePropertyValue ([int]$seconds)
    Set-ZabbixDefinitionState $Definition 'Ready' 'SNMP_ACTIVE' 'Current-value condition translated with problem/healthy polarity. Assignment timing and live WUG behavior still require validation.'
}

function Get-ZabbixMonitorPayload {
    param([object[]]$Profiles)
    $payload = [ordered]@{ activeMonitors = @(); performanceMonitors = @(); passiveMonitors = @() }
    foreach ($profile in $Profiles) {
        foreach ($definition in $profile.Definitions) {
            if ($definition.Status -ne 'Ready' -or $null -eq $definition.Candidate) { continue }
            $type = [string]$definition.Candidate.Template.monitorTypeInfo.baseType
            $key = "${type}Monitors"
            if (-not $payload.Contains($key)) { throw "Unknown converted monitor base type '$type'." }
            $payload[$key] += $definition.Candidate.Template
        }
    }
    return $payload
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBOLuxjglnFWd2S
# hMiUYrIJzU8xdiWLaEADr0ZTI70lVKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCjNkE4jkh8B7Q0xloFoIXkZ/b+lfdFN6KQuctV2YQUXjANBgkqhkiG9w0BAQEF
# AASCAgBGgHLsJcV2D3/UwoZF+gnvToWNT71EOQCxrDtwA14+egJCzeNx3l2cf9gw
# qUKISGKSL9DyK8FkKK4g2QkN2Y/i+m2T46iqJLTF004BYKKjWRkqYHIds7QjFt8R
# pmjf5CuhoN4s28mY8hakWiHi4bt3I3lhw4Fp8YFpCZ+V19fGJjpL4ifevqhQ55sE
# e8ZwXSZlSqd0HE/6KakszZKm1Z9XuraYKhHbb3z18xevRLMg9hU50diknbpGVrjf
# a6Uo8xfufrvJSc1aPzjWT8ExI2MC/b5X6nunsNOax/+wwyZZ4ACh1bfqSOhE9XqD
# sq/W6d6TeKsHAcqNoULy7sWlBuzHxN0Gf/31nOCnNZ/7U3R7YXZ2BxDXT5iAcnPy
# vGi+qEGdXvkv+ai8jk6xasCvsEnrvJiEG9qI32xr+Bga4ue6U52nKvVQ7gq2bK7d
# psHLVR+xy+Zg6BbSANnYv2a+rkWCrK+T8pgQL9rVLCooaBqbliwWznH7MVPvZLzE
# 5I3Tl3TbV9jhlv9IdwqDmx+mIfBgCVTV16FmdQ4dS6Ea5kE4mTwrNL91yN0oDvle
# egXpPZTsOzB5+pgL5Ud1wK2whQ90gkrApXptVlinIAkg5f6e7B+nc7WClJm3fbrs
# mnKttV/7JkPzNaopOwx0IhR6oNy6no0nRJRz4aqvhrGE06UJFaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjEwMjEyMTA2MTRaMC8GCSqGSIb3DQEJBDEiBCBq8+5W
# tz6DWbul4BERBUD5DqaCdgW5IOiwrwMPO2AOBDANBgkqhkiG9w0BAQEFAASCAgB6
# IKuXdovVcbARYxfkBSN7gNGprrNczAFf4jCy6R9wiWQaZFsYnErSJGw8yM8xgq3q
# MxNzv23DOa05OkXDKuNQFPxOnLwAIhXnAu79NhNppLX5mvNKUInjKwD05POA250G
# 6Va4q2EYMGP43CkZxTOMzeQgBIMXszquJK8TptohGetM+tzcJ1Q4VZBR1871CvvF
# H5jW5CKtAwLoRUJNoIit0V5IW9LMbPgX6TWySB8A/cPx+57c4vvQw9hndACl6SSL
# W3Ml6KHcfapvTdGbF4QgUOTB6QS4f5/MNDBRVa3SJ/Qb997KZ1yuIcR11FkdaT9C
# uR9+1XwCjDXIKCShoT9QVGQWCWMUpiYRCBIoi8hsj8ll5jcv/scsuR5XbkAtEFgY
# H5XJieCiAauS5OYQA0aedrZwbGdwZIlDM7+R+i2IJiz67oD7lQajcuJOxdv8Y3Jh
# zYUf8BPzLDmlBpv/oPndpi7jgDT/DeE3EaJyS+Lr+l7lfn28znZv93xGtwwCd/oM
# aD6dhItI7mKBxZzHnm7le6o4LnO99jnZcmYodMqlr7A7OfmxOwLdLgtWxJ+09H8n
# Nk5qV65Rp8qvl4/MLaSxVGitdFsDGEM1Dhox2U4+WFRzFbKPAm8dmLGMqvbDcTD6
# QGkbdesCkdc1Y0QHli8hda4lfSKE3a7hytuiBR4qiQ==
# SIG # End signature block
