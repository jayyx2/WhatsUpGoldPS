<#
.SYNOPSIS
    Docker Discovery -- Discover Docker hosts and containers, then optionally
    push to WhatsUp Gold as monitored devices.

.DESCRIPTION
    Interactive script that discovers Docker hosts and running containers via
    the Docker Engine REST API, then lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + REST API monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Exit

    Architecture (when pushed to WUG):
      [Docker Host device in WUG]
          |-- "Docker Host Health - <host>"               (REST API Active Monitor)
          |-- "Docker Container Health - <container>"     (REST API Active Monitor)
          |-- "memory_usage - <container> (Docker)"       (REST API Perf Monitor)
          |-- "network_rx_bytes - <container> (Docker)"   (REST API Perf Monitor)
          '-- "network_tx_bytes - <container> (Docker)"   (REST API Perf Monitor)

    First Run:
      1. Prompts for Docker host(s) and port
      2. Discovers host info and running containers
      3. Shows summary, then asks what to do

    Subsequent Runs:
      Docker Engine API typically uses anonymous access (port 2375).

.PARAMETER Target
    Docker host(s) -- IP address or FQDN. Accepts multiple values.

.PARAMETER ApiPort
    Docker API port. Default: 2375 (unencrypted).

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER NonInteractive
    Suppress all prompts. Uses parameter defaults.

.NOTES
    Docker Engine API must be exposed on a TCP port (default 2375).
    For TLS-secured Docker (port 2376), certificate auth is required.
    Anonymous monitors do not require a WUG REST API credential.
    Restrict API access to trusted pollers; the full Docker API allows host control.

.EXAMPLE
    .\Setup-Docker-Discovery.ps1
    # Interactive mode.

.EXAMPLE
    .\Setup-Docker-Discovery.ps1 -Target '10.0.0.5','10.0.0.6' -Action PushToWUG -NonInteractive
    # Discover two Docker hosts and push to WUG.

.EXAMPLE
    .\Setup-Docker-Discovery.ps1 -Target '10.0.0.5' -ApiPort 2376 -Action ExportJSON
    # Discover a TLS Docker host and export plan.
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [int]$ApiPort = 2375,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

# --- Output directory ---------------------------------------------------------
if (-not $OutputPath) {
    if ($NonInteractive) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

$DefaultHost = '10.0.0.5'
$DockerPort  = $ApiPort

# --- Load helpers -------------------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Docker.ps1')

# Load dynamic dashboard generator
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Docker Discovery ===" -ForegroundColor Cyan
Write-Host ""

if ($Target) {
    $DockerHosts = @($Target)
}
elseif ($NonInteractive) {
    $DockerHosts = @($DefaultHost)
}
else {
    Write-Host "Enter Docker host(s) -- IP address or FQDN." -ForegroundColor Cyan
    Write-Host "For multiple hosts, separate with commas." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt "Docker host(s) [default: $DefaultHost]"
    if ([string]::IsNullOrWhiteSpace($hostInput)) { $hostInput = $DefaultHost }
    $DockerHosts = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($DockerHosts.Count -eq 0) { Write-Error 'No valid host provided.'; return }
Write-Host "Targets: $($DockerHosts -join ', ')" -ForegroundColor Cyan
Write-Host ""

# --- Port prompt ---
if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt "Docker API port [default: $DockerPort]"
    if ($portInput -and $portInput -match '^\d+$') { $DockerPort = [int]$portInput }
}

# ==============================================================================
# STEP 2: Docker uses anonymous access by default (no auth needed)
# ==============================================================================
$dockerCredential = @{ Anonymous = $true }
Write-Host "Using anonymous access (Docker Engine API)." -ForegroundColor Green
Write-Host ""

# ==============================================================================
# STEP 3: Discover -- query Docker Engine API
# ==============================================================================
Write-Host "Querying Docker at $($DockerHosts -join ', ')..." -ForegroundColor Cyan

$plan = @(Invoke-Discovery -ProviderName 'Docker' `
    -Target $DockerHosts `
    -ApiPort $DockerPort `
    -Credential $dockerCredential)

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check Docker connectivity and API port."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================
$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $hostName = $item.Attributes['Docker.HostName']
    if (-not $hostName) { $hostName = $item.Attributes['Docker.HostIP'] }
    $key = "host:$hostName"

    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name  = $hostName
            IP    = $item.Attributes['Docker.HostIP']
            Type  = 'DockerHost'
            Attrs = $item.Attributes
            Items = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$hostDevices = @($devicePlan.Values)
$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } | Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Docker hosts:              $($hostDevices.Count)" -ForegroundColor White
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

Write-Host "Monitor templates:" -ForegroundColor Cyan
foreach ($t in $activeTemplates) { Write-Host "  [Active] $t" -ForegroundColor White }
foreach ($t in $perfTemplates)   { Write-Host "  [Perf]   $t" -ForegroundColor White }
Write-Host ""

$devicePlan.Values | Sort-Object @{E={$_.Name}} |
    ForEach-Object { [PSCustomObject]@{
        Device   = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { 'N/A' }
        Monitors = $_.Items.Count
    }} |
    Format-Table -AutoSize

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================
$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG'        { $choice = '1' }
        'ExportJSON'       { $choice = '2' }
        'ExportCSV'        { $choice = '3' }
        'ShowTable'        { $choice = '4' }
        'Dashboard'        { $choice = '5' }
        'None'             { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice -and $NonInteractive) { $choice = '5' }

if (-not $choice) {
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push monitors to WhatsUp Gold"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate HTML dashboard"
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
        # --- Push to WUG ---
        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
            if (Test-Path $repoPsd1) { Import-Module $repoPsd1 -Force -ErrorAction Stop }
            else { Import-Module WhatsUpGoldPS -ErrorAction Stop }
        }
        catch { Write-Error "Could not load WhatsUpGoldPS module: $_"; return }
        # Dot-source internal helper so scripts can call Get-WUGAPIResponse directly
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if ($WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
        }
        else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors
        }

        $stats = @{
            HealthCreated = 0; HealthSkipped = 0; HealthFailed = 0
            PerfCreated = 0; PerfSkipped = 0; PerfFailed = 0
            DevicesCreated = 0; DevicesFound = 0
        }
        $wugDeviceMap = @{}
        $deviceKeys = @($devicePlan.Keys | Sort-Object)
        $devTotal = $deviceKeys.Count

        Write-Verbose 'Docker monitors use anonymous access; no WUG REST API credential is required.'

        # ---- 2a. Create active monitors ---
        Write-Host ""
        Write-Host "  Creating active monitors in library..." -ForegroundColor Cyan

        $uniqueActiveMonitors = @{}
        foreach ($key in $deviceKeys) {
            foreach ($actItem in @($devicePlan[$key].Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                if ($actItem.Name -and -not $uniqueActiveMonitors.ContainsKey($actItem.Name)) {
                    $uniqueActiveMonitors[$actItem.Name] = $actItem
                }
            }
        }

        # One library read: per-name search returns device assignments, which never match by name.
        $existingActiveNames = @{}
        try {
            $activeLibrary = Get-WUGMonitorLibraryMap -Type active
            foreach ($actName in @($uniqueActiveMonitors.Keys)) {
                if ($activeLibrary.ContainsKey($actName)) { $existingActiveNames[$actName] = [int]$activeLibrary[$actName] }
            }
        }
        catch {
            Write-Warning "    Could not read the active monitor library: $($_.Exception.Message). Monitors may be created again."
        }

        $toCreateActive = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        $stats.HealthSkipped = $uniqueActiveMonitors.Count - $toCreateActive.Count

        if ($toCreateActive.Count -gt 0) {
            Write-Host "    Creating $($toCreateActive.Count) new active monitors..." -ForegroundColor DarkGray

            $activeTemplateArr = @()
            $actTplIdMap = @{}
            $actTplIdx = 0
            foreach ($actName in $toCreateActive) {
                $actItem = $uniqueActiveMonitors[$actName]
                $mp = $actItem.MonitorParams
                $tplId = "act_$actTplIdx"; $actTplIdMap[$tplId] = $actName; $actTplIdx++

                $bags = @(
                    @{ name = 'MonRestApi:RestUrl';                value = "$($mp.RestApiUrl)" }
                    @{ name = 'MonRestApi:HttpMethod';             value = if ($mp.RestApiMethod) { "$($mp.RestApiMethod)" } else { 'GET' } }
                    @{ name = 'MonRestApi:HttpTimeoutMs';          value = if ($mp.RestApiTimeoutMs) { "$($mp.RestApiTimeoutMs)" } else { '10000' } }
                    @{ name = 'MonRestApi:IgnoreCertErrors';       value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '0' } }
                    @{ name = 'MonRestApi:UseAnonymousAccess';     value = if ($mp.RestApiUseAnonymous) { "$($mp.RestApiUseAnonymous)" } else { '1' } }
                    @{ name = 'MonRestApi:CustomHeader';           value = '' }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn'; value = if ($mp.RestApiDownIfResponseCodeIsIn) { "$($mp.RestApiDownIfResponseCodeIsIn)" } else { '[]' } }
                    @{ name = 'MonRestApi:ComparisonList';         value = if ($mp.RestApiComparisonList) { "$($mp.RestApiComparisonList)" } else { '[]' } }
                    @{ name = 'Cred:Type';                        value = '8192' }
                )

                $activeTemplateArr += @{
                    templateId      = $tplId
                    name            = $actName
                    description     = 'Docker RestApi active monitor'
                    useInDiscovery  = $false
                    monitorTypeInfo = @{ baseType = 'active'; classId = 'f0610672-d515-4268-bd21-ac5ebb1476ff' }
                    propertyBags    = $bags
                }
            }

            try {
                $bulkActResult = Add-WUGMonitorTemplate -ActiveMonitors $activeTemplateArr
                if ($bulkActResult.idMap) {
                    foreach ($mapping in $bulkActResult.idMap) {
                        if ($actTplIdMap.ContainsKey($mapping.templateId) -and $mapping.resultId) {
                            $existingActiveNames[$actTplIdMap[$mapping.templateId]] = [int]$mapping.resultId
                            $stats.HealthCreated++
                        }
                    }
                }
                if ($bulkActResult.errors) {
                    foreach ($err in $bulkActResult.errors) {
                        Write-Warning "Active monitor error: $($err.messages -join '; ')"
                        $stats.HealthFailed++
                    }
                }
            }
            catch { Write-Warning "Bulk active monitor creation failed: $_"; $stats.HealthFailed += $toCreateActive.Count }
        }
        Write-Host "    Active monitors: $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor DarkGray

        # ---- 2b. Create perf monitors ---
        Write-Host "  Creating performance monitors in library..." -ForegroundColor Cyan

        $uniquePerfMonitors = @{}
        foreach ($key in $deviceKeys) {
            foreach ($perfItem in @($devicePlan[$key].Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                if ($perfItem.Name -and -not $uniquePerfMonitors.ContainsKey($perfItem.Name)) {
                    $uniquePerfMonitors[$perfItem.Name] = $perfItem
                }
            }
        }

        $existingPerfNames = @{}
        try {
            $perfLibrary = Get-WUGMonitorLibraryMap -Type performance
            foreach ($monName in @($uniquePerfMonitors.Keys)) {
                if ($perfLibrary.ContainsKey($monName)) { $existingPerfNames[$monName] = "$($perfLibrary[$monName])" }
            }
        }
        catch {
            Write-Warning "    Could not read the performance monitor library: $($_.Exception.Message). Monitors may be created again."
        }

        $toCreatePerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        $stats.PerfSkipped = $uniquePerfMonitors.Count - $toCreatePerf.Count

        if ($toCreatePerf.Count -gt 0) {
            Write-Host "    Creating $($toCreatePerf.Count) new perf monitors..." -ForegroundColor DarkGray

            $perfTemplateArr = @()
            $perfTplIdMap = @{}
            $perfTplIdx = 0
            foreach ($monName in $toCreatePerf) {
                $perfItem = $uniquePerfMonitors[$monName]
                $mp = $perfItem.MonitorParams
                $tplId = "perf_$perfTplIdx"; $perfTplIdMap[$tplId] = $monName; $perfTplIdx++

                $bags = @(
                    @{ name = 'RdcRestApi:RestUrl';            value = "$($mp.RestApiUrl)" }
                    @{ name = 'RdcRestApi:JsonPath';           value = "$($mp.RestApiJsonPath)" }
                    @{ name = 'RdcRestApi:HttpMethod';         value = if ($mp.RestApiHttpMethod) { "$($mp.RestApiHttpMethod)" } else { 'GET' } }
                    @{ name = 'RdcRestApi:HttpTimeoutMs';      value = if ($mp.RestApiHttpTimeoutMs) { "$($mp.RestApiHttpTimeoutMs)" } else { '10000' } }
                    @{ name = 'RdcRestApi:IgnoreCertErrors';   value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '0' } }
                    @{ name = 'RdcRestApi:UseAnonymousAccess'; value = if ($mp.RestApiUseAnonymousAccess) { "$($mp.RestApiUseAnonymousAccess)" } else { '1' } }
                    @{ name = 'RdcRestApi:CustomHeader';       value = '' }
                )

                $perfTemplateArr += @{
                    templateId      = $tplId
                    name            = $monName
                    description     = 'Docker RestApi performance monitor'
                    monitorTypeInfo = @{ baseType = 'performance'; classId = '987bb6a4-70f4-4f46-97c6-1c9dd1766437' }
                    propertyBags    = $bags
                }
            }

            try {
                $bulkPerfResult = Add-WUGMonitorTemplate -PerformanceMonitors $perfTemplateArr
                if ($bulkPerfResult.idMap) {
                    foreach ($mapping in $bulkPerfResult.idMap) {
                        if ($perfTplIdMap.ContainsKey($mapping.templateId) -and $mapping.resultId) {
                            $existingPerfNames[$perfTplIdMap[$mapping.templateId]] = "$($mapping.resultId)"
                            $stats.PerfCreated++
                        }
                    }
                }
                if ($bulkPerfResult.errors) {
                    foreach ($err in $bulkPerfResult.errors) {
                        Write-Warning "Perf monitor error: $($err.messages -join '; ')"
                        $stats.PerfFailed++
                    }
                }
            }
            catch { Write-Warning "Bulk perf monitor creation failed: $_"; $stats.PerfFailed += $toCreatePerf.Count }
        }
        Write-Host "    Perf monitors: $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor DarkGray

        # ---- 2c. Check existing vs new devices ---
        Write-Host "  Checking for existing devices..." -ForegroundColor Cyan
        $existingDevices = @{}
        $newDeviceKeys = [System.Collections.Generic.List[string]]::new()

        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            $displayName = "$($dev.Name) (Docker)"
            $deviceId = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $match = $searchResults | Where-Object { $_.displayName -eq $dev.Name -or $_.displayName -eq $displayName -or $_.hostName -eq $dev.Name } | Select-Object -First 1
                    if ($match) { $deviceId = $match.id }
                }
                if (-not $deviceId -and $dev.IP) {
                    $searchResults = @(Get-WUGDevice -SearchValue $dev.IP)
                    $match = $searchResults | Where-Object { $_.networkAddress -eq $dev.IP } | Select-Object -First 1
                    if ($match) { $deviceId = $match.id }
                }
            }
            catch {
                Write-Warning "    Device lookup failed for '$($dev.Name)': $($_.Exception.Message). A duplicate may be created."
            }

            if ($deviceId) { $existingDevices[$key] = $deviceId; $wugDeviceMap[$key] = $deviceId; $stats.DevicesFound++ }
            else { $newDeviceKeys.Add($key) }
        }
        Write-Host "    Found $($stats.DevicesFound) existing, $($newDeviceKeys.Count) new" -ForegroundColor DarkGray

        # ---- 2d. Create new devices ---
        if ($newDeviceKeys.Count -gt 0) {
            Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow
            foreach ($key in $newDeviceKeys) {
                $dev = $devicePlan[$key]
                $addIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
                $displayName = "$($dev.Name) (Docker)"

                $devAttrs = @()
                foreach ($attrName in $dev.Attrs.Keys) {
                    if ($dev.Attrs[$attrName]) { $devAttrs += @{ name = $attrName; value = "$($dev.Attrs[$attrName])" } }
                }

                $actNames = @()
                $seenAct = @{}
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name) -and -not $seenAct.ContainsKey($actItem.Name)) {
                        $actNames += $actItem.Name; $seenAct[$actItem.Name] = $true
                    }
                }

                $perfNames = @()
                $seenPerf = @{}
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name) -and -not $seenPerf.ContainsKey($perfItem.Name)) {
                        $perfNames += $perfItem.Name; $seenPerf[$perfItem.Name] = $true
                    }
                }

                if ($actNames.Count -eq 0 -and $perfNames.Count -eq 0) { continue }

                $splat = @{
                    displayName            = $displayName
                    DeviceAddress          = $addIP
                    Hostname               = $dev.Name
                    Brand                  = 'Docker'
                    Note                   = "Docker host (auto-created by discovery)"
                    NoDefaultActiveMonitor = $true
                }
                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($actNames.Count -gt 0) { $splat['ActiveMonitors'] = $actNames }
                if ($perfNames.Count -gt 0) { $splat['PerformanceMonitors'] = $perfNames }

                try {
                    $devResult = Add-WUGDeviceTemplate @splat

                    $isErrorResult = $false
                    if ($devResult -is [array]) { $isErrorResult = $true }
                    elseif ($devResult -and $devResult.PSObject.Properties['messages']) { $isErrorResult = $true }

                    if ($devResult -and -not $isErrorResult) {
                        $newDeviceId = $null
                        if ($devResult.idMap) { $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId }
                        elseif ($devResult.PSObject.Properties['resultId']) { $newDeviceId = $devResult.resultId }
                        if ($newDeviceId) {
                            $wugDeviceMap[$key] = $newDeviceId
                            $stats.DevicesCreated++
                            Write-Verbose "Created device '$displayName' (ID: $newDeviceId)"
                        } else {
                            Write-Warning "Device '$displayName' - API returned success but no device ID."
                        }
                    } else {
                        $errMsgs = @()
                        if ($devResult -is [array]) { foreach ($e in $devResult) { if ($e.PSObject.Properties['messages']) { $errMsgs += ($e.messages -join '; ') } } }
                        elseif ($devResult -and $devResult.PSObject.Properties['messages']) { $errMsgs += ($devResult.messages -join '; ') }
                        $errText = if ($errMsgs.Count -gt 0) { $errMsgs -join ' | ' } else { 'Unknown error (no details returned)' }
                        Write-Warning "Failed to create device '$displayName': $errText"
                    }
                }
                catch { Write-Warning "Error creating device '$displayName': $_" }
            }
            Write-Host "    Devices created: $($stats.DevicesCreated)" -ForegroundColor Green
        }

        # ---- 2e. Update existing devices ---
        if ($existingDevices.Count -gt 0) {
            Write-Host "  Updating $($existingDevices.Count) existing devices..." -ForegroundColor Cyan
            foreach ($key in $existingDevices.Keys) {
                $deviceId = [int]$existingDevices[$key]
                $dev = $devicePlan[$key]

                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) { $actMonitorIds += $existingActiveNames[$actItem.Name] }
                }
                if ($actMonitorIds.Count -gt 0) {
                    $sync = Sync-WUGDiscoveryMonitorAssignments -DeviceId $deviceId -Type active -MonitorId $actMonitorIds
                    Write-Host "    $($dev.Name) active: $($sync.Assigned) assigned, $($sync.Skipped) existing, $($sync.Failed) failed" -ForegroundColor Gray
                }

                $perfMonitorIds = @()
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name)) { $perfMonitorIds += [int]$existingPerfNames[$perfItem.Name] }
                }
                if ($perfMonitorIds.Count -gt 0) {
                    $sync = Sync-WUGDiscoveryMonitorAssignments -DeviceId $deviceId -Type performance -MonitorId $perfMonitorIds -PerfPollingIntervalMinutes 5
                    Write-Host "    $($dev.Name) performance: $($sync.Assigned) assigned, $($sync.Skipped) existing, $($sync.Failed) failed" -ForegroundColor Gray
                }
            }
        }

        foreach ($key in $wugDeviceMap.Keys) {
            $sync = Sync-WUGDiscoveryDeviceAttributes -DeviceId ([int]$wugDeviceMap[$key]) -Attributes $devicePlan[$key].Attrs
            Write-Host "  $($devicePlan[$key].Name) attributes: $($sync.Updated) written, $($sync.Unchanged) unchanged, $($sync.Failed) failed" -ForegroundColor Gray
        }

        # ---- Summary ---
        Write-Host ""
        Write-Host "Push complete!" -ForegroundColor Green
        Write-Host "  Active monitors:  $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor White
        Write-Host "  Perf monitors:    $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor White
        Write-Host "  Devices:          $($stats.DevicesCreated) created, $($stats.DevicesFound) existing" -ForegroundColor White
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'docker-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'docker-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate Docker HTML Dashboard from discovery data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building Docker dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $activeItems = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })
            $perfItems   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })

            foreach ($item in ($activeItems + $perfItems)) {
                $dashboardRows += [PSCustomObject]@{
                    Device        = $dev.Name
                    IP            = if ($dev.IP) { $dev.IP } else { '(docker)' }
                    Monitor       = $item.Name -replace '\s*\[.*\]$', ''
                    Type          = $item.ItemType
                    Status        = 'Discovered'
                    LastDiscovery = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                }
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashPath = Join-Path $OutputDir 'Docker-Dashboard.html'

            if (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
                Export-DynamicDashboardHtml -Data $dashboardRows `
                    -OutputPath $dashPath `
                    -ReportTitle 'Docker Discovery Dashboard' `
                    -CardField 'Device','Type' `
                    -StatusField 'Status'
            }
            else {
                Write-Warning "No dashboard function available. Exporting as JSON instead."
                $jsonPath = Join-Path $OutputDir "Docker-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).json"
                $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath
                Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
                break
            }

            Write-Host ""
            Write-Host "Dashboard generated: $dashPath" -ForegroundColor Green
            Write-Host "  Devices: $($devicePlan.Count)  |  Monitors: $($dashboardRows.Count)" -ForegroundColor White

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugDashPath = Join-Path $wugDashDir 'Docker-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/Docker-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                }
                Deploy-DashboardWebConfig -Path $wugDashDir
            }
        }
    }
    '6' {
        Write-Host "No action taken." -ForegroundColor Gray
    }
    default {
        Write-Host "Invalid choice." -ForegroundColor Red
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "Re-run anytime to discover new Docker containers." -ForegroundColor Cyan

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA4epy81Kr1foQn
# Mn13YTcUsr0o5RX9dkVjqa2HPpZrdKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCb
# ATN2n69fQUYPdf1HSoLKcgLNpXYy7GMzbiMOi7ZEUzANBgkqhkiG9w0BAQEFAASC
# AgC/xUcNzRar/AqU8aSxF7gZJL2xVU4ywfaKUR9tLGuCBp2IHLqzfF7GqB0Tsgec
# Qou+5Mew5Ucc12JCuyKgSxLX+PO6ac7CaOdBW6n99Xak9UCjvGv3A84IOutLN2Xc
# BdnFwGmprk4t+DQpbSmI1JNi3Yok2MUwuiY0dXbHC7za4+5WirHHHW+smu8IPZuW
# TAf50PpGIJM+xpmGKywW4Wvd5xSF7xDVC5HeMOBupHldVXtClelrgmOeSipvblCx
# Wdgs9G76ZzCjIH+hGHrbtvagZd4Fu6EbMlh5GOPeFatTIXjyFDNn87mrkoshPD/q
# axm/7EqfepiYD5GB1t2GWSgFWE0RnEPeVxVFpWsVP/XpNbdn8BMSw0mZsLI2lQGS
# 5DQArT5FNuLudDsx3vLmQomg7G6hCWJvuOMp+VMQrHLIIuraGcmUlT9BjG/8ZKv5
# s4IuKdDMXE1Fgxvb/CMn/LV2zVRNn2DRrdfZUI/zvvQ3YtMRB3YijDXUIYltxMe5
# 2ykeJzgD14+ctpSFG/lkWyMlI6lz1sLJAwRRJiLdVm0zdTHYy6qmYBpmb4W5kO+q
# 4D94bFcDQKQjdEbvgPh45HrclWuBUzD5iZ+wkRP6eAFKB4V4JKUjPB3ooLZtTqik
# lZ6GdGVDNkBH9p0lZIbHhhLIW45/sHV8dXHdSkbEbf2JPaGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTQwMDQxMzlaMC8GCSqGSIb3DQEJBDEiBCA95rySTcs3
# 7qXIkH9srTNQ/dSrh2A5W/Wiukclgl+r4DANBgkqhkiG9w0BAQEFAASCAgCqCjSc
# PTkoHJs4gjYiAa+WoGmqxvwuyqm+4JXQhnQRL5mMU0GX0Dsry7PsOzcM8ACRiw58
# 0KOShpzMq/iLp7f6VLuNplzJfwhJ9O/jIgPwxxBO3obZ5z0UhCWrZKXtU26J2VSc
# AUNwiiGur+ig5oAazXUCqsVzy+fV0fAjGzn8YuCX8xZ2JEFk0OWbY6dj4KKHWr2I
# joJh61q/5rVys6OtyGmjtbQN4PrBSmV43C1FRCVrsx/nI34KBfCXgLH4KnirAnMZ
# EvKDM4d2yYaQURZegJAfN9rKn1ah5tROeBAqloVoVBaPiwWrc0OcXTNNEQIdyZjI
# N2AkDdRQWUpNM+Y0+acaesQYJUs3zJETLJH6B+28eVGuOQdjcMygIGbhKzYAYASG
# 1Rr5QyczqSjFd3eBGW7sNKPjJjc/SCH7P6MPXJFwgF6u63QKXdw/u2iJROwsxgyx
# OfqR+Ql5TysnTmIB/f19T9FcrXB1GVLKmhhaFzn3AJ6uqZcnvz2ejuywQSkLuqLR
# eIN63l2GiHrpx4yFkL6NJwgKYAVGuqVM6rTytRSlh5QYVDY06fBDOA0DBjoDNzDD
# JVB2F7Nz5dWV+wirkGdVFcVI24kv/PuzinvfJlxby4paqxHKUUa45gFt1acS2+D8
# WWm0Gv/PzUMFYt7lsbCllI0rVVYQbYzyT3/Bzg==
# SIG # End signature block
