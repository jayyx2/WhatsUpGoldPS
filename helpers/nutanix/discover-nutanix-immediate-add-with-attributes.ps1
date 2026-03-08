# Configuration
$NutanixServer = "https://192.168.1.50:9440"  # Prism Element or Prism Central URI
$WUGServer     = "192.168.74.74"

# Credentials
if (!$NutanixCred) { $NutanixCred = Get-Credential -UserName "admin" -Message "Enter credentials for Nutanix Prism" }
if (!$WUGCred)     { $WUGCred     = Get-Credential -Message "Enter credentials for WUG server" }

# Check if the WhatsUpGoldPS module is loaded
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

# Load helper functions
. "$PSScriptRoot\NutanixHelpers.ps1"

# Ignore SSL cert validation (self-signed)
Initialize-SSLBypass

# ========================
# Connect to Nutanix Prism
# ========================
$headers = Connect-NutanixCluster -Server $NutanixServer -Credential $NutanixCred

# ========================
# Gather Cluster Info
# ========================
Write-Host "`n=== Nutanix Cluster ===" -ForegroundColor Cyan
$clusterInfo = Get-NutanixCluster -Server $NutanixServer -Headers $headers
$clusterInfo | Format-List

# ========================
# Gather Host Data
# ========================
Write-Host "=== Gathering Nutanix Host Data ===" -ForegroundColor Cyan
$rawHosts = Get-NutanixHosts -Server $NutanixServer -Headers $headers

$hostResults = foreach ($h in $rawHosts) {
    Get-NutanixHostDetail -HostEntity $h
}

# Build UUID-to-name lookup for VM host mapping
$hostLookup = @{}
foreach ($h in $rawHosts) {
    $hostLookup[$h.uuid] = if ($h.name) { $h.name } else { $h.uuid }
}

Write-Host "`n=== Nutanix Hosts ===" -ForegroundColor Cyan
$hostResults | Format-Table HostName, HypervisorIP, HypervisorType, CPUSockets, CPUCores, RAM_TotalGB, NumVMs, CPUUsagePct -AutoSize

# ========================
# Gather VM Data
# ========================
Write-Host "=== Gathering Nutanix VM Data ===" -ForegroundColor Cyan
$rawVMs = Get-NutanixVMs -Server $NutanixServer -Headers $headers

$vmResults = foreach ($vm in $rawVMs) {
    Get-NutanixVMDetail -VMEntity $vm -HostLookup $hostLookup
}

Write-Host "`n=== Nutanix VMs ===" -ForegroundColor Cyan
$vmResults | Sort-Object Host, Name | Format-Table Name, IPAddress, Host, PowerState, NumCPU, MemoryGB, DiskTotalGB -AutoSize

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# --- Nutanix Hosts ---
Write-Host "`n=== Adding Nutanix Hosts to WUG ===" -ForegroundColor Cyan
foreach ($host_ in $hostResults) {
    if ($host_.HypervisorIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping host $($host_.HostName) due to invalid IP: $($host_.HypervisorIP)"
        continue
    }

    if (Get-WUGDevice -SearchValue $host_.HypervisorIP -View id) {
        Write-Warning "Skipping already monitored host $($host_.HostName) ($($host_.HypervisorIP))"
        continue
    }

    $attributes = @(
        @{ Name = "Nutanix_Type";              Value = "Nutanix Host" }
        @{ Name = "Nutanix_HostName";           Value = "$($host_.HostName)" }
        @{ Name = "Nutanix_HostUuid";           Value = "$($host_.HostUuid)" }
        @{ Name = "Nutanix_HypervisorIP";       Value = "$($host_.HypervisorIP)" }
        @{ Name = "Nutanix_CvmIP";              Value = "$($host_.CvmIP)" }
        @{ Name = "Nutanix_IpmiIP";             Value = "$($host_.IpmiIP)" }
        @{ Name = "Nutanix_HypervisorType";     Value = "$($host_.HypervisorType)" }
        @{ Name = "Nutanix_HypervisorVersion";  Value = "$($host_.HypervisorVersion)" }
        @{ Name = "Nutanix_Serial";             Value = "$($host_.Serial)" }
        @{ Name = "Nutanix_BlockModel";         Value = "$($host_.BlockModel)" }
        @{ Name = "Nutanix_BlockSerial";        Value = "$($host_.BlockSerial)" }
        @{ Name = "Nutanix_CPUModel";           Value = "$($host_.CPUModel)" }
        @{ Name = "Nutanix_CPUSockets";         Value = "$($host_.CPUSockets)" }
        @{ Name = "Nutanix_CPUCores";           Value = "$($host_.CPUCores)" }
        @{ Name = "Nutanix_CPUThreads";         Value = "$($host_.CPUThreads)" }
        @{ Name = "Nutanix_CPUFreqGHz";         Value = "$($host_.CPUFreqGHz)" }
        @{ Name = "Nutanix_RAM_TotalGB";        Value = "$($host_.RAM_TotalGB)" }
        @{ Name = "Nutanix_NumVMs";             Value = "$($host_.NumVMs)" }
        @{ Name = "Nutanix_NumDisks";           Value = "$($host_.NumDisks)" }
        @{ Name = "Nutanix_StorageCapacityGB";  Value = "$($host_.StorageCapacityGB)" }
        @{ Name = "Nutanix_StorageUsedGB";      Value = "$($host_.StorageUsedGB)" }
        @{ Name = "Nutanix_SampleCpuPct";       Value = "$($host_.CPUUsagePct)" }
        @{ Name = "Nutanix_SampleMemPct";       Value = "$($host_.MemUsagePct)" }
        @{ Name = "Nutanix_Cluster";            Value = "$($clusterInfo.ClusterName)" }
        @{ Name = "Nutanix_ClusterVersion";     Value = "$($clusterInfo.ClusterVersion)" }
    )

    $note = "Nutanix $($host_.HypervisorType) | $($host_.BlockModel) S/N $($host_.Serial) | " +
            "$($host_.CPUSockets)S/$($host_.CPUCores)C/$($host_.CPUThreads)T $($host_.CPUModel) | " +
            "$($host_.RAM_TotalGB) GB RAM | Cluster: $($clusterInfo.ClusterName) | " +
            "Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $host_.HostName `
        -DeviceAddress $host_.HypervisorIP `
        -Brand "Nutanix Host" `
        -OS $host_.HypervisorVersion `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added Nutanix host $($host_.HostName) ($($host_.HypervisorIP))" -ForegroundColor Green
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
        @{ Name = "Nutanix_Type";             Value = "Virtual Machine" }
        @{ Name = "Nutanix_Host";             Value = "$($vm.Host)" }
        @{ Name = "Nutanix_HostUuid";         Value = "$($vm.HostUuid)" }
        @{ Name = "Nutanix_PowerState";       Value = "$($vm.PowerState)" }
        @{ Name = "Nutanix_GuestOS";          Value = "$($vm.GuestOS)" }
        @{ Name = "Nutanix_MachineType";      Value = "$($vm.MachineType)" }
        @{ Name = "Nutanix_NumCPU";           Value = "$($vm.NumCPU)" }
        @{ Name = "Nutanix_CoresPerVcpu";     Value = "$($vm.NumCoresPerVcpu)" }
        @{ Name = "Nutanix_MemoryGB";         Value = "$($vm.MemoryGB)" }
        @{ Name = "Nutanix_DiskCount";        Value = "$($vm.DiskCount)" }
        @{ Name = "Nutanix_DiskTotalGB";      Value = "$($vm.DiskTotalGB)" }
        @{ Name = "Nutanix_NicCount";         Value = "$($vm.NicCount)" }
        @{ Name = "Nutanix_VLanIds";          Value = "$($vm.VLanIds)" }
        @{ Name = "Nutanix_NetworkNames";     Value = "$($vm.NetworkNames)" }
        @{ Name = "Nutanix_ProtectionDomain"; Value = "$($vm.ProtectionDomain)" }
        @{ Name = "Nutanix_NgtEnabled";       Value = "$($vm.NgtEnabled)" }
        @{ Name = "Nutanix_Cluster";          Value = "$($clusterInfo.ClusterName)" }
    )

    $osString = if ($vm.GuestOS -and $vm.GuestOS -ne "N/A") { $vm.GuestOS } else { "Unknown" }

    $note = "Nutanix VM on $($vm.Host) | $($vm.NumCPU) vCPU ($($vm.NumCoresPerVcpu) cores/vcpu), $($vm.MemoryGB) GB RAM | " +
            "$($vm.GuestOS) | Disks: $($vm.DiskCount) ($($vm.DiskTotalGB) GB) | " +
            "NICs: $($vm.NicCount) ($($vm.NetworkNames)) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $vm.Name `
        -DeviceAddress $vm.IPAddress `
        -Brand "Nutanix VM" `
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
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}
