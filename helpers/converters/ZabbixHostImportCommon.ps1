$zabbixCommonDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$zabbixCommonRoot = Split-Path (Split-Path $zabbixCommonDir -Parent) -Parent
. (Join-Path $zabbixCommonDir 'ZabbixTemplateConversion.ps1')
. (Join-Path $zabbixCommonDir 'ZabbixWugImport.ps1')
. (Join-Path $zabbixCommonRoot 'functions\Connect-WUGServer.ps1')
. (Join-Path $zabbixCommonRoot 'functions\Get-WUGAPIResponse.ps1')
. (Join-Path $zabbixCommonRoot 'functions\Add-WUGDeviceTemplate.ps1')
. (Join-Path $zabbixCommonRoot 'functions\Add-WUGCredential.ps1')
. (Join-Path $zabbixCommonRoot 'helpers\discovery\DiscoveryHelpers.ps1')

function Invoke-ZabbixExampleRequest {
    param([string]$Method, [hashtable]$Parameters, [switch]$Anonymous)
    $request = @{ jsonrpc = '2.0'; method = $Method; params = $Parameters; id = 1 }
    $headers = @{}
    if (-not $Anonymous) {
        if ($zabbixVersion -ge [version]'6.4') { $headers['Authorization'] = "Bearer $apiToken" }
        else { $request['auth'] = $apiToken }
    }
    $response = Invoke-RestMethod -Uri $apiUri.AbsoluteUri -Method Post -Headers $headers `
        -ContentType 'application/json-rpc' -Body (ConvertTo-Json $request -Depth 20 -Compress) `
        -TimeoutSec 120 -MaximumRedirection 0 -ErrorAction Stop
    if ($response.error) {
        throw "Zabbix $Method failed (code $($response.error.code)). Check API permissions and server logs."
    }
    if (-not $response.PSObject.Properties['result']) { throw "Zabbix $Method returned no result." }
    return $response.result
}

function Invoke-WugExampleRequest {
    param([string]$Path, [string]$Method = 'GET', $Body)
    $arguments = @{
        Uri = "$($global:WhatsUpServerBaseURI)/api/v1/$Path"
        Method = $Method
        ErrorAction = 'Stop'
    }
    if ($Method -ne 'GET') {
        $arguments['Body'] = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
        $arguments['MaxRetries'] = 0
    }
    $response = Get-WUGAPIResponse @arguments
    if ($null -ne $response -and $response.PSObject.Properties['success']) {
        if ($response.success -ne $true) { throw "WUG $Method $Path reported failure." }
        return $response
    }
    if ($null -eq $response -or $null -eq $response.data -or
        ($response.data.PSObject.Properties['errors'] -and $response.data.errors)) {
        throw "WUG $Method $Path failed or returned unreadable data. Stop and inspect the server before retrying."
    }
    return $response
}

function Get-WugExamplePages {
    param([string]$Path, [string]$Collection)
    $pageId = ''
    $seen = @{}
    do {
        if ($seen.ContainsKey($pageId)) { throw 'WUG returned a repeated pagination ID.' }
        $seen[$pageId] = $true
        $pagePath = $Path
        if ($pageId) { $pagePath += '&pageId=' + [uri]::EscapeDataString($pageId) }
        $response = Invoke-WugExampleRequest -Path $pagePath
        if ($Collection) {
            if ($null -eq $response.data.$Collection) { throw "WUG omitted '$Collection'." }
            $response.data.$Collection
        }
        else { $response.data }
        $pageId = [string]$response.paging.nextPageId
    } while ($pageId)
}

function Get-ZabbixExampleCredentialSource {
    param($Details, [object[]]$HostMacros, [object[]]$Templates,
        [string[]]$FieldNames = @('community', 'securityname', 'contextname', 'authpassphrase', 'privpassphrase',
            'securitylevel', 'authprotocol', 'privprotocol'))
    $values = @{}
    foreach ($field in $FieldNames) {
        $text = [string]$Details.$field
        $seen = @{}
        for ($depth = 0; $text -match '\{\$[^}]+\}' -and $depth -lt 8; $depth++) {
            $reference = $Matches[0]
            if ($reference -notmatch '^\{\$[A-Za-z0-9_.]+\}$') { break }
            if ($seen.ContainsKey($reference)) { break }
            $seen[$reference] = $true
            $macros = @($HostMacros | Where-Object { $_.macro -ceq $reference })
            if ($macros.Count -eq 0) {
                $macros = @($Templates | ForEach-Object { $_.macros } | Where-Object { $_.macro -ceq $reference })
            }
            # Never guess precedence between different inherited values or resolve secret/vault macros.
            if ($macros.Count -eq 0 -or @($macros | Where-Object { [string]$_.type -ne '0' }).Count -gt 0) { break }
            $distinct = @($macros | Select-Object -ExpandProperty value -Unique)
            if ($distinct.Count -ne 1 -or [string]$distinct[0] -match '^\*+$') { break }
            $text = $text.Replace($reference, [string]$distinct[0])
        }
        if ($text -match '\{[^}]+\}' -or $text -match '^\*+$') { $text = '' }
        if ($text) { $values[$field] = ConvertTo-SecureString $text -AsPlainText -Force }
    }
    return ,$values
}

function Get-ZabbixExampleAdditionalCredentials {
    param($Plan, [object[]]$Items, [object[]]$HostMacros, [object[]]$Templates)
    foreach ($item in $Items) {
        if (-not $item.itemid -or [string]$item.type -ne '13') { throw 'Zabbix returned an invalid SSH item candidate.' }
        if ([string]$item.authtype -ne '0') {
            Write-Warning "SSH item $($item.itemid) uses key authentication. This wizard cannot translate key-file references into a WUG password credential; it will not substitute authentication methods."
            continue
        }
        $sourceKey = "$($Plan.Host)|ssh-item-$($item.itemid)"
        $credentialSources[$sourceKey] = Get-ZabbixExampleCredentialSource -Details $item `
            -HostMacros $HostMacros -Templates $Templates -FieldNames @('username', 'password', 'port')
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = 'ssh'; SourceKey = $sourceKey
            Label = "SSH item $($item.itemid)"; SourceNames = @("item $($item.itemid): username, password, port")
            Prefix = "$($Plan.Prefix)SSH item $($item.itemid) - "
        }
    }
    $allMacros = @($HostMacros) + @($Templates | ForEach-Object { $_.macros })
    foreach ($type in @('ssh', 'windows')) {
        $pattern = if ($type -eq 'ssh') { '^\{\$(SSH)[_.]' } else { '^\{\$(WINDOWS|WIN|WMI)[_.]' }
        $matching = @($allMacros | Where-Object {
            $_.macro -match $pattern -and $_.macro -match '^\{\$[A-Za-z0-9_.]+\}$'
        })
        if ($matching.Count -eq 0) { continue }
        $details = [ordered]@{}
        foreach ($field in @('username', 'password')) {
            $suffix = if ($field -eq 'username') { '[_.](USER|USERNAME|USER_NAME|LOGIN)\}$' } else { '[_.](PASSWORD|PASSWD|PASS)\}$' }
            $names = @($matching | Where-Object { $_.macro -match $suffix } | Select-Object -ExpandProperty macro -Unique)
            if ($names.Count -eq 1) { $details[$field] = $names[0] }
        }
        $sourceKey = "$($Plan.Host)|$type-macros"
        $credentialSources[$sourceKey] = Get-ZabbixExampleCredentialSource -Details ([PSCustomObject]$details) `
            -HostMacros $HostMacros -Templates $Templates -FieldNames @('username', 'password')
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = $type; SourceKey = $sourceKey
            Label = "$type macro candidate (confirm its purpose)"
            SourceNames = @($matching | Select-Object -ExpandProperty macro -Unique)
            Prefix = "$($Plan.Prefix)$type macros - "
        }
    }
}

function Read-WugExampleCredentialField {
    param([string]$Label, [System.Security.SecureString]$Suggested, [switch]$Optional)
    if ($Suggested -and $Suggested.Length -gt 0) {
        if ((Read-Host "Use available Zabbix/vault value for $Label (not displayed)? [Y/N]") -ieq 'Y') {
            return $Suggested.Copy()
        }
    }
    while ($true) {
        $value = Read-Host "$Label (masked input)" -AsSecureString
        if ($Optional -or $value.Length -gt 0) { return $value }
        $value.Dispose()
        Write-Warning "$Label is required."
    }
}

function New-WugExampleCredential {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Plan, [switch]$DeferCreation)
    $sourceKey = $Plan.Host
    if ($Plan.SourceKey) { $sourceKey = $Plan.SourceKey }
    $source = $credentialSources[$sourceKey]
    $suffix = if ($Plan.SourceKey) { '.Credential' } else { '.Snmp' }
    $vaultName = 'Zabbix.' + (Get-ZabbixDefinitionId "$($apiUri.AbsoluteUri)|$($global:WhatsUpServerBaseURI)|$sourceKey|$($Plan.CredentialType)") + $suffix
    Initialize-DiscoveryVault
    $saved = @{}
    if (@(Get-DiscoveryCredential -ErrorAction Stop | Where-Object { $_.Name -eq $vaultName }).Count -gt 0) {
        if ((Read-Host "Use encrypted vault defaults for $($Plan.Host)? [Y/N]") -ieq 'Y') {
            $saved = Get-DiscoveryCredential -Name $vaultName -AsSecureString -ErrorAction Stop
            if ($saved -isnot [hashtable]) { throw 'The credential vault entry is not a field bundle.' }
        }
    }
    $fields = @{}
    $arguments = @{}
    try {
        $defaultName = "$($Plan.Prefix)SNMP"
        if ($Plan.SourceKey) { $defaultName = "$($Plan.Prefix)credential" }
        $name = (Read-Host "New WUG credential name [$defaultName]").Trim()
        if (-not $name) { $name = $defaultName }
        $existing = @(Get-WugExamplePages -Path 'credentials/-?view=basic&type=all&limit=250' |
            Where-Object { $_.name -eq $name })
        if ($existing.Count -gt 0) { throw "WUG credential '$name' already exists. Select it from the list; it will not be overwritten." }
        $mapping = [ordered]@{}
        if ($Plan.CredentialType -in @('snmpV1', 'snmpV2')) {
            $mapping['SnmpReadCommunity'] = 'community'
        }
        elseif ($Plan.CredentialType -eq 'ssh') {
            $mapping['SshUsername'] = 'username'
            $mapping['SshPassword'] = 'password'
            $port = ''
            if ($source.ContainsKey('port')) { $port = [PSCredential]::new('value', $source.port).GetNetworkCredential().Password }
            if ($saved.ContainsKey('SshPort')) { $port = [PSCredential]::new('value', $saved.SshPort).GetNetworkCredential().Password }
            if (-not $port) { $port = '22' }
            $inputPort = Read-Host "Confirm WUG SSH port [$port]"
            if ($inputPort) { $port = $inputPort }
            $number = 0
            if (-not [int]::TryParse($port, [ref]$number) -or $number -lt 1 -or $number -gt 65535) { throw 'SSH port must be between 1 and 65535.' }
            $fields['SshPort'] = ConvertTo-SecureString $port -AsPlainText -Force
        }
        elseif ($Plan.CredentialType -eq 'windows') {
            Write-Warning 'Confirm WindowsUser is the intended DOMAIN\user or .\user. Zabbix agent monitoring does not imply Windows login credentials.'
            $mapping['WindowsUser'] = 'username'
            $mapping['WindowsPassword'] = 'password'
        }
        elseif ($Plan.CredentialType -in @('restapi', 'ado', 'aws', 'azure', 'redfish')) {
            $credentialMappings = @{
                restapi = [ordered]@{ RestApiUsername = 'username'; RestApiPassword = 'password' }
                ado = [ordered]@{ AdoUsername = 'username'; AdoPassword = 'password' }
                aws = [ordered]@{ AwsAccessKeyID = 'accesskey'; AwsSecureAccessKey = 'secretkey' }
                azure = [ordered]@{ AzureTenantID = 'tenantid'; AzureClientID = 'clientid'; AzureSecureKey = 'clientsecret' }
                redfish = [ordered]@{ RedfishUsername = 'username'; RedfishPassword = 'password' }
            }
            $mapping = $credentialMappings[$Plan.CredentialType]
            if ($Plan.CredentialType -eq 'restapi') {
                Write-Warning 'This credential creation path is HTTP Basic only. Bearer tokens, OAuth and custom headers need a separately configured WUG credential; no authentication downgrade is performed.'
                if ($Plan.AuthMode -and $Plan.AuthMode -ne 'Basic') { throw 'Select an existing WUG REST API credential for this authentication mode.' }
            }
            if ($Plan.CredentialType -eq 'ado') { Write-Warning 'ADO credentials do not translate a Zabbix ODBC DSN or SQL query into a WUG connection.' }
        }
        elseif ($Plan.CredentialType -eq 'snmpV3') {
            $level = ''
            if ($source.ContainsKey('securitylevel')) {
                $level = [PSCredential]::new('value', $source.securitylevel).GetNetworkCredential().Password
            }
            if (-not $level) { $level = Read-Host 'Zabbix SNMPv3 security level (0=noAuthNoPriv, 1=authNoPriv, 2=authPriv)' }
            if ($level -ne '2') {
                throw 'Automatic SNMPv3 creation currently supports authPriv only. Use U to configure other security levels in WUG and refresh; no security-level downgrade was applied.'
            }
            $mapping['SnmpV3Username'] = 'securityname'
            $mapping['SnmpV3Context'] = 'contextname'
            $mapping['SnmpV3AuthPassword'] = 'authpassphrase'
            $mapping['SnmpV3EncryptPassword'] = 'privpassphrase'
            foreach ($protocol in @(
                @{ Field = 'SnmpV3AuthProtocol'; Source = 'authprotocol'; Label = 'authentication (1=MD5, 3=SHA)'; Map = @{ '0' = '1'; '1' = '3' } }
                @{ Field = 'SnmpV3EncryptProtocol'; Source = 'privprotocol'; Label = 'privacy (1=DES, 3=AES128)'; Map = @{ '0' = '1'; '1' = '3' } }
            )) {
                $mapped = ''
                if ($source.ContainsKey($protocol.Source)) {
                    $zabbixProtocol = [PSCredential]::new('value', $source[$protocol.Source]).GetNetworkCredential().Password
                    if (-not $protocol.Map.ContainsKey($zabbixProtocol)) {
                        throw 'The source SNMPv3 protocol is not supported by this automatic mapping. Use U to configure it in WUG; no weaker protocol was substituted.'
                    }
                    $mapped = $protocol.Map[$zabbixProtocol]
                }
                if ($saved.ContainsKey($protocol.Field)) {
                    $mapped = [PSCredential]::new('value', $saved[$protocol.Field]).GetNetworkCredential().Password
                }
                $inputValue = Read-Host "WUG $($protocol.Label) [$mapped]"
                if ($inputValue) { $mapped = $inputValue }
                if ($mapped -notin @('1', '3')) { throw 'Select protocol 1 or 3; no default protocol will be guessed.' }
                $fields[$protocol.Field] = ConvertTo-SecureString $mapped -AsPlainText -Force
            }
        }
        else { throw "Unsupported credential type '$($Plan.CredentialType)'." }
        foreach ($field in $mapping.Keys) {
            $suggested = $source[$mapping[$field]]
            if ($saved.ContainsKey($field)) { $suggested = $saved[$field] }
            $value = Read-WugExampleCredentialField -Label $field -Suggested $suggested -Optional:($field -eq 'SnmpV3Context')
            if ($value.Length -eq 0) { $value.Dispose() }
            else { $fields[$field] = $value }
        }
        if ($DeferCreation) {
            $staged = [PSCustomObject]@{
                id = $null; name = $name; type = $Plan.CredentialType; VaultName = $vaultName
                Fields = $fields; Action = 'CreatePending'
            }
            $fields = @{}
            return $staged
        }
        Write-Warning "Credential '$name' will be saved in the encrypted discovery vault as '$vaultName' and created in WUG. Values have not been tested against the device."
        if ((Read-Host 'Type CREATE to save to the vault and create this WUG credential') -cne 'CREATE') {
            Write-Warning 'Credential creation cancelled; nothing was saved or created.'
            return
        }
        if (-not $PSCmdlet.ShouldProcess($name, 'Save encrypted vault bundle and create WUG credential')) { return }
        Save-DiscoveryCredential -Name $vaultName -Fields $fields -Description 'Zabbix credential import (not device-validated)' -Force -Confirm:$false -ErrorAction Stop | Out-Null
        $arguments = @{ Name = $name; Type = $Plan.CredentialType; Description = 'Zabbix credential import; verify live device authentication.' }
        foreach ($field in $fields.Keys) {
            $arguments[$field] = [PSCredential]::new('value', $fields[$field]).GetNetworkCredential().Password
        }
        $created = Add-WUGCredential @arguments -Confirm:$false -ErrorAction Stop
        if (-not $created.id -or $created.name -ne $name -or $created.type -ne $Plan.CredentialType) {
            throw 'WUG credential creation was not confirmed. The encrypted vault entry remains; inspect WUG before retrying.'
        }
        $confirmed = (Invoke-WugExampleRequest -Path ("credentials/" + [uri]::EscapeDataString([string]$created.id) + '?view=basic')).data
        if ($confirmed.id -ne $created.id -or $confirmed.name -ne $name -or $confirmed.type -ne $Plan.CredentialType) {
            throw 'WUG credential read-back failed. The credential and vault entry may exist; inspect WUG before retrying.'
        }
        return $confirmed
    }
    finally {
        $arguments.Clear()
        foreach ($value in $fields.Values) { $value.Dispose() }
        foreach ($value in $saved.Values) { if ($value -is [System.Security.SecureString]) { $value.Dispose() } }
    }
}

function Select-WugExampleCredential {
    param($Plan, [switch]$DeferCreation)
    :credentialSelection while ($true) {
        $credentials = @(Get-WugExamplePages -Path "credentials/-?view=basic&type=$($Plan.CredentialType)&limit=250" |
            Sort-Object name, id)
        $choices = @(
            for ($index = 0; $index -lt $credentials.Count; $index++) {
                $credential = $credentials[$index]
                if (-not $credential.id -or -not $credential.name -or $credential.type -ne $Plan.CredentialType) {
                    throw "WUG returned an invalid $($Plan.CredentialType) credential list."
                }
                [PSCustomObject]@{ Number = $index + 1; Name = $credential.name; Type = $credential.type; Id = $credential.id }
            }
        )
        if ($choices.Count -gt 0) { $choices | Format-Table -AutoSize | Out-Host }
        else { Write-Warning "No $($Plan.CredentialType) credentials exist in the connected WUG library." }
        $choice = (Read-Host "Credential for $($Plan.Host): number or ID, [C] Create with vault, [U] WUG UI, [R] Refresh, [Q] Cancel").Trim()
        switch ($choice.ToUpperInvariant()) {
            'Q' { return }
            'R' { continue credentialSelection }
            'C' {
                if ($Plan.AuthMode -eq 'ExistingOnly') {
                    Write-Warning 'This authentication type requires a deliberately configured existing WUG credential. Use U/R or select one; automatic Basic creation is blocked.'
                    continue credentialSelection
                }
                $created = New-WugExampleCredential -Plan $Plan -DeferCreation:$DeferCreation
                if ($created) { return $created }
                continue credentialSelection
            }
            'U' {
                Write-Warning "In the connected WUG server's web UI, open Settings > Libraries > Credentials and create a $($Plan.CredentialType) credential for '$($Plan.Host)'. UI labels may vary by WUG version."
                if ($Plan.CredentialType -in @('ssh', 'windows')) {
                    Write-Warning 'Confirm the intended account and authentication settings, then supply its actual secrets. SSH key authentication is not translated by this wizard.'
                }
                elseif ($Plan.CredentialType -in @('snmpV1', 'snmpV2', 'snmpV3')) {
                    Write-Warning 'For SNMPv1/v2, enter the device read community. For SNMPv3, match its security name, context, security level, authentication/privacy protocols and secrets.'
                }
                else {
                    Write-Warning "Configure the intended $($Plan.CredentialType) identity, authentication mode and required connection settings. A setting name alone does not prove its purpose."
                }
                Write-Warning 'Obtain missing secrets through your approved secure channel; the Zabbix API token is NOT a device credential.'
                [void](Read-Host 'Save the credential in WUG, then press Enter to refresh this list (or use Q at the next prompt to cancel)')
                continue credentialSelection
            }
        }
        $number = 0
        $selected = $null
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $credentials.Count) {
            $selected = $credentials[$number - 1]
        }
        else {
            $matches = @($credentials | Where-Object { $_.id -ceq $choice })
            if ($matches.Count -eq 1) { $selected = $matches[0] }
        }
        if (-not $selected) {
            Write-Warning 'Select a listed number or credential ID, or use C, U, R, or Q.'
            continue
        }
        $credential = (Invoke-WugExampleRequest -Path ("credentials/" + [uri]::EscapeDataString([string]$selected.id) + '?view=basic')).data
        if ($credential.type -ne $Plan.CredentialType -or $credential.id -ne $selected.id -or -not $credential.name) {
            throw 'The selected WUG credential changed or is no longer readable. Refresh and retry the import.'
        }
        return $credential
    }
}

function Find-WugExampleDevice {
    param($Plan)
    $matches = @{}
    foreach ($search in @($Plan.Host, $Plan.Name, $Plan.Address) | Select-Object -Unique) {
        $path = 'device-groups/-1/devices/-?view=card&limit=250&search=' + [uri]::EscapeDataString($search)
        foreach ($device in @(Get-WugExamplePages -Path $path -Collection 'devices')) {
            if ($device.hostName -eq $Plan.Host -or $device.name -eq $Plan.Name -or $device.displayName -eq $Plan.Name -or
                $device.networkAddress -eq $Plan.Address) {
                if (-not $device.id) { throw 'A matching WUG device has no ID.' }
                $matches[[string]$device.id] = $device
            }
        }
    }
    if ($matches.Count -gt 1) { throw "Multiple WUG devices match '$($Plan.Host)'; resolve them before importing." }
    foreach ($device in $matches.Values) {
        if ($device.networkAddress -ne $Plan.Address) {
            throw "WUG device '$($device.id)' matches '$($Plan.Host)' by name but has a different address; reconcile it before importing."
        }
        $device
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB0fwHowG9sFtR3
# T/wZ9xeAcRyRHfD0etvEIIqTe5RoGaCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAW
# cgXUVP8w3tjZG3npeN0obAWdJFS4JITpOS9QRrylczANBgkqhkiG9w0BAQEFAASC
# AgCn/F/KUxGBW6kCYdLtvuYuUL6eqgdslMvjt8pCfvXWI89PwcPWecFyARq0fofD
# 46NO3Fsb3u/z+BSZxgPVIIMNq4Btfe4dUK5NbFGOlAyeoFBCo5flc4rCUB/9y7Wf
# 4y9unIBBAluiUEs8kT7XxjkZV/jKL+xn8f+vHTNuPfJ6Ra54PvS9SVdo5H7ANCUT
# rBXianHKA9jkiiGNG6P+VyrACYbT7P+lt/dw82nZI6w/h9pPcyzBLgSz9y/WHMku
# r1n/JThDsJqGip6sssZdMlK8Wiqw3lyAsBQUnZsCD6c5YaGSlUKs7WsY6J1+v78Q
# 1wGQLZZ3QXPecZGNeAK8O0lXEiB9DvODBDcufz1Lik7u0qNmjMnYSOW/E6I/Sbkn
# jz+c2NFsHA0DXhv8x2ykZXzCwJPUyq9CwZqXivZyvOInhv3EhpARRGqfK4JY04Ab
# Y5Eo+Nk9gzgMBxMV28XQ7TGMj10iSEgC+s2dCqB0Nn1bEoZ9n18CiT7sHGIyuZYg
# nKtgn3tS7FwR4gYbQGg79Ff/513cJiGwpHvOQAFSxMrGXIgrWjjUrFVIrdeuFVY0
# rcrwaxWx3TbT5VFOBHi+E5fiQtgTI6oU3oTmcr31vrzG2sKxC7/rUdCjsyu/myEy
# Q9w8TMVg4V+Iqc749b+VeXJxzjvJh7x/UpglY7R4FduSYaGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MTJaMC8GCSqGSIb3DQEJBDEiBCDKV1tAFofC
# u8OZ/cN7dLX+RAPJLBWNhBVRUcFxpS0FWTANBgkqhkiG9w0BAQEFAASCAgAwQSOa
# GXJhhoWFtOVt9hm0ldUx4dtY+tTyMi9EO39s08w18deM25CjIJ1TO6mLn/5Ou2BA
# 873IBCLXWxh+rtXAatxxkogPVfRKVyTI+pi5YqGEbrmG2GoU5GB3zq/FVt+D0Nob
# RKgmUhMups4rf45Y+YurxTLuvSiFChDDSCn+DbJKyexatKSGQ60ARQFh/0aq5VKt
# mwnvJESLVIXigO5UzFTYnC75wiXtG7anehahQ/WLx3fksa2stX28LitRrFAwqdfL
# KPOACYY5XNleA0BprIqHlp1w0OOtcR/1onEAtxXke2TyE/rYPXeEzLWV/YByqW0H
# 0KjJxHIqEPxIQJMDidjsc6fnEuE3bjqfx/JNrbmwZ9vQJE+SlwbMuUIKjdMjrPGS
# +yK9eShqRbBHxJW40QSWEBmekGtMbmRa2oxbXBFIChkm1xttSJY9gpAl+bN1qx6L
# +3AAuOJ47hkSoHx4ADXf8qWQw/iUwFDFb7NfT9IXnVPnBi/cFHX54GUXZX1cw4js
# 3zaU+sE1zO6aEcLfAT5BE1wkQu+GmnYrQz6fWdqnyqsImVIyDXG9Lo0FeZ+5S8Fy
# +ulq0QKtFLKSLsFP2L/6oWwWcvc2vhZMrBYk5TBn4sncmkeplLIVLAtdBULmzk+X
# XOCJmPtlzBO4TSrjV/BJ1umUl0blF0KygWOnMQ==
# SIG # End signature block
