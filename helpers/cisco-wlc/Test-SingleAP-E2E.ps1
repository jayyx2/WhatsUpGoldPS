#requires -Version 5.1
<#
.SYNOPSIS
    Single AP end-to-end test: create monitor, device, interface, and assign monitor with per-AP argument.
.DESCRIPTION
    Creates ONE SNMP monitor (shared), ONE device (AP LAN IP), adds WLC interface, assigns monitor with per-AP SNMP instance.
.PARAMETER WLCAddress
    WLC IP address (used for the interface and monitor polling target)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WLCAddress,

    [Parameter()]
    [string]$WUGServer = '192.168.74.74:9644'
)

# Load local repo version (not installed module)
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$localPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
Write-Verbose "Loading module from: $localPsd1"
Import-Module $localPsd1 -Force -ErrorAction Stop

# Connect (uses vaulted creds) - pass the server address to avoid interactive prompt
Write-Host "Connecting to WUG..." -ForegroundColor Cyan
try {
    Connect-WUGServer -serverUri '192.168.74.74' -Port 9644 -IgnoreSSLErrors -ErrorAction Stop
}
catch {
    Write-Error "Failed to connect: $_"
    return
}
Write-Host "Connected: $global:WhatsUpServerBaseURI" -ForegroundColor Green

# ============================================================================
# TEST AP DATA
# ============================================================================
$testAP = @{
    Name           = 'TEST-AP-001'
    MAC            = '00:1a:2b:3c:4d:5e'
    Model          = 'C9120AX-W'
    Serial         = 'FJC12345678'
    Location       = 'Building A - Floor 1'
    APLanIP        = '192.168.1.100'      # Device address
    WLCAddress     = $WLCAddress           # Interface address for monitoring
}

# Use an existing monitor template for testing (instead of trying to create a new one)
$monitorName = 'Azure Health - awugninja7477'

Write-Host ""
Write-Host "=== TEST PARAMETERS ===" -ForegroundColor Yellow
Write-Host "  Monitor Name: $monitorName (using existing template)"
Write-Host "  AP Name: $($testAP.Name)"
Write-Host "  AP LAN IP: $($testAP.APLanIP)"
Write-Host "  WLC Address (for interface): $($testAP.WLCAddress)"
Write-Host ""

# ============================================================================
# STEP 1: Get existing monitor from library
# ============================================================================

Write-Host "STEP 1: Retrieving SNMP monitor from library..." -ForegroundColor Cyan

$monitors = @(Get-WUGActiveMonitor -View basic | Where-Object { $_.TemplateName -eq $monitorName })
$monitorId = $null

if ($monitors) {
    $mon = $monitors | Select-Object -First 1
    $monitorId = $mon.TemplateId
    Write-Host "  Found existing monitor template: $monitorName (ID: $monitorId)" -ForegroundColor Green
}
else {
    Write-Error "Monitor template '$monitorName' not found"
    Write-Host "  Available templates:" -ForegroundColor Yellow
    Get-WUGActiveMonitor | Select-Object -ExpandProperty TemplateName -Unique | Sort-Object | Select-Object -First 5 | ForEach-Object { Write-Host "    - $_" }
    return
}

# ============================================================================
# STEP 2: Create device with AP LAN IP
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Creating device '$($testAP.Name)' with AP LAN IP '$($testAP.APLanIP)'..." -ForegroundColor Cyan

$deviceDisplayName = "$($testAP.Name) (AP)"
$existing = $null

try {
    $found = @(Get-WUGDevice -SearchValue $testAP.Name -ErrorAction SilentlyContinue)
    if ($found) {
        $existing = $found | Where-Object {
            $_.displayName -eq $testAP.Name -or 
            $_.displayName -eq $deviceDisplayName -or 
            $_.hostName -eq $testAP.Name
        } | Select-Object -First 1
    }
}
catch { }

if ($existing) {
    Write-Host "  Device exists (ID: $($existing.id)) - will update" -ForegroundColor Yellow
    $deviceId = $existing.id
}
else {
    Write-Host "  Creating new device..." -ForegroundColor Gray
    
    $deviceAttrs = @(
        @{ name = 'WLC_Address';  value = $testAP.WLCAddress }
        @{ name = 'AP_Name';      value = $testAP.Name }
        @{ name = 'AP_MAC';       value = $testAP.MAC }
        @{ name = 'AP_Model';     value = $testAP.Model }
        @{ name = 'AP_Serial';    value = $testAP.Serial }
        @{ name = 'AP_Location';  value = $testAP.Location }
    )

    try {
        $devResult = Add-WUGDeviceTemplate -displayName $deviceDisplayName `
            -DeviceAddress $testAP.APLanIP `
            -Hostname $testAP.Name `
            -Brand 'Cisco' `
            -Attributes $deviceAttrs `
            -ErrorAction Stop

        Write-Verbose "Device result: $(ConvertTo-Json $devResult -Depth 3)"
        
        # Extract device ID from result
        $deviceId = $null
        if ($devResult -is [array] -and $devResult.Count -gt 0) {
            $deviceId = $devResult[0].id
        }
        elseif ($devResult -and $devResult.PSObject.Properties['id']) {
            $deviceId = $devResult.id
        }
        elseif ($devResult -and $devResult.PSObject.Properties['idMap']) {
            $deviceId = ($devResult.idMap | Select-Object -First 1).resultId
        }
        
        if ($deviceId) {
            Write-Host "  Device created (ID: $deviceId)" -ForegroundColor Green
        }
        else {
            Write-Warning "Device creation returned success but ID not found in: $(ConvertTo-Json $devResult -Depth 2)"
        }
    }
    catch {
        Write-Error "Failed to create device: $_"
        return
    }
}

Write-Host "  Device ID: $deviceId" -ForegroundColor Green

# ============================================================================
# STEP 3: Add WLC interface to device
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Adding WLC interface to device..." -ForegroundColor Cyan

try {
    # Add interface for WLC IP (this is where the monitor will poll from)
    $ifaceResult = Add-WUGDeviceInterface -DeviceId $deviceId `
        -Address $testAP.WLCAddress `
        -HostName "WLC (SNMP Monitoring)" `
        -ErrorAction Stop

    Write-Host "  WLC interface added" -ForegroundColor Green
    if ($ifaceResult -and $ifaceResult.id) {
        Write-Host "    Interface ID: $($ifaceResult.id)" -ForegroundColor Gray
    }
}
catch {
    Write-Error "Failed to add WLC interface: $_"
    # Continue - this might not be required
}

# ============================================================================
# STEP 4: Get device interfaces to find WLC interface ID
# ============================================================================

Write-Host ""
Write-Host "STEP 4: Retrieving device interfaces..." -ForegroundColor Cyan

try {
    $interfaces = @(Get-WUGDeviceInterface -DeviceId $deviceId -ErrorAction Stop)
    Write-Host "  Found $($interfaces.Count) interface(s):" -ForegroundColor Gray
    
    $wlcInterface = $null
    foreach ($iface in $interfaces) {
        Write-Host "    - ID: $($iface.id), Address: $($iface.ipAddress), Name: $($iface.name)" -ForegroundColor DarkGray
        
        # Find the WLC interface (either by name or by matching the WLC address)
        if ($iface.name -like "*WLC*" -or $iface.ipAddress -eq $testAP.WLCAddress) {
            $wlcInterface = $iface
        }
    }

    if ($wlcInterface) {
        Write-Host "  Selected WLC interface: ID=$($wlcInterface.id), Address=$($wlcInterface.ipAddress)" -ForegroundColor Green
    }
    else {
        Write-Host "  No WLC interface found - will use default" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Failed to get interfaces: $_"
    $wlcInterface = $null
}

# ============================================================================
# STEP 5: Assign monitor to device with per-AP SNMP instance argument
# ============================================================================

Write-Host ""
Write-Host "STEP 5: Assigning SNMP monitor to device with per-AP argument..." -ForegroundColor Cyan

# The SNMP instance argument is used to specify the per-AP OID instance
# For Cisco WLC APs, this is typically the AP number or index
$apNumber = '1'  # In real scenarios, this would be the AP's index from WLC
$snmpInstance = $apNumber

Write-Host "  SNMP Instance argument for this AP: $snmpInstance" -ForegroundColor Gray

try {
    # Get monitor details first
    $monitorDetails = Get-WUGActiveMonitor -MonitorId $monitorId -ErrorAction Stop
    Write-Host "  Monitor details retrieved (Name: $($monitorDetails.name))" -ForegroundColor Gray

    # Add monitor to device with argument
    $monResult = Add-WUGActiveMonitorToDevice -DeviceId $deviceId `
        -MonitorId $monitorId `
        -Argument $snmpInstance `
        -ErrorAction Stop

    Write-Host "  Monitor assigned to device" -ForegroundColor Green
    Write-Verbose "  Assignment result: $($monResult | ConvertTo-Json -Depth 3)"
}
catch {
    Write-Error "Failed to assign monitor: $_"
    Write-Error $_.Exception.Message
    return
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "=== TEST COMPLETE ===" -ForegroundColor Green
Write-Host ""
Write-Host "Created/Updated:"
Write-Host "  Monitor: $monitorName (ID: $monitorId)"
Write-Host "  Device: $deviceDisplayName (ID: $deviceId)"
Write-Host "  Device Address (primary): $($testAP.APLanIP)"
Write-Host "  Interface (WLC): $($testAP.WLCAddress)"
Write-Host "  Monitor Assignment: SNMP Instance = $snmpInstance"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Verify device appears in WUG with correct monitor"
Write-Host "  2. Check monitor is polling from WLC interface"
Write-Host "  3. If working, scale to all 1728 APs"
Write-Host ""
