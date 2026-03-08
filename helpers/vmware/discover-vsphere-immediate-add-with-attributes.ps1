# Configuration
$vCenterServer = "192.168.23.60"
$WUGServer = "192.168.1.250"

# Credentials
if (!$VMwareCred) {
    $VMwareCred = Get-Credential -UserName "administrator@vsphere.local" -Message "Enter credentials for vCenter server"
}
if (!$WUGCred) {
    $WUGCred = Get-Credential -UserName "admin" -Message "Enter credentials for WUG server"
}

# Check if the WhatsUpGoldPS module is loaded, and if not, import it
if (-not (Get-Module -Name WhatsUpGoldPS)) {Import-Module WhatsUpGoldPS}
# Check if the VMware modules are loaded, and if not, import it
if (-not (Get-Module -Name VMware.Vim)) {Import-Module VMware.Vim}
if (-not (Get-Module -Name VMware.VimAutomation.Cis.Core)) {Import-Module VMware.VimAutomation.Cis.Core}
if (-not (Get-Module -Name VMware.VimAutomation.Common)) {Import-Module VMware.VimAutomation.Common}
if (-not (Get-Module -Name VMware.VimAutomation.Core)) {Import-Module VMware.VimAutomation.Core}
if (-not (Get-Module -Name VMware.VimAutomation.Sdk)) {Import-Module VMware.VimAutomation.Sdk}

# Connect to vCenter
Connect-VIServer $vCenterServer -Credential $VMwareCred

# ========================
# Gather Cluster Info
# ========================
Write-Host "`n=== Gathering Cluster Info ===" -ForegroundColor Cyan
$clusterLookup = @{}
foreach ($cluster in (Get-Cluster)) {
    $clusterLookup[$cluster.Name] = @{
        HAEnabled         = $cluster.HAEnabled
        HAFailoverLevel   = $cluster.HAFailoverLevel
        DrsEnabled        = $cluster.DrsEnabled
        DrsAutomationLevel = $cluster.DrsAutomationLevel
        EVCMode           = $cluster.EVCMode
    }
}

# ========================
# Gather Datastore Info
# ========================
Write-Host "=== Gathering Datastore Info ===" -ForegroundColor Cyan
$datastoreLookup = @{}
foreach ($ds in (Get-Datastore)) {
    $datastoreLookup[$ds.Name] = @{
        CapacityGB  = [math]::Round($ds.CapacityGB, 2)
        FreeSpaceGB = [math]::Round($ds.FreeSpaceGB, 2)
        PercentFree = [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1)
        Type        = $ds.Type
    }
}

# ========================
# Gather ESXi Host Data
# ========================
Write-Host "=== Gathering ESXi Host Data ===" -ForegroundColor Cyan
$esxiHosts = foreach ($esxi in (Get-VMHost)) {
    $mgmtIP = (Get-VMHostNetworkAdapter -VMHost $esxi -VMKernel |
        Where-Object { $_.ManagementTrafficEnabled } | Select-Object -First 1).IP
    $clusterName = $esxi.Parent.Name

    # Perf samples
    $cpuAvg = (Get-Stat -Entity $esxi -Stat "cpu.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average
    $memAvg = (Get-Stat -Entity $esxi -Stat "mem.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average
    $netAvg = (Get-Stat -Entity $esxi -Stat "net.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average
    $diskAvg = (Get-Stat -Entity $esxi -Stat "disk.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average

    # Datastores attached to this host
    $hostDatastores = ($esxi | Get-Datastore | Select-Object -ExpandProperty Name) -join ", "

    [PSCustomObject]@{
        Name            = $esxi.Name
        IPAddress       = $mgmtIP
        Cluster         = $clusterName
        ConnectionState = $esxi.ConnectionState.ToString()
        PowerState      = $esxi.PowerState.ToString()
        Version         = $esxi.Version
        Build           = $esxi.Build
        Manufacturer    = $esxi.Manufacturer
        Model           = $esxi.Model
        CpuSockets      = $esxi.ExtensionData.Hardware.CpuInfo.NumCpuPackages
        CpuCores        = $esxi.ExtensionData.Hardware.CpuInfo.NumCpuCores
        CpuThreads      = $esxi.ExtensionData.Hardware.CpuInfo.NumCpuThreads
        CpuTotalMHz     = $esxi.CpuTotalMhz
        CpuUsageMHz     = $esxi.CpuUsageMhz
        MemoryTotalGB   = [math]::Round($esxi.MemoryTotalGB, 2)
        MemoryUsageGB   = [math]::Round($esxi.MemoryUsageGB, 2)
        CpuUsagePct     = [math]::Round($cpuAvg, 2)
        MemUsagePct     = [math]::Round($memAvg, 2)
        NetUsageKBps    = [math]::Round($netAvg, 2)
        DiskUsageKBps   = [math]::Round($diskAvg, 2)
        Datastores      = $hostDatastores
    }
}

Write-Host "`n=== ESXi Hosts ===" -ForegroundColor Cyan
$esxiHosts | Format-Table Name, IPAddress, Cluster, Version, CpuCores, MemoryTotalGB, CpuUsagePct, MemUsagePct -AutoSize

# ========================
# Gather VM Data
# ========================
Write-Host "`n=== Gathering VM Data ===" -ForegroundColor Cyan
$vmResults = foreach ($vm in (Get-VM)) {
    $guest = $vm | Get-VMGuest
    $ipAddr = $guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
    $nics = ($vm | Get-NetworkAdapter)
    $disks = ($vm | Get-HardDisk)

    # Perf samples (only for powered-on VMs)
    $cpuAvg = $null; $memAvg = $null; $netAvg = $null; $diskAvg = $null; $diskLat = $null
    if ($vm.PowerState -eq 'PoweredOn') {
        $cpuAvg = (Get-Stat -Entity $vm -Stat "cpu.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $memAvg = (Get-Stat -Entity $vm -Stat "mem.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $netAvg = (Get-Stat -Entity $vm -Stat "net.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $diskAvg = (Get-Stat -Entity $vm -Stat "disk.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $diskLat = (Get-Stat -Entity $vm -Stat "disk.totalLatency.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
    }

    [PSCustomObject]@{
        Name              = $vm.Name
        IPAddress         = $ipAddr
        PowerState        = $vm.PowerState.ToString()
        ESXiHost          = $vm.VMHost.Name
        Cluster           = $vm.VMHost.Parent.Name
        GuestOS           = $vm.ExtensionData.Config.GuestFullName
        GuestFamily       = $guest.GuestFamily
        ToolsStatus       = $vm.ExtensionData.Guest.ToolsStatus
        NumCPU            = $vm.NumCpu
        MemoryGB          = $vm.MemoryGB
        ProvisionedSpaceGB = [math]::Round($vm.ProvisionedSpaceGB, 2)
        UsedSpaceGB       = [math]::Round($vm.UsedSpaceGB, 2)
        NicCount          = $nics.Count
        NicTypes          = ($nics.Type | Select-Object -Unique) -join ", "
        NetworkNames      = ($nics.NetworkName | Select-Object -Unique) -join ", "
        DiskCount         = $disks.Count
        DiskTotalGB       = [math]::Round(($disks | Measure-Object -Property CapacityGB -Sum).Sum, 2)
        CpuUsagePct       = if ($null -ne $cpuAvg) { [math]::Round($cpuAvg, 2) } else { "N/A" }
        MemUsagePct       = if ($null -ne $memAvg) { [math]::Round($memAvg, 2) } else { "N/A" }
        NetUsageKBps      = if ($null -ne $netAvg) { [math]::Round($netAvg, 2) } else { "N/A" }
        DiskUsageKBps     = if ($null -ne $diskAvg) { [math]::Round($diskAvg, 2) } else { "N/A" }
        DiskLatencyMs     = if ($null -ne $diskLat) { [math]::Round($diskLat, 2) } else { "N/A" }
    }
}

Write-Host "`n=== Virtual Machines ===" -ForegroundColor Cyan
$vmResults | Format-Table Name, IPAddress, PowerState, Cluster, ESXiHost, NumCPU, MemoryGB, CpuUsagePct, MemUsagePct -AutoSize

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# --- ESXi Hosts ---
Write-Host "`n=== Adding ESXi Hosts to WUG ===" -ForegroundColor Cyan
foreach ($esxi in $esxiHosts) {
    if ($esxi.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping ESXi host $($esxi.Name) - invalid/missing IP: $($esxi.IPAddress)"
        continue
    }

    if (Get-WUGDevice -SearchValue $esxi.IPAddress -View id) {
        Write-Warning "Skipping already monitored ESXi host $($esxi.Name) ($($esxi.IPAddress))"
        continue
    }

    # Host-specific attributes
    $clusterInfo = $clusterLookup[$esxi.Cluster]
    $attributes = @(
        @{ Name = "vSphere_Type";          Value = "ESXi Host" }
        @{ Name = "vSphere_Cluster";       Value = "$($esxi.Cluster)" }
        @{ Name = "vSphere_Version";       Value = "$($esxi.Version)" }
        @{ Name = "vSphere_Build";         Value = "$($esxi.Build)" }
        @{ Name = "vSphere_Manufacturer";  Value = "$($esxi.Manufacturer)" }
        @{ Name = "vSphere_Model";         Value = "$($esxi.Model)" }
        @{ Name = "vSphere_ConnectionState"; Value = "$($esxi.ConnectionState)" }
        @{ Name = "vSphere_PowerState";    Value = "$($esxi.PowerState)" }
        @{ Name = "vSphere_CpuSockets";    Value = "$($esxi.CpuSockets)" }
        @{ Name = "vSphere_CpuCores";      Value = "$($esxi.CpuCores)" }
        @{ Name = "vSphere_CpuThreads";    Value = "$($esxi.CpuThreads)" }
        @{ Name = "vSphere_CpuTotalMHz";   Value = "$($esxi.CpuTotalMHz)" }
        @{ Name = "vSphere_MemoryTotalGB"; Value = "$($esxi.MemoryTotalGB)" }
        @{ Name = "vSphere_Datastores";    Value = "$($esxi.Datastores)" }
        @{ Name = "vSphere_SampleCpuPct";  Value = "$($esxi.CpuUsagePct)" }
        @{ Name = "vSphere_SampleMemPct";  Value = "$($esxi.MemUsagePct)" }
        @{ Name = "vSphere_SampleNetKBps"; Value = "$($esxi.NetUsageKBps)" }
        @{ Name = "vSphere_SampleDiskKBps"; Value = "$($esxi.DiskUsageKBps)" }
    )

    # Cluster-level attributes (only on hosts)
    if ($clusterInfo) {
        $attributes += @(
            @{ Name = "vSphere_Cluster_HAEnabled";       Value = "$($clusterInfo.HAEnabled)" }
            @{ Name = "vSphere_Cluster_HAFailoverLevel"; Value = "$($clusterInfo.HAFailoverLevel)" }
            @{ Name = "vSphere_Cluster_DrsEnabled";      Value = "$($clusterInfo.DrsEnabled)" }
            @{ Name = "vSphere_Cluster_DrsAutomation";   Value = "$($clusterInfo.DrsAutomationLevel)" }
            @{ Name = "vSphere_Cluster_EVCMode";         Value = "$($clusterInfo.EVCMode)" }
        )
    }

    $note = "ESXi $($esxi.Version) build $($esxi.Build) | $($esxi.Manufacturer) $($esxi.Model) | " +
            "$($esxi.CpuSockets)S/$($esxi.CpuCores)C/$($esxi.CpuThreads)T | $($esxi.MemoryTotalGB) GB RAM | " +
            "Cluster: $($esxi.Cluster) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $esxi.Name `
        -DeviceAddress $esxi.IPAddress `
        -Brand "VMware ESXi" `
        -OS "VMware ESXi $($esxi.Version)" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added ESXi host $($esxi.Name) ($($esxi.IPAddress))" -ForegroundColor Green
    }
}

# --- Virtual Machines ---
Write-Host "`n=== Adding VMs to WUG ===" -ForegroundColor Cyan
foreach ($vm in $vmResults) {
    if ($vm.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping VM $($vm.Name) - invalid/missing IP: $($vm.IPAddress)"
        continue
    }

    if (Get-WUGDevice -SearchValue $vm.IPAddress -View id) {
        Write-Warning "Skipping already monitored VM $($vm.Name) ($($vm.IPAddress))"
        continue
    }

    # Guest-specific attributes (no hardware/cluster-level host details)
    $attributes = @(
        @{ Name = "vSphere_Type";           Value = "Virtual Machine" }
        @{ Name = "vSphere_PowerState";     Value = "$($vm.PowerState)" }
        @{ Name = "vSphere_ESXiHost";       Value = "$($vm.ESXiHost)" }
        @{ Name = "vSphere_Cluster";        Value = "$($vm.Cluster)" }
        @{ Name = "vSphere_GuestOS";        Value = "$($vm.GuestOS)" }
        @{ Name = "vSphere_GuestFamily";    Value = "$($vm.GuestFamily)" }
        @{ Name = "vSphere_ToolsStatus";    Value = "$($vm.ToolsStatus)" }
        @{ Name = "vSphere_NumCPU";         Value = "$($vm.NumCPU)" }
        @{ Name = "vSphere_MemoryGB";       Value = "$($vm.MemoryGB)" }
        @{ Name = "vSphere_ProvisionedGB";  Value = "$($vm.ProvisionedSpaceGB)" }
        @{ Name = "vSphere_UsedSpaceGB";    Value = "$($vm.UsedSpaceGB)" }
        @{ Name = "vSphere_NicCount";       Value = "$($vm.NicCount)" }
        @{ Name = "vSphere_NicTypes";       Value = "$($vm.NicTypes)" }
        @{ Name = "vSphere_NetworkNames";   Value = "$($vm.NetworkNames)" }
        @{ Name = "vSphere_DiskCount";      Value = "$($vm.DiskCount)" }
        @{ Name = "vSphere_DiskTotalGB";    Value = "$($vm.DiskTotalGB)" }
        @{ Name = "vSphere_SampleCpuPct";   Value = "$($vm.CpuUsagePct)" }
        @{ Name = "vSphere_SampleMemPct";   Value = "$($vm.MemUsagePct)" }
        @{ Name = "vSphere_SampleNetKBps";  Value = "$($vm.NetUsageKBps)" }
        @{ Name = "vSphere_SampleDiskKBps"; Value = "$($vm.DiskUsageKBps)" }
        @{ Name = "vSphere_SampleDiskLatMs"; Value = "$($vm.DiskLatencyMs)" }
    )

    # Determine OS string for the WUG device
    $osString = if ($vm.GuestOS) { $vm.GuestOS } else { "Unknown" }

    $note = "VM on $($vm.ESXiHost) | $($vm.NumCPU) vCPU, $($vm.MemoryGB) GB RAM | " +
            "$($vm.GuestOS) | Provisioned: $($vm.ProvisionedSpaceGB) GB | " +
            "NICs: $($vm.NicCount) ($($vm.NetworkNames)) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $vm.Name `
        -DeviceAddress $vm.IPAddress `
        -Brand "VMware VM" `
        -OS $osString `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added VM $($vm.Name) ($($vm.IPAddress))" -ForegroundColor Green
    }
}

# Cleanup
Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCm2c55m2jry5L3
# 80MccxZy347301N6DurdOUjID5BfZaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgmQfdP5SoIKQbg1XMNmdExCAr1hqg9fT4
# FhLQ6hyjVwowDQYJKoZIhvcNAQEBBQAEggIAV12vBRGIVSN72kV2Ar0twpP+n2WA
# 7zC9OKpjFrOfnAqN0F13LPp3ewM8ez3RUEX6vxLvhX1ud77gdPAt4Btz75VqcuLH
# 0X90TtFEkm3AU1RVtzGU2iCD4lwRwqQU9CrlD0D+8cbY2L9lZqbn8gguYymyB7Lz
# EylqhNOJ7d64+FVdC2Cr3Dh/Tfv4znx0UpAgXbXt1FF3mcdGnts3o6yvDZ7tOmhN
# y1jiLydkZTa1sTgnHjpwy22sxSoqc4SdQMpO0Mdejzuybcd2QZv/+r+WwsYpzaHd
# /GBiThraptuiWLEAeMcMPfVYvv9QbdVtFypChlW2t+mcPQTl6bwbDGnk6SZadrR1
# MEJb1gqWZ8PCSrKzO+IHHEoF/kyzlC0zYTQjyERpsHkHZqezkcq3uSOpG3UUs89F
# WzQ8DTPw/X7IB0gQ3lwQH9F/WUPdhlaYNws6bkFfkmiC4lV9PBBhXMRt8f60sraM
# 6NvgLdWm4KJ8eDNX7xu6JTg4jQ1YHYXWcMEDfWPQOJFN5HYKDWe1WQziC5ZlGX1D
# cny/707l3my+EIfGvwa5nKM1R6aU22DcqIIb5CjyV7M5tI7oyfNKIr7119R+A8Tm
# 1YPEUlaLLcW72t7X8a2P4OSfrdZ/8gUWrYfxgkisjsA/KfVBbl9MJ+4lazBvWkBo
# 8nqjXroyD3AzJ6M=
# SIG # End signature block
