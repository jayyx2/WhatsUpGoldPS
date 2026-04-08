<#
.SYNOPSIS
    Nutanix Discovery -- Discover clusters, hosts, and VMs from Nutanix Prism,
    then optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers Nutanix infrastructure via the Prism v2.0
    REST API, then lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + REST API monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Exit

    Architecture (when pushed to WUG):
      [Nutanix Host device in WUG]
          |-- "Nutanix Cluster Health - <cluster>"   (Active Monitor)
          |-- "Nutanix Host Health - <host>"          (Active Monitor)
          |-- "cpu_ppm - <host> (NutanixHost)"        (Perf Monitor)
          |-- "memory_ppm - <host> (NutanixHost)"     (Perf Monitor)
          '-- ...
      [Nutanix VM device in WUG]
          |-- "Nutanix VM Health - <vm>"              (Active Monitor)
          |-- "cpu_ppm - <vm> (NutanixVM)"            (Perf Monitor)
          '-- "memory_ppm - <vm> (NutanixVM)"         (Perf Monitor)

    First Run:
      1. Prompts for Prism Element/Central host(s) and port
      2. Prompts for Nutanix credentials (username + password)
      3. Stores credentials in DPAPI vault (encrypted to user + machine)
      4. Discovers clusters, hosts, VMs
      5. Shows summary, then asks what to do

    Subsequent Runs:
      Loads credentials from vault automatically.

.PARAMETER Target
    Nutanix Prism host(s) -- IP address or FQDN. Accepts multiple values.

.PARAMETER ApiPort
    Nutanix Prism API port. Default: 9440.

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and parameter defaults.

.NOTES
    Nutanix Prism uses self-signed SSL certificates -- the provider handles
    SSL bypass automatically for PowerShell 5.1.

.EXAMPLE
    .\Setup-Nutanix-Discovery.ps1
    # Interactive mode.

.EXAMPLE
    .\Setup-Nutanix-Discovery.ps1 -Target '10.0.0.10' -Action PushToWUG -NonInteractive
    # Scheduled mode -- uses vault credentials, pushes to WUG.

.EXAMPLE
    .\Setup-Nutanix-Discovery.ps1 -Target '10.0.0.10','10.0.0.11' -Action ExportJSON
    # Discover multiple Prism hosts and export plan.
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [int]$ApiPort = 9440,

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

$DefaultHost  = '10.0.0.10'
$NutanixPort  = $ApiPort

# --- Load helpers -------------------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Nutanix.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Nutanix Discovery ===" -ForegroundColor Cyan
Write-Host ""

if ($Target) {
    $NutanixHosts = @($Target)
}
elseif ($NonInteractive) {
    $NutanixHosts = @($DefaultHost)
}
else {
    Write-Host "Enter Nutanix Prism host(s) -- IP address or FQDN." -ForegroundColor Cyan
    Write-Host "For multiple hosts, separate with commas." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt "Prism host(s) [default: $DefaultHost]"
    if ([string]::IsNullOrWhiteSpace($hostInput)) { $hostInput = $DefaultHost }
    $NutanixHosts = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($NutanixHosts.Count -eq 0) { Write-Error 'No valid host provided.'; return }
Write-Host "Targets: $($NutanixHosts -join ', ')" -ForegroundColor Cyan
Write-Host ""

# --- Port prompt ---
if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt "Nutanix Prism API port [default: $NutanixPort]"
    if ($portInput -and $portInput -match '^\d+$') { $NutanixPort = [int]$portInput }
}

# ==============================================================================
# STEP 2: Authentication (username + password for Basic auth)
# ==============================================================================
$vaultName = "Nutanix.$($NutanixHosts[0]).Credential"
$credSplat = @{ Name = $vaultName; CredType = 'PSCredential'; ProviderLabel = 'Nutanix' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
$psCred = Resolve-DiscoveryCredential @credSplat

if (-not $psCred) {
    Write-Error 'No Nutanix credentials available. Exiting.'
    return
}

$nutanixCredential = @{
    Username = $psCred.UserName
    Password = $psCred.GetNetworkCredential().Password
}

Write-Host "Authenticated as: $($psCred.UserName)" -ForegroundColor Green
Write-Host ""

# ==============================================================================
# STEP 3: Discover -- query Nutanix Prism API
# ==============================================================================
Write-Host "Querying Nutanix Prism at $($NutanixHosts -join ', ')..." -ForegroundColor Cyan

$plan = Invoke-Discovery -ProviderName 'Nutanix' `
    -Target $NutanixHosts `
    -ApiPort $NutanixPort `
    -Credential $nutanixCredential `
    -IgnoreCertErrors

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check Nutanix connectivity and credentials."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================
$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $type = $item.Attributes['Nutanix.DeviceType']
    switch ($type) {
        'Cluster' {
            $key  = "cluster:$($item.Attributes['Nutanix.ClusterName'])"
            $name = $item.Attributes['Nutanix.ClusterName']
            $ip   = $item.Attributes['Nutanix.ClusterIP']
        }
        'Host' {
            $key  = "host:$($item.Attributes['Nutanix.HostName'])"
            $name = $item.Attributes['Nutanix.HostName']
            $ip   = $item.Attributes['Nutanix.HostIP']
        }
        'VM' {
            $vmId = $item.Attributes['Nutanix.VMUUID']
            $key  = "vm:$vmId"
            $name = $item.Attributes['Nutanix.VMName']
            $ip   = $item.Attributes['Nutanix.VMIP']
        }
        default { continue }
    }
    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name  = $name
            IP    = $ip
            Type  = $type
            Attrs = $item.Attributes
            Items = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$clusterDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'Cluster' })
$hostDevices    = @($devicePlan.Values | Where-Object { $_.Type -eq 'Host' })
$vmDevices      = @($devicePlan.Values | Where-Object { $_.Type -eq 'VM' })
$vmWithIP       = @($vmDevices | Where-Object { $_.IP })
$vmNoIP         = @($vmDevices | Where-Object { -not $_.IP })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } | Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Clusters:               $($clusterDevices.Count)" -ForegroundColor White
Write-Host "  Hosts:                  $($hostDevices.Count)" -ForegroundColor White
Write-Host "  VMs:                    $($vmDevices.Count)" -ForegroundColor White
Write-Host "  VMs with IP:            $($vmWithIP.Count)" -ForegroundColor White
Write-Host "  VMs without IP:         $($vmNoIP.Count)" -ForegroundColor White
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

Write-Host "Monitor templates:" -ForegroundColor Cyan
foreach ($t in $activeTemplates) { Write-Host "  [Active] $t" -ForegroundColor White }
foreach ($t in $perfTemplates)   { Write-Host "  [Perf]   $t" -ForegroundColor White }
Write-Host ""

if ($vmNoIP.Count -gt 0) {
    Write-Host "VMs without IP (will use 0.0.0.0):" -ForegroundColor Yellow
    foreach ($v in $vmNoIP) { Write-Host "    $($v.Name)" -ForegroundColor DarkYellow }
    Write-Host ""
}

$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    ForEach-Object { [PSCustomObject]@{
        Device   = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { '(none)' }
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
            DevicesCreated = 0; DevicesFound = 0; CredsAssigned = 0
        }
        $wugDeviceMap = @{}
        $deviceKeys = @($devicePlan.Keys | Sort-Object)
        $devTotal = $deviceKeys.Count

        # ---- 1. Create/find REST API credential ---
        Write-Host ""
        Write-Host "Setting up Nutanix REST API credential in WUG..." -ForegroundColor Cyan
        $credName = "Nutanix Prism API"
        $nutanixCredId = $null

        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName -View basic)
            if ($existingCreds.Count -eq 0) { $existingCreds = @(Get-WUGCredential -SearchValue $credName -View basic) }
            if ($existingCreds.Count -gt 0) {
                $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                if ($matchCred) { $nutanixCredId = $matchCred.id; Write-Host "  Found existing credential (ID: $nutanixCredId)" -ForegroundColor Green }
            }
        }
        catch { }

        if (-not $nutanixCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                $credResult = Add-WUGCredential -Name $credName `
                    -Description "Nutanix Prism API credential (auto-created by discovery)" `
                    -Type restapi `
                    -RestApiUsername $psCred.UserName `
                    -RestApiPassword ($psCred.GetNetworkCredential().Password) `
                    -RestApiAuthType '1' `
                    -RestApiIgnoreCertErrors 'True'
                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) { $nutanixCredId = $credResult.data.idMap.resultId }
                    elseif ($credResult.PSObject.Properties['resourceId']) { $nutanixCredId = $credResult.resourceId }
                    elseif ($credResult.PSObject.Properties['id']) { $nutanixCredId = $credResult.id }
                    if ($nutanixCredId) { Write-Host "  Created credential (ID: $nutanixCredId)" -ForegroundColor Green }
                }
            }
            catch { Write-Verbose "Credential creation failed: $_" }
            if (-not $nutanixCredId) {
                try {
                    $recheck = @(Get-WUGCredential -SearchValue $credName -View basic)
                    $match = $recheck | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                    if ($match) { $nutanixCredId = $match.id }
                }
                catch { }
            }
            if (-not $nutanixCredId) { Write-Warning "Could not create REST API credential. Create manually in WUG." }
        }

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

        $existingActiveNames = @{}
        foreach ($actName in @($uniqueActiveMonitors.Keys)) {
            try {
                $found = @(Get-WUGActiveMonitor -Search $actName)
                $exact = $found | Where-Object { $_.name -eq $actName } | Select-Object -First 1
                if ($exact) { $existingActiveNames[$actName] = [int]$exact.id }
            }
            catch { }
        }

        $toCreateActive = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        $stats.HealthSkipped = $uniqueActiveMonitors.Count - $toCreateActive.Count

        if ($toCreateActive.Count -gt 0) {
            Write-Host "    Creating $($toCreateActive.Count) new active monitors (bulk)..." -ForegroundColor DarkGray

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
                    @{ name = 'MonRestApi:IgnoreCertErrors';       value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '1' } }
                    @{ name = 'MonRestApi:UseAnonymousAccess';     value = if ($mp.RestApiUseAnonymous) { "$($mp.RestApiUseAnonymous)" } else { '0' } }
                    @{ name = 'MonRestApi:CustomHeader';           value = if ($mp.RestApiCustomHeader) { "$($mp.RestApiCustomHeader)" } else { '' } }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn'; value = if ($mp.RestApiDownIfResponseCodeIsIn) { "$($mp.RestApiDownIfResponseCodeIsIn)" } else { '[]' } }
                    @{ name = 'MonRestApi:ComparisonList';         value = if ($mp.RestApiComparisonList) { "$($mp.RestApiComparisonList)" } else { '[]' } }
                    @{ name = 'Cred:Type';                        value = '8192' }
                )

                $activeTemplateArr += @{
                    templateId      = $tplId
                    name            = $actName
                    description     = 'Nutanix RestApi active monitor'
                    useInDiscovery  = $false
                    monitorTypeInfo = @{ baseType = 'active'; classId = 'f0610672-d515-4268-bd21-ac5ebb1476ff' }
                    propertyBags    = $bags
                }
            }

            try {
                $batchSize = 50
                for ($bi = 0; $bi -lt $activeTemplateArr.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $activeTemplateArr.Count - 1)
                    $actBatch = @($activeTemplateArr[$bi..$batchEnd])
                    if ($activeTemplateArr.Count -gt $batchSize) {
                        $batchNum = [Math]::Floor($bi / $batchSize) + 1
                        $totalBatches = [Math]::Ceiling($activeTemplateArr.Count / $batchSize)
                        Write-Host "      Batch $batchNum/$totalBatches ($($actBatch.Count) monitors)..." -ForegroundColor DarkGray
                    }

                    $bulkActResult = Add-WUGMonitorTemplate -ActiveMonitors $actBatch
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
                    if ($batchEnd -lt $activeTemplateArr.Count - 1) { Start-Sleep -Seconds 2 }
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
        foreach ($monName in @($uniquePerfMonitors.Keys)) {
            try {
                $found = @(Get-WUGPerformanceMonitor -Search $monName)
                $exact = $found | Where-Object { $_.name -eq $monName } | Select-Object -First 1
                if ($exact) { $existingPerfNames[$monName] = "$($exact.id)" }
            }
            catch { }
        }

        $toCreatePerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        $stats.PerfSkipped = $uniquePerfMonitors.Count - $toCreatePerf.Count

        if ($toCreatePerf.Count -gt 0) {
            Write-Host "    Creating $($toCreatePerf.Count) new perf monitors (bulk)..." -ForegroundColor DarkGray

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
                    @{ name = 'RdcRestApi:IgnoreCertErrors';   value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '1' } }
                    @{ name = 'RdcRestApi:UseAnonymousAccess'; value = if ($mp.RestApiUseAnonymousAccess) { "$($mp.RestApiUseAnonymousAccess)" } else { '0' } }
                    @{ name = 'RdcRestApi:CustomHeader';       value = if ($mp.RestApiCustomHeader) { "$($mp.RestApiCustomHeader)" } else { '' } }
                )

                $perfTemplateArr += @{
                    templateId      = $tplId
                    name            = $monName
                    description     = 'Nutanix RestApi performance monitor'
                    monitorTypeInfo = @{ baseType = 'performance'; classId = '987bb6a4-70f4-4f46-97c6-1c9dd1766437' }
                    propertyBags    = $bags
                }
            }

            try {
                $batchSize = 50
                for ($bi = 0; $bi -lt $perfTemplateArr.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $perfTemplateArr.Count - 1)
                    $perfBatch = @($perfTemplateArr[$bi..$batchEnd])
                    $batchNum = [Math]::Floor($bi / $batchSize) + 1
                    $totalBatches = [Math]::Ceiling($perfTemplateArr.Count / $batchSize)
                    Write-Host "      Batch $batchNum/$totalBatches ($($perfBatch.Count) monitors)..." -ForegroundColor DarkGray

                    $bulkPerfResult = Add-WUGMonitorTemplate -PerformanceMonitors $perfBatch
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
                    if ($batchEnd -lt $perfTemplateArr.Count - 1) { Start-Sleep -Seconds 2 }
                }
            }
            catch { Write-Warning "Bulk perf monitor creation failed: $_"; $stats.PerfFailed += $toCreatePerf.Count }
        }
        Write-Host "    Perf monitors: $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor DarkGray

        # ---- 2c. Check existing vs new devices ---
        Write-Host "  Checking for existing devices..." -ForegroundColor Cyan
        $existingDevices = @{}
        $newDeviceKeys = [System.Collections.Generic.List[string]]::new()
        $devIdx = 0

        foreach ($key in $deviceKeys) {
            $devIdx++
            $dev = $devicePlan[$key]
            $addIP = if ($dev.IP -and $dev.IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $dev.IP } else { '0.0.0.0' }
            $displayName = "$($dev.Name) ($($dev.Type))"

            Write-Progress -Activity 'Checking existing devices' `
                -Status "$devIdx / $devTotal - $($dev.Name)" `
                -PercentComplete ([Math]::Round(($devIdx / $devTotal) * 100))

            $deviceId = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $match = $searchResults | Where-Object { $_.displayName -eq $dev.Name -or $_.displayName -eq $displayName -or $_.hostName -eq $dev.Name } | Select-Object -First 1
                    if ($match) { $deviceId = $match.id }
                }
                if (-not $deviceId -and $dev.IP) {
                    $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                    $match = $searchResults | Where-Object { $_.networkAddress -eq $addIP } | Select-Object -First 1
                    if ($match) { $deviceId = $match.id }
                }
            }
            catch { }

            if ($deviceId) { $existingDevices[$key] = $deviceId; $wugDeviceMap[$key] = $deviceId; $stats.DevicesFound++ }
            else { $newDeviceKeys.Add($key) }
        }
        Write-Progress -Activity 'Checking existing devices' -Completed
        Write-Host "    Found $($stats.DevicesFound) existing, $($newDeviceKeys.Count) new" -ForegroundColor DarkGray

        # ---- 2d. Create new devices ---
        if ($newDeviceKeys.Count -gt 0) {
            Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow
            $devIdx = 0
            foreach ($key in $newDeviceKeys) {
                $devIdx++
                $dev = $devicePlan[$key]
                $addIP = if ($dev.IP -and $dev.IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $dev.IP } else { '0.0.0.0' }
                $displayName = "$($dev.Name) ($($dev.Type))"

                Write-Progress -Activity 'Creating devices' `
                    -Status "$devIdx / $($newDeviceKeys.Count) - $displayName" `
                    -PercentComplete ([Math]::Round(($devIdx / $newDeviceKeys.Count) * 100))

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

                # Perf monitors assigned separately for polling interval control
                if ($actNames.Count -eq 0) {
                    # Check if there are perf monitors at least
                    $hasPerfMons = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count -gt 0
                    if (-not $hasPerfMons) { continue }
                }

                $splat = @{
                    displayName            = $displayName
                    DeviceAddress          = $addIP
                    Hostname               = $dev.Name
                    Brand                  = 'Nutanix'
                    Note                   = "Nutanix $($dev.Type) (auto-created by discovery)"
                    NoDefaultActiveMonitor = $true
                }
                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($nutanixCredId) { $splat['CredentialRestApi'] = $credName }
                if ($actNames.Count -gt 0) { $splat['ActiveMonitors'] = $actNames }

                try {
                    $devResult = Add-WUGDeviceTemplate @splat
                    if ($devResult -and -not $devResult.error) {
                        $newDeviceId = $null
                        if ($devResult.idMap) { $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId }
                        elseif ($devResult.PSObject.Properties['resultId']) { $newDeviceId = $devResult.resultId }
                        if ($newDeviceId) { $wugDeviceMap[$key] = $newDeviceId }
                        $stats.DevicesCreated++
                    }
                }
                catch { Write-Warning "Error creating device '$displayName': $_" }
            }
            Write-Progress -Activity 'Creating devices' -Completed
            Write-Host "    Devices created: $($stats.DevicesCreated)" -ForegroundColor Green
        }

        # ---- 2e. Assign perf monitors separately (new + existing devices) ---
        Write-Host "  Assigning performance monitors to devices..." -ForegroundColor Cyan
        foreach ($key in $deviceKeys) {
            $deviceId = $wugDeviceMap[$key]
            if (-not $deviceId) { continue }
            $deviceId = [int]$deviceId
            $dev = $devicePlan[$key]

            # Assign credential
            if ($nutanixCredId -and $existingDevices.ContainsKey($key)) {
                try { $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $nutanixCredId -Assign; $stats.CredsAssigned++ }
                catch { }
            }

            # Assign active monitors (for existing devices)
            if ($existingDevices.ContainsKey($key)) {
                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) { $actMonitorIds += $existingActiveNames[$actItem.Name] }
                }
                if ($actMonitorIds.Count -gt 0) {
                    try { Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $actMonitorIds -ErrorAction Stop } catch { }
                }
            }

            # Assign perf monitors with polling interval (all devices)
            $perfMonitorIds = @()
            foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name)) { $perfMonitorIds += [int]$existingPerfNames[$perfItem.Name] }
            }
            if ($perfMonitorIds.Count -gt 0) {
                try { Add-WUGPerformanceMonitorToDevice -DeviceId $deviceId -MonitorId $perfMonitorIds -PollingIntervalMinutes 5 -ErrorAction Stop }
                catch { }
            }
        }

        # ---- Summary ---
        Write-Host ""
        Write-Host "Push complete!" -ForegroundColor Green
        Write-Host "  Active monitors:  $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor White
        Write-Host "  Perf monitors:    $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor White
        Write-Host "  Devices:          $($stats.DevicesCreated) created, $($stats.DevicesFound) existing" -ForegroundColor White
        Write-Host "  Creds assigned:   $($stats.CredsAssigned)" -ForegroundColor White
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'nutanix-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'nutanix-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate Nutanix HTML Dashboard from discovery data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building Nutanix dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $activeItems = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })
            $perfItems   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })

            foreach ($item in ($activeItems + $perfItems)) {
                $dashboardRows += [PSCustomObject]@{
                    Device        = $dev.Name
                    IP            = if ($dev.IP) { $dev.IP } else { '(cluster)' }
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
            $dashPath = Join-Path $OutputDir 'Nutanix-Dashboard.html'

            if (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
                Export-DynamicDashboardHtml -Data $dashboardRows `
                    -OutputPath $dashPath `
                    -ReportTitle 'Nutanix Discovery Dashboard' `
                    -CardField 'Device','Type' `
                    -StatusField 'Status'
            }
            else {
                Write-Warning "No dashboard function available. Exporting as JSON instead."
                $jsonPath = Join-Path $OutputDir "Nutanix-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).json"
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
                $wugDashPath = Join-Path $wugDashDir 'Nutanix-Dashboard.html'
                try {
                    Copy-Item -Path $dashPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/Nutanix-Dashboard.html" -ForegroundColor Cyan
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
Write-Host "Re-run anytime to discover new Nutanix clusters/hosts/VMs." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCnNHnnPHdVbmTk
# VHjXkx0cBoERZ9aaUIY11NIXeZNuMaCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBDxEJ1
# B4banAOPQyfHNR6XGiIyGmAiw2Ka29jEV1t6kjANBgkqhkiG9w0BAQEFAASCAgC7
# afx9MkC5FdfNdWCim1QLQLJLciM+a2xC57qEFniai9BEvQXmGaxnhb53EK5EQp4Q
# B7uH7U5EXQi4+aodNY1tyv6EvR9QiarF6FSRwYA+qkVR/LAgfvXRHKOLaJ/ph763
# K4irbo3Et2W3Kbw00pccA6Md2efu2PQ0e0ShLCgCAyQiNhzqiSuWtAOeZGC0Ffh5
# 2ykGEfkX/XrJbJf58gy4VNgPRG+494y6U7FEBSERH8To13MJopcDYgIbFdgaSF4E
# kAF4OMHxvPnXzwIphWN9gsRNJOgR4oInQn9I37ly9h1ZERtgXzMAq+0zQ7DLz0L8
# k9DwautK67ydyZi/lvzusLr/Mm6akLL1siaAV8MKkE6KnQPLtj40cll/3P2b6FE4
# U2YIHkksoLG6hgf2MlnT7GnYNXfJl5uDVvoJ7k/o8G1uB/1ucnhDjsgbrY1ZXGBS
# aF9NaDDMRRIp+acX+3Oqq2BgFrvhWJtmF09efv6RWn4mvvwOA7VkCb61k/3GjPF1
# atnON7TfqfvCO9O+1flWRxrwqw2/vSkJwI2mfyabmxGFrqnf0cEgdjBdfYs24NkE
# 7iEshQkkN9H9oLIPDKna5vKAHW5z95dI3FOU4tF6BjRpp8WFFqSa+cuGC13SKU+S
# kqqV5cNrlg2I8XkCPsrPECoftNZKKsIsYVkHmtfvVaGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzExNTIw
# NFowPwYJKoZIhvcNAQkEMTIEMOyCkAa0Ra+JED9gPB/K6dOY1ijiSmwRzSDyf00A
# HuZn2/0s7ywNsozauyOlIPa0KjANBgkqhkiG9w0BAQEFAASCAgAKobiwDEwbNAmI
# iBMhlkBg9anUlk9c7Zyl5e52DtjL4Y5+fB8vjs/lhX1JQXgSSaByxJhHrFI5wiGD
# +qVLsYIj3ww6rvxpVsNrxDWwDhV1/ek/58dwQUWMRJoBpiS5Dc1srOGjSkV7dYZg
# wao69hgRnLe5EVe+Q10iU+UueEGebf9+0i9cACai22GWZuEANZCgX25kw++edgH3
# JjkodZizmdgN+MCaDPBS/9g35CQs1PqRsdNDpp64pk3U9DD3sFnC5JvuRfrLC2aE
# W0GZX62eGOHl/3z2XeV6wa1NzfwaLGGOn8+cJpXHoVzec2wEAmSvit9MLNpJbDNh
# hybiP7/5uK+dBpXhEDutRQyhgF+wUXYfgVrnLXRIGVookFvpgip20r9CvZUZL5I/
# lVEFNVL/E8pLKCrVACaY4/XGoCZHF25LFe1BUclv+Irfqc4pegd1rO+tQog3NmCi
# 1UmOY18f/cFyRofxd6f/AnQj1wj9WpQNjVKuH0j6xzG6x65L4N0DRPk2XjndY20U
# 38zfYKEkYPzfu8IdHDn0mBUh8RYrtO3gsapc9OpPpuZSZmrVGiCZSFzQMYqHi4NG
# RE83FmirOvdIB7W5DwrqUyQm57Pj5QD2S8qwLvzKWJpJ4aIi2BeZsusmrR0n8Zbl
# iTKj44sIPllVpjFYOhOof4pzNyPKaw==
# SIG # End signature block
