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
# Add to WhatsUp Gold (bulk discover-then-add)
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# Collect valid IPs from hosts and VMs into a single array
$allIPs = @()

foreach ($host_ in $hostResults) {
    if ($host_.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $allIPs += $host_.IPAddress
    } else {
        Write-Warning "Skipping host $($host_.HostName) due to invalid IP: $($host_.IPAddress)"
    }
}

foreach ($vm in $vmResults) {
    if ($vm.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $allIPs += $vm.IPAddress
    } else {
        Write-Warning "Skipping VM $($vm.Name) due to invalid IP: $($vm.IPAddress)"
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
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}
