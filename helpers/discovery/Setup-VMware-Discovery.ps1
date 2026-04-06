<#
.SYNOPSIS
    VMware vSphere Discovery -- Discover ESXi hosts/VMs and optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers VMware vSphere infrastructure, then
    lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Generate VMware HTML dashboard (live metrics)
      [6] Exit

    Two collection methods:
      [1] VMware PowerCLI -- uses Connect-VIServer, Get-VMHost, Get-VM, etc.
      [2] REST API (direct) -- zero external dependencies, uses vCenter REST API

    First Run:
      1. Prompts for collection method, vCenter server, port, credentials
      2. Stores credentials in DPAPI vault (encrypted to user + machine)
      3. Discovers ESXi hosts + VMs from vCenter
      4. Shows summary, then asks what to do with the results

    Subsequent Runs:
      Loads credentials from vault automatically -- skips credential prompt.

.PARAMETER Target
    vCenter server or ESXi host — IP address or FQDN.
    When omitted in interactive mode, prompts for input.

.PARAMETER ApiPort
    vCenter port. Default: 443.

.PARAMETER UseRestApi
    Use vCenter REST API (no PowerCLI needed, vSphere 6.5+ required). Default: true.
    Pass -UseRestApi:$false for VMware PowerCLI mode.

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
    .\Setup-VMware-Discovery.ps1
    # Interactive mode — prompts for everything.

.EXAMPLE
    .\Setup-VMware-Discovery.ps1 -Target 'vcenter01.lab.local' -Action ExportJSON -NonInteractive
    # Scheduled mode — uses vault credentials, exports JSON, no prompts.

.NOTES
    WhatsUpGoldPS module is only needed if you choose option [1].
    REST API mode has zero external module dependencies (vSphere 6.5+ required).
    Module mode requires: VMware.PowerCLI.
#>
[CmdletBinding()]
param(
    [string]$Target,

    [int]$ApiPort = 443,

    [switch]$UseRestApi,

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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Configuration -----------------------------------------------------------
$DefaultServer = 'vcenter01.lab.local'   # Default vCenter server (interactive fallback)
$DefaultPort   = $ApiPort

# Default to REST API if not explicitly set
if (-not $PSBoundParameters.ContainsKey('UseRestApi')) {
    $UseRestApi = $true
}

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-VMware.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== VMware vSphere Discovery ===" -ForegroundColor Cyan
Write-Host ""

# --- Collection method ---------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('UseRestApi') -and -not $NonInteractive) {
    Write-Host "VMware data collection method:" -ForegroundColor Cyan
    Write-Host "  [1] VMware PowerCLI modules (requires VMware.PowerCLI)" -ForegroundColor White
    Write-Host "  [2] REST API direct (zero external dependencies, vSphere 6.5+)" -ForegroundColor White
    Write-Host ""
    $methodChoice = Read-Host -Prompt "Choice [1/2, default: 2]"
    $UseRestApi = ($methodChoice -ne '1')
}

if ($UseRestApi) {
    Write-Host "Using REST API mode (no PowerCLI needed)." -ForegroundColor Green
}
else {
    Write-Host "Using VMware PowerCLI module mode." -ForegroundColor Green

    # --- Check for PowerCLI -------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI -ErrorAction SilentlyContinue)) {
        Write-Warning "VMware.PowerCLI module not found. Install it with:"
        Write-Host "  Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force" -ForegroundColor Yellow
        if ($NonInteractive) {
            Write-Error "VMware.PowerCLI module not found and cannot install in non-interactive mode."
            return
        }
        Write-Host ""
        $installChoice = Read-Host -Prompt "Attempt to install now? [y/N]"
        if ($installChoice -eq 'y' -or $installChoice -eq 'Y') {
            try {
                Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -ErrorAction Stop
                Write-Host "VMware.PowerCLI installed successfully." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to install VMware.PowerCLI: $_"
                return
            }
        }
        else {
            Write-Host "Cannot proceed without PowerCLI. Exiting." -ForegroundColor Red
            return
        }
    }
}

# --- Resolve vCenter server -----------------------------------------------------
if ($Target) {
    $VMwareServer = $Target
}
elseif ($NonInteractive) {
    $VMwareServer = $DefaultServer
}
else {
    Write-Host "Enter vCenter Server or ESXi host -- IP address or FQDN." -ForegroundColor Cyan
    $serverInput = Read-Host -Prompt "vCenter server [default: $DefaultServer]"
    if ([string]::IsNullOrWhiteSpace($serverInput)) {
        $serverInput = $DefaultServer
    }
    $VMwareServer = $serverInput.Trim()
}
Write-Host "Target: $VMwareServer" -ForegroundColor Cyan
Write-Host ""

# --- Resolve port --------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt "vCenter port [default: $DefaultPort]"
    if ($portInput -and $portInput -match '^\d+$') {
        $DefaultPort = [int]$portInput
    }
}

# ==============================================================================
# STEP 2: Credentials (DPAPI vault -- encrypted, cached)
# ==============================================================================
$vaultName = "VMware.$VMwareServer.Credential"
$credSplat = @{ Name = $vaultName; CredType = 'PSCredential'; ProviderLabel = 'VMware' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
$VMwareCred = Resolve-DiscoveryCredential @credSplat
if (-not $VMwareCred) {
    Write-Error 'No credentials provided. Exiting.'
    return
}

# ==============================================================================
# STEP 3: Discover -- query vCenter for hosts + VMs
# ==============================================================================
Write-Host ""
Write-Host "Connecting to vCenter at $VMwareServer..." -ForegroundColor Cyan

$plan = Invoke-Discovery -ProviderName 'VMware' `
    -Target @($VMwareServer) `
    -ApiPort $DefaultPort `
    -Credential @{ Username = $VMwareCred.UserName; Password = $VMwareCred.GetNetworkCredential().Password; PSCredential = $VMwareCred; UseRestApi = $UseRestApi }

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check vCenter connectivity and credentials."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

# Group items by target device
$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    if (-not $item -or -not $item.Attributes) { continue }
    $type = $item.Attributes['VMware.DeviceType']
    switch ($type) {
        'vCenter' {
            $key  = "vcenter:$($item.Attributes['VMware.vCenter'])"
            $name = $item.Attributes['VMware.vCenter']
            $ip   = $item.Attributes['VMware.vCenter']
            $parentHost = $null
        }
        'ESXiHost' {
            $hostName = $item.Attributes['VMware.HostName']
            $key  = "host:${hostName}"
            $name = $hostName
            $ip   = $item.Attributes['VMware.HostIP']
            $parentHost = $null
        }
        'VM' {
            $vmName = $item.Attributes['VMware.VMName']
            $key  = "vm:${vmName}"
            $name = $vmName
            $ip   = $item.Attributes['VMware.VMIP']
            $parentHost = $item.Attributes['VMware.ESXiHost']
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

$hostDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'ESXiHost' })
$vmDevices   = @($devicePlan.Values | Where-Object { $_.Type -eq 'VM' })
$vmWithIP    = @($vmDevices | Where-Object { $_.IP })
$vmNoIP      = @($vmDevices | Where-Object { -not $_.IP })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } |
    Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
    Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  ESXi Hosts:            $($hostDevices.Count)" -ForegroundColor White
Write-Host "  VMs (with IP):         $($vmWithIP.Count)" -ForegroundColor White
Write-Host "  VMs (no IP/no agent):  $($vmNoIP.Count)" -ForegroundColor White
Write-Host "  Total WUG devices:     $($hostDevices.Count + $vmWithIP.Count + 1) (hosts + VMs w/ IP + vCenter)" -ForegroundColor White
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
    Write-Host "VMs without IP (VMware Tools needed -- monitors attach to parent host):" -ForegroundColor Yellow
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
    Write-Host "  [1] Push monitors to WhatsUp Gold (creates devices + credential + monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate VMware HTML dashboard (from discovery data)"
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
        # --- Multi-device push to WUG -----------------------------------------
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

        # Create/find devices in WUG
        Write-Host ""
        Write-Host "Creating devices in WUG..." -ForegroundColor Cyan

        $wugDeviceMap = @{}
        $devicesCreated = 0
        $devicesFound   = 0

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $addIP = $null
            if ($dev.Type -eq 'vCenter') { $addIP = $dev.IP }
            elseif ($dev.Type -eq 'ESXiHost') { $addIP = $dev.IP }
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

        # Map no-IP VMs to parent host devices
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -eq 'VM' -and -not $dev.IP -and -not $wugDeviceMap.ContainsKey($key)) {
                $parentKey = "host:$($dev.ParentHost)"
                if ($wugDeviceMap.ContainsKey($parentKey)) {
                    $wugDeviceMap[$key] = $wugDeviceMap[$parentKey]
                    Write-Host "  $($dev.Name) (VM, no IP) -> host $($dev.ParentHost)" -ForegroundColor DarkGray
                }
                else {
                    Write-Warning "No WUG device for VM '$($dev.Name)' -- parent host '$($dev.ParentHost)' not found."
                }
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing" -ForegroundColor Cyan

        # Set device attributes
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

        # Update plan items with WUG device IDs and sync
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
        $jsonPath = Join-Path $OutputDir 'vmware-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'vmware-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate VMware HTML Dashboard from already-collected plan data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building VMware dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $attrs = $dev.Attrs

            switch ($dev.Type) {
                'ESXiHost' {
                    $dashboardRows += [PSCustomObject]@{
                        Type              = 'Host'
                        Name              = $dev.Name
                        PowerState        = if ($attrs['VMware.PowerState']) { $attrs['VMware.PowerState'] } elseif ($attrs['VMware.Version']) { 'PoweredOn' } else { 'N/A' }
                        IPAddress         = if ($dev.IP) { $dev.IP } else { 'N/A' }
                        Cluster           = if ($attrs['VMware.Cluster']) { $attrs['VMware.Cluster'] } else { 'N/A' }
                        ESXiHost          = $dev.Name
                        GuestOS           = if ($attrs['VMware.Version']) { "VMware ESXi $($attrs['VMware.Version'])" } else { 'ESXi' }
                        ToolsStatus       = 'N/A'
                        CPU               = if ($attrs['VMware.CpuCores'] -and $attrs['VMware.CpuCores'] -ne 'N/A') { "$($attrs['VMware.CpuSockets'])s/$($attrs['VMware.CpuCores'])c" } else { 'N/A' }
                        Memory            = if ($attrs['VMware.MemTotalGB'] -and $attrs['VMware.MemTotalGB'] -ne 'N/A') { "$($attrs['VMware.MemTotalGB']) GB" } else { 'N/A' }
                        CpuUsagePct       = 'N/A'
                        MemUsagePct       = 'N/A'
                        NetUsageKBps      = 'N/A'
                        DiskUsageKBps     = 'N/A'
                        Hardware          = if ($attrs['VMware.Manufacturer']) { "$($attrs['VMware.Manufacturer']) $($attrs['VMware.Model'])".Trim() } else { 'N/A' }
                        VersionBuild      = if ($attrs['VMware.Version']) { "ESXi $($attrs['VMware.Version']) Build $($attrs['VMware.Build'])" } else { 'N/A' }
                        Datastores        = 'N/A'
                        ProvisionedSpaceGB = 'N/A'
                        UsedSpaceGB       = 'N/A'
                        NicCount          = 'N/A'
                        DiskCount         = 'N/A'
                        DiskLatencyMs     = 'N/A'
                    }
                }
                'VM' {
                    $dashboardRows += [PSCustomObject]@{
                        Type              = 'VM'
                        Name              = $dev.Name
                        PowerState        = if ($attrs['VMware.PowerState']) { $attrs['VMware.PowerState'] } else { 'N/A' }
                        IPAddress         = if ($dev.IP) { $dev.IP } else { 'N/A' }
                        Cluster           = if ($attrs['VMware.Cluster']) { $attrs['VMware.Cluster'] } else { 'N/A' }
                        ESXiHost          = if ($attrs['VMware.ESXiHost']) { $attrs['VMware.ESXiHost'] } else { 'N/A' }
                        GuestOS           = if ($attrs['VMware.GuestOS']) { $attrs['VMware.GuestOS'] } else { 'N/A' }
                        ToolsStatus       = if ($attrs['VMware.ToolsStatus']) { $attrs['VMware.ToolsStatus'] } else { 'N/A' }
                        CPU               = if ($attrs['VMware.NumCPU']) { "$($attrs['VMware.NumCPU']) vCPU" } else { 'N/A' }
                        Memory            = if ($attrs['VMware.MemoryGB']) { "$($attrs['VMware.MemoryGB']) GB" } else { 'N/A' }
                        CpuUsagePct       = 'N/A'
                        MemUsagePct       = 'N/A'
                        NetUsageKBps      = 'N/A'
                        DiskUsageKBps     = 'N/A'
                        Hardware          = 'N/A'
                        VersionBuild      = 'N/A'
                        Datastores        = 'N/A'
                        ProvisionedSpaceGB = 'N/A'
                        UsedSpaceGB       = 'N/A'
                        NicCount          = if ($attrs['VMware.NicCount']) { $attrs['VMware.NicCount'] } else { 'N/A' }
                        DiskCount         = if ($attrs['VMware.DiskCount']) { $attrs['VMware.DiskCount'] } else { 'N/A' }
                        DiskLatencyMs     = 'N/A'
                    }
                }
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashReportTitle = "VMware vSphere Dashboard"
            $dashTempPath = Join-Path $OutputDir 'VMware-Dashboard.html'

            $null = Export-VMwareDiscoveryDashboardHtml `
                -DashboardData $dashboardRows `
                -OutputPath $dashTempPath `
                -ReportTitle $dashReportTitle

            Write-Host ""
            Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
            $dHosts   = @($dashboardRows | Where-Object { $_.Type -eq 'Host' }).Count
            $dVMs     = @($dashboardRows | Where-Object { $_.Type -eq 'VM' }).Count
            $dOn      = @($dashboardRows | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
            $dOff     = @($dashboardRows | Where-Object { $_.PowerState -eq 'PoweredOff' }).Count
            Write-Host "  Hosts: $dHosts  |  VMs: $dVMs  |  Powered On: $dOn  |  Powered Off: $dOff" -ForegroundColor White

            # Copy to NmConsole
            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashPath = Join-Path $nmConsolePath 'VMware-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/VMware-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                    Write-Host "  Manual copy: Copy-Item '$dashTempPath' '$wugDashPath'" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host ""
                Write-Host "WUG NmConsole directory not found locally." -ForegroundColor Yellow
                Write-Host "Copy the file to your WUG server:" -ForegroundColor Yellow
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\VMware-Dashboard.html'" -ForegroundColor Cyan
            }
        }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "Re-run anytime to discover new VMware hosts/VMs." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDzGg9iiGoOva1w
# M/EC+cVOX1Ui3bv31ZmgS/ssv8xdcaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgDDSzD2bYsdL8CdADYgRXIm6E3rbA9v++
# FU4ZqOBXp7kwDQYJKoZIhvcNAQEBBQAEggIAU64cwI0wd1xrIExKxdw2PlcQQ+Hj
# 1DwuvXYQh6xvK2bIrHEEEmtrvE6fcUNuerUu9dv6aBx4o+2LSFQcL8UAYY/0ECwo
# 9izYuKBQDfBg4MlOo8MLo7P3RTrl9hLC9+t2XHFuOFD1UGHM+/NL8Hf8BB3lSNm/
# K0/+DCfVwnuuaMrtXMs4jtTb2FmGvUiczeDLAPOwdsbkiw8ZcO69ihaHxhZUKZvo
# F45PWUGNepDTI7iZ7q/VTvVGcVbKO68tEuHv+2MFZF/CS7WkPp3h/ZZeFB+bY+tQ
# dWM95H0PO31GwBoTuBpc155u6rrN6yAMV6ZBR+6BWFf67ZfoMxFyueYu4U8a9uoT
# bdrhd2sHsJG8ebaNdRipVBUEMkTEUP98W4Zcdejz/t5s+zh90C8jmbDzPNuAaEpB
# pAdBzIz/Xjvq4BbQQbCyPJ6XZDtfKPLCFsOScYtU62HCqrYvfobUEjqrZzvVDbT8
# 99TUgEixBLRM6j4P+gDMQOTwELo4cgeH1K5tGpVIcRSGMBjHVbL75Niy+7qt1xqm
# N2N9S/oTfRjUjSZe/z6hkI7EoxCqxWIik80yx2JzbAN0RBXcT7z3S846f8Y09v6P
# 4/tI4ZBNVOiIc+Ldscdtd9v1kjEM3xnXZDZNC6fUMgxboveFvbxBbk4J2BlAoyHE
# c0Z7CptEskvsa+0=
# SIG # End signature block
