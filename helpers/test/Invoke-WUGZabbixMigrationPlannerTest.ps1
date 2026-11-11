<#
.SYNOPSIS
    Tests guided Zabbix migration without contacting Zabbix or WUG.
.DESCRIPTION
    Verifies effective item mappings, redacted plans, staged credentials, discovery,
    resume validation, preflight gates and creation/assignment read-back.
.EXAMPLE
    .\helpers\test\Invoke-WUGZabbixMigrationPlannerTest.ps1
.NOTES
    Dependency-free Windows PowerShell 5.1 test runner.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..'
. (Join-Path $root 'helpers\converters\ZabbixMigrationPlanner.ps1')
$realAddCredential = (Get-Command Add-WUGCredential).ScriptBlock
$example = Join-Path $root 'examples\Import-ZabbixHostsToWUG.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($example, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
$script:passed = 0
function Assert-Migration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Assert-MigrationThrows {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action; throw 'Expected failure was not raised.' }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        $script:passed++
    }
}
filter Out-Host {}
function New-TestItem {
    param([string]$Id = '1', [string]$Type = '20', [string]$Key = 'load')
    [PSCustomObject]@{
        itemid = $Id; name = 'source item'; key_ = $Key; type = $Type; status = '0'
        delay = '1m'; value_type = '3'; snmp_oid = '1.3.6.1.2.1.1.3.0'; preprocessing = @()
        interfaceid = '10'; username = ''; password = ''; authtype = '0'; port = '22'
        request_method = '0'; url = 'https://web.invalid/health'; verify_peer = '1'; verify_host = '1'
        follow_redirects = '0'; headers = @(); posts = ''; query_fields = @(); http_proxy = ''
    }
}
$hostInfo = [PSCustomObject]@{ host = 'host01'; hostid = '1'; name = 'Host One'; status = '0' }
$snmpItem = New-TestItem
$pingItem = New-TestItem '2' '3' 'icmpping'
$tcpItem = New-TestItem '3' '3' 'net.tcp.service[tcp,,443]'
$httpItem = New-TestItem '4' '19' 'http.check'
$sshItem = New-TestItem '5' '13' 'ssh.run[check]'
$dbItem = New-TestItem '6' '11' 'db.odbc.select[check]'
$cpuItem = New-TestItem '7' '0' 'system.cpu.util'
$profile = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items @($snmpItem,$pingItem,$tcpItem,$httpItem,$sshItem,$dbItem,$cpuItem) `
    -Triggers @() -Rules @([PSCustomObject]@{ itemid='8' }) -WebScenarios @([PSCustomObject]@{ httptestid='9' })
Assert-Migration ($profile.Definitions.Count -eq 9) 'Effective inventory omitted requirements.'
Assert-Migration ($profile.Definitions[0].Status -eq 'Ready') 'Numeric SNMP item did not map.'
Assert-Migration ($profile.Definitions[0].Candidate.Semantics -eq 'EffectiveHostSnapshot') 'Snapshot was not labeled.'
Assert-Migration ($profile.Definitions[0].Candidate.PollingIntervalMinutes -eq 1) 'SNMP cadence changed.'
Assert-Migration ($profile.Definitions[1].Status -eq 'Review') 'Ping was silently approved.'
Assert-Migration ($profile.Definitions[2].Status -eq 'Review') 'TCP was silently approved.'
Assert-Migration ($profile.Definitions[3].Status -eq 'Review') 'HTTP was silently approved.'
Assert-Migration (-not $profile.Definitions[4].Candidate -and -not $profile.Definitions[5].Candidate) 'Source commands or queries were translated without review.'
Assert-Migration (-not $profile.Definitions[6].Candidate) 'Agent CPU was silently equated to WMI.'
$alternativeProfile = [PSCustomObject]@{ Definitions = @($profile.Definitions[1..3]) }
foreach ($definition in $alternativeProfile.Definitions) { $definition.Status = 'Ready' }
Assert-MigrationThrows { Invoke-WUGZabbixProfileImport -Profiles @($alternativeProfile) -WhatIf } '*Only converted*'
$alternativeReceipts = @(Invoke-WUGZabbixProfileImport -Profiles @($alternativeProfile) -IncludeMigrationAlternatives -WhatIf)
Assert-Migration ($alternativeReceipts.Count -eq 3) 'Real importer rejected explicitly enabled alternatives.'
foreach ($definition in $alternativeProfile.Definitions) { $definition.Status = 'Review' }
foreach ($change in @('preprocessing', 'auth', 'headers', 'tls', 'redirect', 'query', 'method')) {
    $item = New-TestItem '4' '19'
    switch ($change) {
        preprocessing { $item.preprocessing = @(@{type='1';params='2'}) }
        auth { $item.authtype = '1' }
        headers { $item.headers = @(@{name='Authorization';value='synthetic-secret'}) }
        tls { $item.verify_peer = '0' }
        redirect { $item.follow_redirects = '1' }
        query { $item.url = 'https://web.invalid/?token=synthetic-secret' }
        method { $item.request_method = '1' }
    }
    $result = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items @($item)
    Assert-Migration (-not $result.Definitions[0].Candidate) "Unsafe HTTP $change was mapped."
}
foreach ($delay in @('5s', '90s', '1m;30s/1-7,00:00-24:00', '{$DELAY}', '0')) {
    $item = New-TestItem; $item.delay = $delay
    $result = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items @($item)
    Assert-Migration ($result.Definitions[0].Status -ne 'Ready') "Invalid/rounded SNMP interval '$delay' was approved."
}
$item = New-TestItem; $item.status = '1'
$result = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items @($item)
Assert-Migration ($result.Definitions[0].Status -eq 'Disabled') 'Disabled effective item was enabled.'
$item = New-TestItem; $item.snmp_oid = '1.3.6.1.2.1.2.2.1.10.12.34.56'
$result = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items @($item)
Assert-Migration (($result.Definitions[0].Candidate.Template.propertyBags | Where-Object name -eq 'SNMP:OID').value -eq $item.snmp_oid) 'Composite resolved instance was truncated.'

$script:answers = [System.Collections.Generic.Queue[string]]::new()
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { return ConvertTo-SecureString 'synthetic-secret' -AsPlainText -Force }
    if ($script:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $script:answers.Dequeue()
}
$rows = @([PSCustomObject]@{id='1';name='one'},[PSCustomObject]@{id='2';name='two'})
$script:answers.Enqueue('3'); $script:answers.Enqueue('1,2,1')
$selected = Select-ZabbixMigrationRows $rows 'Select'
Assert-Migration (@($selected).Count -eq 2) 'Picker failed validation/deduplication.'
$script:answers.Enqueue('B')
Assert-Migration ((Select-ZabbixMigrationRows $rows 'Select') -eq 'B') 'Back did not navigate.'
$script:answers.Enqueue('Q')
Assert-Migration ((Select-ZabbixMigrationRows $rows 'Select') -eq 'Q') 'Cancel did not navigate.'

$apiUri = [uri]'https://zabbix.invalid/api_jsonrpc.php'
$global:WhatsUpServerBaseURI = 'https://wug.invalid:9644'
$global:WUGBearerHeaders = @{Authorization='synthetic-token'}
$credentialSources = @{}
$candidatePlan = [PSCustomObject]@{ Host='host01'; Prefix='test '; SourceKey='test'; CredentialType='aws'; Label='AWS' }
$credentialSources['test'] = @{
    accesskey = ConvertTo-SecureString 'synthetic-access' -AsPlainText -Force
    secretkey = ConvertTo-SecureString 'synthetic-secret' -AsPlainText -Force
}
$script:vaultWrites = 0; $script:credentialWrites = 0
function Initialize-DiscoveryVault {}
function Get-DiscoveryCredential {}
function Get-WugExamplePages { param($Path,$Collection); return @() }
function Save-DiscoveryCredential { param($Name,$Fields,$Description,[switch]$Force,[switch]$Confirm); $script:vaultWrites++ }
function Add-WUGCredential {
    param($Name,$Type,$Description,$AwsAccessKeyID,$AwsSecureAccessKey,[switch]$Confirm)
    $script:credentialWrites++
    Assert-Migration ($AwsSecureAccessKey -eq 'synthetic-secret') 'Credential payload lost the supplied secret.'
    $script:currentCredential = [PSCustomObject]@{id='99';name=$Name;type=$Type}
    return $script:currentCredential
}
function Invoke-WugExampleRequest {
    param($Path,$Method,$Body)
    [PSCustomObject]@{data=[PSCustomObject]@{id='99';name='test credential';type='aws'}}
}
foreach ($answer in @('', 'Y','Y')) { $script:answers.Enqueue($answer) }
$staged = New-WugExampleCredential $candidatePlan -DeferCreation
Assert-Migration (-not $staged.id -and $staged.Fields.Count -eq 2) 'Credential was not staged.'
Assert-Migration ($script:vaultWrites -eq 0 -and $script:credentialWrites -eq 0) 'Credential writes happened before APPLY.'
$applied = Apply-ZabbixMigrationCredential $staged
Assert-Migration ($applied.id -eq '99' -and $script:vaultWrites -eq 1 -and $script:credentialWrites -eq 1) 'Staged credential did not apply/read back.'
foreach ($value in $staged.Fields.Values) { $value.Dispose() }
foreach ($value in $credentialSources.test.Values) { $value.Dispose() }

function Get-WUGAPIResponse {
    [CmdletBinding()]
    param($Uri,$Method,$Body,[int]$MaxRetries)
    Assert-Migration ($Method -eq 'POST' -and $PSBoundParameters.ContainsKey('MaxRetries') -and $MaxRetries -eq 0) 'Real credential POST may be blindly retried.'
    $script:credentialPayload = ConvertFrom-Json $Body
    [PSCustomObject]@{data=[PSCustomObject]@{id='99';name=$script:credentialPayload.name;type=$script:realType}}
}
$credentialContracts = @{
    restapi = @{ Arguments=@{RestApiUsername='user';RestApiPassword='synthetic-secret'}; Bags=@{'CredRestAPI:Username'='user';'CredRestAPI:Password'='synthetic-secret';'CredRestAPI:Authtype'='0'} }
    ado = @{ Arguments=@{AdoUsername='user';AdoPassword='synthetic-secret'}; Bags=@{'CredADO:Username'='user';'CredADO:Password'='synthetic-secret'} }
    aws = @{ Arguments=@{AwsAccessKeyID='key';AwsSecureAccessKey='synthetic-secret'}; Bags=@{'CredAWS:AccessKeyID'='key';'CredAWS:SecureAccessKey'='synthetic-secret'} }
    azure = @{ Arguments=@{AzureTenantID='tenant';AzureClientID='client';AzureSecureKey='synthetic-secret'}; Bags=@{'CredAzure:TenantID'='tenant';'CredAzure:ClientID'='client';'CredAzure:SecureKey'='synthetic-secret'} }
    redfish = @{ Arguments=@{RedfishUsername='user';RedfishPassword='synthetic-secret';RedfishIgnoreCertErrors='False'}; Bags=@{'CredRedfishBmc:Username'='user';'CredRedfishBmc:Password'='synthetic-secret';'CredRedfishBmc:IgnoreCertificateErrors'='False'} }
}
foreach ($type in @('restapi','ado','aws','azure','redfish')) {
    $script:realType = $type
    $arguments = @{Name='fixture';Type=$type}
    foreach ($field in $credentialContracts[$type].Arguments.Keys) { $arguments[$field] = $credentialContracts[$type].Arguments[$field] }
    $receipt = & $realAddCredential @arguments -Confirm:$false -ErrorAction Stop
    Assert-Migration ($receipt.id -eq '99') "Real $type credential did not return its ID."
    foreach ($bag in $credentialContracts[$type].Bags.Keys) {
        $actual = @($script:credentialPayload.propertyBags | Where-Object name -eq $bag)
        Assert-Migration ($actual.Count -eq 1 -and $actual[0].value -ceq $credentialContracts[$type].Bags[$bag]) "Wrong $type property bag '$bag'."
    }
}

$credentialSources = @{}
$plan = [PSCustomObject]@{Host='host01';Prefix='test '}
$macros = @(
    [PSCustomObject]@{macro='{$AWS.ACCESS_KEY_ID}';value='readable-id';type='0'}
    [PSCustomObject]@{macro='{$AWS.SECRET_ACCESS_KEY}';value='******';type='1'}
    [PSCustomObject]@{macro='{$AZURE.TENANT_ID}';value='tenant';type='0'}
    [PSCustomObject]@{macro='{$REDFISH.USERNAME}';value='user';type='0'}
    [PSCustomObject]@{macro='{$VMWARE.USERNAME}';value='user';type='0'}
    [PSCustomObject]@{macro='{$JMX.USERNAME}';value='user';type='0'}
)
$candidates = @(Get-ZabbixMigrationCredentials $plan @() $macros @() @())
Assert-Migration ($candidates.Count -eq 5) 'Cloud/Redfish/VMware/JMX candidates missing.'
Assert-Migration (-not $credentialSources['host01|aws-macros'].ContainsKey('secretkey')) 'Secret macro was treated as readable.'
Assert-Migration (@($candidates | Where-Object AuthMode -eq 'ExistingOnly').Count -eq 2) 'Unverified credential contracts were enabled.'
Assert-Migration ((ConvertTo-Json -InputObject $candidates -Depth 10) -notmatch 'readable-id|SecureString|\*{6}') 'Credential candidate metadata leaked values.'
foreach ($source in $credentialSources.Values) { foreach ($value in $source.Values) { $value.Dispose() } }
$keyItem = New-TestItem '5' '13'; $keyItem.authtype='1'
$keyCandidates = @(Get-ZabbixMigrationCredentials $plan @($keyItem) @() @() @())
Assert-Migration ($keyCandidates.Count -eq 1 -and $keyCandidates[0].AuthMode -eq 'ExistingOnly') 'SSH keys were silently downgraded or omitted.'

$credentialFields = @{
    restapi=@{RestApiUsername='username';RestApiPassword='password'}
    ado=@{AdoUsername='username';AdoPassword='password'}
    aws=@{AwsAccessKeyID='accesskey';AwsSecureAccessKey='secretkey'}
    azure=@{AzureTenantID='tenantid';AzureClientID='clientid';AzureSecureKey='clientsecret'}
    redfish=@{RedfishUsername='username';RedfishPassword='password'}
}
foreach ($type in @('restapi','ado','aws','azure','redfish')) {
    $candidatePlan = [PSCustomObject]@{Host='host01';Prefix='test ';SourceKey="stage-$type";CredentialType=$type;AuthMode='Basic'}
    $source = @{}
    foreach ($field in $credentialFields[$type].Values) { $source[$field]=ConvertTo-SecureString 'synthetic-secret' -AsPlainText -Force }
    $credentialSources[$candidatePlan.SourceKey]=$source
    $script:answers.Enqueue('')
    foreach ($field in $credentialFields[$type].Keys) { $script:answers.Enqueue('Y') }
    $staged = New-WugExampleCredential $candidatePlan -DeferCreation
    Assert-Migration ($staged.Fields.Count -eq $credentialFields[$type].Count) "Staging lost $type fields."
    foreach ($field in $credentialFields[$type].Keys) { Assert-Migration ($staged.Fields.ContainsKey($field)) "Staging lost typed parameter '$field'." }
    foreach ($value in $staged.Fields.Values) { $value.Dispose() }
    foreach ($value in $source.Values) { $value.Dispose() }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('WugZabbixPlannerTest-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $plan = [PSCustomObject]@{ HostId='1'; Fingerprint=('a' * 24); Profile=$profile; ExistingMonitors=@(); Secrets='synthetic-secret' }
    Save-ZabbixMigrationPlan $temp @($plan) $apiUri.AbsoluteUri
    $json = [System.IO.File]::ReadAllText($temp)
    Assert-Migration ($json -notmatch 'synthetic-secret|propertyBags|SecureString|Password|Fields') 'Saved plan leaked private fields or payloads.'
    $saved = Read-ZabbixMigrationPlan $temp
    Assert-Migration ($saved.Hosts[0].HostId -eq '1') 'Saved plan did not round-trip.'
    Assert-MigrationThrows { Save-ZabbixMigrationPlan $temp @($plan) $apiUri.AbsoluteUri } '*already exists*'
    $bytes = [System.IO.File]::ReadAllBytes($temp)
    Assert-Migration ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Saved plan is not UTF-8 BOM.'
}
finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }

# End-to-end planner with bounded source/WUG fakes, including source permission failures.
$script:mode = 'Preview'
$script:assignedMonitors = @()
$script:writes = 0
$script:discoveredMethods = [System.Collections.Generic.List[string]]::new()
function Invoke-ZabbixExampleRequest {
    param($Method,$Parameters,[switch]$Anonymous)
    $script:discoveredMethods.Add($Method)
    if ($script:mode -eq 'Permissions' -and $Method -eq 'httptest.get') { throw 'Source permissions denied.' }
    switch ($Method) {
        'apiinfo.version' { return '7.4.1' }
        'hostgroup.get' { return [PSCustomObject]@{groupid='1';name='Test group'} }
        'host.get' {
            return [PSCustomObject]@{
                hostid='1';host='host01';name='Host One';status='0';parentTemplates=@();macros=@()
                interfaces=@([PSCustomObject]@{interfaceid='10';main='1';type='1';useip='1';ip='192.0.2.1';port='10050'})
            }
        }
        'item.get' { return $pingItem }
        { $_ -in @('usermacro.get','trigger.get','discoveryrule.get','httptest.get') } { return @() }
        default { throw "Unexpected source method $Method" }
    }
}
function Connect-WUGServer { $script:connected=$true }
function Find-WugExampleDevice { param($Plan); return }
function Get-WUGZabbixLibraryTemplates {
    if ($script:mode -eq 'NameConflict') {
        $profile = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items @($pingItem)
        $template = ConvertTo-ZabbixData $profile.Definitions[0].Candidate.Template
        $template['name'] = 'Zabbix zabbix.invalid 1 - ' + $template.name
        $template['id'] = '101'
        ($template.propertyBags | Where-Object name -eq 'Timeout').value = '99'
        return @{ ("active|" + $template.name).ToLowerInvariant() = $template }
    }
    return @{}
}
function Invoke-WUGZabbixProfileImport {
    param($Profiles,$NamePrefix,[switch]$IncludeMigrationAlternatives,[switch]$Confirm)
    Assert-Migration $IncludeMigrationAlternatives 'Planner bypassed verified importer extension.'
    $script:writes++
    [PSCustomObject]@{Name=$NamePrefix+$Profiles[0].Definitions[0].Candidate.Name;BaseType='active';MonitorId='100';Action='Created'}
}
function Add-WUGDeviceTemplate {
    param($displayName,$DeviceAddress,$Hostname,$SNMPPort,$Brand,[switch]$NoDefaultActiveMonitor,[switch]$Confirm)
    $script:writes++
    [PSCustomObject]@{successful=1;errors=@();idMap=@([PSCustomObject]@{templateId='1';resultId='200'})}
}
function Get-WugExamplePages {
    param($Path,$Collection)
    if ($Path -like 'credentials/-*') {
        if ($Path -like '*type=windows*' -or $Path -like '*type=all*') {
            return [PSCustomObject]@{id='99';name='Windows fixture';type='windows'}
        }
        return @()
    }
    return $script:assignedMonitors
}
function Invoke-WugExampleRequest {
    param($Path,$Method='GET',$Body)
    if ($Path -like 'monitors/-/config/supported-types*') {
        $class = if ($script:mode -eq 'Unsupported') { 'unsupported' } else { '2655476e-36b0-455f-9cce-940b6f8e07bf' }
        return [PSCustomObject]@{data=@([PSCustomObject]@{classId=$class;baseType='active'})}
    }
    if ($Path -like 'credentials/99*') { return [PSCustomObject]@{data=$script:currentCredential} }
    if ($Path -like 'devices/*/credentials/-*') {
        if ($Method -eq 'PUT') {
            Assert-Migration ($Body -eq '99') 'Credential assignment body was not the selected ID.'
            $script:writes++; $script:credentialBound=$true
            return [PSCustomObject]@{success=$true}
        }
        return [PSCustomObject]@{data=@($script:currentCredential)}
    }
    if ($Path -like 'devices/*/monitors/-' -and $Method -eq 'POST') {
        $script:writes++
        if ($script:mode -ne 'ReadBackFailure') {
            $script:assignedMonitors += [PSCustomObject]@{type=$Body.type;monitorTypeId=$Body.monitorTypeId}
        }
        return [PSCustomObject]@{data=[PSCustomObject]@{successful=1}}
    }
    throw "Unexpected WUG request $Path"
}
foreach ($mode in @('Preview','Cancel','Apply','NeedsReview','CredentialExisting','CredentialCreate','Unsupported','NameConflict','ReadBackFailure','Permissions')) {
    $script:mode=$mode; $script:connected=$false; $script:writes=0; $script:assignedMonitors=@()
    $script:vaultWrites=0; $script:credentialWrites=0; $script:credentialBound=$false
    $script:currentCredential=[PSCustomObject]@{id='99';name='Windows fixture';type='windows'}
    $script:answers.Clear()
    foreach ($answer in @('https://zabbix.invalid/api_jsonrpc.php','A','A')) { $script:answers.Enqueue($answer) }
    if ($mode -eq 'Cancel') { $script:answers.Enqueue('Q') }
    elseif ($mode -eq 'NeedsReview') {
        foreach ($answer in @('A','M','Y','A','APPLY')) { $script:answers.Enqueue($answer) }
    }
    elseif ($mode -eq 'CredentialExisting') {
        foreach ($answer in @('M','Y','C','Y','5','Y','1','Y','A','APPLY')) { $script:answers.Enqueue($answer) }
    }
    elseif ($mode -eq 'CredentialCreate') {
        foreach ($answer in @('M','Y','C','Y','8','Y','C','','Y','A','APPLY')) { $script:answers.Enqueue($answer) }
    }
    elseif ($mode -notin @('Preview','Permissions')) {
        foreach ($answer in @('M','Y','A','APPLY')) { $script:answers.Enqueue($answer) }
    }
    if ($mode -eq 'Unsupported') {
        Assert-MigrationThrows { Invoke-ZabbixMigrationPlanner -Confirm:$false } '*does not advertise*'
        Assert-Migration ($script:writes -eq 0) 'Unsupported monitor preflight wrote data.'
    }
    elseif ($mode -eq 'NameConflict') {
        Assert-MigrationThrows { Invoke-ZabbixMigrationPlanner -Confirm:$false } '*name/configuration conflict*'
        Assert-Migration ($script:writes -eq 0) 'Library name/configuration preflight wrote data.'
    }
    elseif ($mode -eq 'ReadBackFailure') {
        Assert-MigrationThrows { Invoke-ZabbixMigrationPlanner -Confirm:$false } '*reconciliation failed*'
    }
    elseif ($mode -eq 'Permissions') {
        Assert-MigrationThrows { Invoke-ZabbixMigrationPlanner -WhatIf } '*permissions denied*'
        Assert-Migration (-not $script:connected -and $script:writes -eq 0) 'Source failure allowed WUG mutation.'
    }
    else {
        $report = @(Invoke-ZabbixMigrationPlanner -WhatIf:($mode -eq 'Preview') -Confirm:$false)
        if ($mode -in @('Apply','NeedsReview','CredentialExisting','CredentialCreate')) {
            $expectedWrites = if ($mode -in @('Apply','NeedsReview')) { 3 } else { 4 }
            Assert-Migration ($script:writes -eq $expectedWrites -and $report[0].DeviceId -eq '200') 'Full planner apply did not create/assign expected objects.'
            Assert-Migration ($report[0].LiveValidation -eq 'NotRun' -and $report[0].AssignmentValidation -eq 'ReadBackVerified') 'Read-back was misrepresented as live polling.'
            if ($mode -in @('CredentialExisting','CredentialCreate')) { Assert-Migration ($script:credentialBound -and $report[0].AssignedCredentials -eq 1) 'Explicit additional credential was not assigned.' }
            if ($mode -eq 'CredentialCreate') {
                Assert-Migration ($script:vaultWrites -eq 1 -and $script:credentialWrites -eq 1) 'Staged credential was not saved and created once.'
            }
        }
        else {
            Assert-Migration ($script:writes -eq 0) 'Preview/cancel wrote data.'
            if ($mode -eq 'Preview') { Assert-Migration (-not $script:connected) 'Preview connected to WUG.' }
        }
    }
}
$missingMethods = @(@('hostgroup.get','host.get','item.get','trigger.get','discoveryrule.get','httptest.get','usermacro.get') |
    Where-Object { -not $script:discoveredMethods.Contains($_) })
Assert-Migration ($missingMethods.Count -eq 0) 'Effective source inventory API surfaces were omitted.'

$resumeFile = Join-Path ([System.IO.Path]::GetTempPath()) ('WugZabbixResumeTest-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $script:mode='Apply'; $script:answers.Clear(); $script:writes=0; $script:assignedMonitors=@()
    foreach ($answer in @('https://zabbix.invalid/api_jsonrpc.php','A','A','M','Y','S',$resumeFile,'Q')) { $script:answers.Enqueue($answer) }
    Invoke-ZabbixMigrationPlanner -Confirm:$false
    Assert-Migration ((Test-Path -LiteralPath $resumeFile) -and $script:writes -eq 0) 'Saving review selections performed mutations.'
    $script:answers.Enqueue('A'); $script:answers.Enqueue('APPLY')
    $report = @(Invoke-ZabbixMigrationPlanner -PlanPath $resumeFile -Confirm:$false)
    Assert-Migration ($report[0].DeviceId -eq '200') 'Saved approved monitor selections did not resume.'
    $pingItem.delay='2m'
    Assert-MigrationThrows { Invoke-ZabbixMigrationPlanner -PlanPath $resumeFile -WhatIf } '*Source changed*'
}
finally {
    $pingItem.delay='1m'
    if (Test-Path -LiteralPath $resumeFile) { Remove-Item -LiteralPath $resumeFile -Force }
}
Write-Output "Passed: $script:passed"

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB1UMboQUP/R2vD
# +nTCk5HGUs0yTMjheFgHtaf7y/eauKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCW
# +xtoeT+Bo3qVYplOii4iYH8SIOefFmLMRayurBwgRDANBgkqhkiG9w0BAQEFAASC
# AgAn7obXvwUvPDpriXXAZhiCb+kIrFvXiWUh44Y+s1N+kwj2bE8ixn7Bx6ERdUrg
# c/sc1F8wrfvX3GVGxoKCt0UUkcle5xh+cf7KnJV2rj8q1Gv35RFfO7KPh9DxeXIt
# eR5YGFSAWE8Cb84XGDU/ochPfsfMU5OTIMT3NmhO5wE4xVUyaKMc72gbp6lBjrbO
# Wgsv4VTq7PtFq2cae6urKcXKrElgwZCrqR/cxlg/gEOXSaBq8S6ZSAZNa/I3Awv8
# B+WGc15drr2uwLjdoOLE8gJ+m5EvRZmw56ZqieJwc3L/YXRJCUkKFXNgpVsHj2vM
# S9yrOlT49k4Tk8M0jjd5G5Eqx9oe+lZbTGW5qozZfqy8F83JadW1Ac57CDBLj7/O
# kRORV8s1CTzf9TWMxr+E0wLvugSdZrWpC5r+M8TryUPbnv3LIuPNASWIElsnZ0al
# tPDu0DDbvv9s7GKq+wYp2hIj3prSeDLugX782q5C/A3tntL2u1FeNsy8UscwxCwo
# rwQrNtROCiFcR83EwUsJ8BjFJsrQ/Y/lRwe+f/ga93Y6WGUVsLY3l6DzWsDpTD/D
# fEjW+lv70w5EO2Fyqwfmy9oTWlrXTH6eU/uP1RfN+cpMPiy7bUx1T8jxIgfYds/S
# 2ZEGlXbcQGrol7/bvLzhICNFrQ6IuZWceCuYXv9gJ51JbqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MjNaMC8GCSqGSIb3DQEJBDEiBCCw0mQ9rtF3
# 4mMkp5c5gawRShsAQBsv26RhLF175lYTcDANBgkqhkiG9w0BAQEFAASCAgBgrepW
# Ovc2rHHSW9S3wDmk2he0695KLaHDfAa3IPfrh4i6SeES9XffVK9Vhe7iaoN03Xyn
# UbuJ6Z5LB2Zb2HYMk2K8EO0HtxE0Lsp/O6e4/OfFc1XcxvFukX7ZuU2luXiljuxB
# WTecJiilRxRKA9QANc3uxPggOoLcaWWl/F1CMeZzOisgmvpK+lV0BUWJ/nb3meiO
# OZBXbobya44SLozin0NyyYaRVLdYkQGOrrhT0MJP/BKORM1RK5P+yUNLRQq5f6DB
# pvwsDAfYP56GBNnHtRdCBqVL86Bgt9MUej9dEnAwENm9xGiApgQEBpKcy7O67u2I
# WZ5U5nK+GWQt0iHSO8U2SEAOSkehuRCSxZsRCJ3J90tQkYYV/8870gPG6iX9j8mN
# C3iomyMhHgchHQNeBGgQ0dIvl8jDji52kSutuhdfqR7ABoUaEZfFX1Np1ZJEPfNZ
# X5O1Pe+ASZ20wP7Sxdg8GO9Hwqk+DZvVorShswR8CoQFt8GRqsnkgP7ce79ESHr2
# bt2XgfjDeWo7jRnbfKcWyNCBi4PVXqkY/drDNqxwGmWmilqq5D1I7ijYPGHQnVYR
# 5WoLZa1d8jSgswKeehqNQu9sz0eXdJQgnM6aMaoSQ20eFX4bXnPMPjOOBJAJccdA
# JR/WnvGiflzFNhd5GiUpE18Wb/EVH8MZCxVnIA==
# SIG # End signature block
