<#
.SYNOPSIS
    Discovers physical disk instances on Windows devices and creates WMI Formatted
    performance monitors in WhatsUp Gold for disk IO metrics.

.DESCRIPTION
    This helper connects to Windows servers via WMI (Get-WmiObject) to enumerate
    physical disk instances from Win32_PerfFormattedData_PerfDisk_PhysicalDisk.
    For each unique disk instance found, it creates WmiFormatted performance monitors
    in the WhatsUp Gold library (if they do not already exist) and assigns them to
    the applicable devices.

    Physical disk instances in WMI can vary per machine (e.g., "0 C:", "1 D:",
    "2 D:" on different servers). This script scans each device to discover the
    actual instances present, creates one library monitor per unique
    class+property+instance combination, and reuses that monitor across all devices
    that share the same instance.

    Monitors created per disk instance:
      - Disk Reads/sec
      - Disk Writes/sec
      - Disk Transfers/sec (Total IOPS)
      - Disk Read Bytes/sec
      - Disk Write Bytes/sec
      - Disk Bytes/sec (Total Throughput)
      - Avg. Disk Queue Length
      - Pct Disk Time

    Prerequisites:
      1. WhatsUpGoldPS module loaded and connected (Connect-WUGServer)
      2. WMI/DCOM or WinRM access to target Windows servers
      3. Credentials with admin access on target servers

.PARAMETER DeviceId
    One or more WUG device IDs to scan. When omitted, devices are resolved
    automatically from a Windows device group (see DeviceGroupSearch).

.PARAMETER Credential
    One or more PSCredentials for WMI access to the target Windows servers.
    Multiple credentials are tried in order per device -- if the first fails
    with an access-denied error the next is attempted. If omitted, credentials
    are resolved from the DPAPI discovery vault. The vault prompts for one
    credential on first run, and you can add more via the interactive prompt.

.PARAMETER DeviceGroupSearch
    Search string used to find a WUG device group containing Windows devices.
    The script searches for a group matching this name, then pulls only those
    devices. Default: 'Windows Infrastructure'. Set to '' to skip group-based filtering.

.PARAMETER DeviceGroupId
    Explicit WUG device group ID. Overrides DeviceGroupSearch. Default: unset.

.PARAMETER WindowsOnly
    When enabled (default), only devices whose role contains 'Windows' are
    scanned. This prevents wasting time trying WMI against Linux boxes,
    switches, etc. Set -WindowsOnly:$false to scan all devices in the group.

.PARAMETER ExcludeInstance
    Array of instance name patterns to skip (e.g., '_Total'). Default: @('_Total').
    Use @() to include _Total.

.PARAMETER DiskType
    Which WMI disk class to query. Default: 'Physical'.
      Physical -- Win32_PerfFormattedData_PerfDisk_PhysicalDisk (raw hardware disks: 0, 1, 2...)
      Logical  -- Win32_PerfFormattedData_PerfDisk_LogicalDisk  (drive letters: C:, D:, E:...)
    Physical disks show hardware-level IO; Logical disks show per-volume IO.

.PARAMETER IncludeCounter
    Array of counter names to create monitors for. Default: DiskTransfersPersec
    (total IOPS). Use 'All' to include all 8 counters.
    Valid values: All, DiskReadsPersec, DiskWritesPersec, DiskTransfersPersec,
    DiskReadBytesPersec, DiskWriteBytesPersec, DiskBytesPersec,
    AvgDiskQueueLength, PercentDiskTime.

.PARAMETER PollingIntervalMinutes
    Polling interval for assigned monitors. Default: 5.

.PARAMETER WmiTimeout
    WMI query timeout in seconds. Default: 10.

.PARAMETER NamePrefix
    Prefix for monitor display names. Default: 'PhysDisk'.

.PARAMETER DryRun
    Show what would be created/assigned without making changes.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: resolved from vault.

.PARAMETER NonInteractive
    Suppress interactive prompts. Uses cached vault credentials.

.EXAMPLE
    .\Setup-WindowsDiskIO-Discovery.ps1

    Interactive mode -- resolves creds from vault (prompts on first run),
    scans all WUG devices, discovers disks, creates monitors.

.EXAMPLE
    .\Setup-WindowsDiskIO-Discovery.ps1 -Credential (Get-Credential)

    Interactive mode with explicit credential -- skips WMI vault lookup.

.EXAMPLE
    .\Setup-WindowsDiskIO-Discovery.ps1 -DeviceId @(100,101,102) -NonInteractive

    Scans specific devices non-interactively using vault credentials.

.EXAMPLE
    .\Setup-WindowsDiskIO-Discovery.ps1 -DeviceId 42 -Credential $cred -DryRun

    Shows what monitors would be created for device 42 without making changes.

.EXAMPLE
    .\Setup-WindowsDiskIO-Discovery.ps1 -DeviceId 42 -Credential $cred -IncludeCounter @('DiskReadsPersec','DiskWritesPersec')

    Only creates Disk Reads/sec and Disk Writes/sec monitors.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: WhatsUpGoldPS module, PowerShell 5.1+
    Encoding: UTF-8 with BOM
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int[]]$DeviceId,

    [PSCredential[]]$Credential,

    [string]$DeviceGroupSearch = 'Windows Infrastructure',

    [string]$DeviceGroupId,

    [bool]$WindowsOnly = $true,

    [string[]]$ExcludeInstance = @('_Total'),

    [ValidateSet('All', 'Physical', 'Logical')]
    [string]$DiskType = 'Logical',

    [ValidateSet('All', 'DiskReadsPersec', 'DiskWritesPersec', 'DiskTransfersPersec',
                 'DiskReadBytesPersec', 'DiskWriteBytesPersec', 'DiskBytesPersec',
                 'AvgDiskQueueLength', 'PercentDiskTime')]
    [string[]]$IncludeCounter,

    [ValidateRange(1, 1440)]
    [int]$PollingIntervalMinutes = 10,

    [int]$WmiTimeout = 10,

    [string]$NamePrefix = 'PhysDisk',

    [string]$WUGServer,

    [switch]$DryRun,

    [switch]$NonInteractive
)

# --- Handle 'All' by running twice with each type ----------------------------
if ($DiskType -eq 'All') {
    $scriptPath = $MyInvocation.MyCommand.Path
    # Load helpers so we can resolve credentials once
    $scriptDir = Split-Path $scriptPath -Parent
    . (Join-Path $scriptDir 'DiscoveryHelpers.ps1')

    # Resolve credentials once here, then pass via -Credential to both passes
    if (-not $PSBoundParameters.ContainsKey('Credential') -or -not $Credential) {
        $credList = @()
        $credIndex = 1
        $wmiVaultName = "Windows.WMI.Credential.$credIndex"
        $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; ProviderLabel = "Windows WMI #$credIndex" }
        if ($NonInteractive) { $credSplat.NonInteractive = $true }
        $firstCred = Resolve-DiscoveryCredential @credSplat
        if (-not $firstCred) {
            Write-Error "No WMI credentials available. Provide -Credential or configure the vault."
            return
        }
        $credList += $firstCred
        if (-not $NonInteractive) {
            while ($true) {
                Write-Host ""
                Write-Host "  Credential #$($credList.Count) loaded: $($credList[-1].UserName)" -ForegroundColor Gray
                Write-Host "  Add another credential to try if this one fails on some servers?" -ForegroundColor Cyan
                $addMore = Read-Host -Prompt "  [Y]es / [N]o (default: N)"
                if ($addMore -notmatch '^[Yy]') { break }
                $credIndex++
                $wmiVaultName = "Windows.WMI.Credential.$credIndex"
                $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; ProviderLabel = "Windows WMI #$credIndex" }
                $nextCred = Resolve-DiscoveryCredential @credSplat
                if ($nextCred) { $credList += $nextCred } else { break }
            }
        }
        $Credential = $credList
    }

    # Build a splat of all bound params except DiskType
    $passThru = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'DiskType') { $passThru[$key] = $PSBoundParameters[$key] }
    }
    # Ensure resolved credentials are passed through
    $passThru['Credential'] = $Credential

    Write-Host ""
    Write-Host "DiskType=All: Running Logical pass first, then Physical." -ForegroundColor Cyan
    Write-Host ""
    & $scriptPath -DiskType Logical @passThru
    Write-Host ""
    & $scriptPath -DiskType Physical @passThru
    return
}

# --- Load discovery helpers (vault, credential resolver) ----------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryHelpersPath = Join-Path $scriptDir 'DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) {
    . $discoveryHelpersPath
}
else {
    Write-Error "DiscoveryHelpers.ps1 not found at '$discoveryHelpersPath'. Cannot continue."
    return
}

# =============================================================================
# Configuration: Counter definitions
# =============================================================================
# Each entry maps a friendly key to the WMI property name and a human-readable
# display label used in the WUG monitor name.
$script:CounterDefinitions = [ordered]@{
    DiskReadsPersec       = @{ Property = 'DiskReadsPersec';       Label = 'Disk Reads/sec' }
    DiskWritesPersec      = @{ Property = 'DiskWritesPersec';      Label = 'Disk Writes/sec' }
    DiskTransfersPersec   = @{ Property = 'DiskTransfersPersec';   Label = 'Disk Transfers/sec (IOPS)' }
    DiskReadBytesPersec   = @{ Property = 'DiskReadBytesPersec';   Label = 'Disk Read Bytes/sec' }
    DiskWriteBytesPersec  = @{ Property = 'DiskWriteBytesPersec';  Label = 'Disk Write Bytes/sec' }
    DiskBytesPersec       = @{ Property = 'DiskBytesPersec';       Label = 'Disk Bytes/sec (Total)' }
    AvgDiskQueueLength    = @{ Property = 'AvgDiskQueueLength';    Label = 'Avg. Disk Queue Length' }
    PercentDiskTime       = @{ Property = 'PercentDiskTime';       Label = '% Disk Time' }
}

# Default counters (IOPS only) when -IncludeCounter is not specified
$script:DefaultCounters = @('DiskTransfersPersec')

# Resolve WMI class and name prefix based on DiskType
if ($DiskType -eq 'Logical') {
    $WmiClass = 'Win32_PerfFormattedData_PerfDisk_LogicalDisk'
    if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = 'LogDisk' }
}
else {
    $WmiClass = 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk'
    if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = 'PhysDisk' }
}

# Filter to requested counters only
if ($IncludeCounter -and $IncludeCounter -contains 'All') {
    # All counters
    $activeCounters = $script:CounterDefinitions
}
elseif ($IncludeCounter) {
    $activeCounters = [ordered]@{}
    foreach ($key in $IncludeCounter) {
        if ($script:CounterDefinitions.Contains($key)) {
            $activeCounters[$key] = $script:CounterDefinitions[$key]
        }
    }
}
else {
    # Default: IOPS only
    $activeCounters = [ordered]@{}
    foreach ($key in $script:DefaultCounters) {
        $activeCounters[$key] = $script:CounterDefinitions[$key]
    }
}

if ($activeCounters.Count -eq 0) {
    Write-Error "No valid counters selected. Exiting."
    return
}

# =============================================================================
# Preflight: WUG connection (vault-backed)
# =============================================================================
if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) {
    Write-Host "Not connected to WhatsUp Gold. Resolving from vault..." -ForegroundColor Yellow
    $wugSplat = @{ Name = 'WUG.Server'; CredType = 'WUGServer'; ProviderLabel = 'WhatsUp Gold' }
    if ($NonInteractive) { $wugSplat.NonInteractive = $true }
    $wugResolved = Resolve-DiscoveryCredential @wugSplat
    if (-not $wugResolved) {
        Write-Error "No WhatsUp Gold server credentials available. Run Connect-WUGServer or configure the vault."
        return
    }
    # Connect using resolved vault credentials
    $wugConnSplat = @{}
    if ($wugResolved -is [hashtable]) {
        $wugConnSplat.Server = $wugResolved.Server
        if ($wugResolved.Port)     { $wugConnSplat.Port = $wugResolved.Port }
        if ($wugResolved.Protocol) { $wugConnSplat.Protocol = $wugResolved.Protocol }
        if ($wugResolved.Credential) { $wugConnSplat.Credential = $wugResolved.Credential }
        if ($wugResolved.IgnoreSSL) { $wugConnSplat.IgnoreSSL = $true }
    }
    elseif ($WUGServer) {
        $wugConnSplat.Server = $WUGServer
    }
    try {
        Connect-WUGServer @wugConnSplat
        Write-Host "Connected to WhatsUp Gold." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to WhatsUp Gold: $_"
        return
    }
}

# =============================================================================
# Resolve WMI credentials (vault-backed, multi-credential support)
# =============================================================================
# Build an ordered list of credentials to try per device.
$credentialList = [System.Collections.Generic.List[PSCredential]]::new()

if ($Credential) {
    # Explicit parameter -- use as-is
    foreach ($c in $Credential) { $credentialList.Add($c) }
}
else {
    # Resolve first credential from vault
    $credIndex = 1
    $wmiVaultName = "Windows.WMI.Credential.$credIndex"
    $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; ProviderLabel = "Windows WMI #$credIndex" }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    $firstCred = Resolve-DiscoveryCredential @credSplat
    if (-not $firstCred) {
        Write-Error "No WMI credentials available. Provide -Credential or configure the vault."
        return
    }
    $credentialList.Add($firstCred)

    # Offer to add more credentials (interactive only)
    if (-not $NonInteractive) {
        while ($true) {
            Write-Host ""
            Write-Host "  Credential #$($credentialList.Count) loaded: $($credentialList[-1].UserName)" -ForegroundColor Gray
            Write-Host "  Add another credential to try if this one fails on some servers?" -ForegroundColor Cyan
            $addMore = Read-Host -Prompt "  [Y]es / [N]o (default: N)"
            if ($addMore -notmatch '^[Yy]') { break }

            $credIndex++
            $wmiVaultName = "Windows.WMI.Credential.$credIndex"
            $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; ProviderLabel = "Windows WMI #$credIndex" }
            $nextCred = Resolve-DiscoveryCredential @credSplat
            if ($nextCred) {
                $credentialList.Add($nextCred)
            }
            else {
                Write-Host "  Skipped." -ForegroundColor Yellow
                break
            }
        }
    }
    else {
        # Non-interactive: load any additional vault entries that already exist
        while ($true) {
            $credIndex++
            $wmiVaultName = "Windows.WMI.Credential.$credIndex"
            $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; NonInteractive = $true }
            $nextCred = Resolve-DiscoveryCredential @credSplat
            if ($nextCred) {
                $credentialList.Add($nextCred)
            }
            else {
                break
            }
        }
    }
}

Write-Host ""
Write-Host "  Credentials to try ($($credentialList.Count)):" -ForegroundColor Cyan
for ($ci = 0; $ci -lt $credentialList.Count; $ci++) {
    Write-Host "    [$($ci + 1)] $($credentialList[$ci].UserName)" -ForegroundColor Gray
}

# =============================================================================
# STEP 1: Resolve target devices (smart Windows group detection)
# =============================================================================
Write-Host ""
Write-Host "=== Windows Physical Disk IO Discovery ===" -ForegroundColor Cyan
Write-Host ""

if ($DeviceId) {
    Write-Host "Fetching $($DeviceId.Count) specified device(s) from WhatsUp Gold..." -ForegroundColor Cyan
    $devices = @()
    foreach ($dId in $DeviceId) {
        try {
            $dev = Get-WUGDevice -DeviceId $dId
            if ($dev) { $devices += $dev }
        }
        catch {
            Write-Warning "Could not retrieve device ID ${dId}: $_"
        }
    }
}
else {
    # --- Auto-resolve device group ------------------------------------------
    $resolvedGroupId = $null

    if ($DeviceGroupId) {
        # Explicit group ID provided
        $resolvedGroupId = $DeviceGroupId
        Write-Host "Using explicit device group ID: $resolvedGroupId" -ForegroundColor Cyan
    }
    elseif ($DeviceGroupSearch) {
        Write-Host "Searching for device group matching '$DeviceGroupSearch'..." -ForegroundColor Cyan
        try {
            $matchingGroups = @(Get-WUGDeviceGroup -SearchValue $DeviceGroupSearch)
            if ($matchingGroups.Count -eq 1) {
                $resolvedGroupId = $matchingGroups[0].id
                Write-Host "  Found group: '$($matchingGroups[0].name)' (ID: $resolvedGroupId)" -ForegroundColor Green
            }
            elseif ($matchingGroups.Count -gt 1) {
                Write-Host "  Found $($matchingGroups.Count) matching groups:" -ForegroundColor Cyan
                for ($gi = 0; $gi -lt $matchingGroups.Count; $gi++) {
                    $g = $matchingGroups[$gi]
                    $devCount = if ($g.deviceCount) { $g.deviceCount } else { '?' }
                    Write-Host "    [$($gi + 1)] $($g.name) (ID: $($g.id), Devices: $devCount)" -ForegroundColor White
                }
                if (-not $NonInteractive) {
                    Write-Host ""
                    $groupChoice = Read-Host -Prompt "  Select group number [default: 1]"
                    if (-not $groupChoice) { $groupChoice = '1' }
                    $groupIdx = [int]$groupChoice - 1
                    if ($groupIdx -ge 0 -and $groupIdx -lt $matchingGroups.Count) {
                        $resolvedGroupId = $matchingGroups[$groupIdx].id
                        Write-Host "  Selected: '$($matchingGroups[$groupIdx].name)' (ID: $resolvedGroupId)" -ForegroundColor Green
                    }
                    else {
                        Write-Warning "Invalid selection. Using first match."
                        $resolvedGroupId = $matchingGroups[0].id
                    }
                }
                else {
                    # Non-interactive: pick the first match
                    $resolvedGroupId = $matchingGroups[0].id
                    Write-Host "  Auto-selected: '$($matchingGroups[0].name)' (ID: $resolvedGroupId)" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "  No groups matching '$DeviceGroupSearch'. Falling back to all devices." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Failed to search device groups: $_. Falling back to all devices."
        }
    }

    if (-not $resolvedGroupId) { $resolvedGroupId = '-1' }
    Write-Host "Fetching devices from group $resolvedGroupId..." -ForegroundColor Cyan
    $devices = @(Get-WUGDevice -DeviceGroupID $resolvedGroupId)

    # --- Filter to Windows-only by role --------------------------------------
    if ($WindowsOnly -and $devices.Count -gt 0) {
        $preCount = $devices.Count
        $devices = @($devices | Where-Object {
            ($_.role -and $_.role -match 'Windows') -or
            ($_.description -and $_.description -match 'Windows')
        })
        $filtered = $preCount - $devices.Count
        if ($filtered -gt 0) {
            Write-Host "  Filtered to Windows devices: $($devices.Count) of $preCount (skipped $filtered non-Windows)." -ForegroundColor Gray
        }
    }
}

if (-not $devices -or $devices.Count -eq 0) {
    Write-Error "No devices found. Exiting."
    return
}

Write-Host "Found $($devices.Count) device(s)." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 2: Scan each device via WMI to discover disk instances
# =============================================================================
# Structure: $deviceDisks[deviceId] = @( "0 C:", "1 D:", ... )
$deviceDisks = @{}
$allInstances = @{}   # unique instance -> $true (dedup across all devices)
$deviceInfo = @{}     # deviceId -> @{ Name; IP }

$scanIndex = 0
foreach ($dev in $devices) {
    $scanIndex++
    $devId   = $dev.id
    $devName = if ($dev.displayName) { $dev.displayName } else { $dev.hostName }
    $devIP   = $dev.networkAddress

    if (-not $devIP) {
        Write-Warning "Device '$devName' (ID: $devId) has no network address. Skipping."
        continue
    }

    $deviceInfo[$devId] = @{ Name = $devName; IP = $devIP }

    $pct = [Math]::Round(($scanIndex / $devices.Count) * 100)
    Write-Progress -Activity "Scanning devices via WMI" `
        -Status "$devName ($devIP) [$scanIndex of $($devices.Count)]" `
        -PercentComplete $pct

    Write-Host "  [$scanIndex/$($devices.Count)] Scanning $devName ($devIP)..." -ForegroundColor Gray -NoNewline

    # Try each credential in order; stop on first success or non-auth failure
    $scanSuccess = $false
    for ($ci = 0; $ci -lt $credentialList.Count; $ci++) {
        $tryCred = $credentialList[$ci]
        if ($credentialList.Count -gt 1 -and $ci -gt 0) {
            Write-Host "" -NoNewline  # newline before retry
            Write-Host "    Retrying with credential #$($ci + 1) ($($tryCred.UserName))..." -ForegroundColor DarkGray -NoNewline
        }

        try {
            $perfData = Get-WmiObject -Class $WmiClass `
                -ComputerName $devIP `
                -Credential $tryCred `
                -ErrorAction Stop |
                Where-Object { $_.Name -and $_.Name -ne '' }

            # Success -- process results
            if (-not $perfData) {
                Write-Host " no disks found." -ForegroundColor Yellow
                $scanSuccess = $true
                break
            }

            $instances = @()
            foreach ($disk in $perfData) {
                $instanceName = $disk.Name

                # Apply exclusion filter
                $excluded = $false
                foreach ($pattern in $ExcludeInstance) {
                    if ($instanceName -like "*$pattern*") {
                        $excluded = $true
                        break
                    }
                }
                if ($excluded) { continue }

                $instances += $instanceName
                $allInstances[$instanceName] = $true
            }

            if ($instances.Count -gt 0) {
                $deviceDisks[$devId] = $instances
                $credLabel = if ($credentialList.Count -gt 1) { " [cred #$($ci + 1)]" } else { '' }
                Write-Host " found $($instances.Count) disk(s): $($instances -join ', ')$credLabel" -ForegroundColor Green
            }
            else {
                Write-Host " no disks after filtering." -ForegroundColor Yellow
            }
            $scanSuccess = $true
            break  # done with this device
        }
        catch [System.UnauthorizedAccessException] {
            # Auth failure -- try next credential if available
            if ($ci -lt ($credentialList.Count - 1)) {
                Write-Verbose "Credential #$($ci + 1) ($($tryCred.UserName)) access denied on ${devIP}. Trying next."
                continue
            }
            Write-Host " access denied (all $($credentialList.Count) credential(s) failed)." -ForegroundColor Red
            Write-Verbose "UnauthorizedAccessException on ${devIP}: $_"
        }
        catch [System.Runtime.InteropServices.COMException] {
            $comMsg = $_.Exception.Message
            # Access-denied COM errors (0x80070005) -- try next credential
            if ($comMsg -match 'Access is denied|0x80070005') {
                if ($ci -lt ($credentialList.Count - 1)) {
                    Write-Verbose "Credential #$($ci + 1) ($($tryCred.UserName)) COM access denied on ${devIP}. Trying next."
                    continue
                }
                Write-Host " access denied (all $($credentialList.Count) credential(s) failed)." -ForegroundColor Red
            }
            else {
                # RPC unavailable, network error, etc. -- no point trying another cred
                Write-Host " WMI/RPC unavailable." -ForegroundColor Red
            }
            Write-Verbose "COMException on ${devIP}: $_"
        }
        catch {
            # Non-auth error -- don't try more creds, skip device
            Write-Host " failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Verbose "Error on ${devIP}: $_"
            break
        }
    }
}

Write-Progress -Activity "Scanning devices via WMI" -Completed

if ($deviceDisks.Count -eq 0) {
    Write-Warning "No physical disks discovered on any device. Nothing to do."
    return
}

$sortedInstances = @($allInstances.Keys | Sort-Object)

Write-Host ""
Write-Host "--- Discovery Summary ---" -ForegroundColor Cyan
Write-Host "  Devices scanned:       $($devices.Count)" -ForegroundColor White
Write-Host "  Devices with disks:    $($deviceDisks.Count)" -ForegroundColor White
Write-Host "  Unique disk instances: $($sortedInstances.Count)" -ForegroundColor White
Write-Host "  Counters per disk:     $($activeCounters.Count)" -ForegroundColor White
Write-Host "  Unique instances:      $($sortedInstances -join ', ')" -ForegroundColor Gray
Write-Host ""

# Show per-device breakdown
Write-Host "  Per-device disk map:" -ForegroundColor White
foreach ($devId in ($deviceDisks.Keys | Sort-Object)) {
    $info = $deviceInfo[$devId]
    $disks = $deviceDisks[$devId] -join ', '
    Write-Host "    $($info.Name) ($($info.IP)): $disks" -ForegroundColor Gray
}
Write-Host ""

$totalMonitors   = $sortedInstances.Count * $activeCounters.Count
$totalAssignments = 0
foreach ($devId in $deviceDisks.Keys) {
    $totalAssignments += $deviceDisks[$devId].Count * $activeCounters.Count
}

Write-Host "  Monitors to create (library):  up to $totalMonitors" -ForegroundColor White
Write-Host "  Assignments to make (devices): up to $totalAssignments" -ForegroundColor White
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] Listing planned monitors:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($instance in $sortedInstances) {
        foreach ($counterKey in $activeCounters.Keys) {
            $def = $activeCounters[$counterKey]
            $monName = "${NamePrefix} - ${instance} - $($def.Label)"
            $assignTo = @()
            foreach ($devId in $deviceDisks.Keys) {
                if ($deviceDisks[$devId] -contains $instance) {
                    $assignTo += "$($deviceInfo[$devId].Name)(#$devId)"
                }
            }
            Write-Host "  [CREATE] $monName" -ForegroundColor Gray
            Write-Host "           Assign to: $($assignTo -join ', ')" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "[DRY RUN] No changes made." -ForegroundColor Yellow
    return
}

# --- Confirmation prompt (interactive) ----------------------------------------
# =============================================================================
# STEP 3: Fetch existing WUG performance monitors to avoid duplicates
# =============================================================================
Write-Host "Checking existing performance monitors in WUG library..." -ForegroundColor Cyan

$existingMonitors = @(Get-WUGPerformanceMonitor -Search $NamePrefix -View 'info')
$existingLookup = @{}
foreach ($mon in $existingMonitors) {
    # Key by exact monitor name for dedup
    $existingLookup[$mon.Name] = $mon
}

Write-Host "  Found $($existingMonitors.Count) existing monitor(s) matching prefix '$NamePrefix'." -ForegroundColor Gray

# Pre-fetch existing monitor assignments per device (to skip already-assigned)
Write-Host "Checking existing device monitor assignments..." -ForegroundColor Cyan
$deviceExistingMonitors = @{}  # devId -> hashtable of monitorTypeId -> $true
foreach ($devId in $deviceDisks.Keys) {
    $deviceExistingMonitors[$devId] = @{}
    try {
        $assigned = @(Get-WUGPerformanceMonitor -DeviceId $devId -Search $NamePrefix -View 'basic')
        foreach ($a in $assigned) {
            $typeId = if ($a.MonitorTypeId) { $a.MonitorTypeId } elseif ($a.monitorTypeId) { $a.monitorTypeId } else { $null }
            if ($typeId) {
                $deviceExistingMonitors[$devId]["$typeId"] = $true
            }
        }
        Write-Verbose "  Device $devId ($($deviceInfo[$devId].Name)): $($assigned.Count) existing '$NamePrefix' monitors."
    }
    catch {
        Write-Verbose "  Could not check existing monitors for device ${devId}: $_"
    }
}
Write-Host "  Done." -ForegroundColor Gray
Write-Host ""

# =============================================================================
# STEP 4: Create library monitors and assign to devices
# =============================================================================
$createdCount        = 0
$skippedCount        = 0
$assignedCount       = 0
$alreadyAssignedCount = 0
$failedCount         = 0

# Cache: monitorName -> libraryMonitorId (for reuse across devices)
$monitorIdCache = @{}

# Pre-populate cache with existing monitors
foreach ($mon in $existingMonitors) {
    $monitorIdCache[$mon.Name] = if ($mon.MonitorId) { $mon.MonitorId } else { $mon.Id }
}

$totalSteps = $sortedInstances.Count * $activeCounters.Count
$stepIndex  = 0

foreach ($instance in $sortedInstances) {
    foreach ($counterKey in $activeCounters.Keys) {
        $stepIndex++
        $def     = $activeCounters[$counterKey]
        $monName = "${NamePrefix} - ${instance} - $($def.Label)"

        $pct = [Math]::Round(($stepIndex / $totalSteps) * 100)
        Write-Progress -Activity "Creating disk IO monitors" `
            -Status "$monName [$stepIndex of $totalSteps]" `
            -PercentComplete $pct

        # --- Create in library if not exists ----------------------------------
        if ($monitorIdCache.ContainsKey($monName)) {
            $libId = $monitorIdCache[$monName]
            Write-Verbose "Monitor '$monName' already exists (ID: $libId). Skipping creation."
            $skippedCount++
        }
        else {
            Write-Host "  Creating: $monName" -ForegroundColor White
            try {
                $result = Add-WUGPerformanceMonitor `
                    -Type WmiFormatted `
                    -Name $monName `
                    -WmiFormattedRelativePath $WmiClass `
                    -WmiFormattedPropertyName $def.Property `
                    -WmiFormattedDisplayname "$($def.Label) ($instance)" `
                    -WmiFormattedInstanceName $instance `
                    -WmiFormattedTimeout $WmiTimeout

                # Extract the new monitor ID from the result
                if ($result -and $result.data -and $result.data.idMap) {
                    $libId = $result.data.idMap.resultId
                }
                elseif ($result -match 'library ID:\s*(\d+)') {
                    $libId = $Matches[1]
                }
                else {
                    # Re-fetch from library by name
                    $refetch = @(Get-WUGPerformanceMonitor -Search $monName -View 'info')
                    $match = $refetch | Where-Object { $_.Name -eq $monName } | Select-Object -First 1
                    if ($match) {
                        $libId = if ($match.MonitorId) { $match.MonitorId } else { $match.Id }
                    }
                    else {
                        Write-Warning "    Could not determine library ID for '$monName'. Skipping assignments."
                        $failedCount++
                        continue
                    }
                }

                $monitorIdCache[$monName] = $libId
                $createdCount++
                Write-Host "    Created (ID: $libId)" -ForegroundColor Green
            }
            catch {
                Write-Error "    Failed to create '$monName': $_"
                $failedCount++
                continue
            }
        }

        # --- Assign to each device that has this disk instance ----------------
        $libId = $monitorIdCache[$monName]
        foreach ($devId in $deviceDisks.Keys) {
            if ($deviceDisks[$devId] -contains $instance) {
                $info = $deviceInfo[$devId]

                # Check if already assigned on this device
                if ($deviceExistingMonitors.ContainsKey($devId) -and $deviceExistingMonitors[$devId].ContainsKey("$libId")) {
                    Write-Verbose "  '$monName' already assigned to $($info.Name) (ID: $devId). Skipping."
                    $alreadyAssignedCount++
                    continue
                }

                Write-Verbose "  Assigning '$monName' to $($info.Name) (ID: $devId)"
                try {
                    Add-WUGPerformanceMonitorToDevice `
                        -DeviceId $devId `
                        -MonitorId $libId `
                        -PollingIntervalMinutes $PollingIntervalMinutes `
                        -Enabled "true"
                    $assignedCount++
                    # Update cache so subsequent runs in same session see it
                    if ($deviceExistingMonitors.ContainsKey($devId)) {
                        $deviceExistingMonitors[$devId]["$libId"] = $true
                    }
                }
                catch {
                    $errMsg = $_.Exception.Message
                    # Duplicate/already-assigned is not fatal
                    if ($errMsg -match '409|already assigned|already exists|duplicate') {
                        Write-Host "    Already assigned: $monName -> $($info.Name)" -ForegroundColor DarkGray
                        $alreadyAssignedCount++
                    }
                    else {
                        Write-Warning "    Failed to assign '$monName' to $($info.Name) (ID: ${devId}): $errMsg"
                        $failedCount++
                    }
                }
            }
        }
    }
}

Write-Progress -Activity "Creating disk IO monitors" -Completed

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "=== Disk IO Discovery Complete ===" -ForegroundColor Cyan
Write-Host "  Monitors created:      $createdCount" -ForegroundColor Green
Write-Host "  Monitors reused:       $skippedCount" -ForegroundColor Gray
Write-Host "  Assignments made:      $assignedCount" -ForegroundColor Green
Write-Host "  Already assigned:      $alreadyAssignedCount" -ForegroundColor Gray
Write-Host "  Failures:              $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host ""

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDSFSmElEgSlDH2
# DI/WHZvG3++G8QvuQ7iNxEjd9K0uIqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAOq3OwkltG8srPOfyD0BUV9EQHNVJ2IK4jmy1OW8npszANBgkqhkiG9w0BAQEF
# AASCAgDlcfslLkgGlSgG9W7BKmD/zMIobAs21XyrUNnEyzumjGZvUvxFnfsSPAGE
# UoYJTIU6Q+B7CFBEPpplrIdmBhLrozKQEM+bXbIZ208GQh0erub0+EzMkmDp1M2h
# E6kN7CcpZYt6FfTUq9Se8m0zLdmgS+j4u7uKqNpbl8ZBrRUTBqvZ/N4KbjXDAWjh
# EguSGr9qSFrsLsopYVeFrjxQq7xw+E3Wy6n1V8kDSKor4CpAorVynfFgnwk7um3z
# W2sEpsCCs4uFmoU4fHSxU62uoAPO8GnOrDbKhFg5SBWtSFYv8ZV2gsRZnSCEE4oJ
# JoaZUiVOODbh8F2c14LUw27nyDl2sYKmXuQ76enun0r/MdzNJyu1O4aY6aEkiaUB
# Q8uOJ/OFqOc7zVlspU5/g2KbDNgPWXlM5a4j9Y2/X3SlTmQRe/MqXuAGeXE+DSfY
# YXQQkm96v8YA2MTjUHV0Ci1HYq9cPM5diPmnPgVeK0Q/HoAuUa7glHRV5UvoAASh
# +eWzsyxR2b8EOLLYJ/9LwAWDO03U/eSO7gbmMbp4ySGKMoajHxJnAbY1z0IaLSN7
# eGMPPJFuFx2Dy0x8c87lmLv0uf0laA2w+TgiyhDpFtwVNZqrF3gbQgBWTfrY1Bda
# H9rHiWsTF+SabimAJc4oJHVQnS/l9S16r0JcWhIqjFQUN/4OkKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MTAwMjEzNTlaMC8GCSqGSIb3DQEJBDEiBCBMD4a+
# 36xKJfvQD1vPZYjgZZGbj06RZL5uQgOQBSNu+zANBgkqhkiG9w0BAQEFAASCAgA9
# bLDzqYLOoa+g0EbZP/V/11Ndbe7GxrcX7rxf/6gFlMTw78OVeAUZWkXYA0nYf7US
# rAhWViRAJB0arVppI1yxPc1Sk8/jUgWAUl2OQi4+XmDMFsrjALWXbLz6DTeEjrPo
# sZbET5D24Ue0Pg25+GL6B8LdmIfNBvDeE8xpoE6iHZtP77CJg6I7IghRfzrcedBr
# kc4N4PoBTh9/4UZypJzlaB5BnJ0JCDAuc0uTESwnl4iN1melvI2259WZWsm1MBCH
# CPHv1JHzHR3v/Kp3eF1aeulV6yMBqrcDG9OVqWzc7046mfPG+Ln1qNtHgHBkqL6d
# gTZm1jjSdHG3J3HG33AjE8yjyh/X11BVxcQtfUZu7EzRSvfi9zGS/YVrT9HqhUSF
# ZBHY29M9NIMFyYgd7JMwH+CdV/tzHO71+mgFL4UG9SpOrewxffagRUd8AtkPu/Vi
# xk+jfN9dg7Vh89xYGj1aD6r0Dv9BT1NDDg6OR/7REGHW0motEp7k1ZG4bswc7Exf
# AD/l9VKBgsfwmpevlFEKWURaYZ7qZD1IuAuEvDVSlniACdB7y3HayoEmJvLPk/PV
# 11Mh0sKuuIhNFifNxPYxIilN8ezwLWnwA1nlVjXoeRa1kIBgQmGcENJ1C9xuk2tW
# aJJ3blx/mXCojhEptKVZ5wrEbM4e0MzPoBlVNcWcKw==
# SIG # End signature block
