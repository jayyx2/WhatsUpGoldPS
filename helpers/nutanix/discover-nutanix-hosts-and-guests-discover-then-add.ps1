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
# Add to WhatsUp Gold (bulk discover-then-add)
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# Collect valid IPs from hosts and VMs into a single array
$allIPs = @()

foreach ($host_ in $hostResults) {
    if ($host_.HypervisorIP -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $allIPs += $host_.HypervisorIP
    } else {
        Write-Warning "Skipping host $($host_.HostName) due to invalid IP: $($host_.HypervisorIP)"
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
