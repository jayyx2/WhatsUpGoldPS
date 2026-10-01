<#
.SYNOPSIS
    Discover a local UniFi Network application and optionally create WUG REST monitors.

.DESCRIPTION
    Uses the local Network Integration API (X-API-KEY) to discover sites and
    all adopted devices, connected clients, networks, Wi-Fi broadcasts, WANs,
    and available site configuration catalogs. API keys are requested through
    the DPAPI discovery vault. Adopted hardware is created or reconciled as WUG
    devices with UniFi attributes and per-device REST monitor assignments.

    WUG cannot resolve credential variables in REST custom-header property bags.
    A WUG push therefore stores the read-only API key in each monitor template.
    Pass -AllowApiKeyInMonitorLibrary to explicitly acknowledge this exposure.

.PARAMETER Target
    Local UniFi console address or hostname. Prompts when omitted; the controller must already exist in WUG for a push.

.PARAMETER ApiPort
    HTTPS API port. Default: 443. Prompts in interactive mode when omitted.

.PARAMETER ApiPathPrefix
    Path before /v1. Default for UniFi OS consoles: /proxy/network/integration.

.PARAMETER MaxDevicesPerSite
    Maximum adopted devices to create per-device monitors for on each site. Default: 100.

.PARAMETER Action
    PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, or None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login.

.PARAMETER OutputPath
    Directory for inventory dashboards and exports.

.PARAMETER AllowApiKeyInMonitorLibrary
    Acknowledge that WUG REST monitor templates store the UniFi API key.

.PARAMETER NonInteractive
    Suppress prompts; the target and saved UniFi API key must already be available.

.EXAMPLE
    .\Setup-UniFi-Discovery.ps1 -Target '192.168.1.235' -Action Dashboard

.EXAMPLE
    .\Setup-UniFi-Discovery.ps1 -Target '192.168.1.235' -Action PushToWUG -AllowApiKeyInMonitorLibrary
#>
[CmdletBinding()]
param(
    [string]$Target,

    [ValidateRange(1, 65535)]
    [int]$ApiPort = 443,

    [string]$ApiPathPrefix = '/proxy/network/integration',

    [ValidateRange(1, 1000)]
    [int]$MaxDevicesPerSite = 100,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$AllowApiKeyInMonitorLibrary,

    [switch]$NonInteractive
)

if (-not $Target) {
    if ($NonInteractive) { throw 'Target is required in non-interactive mode.' }
    $Target = Read-Host -Prompt 'UniFi console address or hostname'
}
if ([string]::IsNullOrWhiteSpace($Target)) { throw 'A UniFi console target is required.' }
Write-Host '=== UniFi Network Discovery ===' -ForegroundColor Cyan
Write-Host "  Controller: $Target`:$ApiPort"
Write-Host "  API path:   $ApiPathPrefix"

if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt 'UniFi HTTPS API port [default: 443]'
    if ($portInput -and $portInput -match '^\d+$') { $ApiPort = [int]$portInput }
}

if (-not $OutputPath) {
    if ($NonInteractive) { $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output' }
    else { $OutputPath = $env:TEMP }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
Write-Host "  Output:     $OutputPath"

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-UniFi.ps1')
$dashboardPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dashboardPath) { . $dashboardPath }

$credentialSplat = @{
    Name = "UniFi.$Target.Token"
    CredType = 'BearerToken'
    ProviderLabel = 'UniFi'
}
if ($NonInteractive) { $credentialSplat.NonInteractive = $true }
elseif ($Action) { $credentialSplat.AutoUse = $true }

try {
    $currentPhase = 'API key resolution'
    Write-Host "Authentication: resolving API key from vault entry 'UniFi.$Target.Token' ..." -ForegroundColor Cyan
    $apiKey = Resolve-DiscoveryCredential @credentialSplat
    if (-not $apiKey) {
        Write-Error "No UniFi API key available for '$Target'. Exiting."
        return
    }
    Write-Host 'Authentication: API key resolved; secret value will not be displayed.' -ForegroundColor Green

    $currentPhase = 'UniFi API discovery'
    Write-Host "Discovery: querying UniFi Network API on $Target`:$ApiPort ..." -ForegroundColor Cyan
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        Write-Verbose 'TLS certificate validation is disabled for this local controller session.'
    }
    $plan = Invoke-Discovery -ProviderName 'UniFi' `
        -Target @($Target) `
        -ApiPort $ApiPort `
        -Credential @{ ApiToken = $apiKey } `
        -Options @{ ApiPathPrefix = $ApiPathPrefix; MaxDevicesPerSite = $MaxDevicesPerSite } `
        -IgnoreCertErrors $true

    if (-not $plan -or $plan.Count -eq 0) { throw 'UniFi discovery returned no monitor plan.' }

    $active = @($plan | Where-Object ItemType -eq 'ActiveMonitor')
    $performance = @($plan | Where-Object ItemType -eq 'PerformanceMonitor')
    $inventoryCarrier = $plan | Where-Object { $_.UniFiInventoryRows } | Select-Object -First 1
    $inventoryRows = @($inventoryCarrier.UniFiInventoryRows)
    $adoptedDevices = @($inventoryCarrier.UniFiAdoptedDevices)
    Write-Host "UniFi discovery complete for $Target." -ForegroundColor Green
    Write-Host "  Inventory records:    $($inventoryRows.Count)"
    Write-Host "  Adopted devices:      $($adoptedDevices.Count)"
    Write-Host "  Active monitors:      $(@($active | Select-Object -ExpandProperty Name -Unique).Count) unique templates / $($active.Count) assignments"
    Write-Host "  Performance monitors: $(@($performance | Select-Object -ExpandProperty Name -Unique).Count) unique templates / $($performance.Count) assignments"
    Write-Host "  Plan items:           $($plan.Count)"
    $inventoryRows | Group-Object -Property Type | Sort-Object -Property Name | ForEach-Object {
        Write-Host ('    {0,-22} {1,5}' -f $_.Name, $_.Count) -ForegroundColor Gray
    }
    $insightRows = @($inventoryRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Insight) })
    Write-Host "  Insight-bearing rows: $($insightRows.Count)"

    $choice = $null
    if ($Action) {
        $choice = switch ($Action) {
            'PushToWUG' { '1' }
            'ExportJSON' { '2' }
            'ExportCSV' { '3' }
            'ShowTable' { '4' }
            'Dashboard' { '5' }
            'None' { '6' }
            'DashboardAndPush' { '7' }
        }
    }
    if (-not $choice -and $NonInteractive) { $choice = '5' }
    if (-not $choice) {
        Write-Host ''
        Write-Host 'What would you like to do?' -ForegroundColor Cyan
        Write-Host '  [1] Push devices, attributes, and monitors to WhatsUp Gold'
        Write-Host '  [2] Export inventory and monitor plan to JSON'
        Write-Host '  [3] Export inventory and monitor plan to CSV'
        Write-Host '  [4] Show inventory table'
        Write-Host '  [5] Generate UniFi inventory dashboard'
        Write-Host '  [6] Exit without additional output'
        Write-Host '  [7] Dashboard + Push to WUG'
        Write-Host ''
        $choice = Read-Host -Prompt 'Choice [1-7]'
    }

    Write-Host "Selected action: $(if ($Action) { $Action } else { $choice })" -ForegroundColor Cyan
    $actionsToRun = if ($choice -eq '7') { @('5', '1') } else { @($choice) }
    $pushToWug = $false
    foreach ($currentChoice in $actionsToRun) {
        switch ($currentChoice) {
            '1' { $pushToWug = $true }
            '2' {
                $currentPhase = 'JSON export'
                Write-Host 'Export: preparing secret-redacted JSON inventory and monitor plan ...' -ForegroundColor Cyan
                $safePlan = @($plan | Export-DiscoveryPlan -Format Object)
                $export = [ordered]@{
                    Controller = $Target
                    GeneratedAt = (Get-Date).ToString('o')
                    Inventory = $inventoryRows
                    MonitorPlan = $safePlan
                }
                $encoding = New-Object System.Text.UTF8Encoding($true)
                $exportPath = Join-Path $OutputPath 'UniFi-Inventory.json'
                [System.IO.File]::WriteAllText($exportPath, ($export | ConvertTo-Json -Depth 8), $encoding)
                Write-Host "Exported secret-redacted UniFi inventory and monitor plan to $exportPath" -ForegroundColor Green
                return
            }
            '3' {
                $currentPhase = 'CSV export'
                Write-Host 'Export: writing inventory and monitor-plan CSV files ...' -ForegroundColor Cyan
                $inventoryRows | Export-Csv -Path (Join-Path $OutputPath 'UniFi-Inventory.csv') -NoTypeInformation -Encoding UTF8
                $plan | Export-DiscoveryPlan -Format CSV -Path (Join-Path $OutputPath 'UniFi-Monitor-Plan.csv')
                Write-Host "Exported UniFi inventory and monitor plan to $OutputPath" -ForegroundColor Green
                return
            }
            '4' {
                Write-Host 'Display: formatting inventory rows ...' -ForegroundColor Cyan
                $inventoryRows | Select-Object Type,Site,Name,State,Address,Model,Firmware,CPU,Memory,RadioRetryPct,Insight,Severity | Format-Table -AutoSize
                return
            }
            '5' {
                $currentPhase = 'dashboard generation'
                Write-Host 'Dashboard: rendering UniFi inventory and insight report ...' -ForegroundColor Cyan
                if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) {
                    throw 'Export-DynamicDashboardHtml.ps1 is required for the UniFi inventory dashboard.'
                }
                $inventoryDashboard = Join-Path $OutputPath 'UniFi-Inventory-Dashboard.html'
                Export-DynamicDashboardHtml -Data $inventoryRows -OutputPath $inventoryDashboard `
                    -ReportTitle 'UniFi Network Inventory and Insights' -CardField Type,Severity -StatusField Severity -ExportPrefix 'unifi_inventory'
                Write-Host "Inventory dashboard: $inventoryDashboard" -ForegroundColor Green
                if ($actionsToRun.Count -eq 1) { return }
            }
            '6' { return }
        }
    }

    if (-not $pushToWug) { return }
    $currentPhase = 'WUG push acknowledgement'
    Write-Host 'WUG push: preparing controller, adopted devices, attributes, and REST monitors.' -ForegroundColor Cyan
    if (-not $AllowApiKeyInMonitorLibrary) {
        if ($NonInteractive) {
            throw 'WUG REST templates require a static API-key header. For non-interactive pushes, pass -AllowApiKeyInMonitorLibrary after reviewing the storage risk.'
        }
        $acknowledgement = Read-Host -Prompt 'WUG REST monitors store the UniFi API key in their custom header. Type YES to acknowledge and continue'
        if ($acknowledgement -cne 'YES') {
            Write-Warning 'WUG push canceled; no WUG devices or monitors were changed.'
            return
        }
    }

    $currentPhase = 'WUG connection'
    Write-Host "WUG push: loading module and connecting to $WUGServer ..." -ForegroundColor Cyan
    $repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'WhatsUpGoldPS.psd1') -Force -ErrorAction Stop
    if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) { throw 'Could not connect to WhatsUp Gold.' }
    Write-Host 'WUG push: connected.' -ForegroundColor Green

    $currentPhase = 'WUG controller lookup'
    Write-Host "WUG push: locating existing controller device '$Target' ..." -ForegroundColor Cyan
    $deviceMatch = Find-WUGDiscoveryDeviceMatch -Name $Target -Address $Target
    if ($deviceMatch.LookupFailed) { throw "WUG device lookup failed: $($deviceMatch.Error)" }
    if (-not $deviceMatch.Found) { throw "Controller '$Target' is not an existing WUG device; refusing to create a duplicate." }
    $deviceId = [int]$deviceMatch.Device.id
    Write-Host "WUG push: controller found (device ID $deviceId)." -ForegroundColor Green

    if (-not $inventoryCarrier) { throw 'Discovery plan did not include UniFi inventory metadata.' }
    $wugDeviceByApiId = @{}
    $wugDeviceIds = New-Object 'System.Collections.Generic.List[int]'
    [void]$wugDeviceIds.Add($deviceId)
    $controllerAddress = [string]$deviceMatch.Device.networkAddress

    $currentPhase = 'adopted-device reconciliation'
    Write-Host "WUG push: reconciling $($adoptedDevices.Count) adopted device(s) by name and IP ..." -ForegroundColor Cyan
    $deviceIndex = 0
    foreach ($inventoryDevice in $adoptedDevices) {
        $deviceIndex++
        $ipAddress = [string]$inventoryDevice.Address
        Write-Verbose "WUG device $deviceIndex/$($adoptedDevices.Count): '$($inventoryDevice.DisplayName)' ($ipAddress)."
        $parsedAddress = $null
        $isIPv4 = [System.Net.IPAddress]::TryParse($ipAddress, [ref]$parsedAddress) -and
            $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
        if (-not $isIPv4) {
            Write-Warning "UniFi device '$($inventoryDevice.Name)' has no IPv4 address; its REST monitors will remain on the controller device."
            $wugDeviceByApiId[$inventoryDevice.ApiDeviceId] = $deviceId
            continue
        }

        if ($controllerAddress -and $ipAddress -eq $controllerAddress) {
            $wugDeviceId = $deviceId
            Write-Host "  [$deviceIndex/$($adoptedDevices.Count)] '$($inventoryDevice.Name)' matches the controller device." -ForegroundColor Gray
        }
        else {
            $inventoryMatch = Find-WUGDiscoveryDeviceMatch -Name $inventoryDevice.DisplayName -Address $ipAddress `
                -AlternateName $inventoryDevice.Name
            if ($inventoryMatch.LookupFailed) {
                throw "WUG inventory-device lookup failed for '$($inventoryDevice.DisplayName)': $($inventoryMatch.Error)"
            }

            if ($inventoryMatch.Found) {
                $wugDeviceId = [int]$inventoryMatch.Device.id
                Write-Host "  [$deviceIndex/$($adoptedDevices.Count)] Found '$($inventoryDevice.DisplayName)' (WUG ID $wugDeviceId); updating $($inventoryDevice.Attributes.Count) attributes." -ForegroundColor Gray
                foreach ($attributeName in $inventoryDevice.Attributes.Keys) {
                    $attributeValue = [string]$inventoryDevice.Attributes[$attributeName]
                    if ([string]::IsNullOrWhiteSpace($attributeValue)) { continue }
                    Set-WUGDeviceAttribute -DeviceId $wugDeviceId -Name $attributeName -Value $attributeValue -Confirm:$false -ErrorAction Stop | Out-Null
                }
            }
            else {
                Write-Host "  [$deviceIndex/$($adoptedDevices.Count)] Creating '$($inventoryDevice.DisplayName)' at $ipAddress ..." -ForegroundColor Yellow
                $wugAttributes = @()
                foreach ($attributeName in $inventoryDevice.Attributes.Keys) {
                    $attributeValue = [string]$inventoryDevice.Attributes[$attributeName]
                    if ([string]::IsNullOrWhiteSpace($attributeValue)) { continue }
                    $wugAttributes += [PSCustomObject]@{ name = $attributeName; value = $attributeValue }
                }
                $primaryRole = if ($inventoryDevice.DeviceType -eq 'Switch') { 'Switch' }
                    elseif ($inventoryDevice.DeviceType -eq 'Gateway') { 'Router' }
                    else { 'Device' }
                $newDevice = Add-WUGDeviceTemplate -displayName $inventoryDevice.DisplayName `
                    -DeviceAddress $ipAddress -Hostname $inventoryDevice.Name -Brand 'Ubiquiti' `
                    -PrimaryRole $primaryRole -Note 'Discovered from the local UniFi Network Integration API.' `
                    -NoDefaultActiveMonitor -Attributes $wugAttributes -ErrorAction Stop
                if ($newDevice.errors -or -not $newDevice.idMap) {
                    throw "WUG did not return a device ID for '$($inventoryDevice.DisplayName)'."
                }
                $wugDeviceId = [int]($newDevice.idMap | Select-Object -First 1).resultId
                Write-Host "    Created WUG device ID $wugDeviceId with $($wugAttributes.Count) UniFi attributes." -ForegroundColor Green
            }
        }

        $wugDeviceByApiId[$inventoryDevice.ApiDeviceId] = $wugDeviceId
        if (-not $wugDeviceIds.Contains($wugDeviceId)) { [void]$wugDeviceIds.Add($wugDeviceId) }
    }

    $currentPhase = 'controller attribute synchronization'
    Write-Host "WUG push: synchronizing $($inventoryCarrier.Attributes.Count) controller attributes ..." -ForegroundColor Cyan
    foreach ($attributeName in $inventoryCarrier.Attributes.Keys) {
        $attributeValue = [string]$inventoryCarrier.Attributes[$attributeName]
        if ([string]::IsNullOrWhiteSpace($attributeValue)) { continue }
        Set-WUGDeviceAttribute -DeviceId $deviceId -Name $attributeName -Value $attributeValue -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # A failed library read must stop the push; it must never be treated as an empty library.
    $currentPhase = 'monitor library reconciliation'
    Write-Host 'WUG push: reading active and performance monitor libraries ...' -ForegroundColor Cyan
    $activeLibrary = Get-WUGMonitorLibraryMap -Type active -ErrorAction Stop
    $perfLibrary = Get-WUGMonitorLibraryMap -Type performance -ErrorAction Stop
    $uniqueActive = @{}
    foreach ($item in $active) { if (-not $uniqueActive.ContainsKey($item.Name)) { $uniqueActive[$item.Name] = $item } }
    $uniquePerf = @{}
    foreach ($item in $performance) { if (-not $uniquePerf.ContainsKey($item.Name)) { $uniquePerf[$item.Name] = $item } }

    $missingActive = @($uniqueActive.Keys | Where-Object { -not $activeLibrary.ContainsKey($_) })
    $missingPerf = @($uniquePerf.Keys | Where-Object { -not $perfLibrary.ContainsKey($_) })
    Write-Host "  Active templates: $($uniqueActive.Count) planned, $($missingActive.Count) to create, $($uniqueActive.Count - $missingActive.Count) already present." -ForegroundColor Gray
    Write-Host "  Performance templates: $($uniquePerf.Count) planned, $($missingPerf.Count) to create, $($uniquePerf.Count - $missingPerf.Count) already present." -ForegroundColor Gray

    if ($missingActive.Count -gt 0) {
        $templates = @()
        $index = 0
        foreach ($name in $missingActive) {
            $mp = $uniqueActive[$name].MonitorParams
            $templates += @{
                templateId = "unifi_act_$index"
                name = $name
                description = 'UniFi Network REST API active monitor'
                useInDiscovery = $false
                hasSensitiveData = $true
                monitorTypeInfo = @{ baseType = 'active'; classId = 'f0610672-d515-4268-bd21-ac5ebb1476ff' }
                propertyBags = @(
                    @{ name = 'MonRestApi:RestUrl'; value = [string]$mp.RestApiUrl }
                    @{ name = 'MonRestApi:HttpMethod'; value = 'GET' }
                    @{ name = 'MonRestApi:HttpTimeoutMs'; value = [string]$mp.RestApiTimeoutMs }
                    @{ name = 'MonRestApi:IgnoreCertErrors'; value = '1' }
                    @{ name = 'MonRestApi:UseAnonymousAccess'; value = '1' }
                    @{ name = 'MonRestApi:CustomHeader'; value = [string]$mp.RestApiCustomHeader }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn'; value = [string]$mp.RestApiDownIfResponseCodeIsIn }
                    @{ name = 'MonRestApi:ComparisonList'; value = [string]$mp.RestApiComparisonList }
                    @{ name = 'Cred:Type'; value = '8192' }
                )
            }
            $index++
        }
        for ($offset = 0; $offset -lt $templates.Count; $offset += 50) {
            $end = [Math]::Min($offset + 49, $templates.Count - 1)
            $batch = @($templates[$offset..$end])
            Write-Host "  Creating active monitor batch $([int]($offset / 50) + 1)/$([Math]::Ceiling($templates.Count / 50.0)) ($($batch.Count) templates) ..." -ForegroundColor Gray
            $null = Add-WUGMonitorTemplate -ActiveMonitors $batch -ErrorAction Stop
        }
    }

    if ($missingPerf.Count -gt 0) {
        $templates = @()
        $index = 0
        foreach ($name in $missingPerf) {
            $mp = $uniquePerf[$name].MonitorParams
            $templates += @{
                templateId = "unifi_perf_$index"
                name = $name
                description = 'UniFi Network REST API performance monitor'
                hasSensitiveData = $true
                monitorTypeInfo = @{ baseType = 'performance'; classId = '987bb6a4-70f4-4f46-97c6-1c9dd1766437' }
                propertyBags = @(
                    @{ name = 'RdcRestApi:RestUrl'; value = [string]$mp.RestApiUrl }
                    @{ name = 'RdcRestApi:JsonPath'; value = [string]$mp.RestApiJsonPath }
                    @{ name = 'RdcRestApi:HttpMethod'; value = 'GET' }
                    @{ name = 'RdcRestApi:HttpTimeoutMs'; value = [string]$mp.RestApiHttpTimeoutMs }
                    @{ name = 'RdcRestApi:IgnoreCertErrors'; value = '1' }
                    @{ name = 'RdcRestApi:UseAnonymousAccess'; value = '1' }
                    @{ name = 'RdcRestApi:CustomHeader'; value = [string]$mp.RestApiCustomHeader }
                    @{ name = 'Cred:Type'; value = '8192' }
                )
            }
            $index++
        }
        for ($offset = 0; $offset -lt $templates.Count; $offset += 50) {
            $end = [Math]::Min($offset + 49, $templates.Count - 1)
            $batch = @($templates[$offset..$end])
            Write-Host "  Creating performance monitor batch $([int]($offset / 50) + 1)/$([Math]::Ceiling($templates.Count / 50.0)) ($($batch.Count) templates) ..." -ForegroundColor Gray
            $null = Add-WUGMonitorTemplate -PerformanceMonitors $batch -ErrorAction Stop
        }
    }

    $activeLibrary = Get-WUGMonitorLibraryMap -Type active -ErrorAction Stop
    $perfLibrary = Get-WUGMonitorLibraryMap -Type performance -ErrorAction Stop
    $unresolvedActive = @($uniqueActive.Keys | Where-Object { -not $activeLibrary.ContainsKey($_) })
    $unresolvedPerf = @($uniquePerf.Keys | Where-Object { -not $perfLibrary.ContainsKey($_) })
    if ($unresolvedActive.Count -or $unresolvedPerf.Count) {
        throw "Monitor templates did not reconcile. Unresolved active=$($unresolvedActive.Count), performance=$($unresolvedPerf.Count). No assignments made."
    }
    Write-Host "WUG push: monitor library reconciled ($($activeLibrary.Count) active and $($perfLibrary.Count) performance templates available)." -ForegroundColor Green

    $activeAssignments = @{}
    $performanceAssignments = @{}
    foreach ($name in $uniqueActive.Keys) {
        $targetDeviceId = $deviceId
        $apiDeviceId = [string]$uniqueActive[$name].Attributes['UniFi.AdoptedDeviceId']
        if ($apiDeviceId -and $wugDeviceByApiId.ContainsKey($apiDeviceId)) {
            $targetDeviceId = [int]$wugDeviceByApiId[$apiDeviceId]
        }
        if (-not $activeAssignments.ContainsKey($targetDeviceId)) {
            $activeAssignments[$targetDeviceId] = New-Object 'System.Collections.Generic.List[int]'
        }
        [void]$activeAssignments[$targetDeviceId].Add([int]$activeLibrary[$name])
    }
    foreach ($name in $uniquePerf.Keys) {
        $targetDeviceId = $deviceId
        $apiDeviceId = [string]$uniquePerf[$name].Attributes['UniFi.AdoptedDeviceId']
        if ($apiDeviceId -and $wugDeviceByApiId.ContainsKey($apiDeviceId)) {
            $targetDeviceId = [int]$wugDeviceByApiId[$apiDeviceId]
        }
        if (-not $performanceAssignments.ContainsKey($targetDeviceId)) {
            $performanceAssignments[$targetDeviceId] = New-Object 'System.Collections.Generic.List[int]'
        }
        [void]$performanceAssignments[$targetDeviceId].Add([int]$perfLibrary[$name])
    }

    $assignmentTargets = @($activeAssignments.Keys) + @($performanceAssignments.Keys) | Select-Object -Unique
    $activeAssignedCount = 0
    $performanceAssignedCount = 0
    $currentPhase = 'monitor assignment'
    Write-Host "WUG push: assigning monitors across $($assignmentTargets.Count) device(s) ..." -ForegroundColor Cyan
    foreach ($targetDeviceId in $assignmentTargets) {
        if ($activeAssignments.ContainsKey($targetDeviceId)) {
            $assignedActive = @(Get-WUGActiveMonitor -DeviceId $targetDeviceId -AssignmentView basic -EnabledOnly 'false' -ErrorAction Stop |
                Select-Object -ExpandProperty MonitorTypeId -Unique)
            $missingActiveIds = @($activeAssignments[$targetDeviceId] | Where-Object { $assignedActive -notcontains $_ })
            if ($missingActiveIds.Count) {
                Write-Host "  Device $targetDeviceId`: assigning $($missingActiveIds.Count) active monitor(s) ($($assignedActive.Count) already assigned)." -ForegroundColor Gray
                Add-WUGActiveMonitorToDevice -DeviceId $targetDeviceId -MonitorId $missingActiveIds -ErrorAction Stop | Out-Null
                $activeAssignedCount += $missingActiveIds.Count
            }
            else { Write-Verbose "Device $targetDeviceId already has all $($assignedActive.Count) planned active monitor(s)." }
        }
        if ($performanceAssignments.ContainsKey($targetDeviceId)) {
            $assignedPerf = @(Get-WUGPerformanceMonitor -DeviceId $targetDeviceId -View basic -ErrorAction Stop |
                Select-Object -ExpandProperty MonitorTypeId -Unique)
            $missingPerfIds = @($performanceAssignments[$targetDeviceId] | Where-Object { $assignedPerf -notcontains $_ })
            if ($missingPerfIds.Count) {
                Write-Host "  Device $targetDeviceId`: assigning $($missingPerfIds.Count) performance monitor(s) ($($assignedPerf.Count) already assigned)." -ForegroundColor Gray
                Add-WUGPerformanceMonitorToDevice -DeviceId $targetDeviceId -MonitorId $missingPerfIds `
                    -PollingIntervalMinutes 10 -ErrorAction Stop | Out-Null
                $performanceAssignedCount += $missingPerfIds.Count
            }
            else { Write-Verbose "Device $targetDeviceId already has all $($assignedPerf.Count) planned performance monitor(s)." }
        }
    }

    $currentPhase = 'device-group synchronization'
    Write-Host "WUG push: synchronizing UniFi-WhatsUpGoldPS group with $($wugDeviceIds.Count) device(s) ..." -ForegroundColor Cyan
    $group = Sync-WUGDiscoveryDeviceGroup -Name 'UniFi-WhatsUpGoldPS' -DeviceId $wugDeviceIds.ToArray() `
        -Description 'UniFi Network controllers and adopted devices managed by WhatsUpGoldPS discovery.' -Confirm:$false

    Write-Host "Push complete: $($wugDeviceIds.Count) WUG devices; $activeAssignedCount active and $performanceAssignedCount performance monitors assigned." -ForegroundColor Green
    if ($group.GroupId) { Write-Host "  Group: UniFi-WhatsUpGoldPS (ID $($group.GroupId)); added $($group.Added)." }
    Write-Host 'WUG push completed successfully.' -ForegroundColor Green
}
catch {
    Write-Warning "UniFi workflow failed during '$currentPhase': $($_.Exception.Message)"
    throw
}
finally {
    $apiKey = $null
    $credentialSplat = $null
    Write-Verbose 'UniFi API key references cleared from the setup script scope.'
}
# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAEvNAWvncR8cW/
# FVMVcF8KXexY9SKQ5AFe6AMcvEVGyqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCBZQuxOGWcB04o0jwAbI4t6nJ89Dx8wW/qWF0F2ltJAxjANBgkqhkiG9w0BAQEF
# AASCAgAOdye4MjCyVIani3zYhgcy+cOvLPCeuywCF6C7rOjnY9u9elVXMBXxaGEy
# qzGvnFTI3ZtY7E96uhRbHId8AmD4Zjh6XPNa2/0Bz044vnxjBNZC0+XHs9xLDLXX
# k/Y4s9AHY+8/sLPuq3EUDooqhnLP5wR/xOUVUPmSdjK0kl0xj+urF07W3bBxn3i2
# cOUSGFcKPzy9mTNBq+paUTgtqmHdBlfCejp3nVCtxH106EvMZa6H44DG781CafOT
# AZ8fm2gAw3lGhw3TOQRVxjTxkAE8ml6PRnwv8eggMuIgLVzIz3EGKNoBWAX/HE4M
# 6yI1cIUH2PQOKpg/MU+XuOAKW0ak4R+0gMaD7kWPH9Q0jwqx2PWoBSfrTz6px+K3
# uBvyh6s+cVX/oC/6CkC5HS5uwLuv1idxzKhQDtF6pyZLv5LXtcKmAth/rleJoZ/G
# CzRUDjJnTGh2mu0r7MyDHVcWj7FSLl7cCnNFNT+KopM94Aw5tuFsA186cA6fTP2j
# X9bLRukD4Bt4T+SX10uaoy0YgKs6w6Tb/ZaSSue5mIqWPbjCuvZ6icrIlC1jluEp
# 79xM19YpJvEgucXccDDUktxqTKNbYlog7F8VI2YZtNc106L5RNG8svi2yWWl/258
# PBf/8Jl0QMrNU3ozwH46gtBb+XhrWL8IKzI+1+BweEz+tdmHmaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MzAyMTU0MDNaMC8GCSqGSIb3DQEJBDEiBCBZLkWf
# BDc2r53X93rQCIG3TD3tINOtdp3FEJdtAjJljTANBgkqhkiG9w0BAQEFAASCAgBx
# nTyj3E6iMNqfDSie49gJzU9opqyGQV+LEGHnc28wpUrzUtSn96unEhYcV+rKx8Hk
# 4AFGm214+lWzcbzKAHeB0GPrvnLGT6CkcCMCspqVr2ha8k3n2Tan1JKpRAxMUSWG
# QUToUpSe89udO0ZSSi9VvY8zYWqQGq5Uc7RnWxV4CI0R5uk1dgMDERtWyxaMyl43
# ipbYNy3LHs0ciIWA7x4Vhq0zBcbiTge2ZCCOBGtBYfRK3PMjbdjxiBNW22LPkhSg
# lv4e4SygH8txn4SnxVIrrAOHOSQqKtEcmFjcM3vRkWNU1L3T029AAEJea2PhqXIJ
# s96k92AZSQf2nInXvdNPBj4bsFWPas41fFI9XKcLD+6Uw3A/sSwygpIXj2d9kJ6l
# SezCW7EdpVgIHAsx3wGkWRpFzxzOleJjsnfBqb43b255fxuNhdvrgs3Vq0OLU4Qr
# sdCiLSxSqpLpiwxvL6+vlikHswTx15SWA2k44JySMtMGV4C7IVDDim93N8lcwXVb
# zeJaqcw9vHdOMQunr2U8lGHDDJcKWJVYIKF8Qc2naAZqA+ftB25/gFYbbR5ibDf+
# 3hSlgOZGPJPHAQV1H9mixSbSJueWaJN/XLuTvgWoZZQHi+voIL4noDzdOCeRJg08
# kxqremNRMEM+AiyDYQgJfPIKWHplOhzNHRMTfGP9vw==
# SIG # End signature block
