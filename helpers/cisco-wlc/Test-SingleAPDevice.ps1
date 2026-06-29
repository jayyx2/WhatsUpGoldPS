#requires -Version 5.1
<#
.SYNOPSIS
    Minimal test: Create ONE AP device with ONE SNMP monitor to debug 500 errors.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WLCAddress,

    [Parameter()]
    [string]$WUGServer = 'https://192.168.74.74:9644'
)

# Load module
if (-not (Get-Command -Name 'Get-WUGAPIResponse' -ErrorAction SilentlyContinue)) {
    try {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
        if (Test-Path $repoPsd1) {
            Import-Module $repoPsd1 -Force -ErrorAction Stop
        }
        else {
            Import-Module WhatsUpGoldPS -ErrorAction Stop
        }
    }
    catch {
        Write-Error "Could not load WhatsUpGoldPS module. $_"
        return
    }
}

# Connect to WUG
Write-Host "Connecting to WUG..." -ForegroundColor Cyan
if (-not $global:WhatsUpServerBaseURI) {
    Connect-WUGServer -serverUri $WUGServer -IgnoreSSLErrors
}

Write-Host "Connected: $global:WhatsUpServerBaseURI" -ForegroundColor Green

# ============================================================================
# STEP 1: Create ONE SNMP active monitor using Add-WUGMonitorTemplate
# ============================================================================

Write-Host "`n=== Creating SNMP Active Monitor ===" -ForegroundColor Cyan

$monitorName = "SNMP AP Admin Status - Test"

# Check if it already exists
$existing = $null
try {
    $found = @(Get-WUGActiveMonitor -Search $monitorName)
    $existing = $found | Where-Object { $_.name -eq $monitorName } | Select-Object -First 1
}
catch { 
    Write-Verbose "Monitor search error: $_"
}

if ($existing) {
    Write-Host "Monitor already exists (ID: $($existing.id))" -ForegroundColor Yellow
}
else {
    Write-Host "Creating monitor '$monitorName' using Add-WUGMonitorTemplate..." -ForegroundColor Gray
    
    try {
        # Build SNMP active monitor template structure
        $propertyBags = @(
            @{ name = 'SNMP:OID';            value = '1.3.6.1.4.1.9.9.513.1.1.1.1' }
            @{ name = 'SNMP:Instance';       value = '' }
            @{ name = 'SNMP:CheckType';      value = '0' }
            @{ name = 'SNMP:Constant-Value'; value = '1' }
            @{ name = 'Cred:Type';           value = '1,2,4' }
        )

        $activeMonitorTemplate = @{
            templateId      = 'snmp_test_1'
            name            = $monitorName
            description     = "Test SNMP monitor for single AP"
            useInDiscovery  = $false
            monitorTypeInfo = @{
                classId  = 'd6d02d69-a418-483a-93ea-20dd2af2d135'
                baseType = 'active'
            }
            propertyBags    = $propertyBags
        }

        # Add-WUGMonitorTemplate handles the API call internally with SSL bypass
        $result = Add-WUGMonitorTemplate -ActiveMonitors @($activeMonitorTemplate) -ErrorAction Stop
        
        Write-Host "Monitor created successfully" -ForegroundColor Green
        Write-Verbose "Result: $($result | ConvertTo-Json -Depth 3)"
    }
    catch {
        Write-Error "Failed to create monitor: $_"
        Write-Error $_.Exception.Message
        return
    }
}

# Retrieve the monitor ID
Write-Host "Retrieving monitor ID for '$monitorName'..." -ForegroundColor DarkGray
$monitors = @(Get-WUGActiveMonitor -Search $monitorName)
Write-Verbose "Found $($monitors.Count) monitor(s) matching search term"

$monitorId = $null
if ($monitors) {
    foreach ($m in $monitors) {
        Write-Verbose "  - ID: $($m.id), Name: $($m.name)"
    }
    $mon = $monitors | Where-Object { $_.name -eq $monitorName } | Select-Object -First 1
    if ($mon) { $monitorId = $mon.id }
}

if (-not $monitorId) {
    Write-Warning "Could not retrieve monitor ID by exact name. Checking all SNMP monitors..."
    $allSnmp = @(Get-WUGActiveMonitor -Search 'SNMP')
    Write-Verbose "Found $($allSnmp.Count) SNMP monitors total"
    foreach ($m in $allSnmp | Select-Object -Last 5) {
        Write-Verbose "  - $($m.id): $($m.name)"
    }
    # Try to find by partial name
    $mon = $allSnmp | Where-Object { $_.name -like "*Test*" } | Select-Object -Last 1
    if ($mon) { $monitorId = $mon.id }
}

if (-not $monitorId) {
    Write-Error "Failed to retrieve monitor ID after creation"
    return
}

Write-Host "Monitor ID: $monitorId / Name: $monitorName" -ForegroundColor Green

# ============================================================================
# STEP 2: Create ONE test device
# ============================================================================

Write-Host "`n=== Creating Test AP Device ===" -ForegroundColor Cyan

$testDeviceName = "TEST-AP-001"
$testDeviceIP = "192.168.1.100"

# Check if already exists
$existing = $null
try {
    $found = @(Get-WUGDevice -SearchValue $testDeviceName)
    $existing = $found | Where-Object { $_.displayName -eq "$testDeviceName (AP)" -or $_.hostName -eq $testDeviceName } | Select-Object -First 1
}
catch { }

if ($existing) {
    Write-Host "Device already exists (ID: $($existing.id))" -ForegroundColor Yellow
    Write-Host "Skipping creation."
}
else {
    Write-Host "Creating device '$testDeviceName' @ $testDeviceIP..." -ForegroundColor Gray
    
    # Create custom attributes
    $attributes = @(
        @{ name = 'WLC_Address';  value = $WLCAddress }
        @{ name = 'AP_Location';  value = 'TEST' }
    )

    $splat = @{
        displayName            = "$testDeviceName (AP)"
        DeviceAddress          = $testDeviceIP
        Hostname               = $testDeviceName
        Brand                  = 'Cisco'
        Note                   = "Test AP for single-device validation"
        Attributes             = $attributes
        ActiveMonitors         = @($monitorName)
        NoDefaultActiveMonitor = $true
    }

    Write-Verbose "Device splat: $(ConvertTo-Json $splat -Depth 5)"

    try {
        $devResult = Add-WUGDeviceTemplate @splat
        
        Write-Host "Device creation result:" -ForegroundColor Gray
        Write-Verbose ($devResult | ConvertTo-Json -Depth 5)

        # Check for errors
        if ($devResult -is [array] -or ($devResult -and $devResult.PSObject.Properties['messages'])) {
            Write-Error "Device creation returned error"
            if ($devResult -is [array]) {
                foreach ($e in $devResult) {
                    Write-Error ($e | ConvertTo-Json)
                }
            }
            else {
                Write-Error ($devResult | ConvertTo-Json)
            }
            return
        }

        # Extract device ID
        $newDeviceId = $null
        if ($devResult.idMap) {
            $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId
        }
        elseif ($devResult.PSObject.Properties['resultId']) {
            $newDeviceId = $devResult.resultId
        }

        if ($newDeviceId) {
            Write-Host "Device created successfully (ID: $newDeviceId)" -ForegroundColor Green
        }
        else {
            Write-Warning "Device creation returned success but no device ID found"
            Write-Verbose ($devResult | ConvertTo-Json)
        }
    }
    catch {
        Write-Error "Exception during device creation: $_"
        Write-Error $_.Exception.Message
        if ($_.Exception.Response) {
            Write-Error "Response Content: $($_.Exception.Response.Content)"
        }
        return
    }
}

Write-Host "`n=== Test Complete ===" -ForegroundColor Cyan
