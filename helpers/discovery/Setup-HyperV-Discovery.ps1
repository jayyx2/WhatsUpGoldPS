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
        if (-not $NonInteractive) {
            Write-Host ""
            $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
            if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
                $WUGServer = $wugInput.Trim()
            }
        }

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
            $wugCred = $WUGCredential
        }
        elseif ($NonInteractive) {
            $wugResolved = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -NonInteractive
            if (-not $wugResolved) {
                Write-Error 'No WUG credentials in vault. Run interactively first to cache them, or pass -WUGCredential.'
                return
            }
            $wugCred = $wugResolved.Credential
            if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
        }
        else {
            $wugCred = Get-Credential -Message "WhatsUp Gold admin credentials for $WUGServer"
        }
        Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors

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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBp69r8wM8bQmHy
# k2G1OJQDGX1wbxgCxP9mjfKe9TWNW6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDdswPM0Z91YjwmTJT6KGJuJmYAxjuuSrr+YC3LMXB9qjANBgkqhkiG9w0BAQEF
# AASCAgCAsST2W3XouCtaTVRyuHr67Av1Ni3wemFQt9ElFJa+iU/U49xoUzvkTq6z
# ZbsvCBPo0b+Y7Rh2AS9QeJ2DMucgJP2GbfUAAKMS1xeykikXNFN43RLbBq5+Kzxz
# 9gNlv1U9x/nQ/k3CnuONtHGQqJJrhk+Qe8x+wX2lbUQ3/1BGy5bup83tmBJ2l6Hj
# I4bICXaDdz4n3XJMwcRXbGec/J06eJwVD7HIOrhOeCr/nOZnHepkX8q4g7eSgPX3
# H4I/bneLRGze/8L1tPggIZlUA9Z364e4I/8LSsx1/oSe4DEYE5IVF7Zcti4eqt/y
# iv3eYid1m1OMMjW/P2xuNAvWBZTfEz2R1cTxh4M8XJcdpVj0iM65YBVEj5LfL860
# rsumbZ2QDd9QgCKavgvjLGjUV3y4OxzEUDYxM9eb4zqQuHsnyKMoaq4EjanCh4S3
# P5TAbTfZ2P3OiW24r9CGI9h3PKRAd5h3kzHwSP4Avy7C1X5MWy0NZAHolq3XTuZC
# SRpZjTt5T9kaBUc7He5VIQwgliVjwHO1DmkjlFMCk0gksy53PXCjl2sM5uwX6DVF
# qEMbcPWwelvZnSpQgtM9Za3hwZ9UKKIbkexjaeVfDzNxDFL/PdB0Zlj5CMpGOIGF
# rL+indamViTpo7aEjUCAJrrpQa5gPgodM7p3f4UoQV2Mjoc6xqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MDYxOTMzMzVaMC8GCSqGSIb3DQEJBDEiBCDgRqnJ
# 3hLnRgcaKGi1lCyGSwajL1jSaMc1ZMAdlJySHTANBgkqhkiG9w0BAQEFAASCAgBc
# KKnpBlg/R01PmQyhwlXxufsXben+I13c7KaJjPUCkSXZrJCShWC2l0fD9Xcnxnky
# aUPBkUasHJTwrGMaMW33Si8RBPiF/dCUBEDbRx4oVjp5941Ixo6vp6iLIoSE2tup
# wSYrPVUOpERUe7tuPOfRGc6VAPzTr4knj+3N3bw5Z2M9j7JDZyvuHZym2JaFg3vA
# tgTiig5vfyRPOtZ9X2ZUn/hXSEyHUBWA4x51OGAT8ewiTe6adO9AYOaqeIWhQMkL
# yZw3s/GXk2yrzlGEEyT+qxa6+kHp2d9QIm+//6jAbPnAOOf2Z+LUGPbxMbB6lIK9
# PVZ8GbtTE2xKdXU0HvV9+93hmprG+B+zk87iUGeesKKIP6H8yaS6LHh9/vUk/DR6
# CI3QgYyvXK5Egt7uMNEaN4Ws3isdPp7evViGehYQTdknPlsgV4kbIX0kMY1lpyEN
# HAobvi+jxOzRgANgpmsdBBU6mgt34EzcJpURmtz6tmJvGZXhvR0msKosqDGfrsLt
# x68Bqd+Stvvyg7c1O25CZmJJEPT7df45vyya9aCxd3zVuumvoNmt+HOxbt+TnB9/
# n/MKJ1bcjja13B/OoSpfurvpzW4N49v2lddEPBj662rpipH0xq4YxzR2XwcnSL8M
# kT6qHarpkmQWJXy7zD9MX5Tj54ddCw9OhZ/ce/2yKw==
# SIG # End signature block
