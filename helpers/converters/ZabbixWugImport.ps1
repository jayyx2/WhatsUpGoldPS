$importDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $importDir 'ZabbixConversionCommon.ps1')
. (Join-Path $importDir 'ZabbixSnmpMappings.ps1')
$apiHelper = Join-Path $importDir '..\..\functions\Get-WUGAPIResponse.ps1'
. $apiHelper

function Get-ZabbixMonitorFingerprint {
    param($Monitor)
    $info = $Monitor.monitorTypeInfo
    if (-not $info -or -not $info.classId -or -not $info.baseType) { throw 'A monitor template requires classId and baseType.' }
    $bags = New-ZabbixMap
    foreach ($bag in @($Monitor.propertyBags)) {
        if (-not $bag.name -or $bags.ContainsKey([string]$bag.name)) { throw 'A monitor template has an empty or duplicate property-bag name.' }
        $bags.Add([string]$bag.name, [string]$bag.value)
    }
    $orderedBags = @(
        foreach ($key in @($bags.Keys | Sort-Object -CaseSensitive)) { [ordered]@{ name = $key; value = $bags[$key] } }
    )
    $config = [ordered]@{ classId = ([string]$info.classId).ToLowerInvariant(); baseType = ([string]$info.baseType).ToLowerInvariant(); propertyBags = $orderedBags }
    if ($info.baseType -eq 'active') { $config['useInDiscovery'] = [bool]$Monitor.useInDiscovery }
    return Get-ZabbixDefinitionId (ConvertTo-Json -InputObject $config -Depth 20 -Compress)
}

function Get-WUGZabbixLibraryTemplates {
    $library = New-ZabbixMap
    $seenPages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pageId = ''
    do {
        if (-not $seenPages.Add($pageId)) { throw 'WUG monitor-template pagination repeated a page ID.' }
        $uri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-/config/template?type=all&replaceSensitiveData=true&includeDeviceMonitors=false&includeSystemMonitors=true&limit=250"
        if ($pageId) { $uri += '&pageId=' + [Uri]::EscapeDataString($pageId) }
        $response = Get-WUGAPIResponse -Uri $uri -Method GET -ErrorAction Stop
        if (-not $response.data) { throw 'WUG returned no monitor-template data; refusing to treat an unreadable library as empty.' }
        if ($response.data.errors) { throw "WUG library read failed: $($response.data.errors -join '; ')" }
        foreach ($baseType in @('active', 'performance', 'passive')) {
            $property = "${baseType}Monitors"
            foreach ($monitor in @($response.data.$property)) {
                if ($null -eq $monitor) { continue }
                if (-not $monitor.name -or -not $monitor.id) { throw 'WUG returned a monitor template without a name or library ID.' }
                $key = "$baseType|$(([string]$monitor.name).ToLowerInvariant())"
                if ($library.ContainsKey($key)) { throw "Multiple WUG library monitors have the same type/name '$key'; resolve the ambiguity before importing." }
                $library.Add($key, $monitor)
            }
        }
        $pageId = [string]$response.paging.nextPageId
    } while ($pageId)
    return ,$library
}

function Invoke-WUGZabbixProfileImport {
    <#
    .SYNOPSIS
        Creates ready converted SNMP monitors in the connected WUG monitor library.
    .DESCRIPTION
        Checks all requested names/configurations before writing, creates only missing
        templates in batches, validates IDs/results, and rereads the library to reconcile.
        Never updates existing monitors or assigns monitors to devices. WhatIf is offline.
    .PARAMETER Profiles
        Profile objects returned by the local Zabbix converter.
    .PARAMETER NamePrefix
        Optional prefix to avoid collisions with existing WUG monitor names.
    .PARAMETER IncludeMigrationAlternatives
        Allows the guided planner's explicitly reviewed Ping, TCP and REST API
        active templates. The default offline converter allowlist is unchanged.
    .EXAMPLE
        Invoke-WUGZabbixProfileImport -Profiles $profiles -WhatIf
    .NOTES
        Requires an existing Connect-WUGServer connection for real writes.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [string]$NamePrefix = '',
        [switch]$IncludeMigrationAlternatives
    )
    $allowed = @{
        'd6d02d69-a418-483a-93ea-20dd2af2d135' = 'active'
        'f14ef52e-b9da-4a2f-b48f-56c96a004cf2' = 'active'
        '2f300544-cba3-4341-9b05-2d1786f68e07' = 'performance'
        '805ebfde-caad-49d7-a81b-e26ba7725149' = 'passive'
    }
    if ($IncludeMigrationAlternatives) {
        $allowed['2655476e-36b0-455f-9cce-940b6f8e07bf'] = 'active'
        $allowed['1ee6ecd4-4c17-4ccc-8ff8-3147f445943f'] = 'active'
        $allowed['f0610672-d515-4268-bd21-ac5ebb1476ff'] = 'active'
    }
    $requested = New-ZabbixMap
    $payload = Get-ZabbixMonitorPayload $Profiles
    foreach ($group in $payload.Keys) {
        foreach ($source in $payload[$group]) {
            $monitor = ConvertTo-ZabbixData $source
            $classId = [string]$monitor.monitorTypeInfo.classId
            if (-not $allowed.ContainsKey($classId) -or $allowed[$classId] -cne $monitor.monitorTypeInfo.baseType -or
                -not $monitor.name -or $monitor['id'] -or $monitor['monitorId'] -or $monitor['ownedByDevice']) {
                throw 'Only converted new SNMP templates or explicitly enabled migration alternatives may be imported.'
            }
            $monitor['name'] = $NamePrefix + [string]$monitor.name
            $key = "$($monitor.monitorTypeInfo.baseType)|$(([string]$monitor.name).ToLowerInvariant())"
            $fingerprint = Get-ZabbixMonitorFingerprint $monitor
            $monitor['templateId'] = Get-ZabbixDefinitionId "$key|$fingerprint"
            if ($requested.ContainsKey($key)) {
                if ((Get-ZabbixMonitorFingerprint $requested[$key]) -cne $fingerprint) { throw "Conflicting converted configurations share the name '$($monitor.name)'." }
            }
            else { $requested.Add($key, $monitor) }
        }
    }
    if ($requested.Count -eq 0) { Write-Warning 'No ready monitor templates to import.'; return }
    $blocked = @($Profiles | ForEach-Object { $_.Definitions } | Where-Object { $_.Status -ne 'Ready' }).Count
    if ($blocked -gt 0) { Write-Warning "Importing ready templates only; $blocked other definition(s) remain excluded. Review the conversion report." }
    $results = [System.Collections.Generic.List[object]]::new()
    if ($WhatIfPreference) {
        foreach ($monitor in $requested.Values) {
            [void]$PSCmdlet.ShouldProcess($monitor.name, 'Create WUG library monitor (existing library not checked)')
            $results.Add([PSCustomObject]@{ Name = $monitor.name; BaseType = $monitor.monitorTypeInfo.baseType; MonitorId = $null; Action = 'PlannedUnverified' })
        }
        return $results.ToArray()
    }
    if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) { throw 'Connect-WUGServer must be called explicitly before importing monitor templates.' }
    $library = Get-WUGZabbixLibraryTemplates
    $missing = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $requested.Keys) {
        $monitor = $requested[$key]
        if ($library.ContainsKey($key)) {
            if ((Get-ZabbixMonitorFingerprint $library[$key]) -cne (Get-ZabbixMonitorFingerprint $monitor)) {
                throw "WUG monitor '$($monitor.name)' already exists with a different configuration. Nothing has been written; use NamePrefix or resolve the conflict."
            }
            $results.Add([PSCustomObject]@{ Name = $monitor.name; BaseType = $monitor.monitorTypeInfo.baseType; MonitorId = $library[$key].id; Action = 'Existing' })
        }
        else { $missing.Add($monitor) }
    }
    $created = New-ZabbixMap
    for ($offset = 0; $offset -lt $missing.Count; $offset += 50) {
        $batch = @($missing | Select-Object -Skip $offset -First 50)
        if (-not $PSCmdlet.ShouldProcess(($batch.name -join ', '), "Create $($batch.Count) WUG library monitor(s)")) { continue }
        $body = [ordered]@{ activeMonitors = @(); performanceMonitors = @(); passiveMonitors = @() }
        foreach ($monitor in $batch) { $body["$($monitor.monitorTypeInfo.baseType)Monitors"] += $monitor }
        $response = Get-WUGAPIResponse -Uri "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-/config/template" -Method PATCH `
            -Body (ConvertTo-Json -InputObject $body -Depth 20 -Compress) -MaxRetries 0 -ErrorAction Stop
        $data = $response.data
        if (-not $data -or $data.errors -or $data.successful -ne $batch.Count) {
            $messages = @($data.errors | ForEach-Object { "$($_.templateId): $($_.messages -join '; ')" }) -join '; '
            throw "WUG did not confirm the whole creation batch. Some monitors may have been created; no blind retry or rollback was attempted. $messages"
        }
        $ids = New-ZabbixMap
        foreach ($mapping in @($data.idMap)) {
            if (-not $mapping.templateId -or -not $mapping.resultId -or $ids.ContainsKey([string]$mapping.templateId)) { throw 'WUG returned an invalid creation idMap; reconcile the library before retrying.' }
            $ids.Add([string]$mapping.templateId, [string]$mapping.resultId)
        }
        if ($ids.Count -ne $batch.Count) { throw 'WUG creation idMap does not cover the full batch; reconcile before retrying.' }
        foreach ($monitor in $batch) {
            if (-not $ids.ContainsKey([string]$monitor.templateId)) { throw "Missing WUG result ID for '$($monitor.name)'." }
            $key = "$($monitor.monitorTypeInfo.baseType)|$(([string]$monitor.name).ToLowerInvariant())"
            $created.Add($key, $ids[[string]$monitor.templateId])
            $results.Add([PSCustomObject]@{ Name = $monitor.name; BaseType = $monitor.monitorTypeInfo.baseType; MonitorId = $ids[[string]$monitor.templateId]; Action = 'Created' })
        }
    }
    if ($created.Count -gt 0) {
        $confirmed = Get-WUGZabbixLibraryTemplates
        foreach ($key in $created.Keys) {
            if (-not $confirmed.ContainsKey($key) -or [string]$confirmed[$key].id -cne $created[$key] -or
                (Get-ZabbixMonitorFingerprint $confirmed[$key]) -cne (Get-ZabbixMonitorFingerprint $requested[$key])) {
                throw "WUG creation reconciliation failed for '$key'. Monitors may exist; no rollback was attempted."
            }
        }
    }
    return $results.ToArray()
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBfsGnoYMhwhBEk
# F9aUIBDp3B1kyM4nxSyTaD6IjuLlN6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCO
# xJZhaF5WEaPrRkbkM7BWg17j/U0gVWhgzsnQ+f7K6TANBgkqhkiG9w0BAQEFAASC
# AgAY/yU9BKgnWPiYpoJegHXT9xQCalPaS6gpRU28p0/Ev9vBqXR/b8SkPSWrqLMb
# S7+K4UhUfolrepOWQre4iS/4hYdpUvIgN04J/3GAjPKJHW5e7mMjcKipBQdueat9
# 2KME+zANE4mHUNmUGbkwWyfrfnAnaKANKZbIsB0sMQLTlrIfoONzENLYyrv+Enfk
# pWtgK9S3JvDZpwcxE7xJhtIvTP1Yi1cNv01+nIKt19i4uCc8gI0TsMKK6NC8e7ra
# RJFaGO9PFWyX4zUZfHcGSlhM+3kjYeohlK5Pj5tXFBVdBXKVojuPr/bS8Q9i+JVB
# B+0SCbYebEN6vCg655Q3RPHTAQWWc7JYb1IQZgdag+gTLJkMVjP3paolFIJu4cxG
# UDJyZDsdwFH5L+sRl02RCAgpjENTcHRfJj9HyYn2mYEC8ZDW5I9ejlSKSSZcoq8t
# GER96+O2Wqz69XJZ88kEj+RQYDbD4YRgTOAFodkfYfHQgVj0rA5Dg2mJ/NDVmYFG
# 28ywtqhM5E/LqnypCnNj39uUtRLaXM96PJ1lAKWgsrUQR0WfuPbIp3Wt90K7ViJC
# Ob55NQ224OHkT7FOgDKL2Oiy97BHTvg9qYJHx2SgRlhzI8N+F8WBvxqY1cePtCJQ
# jNF7qv2r59V6OSvTZCfyeMt+c6Re1jpuioQ2g5+dNh4DMqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MThaMC8GCSqGSIb3DQEJBDEiBCCVl+lduEaV
# swIew2oi6GMww/r1HMhto79YbUpLo5Z9JDANBgkqhkiG9w0BAQEFAASCAgCIZ7Ud
# VVueTBVu/KyRoS5c7GOvgPSnbosA6yrv0hXbsrZJ5ZfrTO0JNWJUiLwYCGIfYFpA
# 6xQg6bf+z7o0EXDbU133ZwrAZALzU3WxSIbC1dYBU1G1l6uukyDc2ZfnA95Et8rp
# zcMJlXttaUirEv5D3RHy03HoX6UVNdlbB1m0pOdM1SBeXXbiCV+PuJgd8QVcBGzr
# noDwW+jZlnegr3uaQPgkMNOLouWi96xRaHSF7LflIEd0aVWIGPYo5pRhHRdZP+J1
# chI/r7JnCutqHHl0EonUWBNHPSJ3G4oKIG621Wj9opMYySoaif0Cl8kvpw0xGlc0
# NJZ/iI4u1lt0VKEQa6yAMzCgTFdGTkLMeoL9gVTN9WAh1iToCZ6Ao4GaqRTBMM4A
# OkTosA12+OUKg0nrzujcZh3hmnapsSD6stiYmx17ya8ooiF5XmS3iAzPoxM6p/sx
# l1ObYSnL0zSMaQHLKqcHYzvOoGMawP3c8sqPYMQr882p+paxo5xzCPTOtmWTRJM0
# 05f1oaytso03ujnRa2W9/Rv0eKU/k1llBrCgZmBWI0cAsnsISqxAiwoXGcUSlS9F
# z/Mhr2R7DrPnmBudYsslJASF0uWuzmCVLP3+/+HDj/xO+ZXxNzbFFUvTLZm6oXsW
# FQFKnA2b23pqdXI4QKwk+XOuwjVadTLUC/mn0A==
# SIG # End signature block
