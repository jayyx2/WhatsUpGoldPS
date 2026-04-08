<#
.SYNOPSIS
    Hyper-V Discovery — Discover hosts/VMs and optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers Hyper-V hosts and their virtual machines
    using CIM sessions, then lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Generate Hyper-V HTML dashboard (live metrics)
      [6] Exit

    First Run:
      1. Prompts for Hyper-V host(s), credentials (domain\user + password)
      2. Stores credentials in DPAPI vault (encrypted to user + machine)
      3. Discovers hosts + VMs via CIM sessions
      4. Shows summary, then asks what to do with the results

    Subsequent Runs:
      Loads credentials from vault automatically — skips credential prompt.

    Prerequisites:
      Hyper-V PowerShell module (comes with Hyper-V role or RSAT).
      WinRM must be enabled on target Hyper-V hosts.

.PARAMETER Target
    Hyper-V host(s) — IP address, hostname, or FQDN. Accepts multiple values.
    When omitted in interactive mode, prompts for input.

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and parameter defaults.
    Ideal for scheduled task execution.

.EXAMPLE
    .\Setup-HyperV-Discovery.ps1
    # Interactive mode — prompts for everything.

.EXAMPLE
    .\Setup-HyperV-Discovery.ps1 -Target 'hyperv01.lab.local' -Action ExportJSON -NonInteractive
    # Scheduled mode — uses vault credentials, exports JSON, no prompts.

.NOTES
    WhatsUpGoldPS module is only needed if you choose option [1].
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

# --- Output directory (persistent default for scheduled runs) -----------------
if (-not $OutputPath) {
    if ($NonInteractive) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Configuration -----------------------------------------------------------
$DefaultHost = 'hyperv01.lab.local'      # Default Hyper-V host (interactive fallback)

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-HyperV.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Hyper-V Discovery ===" -ForegroundColor Cyan
Write-Host ""

# --- Resolve Hyper-V host(s) --------------------------------------------------
if ($Target) {
    $HypervHosts = @($Target)
}
elseif ($NonInteractive) {
    $HypervHosts = @($DefaultHost)
}
else {
    Write-Host "Enter Hyper-V host(s) — IP address, hostname, or FQDN." -ForegroundColor Cyan
    Write-Host "For multiple hosts, separate with commas." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt "Hyper-V host(s) [default: $DefaultHost]"
    if ([string]::IsNullOrWhiteSpace($hostInput)) {
        $hostInput = $DefaultHost
    }
    $HypervHosts = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($HypervHosts.Count -eq 0) {
    Write-Error 'No valid host provided. Exiting.'
    return
}
Write-Host "Targets: $($HypervHosts -join ', ')" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 2: Credentials (DPAPI vault — encrypted, cached)
# ==============================================================================
$vaultName = "HyperV.$($HypervHosts[0]).Credential"
$credSplat = @{ Name = $vaultName; CredType = 'PSCredential'; ProviderLabel = 'Hyper-V' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
$HypervCred = Resolve-DiscoveryCredential @credSplat
if (-not $HypervCred) {
    Write-Error 'No credentials provided. Exiting.'
    return
}

# ==============================================================================
# STEP 3: Discover — connect to Hyper-V hosts and enumerate VMs
# ==============================================================================
Write-Host ""
Write-Host "Connecting to Hyper-V hosts: $($HypervHosts -join ', ')..." -ForegroundColor Cyan

$plan = Invoke-Discovery -ProviderName 'HyperV' `
    -Target $HypervHosts `
    -Credential @{ Username = $HypervCred.UserName; Password = $HypervCred.GetNetworkCredential().Password; PSCredential = $HypervCred }

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check host connectivity and credentials."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $type = $item.Attributes['HyperV.DeviceType']
    switch ($type) {
        'Host' {
            $hostName = $item.Attributes['HyperV.HostName']
            $key  = "host:${hostName}"
            $name = $hostName
            $ip   = $item.Attributes['HyperV.HostIP']
            $parentHost = $null
        }
        'VM' {
            $vmName = $item.Attributes['HyperV.VMName']
            $vmHost = $item.Attributes['HyperV.Host']
            $key  = "vm:${vmHost}:${vmName}"
            $name = $vmName
            $ip   = $item.Attributes['HyperV.VMIP']
            $parentHost = $vmHost
        }
        default { continue }
    }
    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name       = $name
            IP         = $ip
            Type       = $type
            ParentHost = $parentHost
            Attrs      = $item.Attributes
            Items      = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$hostDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'Host' })
$vmDevices   = @($devicePlan.Values | Where-Object { $_.Type -eq 'VM' })
$vmWithIP    = @($vmDevices | Where-Object { $_.IP })
$vmNoIP      = @($vmDevices | Where-Object { -not $_.IP })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } |
    Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
    Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Hyper-V Hosts:         $($hostDevices.Count)" -ForegroundColor White
Write-Host "  VMs (with IP):         $($vmWithIP.Count)" -ForegroundColor White
Write-Host "  VMs (no IP):           $($vmNoIP.Count)" -ForegroundColor White
Write-Host "  Total WUG devices:     $($hostDevices.Count + $vmWithIP.Count) (hosts + VMs w/ IP)" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

Write-Host "Monitor templates:" -ForegroundColor Cyan
foreach ($t in $activeTemplates) { Write-Host "  [Active] $t" -ForegroundColor White }
foreach ($t in $perfTemplates)   { Write-Host "  [Perf]   $t" -ForegroundColor White }
Write-Host ""

if ($vmNoIP.Count -gt 0) {
    Write-Host "VMs without IP (integration services needed — monitors attach to parent host):" -ForegroundColor Yellow
    foreach ($vm in $vmNoIP) {
        Write-Host "    $($vm.Name) (on $($vm.ParentHost))" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    ForEach-Object { [PSCustomObject]@{
        Device   = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { '(via host)' }
        Monitors = $_.Items.Count
        Attrs    = $_.Attrs.Count
    }} |
    Format-Table -AutoSize

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================

# --- Map Action parameter to menu choice number ---
$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG' { $choice = '1' }
        'ExportJSON' { $choice = '2' }
        'ExportCSV' { $choice = '3' }
        'ShowTable' { $choice = '4' }
        'Dashboard' { $choice = '5' }
        'None' { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice) {
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push monitors to WhatsUp Gold (creates devices + monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate Hyper-V HTML dashboard (live metrics)"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host "  [7] Dashboard + Push to WUG"
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-7]"
}

# Handle DashboardAndPush: run Dashboard then PushToWUG sequentially
if ($choice -eq '7') {
    $actionsToRun = @('5', '1')
} else {
    $actionsToRun = @($choice)
}

foreach ($currentChoice in $actionsToRun) {
switch ($currentChoice) {
    '1' {
        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
            if (Test-Path $repoPsd1) { Import-Module $repoPsd1 -Force -ErrorAction Stop }
            else { Import-Module WhatsUpGoldPS -ErrorAction Stop }
        }
        catch {
            Write-Error "Could not load WhatsUpGoldPS module. Is it installed? $_"
            return
        }
        # Dot-source internal helper so scripts can call Get-WUGAPIResponse directly
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if ($WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
        }
        else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors
        }

        Write-Host ""
        Write-Host "Creating devices in WUG..." -ForegroundColor Cyan

        $wugDeviceMap = @{}
        $devicesCreated = 0
        $devicesFound   = 0

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $addIP = $null
            if ($dev.Type -eq 'Host') { $addIP = $dev.IP }
            elseif ($dev.Type -eq 'VM' -and $dev.IP) { $addIP = $dev.IP }
            else { continue }
            if (-not $addIP) { continue }

            $existingDevice = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.networkAddress -eq $addIP -or $_.hostName -eq $addIP -or
                        $_.displayName -eq $addIP -or $_.displayName -eq $dev.Name
                    } | Select-Object -First 1
                    if (-not $existingDevice -and $searchResults.Count -eq 1) {
                        $existingDevice = $searchResults[0]
                    }
                }
            }
            catch { Write-Verbose "Search for '$addIP' returned error: $_" }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $devicesFound++
                Write-Host "  Found: $($existingDevice.displayName) (ID: $($existingDevice.id)) [$($dev.Type)]" -ForegroundColor Green
            }
            else {
                Write-Host "  Adding $addIP ($($dev.Name)) [$($dev.Type)]..." -ForegroundColor Yellow
                try {
                    Add-WUGDevice -IpOrName $addIP -GroupId 0 | Out-Null
                    Start-Sleep -Seconds 2
                    $newDevice = @(Get-WUGDevice -SearchValue $addIP) | Select-Object -First 1
                    if ($newDevice) {
                        $wugDeviceMap[$key] = $newDevice.id
                        $devicesCreated++
                        Write-Host "  Added: $($newDevice.displayName) (ID: $($newDevice.id))" -ForegroundColor Green
                    }
                    else { Write-Warning "Added '$addIP' but could not find it in WUG." }
                }
                catch { Write-Warning "Failed to add device '$addIP': $_" }
            }
        }

        # Map no-IP VMs to parent host
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -eq 'VM' -and -not $dev.IP -and -not $wugDeviceMap.ContainsKey($key)) {
                $parentKey = "host:$($dev.ParentHost)"
                if ($wugDeviceMap.ContainsKey($parentKey)) {
                    $wugDeviceMap[$key] = $wugDeviceMap[$parentKey]
                    Write-Host "  $($dev.Name) (VM, no IP) -> host $($dev.ParentHost)" -ForegroundColor DarkGray
                }
                else {
                    Write-Warning "No WUG device for VM '$($dev.Name)' — parent host '$($dev.ParentHost)' not found."
                }
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing" -ForegroundColor Cyan

        Write-Host "Setting device attributes..." -ForegroundColor Cyan
        foreach ($key in @($wugDeviceMap.Keys)) {
            $devId = $wugDeviceMap[$key]
            $dev   = $devicePlan[$key]
            foreach ($attrName in $dev.Attrs.Keys) {
                try {
                    Set-WUGDeviceAttribute -DeviceId $devId -Name $attrName -Value $dev.Attrs[$attrName] | Out-Null
                }
                catch { Write-Verbose "Attribute set error for $attrName on device $devId`: $_" }
            }
        }

        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
            }
        }

        Write-Host ""
        Write-Host "Syncing monitors..." -ForegroundColor Cyan

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        Write-Host ""
        Write-Host "Sync complete!" -ForegroundColor Green
        Write-Host "  Devices in WUG:              $($wugDeviceMap.Count)" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created: $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:          $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):      $($result.Skipped)" -ForegroundColor White
        Write-Host "  Attributes set:               $($result.AttrsUpdated)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            Write-Host "  Failed:                       $($result.Failed)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Done! Monitors pushed to WhatsUp Gold." -ForegroundColor Green
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'hyperv-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'hyperv-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate Hyper-V HTML Dashboard
        # Reuses host/cluster/VM data already collected by Invoke-Discovery
        # Only reconnects to gather detailed VM metrics (disk, NIC, etc.)
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()

        # Helper: format uptime consistently as human-readable text
        function Format-UptimeText {
            param($RawUptime)
            if (-not $RawUptime) { return '' }
            $ts = $null
            if ($RawUptime -is [timespan]) {
                $ts = $RawUptime
            } else {
                $str = "$RawUptime"
                if (-not $str) { return '' }
                # Already human-readable? (e.g. "18.3 hours")
                if ($str -match '^\d+(\.\d+)?\s+(hour|minute|day|second)') { return $str }
                # Try parsing as TimeSpan
                try { $ts = [timespan]::Parse($str) } catch { return $str }
            }
            if ($ts.TotalDays -ge 1) {
                return "$([math]::Round($ts.TotalDays, 1)) days"
            } elseif ($ts.TotalHours -ge 1) {
                return "$([math]::Round($ts.TotalHours, 1)) hours"
            } elseif ($ts.TotalMinutes -ge 1) {
                return "$([math]::Round($ts.TotalMinutes, 1)) minutes"
            } else {
                return "$([math]::Round($ts.TotalSeconds, 0)) seconds"
            }
        }

        # --- Extract host info and cluster info from plan attributes ---
        $dashClusterInfo = $null
        $dashClusterNodeStates = @{}
        $dashClusterVMOwners = @{}
        $dashHosts = @{}   # hostName -> plan attrs
        $dashVMs   = @{}   # "host:vmname" -> plan attrs

        foreach ($item in $plan) {
            $devType = $item.Attributes['HyperV.DeviceType']
            if ($devType -eq 'Host' -and $item.ItemType -eq 'ActiveMonitor') {
                $hName = $item.Attributes['HyperV.HostName']
                if (-not $dashHosts.ContainsKey($hName)) {
                    $dashHosts[$hName] = $item.Attributes
                }
                # Extract cluster info from first host that has it
                if (-not $dashClusterInfo -and $item.Attributes['HyperV.ClusterName']) {
                    $dashClusterInfo = @{
                        ClusterName = $item.Attributes['HyperV.ClusterName']
                        Nodes       = @($item.Attributes['HyperV.ClusterNodes'] -split ',')
                    }
                }
                if ($item.Attributes['HyperV.NodeState']) {
                    $dashClusterNodeStates[$hName] = $item.Attributes['HyperV.NodeState']
                }
            }
            elseif ($devType -eq 'VM' -and $item.ItemType -eq 'ActiveMonitor') {
                $vmName = $item.Attributes['HyperV.VMName']
                $vmHost = $item.Attributes['HyperV.Host']
                $key = "${vmHost}:${vmName}"
                if (-not $dashVMs.ContainsKey($key)) {
                    $dashVMs[$key] = $item.Attributes
                }
                if ($item.Attributes['HyperV.OwnerNode']) {
                    $dashClusterVMOwners[$vmName] = $item.Attributes['HyperV.OwnerNode']
                    if ($item.Attributes['HyperV.VMId']) {
                        $dashClusterVMOwners[$item.Attributes['HyperV.VMId']] = $item.Attributes['HyperV.OwnerNode']
                    }
                }
            }
        }

        # --- Build host rows from plan data (no reconnection needed) ---
        foreach ($hName in @($dashHosts.Keys | Sort-Object)) {
            $ha = $dashHosts[$hName]
            $nodeState = if ($dashClusterNodeStates.ContainsKey($hName)) { $dashClusterNodeStates[$hName] } else { '' }

            # Combined CPU: "2s/4c/4t"
            $cpuText = "$($ha['HyperV.CPUSockets'])s/$($ha['HyperV.CPUCores'])c/$($ha['HyperV.CPULogical'])t"

            # Combined Memory: "10.7 / 32.0 GB (66.5%)"
            $ramTotal = [double]$ha['HyperV.RAMTotalGB']
            $ramFree  = [double]$ha['HyperV.RAMFreeGB']
            $ramUsed  = [math]::Round($ramTotal - $ramFree, 1)
            $ramPct   = if ($ramTotal -gt 0) { [math]::Round(($ramUsed / $ramTotal) * 100, 1) } else { 0 }
            $memText  = "$ramUsed / $ramTotal GB ($ramPct%)"

            # Combined Storage: "C: 120/500 GB, D: 80/200 GB"
            $storText = if ($ha['HyperV.DiskSummary']) { $ha['HyperV.DiskSummary'] } else { '' }

            # Combined Network: "4 NICs (switch1, switch2)"
            $netText = "$($ha['HyperV.NicCount']) NICs"
            if ($ha['HyperV.SwitchNames']) { $netText += " ($($ha['HyperV.SwitchNames']))" }

            # Combined Cluster: "hvcluster1 (Up)"
            $clText = ''
            if ($dashClusterInfo) {
                $clText = $dashClusterInfo.ClusterName
                if ($nodeState) { $clText += " ($nodeState)" }
            }

            $dashboardRows += [PSCustomObject]@{
                Type        = 'Host'
                Name        = $hName
                State       = if ($ha['HyperV.Status']) { $ha['HyperV.Status'] } else { 'running' }
                Status      = if ($ha['HyperV.Status']) { $ha['HyperV.Status'] } else { 'running' }
                IPAddress   = $ha['HyperV.HostIP']
                Host        = $hName
                CPU         = $cpuText
                Memory      = $memText
                Storage     = $storText
                Network     = $netText
                Cluster     = $clText
                Generation  = ''
                Snapshots   = ''
                Heartbeat   = ''
                Replication = ''
                Uptime      = Format-UptimeText $ha['HyperV.Uptime']
                Notes       = if ($ha['HyperV.Manufacturer']) { "$($ha['HyperV.Manufacturer']) $($ha['HyperV.Model'])" } else { '' }
            }
        }

        # --- Gather detailed VM metrics (reconnect per-host, once) ---
        # Group VMs by host to minimize connections
        $vmsByHost = @{}
        foreach ($key in $dashVMs.Keys) {
            $va = $dashVMs[$key]
            $vmHost = $va['HyperV.Host']
            if (-not $vmsByHost.ContainsKey($vmHost)) {
                $vmsByHost[$vmHost] = [System.Collections.ArrayList]@()
            }
            [void]$vmsByHost[$vmHost].Add($va)
        }

        foreach ($hostTarget in @($vmsByHost.Keys | Sort-Object)) {
            $hostAttrs = $dashHosts[$hostTarget]
            $hostIP = if ($hostAttrs) { $hostAttrs['HyperV.HostIP'] } else { $hostTarget }
            # Connect using IP if available (more reliable for WMI), fall back to hostname
            $connectTarget = if ($hostIP) { $hostIP } else { $hostTarget }

            $session = $null
            $dashConnMethod = $null

            # Try WSMan first, then DCOM
            try {
                $wsOpt = New-CimSessionOption -Protocol Wsman
                $session = New-CimSession -ComputerName $connectTarget -Credential $HypervCred -SessionOption $wsOpt -ErrorAction Stop
                $dashConnMethod = 'WSMan'
            }
            catch {
                try {
                    $dcOpt = New-CimSessionOption -Protocol Dcom
                    $session = New-CimSession -ComputerName $connectTarget -Credential $HypervCred -SessionOption $dcOpt -ErrorAction Stop
                    $dashConnMethod = 'DCOM'
                }
                catch {
                    Write-Warning "Could not connect to $hostTarget ($connectTarget) for VM details: $_"
                    # Add VM rows with basic info from plan
                    foreach ($va in $vmsByHost[$hostTarget]) {
                        $vmIsClustered = $dashClusterVMOwners.ContainsKey($va['HyperV.VMName']) -or
                                         $dashClusterVMOwners.ContainsKey($va['HyperV.VMId'])
                        $clText = ''
                        if ($vmIsClustered -and $dashClusterInfo) {
                            $ow = if ($va['HyperV.OwnerNode']) { $va['HyperV.OwnerNode'] } else { '' }
                            $clText = "$($dashClusterInfo.ClusterName)"
                            if ($ow) { $clText += " (owner: $ow)" }
                        }
                        $dashboardRows += [PSCustomObject]@{
                            Type = 'VM'; Name = $va['HyperV.VMName']; State = $va['HyperV.State']
                            Status = 'OK'; IPAddress = if ($va['HyperV.VMIP']) { $va['HyperV.VMIP'] } else { 'N/A' }
                            Host = $hostTarget; CPU = "$($va['HyperV.CPUCount']) vCPU"
                            Memory = if ($va['HyperV.MemoryGB']) { "$($va['HyperV.MemoryGB']) GB" } else { '' }
                            Storage = ''; Network = ''; Cluster = $clText
                            Generation = ''; Snapshots = ''; Heartbeat = 'N/A'
                            Replication = ''; Uptime = ''; Notes = ''
                        }
                    }
                    continue
                }
            }
            Write-Host "  Connected to $hostTarget for VM details ($dashConnMethod)" -ForegroundColor DarkGray

            try {
                # Get VMs on this host
                if ($dashConnMethod -eq 'WSMan') {
                    $vms = Get-HypervVMs -CimSession $session
                } else {
                    $vms = Get-HypervVMs -ComputerName $connectTarget -Credential $HypervCred
                }
            }
            catch {
                Write-Warning "Error enumerating VMs on $hostTarget : $_"
                # Fall back to plan data for all VMs on this host
                foreach ($va in $vmsByHost[$hostTarget]) {
                    $vmIsClustered = $dashClusterVMOwners.ContainsKey($va['HyperV.VMName']) -or
                                     $dashClusterVMOwners.ContainsKey($va['HyperV.VMId'])
                    $clText = ''
                    if ($vmIsClustered -and $dashClusterInfo) {
                        $ow = if ($va['HyperV.OwnerNode']) { $va['HyperV.OwnerNode'] } else { '' }
                        $clText = "$($dashClusterInfo.ClusterName)"
                        if ($ow) { $clText += " (owner: $ow)" }
                    }
                    $dashboardRows += [PSCustomObject]@{
                        Type = 'VM'; Name = $va['HyperV.VMName']; State = $va['HyperV.State']
                        Status = 'OK'; IPAddress = if ($va['HyperV.VMIP']) { $va['HyperV.VMIP'] } else { 'N/A' }
                        Host = $hostTarget; CPU = "$($va['HyperV.CPUCount']) vCPU"
                        Memory = if ($va['HyperV.MemoryGB']) { "$($va['HyperV.MemoryGB']) GB" } else { '' }
                        Storage = ''; Network = ''; Cluster = $clText
                        Generation = ''; Snapshots = ''; Heartbeat = 'N/A'
                        Replication = ''; Uptime = ''; Notes = ''
                    }
                }
                $vms = @()
            }

            try {
            foreach ($vm in $vms) {
                Write-Host "    VM: $($vm.Name)" -ForegroundColor DarkGray
                try {
                    if ($dashConnMethod -eq 'WSMan') {
                        $vmDetail = Get-HypervVMDetail -CimSession $session -VM $vm
                    } else {
                        $vmDetail = Get-HypervVMDetail -ComputerName $connectTarget -Credential $HypervCred -VM $vm
                    }

                    $vmIsClustered = $false
                    $vmOwner = ''
                    if ($dashClusterVMOwners.Count -gt 0) {
                        $vmIdStr = "$($vmDetail.VMId)"
                        $vmNameStr = "$($vmDetail.Name)"
                        if ($dashClusterVMOwners.ContainsKey($vmIdStr)) {
                            $vmOwner = $dashClusterVMOwners[$vmIdStr]
                            $vmIsClustered = $true
                        } elseif ($dashClusterVMOwners.ContainsKey($vmNameStr)) {
                            $vmOwner = $dashClusterVMOwners[$vmNameStr]
                            $vmIsClustered = $true
                        }
                    }

                    # Combined CPU: "0% (8 vCPU)"
                    $cpuText = "$($vmDetail.CPUUsagePct) ($($vmDetail.CPUCount) vCPU)"

                    # Combined Memory: "16.4 GB assigned" or "2 GB (dynamic)"
                    $memText = "$($vmDetail.MemoryAssignedGB) GB"
                    if ($vmDetail.DynamicMemory -eq 'True') {
                        $memText += " / $($vmDetail.MemoryStartupGB) GB (dynamic)"
                    }

                    # Combined Storage: "1 disk, 40 GB"
                    $storText = "$($vmDetail.DiskCount) disk"
                    if ([int]$vmDetail.DiskCount -ne 1) { $storText += 's' }
                    if ([double]$vmDetail.DiskTotalGB -gt 0) { $storText += ", $($vmDetail.DiskTotalGB) GB" }

                    # Combined Network: "2 NICs (vSwitch, VLAN 16)"
                    $netText = "$($vmDetail.NicCount) NIC"
                    if ([int]$vmDetail.NicCount -ne 1) { $netText += 's' }
                    $netExtra = @()
                    if ($vmDetail.SwitchNames) { $netExtra += $vmDetail.SwitchNames }
                    if ($vmDetail.VLanIds)     { $netExtra += "VLAN $($vmDetail.VLanIds)" }
                    if ($netExtra.Count -gt 0) { $netText += " ($($netExtra -join ', '))" }

                    # Combined Cluster: "hvcluster1 (owner: hyperv1)"
                    $clText = ''
                    if ($vmIsClustered -and $dashClusterInfo) {
                        $clText = "$($dashClusterInfo.ClusterName)"
                        if ($vmOwner) { $clText += " (owner: $vmOwner)" }
                    }

                    $dashboardRows += [PSCustomObject]@{
                        Type        = 'VM'
                        Name        = $vmDetail.Name
                        State       = $vmDetail.State
                        Status      = $vmDetail.Status
                        IPAddress   = $vmDetail.IPAddress
                        Host        = $hostTarget
                        CPU         = $cpuText
                        Memory      = $memText
                        Storage     = $storText
                        Network     = $netText
                        Cluster     = $clText
                        Generation  = $vmDetail.Generation
                        Snapshots   = $vmDetail.SnapshotCount
                        Heartbeat   = $vmDetail.Heartbeat
                        Replication = $vmDetail.ReplicationState
                        Uptime      = Format-UptimeText $vmDetail.Uptime
                        Notes       = $vmDetail.Notes
                    }
                }
                catch {
                    Write-Warning "    Error getting details for VM '$($vm.Name)': $_"
                    # Fallback row with basic VM enumeration data
                    $memFallback = if ($vm.MemoryAssigned) { "$([math]::Round($vm.MemoryAssigned / 1GB, 2)) GB" } else { '' }
                    $dashboardRows += [PSCustomObject]@{
                        Type        = 'VM'
                        Name        = "$($vm.Name)"
                        State       = "$($vm.State)"
                        Status      = 'OK'
                        IPAddress   = 'N/A'
                        Host        = $hostTarget
                        CPU         = "$($vm.ProcessorCount) vCPU"
                        Memory      = $memFallback
                        Storage     = ''
                        Network     = ''
                        Cluster     = ''
                        Generation  = "$($vm.Generation)"
                        Snapshots   = ''
                        Heartbeat   = 'N/A'
                        Replication = ''
                        Uptime      = Format-UptimeText $vm.Uptime
                        Notes       = '(detail error)'
                    }
                }
            }
            } # end try wrapping foreach
            catch {
                Write-Warning "Error collecting VM metrics from $hostTarget : $_"
            }
            finally {
                if ($session) {
                    try { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue } catch { }
                }
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashReportTitle = "Hyper-V Dashboard"
            $dashTempPath = Join-Path $OutputDir 'Hyperv-Dashboard.html'

            $null = Export-HypervDiscoveryDashboardHtml `
                -DashboardData $dashboardRows `
                -OutputPath $dashTempPath `
                -ReportTitle $dashReportTitle

            Write-Host ""
            Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
            $dRunning = @($dashboardRows | Where-Object { $_.State -eq 'Running' }).Count
            $dOff     = @($dashboardRows | Where-Object { $_.State -eq 'Off' }).Count
            $dOther   = @($dashboardRows | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'Off' }).Count
            Write-Host "  VMs: $($dashboardRows.Count)  |  Running: $dRunning  |  Off: $dOff  |  Other: $dOther" -ForegroundColor White

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugDashPath = Join-Path $wugDashDir 'Hyperv-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/Hyperv-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                    Write-Host "  Manual copy: Copy-Item '$dashTempPath' '$wugDashPath'" -ForegroundColor Yellow
                }
                Deploy-DashboardWebConfig -Path $wugDashDir
            }
            else {
                Write-Host ""
                Write-Host "WUG NmConsole directory not found locally." -ForegroundColor Yellow
                Write-Host "Copy the file to your WUG server:" -ForegroundColor Yellow
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\dashboards\Hyperv-Dashboard.html'" -ForegroundColor Cyan
            }
        }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "Re-run anytime to discover new Hyper-V hosts/VMs." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+Jxs6MfoDuEaQ
# glUzfdG3dTMmx+jHPhAZ9Wv0NGps2KCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBdNqS6
# 9X2lxn/y9pJyAd8UtXTmzhNUx4Q98cp6JoZJrjANBgkqhkiG9w0BAQEFAASCAgAa
# hu3MGCqYA249gaExh2AZQjTOWzLD36iCIS8I2YARjYVxbCt/RGg2AM/fWcFpF91g
# VgGNUTlXBMnfVmfWVseXzaYjlqjm1FSFU52iDnCvDY03MPICfidPtvmkYDnwUO4Z
# PmqOPFNzPdRBGcb/2Dlg2VmGorUiwVySZCVaD6Xqj7DyP5xwCQGQuupot2NJF/Gg
# 8Ar2ootzwaBqw+jTdqU09JfGJEqAPLKkaX+cp9eXkOqu+lAjfemyJXj6tyDxgiq7
# kWhgtr6TzzkxcarVu6NFH/7vO0IXW9aGzaYbHf8gwCxbtTRRV1fnDjMdSGBhf0AF
# yCGKUiIM7UuDhbrVUUZUAPkHxn/q08uZzGjT7qIKwJTySXO9D6AgKr2qOnOcnpKu
# CWVl6yM4rL0DhNsTb7PxhiWv9wPlsjK1XEA7BIIVDgUWPwyl0aCAiuLB36a8ozYO
# vfsIFxe+bBWF/ExNNzqmNhdxj7OhIoL4jA17FWQNgbrZ/DIwCTbMvCPfMj+AIyuD
# zRmmXqr2iVjkRFEzQNHqfPkfxYazhxfD5p5+9M0UYObjFbdxTamA6EPHtn3m6X+b
# Vu6/M1bxFJAGNFjCUxdLtF1THXU5c9ZLQqQLHOq1d+L0GHz/EXC0iy5KL+cFxnim
# HxasPSxsd09Ov5ydGQCI1kmrhXoKr+YdmEVZghCZMqGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzExNTE0
# OVowPwYJKoZIhvcNAQkEMTIEMA2arqN/6XdLevHIY5FEs8zoraYgJjXVS0c18W0q
# kgwIGUfbw1sdk6id/yVCzk5S9TANBgkqhkiG9w0BAQEFAASCAgAQTHzAOwTT2fdH
# qm3DSmzo42EORS39jNubg94KYrIPo6WhVrqD2Ng2uujFvi/x/HkFKaiqMf75Arpm
# aNDO2AxhRZpewWdN1aoxTM0zPOtqa0UofDZB+snexcfk4QLJ2uojetmsNT0eu525
# 4fz4v+O2lW8Z+aJx2oSjFn73gsn5se26QHB1UADFV19Tm+sprO5HuAttmTEHvvQ+
# Cd/rA30fOte4LJcU91MNZPdDVy/gZrVWS5lgMbp2Jc8LhJZMJQRHd9cv2AFHHdb6
# 2hMmP5qby/1LvMjDARMJgOls/8h++L20x84HT6SQfbYJkjCWHJqZI7rTsGPK3oiE
# 0T80oZEW36QCzDh84ylzsG4wbs7+guAQSAYFssMDQwSSHSG18Q2H97p5yhWMNgJN
# 9r01n8IMhaiDmgWxuMNNXhhJJCrnxgw0tCRM/00pSzAJBIDW8a7s5A/L745RmR+E
# AzsJ9AfTTWvdaZ0NwHzG5QsljT+voCWgjum+w5tIMH5BlgxIQL05Xrpbuz+AxUse
# SJyjH/tv0RIx7c1wHPHZ2Exup94RDPjmW7kQqm/+CEx7aCUXaNIYLo/gIsBL/xt4
# Svi+qeqXQhHwa1gCe5wWK1+JhEhDs43WPkB6sZVwlWKPVIBPhKlAcEgL1VOseS/u
# 79FGOvay44xxV5UryUErgKgWgr1bDA==
# SIG # End signature block
