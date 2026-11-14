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

.PARAMETER HyperVCredential
    Optional Hyper-V Windows credential supplied by another vault or caller.
    When omitted, the existing discovery-vault lookup is used.

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

    [PSCredential]$HyperVCredential,

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
$HypervCred = if ($HyperVCredential) { $HyperVCredential } else { Resolve-DiscoveryCredential @credSplat }
if (-not $HypervCred) {
    Write-Error 'No credentials provided. Exiting.'
    return
}

# ==============================================================================
# STEP 3: Discover — connect to Hyper-V hosts and enumerate VMs
# ==============================================================================
Write-Host ""
Write-Host "Connecting to Hyper-V hosts: $($HypervHosts -join ', ')..." -ForegroundColor Cyan

$plan = @()
$coveredHosts = @{}
foreach ($hypervTarget in $HypervHosts) {
    if ($coveredHosts.ContainsKey($hypervTarget)) { continue }
    $targetPlan = @(Invoke-Discovery -ProviderName 'HyperV' -Target $hypervTarget `
        -Credential @{ PSCredential = $HypervCred })
    $plan += $targetPlan
    foreach ($hostItem in @($targetPlan | Where-Object { $_.Attributes['HyperV.DeviceType'] -eq 'Host' })) {
        foreach ($identity in @($hostItem.Attributes['HyperV.HostName'], $hostItem.Attributes['HyperV.HostIP'])) {
            if ($identity) { $coveredHosts[$identity] = $true }
        }
    }
}

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
            MonitorHost = $item.Attributes['HyperV.MonitorHost']
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
    Write-Host "VMs without IP (monitors attach to a host; clustered VMs use a stable anchor):" -ForegroundColor Yellow
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

if (-not $choice -and $NonInteractive) { $choice = '5' }

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

        $credentialName = "HyperV Windows - $($HypervCred.UserName)"
        $windowsCredential = @(Get-WUGCredential -Type windows -SearchValue $credentialName -View basic -ErrorAction Stop) |
            Where-Object { $_.name -eq $credentialName } | Select-Object -First 1
        if (-not $windowsCredential) {
            $windowsCredential = Add-WUGCredential -Name $credentialName -Type windows `
                -WindowsUser $HypervCred.UserName -WindowsPassword $HypervCred.GetNetworkCredential().Password -ErrorAction Stop
        }
        $windowsCredentialId = $windowsCredential.id
        if (-not $windowsCredentialId) { throw 'Hyper-V Windows credential returned no WUG credential ID.' }

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
            $searchResults = @(Get-WUGDevice -SearchValue $addIP -View basic -ErrorAction Stop)
            $deviceMatches = @($searchResults | Where-Object {
                $_.networkAddress -eq $addIP -or $_.hostName -eq $addIP
            })
            if ($deviceMatches.Count -eq 0) {
                $deviceMatches = @(Get-WUGDevice -SearchValue $dev.Name -View basic -ErrorAction Stop |
                    Where-Object { $_.hostName -eq $dev.Name -or $_.name -eq $dev.Name })
            }
            if ($deviceMatches.Count -gt 1) { throw "Multiple WUG devices match '$($dev.Name)'; resolve the duplicate identities before pushing." }
            if ($deviceMatches.Count -eq 1) { $existingDevice = $deviceMatches[0] }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $devicesFound++
                Write-Host "  Found: $($existingDevice.name) (ID: $($existingDevice.id)) [$($dev.Type)]" -ForegroundColor Green
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
                    else { throw "Added '$addIP' but could not find it in WUG." }
                }
                catch { throw "Failed to resolve new device '$addIP': $_" }
            }
        }

        # Clustered no-IP VMs keep the same assignment host when ownership changes.
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -eq 'VM' -and -not $dev.IP -and -not $wugDeviceMap.ContainsKey($key)) {
                $monitorHost = if ($dev.MonitorHost) { $dev.MonitorHost } else { $dev.ParentHost }
                $parentKey = "host:$monitorHost"
                if (-not $wugDeviceMap.ContainsKey($parentKey) -and $dev.MonitorHost) {
                    $anchor = @(Get-WUGDevice -SearchValue $monitorHost -View basic -ErrorAction Stop |
                        Where-Object { $_.hostName -eq $monitorHost -or $_.name -eq $monitorHost })
                    if ($anchor.Count -ne 1) { throw "Cannot uniquely resolve the WUG monitor anchor '$monitorHost' for clustered VM '$($dev.Name)'." }
                    $wugDeviceMap[$parentKey] = $anchor[0].id
                }
                if ($wugDeviceMap.ContainsKey($parentKey)) {
                    $wugDeviceMap[$key] = $wugDeviceMap[$parentKey]
                    Write-Host "  $($dev.Name) (VM, no IP) -> monitor host $monitorHost" -ForegroundColor DarkGray
                }
                else {
                    Write-Warning "No WUG device for VM '$($dev.Name)' — parent host '$($dev.ParentHost)' not found."
                }
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing" -ForegroundColor Cyan

        foreach ($wugId in @($wugDeviceMap.Values | Select-Object -Unique)) {
            $assignedCredentials = @(Get-WUGDeviceCredential -DeviceId $wugId -Type windows -View basic -ErrorAction Stop)
            if (-not @($assignedCredentials | Where-Object { $_.id -eq $windowsCredentialId }).Count) {
                $confirmation = Set-WUGDeviceCredential -DeviceId $wugId -CredentialId $windowsCredentialId -Assign -ErrorAction Stop
                if (-not $confirmation.success -and -not $confirmation.data.success) {
                    throw "Windows credential assignment was not confirmed for device $wugId."
                }
            }
        }

        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
                $dev = $devicePlan[$key]
                if ($dev.Type -eq 'VM' -and -not $dev.IP) {
                    # The VM's monitors run on its host, but its inventory must not overwrite the host's.
                    $item.Attributes = @{}
                }
            }
        }

        Write-Host ""
        Write-Host "Syncing monitors..." -ForegroundColor Cyan

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        Write-Host ""
        Write-Host "Sync results:" -ForegroundColor Cyan
        Write-Host "  Devices in WUG:              $(@($wugDeviceMap.Values | Select-Object -Unique).Count)" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created: $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:          $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):      $($result.Skipped)" -ForegroundColor White
        Write-Host "  Attributes set:               $($result.AttrsUpdated)" -ForegroundColor White
        Write-Host "  Attributes unchanged/failed:  $($result.AttrsUnchanged) / $($result.AttrsFailed)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            throw "Hyper-V synchronization failed for $($result.Failed) operation(s). Review the warnings above."
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
            $dashTempPath = Join-Path $OutputDir 'HyperV-Dashboard.html'

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
                $wugDashPath = Join-Path $wugDashDir 'HyperV-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/HyperV-Dashboard.html" -ForegroundColor Cyan
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
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\dashboards\HyperV-Dashboard.html'" -ForegroundColor Cyan
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
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA4oGeMW3Lkxetr
# VzEdI7qJ/JnU/kMGSfPP3YZRSMbn/KCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAB
# dgCazl+ixyN0IrydNICn8LVLLC6Gtuc/2+2lBPSzKTANBgkqhkiG9w0BAQEFAASC
# AgBtTifdC5wEMmjOUCG99EqiuT9Zk+W7enbCtORfLRR5P66cKDk+iWvzCTUzZQh5
# qs6fk3kDYkMDi2ZXJ+RHg3iBVJ8EH88fFhtzK3frszDOgvlRATY99cxOLOaShYOb
# /lp0GosCIjWhlSqISNqQIjVhReDm8Ohh0OBepbp90H/WHLf8r9/C6UWqm6PgvQm+
# DkkSPcfmVgNqW13ygIssfig+CrVhs33zpfXODNXyIqFwfl0YiSvKEJTTDYYmSI8j
# 7HO8W9Nd/OxpNV0w8HKvpHYDhvt12vhKhz5WdYIaLvWzRg52fBu9a2oUiF9SgjEu
# NxW7Gw6RsITLcpZ8+1y63pEA3jLdHqPh03UrnVcWNr62ZqM3So7GmPvD8f7IbB8O
# yXU117owW0Wa9SFo2hho1/7z+Ne4CoUCVIjDysaeIJZXtwCYSEOz4aqW3HDBOlRj
# Y69ICgSKYz6Y/UQDuzWN8QjWGhRIRO1m82fTDss1dh4nqCyPx+rDvT3+H+l88YdP
# FZMv6luyxapwbEkLq/233RVma46kynKnQ0GuNbRrq1R4NBywOZ/stqho1De7QlaB
# DAkU+UBQt5O5GbTSjJrYcIWQFA0F1WsfTBOlPAQ17dyfJxuYHXWGnyRkPelSTrq2
# ZxnTnXIJhoGK/0kHMJaDz4GUs+Fj3YWsEdm9tQk0KMe3PqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTQwMjQxMDJaMC8GCSqGSIb3DQEJBDEiBCD+cRBVkxFu
# 056zmYLkdE3PhvNbjpHQu54tIuLpzqm0ZTANBgkqhkiG9w0BAQEFAASCAgB7TAM4
# /YGyaCtrcLdzO6+WRKUXDa9PY5Q4/rZDyN/O44TPflJccE2kJcmxBby2KW/JtNPd
# WmbX1DjsQEvvdNffPEhCbIyHxKWeQn+fO7oAfnFfZnP/1wdOdOMEVnY3Jjg0Amfx
# 9a2lTLBRYlEDk+Lig9ItXwZ4dAXfpuqs254xjFajn1E5vUQTEaXxOC/G1LY49sWG
# BygO8mM+sYBvOEZ7GGYngGBkS997o8Mnx0NIZFpnLrpzl/7Lm1o5xZcjG7avnHND
# 3X5ROa9MiHzReLOlTCrXyAJ+9NxILeLf7i/ai8WGw6TWVxffSGqEhHLmrRQHosDv
# 5t0T8sF2N5NkCGFLIiUrIitX1tqL1Rsbqzb/8D017UoVG9a1W88TOZhQaowBI/wp
# idPmBdksxMBx/fso2PLjQifRykyZgJW0HJy7zfEtetAENTPPu3BN4UZbg3evAYj9
# s68iZNlFhnIzyZuw5Dj5tUKpap8BSJrhoCBrOIKQAUAFW4RreTbuMa94BJ1+U+2v
# F61gtYIaloiujI/BVbJgJgsqVXJm7wK03iv52Va+ClY5XSc1XPAcEm1hLUmWgAy7
# jrKy0aJ6jpAiZdno8leo0qc3VgyTG5c7Leude+dAAn9zs6o5OJ5QYRoPjfZrzyzT
# mM+1CW5eQ2b1BsPR96E0scIi1LgUo1XV2ouH/A==
# SIG # End signature block
