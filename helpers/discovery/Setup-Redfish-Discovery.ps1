<#
.SYNOPSIS
    Redfish (BMC) Discovery — Inventory server hardware and optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that walks the DMTF Redfish API on a baseboard management
    controller (HPE iLO, Dell iDRAC, Lenovo XCC, Supermicro), builds a monitor plan
    from what the board reports, then lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates device + credential + monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Generate BMC inventory dashboard
      [6] Exit
      [7] Dashboard + Push to WUG

    Architecture (when pushed to WUG):
      [BMC Device in WUG]  +  one REST API credential (basic auth)
          |-- "Redfish - <model> System Health"        (REST API Active Monitor)
          |-- "Redfish - <model> CPU Health"           (REST API Active Monitor)
          |-- "Redfish - <model> Memory Health"        (REST API Active Monitor)
          |-- "Redfish - <model> Chassis Health"       (REST API Active Monitor)
          |-- "Redfish - <model> Power State"          (REST API Active Monitor)
          |-- "Redfish - <model> BMC State"            (REST API Active Monitor)
          |-- "Redfish - <model> PSU n Health"         (REST API Active Monitor)
          |-- "Redfish - <model> Disk n Health"        (REST API Active Monitor)
          |-- "Redfish - <model> Temp <sensor> Health" (REST API Active Monitor)
          |-- "Redfish - <model> Power Consumed (W)"   (REST API Perf Monitor)
          |-- "Redfish - <model> Temp <sensor>"        (REST API Perf Monitor)
          '-- "Redfish - <model> <fan>"                (REST API Perf Monitor)

    Why REST API monitors rather than the native Redfish type:
      WhatsUp Gold ships a Redfish monitor type, but on iLO 4 it resolved only four
      subsystems (system, chassis, temperature, fan). Processors, memory, disks and
      power supplies returned Unknown for every argument format tried, because that
      firmware publishes them as vendor types such as HpMemory and
      HpSmartStorageDiskDrive rather than standard Redfish schema. REST API monitors
      read the JSON directly and cover every component.

    Credentials and URLs:
      Monitors authenticate through a REST API credential assigned to the device, so
      no Authorization header is stored in any monitor definition. URLs use the
      %Device.Address percent variable, so one library monitor serves every BMC of
      the same model. There is no closing percent; %Device.Address% does not expand.

    Depth of inventory:
      By default the whole Redfish service is walked, which reaches components that
      firmware does not link through the standard collections. On an iLO 4 DL360 Gen9
      the walk returns 129 resources against the 30 a conventional traversal finds,
      picking up processors, DIMMs, drives and the array controller.

      The walk costs roughly two minutes per BMC and cannot be parallelised on
      PowerShell 5.1. Use -NoDeepWalk for a shallower scan of the standard
      collections only, which takes about twenty seconds.

    Health monitors vs. performance monitors:
      Health checks are REST API active monitors that compare a JSON value, for
      example reporting down when Status.Health is not "OK". Numeric trends (power
      draw, temperatures, fan speeds) are REST API performance monitors polled every
      ten minutes.

    First Run:
      1. Prompts for BMC address, port, and account (masked input)
      2. Stores the account in the DPAPI vault (encrypted to user + machine)
      3. Walks the Redfish service
      4. Shows summary, then asks what to do with the results

    Subsequent Runs:
      Loads the account from the vault automatically — skips the prompt.

    BMC account requirements:
      Read-only access is enough. On iLO create a user with "Login" privilege;
      on iDRAC a user with "Login to iDRAC" and read access to the system inventory.

.PARAMETER Target
    BMC address(es) — IP address or FQDN. Accepts multiple values.
    When omitted in interactive mode, prompts for input.

.PARAMETER ApiPort
    Redfish HTTPS port. Default: 443.

.PARAMETER NoDeepWalk
    Skip the full service walk and read only the standard collections.
    Faster, but misses components the firmware does not link conventionally.

.PARAMETER WalkMaxResources
    Ceiling on the number of resources the walk fetches per BMC. Default: 400.

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER OutputPath
    Directory for exported JSON/CSV. Defaults to %TEMP% interactively.

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and parameter defaults.
    Ideal for scheduled task execution.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    WhatsUpGoldPS module is only needed if you choose option [1].
    Verified against: HPE ProLiant DL360 Gen9, iLO 4 v2.82, Redfish 1.0.0

.EXAMPLE
    .\Setup-Redfish-Discovery.ps1
    # Interactive mode — prompts for everything.

.EXAMPLE
    .\Setup-Redfish-Discovery.ps1 -Target '192.168.1.99' -Action ShowTable
    # Full walk, show the plan, change nothing.

.EXAMPLE
    .\Setup-Redfish-Discovery.ps1 -Target '10.0.0.10','10.0.0.11' -NoDeepWalk -Action PushToWUG -NonInteractive
    # Fast shallow scan of two BMCs, pushed to WUG with no prompts.

.LINK
    https://www.dmtf.org/standards/redfish
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [int]$ApiPort = 443,

    [switch]$NoDeepWalk,

    [int]$WalkMaxResources = 400,

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
    }
    else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Redfish.ps1')
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# BMCs almost always present a self-signed certificate.
if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}
if (-not ([System.Management.Automation.PSTypeName]'RedfishCertPolicy').Type) {
    Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class RedfishCertPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object RedfishCertPolicy

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Redfish (BMC) Discovery ===" -ForegroundColor Cyan
Write-Host ""

if ($Target) {
    $BmcHosts = @($Target)
}
elseif ($NonInteractive) {
    Write-Error 'No target supplied. Pass -Target when running non-interactively.'
    return
}
else {
    Write-Host "Enter BMC address(es) — IP address or FQDN (iLO, iDRAC, XCC)." -ForegroundColor Cyan
    Write-Host "For multiple BMCs, separate with commas." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt 'BMC address(es)'
    $BmcHosts = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($BmcHosts.Count -eq 0) {
    Write-Error 'No valid BMC address provided. Exiting.'
    return
}
Write-Host "Targets: $($BmcHosts -join ', ')" -ForegroundColor Cyan

if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt "Redfish port [default: $ApiPort]"
    if ($portInput -and $portInput -match '^\d+$') { $ApiPort = [int]$portInput }
}

# --- Walk depth ----------------------------------------------------------------
$deepWalk = -not $NoDeepWalk
if (-not $PSBoundParameters.ContainsKey('NoDeepWalk') -and -not $NonInteractive) {
    Write-Host ""
    Write-Host "Inventory depth:" -ForegroundColor Cyan
    Write-Host "  [1] Deep walk — every reachable resource (~2 min per BMC, finds CPUs/DIMMs/drives)" -ForegroundColor White
    Write-Host "  [2] Shallow   — standard collections only (~20 sec per BMC)" -ForegroundColor White
    Write-Host ""
    $depthChoice = Read-Host -Prompt 'Choice [1/2, default: 1]'
    if ($depthChoice -eq '2') { $deepWalk = $false }
}
Write-Host ("Inventory depth: {0}" -f $(if ($deepWalk) { 'deep walk' } else { 'shallow' })) -ForegroundColor Gray

# ==============================================================================
# STEP 2: Authentication (BMC account, vault-backed)
# ==============================================================================
$vaultName = "Redfish.$($BmcHosts[0]).Credential"
$credSplat = @{ Name = $vaultName; CredType = 'PSCredential'; ProviderLabel = 'Redfish' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }

$BmcCredential = Resolve-DiscoveryCredential @credSplat
if (-not $BmcCredential) {
    Write-Error 'No Redfish credentials available. Exiting.'
    return
}
Write-Host "Using BMC account '$($BmcCredential.UserName)'." -ForegroundColor Green

# ==============================================================================
# STEP 3: Discover — walk the Redfish service
# ==============================================================================
Write-Host ""
if ($deepWalk) {
    Write-Host "Walking Redfish on $($BmcHosts -join ', ') — this takes about two minutes per BMC..." -ForegroundColor Cyan
}
else {
    Write-Host "Reading Redfish collections on $($BmcHosts -join ', ')..." -ForegroundColor Cyan
}

$discoveryOptions = @{ WalkMaxResources = $WalkMaxResources }
if (-not $deepWalk) { $discoveryOptions['NoDeepWalk'] = $true }

$plan = Invoke-Discovery -ProviderName 'Redfish' `
    -Target $BmcHosts `
    -ApiPort $ApiPort `
    -Credential @{ PSCredential = $BmcCredential } `
    -Options $discoveryOptions

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check BMC reachability, the account, and that Redfish is enabled."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

# One WUG device per BMC.
$devicePlan = [ordered]@{}
foreach ($item in $plan) {
    $key = "bmc:$($item.DeviceIP)"
    if (-not $devicePlan.Contains($key)) {
        $attrs = $item.Attributes
        $model = if ($attrs['Redfish.Model']) { $attrs['Redfish.Model'] } else { 'Server' }
        $mgrName = $attrs['Redfish.ManagerHostName']
        $devicePlan[$key] = @{
            Name   = if ($mgrName) { $mgrName } else { $item.DeviceIP }
            IP     = $item.DeviceIP
            Model  = $model
            Vendor = if ($attrs['Redfish.Manufacturer']) { $attrs['Redfish.Manufacturer'] } else { [string]$attrs['Redfish.Vendor'] }
            Attrs  = $attrs
            Items  = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)
$perfTemplates = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } | Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  BMCs discovered:           $($devicePlan.Count)" -ForegroundColor White
Write-Host "  Active monitor templates:  $($activeTemplates.Count)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

# Per-device summary, including anything the BMC reported as unhealthy.
$devicePlan.Values | Sort-Object @{E = { $_.Name } } | ForEach-Object {
    [PSCustomObject]@{
        BMC       = $_.IP
        Host      = $_.Name
        Model     = $_.Model
        CPUs      = $_.Attrs['Redfish.CpuCount']
        DIMMs     = $_.Attrs['Redfish.DimmCount']
        Drives    = $_.Attrs['Redfish.DriveCount']
        Health    = $_.Attrs['Redfish.SystemHealth']
        Monitors  = $_.Items.Count
        Resources = $_.Attrs['Redfish.WalkResourceCount']
    }
} | Format-Table -AutoSize

foreach ($dev in $devicePlan.Values) {
    $bad = $dev.Attrs['Redfish.Unhealthy']
    if ($bad) {
        Write-Host "  $($dev.Name) reports unhealthy components: $bad" -ForegroundColor Yellow
    }
}

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================
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
if (-not $choice -and $NonInteractive) { $choice = '6' }

if (-not $choice) {
    Write-Host ""
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push monitors to WhatsUp Gold (creates device + credential + monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate BMC inventory dashboard"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host "  [7] Dashboard + Push to WUG"
    Write-Host ""
    $choice = Read-Host -Prompt 'Choice [1-7]'
}

$actionsToRun = if ($choice -eq '7') { @('5', '1') } else { @($choice) }

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
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if ($WUGCredential) { Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential }
        else { Connect-WUGDiscoveryServer }

        $stats = @{
            HealthCreated  = 0; HealthSkipped = 0; HealthFailed = 0
            PerfCreated    = 0; PerfSkipped = 0; PerfFailed = 0
            DevicesCreated = 0; DevicesFound = 0
            CredsAssigned  = 0
        }
        $wugDeviceMap = @{}
        $deviceKeys = @($devicePlan.Keys | Sort-Object)

        # ---- 1. Create/find the REST API credential ------------------------
        # Basic auth held in a credential, so no Authorization header is stored in
        # any monitor definition.
        Write-Host ""
        Write-Host "Setting up REST API credential in WUG..." -ForegroundColor Cyan

        $credName = "Redfish REST - $($BmcCredential.UserName)"
        $redfishCredId = $null

        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName -View basic)
            if ($existingCreds.Count -eq 0) {
                $existingCreds = @(Get-WUGCredential -SearchValue $credName -View basic)
            }
            $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
            if ($matchCred) {
                $redfishCredId = $matchCred.id
                Write-Host "  Found existing credential '$credName' (ID: $redfishCredId)" -ForegroundColor Green
            }
        }
        catch { Write-Verbose "Credential search error: $_" }

        if (-not $redfishCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                # AuthType 0 is basic auth; 1 would switch the credential to OAuth2.
                $credResult = Add-WUGCredential -Name $credName `
                    -Description 'Redfish BMC basic auth (auto-created by discovery)' `
                    -Type restapi `
                    -RestApiUsername $BmcCredential.UserName `
                    -RestApiPassword $BmcCredential.GetNetworkCredential().Password `
                    -RestApiAuthType '0' `
                    -RestApiIgnoreCertErrors 'True'
                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) { $redfishCredId = $credResult.data.idMap.resultId }
                    elseif ($credResult.PSObject.Properties['resourceId']) { $redfishCredId = $credResult.resourceId }
                    elseif ($credResult.PSObject.Properties['id']) { $redfishCredId = $credResult.id }
                }
            }
            catch { Write-Verbose "Credential creation failed: $_" }

            if (-not $redfishCredId) {
                try {
                    $recheck = @(Get-WUGCredential -SearchValue $credName -View basic)
                    $match = $recheck | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                    if ($match) { $redfishCredId = $match.id }
                }
                catch { Write-Warning "  Credential re-check failed for '$credName': $($_.Exception.Message)" }
            }

            if ($redfishCredId) {
                Write-Host "  Created credential (ID: $redfishCredId)" -ForegroundColor Green
            }
            else {
                Write-Warning "Could not create the REST API credential via API."
                Write-Warning "Create it manually in WUG: Credentials Library -> Add -> REST API"
                Write-Warning "  Name: $credName | Auth: Basic | Username: $($BmcCredential.UserName)"
                Write-Warning "Monitors will report Down without it, because they carry no Authorization header."
            }
        }

        # ---- 2. Create active monitors in library (bulk) -------------------
        Write-Host ""
        Write-Host "  Creating active monitors in library..." -ForegroundColor Cyan

        $uniqueActiveMonitors = @{}
        foreach ($key in $deviceKeys) {
            foreach ($actItem in @($devicePlan[$key].Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                $actName = $actItem.Name
                if (-not $actName -or $uniqueActiveMonitors.ContainsKey($actName)) { continue }
                $uniqueActiveMonitors[$actName] = $actItem
            }
        }

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
            Write-Host "    Creating $($toCreateActive.Count) new active monitors (bulk)..." -ForegroundColor DarkGray

            $activeTemplateArr = @()
            $actTplIdMap = @{}
            $actTplIdx = 0
            foreach ($actName in $toCreateActive) {
                $actItem = $uniqueActiveMonitors[$actName]
                $mp = $actItem.MonitorParams
                $tplId = "act_$actTplIdx"
                $actTplIdMap[$tplId] = $actName
                $actTplIdx++

                if ($actItem.MonitorType -eq 'Redfish') {
                    Write-Warning "Skipping '$actName': the native Redfish monitor type is no longer used."
                    continue
                }

                $bags = @(
                    @{ name = 'MonRestApi:RestUrl'; value = "$($mp.RestApiUrl)" }
                    @{ name = 'MonRestApi:HttpMethod'; value = if ($mp.RestApiMethod) { "$($mp.RestApiMethod)" } else { 'GET' } }
                    @{ name = 'MonRestApi:HttpTimeoutMs'; value = if ($mp.RestApiTimeoutMs) { "$($mp.RestApiTimeoutMs)" } else { '30000' } }
                    @{ name = 'MonRestApi:IgnoreCertErrors'; value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '1' } }
                    @{ name = 'MonRestApi:UseAnonymousAccess'; value = if ($null -ne $mp.RestApiUseAnonymous) { "$($mp.RestApiUseAnonymous)" } else { '0' } }
                    @{ name = 'MonRestApi:CustomHeader'; value = if ($mp.RestApiCustomHeader) { "$($mp.RestApiCustomHeader)" } else { '' } }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn'; value = if ($mp.RestApiDownIfResponseCodeIsIn) { "$($mp.RestApiDownIfResponseCodeIsIn)" } else { '[]' } }
                    @{ name = 'MonRestApi:ComparisonList'; value = if ($mp.RestApiComparisonList) { "$($mp.RestApiComparisonList)" } else { '[]' } }
                    @{ name = 'Cred:Type'; value = '8192' }
                )

                $activeTemplateArr += @{
                    templateId      = $tplId
                    name            = $actName
                    description     = 'Redfish RestApi active monitor'
                    useInDiscovery  = $false
                    monitorTypeInfo = @{
                        baseType = 'active'
                        classId  = 'f0610672-d515-4268-bd21-ac5ebb1476ff'
                    }
                    propertyBags    = $bags
                }
            }

            try {
                $batchSize = 50
                for ($bi = 0; $bi -lt $activeTemplateArr.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $activeTemplateArr.Count - 1)
                    $actBatch = @($activeTemplateArr[$bi..$batchEnd])

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
                            $errName = if ($actTplIdMap.ContainsKey($err.templateId)) { $actTplIdMap[$err.templateId] } else { $err.templateId }
                            Write-Warning "Active monitor create error for '$errName': $($err.messages -join '; ')"
                            $stats.HealthFailed++
                        }
                    }
                    if ($batchEnd -lt $activeTemplateArr.Count - 1) { Start-Sleep -Seconds 2 }
                }
            }
            catch {
                Write-Warning "Bulk active monitor creation failed, falling back to one-at-a-time: $_"
                foreach ($actName in $toCreateActive) {
                    if ($existingActiveNames.ContainsKey($actName)) { continue }
                    $actItem = $uniqueActiveMonitors[$actName]
                    try {
                        $actParams = @{ Type = $actItem.MonitorType; Name = $actName; ErrorAction = 'Stop' }
                        foreach ($ak in $actItem.MonitorParams.Keys) {
                            if ($ak -ne 'Name' -and $ak -ne 'Description' -and $ak -ne 'UseInDiscovery') {
                                $actParams[$ak] = $actItem.MonitorParams[$ak]
                            }
                        }
                        $monLibId = Add-WUGActiveMonitor @actParams
                        if ($monLibId) { $existingActiveNames[$actName] = [int]$monLibId; $stats.HealthCreated++ }
                    }
                    catch { Write-Warning "Failed to create active monitor '$actName': $_"; $stats.HealthFailed++ }
                }
            }
        }
        Write-Host "    Active monitors: $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor DarkGray

        $missingAct = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        if ($missingAct.Count -gt 0) {
            try {
                $activeLibrary = Get-WUGMonitorLibraryMap -Type active
                $reconciledAct = 0
                foreach ($actName in $missingAct) {
                    if ($activeLibrary.ContainsKey($actName)) {
                        $existingActiveNames[$actName] = [int]$activeLibrary[$actName]
                        $reconciledAct++
                    }
                }
                if ($reconciledAct -gt 0) { Write-Host "    Reconciled $reconciledAct active monitors from library" -ForegroundColor DarkGray }
            }
            catch { Write-Warning "    Could not re-read the active monitor library: $($_.Exception.Message)." }
        }

        # ---- 3. Create perf monitors in library (bulk) ---------------------
        Write-Host "  Creating performance monitors in library..." -ForegroundColor Cyan

        $uniquePerfMonitors = @{}
        foreach ($key in $deviceKeys) {
            foreach ($perfItem in @($devicePlan[$key].Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                $monName = $perfItem.Name
                if (-not $monName -or $uniquePerfMonitors.ContainsKey($monName)) { continue }
                $uniquePerfMonitors[$monName] = $perfItem
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
            Write-Host "    Creating $($toCreatePerf.Count) new perf monitors (bulk)..." -ForegroundColor DarkGray

            $perfTemplateArr = @()
            $perfTplIdMap = @{}
            $perfTplIdx = 0
            foreach ($monName in $toCreatePerf) {
                $perfItem = $uniquePerfMonitors[$monName]
                $mp = $perfItem.MonitorParams
                $tplId = "perf_$perfTplIdx"
                $perfTplIdMap[$tplId] = $monName
                $perfTplIdx++

                $perfTemplateArr += @{
                    templateId      = $tplId
                    name            = $monName
                    description     = 'Redfish RestApi performance monitor'
                    monitorTypeInfo = @{
                        baseType = 'performance'
                        classId  = '987bb6a4-70f4-4f46-97c6-1c9dd1766437'
                    }
                    propertyBags    = @(
                        @{ name = 'RdcRestApi:RestUrl'; value = "$($mp.RestApiUrl)" }
                        @{ name = 'RdcRestApi:JsonPath'; value = "$($mp.RestApiJsonPath)" }
                        @{ name = 'RdcRestApi:HttpMethod'; value = if ($mp.RestApiHttpMethod) { "$($mp.RestApiHttpMethod)" } else { 'GET' } }
                        @{ name = 'RdcRestApi:HttpTimeoutMs'; value = if ($mp.RestApiHttpTimeoutMs) { "$($mp.RestApiHttpTimeoutMs)" } else { '30000' } }
                        @{ name = 'RdcRestApi:IgnoreCertErrors'; value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '1' } }
                        @{ name = 'RdcRestApi:UseAnonymousAccess'; value = if ($null -ne $mp.RestApiUseAnonymousAccess) { "$($mp.RestApiUseAnonymousAccess)" } else { '0' } }
                        @{ name = 'RdcRestApi:CustomHeader'; value = if ($mp.RestApiCustomHeader) { "$($mp.RestApiCustomHeader)" } else { '' } }
                        @{ name = 'Cred:Type'; value = '8192' }
                    )
                }
            }

            try {
                $batchSize = 50
                for ($bi = 0; $bi -lt $perfTemplateArr.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $perfTemplateArr.Count - 1)
                    $perfBatch = @($perfTemplateArr[$bi..$batchEnd])

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
                            $errName = if ($perfTplIdMap.ContainsKey($err.templateId)) { $perfTplIdMap[$err.templateId] } else { $err.templateId }
                            Write-Warning "Perf monitor create error for '$errName': $($err.messages -join '; ')"
                            $stats.PerfFailed++
                        }
                    }
                    if ($batchEnd -lt $perfTemplateArr.Count - 1) { Start-Sleep -Seconds 2 }
                }
            }
            catch {
                Write-Warning "Bulk perf monitor creation failed: $_"
                $stats.PerfFailed += $toCreatePerf.Count
            }
        }
        Write-Host "    Perf monitors: $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor DarkGray

        $missingPerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        if ($missingPerf.Count -gt 0) {
            try {
                $perfLibrary = Get-WUGMonitorLibraryMap -Type performance
                $reconciledPerf = 0
                foreach ($monName in $missingPerf) {
                    if ($perfLibrary.ContainsKey($monName)) {
                        $existingPerfNames[$monName] = "$($perfLibrary[$monName])"
                        $reconciledPerf++
                    }
                }
                if ($reconciledPerf -gt 0) { Write-Host "    Reconciled $reconciledPerf perf monitors from library" -ForegroundColor DarkGray }
            }
            catch { Write-Warning "    Could not re-read the performance monitor library: $($_.Exception.Message)." }
        }

        # ---- 4. Identify existing vs new devices ---------------------------
        Write-Host "  Checking for existing devices..." -ForegroundColor Cyan
        $existingDevices = @{}
        $newDeviceKeys = [System.Collections.Generic.List[string]]::new()

        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            # Devices are created as "<name> (BMC)", so a rerun must match that too.
            $match = Find-WUGDiscoveryDeviceMatch -Name $dev.Name -Address $dev.IP -AlternateName "$($dev.Name) (BMC)"
            if ($match.Found) {
                $existingDevices[$key] = $match.Device.id
                $wugDeviceMap[$key] = $match.Device.id
                $stats.DevicesFound++
            }
            elseif ($match.LookupFailed) {
                Write-Warning "  Could not check whether '$($dev.Name)' exists: $($match.Error). Skipping to avoid creating a duplicate."
            }
            else {
                $newDeviceKeys.Add($key)
            }
        }
        Write-Host "    Found $($stats.DevicesFound) existing, $($newDeviceKeys.Count) new to create" -ForegroundColor DarkGray

        # ---- 5. Create new devices -----------------------------------------
        if ($newDeviceKeys.Count -gt 0) {
            Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow

            foreach ($key in $newDeviceKeys) {
                $dev = $devicePlan[$key]
                $displayName = "$($dev.Name) (BMC)"

                $devAttrs = @()
                foreach ($attrName in $dev.Attrs.Keys) {
                    $attrVal = $dev.Attrs[$attrName]
                    if ($attrVal) { $devAttrs += @{ name = $attrName; value = "$attrVal" } }
                }

                $actNames = @()
                $seenActNames = @{}
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name) -and -not $seenActNames.ContainsKey($actItem.Name)) {
                        $actNames += $actItem.Name
                        $seenActNames[$actItem.Name] = $true
                    }
                }

                $perfNames = @()
                $seenPerfNames = @{}
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name) -and -not $seenPerfNames.ContainsKey($perfItem.Name)) {
                        $perfNames += $perfItem.Name
                        $seenPerfNames[$perfItem.Name] = $true
                    }
                }

                if ($actNames.Count -eq 0 -and $perfNames.Count -eq 0) {
                    Write-Warning "Skipping '$displayName' — no monitors resolved in the library."
                    continue
                }

                $splat = @{
                    displayName            = $displayName
                    DeviceAddress          = $dev.IP
                    Hostname               = $dev.Name
                    Brand                  = if ($dev.Vendor) { "$($dev.Vendor)" } else { 'Redfish' }
                    Note                   = "Redfish BMC — $($dev.Model) (auto-created by discovery)"
                    NoDefaultActiveMonitor = $true
                }
                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($redfishCredId) { $splat['CredentialRestApi'] = $credName }
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
                            Write-Host "    Created '$displayName' (ID: $newDeviceId)" -ForegroundColor Green
                        }
                        else {
                            Write-Warning "Device '$displayName' — API returned success but no device ID."
                        }
                    }
                    else {
                        $errMsgs = @()
                        if ($devResult -is [array]) {
                            foreach ($e in $devResult) {
                                if ($e.PSObject.Properties['messages']) { $errMsgs += ($e.messages -join '; ') }
                            }
                        }
                        elseif ($devResult -and $devResult.PSObject.Properties['messages']) {
                            $errMsgs += ($devResult.messages -join '; ')
                        }
                        $errText = if ($errMsgs.Count -gt 0) { $errMsgs -join ' | ' } else { 'Unknown error (no details returned)' }
                        Write-Warning "Failed to create device '$displayName': $errText"
                    }
                }
                catch { Write-Warning "Error creating device '$displayName': $_" }
            }
        }

        # ---- 6. Update existing devices (creds + monitors) -----------------
        if ($existingDevices.Count -gt 0) {
            Write-Host "  Updating $($existingDevices.Count) existing devices (credentials + monitors)..." -ForegroundColor Cyan

            foreach ($key in $existingDevices.Keys) {
                $deviceId = [int]$existingDevices[$key]
                $dev = $devicePlan[$key]

                if ($redfishCredId) {
                    try {
                        $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $redfishCredId -Assign
                        $stats.CredsAssigned++
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Credential assign error for device $deviceId`: $_"
                        }
                    }
                }

                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) {
                        $actMonitorIds += $existingActiveNames[$actItem.Name]
                    }
                }
                if ($actMonitorIds.Count -gt 0) {
                    try { Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $actMonitorIds -ErrorAction Stop }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Active monitor assign error for device $deviceId`: $_"
                        }
                    }
                }

                $perfMonitorIds = @()
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name)) {
                        $perfMonitorIds += [int]$existingPerfNames[$perfItem.Name]
                    }
                }
                if ($perfMonitorIds.Count -gt 0) {
                    try { Add-WUGPerformanceMonitorToDevice -DeviceId $deviceId -MonitorId $perfMonitorIds -PollingIntervalMinutes 10 -ErrorAction Stop }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Perf monitor assign error for device $deviceId`: $_"
                        }
                    }
                }
            }
        }

        # Group membership only; no rescan is queued, so existing monitoring is untouched.
        $redfishGroupName = 'Redfish-WhatsUpGoldPS'
        $allRedfishDeviceIds = @($wugDeviceMap.Values | Select-Object -Unique | ForEach-Object { [int]$_ })
        if ($allRedfishDeviceIds.Count -gt 0) {
            $redfishGroup = Sync-WUGDiscoveryDeviceGroup -Name $redfishGroupName -DeviceId $allRedfishDeviceIds `
                -Description 'Devices managed by WhatsUpGoldPS Redfish discovery.' -Confirm:$false
            if ($redfishGroup.GroupId) {
                Write-Host "  Group '$redfishGroupName' (ID: $($redfishGroup.GroupId)): added $($redfishGroup.Added) device(s)." -ForegroundColor Gray
            }
        }

        # ---- Summary -------------------------------------------------------
        Write-Host ""
        Write-Host "Push complete!" -ForegroundColor Green
        Write-Host "  Active monitors:  $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor White
        Write-Host "  Perf monitors:    $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor White
        Write-Host "  Devices:          $($stats.DevicesCreated) created, $($stats.DevicesFound) existing" -ForegroundColor White
        Write-Host "  Creds assigned:   $($stats.CredsAssigned)" -ForegroundColor White
        Write-Host ""
        Write-Host "Monitors authenticate through the REST API credential on the device;" -ForegroundColor Gray
        Write-Host "no Authorization header is stored in any monitor definition." -ForegroundColor Gray
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'redfish-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'redfish-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) {
            Write-Warning 'Dashboard generator not available; skipping the Redfish dashboard.'
        }
        else {
            $dashRows = @($devicePlan.Values | Sort-Object @{E = { $_.Name } } | ForEach-Object {
                [PSCustomObject]@{
                    BMC       = $_.IP
                    Host      = $_.Name
                    Vendor    = $_.Vendor
                    Model     = $_.Model
                    Health    = $_.Attrs['Redfish.SystemHealth']
                    Unhealthy = $_.Attrs['Redfish.Unhealthy']
                    CPUs      = $_.Attrs['Redfish.CpuCount']
                    DIMMs     = $_.Attrs['Redfish.DimmCount']
                    Drives    = $_.Attrs['Redfish.DriveCount']
                    Monitors  = $_.Items.Count
                    Resources = $_.Attrs['Redfish.WalkResourceCount']
                }
            })
            $dashPath = Join-Path $OutputDir 'Redfish-Dashboard.html'
            Export-DynamicDashboardHtml -Data $dashRows -OutputPath $dashPath `
                -ReportTitle 'Redfish BMC Inventory' -CardField Vendor, Model, Health -StatusField Health `
                -ExportPrefix 'redfish_inventory' | Out-Null
            Write-Host "Dashboard generated: $dashPath" -ForegroundColor Green
        }
    }
    '6' {
        Write-Host "Nothing changed." -ForegroundColor Gray
    }
    default {
        Write-Host "Unrecognised choice '$currentChoice'. Nothing changed." -ForegroundColor Yellow
    }
}
} # end foreach actionsToRun

# ---- END OF SCRIPT (do not remove this line)

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAmaW4TxRWIoiXG
# emINFWtxQ71lKzj795a2gLZfKCc2PaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCA5PyJ+6mspwfREoDURM3e86oYoJRyKy92C7OTMNDfAGjANBgkqhkiG9w0BAQEF
# AASCAgDg/NbWvOdFufccaRXNynthuDVV7Bv3v080DuZb3w17q02BODwHNk/dZnoV
# uglSTcb54uul2oS5XqHyxy1tCXEcF0afNNs8o4NcVuC8QRlvDyJhKoV4W1r5tUqJ
# 7y8h64nMZ30Hq0h9CTHvHDRYgf4zPlhoNpAL3NutgY6r7E0jQC/PEHiCAUC29NEk
# 8CBxKNZuoLFXzPpJ0GCE49v44Pelkr4RdtS4TvSpatpofMz5KewyRD86xEbWANiN
# 5QbVgRKZsg/JbUi7T4iewH88CfCfVufp55aYFGc0HjVakiFYmUQvjx5W3KKN29th
# E/PAr6y09vQ0gBTP0icK298pyKCBE2EOOALpuJKMYKDo2HAnyrpMBlFoTx0YymcN
# KBbXHi2/Q2MPEMfGZL4RIBMJarzalRJn9QDRlvC4dQlbYMPpoiaQzgLghHL6t+8v
# RC5kjeNVccB2pL1XYf9pncF+x3aMpSLR0gVYw81uNBrqBs+cEh/dRcRH13IBGDID
# 0L1BtjXn0mAaGDzwELgsENhoHEMT/kEmtyyF7fAhTbIs+AqnjEApKggZeynxEv5p
# 8VaJ+RKqv5NcKzyRvdKVss3u7my/03EnUDCrgUqo3Fqf5FPgFlbZa5QwYV52HPbI
# xlxC8AuEGRR3Aj9OOb7hJN2il7q6U2Y4SQU01zzhhHK6nzNBxqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MzAyMjI0NDlaMC8GCSqGSIb3DQEJBDEiBCC1IgqI
# N4JXxCXp3/O+e6e5oMFBYwHFv9GaXjk5Cn13bjANBgkqhkiG9w0BAQEFAASCAgB1
# ya1GmOcNn93tv2Uzyrp+9iuMdnZAx5WyosDR26I+yjKtKIMzpm7XHxK34xKeXv3b
# +x7TO37Oiv356HGCqIEbK8A1d9/hF4aXjzlto130GPFJjwXJCrwoclQMaIu6M6To
# RDaRaps8M5n76f0qfwYPZDlFVSzFzAfa4nGO3av7FRoFEaCdgGOXE/5VA9lhguVU
# DneNXksA632e3LyTRG1D0DwbI7vLJfLy74IJBoH3blhjVQbi/JJOizHMCWPoUE1H
# evG8l+bqgx2BbyeOAc67XlKmt+x6OQ/64iRQjDlKFxZatbAYvFbZIiZ+Fk43Sqmj
# /oDX1sd/KQEfwbLaqeHf7WhJmhfd27iWrui9VO0lfc/mSBqk+DU5zqpmrsdniBXK
# VMTHDy7t2g0aK1og2I4cOyizE5WhFHMBxylSl8zVXL6+nOQbQEGUNqFBdrB3CJrK
# jJPqEZCtXraHWT4uodeSslrOtKhxBnYdxWF1z1UF6wzfe93DzubtlEqyKqFMEOaR
# MhaB26vh0fv5R42tY4kBvypbF9+/peFXSh81RQwIumNI4WuVfo0O+Y467lqESlgJ
# 5hEKXkiBGsOdYv2WuHpq2fOAp8ADxv4onP81AhAs6bVBM1bFksNVC7Pu9l2COiVm
# QX/Ed2BNZGgOfIHT8wK+LvQjjF8ZqaDPRGRs/bdJdw==
# SIG # End signature block
