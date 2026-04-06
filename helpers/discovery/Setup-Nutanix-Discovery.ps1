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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
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
        if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('WUGServer')) {
            $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
            if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) { $WUGServer = $wugInput.Trim() }
        }

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

        # Resolve WUG credentials
        $wugVaultName = "WUG.$WUGServer"
        if ($WUGCredential) { $wugCred = $WUGCredential }
        else {
            $wugSplat = @{ Name = $wugVaultName; CredType = 'WUGServer' }
            if ($NonInteractive) { $wugSplat.NonInteractive = $true }
            else { $wugSplat.AutoUse = $true }
            $wugResolved = Resolve-DiscoveryCredential @wugSplat
            if (-not $wugResolved) { Write-Error 'WUG credential resolution failed.'; return }
            $wugCred = $wugResolved.Credential
            if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
        }
        Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors

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
                $wugDashPath = Join-Path $nmConsolePath 'Nutanix-Dashboard.html'
                try {
                    Copy-Item -Path $dashPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/Nutanix-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                }
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCifCOr9aB0UTwR
# H61kaYTHUSH6Cy5cEDR30Tc8YnMdUqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgCMVuDRNLGqdOmTRWm1oIzgaHs15LQnSC
# wkCL2/tu7sUwDQYJKoZIhvcNAQEBBQAEggIAfXYHpATJEZl4fIYxaXXZ+WITDszi
# UKf9Iz4uJgXnBY4OyaciFp2ID1t/IM4/gZk9/euhczrxCyBa9oqtLj6SnBHLAWHk
# vqjXi6zK7Ffau33TvI4mRImvURd8Y9FgkDJaV8fFIrY3j2aYOpBMu0mVaOc+1ljN
# pzmoxSBG3WflXLYO5EEUBLTuOiNW7mUOagMiKqV/Obo5w8ktoE/NqV0Vrl0QIRCJ
# XYBtTJdtrJHNciW6man6kLK/o2oZm6IyVrrfbmAcyp9/oaO1rnUw1ME3FXVw1OYy
# TM3LDSVfI9lX+6pVMIpzBXpLSAOr8iomX509o3BemQg9Ad5UQuvOQNm8V3EoVXMf
# uqAsWAYV/v3UINXlabaClRPzSEXa4lBbdx17ojlLr1AtZhJ3tRThYvVzyLQ5+pBd
# CAK/gj5dBBSbtQi+eC34F/Q16WMraNWuSvhKg3AeA0zKrbenUq1hE1rKBktblVVy
# RhxigwnO/Ol9IrQ15c0fEyz4syyko1b8JTsoyAEUqGgfwhN0WlYXnWpQPPdeYTmE
# Ny4oK1frOAsAo4gzsGO++2T/E2NPsrIDMMZepdKrzKHSBd9pjN/dX3SHjYO9vMGz
# xK2NdjhsEnuvoUoKqqIMU0KBbJ1XmGHGZAv/wXn+SHcesBF+e3JhBev60WL6RgAv
# qQ16JPu58AKPhXc=
# SIG # End signature block
