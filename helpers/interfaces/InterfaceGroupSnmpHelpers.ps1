#requires -Version 5.1
. (Join-Path $PSScriptRoot 'InterfaceGroupingHelpers.ps1')
$snmpRoot = Join-Path $PSScriptRoot '..\snmp\WhatsUpGoldPS.Snmp'
foreach ($snmpDependency in @('Private\ConvertTo-SnmpCommonTypes.ps1', 'Private\Get-PreferredSharpSnmpTargetFramework.ps1',
        'Private\Get-SharpSnmpLibPackageLocal.ps1', 'Private\SNMPv3EngineCache.ps1',
        'Public\Import-SharpSnmpLib.ps1', 'Public\ConvertTo-SNMPv3AuthProtocol.ps1',
        'Public\ConvertTo-SNMPv3PrivProtocol.ps1', 'Public\Invoke-SNMPMessenger.ps1')) {
    . (Join-Path $snmpRoot $snmpDependency)
}

function Initialize-InterfaceGroupSnmp {
    [CmdletBinding()]
    param()
    $null = Import-SharpSnmpLib -ErrorAction Stop
}

function ConvertTo-InterfaceGroupSnmpCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('V1', 'V2', 'V3')][string]$Version,
        [Parameter(Mandatory)]$Stored
    )
    $authNames = @('None', 'MD5', 'SHA', 'SHA256', 'SHA384', 'SHA512')
    $privacyNames = @('None', 'DES', 'AES128', 'AES192', 'AES256')
        $parameters = @{ Version = $Version }
        if ($Version -ne 'V3') {
            $community = $null
            if ($stored -is [string]) { $community = $stored }
            elseif ($stored -is [hashtable]) { $community = $stored.Community }
            if ([string]::IsNullOrWhiteSpace([string]$community)) { throw "Selected SNMP credential '$name' has no Community field." }
            $parameters.Community = [string]$community
        }
        else {
            if ($stored -isnot [hashtable] -or -not $stored.Username) { throw "Selected SNMPv3 credential '$name' has no Username field." }
            $auth = [string]$stored.AuthProtocol
            $privacy = [string]$stored.PrivacyProtocol
            if ($auth -match '^[0-5]$') { $auth = $authNames[[int]$auth] }
            if ($privacy -match '^[0-4]$') { $privacy = $privacyNames[[int]$privacy] }
            if ($auth -notin @('None', 'NoAuth', 'MD5', 'SHA', 'SHA1', 'SHA96', 'SHA256', 'SHA224', 'SHA2', 'SHA384', 'SHA512') -or
                $privacy -notin @('None', 'NoPriv', 'DES', '3DES', 'TripleDES', 'AES', 'AES128', 'AES192', 'AES256')) {
                throw "Selected SNMPv3 credential '$name' has unsupported protocol fields."
            }
            if ($auth -notin @('None', 'NoAuth') -and -not $stored.AuthPassword) { throw "Selected SNMPv3 credential '$name' is missing its authentication password." }
            if ($privacy -notin @('None', 'NoPriv') -and ($auth -in @('None', 'NoAuth') -or -not $stored.PrivacyPassword)) {
                throw "Selected SNMPv3 credential '$name' needs authentication and a privacy password."
            }
            $parameters.Username = [string]$stored.Username
            $parameters.Context = [string]$stored.Context
            $parameters.AuthProtocol = $auth
            $parameters.AuthPassword = $stored.AuthPassword
            $parameters.PrivacyProtocol = $privacy
            $parameters.PrivacyPassword = $stored.PrivacyPassword
        }
        [pscustomobject]@{ Name = $name; Parameters = $parameters }
}

function Get-InterfaceGroupSnmpCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateCount(1, 12)][string[]]$Names,
        [Parameter(Mandatory)][ValidateSet('V1', 'V2', 'V3')][string[]]$Versions
    )
    if ($Names.Count -ne $Versions.Count) { throw 'SNMP credential names and versions must have the same count.' }
    . (Join-Path $PSScriptRoot '..\discovery\DiscoveryHelpers.ps1')
    Initialize-DiscoveryVault
    $seen = @{}
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $name = $Names[$i]
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Selected SNMP vault names must be simple names, not paths.' }
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'SNMP vault names cannot be blank.' }
        $identity = "$name/$($Versions[$i])"
        if ($seen.ContainsKey($identity)) { throw "Duplicate selected SNMP credential/version: $identity" }
        $seen[$identity] = $true
        $stored = Get-DiscoveryCredential -Name $name -ErrorAction Stop
        if (-not $stored) { throw "Selected SNMP vault credential '$name' is unavailable." }
        ConvertTo-InterfaceGroupSnmpCredential -Name $name -Version $Versions[$i] -Stored $stored
    }
}

function Invoke-InterfaceGroupSnmpWalk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Oid,
        [Parameter(Mandatory)][hashtable]$Credential,
        [int]$Port = 161, [int]$Timeout = 3000
    )
    $parameters = @{ Target = $Target; Table = $Oid; Version = $Credential.Version; Port = $Port; Timeout = $Timeout; ErrorAction = 'Stop' }
    if ($Credential.Version -eq 'V1') {
        $parameters.Community = $Credential.Community
        $result = Invoke-SNMPWalk @parameters
    }
    else {
        if ($Credential.Version -eq 'V3') {
            $auth = ConvertTo-SNMPv3AuthProtocol -Protocol $Credential.AuthProtocol -Password $Credential.AuthPassword
            if ($Credential.PrivacyProtocol -in @('None', 'NoPriv')) {
                $parameters.Privacy = [Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider]::new($auth)
            }
            else {
                $parameters.Privacy = ConvertTo-SNMPv3PrivProtocol -Protocol $Credential.PrivacyProtocol `
                    -Password $Credential.PrivacyPassword -AuthenticationProvider $auth
            }
            $parameters.Report = Get-SNMPv3CachedDiscovery -Target $Target -Port $Port -Timeout $Timeout
            $parameters.Community = $Credential.Username
            $parameters.ContextName = $Credential.Context
        }
        else { $parameters.Community = $Credential.Community }
        $parameters.MaxRepetitions = 10
        $result = Invoke-SNMPBulkWalk @parameters
    }
    foreach ($variable in $result.Variables) {
        $text = $variable.Data.ToString()
        if ($variable.Data.TypeCode.ToString() -eq 'OctetString') {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($variable.Data.GetRaw())
        }
        [pscustomobject]@{ OID = $variable.Id.ToString(); Value = $text; Type = $variable.Data.TypeCode.ToString() }
    }
}

function ConvertFrom-InterfaceGroupSnmpTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $columns = [ordered]@{ IfDescr = '1.3.6.1.2.1.2.2.1.2'; IfName = '1.3.6.1.2.1.31.1.1.1.1'; IfAlias = '1.3.6.1.2.1.31.1.1.1.18' }
    $ports = @{}
    foreach ($row in $Rows) {
        if ($row.Type -and $row.Type -ne 'OctetString') { throw 'Expected textual SNMP interface columns, not exception or numeric values.' }
        $oid = ([string]$row.OID).TrimStart('.')
        foreach ($column in $columns.Keys) {
            $prefix = "$($columns[$column])."
            if (-not $oid.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
            $index = $oid.Substring($prefix.Length)
            $numericIndex = 0
            if ($index -notmatch '^[1-9][0-9]*$' -or -not [int]::TryParse($index, [ref]$numericIndex)) { throw 'SNMP interface column has an invalid ifIndex suffix.' }
            if (-not $ports.ContainsKey($index)) { $ports[$index] = @{ IfIndex = $index; IfDescr = $null; IfName = $null; IfAlias = $null } }
            if ($null -ne $ports[$index][$column]) { throw "Duplicate SNMP interface column for ifIndex $index." }
            $ports[$index][$column] = [string]$row.Value
            break
        }
    }
    foreach ($index in @($ports.Keys | Sort-Object { [long]$_ })) { [pscustomobject]$ports[$index] }
}

function Add-InterfaceGroupSnmpInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][int[]]$DeviceId,
        [Parameter(Mandatory)][object[]]$Credentials,
        [switch]$IncludeSnmpOnly,
        [ValidateSet('Warn', 'Stop')][string]$FailureAction = 'Warn',
        [ValidateRange(1, 65535)][int]$Port = 161,
        [ValidateRange(500, 60000)][int]$Timeout = 3000,
        [hashtable]$Coverage,
        [string]$CancellationPath,
        [hashtable]$DeviceMetadata
    )
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Inventory) { $all.Add($row) }
    $devices = @($DeviceId | Select-Object -Unique)
    $completed = 0
    try {
    foreach ($id in $devices) {
        Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
        Write-Progress -Id 6201 -Activity 'Reading SNMP interface metadata' -Status "Device $id ($($completed + 1)/$($devices.Count))" -PercentComplete ([int](100 * $completed / $devices.Count))
        $deviceRows = @($Inventory | Where-Object DeviceId -eq $id)
        if ($DeviceMetadata -and $DeviceMetadata.ContainsKey([string]$id)) {$device=@($DeviceMetadata[[string]$id])}
        else {$device = @(Get-WUGDevice -DeviceId $id -View basic -ErrorAction Stop)}
        if ($device.Count -ne 1) { throw "Expected one device for SNMP target $id." }
        $ip = $null
        $target = [string]$device[0].networkAddress
        $status = 'Failed'
        $selected = $null
        $ports = @()
        if ([Net.IPAddress]::TryParse($target, [ref]$ip)) {
            foreach ($credential in $Credentials) {
                Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
                try {
                    $raw = @(Invoke-InterfaceGroupSnmpWalk -Target $target -Oid '1.3.6.1.2.1.2.2.1.2' -Credential $credential.Parameters -Port $Port -Timeout $Timeout)
                    $ports = @(ConvertFrom-InterfaceGroupSnmpTable -Rows $raw)
                    if ($ports.Count -eq 0) { throw 'No ifDescr rows returned.' }
                }
                catch {
                    Write-Warning "Device $id SNMP attempt '$($credential.Name)' ($($credential.Parameters.Version)) failed; trying the next selected entry. Error type: $($_.Exception.GetType().Name)."
                    continue
                }
                $selected = $credential.Name
                $status = 'Complete'
                foreach ($oid in @('1.3.6.1.2.1.31.1.1.1.1', '1.3.6.1.2.1.31.1.1.1.18')) {
                    Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
                    try {
                        $extra = @(Invoke-InterfaceGroupSnmpWalk -Target $target -Oid $oid -Credential $credential.Parameters -Port $Port -Timeout $Timeout)
                        $null = ConvertFrom-InterfaceGroupSnmpTable -Rows @($raw + $extra)
                        if ($extra.Count -eq 0) { $status = 'Partial'; Write-Warning "Device $id returned no metadata for SNMP column $oid." }
                        $raw += $extra
                    }
                    catch {
                        $status = 'Partial'
                        Write-Warning "Device $id could read ifDescr but SNMP column $oid failed. Error type: $($_.Exception.GetType().Name)."
                    }
                }
                $ports = @(ConvertFrom-InterfaceGroupSnmpTable -Rows $raw)
                if (@($ports | Where-Object { $null -eq $_.IfDescr -or $null -eq $_.IfName -or $null -eq $_.IfAlias }).Count -gt 0) {
                    $status = 'Partial'
                    Write-Warning "Device $id has incomplete per-interface IF-MIB metadata; grouping uses available fields plus stored WUG descriptions."
                }
                break
            }
        }
        else { Write-Warning "Device $id has no valid IP networkAddress; SNMP enrichment was not attempted." }
        if ($status -ne 'Complete' -and $FailureAction -eq 'Stop') { throw "SNMP enrichment for device $id was $status. No output generated." }
        if ($status -eq 'Failed') { Write-Warning "All selected SNMP entries failed or no usable IP for device $id. Retaining WUG descriptions with SnmpStatus=Failed." }
        $map = @{}
        foreach ($snmpInterface in $ports) { $map[$snmpInterface.IfIndex] = $snmpInterface }
        if ($null -ne $Coverage) { $Coverage[[string]$id] = $status }
        $matched = @{}
        foreach ($row in $deviceRows) {
            $metadata = $null
            if ($row.IfIndex -and $map.ContainsKey([string]$row.IfIndex)) { $metadata = $map[[string]$row.IfIndex]; $matched[[string]$row.IfIndex] = $true }
            $rowStatus = $status
            if ($status -ne 'Failed' -and -not $metadata) { $rowStatus = 'NotFound' }
            foreach ($field in @('IfAlias', 'IfName', 'IfDescr')) {
                $row | Add-Member -NotePropertyName $field -NotePropertyValue $(if ($metadata) { $metadata.$field } else { $null }) -Force
            }
            $row | Add-Member -NotePropertyName SnmpStatus -NotePropertyValue $rowStatus -Force
            $row | Add-Member -NotePropertyName SnmpCredentialName -NotePropertyValue $selected -Force
            $row | Add-Member -NotePropertyName InventorySource -NotePropertyValue 'WUG' -Force
        }
        if ($IncludeSnmpOnly) {
            foreach ($snmpInterface in $ports) {
                if ($matched.ContainsKey([string]$snmpInterface.IfIndex)) { continue }
                $all.Add([pscustomobject]@{
                    DeviceId = $id; DeviceName = $device[0].displayName; IfIndex = $snmpInterface.IfIndex
                    InterfaceComment = ''; InterfaceName = ''; IfAlias = $snmpInterface.IfAlias; IfName = $snmpInterface.IfName; IfDescr = $snmpInterface.IfDescr
                    Status = 'Unmonitored'; StatusDetail = 'SNMP metadata only; no joined WUG interface assignment or traffic history.'
                    ActiveAssignmentIds = @(); PerformanceAssignmentIds = @(); PerformanceEnabled = $false
                    TrafficInterfaceIds = @(); TrafficAvailable = $false; RxBps = $null; TxBps = $null
                    RxPercent = $null; TxPercent = $null; PollTimeUtc = $null; SecondsSincePoll = $null; Samples = @()
                    SnmpStatus = $status; SnmpCredentialName = $selected; InventorySource = 'SNMP-only'
                })
            }
        }
        $completed++
    }
    }
    finally { Write-Progress -Id 6201 -Activity 'Reading SNMP interface metadata' -Completed }
    @($all)
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCzC3o1Xngw8G1p
# RM7S9RiYAULVaW1rwohVQh4ZYNzTMaCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBm
# MmPyItu7RQ2cNwvNZIiE2JUkKgXNC64RqaKzBglz/TANBgkqhkiG9w0BAQEFAASC
# AgBDamHvMVR3yKjOXVFujKKrcfe7B5dc8Vb5qCJgsKHIKPXD6s3FDH3EPTLjcdh4
# tuDdXmhFy8q3eKg8D3hFrVZuH8P13/U4OJwEmxC2Qx1gQG89ip7JUIvj+NPPtDxn
# H/kAmYxfYyhkmM0og9pB8Ew2n1IOw4zlWTvN8gDvtygo59oimzOGYTa18ij3IBBg
# JWSqLW5jlo+vjZIEGd0F6g0pylw8v/T5axq8erN3jCU69x3NAvvrFk5pyl18mulb
# qhrzPYn8AcqYIuIkUKqh2p1CEUdZOmxYB6lZLnLZfyYuFQNuEke2gyLPYUQeZd7L
# 60ExdLqYpPwe6nJUqnfNCYnQeWM5RjWYAE/Aq5N/C6D5IeFlWUcc2do7QHLQi3uR
# O//kISR7uCVN3bIl/9AR7GnB+Tn4riOt+Bi3CMxFLa7YjnKEg8+u7An1AwtB+BGR
# BV+YWNAkKEox8dh99DCy11HAyka3QlwEo8GFLYIXixNdz/e7LOWl9Lu6f2vwERf0
# RvL+aRC94lFb91ZYwB2V/80rarsjx3tx6WDPgrpJYjqT7odkCEtJBOSB49i1uU8Z
# dxtc2Kfv50v7gguMzm0cqWT4Qwgeo8WtjZTp16nROk12jp+WqmKK6LJYiVZJBmNA
# qUx7a6oZsyx/OI2VpqRNAM0PYlGlVH4w0j1sTTLdCdx/j6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzMzVaMC8GCSqGSIb3DQEJBDEiBCAOMgDJKk8B
# uX9VfkCAey31gBUk9xB5xFO2NINJRTpwCzANBgkqhkiG9w0BAQEFAASCAgAAtkY4
# 0iL8vNWwxS4cHA2HQIIBszy1W5l/vyoKmzXW1aWpAwi/qm50KlsJUQUpGnGXc6ij
# 4VgZPbpF3R1vbR4tWJSKY9wyp+spOzDCNA8OTH8Sk2LsMcqJgfvFbwkTBJFCGeqD
# MldUKJIMWY08ATgl6flT24YwwFF3h0rDFrHgFgkbFh5qY3jR1ihzQJ77j7PAS1I3
# Tt/u62hOlPcIOAhmm09UV0hQTHvA6ZktXlHxlobGKczHUYOmZKYx4hj7FKbzhwrw
# rgKObwTEbZApUD7lKnLByJb9zu2U9ZXJ/FPwKoI9WTiVRLXEHxoLehBSsiOjQnBR
# GizF7QITr2aCG5x4luQMAYjmRr8MKjZQpLNRwa8XKspVg/Z6O6vPLqnX8L6jsthT
# HVv+vDU55zdqo5q+zsTTfpfnsjfAVVrrrIC4IEjTNg1Wc+Dh++pUvysFg8sadiDY
# 3CZX6RikPOtJDcOXuvloNsfhzk6C27fHto34PXnFTrPGDkK6Z2JsfETDni+vzSop
# 8pKkXLPj7E+JAkcLtzBa/octtPM07VodFtlnBNeKIqxKx4obV5Vo2TthE8BD2p4Y
# nt+xTs3k2QPOowsoxkPJPqvIH4Lt65hJw27OoFrk/ibBDnvS2XUCLVUIFiHOP4b0
# YHSIUlF1aPg72+AphITvXIQ7nZQ/dEufj69kzg==
# SIG # End signature block
