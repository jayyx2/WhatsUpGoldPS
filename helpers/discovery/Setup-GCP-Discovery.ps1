<#
.SYNOPSIS
    GCP Discovery -- Discover Google Cloud VMs, Cloud SQL, and load balancers,
    then optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers Google Cloud Platform infrastructure via
    the Compute Engine, Cloud SQL, and forwarding rules APIs, then lets you
    choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + REST API monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Exit

    Architecture (when pushed to WUG):
      [GCP VM device in WUG]
          |-- "GCP VM Health - <vmName>"       (REST API Active Monitor)
          '-- ...
      [Cloud SQL device in WUG]
          |-- "GCP Cloud SQL Health - <name>"  (REST API Active Monitor)
          '-- ...
      [Load Balancer device in WUG]
          |-- "GCP LB Health - <name>"         (REST API Active Monitor)
          '-- ...

    First Run:
      1. Prompts for GCP project ID (or discovers via gcloud)
      2. Prompts for service account key file path
      3. Stores key file path in DPAPI vault (encrypted)
      4. Activates service account and discovers resources
      5. Shows summary, then asks what to do

    Subsequent Runs:
      Loads service account key path from vault and re-authenticates.

    Prerequisites:
      1. gcloud CLI installed and in PATH
      2. Service account JSON key with Compute Viewer + Monitoring Viewer roles

.PARAMETER Target
    GCP project ID(s). Accepts multiple values.
    When omitted in interactive mode, prompts for input.

.PARAMETER KeyFilePath
    Path to GCP service account JSON key file.
    When omitted, uses vault-cached path or prompts.

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
    Requires gcloud CLI for authentication.
    GCP OAuth2 tokens expire after 1 hour.

.EXAMPLE
    .\Setup-GCP-Discovery.ps1
    # Interactive mode.

.EXAMPLE
    .\Setup-GCP-Discovery.ps1 -Target 'my-project-123' -KeyFilePath 'C:\keys\sa.json' -Action PushToWUG -NonInteractive
    # Scheduled mode.

.EXAMPLE
    .\Setup-GCP-Discovery.ps1 -Target 'project-a','project-b' -Action ExportJSON
    # Discover multiple projects and export.
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [string]$KeyFilePath,

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

# --- Load helpers -------------------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-GCP.ps1')

# Load dynamic dashboard generator
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== GCP Discovery ===" -ForegroundColor Cyan
Write-Host ""

# Verify gcloud is available
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Error "gcloud CLI not found in PATH. Install it from https://cloud.google.com/sdk/docs/install"
    return
}

if ($Target) {
    $GCPProjects = @($Target)
}
elseif ($NonInteractive) {
    # Try to get current project from gcloud
    try {
        $currentProject = & gcloud config get-value project 2>$null
        if ($currentProject) { $GCPProjects = @($currentProject) }
        else { Write-Error 'No GCP project specified and gcloud has no default project.'; return }
    }
    catch { Write-Error 'Could not determine GCP project.'; return }
}
else {
    $currentProject = $null
    try { $currentProject = & gcloud config get-value project 2>$null } catch { }
    $defaultPrompt = if ($currentProject) { $currentProject } else { 'my-project-id' }
    Write-Host "Enter GCP project ID(s)." -ForegroundColor Cyan
    Write-Host "For multiple projects, separate with commas." -ForegroundColor Gray
    $projInput = Read-Host -Prompt "GCP project(s) [default: $defaultPrompt]"
    if ([string]::IsNullOrWhiteSpace($projInput)) { $projInput = $defaultPrompt }
    $GCPProjects = @($projInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($GCPProjects.Count -eq 0) { Write-Error 'No valid project provided.'; return }
Write-Host "Projects: $($GCPProjects -join ', ')" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 2: Authentication (service account key file)
# ==============================================================================
$vaultName = "GCP.ServiceAccount"

# Resolve key file path
if (-not $KeyFilePath) {
    $credSplat = @{ Name = $vaultName; CredType = 'FilePath'; ProviderLabel = 'GCP Service Account Key' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    elseif ($Action) { $credSplat.AutoUse = $true }
    $resolvedKeyFile = Resolve-DiscoveryCredential @credSplat
    if ($resolvedKeyFile) {
        $KeyFilePath = $resolvedKeyFile
    }
}

if (-not $KeyFilePath -and -not $NonInteractive) {
    $KeyFilePath = Read-Host -Prompt "Path to service account JSON key file"
}

if (-not $KeyFilePath -or -not (Test-Path $KeyFilePath)) {
    Write-Error "Service account key file not found: $KeyFilePath"
    return
}

# Authenticate with gcloud
Write-Host "Activating GCP service account..." -ForegroundColor Cyan
try {
    $null = & gcloud auth activate-service-account --key-file="$KeyFilePath" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gcloud activation failed" }
}
catch {
    Write-Error "GCP service account activation failed: $_"
    return
}

# Get access token
$gcpToken = $null
try {
    $gcpToken = & gcloud auth print-access-token 2>$null
    if (-not $gcpToken) { throw "No token returned" }
}
catch {
    Write-Error "Could not obtain GCP access token: $_"
    return
}

Write-Host "GCP authentication successful." -ForegroundColor Green
Write-Host ""

# ==============================================================================
# STEP 3: Discover -- query GCP APIs for each project
# ==============================================================================
Write-Host "Querying GCP projects: $($GCPProjects -join ', ')..." -ForegroundColor Cyan

$allPlan = @()
foreach ($proj in $GCPProjects) {
    $gcpCredential = @{
        AccessToken = $gcpToken
        Project     = $proj
    }

    $projPlan = Invoke-Discovery -ProviderName 'GCP' `
        -Target $proj `
        -Credential $gcpCredential

    if ($projPlan) { $allPlan += @($projPlan) }
}
$plan = $allPlan

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check GCP permissions and project access."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================
$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $devType = $item.Attributes['GCP.DeviceType']
    switch ($devType) {
        'VM' {
            $key  = "vm:$($item.Attributes['GCP.VMId'])"
            $name = $item.Attributes['GCP.VMName']
            $ip   = $item.Attributes['GCP.IPAddress']
        }
        'CloudSQL' {
            $key  = "sql:$($item.Attributes['GCP.SQLName'])"
            $name = $item.Attributes['GCP.SQLName']
            $ip   = $item.Attributes['GCP.IPAddress']
        }
        'ForwardingRule' {
            $key  = "fwd:$($item.Attributes['GCP.FwdRuleName'])"
            $name = $item.Attributes['GCP.FwdRuleName']
            $ip   = $item.Attributes['GCP.IPAddress']
        }
        default { continue }
    }
    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name  = $name
            IP    = $ip
            Type  = $devType
            Attrs = $item.Attributes
            Items = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$vmDevices  = @($devicePlan.Values | Where-Object { $_.Type -eq 'VM' })
$sqlDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'CloudSQL' })
$fwdDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'ForwardingRule' })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  VMs:                    $($vmDevices.Count)" -ForegroundColor White
Write-Host "  Cloud SQL:              $($sqlDevices.Count)" -ForegroundColor White
Write-Host "  Forwarding Rules (LB):  $($fwdDevices.Count)" -ForegroundColor White
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

Write-Host "Monitor templates:" -ForegroundColor Cyan
foreach ($t in $activeTemplates) { Write-Host "  [Active] $t" -ForegroundColor White }
Write-Host ""

$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    ForEach-Object { [PSCustomObject]@{
        Device   = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { '(cloud)' }
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

        $stats = @{ HealthCreated = 0; HealthSkipped = 0; HealthFailed = 0; DevicesCreated = 0; DevicesFound = 0; CredsAssigned = 0 }
        $wugDeviceMap = @{}
        $deviceKeys = @($devicePlan.Keys | Sort-Object)
        $devTotal = $deviceKeys.Count

        # ---- 1. Create/find REST API credential ---
        # GCP uses OAuth2 bearer token; the credential stores the token
        Write-Host ""
        Write-Host "Setting up GCP REST API credential in WUG..." -ForegroundColor Cyan
        $credName = "GCP Bearer Token"
        $gcpCredId = $null

        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName -View basic)
            if ($existingCreds.Count -eq 0) { $existingCreds = @(Get-WUGCredential -SearchValue $credName -View basic) }
            if ($existingCreds.Count -gt 0) {
                $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                if ($matchCred) { $gcpCredId = $matchCred.id; Write-Host "  Found existing credential (ID: $gcpCredId)" -ForegroundColor Green }
            }
        }
        catch {
            Write-Warning "  Credential lookup failed for '$credName': $($_.Exception.Message). A duplicate may be created."
        }

        if (-not $gcpCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                $credResult = Add-WUGCredential -Name $credName `
                    -Description "GCP OAuth2 Bearer Token (auto-created by discovery)" `
                    -Type restapi `
                    -RestApiUsername 'oauth2' `
                    -RestApiPassword $gcpToken `
                    -RestApiAuthType '0' `
                    -RestApiIgnoreCertErrors 'False'
                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) { $gcpCredId = $credResult.data.idMap.resultId }
                    elseif ($credResult.PSObject.Properties['resourceId']) { $gcpCredId = $credResult.resourceId }
                    elseif ($credResult.PSObject.Properties['id']) { $gcpCredId = $credResult.id }
                    if ($gcpCredId) { Write-Host "  Created credential (ID: $gcpCredId)" -ForegroundColor Green }
                }
            }
            catch { Write-Verbose "Credential creation failed: $_" }
            if (-not $gcpCredId) { Write-Warning "Could not create REST API credential. GCP bearer tokens expire hourly." }
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
                    @{ name = 'MonRestApi:HttpTimeoutMs';          value = if ($mp.RestApiTimeoutMs) { "$($mp.RestApiTimeoutMs)" } else { '15000' } }
                    @{ name = 'MonRestApi:IgnoreCertErrors';       value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '0' } }
                    @{ name = 'MonRestApi:UseAnonymousAccess';     value = if ($mp.RestApiUseAnonymous) { "$($mp.RestApiUseAnonymous)" } else { '0' } }
                    @{ name = 'MonRestApi:CustomHeader';           value = '' }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn'; value = if ($mp.RestApiDownIfResponseCodeIsIn) { "$($mp.RestApiDownIfResponseCodeIsIn)" } else { '[]' } }
                    @{ name = 'MonRestApi:ComparisonList';         value = if ($mp.RestApiComparisonList) { "$($mp.RestApiComparisonList)" } else { '[]' } }
                    @{ name = 'Cred:Type';                        value = '8192' }
                )

                $activeTemplateArr += @{
                    templateId      = $tplId
                    name            = $actName
                    description     = 'GCP RestApi active monitor'
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

        # ---- 2b. Check existing vs new devices ---
        Write-Host "  Checking for existing devices..." -ForegroundColor Cyan
        $existingDevices = @{}
        $newDeviceKeys = [System.Collections.Generic.List[string]]::new()

        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            $displayName = "$($dev.Name) (GCP)"
            $deviceId = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $match = $searchResults | Where-Object { $_.displayName -eq $dev.Name -or $_.displayName -eq $displayName } | Select-Object -First 1
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

        # ---- 2c. Create new devices ---
        if ($newDeviceKeys.Count -gt 0) {
            Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow
            $devIdx = 0
            foreach ($key in $newDeviceKeys) {
                $devIdx++
                $dev = $devicePlan[$key]
                $addIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
                $displayName = "$($dev.Name) (GCP)"

                Write-Progress -Activity 'Creating devices' `
                    -Status "$devIdx / $($newDeviceKeys.Count) - $displayName" `
                    -PercentComplete ([Math]::Round(($devIdx / $newDeviceKeys.Count) * 100))

                $devAttrs = @()
                foreach ($attrName in $dev.Attrs.Keys) {
                    if ($dev.Attrs[$attrName]) { $devAttrs += @{ name = $attrName; value = "$($dev.Attrs[$attrName])" } }
                }

                $actNames = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) { $actNames += $actItem.Name }
                }

                if ($actNames.Count -eq 0) { continue }

                $splat = @{
                    displayName            = $displayName
                    DeviceAddress          = $addIP
                    Hostname               = $dev.Name
                    Brand                  = 'Google Cloud'
                    Note                   = "GCP $($dev.Type) (auto-created by discovery)"
                    NoDefaultActiveMonitor = $true
                }
                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($gcpCredId) { $splat['CredentialRestApi'] = $credName }
                if ($actNames.Count -gt 0) { $splat['ActiveMonitors'] = $actNames }

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
            Write-Progress -Activity 'Creating devices' -Completed
            Write-Host "    Devices created: $($stats.DevicesCreated)" -ForegroundColor Green
        }

        # ---- 2d. Update existing devices ---
        if ($existingDevices.Count -gt 0) {
            Write-Host "  Updating $($existingDevices.Count) existing devices..." -ForegroundColor Cyan
            foreach ($key in $existingDevices.Keys) {
                $deviceId = [int]$existingDevices[$key]
                $dev = $devicePlan[$key]

                if ($gcpCredId) {
                    try { $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $gcpCredId -Assign; $stats.CredsAssigned++ }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Warning "    Could not assign credential to device ${deviceId}: $($_.Exception.Message)"
                        }
                    }
                }

                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) { $actMonitorIds += $existingActiveNames[$actItem.Name] }
                }
                if ($actMonitorIds.Count -gt 0) {
                    try { Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $actMonitorIds -ErrorAction Stop }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Warning "    Could not assign active monitors to device ${deviceId}: $($_.Exception.Message)"
                        }
                    }
                }
            }
        }

        # ---- Summary ---
        Write-Host ""
        Write-Host "Push complete!" -ForegroundColor Green
        Write-Host "  Active monitors:  $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor White
        Write-Host "  Devices:          $($stats.DevicesCreated) created, $($stats.DevicesFound) existing" -ForegroundColor White
        Write-Host "  Creds assigned:   $($stats.CredsAssigned)" -ForegroundColor White
        Write-Host ""
        Write-Host "Note: GCP bearer tokens expire after 1 hour. Re-run to refresh." -ForegroundColor Yellow
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'gcp-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'gcp-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate GCP HTML Dashboard from discovery data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building GCP dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $activeItems = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })
            $perfItems   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })

            foreach ($item in ($activeItems + $perfItems)) {
                $dashboardRows += [PSCustomObject]@{
                    Device        = $dev.Name
                    IP            = if ($dev.IP) { $dev.IP } else { '(cloud)' }
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
            $dashPath = Join-Path $OutputDir 'GCP-Dashboard.html'

            if (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
                Export-DynamicDashboardHtml -Data $dashboardRows `
                    -OutputPath $dashPath `
                    -ReportTitle 'GCP Discovery Dashboard' `
                    -CardField 'Device','Type' `
                    -StatusField 'Status'
            }
            else {
                Write-Warning "No dashboard function available. Exporting as JSON instead."
                $jsonPath = Join-Path $OutputDir "GCP-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).json"
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
                $wugDashPath = Join-Path $wugDashDir 'GCP-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/GCP-Dashboard.html" -ForegroundColor Cyan
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
Write-Host "Re-run anytime to discover new GCP resources." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCKtbKarIUg5/NX
# oZJT1WKrC1ldbrKOJ5+xhkYdSl2MkqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDBUCk/eykGFZfHmq18vY6qmacZc0m8yAO/7q94RB8ZMTANBgkqhkiG9w0BAQEF
# AASCAgCzuuHqlWHliZgNzb6oleDG7g9/wY3T04WJZGcjdxkRVAQ5+8ut7FfqOwGw
# depjbzw68fWTCKVNyutStLH6i+UVXjuT3mvhxKwuFW5wuox9nSwvSLPHukadOiYU
# ncb7vZmQbu4DVVsAy/NvmouMTNI+f7VefrK6pVjFUrVByaE7Z+sWe388ne6mx9dc
# MEUvHtrM5FwRQ8gENYrQdou903z8P1tpWbq8ByT8TaAovZ6hoYrLGJR53oaQinve
# qUTxtsVFBcvIEhaE0k5/Xkj708wMiJIVJrS+Qujj6HOnTLOEYHU9/AIp8iFmHQVY
# +UOclwI0P1xMpxcOXrRuEfRkBDt9dOqv5jgZzcxsnLZM6oWXfwqiX5rQ9Z0k9aB2
# GsJ+SJAN0eEFC1sOn2QlUG578yqAj7tPlqR0vxRzvZdksEFoCTKqiEtQ8mIaCCnX
# 1C3dPs7yaymdFxYDu+SPjMkUchledOE7n4gxk5b0dRvphx1YynZWOpljZerl2yrE
# H0e6A2PnAM/uNBEIDsV0WDqTe70TWcByMWRBeKTjtd7jTS2oMz41ZcskUeCzrRXA
# qXdN64pJPf/Z0XbpG+YVrtYaoIIMzn5d57ffzwM+/EEcxkUW8/k4UwWoYafKtlus
# vi1T7n4TGKO4NHD92hxZLKvqluh8RqU08tkyKFX3ZvPrAzbvGKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MzAxNTU2NDZaMC8GCSqGSIb3DQEJBDEiBCDKy40u
# 6KHDCzqC4CKv2tDiUhzaVOw8+mdtAhe7RqA0STANBgkqhkiG9w0BAQEFAASCAgBl
# xvISKjwMxO77bCvWN9SxbVkb9rQQlW3HZHipDcuMMdxObY7KkLUKLrD/zDMCmd/k
# FTXg4ZRn8UFG6V+o2o7I1lAJDV0zMjPuE5f1HWPf+B37pwPuVJszzAfmMFS2cbvY
# e9NETJZZbQxgswn7ETqlPf8r9eQL2IsGtCzELMDoc7TMbAyeeHrdWMUwMs9q+HO6
# Zg5nfhaWtqguv+xM2u8q2hn1yEUvvGIDUpIo2pvIFfa6AVPZmk3F9Ubbs8HiVBTk
# iRm2zB9WNB7qOPQs5L8hiVob4xpiK0yuDOx26N+phIrZPv0B69fIul5K99DNKnmg
# kXtWJfLBcmZ5Z2luAdIX9onYmRV0r3Re5EtZmFffOF4znn+vnzpWp+QSiDLgBMNz
# 4zRgHj57zlck4qSHwhH7ABX9ITI0QhJ2s0OhsCj3KthfmrvvF+ht0dCkDCNI29gz
# OSe0lu1X5dwXZbgp3+m3ZdrncYz7pUkO6ix/waPCd761GoFpxor4YPDO6gAnhr0F
# J3yaJiG4KMw9LQMYnpN2WcQY9aOdH9AFaeWKdG/NexnBSGNvQ0hiOpNQouSIE/nj
# YqsuQB1wVuh4DZCsZpq18gmBpz/IPKj87qoeuODu/gf2nXrAT4g6tVDHWMjMcQ85
# voAR91B4wIMKeZxNJdwn92dw+0R2FZWZyn/5JRxMpw==
# SIG # End signature block
