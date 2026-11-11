<#
.SYNOPSIS
    Guides Zabbix host discovery, credential review and migration into WUG.
.DESCRIPTION
    Selects host groups and hosts, reads effective items, triggers, interfaces,
    template macros, discovery rules and web scenarios. Reviews supported SNMP
    snapshots and explicit WUG-native alternatives. Stages vault-backed credential
    creation and approved device assignments until one final APPLY confirmation.
    Unsupported checks stay visible, with a reviewed existing-monitor replacement
    option. Saved redacted selections are re-discovered on resume.
.PARAMETER Legacy
    Runs the original exact-host-name, template-export SNMP example instead.
.PARAMETER PlanPath
    Resumes a redacted selection JSON file; source and credentials are read again.
.EXAMPLE
    .\examples\Import-ZabbixHostsToWUG.ps1 -WhatIf
.EXAMPLE
    .\examples\Import-ZabbixHostsToWUG.ps1
.NOTES
    Requires PowerShell 5.1 and Zabbix 6.0-7.4. Use trusted HTTPS certificates.
    The planner needs hostgroup.get, host.get, template.get, usermacro.get,
    item.get, trigger.get, discoveryrule.get and httptest.get access.
    The legacy path additionally uses configuration.export.
    WUG changes are not transactional; failures stop without rolling back.
.LINK
    https://www.zabbix.com/documentation/current/en/manual/api
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Legacy,
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$converter = Join-Path $repoRoot 'helpers\converters\Convert-ZabbixTemplateToWUG.ps1'
. (Join-Path $repoRoot 'helpers\converters\ZabbixMigrationPlanner.ps1')

if (-not $Legacy) {
    Invoke-ZabbixMigrationPlanner -PlanPath $PlanPath -WhatIf:$WhatIfPreference -Confirm:$false
    return
}

$apiUri = [uri](Read-Host 'Zabbix API URL (https://zabbix.example.com/api_jsonrpc.php)')
if (-not $apiUri.IsAbsoluteUri -or $apiUri.Scheme -ne 'https' -or $apiUri.UserInfo -or
    $apiUri.Query -or $apiUri.Fragment -or $apiUri.AbsolutePath -notlike '*/api_jsonrpc.php') {
    throw 'Enter the complete HTTPS api_jsonrpc.php URL without credentials, query, or fragment.'
}
$secureToken = Read-Host 'Zabbix API token' -AsSecureString
$tokenCredential = [PSCredential]::new('api-token', $secureToken)
$apiToken = $tokenCredential.GetNetworkCredential().Password
if (-not $apiToken) { throw 'A Zabbix API token is required.' }
$temporaryExport = $null
$credentialSources = @{}

try {
try {
    $zabbixVersion = [version](Invoke-ZabbixExampleRequest -Method 'apiinfo.version' -Parameters @{} -Anonymous)
    if ($zabbixVersion -lt [version]'6.0' -or $zabbixVersion -ge [version]'7.5') {
        throw "This example supports Zabbix 6.0-7.4, not $zabbixVersion."
    }
    $hostNames = @((Read-Host 'Exact Zabbix technical host names, separated by commas').Split(',') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($hostNames.Count -eq 0) { throw 'Select at least one host.' }
    $hosts = @(Invoke-ZabbixExampleRequest -Method 'host.get' -Parameters @{
        output = @('hostid', 'host', 'name', 'status')
        filter = @{ host = $hostNames }
        selectInterfaces = @('interfaceid', 'type', 'main', 'useip', 'ip', 'dns', 'port', 'details')
        selectParentTemplates = @('templateid', 'host')
        selectMacros = @('macro', 'value', 'type')
    })
    foreach ($name in $hostNames) {
        if (@($hosts | Where-Object { $_.host -ceq $name }).Count -ne 1) {
            throw "Host '$name' was not found uniquely, or is not accessible to this API token."
        }
    }

    $plans = [System.Collections.Generic.List[object]]::new()
    foreach ($zHost in $hosts) {
        if ([string]$zHost.status -ne '0') { throw "Host '$($zHost.host)' is disabled; it will not be enabled implicitly." }
        $interfaces = @($zHost.interfaces | Where-Object { $_.type -eq '2' -and $_.main -eq '1' })
        if ($interfaces.Count -ne 1) { throw "Host '$($zHost.host)' needs exactly one primary SNMP interface." }
        $interface = $interfaces[0]
        if ($interface.useip -ne '1') { throw "Host '$($zHost.host)' uses DNS polling; this example requires a literal IPv4 address." }
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$interface.ip, [ref]$ip) -or
            $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Host '$($zHost.host)' does not have a supported IPv4 SNMP address."
        }
        $port = 0
        if (-not [int]::TryParse([string]$interface.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw "Resolve the SNMP port for '$($zHost.host)' to a literal port first."
        }
        $credentialType = switch ([string]$interface.details.version) {
            '1' { 'snmpV1' } '2' { 'snmpV2' } '3' { 'snmpV3' }
            default { throw "Unsupported SNMP version on '$($zHost.host)'." }
        }
        $macroValues = @{}
        $credentialReferences = @(
            foreach ($property in $interface.details.PSObject.Properties) {
                foreach ($match in [regex]::Matches([string]$property.Value, '\{\$[^}]+\}')) { $match.Value }
            }
        )
        foreach ($macro in @($zHost.macros)) {
            if ($macro.macro -match '(?i)SECRET|PASSWORD|PASSWD|COMMUNITY|TOKEN|API.?KEY') { continue }
            if ($macro.macro -match '^\{\$(SSH|WINDOWS|WIN|WMI)[_.]') { continue }
            if ($macro.macro -cin $credentialReferences) {
                if ([string]$macro.type -ne '0') {
                    Write-Warning "A credential macro on '$($zHost.host)' cannot be read safely; supply its value during credential creation."
                }
                continue
            }
            if ([string]$macro.type -ne '0' -or $macro.macro -notmatch '^\{\$[A-Za-z0-9_.]+\}$') {
                throw "Host '$($zHost.host)' has a secret/vault or context macro that this example cannot safely apply."
            }
            $macroValues[$macro.macro] = [string]$macro.value
        }
        $roots = @($zHost.parentTemplates)
        if ($roots.Count -eq 0) { throw "Host '$($zHost.host)' has no linked templates." }
        $templates = @{}
        $pending = @($roots.templateid)
        for ($depth = 0; $pending.Count -gt 0; $depth++) {
            if ($depth -ge 32) { throw 'Template ancestry exceeds 32 levels.' }
            $batch = @(Invoke-ZabbixExampleRequest -Method 'template.get' -Parameters @{
                templateids = $pending
                output = @('templateid', 'host')
                selectParentTemplates = @('templateid', 'host')
                selectMacros = @('macro', 'value', 'type')
            })
            foreach ($id in $pending) {
                if (@($batch | Where-Object { $_.templateid -eq $id }).Count -ne 1) {
                    throw "Linked template ID '$id' is missing or inaccessible."
                }
            }
            foreach ($template in $batch) { $templates[[string]$template.templateid] = $template }
            $pending = @($batch | ForEach-Object { $_.parentTemplates } |
                Where-Object { -not $templates.ContainsKey([string]$_.templateid) } |
                Select-Object -ExpandProperty templateid -Unique)
        }
        $credentialSources[$zHost.host] = Get-ZabbixExampleCredentialSource -Details $interface.details -HostMacros @($zHost.macros) -Templates @($templates.Values)
        $exportJson = Invoke-ZabbixExampleRequest -Method 'configuration.export' -Parameters @{
            format = 'json'; options = @{ templates = @($templates.Keys) }
        }
        $temporaryExport = Join-Path ([System.IO.Path]::GetTempPath()) ("WUG-Zabbix-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [System.IO.File]::WriteAllText($temporaryExport, $exportJson, [System.Text.UTF8Encoding]::new($true))
            $profiles = @(
                foreach ($root in $roots) {
                    & $converter -Path $temporaryExport -TemplateName $root.host -MacroValues $macroValues
                }
            )
        }
        finally {
            if (Test-Path -LiteralPath $temporaryExport) { Remove-Item -LiteralPath $temporaryExport -Force -WhatIf:$false -Confirm:$false }
            $temporaryExport = $null
        }
        $candidates = @($profiles.Definitions | Where-Object { $_.Status -eq 'Ready' } |
            ForEach-Object { $_.Candidate })
        if ($candidates.Count -eq 0) { throw "No supported monitors for '$($zHost.host)'; no empty device will be created." }
        foreach ($group in @($candidates | Group-Object { "$($_.Template.monitorTypeInfo.baseType)|$($_.Name)" })) {
            $timings = @($group.Group | Select-Object PollingIntervalSeconds, PollingIntervalMinutes -Unique)
            if ($timings.Count -ne 1) { throw "Conflicting assignment intervals for '$($group.Name)'." }
        }
        $plans.Add([PSCustomObject]@{
            Host = $zHost.host; Name = $zHost.name; Address = $ip.ToString(); Port = $port
            CredentialType = $credentialType; CredentialId = $null; CredentialName = $null
            DeviceId = $null; Profiles = $profiles; Candidates = $candidates
            Prefix = "Zabbix $($apiUri.Authority) $($zHost.hostid) - "
            Excluded = @($profiles.Definitions | Where-Object { $_.Status -ne 'Ready' }).Count
            AdditionalCredentialCandidates = @()
            AdditionalCredentials = @()
        })
        $sshItems = @(Invoke-ZabbixExampleRequest -Method 'item.get' -Parameters @{
            hostids = @($zHost.hostid); filter = @{ type = '13'; status = '0' }
            output = @('itemid', 'type', 'authtype', 'username', 'password', 'port')
        })
        $plans[$plans.Count - 1].AdditionalCredentialCandidates = @(Get-ZabbixExampleAdditionalCredentials `
            -Plan $plans[$plans.Count - 1] -Items $sshItems -HostMacros @($zHost.macros) -Templates @($templates.Values))
    }
}
finally {
    $apiToken = $null
    $tokenCredential = $null
    if ($secureToken) { $secureToken.Dispose() }
    if ($temporaryExport -and (Test-Path -LiteralPath $temporaryExport)) {
        Remove-Item -LiteralPath $temporaryExport -Force -WhatIf:$false -Confirm:$false
    }
}

foreach ($property in @('Name', 'Address')) {
    if (@($plans | Group-Object -Property $property | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
        throw "Selected Zabbix hosts share a $property; resolve ambiguous WUG identities before importing."
    }
}
$plans | Select-Object Host, Address, CredentialType, @{n='Ready'; e={$_.Candidates.Count}}, Excluded |
    Format-Table -AutoSize | Out-Host
Write-Warning 'Only supported template definitions are copied. Host item overrides, global macros, discovered instances, history and alert actions are NOT migrated.'
foreach ($plan in $plans) {
    $plan.Profiles.Definitions | Where-Object { $_.Status -ne 'Ready' } |
        Select-Object @{n='Host'; e={$plan.Host}}, Name, Status, Reasons | Format-Table -Wrap | Out-Host
    $plan.AdditionalCredentialCandidates | Select-Object Host, CredentialType, Label, SourceNames |
        Format-Table -Wrap | Out-Host
}
if ($WhatIfPreference) {
    [void]$PSCmdlet.ShouldProcess(($plans.Host -join ', '), 'Import supported monitors, create/find devices, and assign credentials/monitors')
    $plans
    return
}
if ((Read-Host 'Review the preview. Type IMPORT to connect to WUG and continue') -cne 'IMPORT') {
    Write-Warning 'Import cancelled. No WUG connection or writes were made.'
    $plans
    return
}
Connect-WUGServer -ErrorAction Stop
if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) { throw 'WUG connection failed.' }

foreach ($plan in $plans) {
    $credential = Select-WugExampleCredential -Plan $plan
    if (-not $credential) {
        Write-Warning 'Import cancelled during credential selection. No library monitors, devices, or assignments were written by the wizard; credentials and vault entries already created remain.'
        return
    }
    $plan.CredentialId = $credential.id
    $plan.CredentialName = $credential.name
    $existing = Find-WugExampleDevice $plan
    if ($existing) {
        $plan.DeviceId = $existing.id
        Write-Warning "Reusing WUG device $($existing.id) for '$($plan.Host)'. Existing address, port and monitor settings will not be changed; verify these match the source."
    }
}

foreach ($plan in $plans) {
    foreach ($candidate in $plan.AdditionalCredentialCandidates) {
        Write-Warning "Credential candidate from Zabbix: $($candidate.Label). Setting names: $($candidate.SourceNames -join ', '). Values are not displayed. This does not convert SSH/Windows checks or assign the credential to the device."
        if ((Read-Host "Add the Zabbix $($candidate.Label) credential for $($plan.Host) to WUG? [Y/N]") -ine 'Y') { continue }
        $credential = Select-WugExampleCredential -Plan $candidate
        if ($credential) {
            $plan.AdditionalCredentials += [PSCustomObject]@{
                Name = $credential.name; Id = $credential.id; Type = $credential.type
            }
        }
        else { Write-Warning "Skipped optional $($candidate.CredentialType) credential." }
    }
}

if (-not $PSCmdlet.ShouldProcess(($plans.Host -join ', '), 'Create WUG library monitors and devices; assign SNMP credentials and monitors')) { return }

# Import and reconcile all libraries before any device writes.
$receipts = @{}
foreach ($plan in $plans) {
    $receipts[$plan.Host] = @(Invoke-WUGZabbixProfileImport -Profiles $plan.Profiles -NamePrefix $plan.Prefix -ErrorAction Stop)
}
foreach ($plan in $plans) {
    if (-not $plan.DeviceId) {
        $splat = @{
            displayName = $plan.Name; DeviceAddress = $plan.Address; Hostname = $plan.Host
            SNMPPort = $plan.Port; Brand = 'Zabbix'; NoDefaultActiveMonitor = $true
            Note = "Imported from Zabbix $($apiUri.Authority); host $($plan.Host). Supported templates only."
        }
        $splat["Credential$($plan.CredentialType)"] = $plan.CredentialName
        $created = Add-WUGDeviceTemplate @splat -ErrorAction Stop
        if ($created.errors -or $created.successful -ne 1 -or @($created.idMap).Count -ne 1 -or -not $created.idMap[0].resultId) {
            throw "Device creation for '$($plan.Host)' was not confirmed. Inspect WUG before retrying."
        }
        $plan.DeviceId = $created.idMap[0].resultId
    }
}
foreach ($plan in $plans) {
    $devicePath = 'devices/' + [uri]::EscapeDataString([string]$plan.DeviceId)
    $credentialResult = Invoke-WugExampleRequest -Path "$devicePath/credentials/-" -Method PUT -Body ([string]$plan.CredentialId)
    if ($credentialResult.success -ne $true) {
        throw "Credential assignment on device $($plan.DeviceId) was not confirmed."
    }
    $boundCredentials = (Invoke-WugExampleRequest -Path "$devicePath/credentials/-?view=basic&type=snmp").data
    if (@($boundCredentials | Where-Object { $_.id -eq $plan.CredentialId }).Count -ne 1) {
        throw "Credential read-back on device $($plan.DeviceId) did not match the selected credential."
    }
    $assigned = @{}
    foreach ($monitor in @(Get-WugExamplePages -Path "$devicePath/monitors/-?type=all&view=basic&limit=250")) {
        $assigned["$($monitor.type)|$($monitor.monitorTypeId)"] = $true
    }
    foreach ($receipt in $receipts[$plan.Host]) {
        $key = "$($receipt.BaseType)|$($receipt.MonitorId)"
        if ($assigned.ContainsKey($key)) { continue }
        $candidate = @($plan.Candidates | Where-Object {
            $plan.Prefix + $_.Name -ceq $receipt.Name -and $_.Template.monitorTypeInfo.baseType -eq $receipt.BaseType
        })[0]
        if (-not $candidate) { throw "No assignment configuration for '$($receipt.Name)'." }
        $body = @{
            type = $receipt.BaseType; monitorTypeId = [string]$receipt.MonitorId
            enabled = $true; isGlobal = $true
        }
        switch ($receipt.BaseType) {
            'active' { $body['active'] = @{ pollingIntervalSeconds = $candidate.PollingIntervalSeconds } }
            'performance' { $body['performance'] = @{ pollingIntervalMinutes = $candidate.PollingIntervalMinutes } }
            'passive' { $body['passive'] = @{} }
            default { throw "Unsupported monitor type '$($receipt.BaseType)'." }
        }
        $result = Invoke-WugExampleRequest -Path "$devicePath/monitors/-" -Method POST -Body $body
        if ($result.data.successful -ne 1) { throw "Monitor assignment '$($receipt.Name)' was not confirmed." }
        $assigned[$key] = $true
    }
    $confirmed = @{}
    foreach ($monitor in @(Get-WugExamplePages -Path "$devicePath/monitors/-?type=all&view=basic&limit=250")) {
        $confirmed["$($monitor.type)|$($monitor.monitorTypeId)"] = $true
    }
    foreach ($receipt in $receipts[$plan.Host]) {
        if (-not $confirmed.ContainsKey("$($receipt.BaseType)|$($receipt.MonitorId)")) {
            throw "Final monitor verification failed on '$($plan.Host)'. Inspect WUG before retrying."
        }
    }
    [PSCustomObject]@{
        Host = $plan.Host; DeviceId = $plan.DeviceId; Monitors = $receipts[$plan.Host].Count
        ExcludedDefinitions = $plan.Excluded; Result = 'AssignmentsVerified'
        AdditionalCredentials = $plan.AdditionalCredentials
    }
}
}
finally {
    foreach ($source in $credentialSources.Values) {
        foreach ($value in $source.Values) { $value.Dispose() }
    }
    $credentialSources.Clear()
    $hosts = $null
    $templates = $null
    $interface = $null
    $zHost = $null
    $sshItems = $null
    $item = $null
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCwSlAN/mYdGTNM
# D2sagSpbqMqOsUUTeQz9wurmSFA/36CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCA+
# cZmAs1ivRRnCt7JK636YXZ+cBs9HkfGmSEM4W23OcjANBgkqhkiG9w0BAQEFAASC
# AgCVldWrasGHILE4ylcaLCHokUo2tLuBiSef2h4/r2T0CDMmrBV6HsoN9aSMiPjW
# NQMgyH7Ra2vI/KiqdTVbD6TrpNbpEQjvq3lOSVF+NoC9hf8ESeSTb5JqtRmtDUTY
# WQ0vyeiJjXgqAXu0VvMureansCIJxko2dBxaafwe13vjrHX14m1mYpJ754bCYSYk
# JV5LoFZMGdofBfVwe8tLo6YEVhJIIVLt83DytbWhfISH++/76CgZxKOVVhmOvKhB
# B2WMWiXEQZtFuAE1XmKuyxrW7x+ESsDKdut86Jtw1GlmFUqSNCwzsqY7rC13NMda
# 1LCSQ2uQxmBOvYZBWfBKZAkbZYAy6+BRbl9F5Ck94fcuDUweAiyHDoAuo035JWQq
# f7kXyEck6JXL62mxfno3bcyRRlOVoF+1oHrStTYq3TDYImiWSYnKd65HaHojiRxv
# Um5kKJtFRq6rETEfDGK4czNJkscI29CCh8MohK1+gj2R3ynNrYSw/KKkA0nKBHjK
# zL1RjgBnxizpKLMERwK7+BYIn5ObCxsDhH5O2PGgNCAwVyh/HbAEpt8JAKodL+Vf
# BjC0lqhiF4gI8j9OmvWWH9BGZccvcPDPWZ3XjynUxugJVaUOOn3UbYgeyO5bs4V0
# 3GVZy/yHinPrqKDBDex7ROlvxw9B3xshkTYxu6ZYT/tgCKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MDlaMC8GCSqGSIb3DQEJBDEiBCDlie0qb1QI
# pYqPVmJbl+9otEKXVCU6ruLupysY1O6UyjANBgkqhkiG9w0BAQEFAASCAgAo7NFM
# ET4FuVdDN7SXBKCnT1NPExAbKuEm6r9AfIDoxOnoeUtH+e3lCE2zH+SgnzlGJ7Q2
# 7qdL48vVesHa6ozSmRt2VjIS9FOA9ac3EC8zxxias3YqIcoLfxC2ivNiZRRYQMZQ
# ewy/y3WbuWGIgxRpDIeo9eijRq+4MD+WNGbzrbel45Tn6Ze8JYdK5MvRcoJY9z4B
# 8hJlrSstvLDGMmkiFPGfoNlkwBPcDdREP0V0OczvfXv7AXoTo6121WvkOLqjjF1o
# Arx/grg84G2OM8Xla5NyfYilind91x0TFfJ933zonGrCHHeTOIcPTU2QuCR8obh6
# B6FsBz1zxh61N5a06ThsNaobztxUt4jNpacf2ZimbBLL5c+A1wWts32hi939SOD1
# R+wXEAr/s3RBLuTJ2xijg2Ms6dHVx0mEVVR4hX1n9MqJdTjiFtxpv2fnbxL7t+aC
# zI5XSQmPGaTRDN28TIn71qT2lxQSSWhRQGWJPuVbT3gJ0Nn+Nwag5DTpMMUOx16j
# lrHf2ZHoyGA5QbV0S0Itsbd61UsaH4JKqrsKcVMCUHi5hbby5zTmuyBoj8361yM1
# 2cPHU8+qlJpraPc37q+zLJfNdaloQtas0Dy1yqYg+/r5g8kVs1kgWYb7vwAVuh6N
# plqhbsjwoSVUGhXNmxe0RpA25zy7FTgOVTL4/w==
# SIG # End signature block
