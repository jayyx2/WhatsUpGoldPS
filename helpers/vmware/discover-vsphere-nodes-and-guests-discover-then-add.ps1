# Configuration
$vCenterServer = "192.168.23.60"

# Check if the WhatsUpGoldPS module is loaded, and if not, import it
if (-not (Get-Module -Name WhatsUpGoldPS)) {Import-Module WhatsUpGoldPS}
# Check if the VMware modules are loaded, and if not, import it
if (-not (Get-Module -Name VMware.Vim)) {Import-Module VMware.Vim}
if (-not (Get-Module -Name VMware.VimAutomation.Cis.Core)) {Import-Module VMware.VimAutomation.Cis.Core}
if (-not (Get-Module -Name VMware.VimAutomation.Common)) {Import-Module VMware.VimAutomation.Common}
if (-not (Get-Module -Name VMware.VimAutomation.Core)) {Import-Module VMware.VimAutomation.Core}
if (-not (Get-Module -Name VMware.VimAutomation.Sdk)) {Import-Module VMware.VimAutomation.Sdk}

# Load vault functions for credential resolution
$discoveryHelpersPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) { . $discoveryHelpersPath }

# Resolve credentials from vault
if (!$VMwareCred) { $VMwareCred = Resolve-DiscoveryCredential -Name "VMware.$vCenterServer.Credential" -CredType PSCredential -ProviderLabel 'VMware vCenter' -AutoUse }
if (!$VMwareCred) { throw "VMware credentials are required. Store them in the vault first." }
$WUGCred = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -ProviderLabel 'WhatsUp Gold' -AutoUse
if (-not $WUGCred) { throw "WhatsUp Gold credentials are required. Store them in the vault first." }
$WUGServer = $WUGCred.UserName

# Connect to vCenter
Connect-VIServer $vCenterServer -Credential $VMwareCred

# ========================
# Discover Clusters
# ========================
Write-Host "`n=== vSphere Clusters ===" -ForegroundColor Cyan
$clusters = Get-Cluster | Select-Object Name, HAEnabled, HAFailoverLevel, DrsEnabled, DrsAutomationLevel, EVCMode
$clusters | Format-Table -AutoSize

# ========================
# Discover ESXi Hosts
# ========================
Write-Host "`n=== ESXi Hosts ===" -ForegroundColor Cyan
$esxiHosts = Get-VMHost | Select-Object Name, ConnectionState, PowerState, `
    @{N='Cluster'; E={$_.Parent.Name}}, `
    @{N='IPAddress'; E={(Get-VMHostNetworkAdapter -VMHost $_ -VMKernel | Where-Object {$_.ManagementTrafficEnabled} | Select-Object -First 1).IP}}, `
    Version, Build, Manufacturer, Model, `
    @{N='CpuSockets'; E={$_.ExtensionData.Hardware.CpuInfo.NumCpuPackages}}, `
    @{N='CpuCores'; E={$_.ExtensionData.Hardware.CpuInfo.NumCpuCores}}, `
    @{N='CpuThreads'; E={$_.ExtensionData.Hardware.CpuInfo.NumCpuThreads}}, `
    @{N='MemoryGB'; E={[math]::Round($_.MemoryTotalGB, 2)}}, `
    @{N='CpuUsageMHz'; E={$_.CpuUsageMhz}}, `
    @{N='CpuTotalMHz'; E={$_.CpuTotalMhz}}, `
    @{N='MemoryUsageGB'; E={[math]::Round($_.MemoryUsageGB, 2)}}
$esxiHosts | Format-Table -AutoSize

# ========================
# Discover VMs
# ========================
Write-Host "`n=== Virtual Machines ===" -ForegroundColor Cyan
$vms = Get-VM | Select-Object Name, PowerState, `
    @{N='Cluster'; E={$_.VMHost.Parent.Name}}, `
    @{N='ESXiHost'; E={$_.VMHost.Name}}, `
    @{N='IPAddress'; E={($_ | Get-VMGuest).IPAddress | Where-Object {$_ -match '^\d{1,3}(\.\d{1,3}){3}$'} | Select-Object -First 1}}, `
    @{N='OS'; E={$_.ExtensionData.Config.GuestFullName}}, `
    @{N='NumCPU'; E={$_.NumCpu}}, `
    @{N='MemoryGB'; E={$_.MemoryGB}}, `
    @{N='ProvisionedSpaceGB'; E={[math]::Round($_.ProvisionedSpaceGB, 2)}}, `
    @{N='UsedSpaceGB'; E={[math]::Round($_.UsedSpaceGB, 2)}}, `
    @{N='ToolsStatus'; E={$_.ExtensionData.Guest.ToolsStatus}}, `
    @{N='NicCount'; E={($_ | Get-NetworkAdapter).Count}}, `
    @{N='DiskCount'; E={($_ | Get-HardDisk).Count}}
$vms | Format-Table -AutoSize

# ========================
# Sample Performance Metrics
# ========================
Write-Host "`n=== Sample Performance Metrics (ESXi Hosts) ===" -ForegroundColor Cyan
foreach ($esxi in (Get-VMHost)) {
    Write-Host "`n--- $($esxi.Name) ---" -ForegroundColor Yellow

    # CPU usage %
    $cpuUsage = Get-Stat -Entity $esxi -Stat "cpu.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  CPU Usage (avg):    $([math]::Round($cpuUsage.Average, 2))%"

    # Memory usage %
    $memUsage = Get-Stat -Entity $esxi -Stat "mem.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Memory Usage (avg): $([math]::Round($memUsage.Average, 2))%"

    # Network usage (KBps)
    $netUsage = Get-Stat -Entity $esxi -Stat "net.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Net Usage (avg):    $([math]::Round($netUsage.Average, 2)) KBps"

    # Disk usage (KBps)
    $diskUsage = Get-Stat -Entity $esxi -Stat "disk.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Disk Usage (avg):   $([math]::Round($diskUsage.Average, 2)) KBps"
}

Write-Host "`n=== Sample Performance Metrics (VMs) ===" -ForegroundColor Cyan
foreach ($vm in (Get-VM | Where-Object {$_.PowerState -eq 'PoweredOn'} | Select-Object -First 10)) {
    Write-Host "`n--- $($vm.Name) ---" -ForegroundColor Yellow

    # CPU usage %
    $cpuUsage = Get-Stat -Entity $vm -Stat "cpu.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  CPU Usage (avg):    $([math]::Round($cpuUsage.Average, 2))%"

    # Memory usage %
    $memUsage = Get-Stat -Entity $vm -Stat "mem.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Memory Usage (avg): $([math]::Round($memUsage.Average, 2))%"

    # Network usage (KBps)
    $netUsage = Get-Stat -Entity $vm -Stat "net.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Net Usage (avg):    $([math]::Round($netUsage.Average, 2)) KBps"

    # Disk usage (KBps)
    $diskUsage = Get-Stat -Entity $vm -Stat "disk.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Disk Usage (avg):   $([math]::Round($diskUsage.Average, 2)) KBps"

    # Disk latency (ms)
    $diskLatency = Get-Stat -Entity $vm -Stat "disk.totalLatency.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average
    Write-Host "  Disk Latency (avg): $([math]::Round($diskLatency.Average, 2)) ms"
}

# ========================
# Datastore Info
# ========================
Write-Host "`n=== Datastores ===" -ForegroundColor Cyan
$datastores = Get-Datastore | Select-Object Name, `
    @{N='CapacityGB'; E={[math]::Round($_.CapacityGB, 2)}}, `
    @{N='FreeSpaceGB'; E={[math]::Round($_.FreeSpaceGB, 2)}}, `
    @{N='UsedGB'; E={[math]::Round($_.CapacityGB - $_.FreeSpaceGB, 2)}}, `
    @{N='PercentFree'; E={[math]::Round(($_.FreeSpaceGB / $_.CapacityGB) * 100, 1)}}, `
    Type, State
$datastores | Format-Table -AutoSize

# ========================
# Virtual Switches / Port Groups
# ========================
Write-Host "`n=== Virtual Switches ===" -ForegroundColor Cyan
Get-VirtualSwitch | Select-Object Name, VMHost, NumPorts, NumPortsAvailable, Mtu, Nic | Format-Table -AutoSize

Write-Host "`n=== Port Groups ===" -ForegroundColor Cyan
Get-VirtualPortGroup | Select-Object Name, VirtualSwitch, VLanId, VMHostId | Format-Table -AutoSize

# ========================
# Resource Pools
# ========================
Write-Host "`n=== Resource Pools ===" -ForegroundColor Cyan
Get-ResourcePool | Select-Object Name, `
    @{N='CpuSharesLevel'; E={$_.CpuSharesLevel}}, `
    @{N='CpuReservationMHz'; E={$_.CpuReservationMHz}}, `
    @{N='CpuLimitMHz'; E={$_.CpuLimitMHz}}, `
    @{N='MemSharesLevel'; E={$_.MemSharesLevel}}, `
    @{N='MemReservationGB'; E={[math]::Round($_.MemReservationGB, 2)}}, `
    @{N='MemLimitGB'; E={[math]::Round($_.MemLimitGB, 2)}} |
    Format-Table -AutoSize

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# Collect valid IPs from ESXi hosts and VMs into a single array
$allIPs = @()

foreach ($esxi in $esxiHosts) {
    if ($esxi.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $allIPs += $esxi.IPAddress
    } else {
        Write-Warning "Skipping ESXi host $($esxi.Name) due to missing/invalid IP"
    }
}

foreach ($vm in $vms) {
    if ($vm.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $allIPs += $vm.IPAddress
    } else {
        Write-Warning "Skipping VM $($vm.Name) due to missing/invalid IP"
    }
}

# Deduplicate IPs
$allIPs = $allIPs | Select-Object -Unique

# Add all discovered devices in a single call
if ($allIPs.Count -gt 0) {
    Write-Host "`nAdding $($allIPs.Count) devices to WhatsUp Gold..." -ForegroundColor Cyan
    Add-WUGDevice -IpOrNames $allIPs
} else {
    Write-Warning "No valid IP addresses found to add."
}

# Cleanup
Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCADUZlr4EgtvQ/W
# Kjpe92dVI5k6Q7qQiAiWw7HK+Cw5B6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgZr4Xm/Px4oCP8vMzMh9aYTYVG/Zyk2Ry
# qZmbdh6FuIQwDQYJKoZIhvcNAQEBBQAEggIAbYngVo17gVVhfohdlw0rAWleaM4t
# P4OOtBKzqQ8NwmcaEL6oP+U5v5OEW2Es0qPily7a3ITdj0iqbKy0k6nKKUCKsFj6
# +6BBGWIkRkQruLK0Q4l1+etpw4RqdYHqHkgDgDLZDYbQi0H204UQhe5jLz8DGjKw
# qdRW3pbldgBtS9xVrLHVbjsSsprUYo+Cuh/ePCRlnaPEgnXy/9x6/DwYk5HhxB+0
# WluH5DZK4XDyXrqgrHvgeOU0oDl0J422/PlapgmLgDnJPOhMO+gaF91GIGx0zwlC
# 1KyeCG+CGX0R3hr6khswurAOdK9QB8tT7PEPrI3rjLz8tkb2rwgKT42OXjukrNhc
# XJ+QSJCXsyvXzOc4wvOgU5OxCraip5qeFkxvEzHUP7VsupitNX2OtzSO8bbRS7+k
# yH6F8MN/t0UkABkGsFEkOGQK9a3fNPEvTZw7r3D1ZxsHq7XgGrNwIbnE8IAyQEA+
# xRBZ0gONZMOmfaf9d+iWBtYVYuLZGHBgUabvn4hsHCl1gzY6tvLpYsclo8RRJvhC
# xiKQZHOamSdBEuoFAMidNzF2/jiFrXqUJ3fXc36sS9nCIMjo1QH37WYAJZEGLaKI
# JstVucO6/8fLGkDI/XJpp//dkdnGjp+VsYvDEjvrQ36iskEdGDSFeQjX/wyrfcdE
# PW678klMVy6DYmg=
# SIG # End signature block
