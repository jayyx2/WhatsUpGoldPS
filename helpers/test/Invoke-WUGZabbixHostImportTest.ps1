<#
.SYNOPSIS
    Tests the interactive Zabbix host example without network calls or credentials.
.DESCRIPTION
    Runs the example body with synthetic API responses, prompts and WUG writes.
    Uses the real converter and the example's request/pagination functions.
.EXAMPLE
    .\helpers\test\Invoke-WUGZabbixHostImportTest.ps1
.NOTES
    Requires PowerShell 5.1. No external test dependencies.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..'
$example = Join-Path $root 'examples\Import-ZabbixHostsToWUG.ps1'
$converter = Join-Path $root 'helpers\converters\Convert-ZabbixTemplateToWUG.ps1'
. (Join-Path $root 'helpers\converters\ZabbixTemplateConversion.ps1')
. (Join-Path $root 'helpers\converters\ZabbixHostImportCommon.ps1')

# Load the legacy body without running the real connection bootstrap.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($example, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
$start = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('$apiUri =') })[0].Extent.StartOffset
$source = [System.IO.File]::ReadAllText($example)
$body = [scriptblock]::Create("[CmdletBinding(SupportsShouldProcess = `$true)]`nparam()`n" + $source.Substring($start))
$script:passed = 0

function Assert-Example {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($AsSecureString) {
        if ($Prompt -like 'SnmpV3Context*') { return [System.Security.SecureString]::new() }
        return ConvertTo-SecureString 'synthetic-token' -AsPlainText -Force
    }
    if ($Prompt -like 'Use available Zabbix/vault*' -or $Prompt -like 'Use encrypted vault defaults*') { return 'Y' }
    if ($Prompt -like 'New WUG credential name*') { return '' }
    if ($Prompt -like 'WUG authentication*' -or $Prompt -like 'WUG privacy*') { return '' }
    if ($Prompt -like 'Confirm WUG SSH port*') { return '' }
    if ($Prompt -like 'Add the Zabbix*') {
        $script:optionalPrompted = $true
        if ($script:mode -in @('AdditionalSSH', 'AdditionalSSHMissing', 'AdditionalWindows', 'AdditionalWindowsMissing',
                'AdditionalAmbiguous', 'AdditionalDuplicate', 'AdditionalCreateCancel', 'AdditionalExisting')) {
            $script:selectAdditional = $true
            return 'Y'
        }
        return 'N'
    }
    if ($Prompt -like 'Type CREATE*') {
        if ($script:mode -in @('CredentialCreateCancel', 'AdditionalCreateCancel')) { return 'CANCEL' }
        return 'CREATE'
    }
    if ($Prompt -like 'Zabbix API URL*') { return 'https://zabbix.invalid/api_jsonrpc.php' }
    if ($Prompt -like 'Exact Zabbix*') { return 'switch01' }
    if ($Prompt -like 'Review the preview*') { return $script:confirmation }
    if ($Prompt -like 'Credential for*') {
        if ($script:selectAdditional) {
            $script:selectAdditional = $false
            if ($script:mode -eq 'AdditionalExisting') { return '1' }
            if ($script:optionalCreationAttempted) { return 'Q' }
            $script:optionalCreationAttempted = $true
            return 'C'
        }
        if ($script:mode -eq 'AdditionalCreateCancel' -and $script:optionalCreationAttempted) { return 'Q' }
        if ($script:mode -eq 'CredentialCancel') { return 'Q' }
        if ($script:mode -in @('CredentialCreate', 'CredentialV3', 'CredentialV1', 'CredentialMacro',
                'CredentialMasked', 'CredentialSecretMacro', 'CredentialTemplateMacro', 'CredentialAmbiguousMacro',
                'CredentialMacroCycle', 'CredentialVault', 'CredentialVaultFailure', 'CredentialCreateFailure',
                'CredentialDuplicateName', 'CredentialUnsupportedProtocol', 'CredentialUnsupportedLevel',
                'CredentialCreateCancel') -and -not $script:credentialAttempted) {
            $script:credentialAttempted = $true
            return 'C'
        }
        if ($script:mode -eq 'CredentialUI' -and -not $script:credentialSaved) { return 'U' }
        if ($script:mode -eq 'CredentialRefresh' -and $script:credentialPrompts -eq 0) {
            $script:credentialPrompts++
            return 'R'
        }
        if ($script:mode -eq 'CredentialInvalid' -and $script:credentialPrompts -eq 0) {
            $script:credentialPrompts++
            return 'not-a-credential'
        }
        if ($script:mode -eq 'CredentialById') { return 'credential-1' }
        return '1'
    }
    if ($Prompt -like 'Save the credential in WUG*') {
        $script:credentialSaved = $true
        return ''
    }
    throw "Unexpected prompt '$Prompt'."
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $MaximumRedirection)
    $request = ConvertFrom-Json $Body
    $script:zabbixCalls.Add($request.method)
    if ($request.method -eq 'apiinfo.version') { return [PSCustomObject]@{ result = $script:version } }
    if ([version]$script:version -ge [version]'6.4') {
        Assert-Example ($Headers.Authorization -eq 'Bearer synthetic-token' -and -not $request.auth) 'Missing bearer authentication.'
    }
    else { Assert-Example ($request.auth -eq 'synthetic-token' -and -not $Headers.Authorization) 'Missing legacy token authentication.' }
    switch ($request.method) {
        'host.get' {
            if ($script:mode -eq 'ApiFailure') { return [PSCustomObject]@{ error = @{ code = -32602 } } }
            $details = [PSCustomObject]@{ version = '2'; community = 'zabbix-community' }
            if ($script:mode -eq 'CredentialV1') { $details.version = '1' }
            if ($script:mode -eq 'CredentialMacro') { $details.community = '{$COMMUNITY}' }
            if ($script:mode -eq 'CredentialSecretMacro') { $details.community = '{$SNMP_READ}' }
            if ($script:mode -in @('CredentialTemplateMacro', 'CredentialAmbiguousMacro', 'CredentialMacroCycle')) { $details.community = '{$SNMP_TEXT}' }
            if ($script:mode -eq 'CredentialMasked') { $details.community = '******' }
            if ($script:mode -in @('CredentialV3', 'CredentialUnsupportedProtocol', 'CredentialUnsupportedLevel')) {
                $details = [PSCustomObject]@{
                    version = '3'; securityname = 'snmp-user'; contextname = ''; securitylevel = '2'
                    authprotocol = '1'; privprotocol = '1'; authpassphrase = 'zabbix-auth'; privpassphrase = 'zabbix-privacy'
                }
                if ($script:mode -eq 'CredentialUnsupportedProtocol') { $details.authprotocol = '4' }
                if ($script:mode -eq 'CredentialUnsupportedLevel') { $details.securitylevel = '1' }
            }
            $script:snmpType = 'snmpV' + $details.version
            return [PSCustomObject]@{ result = @([PSCustomObject]@{
                hostid = '10'; host = 'switch01'; name = 'Switch 01'; status = '0'
                interfaces = @([PSCustomObject]@{
                    type = '2'; main = '1'; useip = '1'; ip = '192.0.2.10'; port = '1161'
                    details = $details
                })
                parentTemplates = @([PSCustomObject]@{ templateid = '100'; host = 'Child' })
                macros = @(
                    [PSCustomObject]@{ macro = '{$INTERVAL}'; value = '2m'; type = '0' }
                    [PSCustomObject]@{ macro = '{$COMMUNITY}'; value = 'macro-community'; type = '0' }
                    $(if ($script:mode -eq 'CredentialSecretMacro') {
                        [PSCustomObject]@{ macro = '{$SNMP_READ}'; value = '******'; type = '1' }
                    })
                    $(if ($script:mode -eq 'CredentialMacroCycle') {
                        [PSCustomObject]@{ macro = '{$SNMP_TEXT}'; value = '{$SNMP_TEXT}'; type = '0' }
                    })
                    $(if ($script:mode -in @('AdditionalWindows', 'AdditionalWindowsMissing', 'AdditionalSkip', 'AdditionalPreview', 'AdditionalAmbiguous')) {
                        [PSCustomObject]@{
                            macro = '{$WINDOWS.USER}'; value = 'DOMAIN\fixture-user'
                            type = $(if ($script:mode -eq 'AdditionalWindowsMissing') { '1' } else { '0' })
                        }
                        [PSCustomObject]@{
                            macro = '{$WINDOWS.PASSWORD}'; value = '******'; type = '1'
                        }
                        if ($script:mode -eq 'AdditionalAmbiguous') {
                            [PSCustomObject]@{ macro = '{$WINDOWS.LOGIN}'; value = 'other-user'; type = '0' }
                        }
                    })
                )
            }) }
        }
        'item.get' {
            if ($script:mode -eq 'AdditionalItemFailure') { return [PSCustomObject]@{ error = @{ code = -32602 } } }
            if ($script:mode -in @('AdditionalSSH', 'AdditionalSSHMissing', 'AdditionalSSHKey',
                    'AdditionalDuplicate', 'AdditionalCreateCancel', 'AdditionalExisting')) {
                return [PSCustomObject]@{ result = @([PSCustomObject]@{
                    itemid = '77'; type = '13'
                    authtype = $(if ($script:mode -eq 'AdditionalSSHKey') { '1' } else { '0' })
                    username = 'ssh-user'
                    password = $(if ($script:mode -eq 'AdditionalSSHMissing') { '******' } else { 'ssh-password' })
                    port = '2222'
                }) }
            }
            return [PSCustomObject]@{ result = @() }
        }
        'template.get' {
            $result = foreach ($id in $request.params.templateids) {
                if ($id -eq '100') {
                    [PSCustomObject]@{
                        templateid = '100'; host = 'Child'
                        parentTemplates = @([PSCustomObject]@{ templateid = '101'; host = 'Parent' })
                        macros = @([PSCustomObject]@{ macro = '{$SNMP_TEXT}'; value = 'template-community'; type = '0' })
                    }
                }
                elseif ($id -eq '101') {
                    [PSCustomObject]@{
                        templateid = '101'; host = 'Parent'; parentTemplates = @()
                        macros = @($(if ($script:mode -eq 'CredentialAmbiguousMacro') {
                            [PSCustomObject]@{ macro = '{$SNMP_TEXT}'; value = 'different-community'; type = '0' }
                        }))
                    }
                }
                else { throw "Unexpected template '$id'." }
            }
            return [PSCustomObject]@{ result = @($result) }
        }
        'configuration.export' {
            Assert-Example (@($request.params.options.templates).Count -eq 2) 'Ancestors were not exported.'
            $script:exportCount++
            return [PSCustomObject]@{ result = (@{ zabbix_export = @{
                version = $(if ($script:mode -eq 'ConversionFailure') { '99.0' } else { '6.0' })
                templates = @(
                    @{ template = 'Parent'; name = 'Parent'; items = @(@{
                        name = 'Temperature'; key = 'temperature'; type = 'SNMP_AGENT'
                        snmp_oid = '1.3.6.1.4.1.9.1.0'; value_type = 'UNSIGNED'; delay = '{$INTERVAL}'
                    }; @{ name = 'Trap'; key = 'snmptrap["linkDown"]'; type = 'SNMP_TRAP' }) }
                    @{ template = 'Child'; name = 'Child'; templates = @(@{ name = 'Parent' })
                        triggers = @(@{ name = 'Hot'; expression = 'last(/Child/temperature)>50' }) }
                )
            } } | ConvertTo-Json -Depth 20 -Compress) }
        }
        default { throw "Unexpected Zabbix method '$($request.method)'." }
    }
}

function Connect-WUGServer {
    [CmdletBinding()]
    param()
    $script:wugCalls.Add('Connect')
    $global:WUGBearerHeaders = @{ Authorization = 'synthetic' }
    $global:WhatsUpServerBaseURI = 'https://wug.invalid'
}

function Invoke-WUGZabbixProfileImport {
    [CmdletBinding()]
    param($Profiles, $NamePrefix)
    $script:wugCalls.Add('Library')
    foreach ($candidate in @($Profiles.Definitions | Where-Object { $_.Status -eq 'Ready' } | ForEach-Object { $_.Candidate })) {
        $type = $candidate.Template.monitorTypeInfo.baseType
        [PSCustomObject]@{ Name = $NamePrefix + $candidate.Name; BaseType = $type; MonitorId = "$type-1"; Action = 'Existing' }
    }
}

function Add-WUGDeviceTemplate {
    [CmdletBinding()]
    param($displayName, $DeviceAddress, $Hostname, $SNMPPort, $Brand, $NoDefaultActiveMonitor, $Note,
        $CredentialsnmpV2, $CredentialsnmpV1, $CredentialsnmpV3)
    $credentialName = @($CredentialsnmpV2, $CredentialsnmpV1, $CredentialsnmpV3 | Where-Object { $_ })[0]
    Assert-Example ($SNMPPort -eq 1161 -and $NoDefaultActiveMonitor -and $credentialName -eq $script:credentialName) 'Device settings were lost.'
    $script:wugCalls.Add('Device')
    $script:existingDevice = $true
    return [PSCustomObject]@{ successful = 1; idMap = @([PSCustomObject]@{ resultId = '42' }); errors = @() }
}

function Initialize-DiscoveryVault {}

function Get-DiscoveryCredential {
    [CmdletBinding()]
    param($Name, [switch]$AsSecureString)
    if ($script:mode -ne 'CredentialVault') { return }
    if (-not $Name) {
        [PSCustomObject]@{ Name = 'Zabbix.' + (Get-ZabbixDefinitionId 'https://zabbix.invalid/api_jsonrpc.php|https://wug.invalid|switch01|snmpV2') + '.Snmp' }
        return
    }
    Assert-Example $AsSecureString.IsPresent 'Vault read requested plaintext.'
    return @{ SnmpReadCommunity = (ConvertTo-SecureString 'vault-community' -AsPlainText -Force) }
}

function Save-DiscoveryCredential {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Name, $Fields, $Description, [switch]$Force)
    if ($script:mode -eq 'CredentialVaultFailure') { throw 'Synthetic vault write failed.' }
    foreach ($value in $Fields.Values) { Assert-Example ($value -is [System.Security.SecureString]) 'Vault field was not SecureString.' }
    $script:vaultWrites++
    $script:credentialSaved = $true
}

function Add-WUGCredential {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Name, $Type, $Description, $SnmpReadCommunity, $SnmpV3Username, $SnmpV3Context,
        $SnmpV3AuthPassword, $SnmpV3EncryptPassword, $SnmpV3AuthProtocol, $SnmpV3EncryptProtocol,
        $SshUsername, $SshPassword, $SshPort, $WindowsUser, $WindowsPassword)
    Assert-Example ($script:vaultWrites -eq 1) 'WUG credential creation occurred before vault save.'
    $script:credentialCreates++
    if ($script:mode -eq 'CredentialCreateFailure') { return [PSCustomObject]@{ errors = @('creation failed') } }
    if ($Type -in @('ssh', 'windows')) {
        if ($Type -eq 'ssh') {
            $expected = if ($script:mode -eq 'AdditionalSSHMissing') { 'synthetic-token' } else { 'ssh-password' }
            Assert-Example ($SshUsername -eq 'ssh-user' -and $SshPassword -eq $expected -and $SshPort -eq '2222') 'SSH source fields were not mapped.'
        }
        else {
            $expected = if ($script:mode -in @('AdditionalAmbiguous', 'AdditionalWindowsMissing')) { 'synthetic-token' } else { 'DOMAIN\fixture-user' }
            Assert-Example ($WindowsUser -eq $expected -and $WindowsPassword -eq 'synthetic-token') 'Windows fields did not use confirmed values or missing-secret input.'
        }
        $script:mockAdditional = [PSCustomObject]@{ id = 'credential-extra'; name = $Name; type = $Type }
        return $script:mockAdditional
    }
    elseif ($Type -eq 'snmpV3') {
        Assert-Example ($SnmpV3Username -eq 'snmp-user' -and $SnmpV3AuthPassword -eq 'zabbix-auth' -and
            $SnmpV3EncryptPassword -eq 'zabbix-privacy' -and $SnmpV3AuthProtocol -eq '3' -and
            $SnmpV3EncryptProtocol -eq '3') 'SNMPv3 mapping changed source credentials or protocol IDs.'
    }
    else {
        $expected = switch ($script:mode) {
            'CredentialMacro' { 'macro-community' }
            'CredentialMasked' { 'synthetic-token' }
            'CredentialSecretMacro' { 'synthetic-token' }
            'CredentialTemplateMacro' { 'template-community' }
            'CredentialAmbiguousMacro' { 'synthetic-token' }
            'CredentialMacroCycle' { 'synthetic-token' }
            'CredentialVault' { 'vault-community' }
            default { 'zabbix-community' }
        }
        Assert-Example ($SnmpReadCommunity -ceq $expected) 'SNMP community did not match confirmed source.'
    }
    $script:credentialName = $Name
    return [PSCustomObject]@{ id = 'credential-1'; name = $Name; type = $Type }
}

function Get-WUGAPIResponse {
    [CmdletBinding()]
    param($Uri, $Method, $Body, $MaxRetries)
    $script:wugCalls.Add("$Method $Uri")
    if ($Method -ne 'GET') { Assert-Example ($MaxRetries -eq 0) 'Blind mutation retries enabled.' }
    if ($Uri -match '/api/v1/credentials/-\?') {
        if ($Uri -match 'type=(ssh|windows)') {
            if ($script:mode -eq 'AdditionalExisting') {
                $script:mockAdditional = [PSCustomObject]@{ id = 'credential-extra'; name = 'Existing SSH'; type = 'ssh' }
                return [PSCustomObject]@{ data = @($script:mockAdditional); paging = @{ nextPageId = '' } }
            }
            return [PSCustomObject]@{ data = @(); paging = @{ nextPageId = '' } }
        }
        if ($script:mode -eq 'AdditionalDuplicate' -and $Uri -match 'type=all') {
            return [PSCustomObject]@{ data = @([PSCustomObject]@{
                id = 'duplicate'; name = 'Zabbix zabbix.invalid 10 - SSH item 77 - credential'; type = 'ssh'
            }); paging = @{ nextPageId = '' } }
        }
        if ($script:mode -eq 'CredentialReadFailure') { return [PSCustomObject]@{ data = $null } }
        if (($Uri -match 'type=all' -and $script:mode -ne 'CredentialDuplicateName') -or
            ($script:mode -in @('CredentialCreate', 'CredentialUI') -and -not $script:credentialSaved)) {
            return [PSCustomObject]@{ data = @(); paging = @{ nextPageId = '' } }
        }
        if ($script:mode -eq 'CredentialPaging' -and $Uri -notmatch 'pageId=') {
            return [PSCustomObject]@{ data = @(); paging = @{ nextPageId = 'creds&2' } }
        }
        if ($script:mode -eq 'CredentialPaging') {
            Assert-Example ($Uri -match 'pageId=creds%262') 'Credential pagination ID was not escaped.'
        }
        return [PSCustomObject]@{
            data = @([PSCustomObject]@{
                id = 'credential-1'; name = $script:credentialName
                type = $(if ($script:mode -eq 'CredentialWrongType') { 'snmpV3' } else { $script:snmpType })
            })
            paging = @{ nextPageId = '' }
        }
    }
    if ($Uri -match '/credentials/credential-extra\?') { return [PSCustomObject]@{ data = $script:mockAdditional } }
    if ($Uri -match '/credentials/credential-1\?') {
        if ($script:mode -eq 'CredentialChanged') {
            return [PSCustomObject]@{ data = [PSCustomObject]@{ id = 'credential-1'; name = 'SNMP credential'; type = 'snmpV3' } }
        }
        return [PSCustomObject]@{ data = [PSCustomObject]@{ id = 'credential-1'; name = $script:credentialName; type = $script:snmpType } }
    }
    if ($Uri -match '/device-groups/') {
        if ($script:readFailure) { return [PSCustomObject]@{ data = $null } }
        $devices = @()
        if ($script:existingDevice) { $devices = @([PSCustomObject]@{ id = '42'; name = 'Switch 01'; hostName = 'switch01'; networkAddress = '192.0.2.10' }) }
        if ($script:mode -eq 'AmbiguousDevice') {
            $devices = @(
                [PSCustomObject]@{ id = '42'; name = 'Switch 01'; hostName = 'switch01'; networkAddress = '192.0.2.10' }
                [PSCustomObject]@{ id = '43'; name = 'Switch 01'; hostName = 'switch01'; networkAddress = '192.0.2.10' }
            )
        }
        return [PSCustomObject]@{ data = [PSCustomObject]@{ devices = $devices }; paging = @{ nextPageId = '' } }
    }
    if ($Uri -match '/devices/42/credentials/-') {
        if ($Method -eq 'PUT') {
            Assert-Example ((ConvertFrom-Json $Body) -eq 'credential-1') 'Invalid credential body.'
            return [PSCustomObject]@{ success = $true }
        }
        return [PSCustomObject]@{ data = @([PSCustomObject]@{ id = 'credential-1' }) }
    }
    if ($Uri -match '/devices/42/monitors/-') {
        if ($Method -eq 'POST') {
            $assignment = ConvertFrom-Json $Body
            if ($assignment.type -eq 'active') { Assert-Example ($assignment.active.pollingIntervalSeconds -eq 120) 'Active timing not preserved.' }
            elseif ($assignment.type -eq 'performance') { Assert-Example ($assignment.performance.pollingIntervalMinutes -eq 2) 'Performance timing not preserved.' }
            elseif ($assignment.type -ne 'passive') { throw 'Unexpected assignment type.' }
            $script:assignments.Add($assignment)
            return [PSCustomObject]@{ data = @{ successful = 1 } }
        }
        if ($script:assignments.Count -gt 1 -and $Uri -notmatch 'pageId=') {
            return [PSCustomObject]@{ data = @($script:assignments[0]); paging = @{ nextPageId = 'page&2' } }
        }
        $data = @($script:assignments.ToArray())
        if ($Uri -match 'pageId=') {
            Assert-Example ($Uri -match 'pageId=page%262') 'Pagination ID was not escaped.'
            $data = @($script:assignments | Select-Object -Skip 1)
        }
        if ($script:mode -eq 'MissingAssignment') { $data = @() }
        return [PSCustomObject]@{ data = $data; paging = @{ nextPageId = '' } }
    }
    throw "Unexpected WUG request $Method $Uri."
}

$savedHeaders = $global:WUGBearerHeaders
$savedUri = $global:WhatsUpServerBaseURI
try {
    foreach ($case in @('Preview', 'Cancel', 'Create', 'Rerun', 'LegacyAuth', 'ReadFailure',
            'ConversionFailure', 'ApiFailure', 'AmbiguousDevice', 'MissingAssignment',
            'CredentialCreate', 'CredentialRefresh', 'CredentialInvalid', 'CredentialById',
            'CredentialPaging', 'CredentialCancel', 'CredentialReadFailure', 'CredentialWrongType', 'CredentialChanged',
            'CredentialV3', 'CredentialV1', 'CredentialMacro', 'CredentialMasked', 'CredentialSecretMacro',
            'CredentialTemplateMacro', 'CredentialAmbiguousMacro', 'CredentialMacroCycle', 'CredentialVault',
            'CredentialVaultFailure', 'CredentialCreateFailure', 'CredentialDuplicateName',
            'CredentialUnsupportedProtocol', 'CredentialUnsupportedLevel', 'CredentialCreateCancel', 'CredentialUI',
            'AdditionalSSH', 'AdditionalSSHMissing', 'AdditionalSSHKey', 'AdditionalWindows', 'AdditionalWindowsMissing',
            'AdditionalSkip', 'AdditionalPreview', 'AdditionalAmbiguous', 'AdditionalDuplicate',
            'AdditionalItemFailure', 'AdditionalCreateCancel', 'AdditionalExisting')) {
        $script:mode = $case
        $script:optionalPrompted = $false
        $script:selectAdditional = $false
        $script:optionalCreationAttempted = $false
        $script:mockAdditional = $null
        $script:credentialName = $(if ($case -eq 'CredentialDuplicateName') { 'Zabbix zabbix.invalid 10 - SNMP' } else { 'SNMP credential' })
        $script:snmpType = 'snmpV2'
        $script:credentialAttempted = $false
        $script:vaultWrites = 0
        $script:credentialCreates = 0
        $script:credentialSaved = $false
        $script:credentialPrompts = 0
        $script:wugCalls = [System.Collections.Generic.List[string]]::new()
        $script:zabbixCalls = [System.Collections.Generic.List[string]]::new()
        $script:confirmation = 'IMPORT'
        $script:version = '7.4.0'
        $script:readFailure = $case -eq 'ReadFailure'
        if ($case -ne 'Rerun') {
            $script:assignments = [System.Collections.Generic.List[object]]::new()
            $script:existingDevice = $false
        }
        if ($case -eq 'Cancel') { $script:confirmation = 'CANCEL' }
        if ($case -eq 'LegacyAuth') { $script:version = '6.0.0' }
        $before = @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'WUG-Zabbix-*.json' | Select-Object -ExpandProperty FullName)
        $caught = $null
        try { $result = @(& $body -WhatIf:($case -in @('Preview', 'AdditionalPreview')) -Confirm:$false) }
        catch { $caught = $_ }
        if ($case -in @('ReadFailure', 'ConversionFailure', 'ApiFailure', 'AmbiguousDevice', 'MissingAssignment',
                'CredentialReadFailure', 'CredentialWrongType', 'CredentialChanged', 'CredentialVaultFailure',
                'CredentialCreateFailure', 'CredentialDuplicateName', 'CredentialUnsupportedProtocol', 'CredentialUnsupportedLevel',
                'AdditionalDuplicate', 'AdditionalItemFailure')) {
            $pattern = switch ($case) {
                'ReadFailure' { 'unreadable' }
                'ConversionFailure' { 'Unsupported Zabbix export' }
                'ApiFailure' { 'Zabbix host.get failed' }
                'AmbiguousDevice' { 'Multiple WUG devices match' }
                'MissingAssignment' { 'Final monitor verification failed' }
                'CredentialReadFailure' { 'unreadable' }
                'CredentialWrongType' { 'invalid snmpV2 credential list' }
                'CredentialChanged' { 'selected WUG credential changed' }
                'CredentialVaultFailure' { 'Synthetic vault write failed' }
                'CredentialCreateFailure' { 'credential creation was not confirmed' }
                'CredentialDuplicateName' { 'already exists' }
                'CredentialUnsupportedProtocol' { 'source SNMPv3 protocol is not supported' }
                'CredentialUnsupportedLevel' { 'supports authPriv only' }
                'AdditionalDuplicate' { 'already exists' }
                'AdditionalItemFailure' { 'Zabbix item.get failed' }
            }
            Assert-Example ($null -ne $caught -and $caught.Exception.Message -match $pattern) "Expected failure '$pattern', got '$caught'."
        }
        if ($case -in @('ReadFailure', 'ConversionFailure', 'ApiFailure', 'AmbiguousDevice',
                'CredentialReadFailure', 'CredentialCancel', 'CredentialWrongType', 'CredentialChanged',
                'CredentialVaultFailure', 'CredentialCreateFailure', 'CredentialDuplicateName',
                'CredentialUnsupportedProtocol', 'CredentialUnsupportedLevel', 'AdditionalDuplicate', 'AdditionalItemFailure')) {
            if ($case -eq 'CredentialCancel' -and $caught) { throw $caught }
            Assert-Example (-not $script:wugCalls.Contains('Library') -and -not $script:wugCalls.Contains('Device')) 'Import wrote after a failed device precheck.'
            Assert-Example (@($script:wugCalls | Where-Object { $_ -match '^(PUT|POST|PATCH) ' }).Count -eq 0) 'Credential precheck/cancellation wrote an assignment.'
        }
        elseif ($case -ne 'MissingAssignment') {
            if ($caught) { throw $caught }
            if ($case -in @('Preview', 'Cancel', 'AdditionalPreview')) {
                Assert-Example ($script:wugCalls.Count -eq 0) 'Preview/cancellation touched WUG.'
                Assert-Example ($result[0].Candidates.Count -eq 3) 'Inherited ready definitions missing.'
            }
            else {
                Assert-Example ($result[-1].Result -eq 'AssignmentsVerified') 'Final assignment verification failed.'
                Assert-Example ($script:assignments.Count -eq 3) 'Assignments missing or duplicated on rerun.'
                if ($case -eq 'Rerun') { Assert-Example (-not $script:wugCalls.Contains('Device')) 'Rerun recreated the device.' }
                else { Assert-Example ($script:wugCalls.IndexOf('Library') -lt $script:wugCalls.IndexOf('Device')) 'Device created before library import.' }
            }
        }
        $leftovers = @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'WUG-Zabbix-*.json' |
            Where-Object { $_.FullName -notin $before })
        Assert-Example ($leftovers.Count -eq 0) 'Raw export was not cleaned up.'
        if ($case -in @('CredentialCreate', 'CredentialV3', 'CredentialV1', 'CredentialMacro', 'CredentialMasked', 'CredentialSecretMacro',
                'CredentialTemplateMacro', 'CredentialAmbiguousMacro', 'CredentialMacroCycle', 'CredentialVault')) {
            Assert-Example ($script:vaultWrites -eq 1 -and $script:credentialCreates -eq 1) 'Credential was not saved and created exactly once.'
        }
        if ($case -in @('Preview', 'Cancel', 'CredentialCancel', 'CredentialCreateCancel', 'CredentialVaultFailure',
                'CredentialDuplicateName', 'CredentialUnsupportedProtocol', 'CredentialUnsupportedLevel',
                'AdditionalSkip', 'AdditionalPreview', 'AdditionalDuplicate', 'AdditionalItemFailure', 'AdditionalCreateCancel',
                'AdditionalSSHKey', 'AdditionalExisting')) {
            Assert-Example ($script:vaultWrites -eq 0 -and $script:credentialCreates -eq 0) 'Unexpected credential or vault write.'
        }
        if ($case -in @('AdditionalSSH', 'AdditionalSSHMissing', 'AdditionalWindows', 'AdditionalWindowsMissing', 'AdditionalAmbiguous')) {
            Assert-Example ($script:vaultWrites -eq 1 -and $script:credentialCreates -eq 1) 'Optional credential was not saved and created once.'
            Assert-Example ($result[-1].AdditionalCredentials[0].Id -eq 'credential-extra') 'Optional credential was not reported.'
            Assert-Example (@($script:wugCalls | Where-Object { $_ -match '^PUT.*credential-extra' }).Count -eq 0) 'Optional credential was assigned without permission.'
        }
        if ($case -eq 'AdditionalPreview') {
            Assert-Example (-not $script:optionalPrompted -and $result[0].AdditionalCredentialCandidates.Count -eq 1) 'WhatIf omitted candidate metadata or prompted for optional credentials.'
        }
        if ($case -eq 'AdditionalExisting') {
            Assert-Example ($result[-1].AdditionalCredentials[0].Name -eq 'Existing SSH') 'Existing optional credential was not reused.'
        }
        if ($case -like 'Additional*' -and $null -eq $caught) {
            $json = ConvertTo-Json -InputObject $result -Depth 100 -Compress
            Assert-Example ($json -notmatch 'ssh-password|synthetic-token') 'A secret leaked into returned plans or completion summaries.'
        }
        $script:passed++
        Write-Output "PASS: $case"
    }
    & {
        $originalLocal = $env:LOCALAPPDATA
        $originalProgram = $env:ProgramData
        $tempVault = Join-Path ([System.IO.Path]::GetTempPath()) ('WUG-ZabbixVaultTest-' + [guid]::NewGuid().ToString('N'))
        $secrets = @{}
        $roundTrip = @{}
        try {
            # Keep both DPAPI scopes and audit/key files inside this isolated test tree.
            $env:LOCALAPPDATA = Join-Path $tempVault 'User'
            $env:ProgramData = Join-Path $tempVault 'Machine'
            . (Join-Path $root 'helpers\discovery\DiscoveryHelpers.ps1')
            . (Join-Path $root 'functions\Add-WUGCredential.ps1')
            Set-DiscoveryVaultPath -Path (Join-Path $tempVault 'Primary')
            foreach ($entry in @{
                SnmpV3Username = 'fixture-user'
                SnmpV3AuthPassword = 'fixture-auth'; SnmpV3EncryptPassword = 'fixture-privacy'
                SnmpV3AuthProtocol = '3'; SnmpV3EncryptProtocol = '3'
            }.GetEnumerator()) {
                $secure = [System.Security.SecureString]::new()
                foreach ($character in $entry.Value.ToCharArray()) { $secure.AppendChar($character) }
                $secrets[$entry.Key] = $secure
            }
            Save-DiscoveryCredential -Name 'Zabbix.fixture.Snmp' -Fields $secrets -Force -Confirm:$false -ErrorAction Stop | Out-Null
            $roundTrip = Get-DiscoveryCredential -Name 'Zabbix.fixture.Snmp' -AsSecureString -ErrorAction Stop
            Assert-Example ($roundTrip.Count -eq 5) 'Vault round-trip lost fields.'
            foreach ($field in $secrets.Keys) {
                Assert-Example ($roundTrip[$field] -is [System.Security.SecureString]) 'Real vault returned plaintext.'
                $expected = [PSCredential]::new('value', $secrets[$field]).GetNetworkCredential().Password
                $actual = [PSCredential]::new('value', $roundTrip[$field]).GetNetworkCredential().Password
                Assert-Example ($expected -ceq $actual) 'Real vault changed a credential field.'
            }
            function Get-WUGAPIResponse {
                [CmdletBinding()]
                param($Uri, $Method, $Body, [int]$MaxRetries)
                $request = ConvertFrom-Json $Body
                Assert-Example ($Method -eq 'POST') 'Real credential cmdlet used the wrong method.'
                Assert-Example ($PSBoundParameters.ContainsKey('MaxRetries') -and $MaxRetries -eq 0) 'Credential POST enabled blind retries.'
                $bags = @{}
                foreach ($bag in $request.propertyBags) { $bags[$bag.name] = $bag.value }
                switch ($request.type) {
                    'snmpV3' {
                        Assert-Example ($bags['CredSnmpV3:Username'] -eq 'fixture-user' -and
                            $bags['CredSnmpV3:AuthProtocol'] -eq '3' -and
                            $bags['CredSnmpV3:EncryptProtocol'] -eq '3' -and
                            $bags['CredSnmpV3:AuthPassword'] -eq 'fixture-auth' -and
                            $bags['CredSnmpV3:EncryptPassword'] -eq 'fixture-privacy' -and
                            $bags['CredSnmpV3:Context'] -eq '') 'Real credential cmdlet emitted incorrect SNMP property bags.'
                    }
                    'ssh' {
                        Assert-Example ($bags['CredSSH:Username'] -eq 'fixture-user' -and
                            $bags['CredSSH:Password'] -eq 'fixture-auth' -and
                            $bags['CredSSH:Port'] -eq '2222') 'Real credential cmdlet emitted incorrect SSH property bags.'
                    }
                    'windows' {
                        Assert-Example ($bags['CredWindows:DomainAndUserid'] -eq '.\fixture-user' -and
                            $bags['CredWindows:Password'] -eq 'fixture-auth') 'Real credential cmdlet emitted incorrect Windows property bags.'
                    }
                    default { throw 'Unexpected real credential type.' }
                }
                return [PSCustomObject]@{ data = [PSCustomObject]@{ id = 'fixture-id'; name = $request.name; type = $request.type } }
            }
            $arguments = @{ Name = 'fixture'; Type = 'snmpV3' }
            foreach ($field in $roundTrip.Keys) {
                $arguments[$field] = [PSCredential]::new('value', $roundTrip[$field]).GetNetworkCredential().Password
            }
            $created = Add-WUGCredential @arguments -Confirm:$false -ErrorAction Stop
            Assert-Example ($created.id -eq 'fixture-id') 'Real credential cmdlet did not return the credential ID.'
            $arguments.Clear()
            $created = Add-WUGCredential -Name 'fixture-ssh' -Type ssh -SshUsername 'fixture-user' `
                -SshPassword ([PSCredential]::new('value', $roundTrip.SnmpV3AuthPassword).GetNetworkCredential().Password) `
                -SshPort '2222' -Confirm:$false -ErrorAction Stop
            Assert-Example ($created.type -eq 'ssh' -and $created.id -eq 'fixture-id') 'Real SSH credential creation response was not recognized.'
            $created = Add-WUGCredential -Name 'fixture-windows' -Type windows -WindowsUser '.\fixture-user' `
                -WindowsPassword ([PSCredential]::new('value', $roundTrip.SnmpV3AuthPassword).GetNetworkCredential().Password) `
                -Confirm:$false -ErrorAction Stop
            Assert-Example ($created.type -eq 'windows' -and $created.id -eq 'fixture-id') 'Real Windows credential creation response was not recognized.'
        }
        finally {
            foreach ($value in $secrets.Values) { $value.Dispose() }
            foreach ($value in $roundTrip.Values) { $value.Dispose() }
            $env:LOCALAPPDATA = $originalLocal
            $env:ProgramData = $originalProgram
            if (Test-Path -LiteralPath $tempVault) { Remove-Item -LiteralPath $tempVault -Recurse -Force -Confirm:$false }
        }
    }
    $script:passed++
    Write-Output 'PASS: Real vault DPAPI round-trip and Add-WUGCredential property bags'
}
finally {
    $global:WUGBearerHeaders = $savedHeaders
    $global:WhatsUpServerBaseURI = $savedUri
}
Write-Output "Passed: $script:passed"

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA2i0mfwowfwzim
# NW5veZKc3jyfWTZAhZAd84ZVocO4N6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBR
# KSQDIMmcGkfpk236EuYRAqEhtL7m8JMZCW+rxWN4hDANBgkqhkiG9w0BAQEFAASC
# AgDOzHkv7Xg+7pD5xRKct/UO7rha84x0wogKE3Ys8G5mPMQamcWnQ+INvRmG7l/P
# +hgfZ3XeqRZj6qSusQV81Ay9vMGZFVUXjBiptDIGzCN1g7bvu6bfY11ITKWhqbjt
# GSe+rdpJxab57AYuW6Jd3qWGkn6aukulolRWp370pIQfZMpqLuEhxFxtS/xC9w7l
# Zj2h+I79zIb20v7SuxFv51ipHNUrGQbDRXv2dJHjP+80DTmqFMsax6Iyry9Shqys
# ZiWnXF3k3dNcURK5LrhJGT2sgEsDarUbPeQUKFix90rxGsSR8b7Fqg7YMlDxFZjf
# rmKykHjXYZwQJZ9B3BqEee8DPzSbFVyd/cpyf+8Rnj59cw7NhTASSOxQ5j4FEbP+
# fKvEJxfkDenDz9xJzVGC431xjpryafw6/rjnA+vQtZeNEzl0md74j5Bj3x3YNRwX
# KiQSOAnLLzsT73qwYQyOK3oXcOBOMtXcl98itBFeMcyMF6DpTng5sP1ziuwJvNf9
# tokzMfRj/ig7dvB0v484QRHP/Mpoey6CSelGajlB9Om6OiiNSNd7a3omrvZl9tor
# upQnnYfNYNOvYHdMYr2yojgIROw3Rx93DbMp8vue3RKDz1RD1j/te8Hf+4EKJo4M
# vMfmhLQNjawPq6/UvyAUJ4f6Yu1T/tP8OkSu46pGqNKXwqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MjBaMC8GCSqGSIb3DQEJBDEiBCDpOoKsrid/
# Jlb7etRf90DuFMlKlv3Cse1CyjriMOaN1zANBgkqhkiG9w0BAQEFAASCAgAsbUUb
# KVT9eOJWHWm4absTxb+Mv8antQQxfAsLExIjjhNv+rhPZF3ZUd76v5R+VU/IqSo0
# JlHEQHAPw/vEMiT6Klb+gsScX7cgn3EKGUlV7J+0/kBgKokogJi/X/T7dYo3t0jM
# GuwCNAPb5GhJBotm2prrz4zPPhZlpFecw+CKDVP9dVsqN76Tq3qPy7ax64o65S88
# SYb0TKrrx8iODAZCc5iJleuQsKCdr3O62DRNLIAgegv6ibR7So34GSzVjpBfx0G3
# 3hD0PiqptOJurG7vylzyW7SKmUX1ccRp24ik4GkWSSVr3mAw31ODFwnbpy1+6Gat
# yqF4nSjayJWsonkt2As7A+70PIwvKepl6V72/hG+1Zamq1kH1jotMHB/NUknrWUB
# s84jZmV6XKYOqQ8unqVsd7EJyf4zYclBxkSff2h1jgAdOCP6UVeuAfCODiOs1RmF
# rxxPFtlyhrPhdlhTYRKlo5Hsd+qMRYTxgpPe9znH+WA7WXU4DJru7EOkHNrRbMul
# wrEVI4F2dqUZRIhkwvGTlm/KLpvvqWFoP0V8QEAU3wFNiS5WE68JmoNwB8VkdSXd
# IvsqLNyprkRPVhmbkJFAESvXqDiFTTaIf3cvT3kRhbAMg1Xj4rRUbAi7DuP94df9
# P6BU7397QegTDG/0Q47gW++iU8TdiE3ZogZFIQ==
# SIG # End signature block
