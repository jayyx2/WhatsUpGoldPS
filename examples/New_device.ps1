<#
This script creates a new device in WhatsUp Gold using the provided parameters.
It demonstrates the usage of various parameters like DeviceAddress, displayName, 
deviceType, primaryRole, and different monitor types (ActiveMonitors, PerformanceMonitors, PassiveMonitors).
#>

# Check if the WhatsUpGoldPS module is loaded, and if not, import it
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    Import-Module WhatsUpGoldPS
}

### New device example
Write-Host "Begin creating new device..."
Write-Host "Settings parameters."
# New device parameters
$params = @{
    DeviceAddress       = "192.168.1.1"
    displayName         = "Example New Device"
    primaryRole         = "Device"
    ActiveMonitors      = @("Ping", "SNMP")
    PerformanceMonitors = @("CPU Utilization", "Memory Utilization")
    PassiveMonitors     = @("Cold Start", "Warm Start")
    note               = "Added by WhatsUpGoldPS PowerShell module on $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz UTC"))"
    snmpOid             = "1.3.6.4"
}

# Add the new device using the specified parameters and store the id
$NewDeviceID = (Add-WUGDevice @params).idMap.resultId
Write-Host "New device created, device ID is ${NewDeviceID}"
Write-Host "Sleeping for 3 seconds..."
Start-Sleep -Seconds 3
Write-Host "Begin update device properties for new device..."
Write-Host "Settings parameters."
# Set Device Properties parameters
$isWireless = $false
$collectWireless = $false
$keepDetailsCurrent = $false
$note = "This note was changed on $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz UTC"))"
$snmpOid = "1.3.6.4.1"
$displayName = "Example Changed Device"
#Use the stored $NewDeviceID to adjust Device Properties
Set-WUGDeviceProperties -DeviceID $NewDeviceID -DisplayName $displayName -isWireless $isWireless -collectWireless $collectWireless -keepDetailsCurrent $keepDetailsCurrent -note $note -snmpOid $snmpOid -actionPolicy $actionPolicy
Write-Host "Updated the device with our new properties."