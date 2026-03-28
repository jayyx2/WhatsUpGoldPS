<#
.SYNOPSIS
    Renames devices and updates the existing "Memory Utilization" performance
    monitor to collect physical memory via WMI on Hyper-V role devices.

.DESCRIPTION
    Demonstrates two common WhatsUp Gold housekeeping tasks:

      1. Bulk-rename devices -- strips old DNS suffixes, normalises hostnames,
         or applies a custom naming convention so display names are clean.

      2. On devices with a Hyper-V role, finds the existing "Memory Utilization"
         performance monitor and updates its library template PropertyBags so it
         uses the WMI protocol and collects only Physical Memory.
         This modifies the EXISTING monitor in-place via
         PUT /api/v1/monitors/{monitorId}?type=performance -- no remove/add.

         The known PropertyBags for the built-in Memory Utilization monitor are:
           Memory:UseWMI          = 1   (use WMI protocol)
           Memory:CollectionType  = 0   (specific memory items, not all)
           Memory:SelectedIndexes = 1000|Physical Memory

    The script uses the DPAPI credential vault from the Discovery framework so
    you only type WUG credentials once. First run prompts and caches; subsequent
    runs load from vault automatically.

    WhatsUpGoldPS functions used:
      Connect-WUGServer          -- authenticate to WUG REST API
      Get-WUGDevice              -- search / list devices
      Get-WUGDeviceRole          -- check device role assignments (Hyper-V filter)
      Set-WUGDeviceProperties    -- change display name, notes, etc.
      Get-WUGPerformanceMonitor  -- list performance monitors on a device
      Set-WUGPerformanceMonitor  -- update monitor template PropertyBags (PUT)

.NOTES
    Author : Jason Alberino (jason@wug.ninja)
    Requires: WhatsUpGoldPS module, DiscoveryHelpers.ps1 (for vault)
    Encoding: UTF-8 with BOM

.EXAMPLE
    .\Rename_and_update_device_settings.ps1
    # Interactive -- prompts for WUG server, processes all devices.

.EXAMPLE
    .\Rename_and_update_device_settings.ps1 -WUGServer '192.168.74.74' -NonInteractive
    # Unattended -- uses vault credentials, no prompts.

.EXAMPLE
    .\Rename_and_update_device_settings.ps1 -WhatIf
    # Preview mode -- shows what would change without applying anything.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$WUGServer,
    [PSCredential]$WUGCredential,
    [switch]$NonInteractive
)

# ============================================================================
# 0. Load helpers + module
# ============================================================================
$ErrorActionPreference = 'Stop'

# Load WhatsUpGoldPS
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    try { Import-Module WhatsUpGoldPS -ErrorAction Stop }
    catch { Write-Error "WhatsUpGoldPS module not found. Install it first."; return }
}

# Load DiscoveryHelpers for vault support (optional -- falls back to Get-Credential)
$discoveryHelpers = Join-Path $PSScriptRoot '..\helpers\discovery\DiscoveryHelpers.ps1'
$hasVault = $false
if (Test-Path $discoveryHelpers) {
    . $discoveryHelpers
    $hasVault = $true
}

# ============================================================================
# 1. Connect to WhatsUp Gold
# ============================================================================
Write-Host "=== Device Rename & Monitor Update ===" -ForegroundColor Cyan
Write-Host ""

if (-not $WUGServer) {
    if ($NonInteractive) {
        Write-Error 'WUG server is required for non-interactive mode. Pass -WUGServer.'
        return
    }
    $WUGServer = Read-Host -Prompt "WhatsUp Gold server address (e.g. 192.168.74.74)"
    if ([string]::IsNullOrWhiteSpace($WUGServer)) {
        Write-Error 'WUG server address is required.'; return
    }
}

if ($WUGCredential) {
    $wugCred = $WUGCredential
}
elseif ($hasVault) {
    # Use the discovery vault to cache/retrieve WUG credentials
    $credSplat = @{ Name = 'WUG.Server'; CredType = 'WUGServer'; ProviderLabel = 'WhatsUp Gold' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    $wugResolved = Resolve-DiscoveryCredential @credSplat
    if (-not $wugResolved) {
        Write-Error 'No WUG credentials available. Run interactively first to cache them.'
        return
    }
    $wugCred = $wugResolved.Credential
    if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
}
else {
    if ($NonInteractive) {
        Write-Error 'No vault available and no -WUGCredential provided.'; return
    }
    $wugCred = Get-Credential -Message "WhatsUp Gold admin credentials for $WUGServer"
}

Write-Host "Connecting to $WUGServer..." -ForegroundColor Cyan
Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors
Write-Host "Connected." -ForegroundColor Green
Write-Host ""

# ============================================================================
# 2. Configuration -- customise these to match your environment
# ============================================================================

# --- Display name rules ---------------------------------------------------
# Each rule is a scriptblock that receives the current displayName and returns
# the new name, or $null to leave it unchanged. Rules chain in order.
$renamingRules = @(
    # Rule 1: Strip common DNS suffixes
    {
        param($name)
        $suffixes = @('.corp.local', '.ad.local', '.internal.local', '.domain.local', '.local')
        foreach ($s in $suffixes) {
            if ($name.EndsWith($s, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $name.Substring(0, $name.Length - $s.Length)
            }
        }
        return $null
    },
    # Rule 2: Strip trailing FQDN past first dot (e.g. server01.old.domain.com -> server01)
    {
        param($name)
        if ($name -match '^[^.]+\..+\..+') {
            return ($name -split '\.')[0]
        }
        return $null
    },
    # Rule 3: Upper-case the first letter (cosmetic)
    {
        param($name)
        if ($name.Length -gt 0 -and $name[0] -cmatch '[a-z]') {
            return $name.Substring(0,1).ToUpper() + $name.Substring(1)
        }
        return $null
    }
)

# --- Memory monitor search pattern ------------------------------------------
# Name pattern used to find the existing memory monitor on each device
$memoryMonitorSearch = 'Memory Utilization'

# --- Memory monitor PropertyBags to SET -------------------------------------
# These are the known property bags for the built-in Memory Utilization monitor.
# The public API does not return these on GET, but the PUT endpoint accepts them.
# Values derived from the WUG database and UI network calls.
$memoryPropertyBags = @(
    @{ name = 'Memory:UseWMI';          value = '1' }              # WMI protocol
    @{ name = 'Memory:CollectionType';  value = '0' }              # Specific items
    @{ name = 'Memory:SelectedIndexes'; value = '1000|Physical Memory' }  # Physical only
)

# ============================================================================
# 3. Get all devices
# ============================================================================
Write-Host "Retrieving devices..." -ForegroundColor Cyan
$devices = @(Get-WUGDevice -View card)
Write-Host "  Found $($devices.Count) devices." -ForegroundColor White
Write-Host ""

if ($devices.Count -eq 0) {
    Write-Host "No devices found. Nothing to do." -ForegroundColor Yellow
    return
}

# ============================================================================
# 4. Rename devices with old/weird DNS names
# ============================================================================
Write-Host "--- Phase 1: Display Name Cleanup ---" -ForegroundColor Cyan

$renameCount = 0
foreach ($dev in $devices) {
    $currentName = $dev.displayName
    $newName = $null

    foreach ($rule in $renamingRules) {
        $result = & $rule $currentName
        if ($result -and $result -ne $currentName) {
            $newName = $result
            $currentName = $newName  # chain rules
        }
    }

    if ($newName -and $newName -ne $dev.displayName) {
        Write-Host "  Rename: '$($dev.displayName)' -> '$newName'" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess("Device $($dev.id) '$($dev.displayName)'", "Rename to '$newName'")) {
            try {
                Set-WUGDeviceProperties -DeviceId $dev.id -DisplayName $newName
                $renameCount++
            }
            catch {
                Write-Warning "  Failed to rename device $($dev.id): $_"
            }
        }
    }
}

Write-Host ""
Write-Host "  Renamed: $renameCount devices" -ForegroundColor Green
Write-Host ""

# ============================================================================
# 5. Filter to Hyper-V role devices and update their Memory Utilization monitor
# ============================================================================
Write-Host "--- Phase 2: Memory Monitor Update (Hyper-V devices only) ---" -ForegroundColor Cyan
Write-Host "  Finding devices with Hyper-V role..." -ForegroundColor DarkGray

$hypervDevices = @()
foreach ($dev in $devices) {
    try {
        $roles = @(Get-WUGDeviceRole -DeviceId $dev.id)
        $isHyperV = $roles | Where-Object {
            $_.name -match 'Hyper-V' -or $_.name -match 'HyperV'
        }
        if ($isHyperV) {
            $hypervDevices += $dev
        }
    }
    catch {
        Write-Verbose "Could not get roles for device $($dev.id) ($($dev.displayName)): $_"
    }
}

Write-Host "  Found $($hypervDevices.Count) Hyper-V devices." -ForegroundColor White
Write-Host ""

if ($hypervDevices.Count -eq 0) {
    Write-Host "  No Hyper-V devices found. Skipping monitor updates." -ForegroundColor Yellow
}

$monitorsUpdated    = 0
$monitorsSkipped    = 0
$monitorsNotFound   = 0
$alreadyUpdatedIds  = @{}  # Track template IDs already updated (shared library monitors)

foreach ($dev in $hypervDevices) {
    $devId   = $dev.id
    $devName = $dev.displayName

    # Use Get-WUGPerformanceMonitor to list performance monitors on this device
    $perfMonitors = @()
    try {
        $perfMonitors = @(Get-WUGPerformanceMonitor -DeviceId $devId -Search $memoryMonitorSearch)
    }
    catch {
        Write-Verbose "Could not list performance monitors for device $devId ($devName): $_"
        continue
    }

    # Find the "Memory Utilization" monitor by name
    $memMon = $perfMonitors | Where-Object {
        $_.MonitorTypeName -match $memoryMonitorSearch
    } | Select-Object -First 1

    if (-not $memMon) {
        Write-Verbose "  $devName -- No '$memoryMonitorSearch' monitor found."
        $monitorsNotFound++
        continue
    }

    # The MonitorTypeId is the library template ID used for the PUT
    $templateId = $memMon.MonitorTypeId
    if (-not $templateId) {
        Write-Warning "  $devName -- Found memory monitor but no MonitorTypeId."
        $monitorsNotFound++
        continue
    }

    # Skip if we already updated this shared template (all devices share it)
    if ($alreadyUpdatedIds.ContainsKey($templateId)) {
        Write-Host "  $devName -- Template $templateId already updated (shared monitor)." -ForegroundColor DarkGray
        $monitorsSkipped++
        continue
    }

    Write-Host "  $devName -- Updating '$($memMon.MonitorTypeName)' (Template: $templateId)" -ForegroundColor Yellow
    Write-Host "    Setting: Memory:UseWMI=1, Memory:CollectionType=0, Memory:SelectedIndexes=1000|Physical Memory" -ForegroundColor Cyan

    # Update the library template via Set-WUGPerformanceMonitor
    # The built-in monitor GET does not expose propertyBags, so we send known values.
    if ($PSCmdlet.ShouldProcess("Monitor template $templateId '$($memMon.MonitorTypeName)'", 'Update to WMI / Physical Memory only')) {
        try {
            Set-WUGPerformanceMonitor -MonitorId $templateId -PropertyBags $memoryPropertyBags

            $monitorsUpdated++
            $alreadyUpdatedIds[$templateId] = $true
            Write-Host "    Updated successfully." -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed to update template ${templateId}: $_"
        }
    }
}

# ============================================================================
# 6. Summary
# ============================================================================
Write-Host ""
Write-Host "=== Complete ===" -ForegroundColor Green
Write-Host "  Total devices:              $($devices.Count)" -ForegroundColor White
Write-Host "  Devices renamed:            $renameCount" -ForegroundColor White
Write-Host "  Hyper-V devices found:      $($hypervDevices.Count)" -ForegroundColor White
Write-Host "  Memory monitors updated:    $monitorsUpdated" -ForegroundColor White
Write-Host "  Already updated (shared):   $monitorsSkipped" -ForegroundColor White
Write-Host "  No memory monitor found:    $monitorsNotFound" -ForegroundColor White
Write-Host ""
Write-Host "Tip: Run with -WhatIf to preview changes without applying them." -ForegroundColor DarkGray
Write-Host "Tip: Run with -Verbose to see skipped devices and monitor details." -ForegroundColor DarkGray
