#requires -Version 5.1

<#
.SYNOPSIS
    Exports Cisco WLC Access Points as devices to WhatsUp Gold with per-AP SNMP monitors.

.DESCRIPTION
    Reads WLC discovery output (AP inventory from JSONL) and creates/updates AP devices in WhatsUp Gold.
    Each AP becomes a device with:
    - SNMP active monitor for AP admin status (OID 1.3.6.1.4.1.9.9.513.1.1.1.1.38 with per-AP instance)
    - Custom device attributes: WLC_Address, AP_Name, AP_MAC, AP_Model, AP_Serial, AP_Location, etc.

.PARAMETER InputDirectory
    Directory containing discovery output (full/ subdirectory with JSONL files).
    Default: $env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Output\full

.PARAMETER WLCAddress
    Primary WLC IP address (used for all AP SNMP monitors).

.PARAMETER WUGServer
    WhatsUp Gold server URI. Default: https://192.168.74.74:9644

.PARAMETER WUGCredential
    Credentials for WUG API connection.

.PARAMETER DeviceGroupId
    Device group ID for new AP devices. Default: 0 (Static group)

.PARAMETER SNMPCredentialName
    Name of the SNMP credential in WUG to assign to AP devices. If not specified,
    no SNMP credential is assigned (useful if the device inherits one).

.EXAMPLE
    .\Export-CiscoWLCAPDevicesToWUG.ps1 -InputDirectory 'C:\temp\wlc-output\full' `
        -WLCAddress 192.168.1.100 -WUGServer 'https://wug.lab:9644'

.EXAMPLE
    .\Export-CiscoWLCAPDevicesToWUG.ps1 -WLCAddress 192.168.75.33 `
        -SNMPCredentialName 'SNMP v2 - public'

.NOTES
    Requires: WhatsUpGoldPS module, active WUG connection
    Encoding: UTF-8 with BOM
    Author: WhatsUpGoldPS Discovery Framework
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputDirectory,

    [Parameter(Mandatory)]
    [string]$WLCAddress,

    [Parameter()]
    [string]$WUGServer,

    [Parameter()]
    [pscredential]$WUGCredential,

    [Parameter()]
    [int]$DeviceGroupId = 0,

    [Parameter()]
    [string]$SNMPCredentialName,

    [Parameter()]
    [int]$LimitAPs = 10,

    [Parameter()]
    [switch]$DryRun
)

# ============================================================================
# Module / dependency loading
# ============================================================================

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

# Resolve input directory
if ([string]::IsNullOrWhiteSpace($InputDirectory)) {
    $base = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    $InputDirectory = Join-Path $base 'full'
}

if (-not (Test-Path $InputDirectory)) {
    Write-Error "Input directory not found: $InputDirectory"
    return
}

Write-Verbose "Using input directory: $InputDirectory"
Write-Verbose "WLC Address: $WLCAddress"

# ============================================================================
# STEP 1: Read AP discovery data from JSONL
# ============================================================================

Write-Host ""
Write-Host "Loading AP discovery data..." -ForegroundColor Cyan

$apItems = @()
# Read from wireless-ap-inventory-summary.json (produced by Build-Wireless-Summaries)
# This is in the summary subdirectory of the input directory's parent
$baseDir = Split-Path $InputDirectory -Parent
$summaryDir = Join-Path $baseDir 'summary'
$apInventoryFile = Join-Path $summaryDir 'wireless-ap-inventory-summary.json'

if (-not (Test-Path $apInventoryFile)) {
    Write-Warning "No wireless-ap-inventory-summary.json found at $apInventoryFile"
    Write-Warning "Please run discovery first to generate the AP inventory"
    return
}

Write-Verbose "Reading $apInventoryFile"
try {
    $apItems = @(Get-Content -Path $apInventoryFile -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}
catch {
    Write-Warning "Error reading AP inventory: $_"
    return
}

$apCount = $apItems.Count
Write-Host "  Found $apCount AP(s)" -ForegroundColor Green

if ($apCount -eq 0) {
    Write-Warning "No AP items found. Exiting."
    return
}

# ============================================================================
# STEP 2: Build device plan for APs
# ============================================================================

Write-Host ""
Write-Host "Building AP device plan..." -ForegroundColor Cyan

# Sanitize AP names: replace invalid hostname characters
function Sanitize-HostName {
    param([string]$Name)
    # Replace invalid hostname characters (/, \, :, etc.) with hyphens
    return $Name -replace '[/\\:*?"<>|]', '-'
}

$devicePlan = @{}

foreach ($ap in $apItems) {
    # Use properties from AP inventory JSON: APName, APMac
    $rawName = if ($ap.APName -and $ap.APName -ne '') { $ap.APName } else { $ap.APMac }
    $sanitizedName = Sanitize-HostName -Name $rawName
    
    $apKey = if ($ap.APMac) { "AP-$($ap.APMac)" } else { "AP-$sanitizedName" }
    $displayName = $sanitizedName
    $apIP = if ($ap.APIPAddress -and $ap.APIPAddress -ne '') { $ap.APIPAddress } else { $WLCAddress }

    if ($devicePlan.Keys -notcontains $apKey) {
        $devicePlan[$apKey] = @{
            Name      = $displayName
            IP        = $apIP
            WLCIP     = $WLCAddress
            Type      = 'AccessPoint'
            APMac     = $ap.APMac
            APIndex   = if ($ap.IndexSuffix) { $ap.IndexSuffix } else { $ap.APMac }  # Per-AP SNMP instance
            Attrs     = @{}
            Items     = [System.Collections.Generic.List[object]]::new()
        }
    }

    $dev = $devicePlan[$apKey]

    # Collect attributes from AP inventory JSON
    $dev.Attrs['AP_Name']        = $rawName  # Store original name in attribute
    $dev.Attrs['AP_MAC']         = if ($ap.APMac) { $ap.APMac } else { 'N/A' }
    $dev.Attrs['AP_Uptime']      = if ($ap.ApUptime) { $ap.ApUptime } else { '' }
    $dev.Attrs['AP_AdminStatus'] = if ($ap.AdminStatus) { $ap.AdminStatus } else { '' }
    $dev.Attrs['AP_PowerStatus'] = if ($ap.PowerStatus) { $ap.PowerStatus } else { '' }
    $dev.Attrs['AP_CpuCurrent']  = if ($ap.CpuCurrentPct) { "$($ap.CpuCurrentPct)%" } else { '' }
    $dev.Attrs['AP_CpuAvg']      = if ($ap.CpuAvgPct) { "$($ap.CpuAvgPct)%" } else { '' }
    $dev.Attrs['AP_MemCurrent']  = if ($ap.MemCurrentPct) { "$($ap.MemCurrentPct)%" } else { '' }
    $dev.Attrs['AP_MemAvg']      = if ($ap.MemAvgPct) { "$($ap.MemAvgPct)%" } else { '' }
    $dev.Attrs['AP_PrimaryController'] = if ($ap.PrimaryControllerAddress) { $ap.PrimaryControllerAddress } else { '' }
    $dev.Attrs['WLC_Address']    = $WLCAddress
    $dev.Attrs['AP_IPAddress']   = if ($ap.APIPAddress) { $ap.APIPAddress } else { '' }
    $dev.Attrs['AP_SNMPInstance'] = if ($ap.IndexSuffix) { $ap.IndexSuffix } else { '1' }  # Store instance for reference

    # Store SNMP instance on device for easy access during monitor assignment
    $dev.SNMPInstance = if ($ap.IndexSuffix) { $ap.IndexSuffix } else { '1' }

    # --- Monitor items ---
    # Active: Shared across all APs (instance passed per-device via Argument)
    
    # Active: AP Admin Status (SNMP health check - up if admin status = 1)
    $dev.Items.Add([PSCustomObject]@{
        Name        = "SNMP AP Admin Status"
        ItemType    = 'ActiveMonitor'
        MonitorType = 'SNMP'
    })
}

Write-Host "  Created device plan for $($devicePlan.Count) unique AP(s)" -ForegroundColor Green

# --- Apply limit if specified (for testing) ---
if ($LimitAPs -gt 0 -and $LimitAPs -lt $devicePlan.Count) {
    $limitedPlan = @{}
    $count = 0
    foreach ($key in @($devicePlan.Keys)) {
        if ($count -ge $LimitAPs) { break }
        $limitedPlan[$key] = $devicePlan[$key]
        $count++
    }
    $devicePlan = $limitedPlan
    Write-Host "  Limited to first $LimitAPs AP(s) for testing" -ForegroundColor Yellow
}

# ============================================================================
# DRY RUN MODE: Show plan without creating anything
# ============================================================================

if ($DryRun) {
    Write-Host ""
    Write-Host "=== DRY RUN MODE - Plan Preview ===" -ForegroundColor Yellow
    Write-Host "Would create $($devicePlan.Count) AP device(s) with the following monitors:" -ForegroundColor Cyan
    Write-Host ""
    
    $uniqueActNames = @()
    $uniquePerfNames = @()
    foreach ($key in @($devicePlan.Keys)) {
        $dev = $devicePlan[$key]
        foreach ($item in @($dev.Items)) {
            if ($item.ItemType -eq 'ActiveMonitor' -and $item.Name -notin $uniqueActNames) {
                $uniqueActNames += $item.Name
            }
            elseif ($item.ItemType -eq 'PerformanceMonitor' -and $item.Name -notin $uniquePerfNames) {
                $uniquePerfNames += $item.Name
            }
        }
    }
    
    Write-Host "Active Monitors to create (SHARED):" -ForegroundColor Green
    foreach ($actName in $uniqueActNames) {
        Write-Host "  - $actName (OID: 1.3.6.1.4.1.9.9.513.1.1.1.1.38, instance per-AP via Argument)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "Devices to create:" -ForegroundColor Green
    foreach ($key in @($devicePlan.Keys)) {
        $dev = $devicePlan[$key]
        Write-Host "  - $($dev.Name) @ $($dev.IP) (with $($dev.Items.Count) monitor assignments)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "=== End DRY RUN MODE ===" -ForegroundColor Yellow
    Write-Host "Run again WITHOUT -DryRun to create these devices and monitors." -ForegroundColor Cyan
    Write-Host ""
    return
}

# ============================================================================
# STEP 3: Connect to WUG
# ============================================================================

Write-Host ""
Write-Host "Connecting to WhatsUp Gold..." -ForegroundColor Cyan

# Use existing connection if available; otherwise use vaulted credentials (no-prompt mode)
if (-not $global:WhatsUpServerBaseURI) {
    try {
        if ($WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors -ErrorAction Stop
        }
        else {
            # Use vaulted WUG server credentials; use -UseVault to prevent interactive prompts
            # If this param doesn't exist, fallback to regular connection
            $ConnectParams = @{ ErrorAction = 'Stop' }
            if ($WUGServer) { $ConnectParams['serverUri'] = $WUGServer }
            Connect-WUGServer @ConnectParams
        }
    }
    catch {
        Write-Error "Failed to connect to WhatsUp Gold: $_"
        Write-Error "Please ensure WUG connection is configured. Run: Connect-WUGServer"
        return
    }
}

if (-not $global:WhatsUpServerBaseURI) {
    Write-Error "No WhatsUp Gold connection established. Please use Connect-WUGServer first."
    return
}

# Capture the connected server URI and extract server address for reconnect (URI -> server address only)
$connectedServerURI = $global:WhatsUpServerBaseURI
# Extract server address from URI: "https://192.168.74.74:9644" -> "192.168.74.74"
$connectedServerAddress = if ($connectedServerURI -match '://([^/:]+)') { $Matches[1] } else { $connectedServerURI }

Write-Host "  Connected to $connectedServerURI" -ForegroundColor Green

# ============================================================================
# STEP 4: Create SNMP active monitor in WUG library
# ============================================================================

Write-Host ""
Write-Host "Creating SNMP monitors in WUG library..." -ForegroundColor Cyan

$stats = @{
    HealthCreated  = 0
    HealthSkipped  = 0
    HealthFailed   = 0
    DevicesCreated = 0
    DevicesFound   = 0
    AttrsUpdated   = 0
}

# ---- 4a. Deduplicate active monitors across all devices --------------------
$uniqueActiveMonitors = @{}
foreach ($key in @($devicePlan.Keys)) {
    $dev = $devicePlan[$key]
    foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
        $actName = $actItem.Name
        if (-not $actName -or $uniqueActiveMonitors.ContainsKey($actName)) { continue }
        $uniqueActiveMonitors[$actName] = $actItem
    }
}

# ---- 4b. Get ALL active monitors in ONE call (like we did with devices) ------
$existingActiveNames = @{}  # name -> library ID
$allActiveMonitors = @()

try {
    # Fetch all active monitors without filter
    $allActiveMonitors = @(Get-WUGActiveMonitor -ErrorAction SilentlyContinue)
    Write-Verbose "Retrieved $($allActiveMonitors.Count) active monitors from library"
    
    # Build lookup by name
    foreach ($mon in $allActiveMonitors) {
        $monName = if ($mon.PSObject.Properties['name']) { $mon.name } else { $mon.TemplateName }
        if ($monName) {
            $monId = if ($mon.PSObject.Properties['id']) { $mon.id } elseif ($mon.PSObject.Properties['TemplateId']) { $mon.TemplateId } else { $null }
            if ($monId -and -not $existingActiveNames.ContainsKey($monName)) {
                $existingActiveNames[$monName] = $monId
            }
        }
    }
    Write-Verbose "Built active monitor lookup with $($existingActiveNames.Count) entries"
}
catch {
    Write-Warning "Could not retrieve active monitors: $_"
}

$toCreateActive = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
$stats.HealthSkipped = $uniqueActiveMonitors.Count - $toCreateActive.Count

# ---- 4c. Create missing active monitors (one at a time) ----------------------
if ($toCreateActive.Count -gt 0) {
    Write-Host "    Creating $($toCreateActive.Count) new active monitor(s)..." -ForegroundColor DarkGray

    foreach ($actName in $toCreateActive) {
        try {
            # Try to create the monitor
            $monResult = Add-WUGActiveMonitor -Type SNMP `
                -Name $actName `
                -SnmpOID '1.3.6.1.4.1.9.9.513.1.1.1.1.38' `
                -SnmpCheckType 'constant' `
                -SnmpValue '1' `
                -Timeout 10 `
                -ErrorAction Stop
            
            # If we got a result, use it; otherwise assume the monitor exists by name
            if ($monResult) {
                $existingActiveNames[$actName] = $monResult
                $stats.HealthCreated++
                Write-Verbose "Created monitor '$actName' (ID: $monResult)"
            }
            else {
                # Monitor likely already existed (Add-WUGActiveMonitor skipped creation but returned $null)
                # Just use the name as the monitor identifier
                $existingActiveNames[$actName] = $actName
                $stats.HealthSkipped++
                Write-Verbose "Monitor '$actName' already exists or was skipped"
            }
        }
        catch {
            # If error mentions "already exists", still mark it as found
            if ($_ -match 'already exists|Skipping|Skip') {
                $existingActiveNames[$actName] = $actName
                $stats.HealthSkipped++
                Write-Verbose "Monitor '$actName' already exists (caught in error)"
            }
            else {
                Write-Warning "Failed to create monitor '$actName': $_"
                $stats.HealthFailed++
            }
        }
    }
}
Write-Host "    Active monitors: $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor DarkGray

# ---- 4d. Final check: any monitors still not found? ------
$missingAct = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
if ($missingAct.Count -gt 0) {
    Write-Verbose "Re-loading active monitor library to find $($missingAct.Count) missing monitor(s)..."
    try {
        $allActiveMonitors = @(Get-WUGActiveMonitor -ErrorAction SilentlyContinue)
        foreach ($mon in $allActiveMonitors) {
            foreach ($actName in $missingAct) {
                if ($existingActiveNames.ContainsKey($actName)) { continue }
                $monName = if ($mon.PSObject.Properties['name']) { $mon.name } else { $mon.TemplateName }
                if ($monName -eq $actName) {
                    $monId = if ($mon.PSObject.Properties['id']) { $mon.id } elseif ($mon.PSObject.Properties['TemplateId']) { $mon.TemplateId } else { $null }
                    if ($monId) {
                        $existingActiveNames[$actName] = $monId
                    }
                }
            }
        }
    }
    catch { }
}

# ============================================================================
# STEP 5: Check for existing devices in WUG (bulk lookup - ONE API call)
# ============================================================================

Write-Host ""
Write-Host "  Checking for existing devices..." -ForegroundColor Cyan

# ---- 5a. Get ALL WUG devices in ONE call (not per-device search) ------
$allWUGDevices = @()
try {
    $allWUGDevices = @(Get-WUGDevice -View 'basic' -ErrorAction Stop)
    Write-Verbose "Retrieved $($allWUGDevices.Count) devices from WUG"
}
catch {
    Write-Warning "Failed to retrieve device list from WUG: $_"
    $allWUGDevices = @()
}

# ---- 5b. Build local lookup hashtable (instant search, zero API calls) -----
$deviceLookup = @{}  # displayName -> id, hostName -> id

foreach ($wugDev in $allWUGDevices) {
    # Index by displayName
    if ($wugDev.displayName -and -not $deviceLookup.ContainsKey($wugDev.displayName)) {
        $deviceLookup[$wugDev.displayName] = $wugDev.id
    }
    # Index by hostName
    if ($wugDev.hostName -and -not $deviceLookup.ContainsKey($wugDev.hostName)) {
        $deviceLookup[$wugDev.hostName] = $wugDev.id
    }
    # Index by (AP) variant
    if ($wugDev.displayName) {
        $apVariant = "$($wugDev.displayName) (AP)"
        if (-not $deviceLookup.ContainsKey($apVariant)) {
            $deviceLookup[$apVariant] = $wugDev.id
        }
    }
}
Write-Verbose "Built device lookup table with $($deviceLookup.Count) entries"

# ---- 5c. Check each AP device (all lookups are now instant hashtable searches) -----
$wugDeviceMap    = @{}   # key -> deviceId (all devices)
$existingDevices = @{}   # key -> deviceId (already in WUG)
$newDeviceKeys   = [System.Collections.Generic.List[string]]::new()
$deviceKeys      = @($devicePlan.Keys)
$devTotal        = $deviceKeys.Count

foreach ($key in $deviceKeys) {
    $dev = $devicePlan[$key]
    $displayName = "$($dev.Name) (AP)"

    $deviceId = $null

    # Try multiple lookup keys (instant hashtable access - no API call)
    if ($deviceLookup.ContainsKey($dev.Name)) {
        $deviceId = $deviceLookup[$dev.Name]
    }
    elseif ($deviceLookup.ContainsKey($displayName)) {
        $deviceId = $deviceLookup[$displayName]
    }

    if ($deviceId) {
        $existingDevices[$key] = $deviceId
        $wugDeviceMap[$key] = $deviceId
        $stats.DevicesFound++
    }
    else {
        $newDeviceKeys.Add($key)
    }
}

Write-Host "    Found $($stats.DevicesFound) existing, $($newDeviceKeys.Count) new to create" -ForegroundColor DarkGray

# ============================================================================
# STEP 6: Create new devices via Add-WUGDeviceTemplate
# ============================================================================

if ($newDeviceKeys.Count -gt 0) {
    Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow
    $devIdx = 0
    $devicesCreatedSinceReconnect = 0
    $reconnectInterval = 5  # Reconnect after every 5 devices to refresh token frequently

    foreach ($key in $newDeviceKeys) {
        $devIdx++
        $dev = $devicePlan[$key]
        $addIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
        $displayName = "$($dev.Name) (AP)"

        # Periodic token refresh: reconnect after every N devices
        if ($devicesCreatedSinceReconnect -ge $reconnectInterval) {
            Write-Verbose "Token refresh: Reconnecting to WUG after $reconnectInterval devices..."
            try {
                Disconnect-WUGServer -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Milliseconds 500
                
                if ($WUGCredential) {
                    Connect-WUGServer -serverUri $connectedServerAddress -Credential $WUGCredential -ErrorAction Stop | Out-Null
                } else {
                    Connect-WUGServer -serverUri $connectedServerAddress -ErrorAction Stop | Out-Null
                }
                $devicesCreatedSinceReconnect = 0
                Write-Verbose "Session refreshed successfully"
            }
            catch {
                Write-Warning "Failed to refresh session: $_"
            }
        }

        Write-Progress -Activity 'Creating devices' `
            -Status "$devIdx / $($newDeviceKeys.Count) - $displayName" `
            -PercentComplete ([Math]::Round(($devIdx / $newDeviceKeys.Count) * 100))

        # Build attributes array
        $devAttrs = @()
        foreach ($attrName in $dev.Attrs.Keys) {
            $attrVal = $dev.Attrs[$attrName]
            if ($attrVal) { $devAttrs += @{ name = $attrName; value = "$attrVal" } }
        }

        # Collect unique active monitor names that exist in library
        $actNames = @()
        $seenActNames = @{}
        foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
            if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name) -and -not $seenActNames.ContainsKey($actItem.Name)) {
                $actNames += $actItem.Name
                $seenActNames[$actItem.Name] = $true
            }
        }

        # Skip devices with no monitors to assign
        if ($actNames.Count -eq 0) {
            Write-Verbose "Skipping '$displayName' - no monitors to assign."
            continue
        }

        $devNote = "Cisco WLC AP (auto-created by CiscoWLC discovery)"

        $splat = @{
            displayName            = $displayName
            DeviceAddress          = $addIP
            Hostname               = $dev.Name
            Brand                  = 'Cisco'
            Note                   = $devNote
            NoDefaultActiveMonitor = $true
        }

        if ($actNames.Count -gt 0) { 
            $splat['ActiveMonitors'] = $actNames
        }
        if ($SNMPCredentialName) { $splat['CredentialSNMPv2'] = $SNMPCredentialName }

        try {
            $devResult = Add-WUGDeviceTemplate @splat -ErrorAction Stop

            # Detect error arrays: Add-WUGDeviceTemplate returns $result.data.errors
            # (array of objects with .templateId/.messages) on failure, or
            # $result.data (object with .idMap/.errors/.operations/.successful) on success.
            $isErrorResult = $false
            if ($devResult -is [array]) {
                # Error array returned — each element has .templateId and .messages
                $isErrorResult = $true
            } elseif ($devResult -and $devResult.PSObject.Properties['messages']) {
                # Single error object
                $isErrorResult = $true
            }

            if ($devResult -and -not $isErrorResult) {
                $newDeviceId = $null
                if ($devResult.idMap) {
                    $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId
                } elseif ($devResult.PSObject.Properties['resultId']) {
                    $newDeviceId = $devResult.resultId
                }
                if ($newDeviceId) {
                    $wugDeviceMap[$key] = $newDeviceId
                    $stats.DevicesCreated++
                    $devicesCreatedSinceReconnect++
                    Write-Verbose "Created device '$displayName' (ID: $newDeviceId)"
                } else {
                    Write-Warning "Device '$displayName' — API returned success but no device ID."
                }
            } else {
                $errMsgs = @()
                if ($devResult -is [array]) {
                    foreach ($e in $devResult) {
                        if ($e.PSObject.Properties['messages']) { $errMsgs += ($e.messages -join '; ') }
                    }
                } elseif ($devResult -and $devResult.PSObject.Properties['messages']) {
                    $errMsgs += ($devResult.messages -join '; ')
                }
                $errText = if ($errMsgs.Count -gt 0) { $errMsgs -join ' | ' } else { 'Unknown error (no details returned)' }
                
                # Detect token expiration (HTTP 500 errors may indicate expired token)
                if ($errText -match '500|Internal Server Error|token|authorization|auth|expired|invalid') {
                    Write-Warning "Detected possible token expiration. Attempting to refresh..."
                    try {
                        if ($WUGCredential) {
                            Connect-WUGServer -serverUri $connectedServerAddress -Credential $WUGCredential -ErrorAction Stop | Out-Null
                        } else {
                            Connect-WUGServer -serverUri $connectedServerAddress -ErrorAction Stop | Out-Null
                        }
                        Write-Host "Token refreshed. Retrying device creation..." -ForegroundColor Yellow
                        
                        # Retry the device creation
                        $devResult2 = $null
                        try {
                            $devResult2 = Add-WUGDeviceTemplate @splat -ErrorAction Stop
                            $isErrorResult2 = $devResult2 -is [array] -or ($devResult2 -and $devResult2.PSObject.Properties['messages'])
                            if ($devResult2 -and -not $isErrorResult2) {
                                $newDeviceId = if ($devResult2.idMap) { 
                                    ($devResult2.idMap | Select-Object -First 1).resultId 
                                } elseif ($devResult2.PSObject.Properties['resultId']) { 
                                    $devResult2.resultId 
                                }
                                if ($newDeviceId) {
                                    $wugDeviceMap[$key] = $newDeviceId
                                    $stats.DevicesCreated++
                                    $devicesCreatedSinceReconnect++
                                    Write-Verbose "Created device '$displayName' (ID: $newDeviceId) after token refresh"
                                }
                            }
                        }
                        catch {
                            Write-Warning "Retry failed for device '$displayName': $_"
                        }
                    }
                    catch {
                        Write-Warning "Failed to refresh token during error recovery: $_"
                    }
                } else {
                    Write-Warning "Failed to create device '$displayName': $errText"
                }
            }
        }
        catch {
            $errMsg = "$($_.Exception.Message)"
            Write-Warning "Error creating device '$displayName': $errMsg"
            
            # Detect token expiration (HTTP 500 errors may indicate expired token)
            if ($errMsg -match '500|Internal Server Error|token|authorization|auth|expired|invalid|Unauthorized') {
                Write-Host "HTTP 500 detected. Disconnecting and reconnecting to refresh session..." -ForegroundColor Yellow
                try {
                    # Full disconnect-reconnect cycle to clear bad session
                    Disconnect-WUGServer -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Milliseconds 500  # Brief pause to ensure disconnect completes
                    
                    if ($WUGCredential) {
                        Connect-WUGServer -serverUri $connectedServerAddress -Credential $WUGCredential -ErrorAction Stop | Out-Null
                    } else {
                        Connect-WUGServer -serverUri $connectedServerAddress -ErrorAction Stop | Out-Null
                    }
                    Write-Host "Session refreshed. Retrying device creation..." -ForegroundColor Green
                    
                    # Retry the device creation
                    try {
                        $devResult2 = Add-WUGDeviceTemplate @splat -ErrorAction Stop
                        $isErrorResult2 = $devResult2 -is [array] -or ($devResult2 -and $devResult2.PSObject.Properties['messages'])
                        if ($devResult2 -and -not $isErrorResult2) {
                            $newDeviceId = if ($devResult2.idMap) { 
                                ($devResult2.idMap | Select-Object -First 1).resultId 
                            } elseif ($devResult2.PSObject.Properties['resultId']) { 
                                $devResult2.resultId 
                            }
                            if ($newDeviceId) {
                                $wugDeviceMap[$key] = $newDeviceId
                                $stats.DevicesCreated++
                                $devicesCreatedSinceReconnect = 0  # Reset counter after successful reconnect
                                Write-Host "✓ Retry successful: Created device '$displayName' (ID: $newDeviceId)" -ForegroundColor Green
                            }
                        }
                    }
                    catch {
                        Write-Warning "Retry failed for device '$displayName': $($_.Exception.Message)"
                    }
                }
                catch {
                    Write-Warning "Failed to refresh session: $($_.Exception.Message)"
                }
            }
        }
    }

    Write-Progress -Activity 'Creating devices' -Completed
    Write-Host "    Devices: $($stats.DevicesCreated) created" -ForegroundColor Green
}

# ============================================================================
# STEP 6b: Add WLC interface on new devices that have their own LAN IP
# ============================================================================

$newlyCreatedKeys = @($newDeviceKeys | Where-Object { $wugDeviceMap.ContainsKey($_) })
$devicesWithLanIP = @($newlyCreatedKeys | Where-Object {
    $d = $devicePlan[$_]
    $d.IP -ne $WLCAddress -and $d.WLCIP
})

if ($devicesWithLanIP.Count -gt 0) {
    Write-Host "  Adding WLC interface to $($devicesWithLanIP.Count) device(s) with LAN IPs..." -ForegroundColor Cyan
    foreach ($key in $devicesWithLanIP) {
        $deviceId = $wugDeviceMap[$key]
        $dev = $devicePlan[$key]
        try {
            Add-WUGDeviceInterface -DeviceId $deviceId -Address $dev.WLCIP -HostName $dev.WLCIP -ErrorAction Stop | Out-Null
            Write-Verbose "Added WLC interface ($($dev.WLCIP)) to device $deviceId"
        }
        catch {
            Write-Verbose "Could not add WLC interface to device $deviceId`: $_"
        }
    }
}

# ============================================================================
# STEP 7: Assign monitors with per-AP SNMP instances & comments to new devices
# ============================================================================

if ($newlyCreatedKeys.Count -gt 0) {
    Write-Host "  Assigning SNMP monitors with per-AP instances..."-ForegroundColor Cyan
    $monAssignIdx = 0

    foreach ($key in $newlyCreatedKeys) {
        $monAssignIdx++
        $deviceId = $wugDeviceMap[$key]
        $dev = $devicePlan[$key]
        $displayName = "$($dev.Name) (AP)"

        Write-Progress -Activity 'Assigning monitors to new devices' `
            -Status "$monAssignIdx / $($newlyCreatedKeys.Count) - $displayName" `
            -PercentComplete ([Math]::Round(($monAssignIdx / $newlyCreatedKeys.Count) * 100))

        # Assign active monitors with per-AP SNMP instance and comment
        foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
            if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) {
                $monTemplateId = $existingActiveNames[$actItem.Name]
                $snmpInstance = if ($dev.SNMPInstance) { $dev.SNMPInstance } else { '1' }
                $monComment = "$($dev.APMac)"
                
                try {
                    $monAssignResult = Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $monTemplateId -Argument $snmpInstance -Comment $monComment -ErrorAction Stop
                    Write-Verbose "Assigned monitor '$($actItem.Name)' to device $deviceId with instance=$snmpInstance and comment"
                }
                catch {
                    if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                        Write-Warning "Failed to assign monitor '$($actItem.Name)' to device $deviceId`: $_"
                    }
                }
            }
        }
    }

    Write-Progress -Activity 'Assigning monitors to new devices' -Completed
}

# ============================================================================
# STEP 8: Set device attributes on newly created devices
# ============================================================================

if ($newlyCreatedKeys.Count -gt 0) {
    Write-Host "  Setting device attributes on newly created devices..." -ForegroundColor Cyan
    $attrIdx = 0

    foreach ($key in $newlyCreatedKeys) {
        $attrIdx++
        $deviceId = $wugDeviceMap[$key]
        $dev = $devicePlan[$key]
        $displayName = "$($dev.Name) (AP)"

        Write-Progress -Activity 'Setting attributes on new devices' `
            -Status "$attrIdx / $($newlyCreatedKeys.Count) - $displayName" `
            -PercentComplete ([Math]::Round(($attrIdx / $newlyCreatedKeys.Count) * 100))

        foreach ($attrName in $dev.Attrs.Keys) {
            $attrVal = $dev.Attrs[$attrName]
            if ($attrVal) {
                try {
                    $null = Set-WUGDeviceAttribute -DeviceId $deviceId -Name $attrName -Value "$attrVal" -ErrorAction SilentlyContinue
                    $stats.AttrsUpdated++
                }
                catch {
                    Write-Verbose "Could not set attribute '$attrName' on device $deviceId`: $_"
                }
            }
        }
    }

    Write-Progress -Activity 'Setting attributes on new devices' -Completed
}

# ============================================================================
# STEP 9: Handle existing devices (credential + monitor assignment + attributes)
# ============================================================================

if ($existingDevices.Count -gt 0) {
    Write-Host "  Updating $($existingDevices.Count) existing devices (credentials + monitors + attributes)..." -ForegroundColor Cyan
    $existIdx = 0

    foreach ($key in $existingDevices.Keys) {
        $existIdx++
        $deviceId = [int]$existingDevices[$key]
        $dev = $devicePlan[$key]
        $displayName = "$($dev.Name) (AP)"

        Write-Progress -Activity 'Updating existing devices' `
            -Status "$existIdx / $($existingDevices.Count) - $displayName" `
            -PercentComplete ([Math]::Round(($existIdx / $existingDevices.Count) * 100))

        # Assign SNMP credential if specified
        if ($SNMPCredentialName) {
            try {
                $credResult = @(Get-WUGCredential -Type snmpv2 -SearchValue $SNMPCredentialName)
                $credMatch = $credResult | Where-Object { $_.name -eq $SNMPCredentialName } | Select-Object -First 1
                if ($credMatch) {
                    $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $credMatch.id -Assign
                }
            }
            catch {
                if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                    Write-Verbose "SNMP credential assign error for device $deviceId`: $_"
                }
            }
        }

        # Assign active monitors with per-AP SNMP instance and comment
        foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
            if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) {
                $monTemplateId = $existingActiveNames[$actItem.Name]
                $snmpInstance = if ($dev.SNMPInstance) { $dev.SNMPInstance } else { '1' }
                $monComment = "$($dev.APMac)"
                
                try {
                    $monAssignResult = Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $monTemplateId -Argument $snmpInstance -Comment $monComment -ErrorAction Stop
                    Write-Verbose "Assigned monitor '$($actItem.Name)' to device $deviceId with instance=$snmpInstance and comment"
                }
                catch {
                    if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                        Write-Warning "Failed to assign monitor '$($actItem.Name)' to device $deviceId`: $_"
                    }
                }
            }
        }

        # Update device attributes
        foreach ($attrName in $dev.Attrs.Keys) {
            $attrVal = $dev.Attrs[$attrName]
            if ($attrVal) {
                try {
                    $null = Set-WUGDeviceAttribute -DeviceId $deviceId -Name $attrName -Value "$attrVal" -ErrorAction SilentlyContinue
                    $stats.AttrsUpdated++
                }
                catch {
                    Write-Verbose "Could not set attribute '$attrName' on device $deviceId`: $_"
                }
            }
        }
    }
    Write-Progress -Activity 'Updating existing devices' -Completed
}

# ============================================================================
# STEP 10: Summary
# ============================================================================

Write-Host ""
Write-Host "Push complete!" -ForegroundColor Green
Write-Host "  Active monitors:  $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor White
Write-Host "  Devices:          $($stats.DevicesCreated) created, $($stats.DevicesFound) existing" -ForegroundColor White
Write-Host "  Attributes:       $($stats.AttrsUpdated) set/updated" -ForegroundColor White
Write-Host ""
Write-Host "Done! Devices pushed to WhatsUp Gold." -ForegroundColor Green

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD8Hbzqi30uH4mX
# FT4tFaLhsNVZI2XMLvhnMEZTFUzPqqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCAXqW08iHJNwz1YTAzA6Q/rBdTzWY3jKqUr25cqAFSRIjANBgkqhkiG9w0BAQEF
# AASCAgCC0YvGO3CLtAtICCOvZtH3EabAr0bfEdupbcVud1OT0ruo9by8xq6zZzAV
# pbXS+U3f/Pme+ikpn/bCSc6jot+rqevxX7zrfL1pckP5odRledu6wJijioVksl/2
# 8PWH95eAM+lDfaPT3E/HdlCrYFjMUxaDXjMtw3NgS/LwqoMzdhQVeoUnZEnNXRIT
# 0K7JUX+S84pDNB2Mkqu9AJs1RvrTO0d7Iv62JCoEQQcCAl2Rjd9fazgQAqzCr9bf
# WehyXVaYmaCu713YL0gql5qUBdfJQw0NX3CRMj/ofLeblIgV+tszJg/5mitEcchr
# jgUnU0qq+n+U41x+lKNWDgejQT5Ppb5hLUZmmTc0FeTfTx8ww6ka1x8LsxVOXD7q
# JVj5rsbo8lguI8XapHAJJh0W3a2Z5f4MgRG+vqYyK7x9m9c/uA8XTDhiDZHgqsG4
# 5gWae4SBbzMqf2OcF9Yj1Ra1Tv2wVZSIX9ZL+uPn29Pg5bHB8M2T2l2gE29ODvUL
# VKzc/wZ90fS+xxjhxfbnXwUvkSLIgLBRDW3GfFyJp+Gg9MlEwpyQrcCCG73PtY8R
# VOcV943wF2b/pA2/2VccwtNrqmQWjSjqwyFY1+00/ueuRzeIuAvheU5Qs879hYul
# 2RiaBEo9y6EeKEYLFuohza0z1NwMF5DTiSo+xRxPDcHdloXG2KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MTQwMDM5MTZaMC8GCSqGSIb3DQEJBDEiBCAzVPrH
# H50d4fY0I6sjJMw5JRiCqyOI7TrvM8/JeymgETANBgkqhkiG9w0BAQEFAASCAgCj
# dtSgDCBF9201QrzZfq3asEcjKMpddLzYbSPpj0nAJd7sxxBJfjXLmxovmwuFI1x0
# 9xr4vo06lhI1v1VFhqaUhRMymvy3wy/x3iEvYrJDWAwOQbrA9KfzhCAw+YaH5rPp
# rnYHSjE9xoxW/teo1kcgw1QvaGLQMnurhgDf3yD9WrN94xFcjasPcQx0mo9Ql34Z
# wiOMZDyfFN0Si282pEPY1r5IvL2qCbgvnBTd9WW2v28VKHvIcbG+5u0AxMG1ntkt
# T6fbSIW2i4GIWDF637jmqzcG64y0Nil4VG9B4Lmi57gE4yMitlOQ+47T2WhHDmlt
# ZfMzq+baKsH+u4GkFpKh4h/bAfjkF/lwhuZZhLN+VD7SMWEZ4IwwfARQsmVjQDsE
# 6EbYgSA9q9yy+EEeUXgB4HFxbhP+h8GFnsnVoOrnaZeA4OpRcd3OsrrNjW5UIo8/
# c6S6TGIM4JaEazmm22v2gSyqtXLpcbCe3Y4XC6EO4nSXUU9aEHlNwaxuEsm0+n6o
# bzGAdxzPFcyvW2FxGDAh1vq/mpRveU2kPiRuveGKBMq4FzmNTfCJVsxC64dxNd76
# 09vjdPXGoxDNITr6i00hRC0NCRsky/USMD+b4eoAeDGg259nHAJY4F50YP3o0Hg1
# s9dSEhapbynwdW6hUF8yoXYIMSUxRGG9vO/8fHrorQ==
# SIG # End signature block
