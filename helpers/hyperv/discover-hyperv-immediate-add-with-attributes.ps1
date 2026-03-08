# Configuration
$HypervHosts = @("192.168.1.10", "192.168.1.11")  # Hyper-V host IPs or hostnames
$WUGServer   = "192.168.74.74"

# Credentials
if (!$HypervCred) { $HypervCred = Get-Credential -Message "Enter credentials for Hyper-V host(s)" }
if (!$WUGCred)    { $WUGCred    = Get-Credential -Message "Enter credentials for WUG server" }

# Check if the WhatsUpGoldPS module is loaded
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

# Load helper functions
. "$PSScriptRoot\HypervHelpers.ps1"

# ========================
# Discover Hyper-V Hosts and VMs
# ========================
$hostResults = @()
$vmResults   = @()

foreach ($hvHost in $HypervHosts) {
    Write-Host "`n=== Connecting to Hyper-V host: $hvHost ===" -ForegroundColor Cyan
    try {
        $session = Connect-HypervHost -ComputerName $hvHost -Credential $HypervCred
    }
    catch {
        Write-Warning "Failed to connect to $hvHost : $_"
        continue
    }

    # Gather host detail
    $hostDetail = Get-HypervHostDetail -CimSession $session
    $hostResults += $hostDetail

    # Gather VMs
    $vms = Get-HypervVMs -CimSession $session
    foreach ($vm in $vms) {
        $vmDetail = Get-HypervVMDetail -CimSession $session -VM $vm
        $vmResults += $vmDetail
    }

    Remove-CimSession -CimSession $session
}

# Output results
Write-Host "`n=== Hyper-V Hosts ===" -ForegroundColor Cyan
$hostResults | Format-Table HostName, IPAddress, OSName, CPUSockets, CPUCores, RAM_TotalGB, Status -AutoSize

Write-Host "`n=== Hyper-V VMs ===" -ForegroundColor Cyan
$vmResults | Sort-Object Host, Name | Format-Table Name, IPAddress, Host, State, CPUCount, MemoryAssignedGB, DiskTotalGB -AutoSize

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# --- Hyper-V Hosts ---
Write-Host "`n=== Adding Hyper-V Hosts to WUG ===" -ForegroundColor Cyan
foreach ($host_ in $hostResults) {
    if ($host_.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping host $($host_.HostName) due to invalid IP: $($host_.IPAddress)"
        continue
    }

    if (Get-WUGDevice -SearchValue $host_.IPAddress -View id) {
        Write-Warning "Skipping already monitored host $($host_.HostName) ($($host_.IPAddress))"
        continue
    }

    # Build attributes from all properties
    $attributes = @(
        @{ Name = "HyperV_Type";         Value = "Hyper-V Host" }
        @{ Name = "HyperV_HostName";     Value = "$($host_.HostName)" }
        @{ Name = "HyperV_OSName";       Value = "$($host_.OSName)" }
        @{ Name = "HyperV_OSVersion";    Value = "$($host_.OSVersion)" }
        @{ Name = "HyperV_OSBuild";      Value = "$($host_.OSBuild)" }
        @{ Name = "HyperV_Manufacturer"; Value = "$($host_.Manufacturer)" }
        @{ Name = "HyperV_Model";        Value = "$($host_.Model)" }
        @{ Name = "HyperV_Domain";       Value = "$($host_.Domain)" }
        @{ Name = "HyperV_CPUModel";     Value = "$($host_.CPUModel)" }
        @{ Name = "HyperV_CPUSockets";   Value = "$($host_.CPUSockets)" }
        @{ Name = "HyperV_CPUCores";     Value = "$($host_.CPUCores)" }
        @{ Name = "HyperV_CPULogical";   Value = "$($host_.CPULogical)" }
        @{ Name = "HyperV_RAM_TotalGB";  Value = "$($host_.RAM_TotalGB)" }
        @{ Name = "HyperV_RAM_FreeGB";   Value = "$($host_.RAM_FreeGB)" }
        @{ Name = "HyperV_Uptime";       Value = "$($host_.Uptime)" }
    )

    $note = "Hyper-V Host | $($host_.OSName) | $($host_.Manufacturer) $($host_.Model) | " +
            "$($host_.CPUSockets)S/$($host_.CPUCores)C/$($host_.CPULogical)T | $($host_.RAM_TotalGB) GB RAM | " +
            "Domain: $($host_.Domain) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $host_.HostName `
        -DeviceAddress $host_.IPAddress `
        -Brand "Microsoft Hyper-V Host" `
        -OS $host_.OSName `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added Hyper-V host $($host_.HostName) ($($host_.IPAddress))" -ForegroundColor Green
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

    $attributes = @(
        @{ Name = "HyperV_Type";             Value = "Virtual Machine" }
        @{ Name = "HyperV_Host";             Value = "$($vm.Host)" }
        @{ Name = "HyperV_State";            Value = "$($vm.State)" }
        @{ Name = "HyperV_Status";           Value = "$($vm.Status)" }
        @{ Name = "HyperV_Generation";       Value = "$($vm.Generation)" }
        @{ Name = "HyperV_Version";          Value = "$($vm.Version)" }
        @{ Name = "HyperV_CPUCount";         Value = "$($vm.CPUCount)" }
        @{ Name = "HyperV_CPUUsagePct";      Value = "$($vm.CPUUsagePct)" }
        @{ Name = "HyperV_MemoryAssignedGB"; Value = "$($vm.MemoryAssignedGB)" }
        @{ Name = "HyperV_MemoryStartupGB";  Value = "$($vm.MemoryStartupGB)" }
        @{ Name = "HyperV_DynamicMemory";    Value = "$($vm.DynamicMemory)" }
        @{ Name = "HyperV_DiskCount";        Value = "$($vm.DiskCount)" }
        @{ Name = "HyperV_DiskTotalGB";      Value = "$($vm.DiskTotalGB)" }
        @{ Name = "HyperV_NicCount";         Value = "$($vm.NicCount)" }
        @{ Name = "HyperV_SwitchNames";      Value = "$($vm.SwitchNames)" }
        @{ Name = "HyperV_VLanIds";          Value = "$($vm.VLanIds)" }
        @{ Name = "HyperV_SnapshotCount";    Value = "$($vm.SnapshotCount)" }
        @{ Name = "HyperV_Heartbeat";        Value = "$($vm.Heartbeat)" }
        @{ Name = "HyperV_ReplicationState"; Value = "$($vm.ReplicationState)" }
    )

    $note = "Hyper-V VM on $($vm.Host) | $($vm.CPUCount) vCPU, $($vm.MemoryAssignedGB) GB RAM | " +
            "Gen $($vm.Generation) v$($vm.Version) | Disks: $($vm.DiskCount) ($($vm.DiskTotalGB) GB) | " +
            "NICs: $($vm.NicCount) ($($vm.SwitchNames)) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $vm.Name `
        -DeviceAddress $vm.IPAddress `
        -Brand "Microsoft Hyper-V VM" `
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
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}
