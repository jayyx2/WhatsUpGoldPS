<#
.SYNOPSIS
    OCI Discovery -- Discover Oracle Cloud compute, databases, and load balancers,
    then optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers Oracle Cloud Infrastructure resources via
    the OCI.PSModules, then lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + REST API monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Exit

    Architecture (when pushed to WUG):
      [OCI Compute device in WUG]
          |-- "OCI Compute Health - <name>"    (REST API Active Monitor)
          '-- ...
      [OCI DB System device in WUG]
          |-- "OCI DB Health - <name>"         (REST API Active Monitor)
          '-- ...
      [OCI Autonomous DB device in WUG]
          |-- "OCI ADB Health - <name>"        (REST API Active Monitor)
          '-- ...
      [OCI Load Balancer device in WUG]
          |-- "OCI LB Health - <name>"         (REST API Active Monitor)
          '-- ...

    First Run:
      1. Prompts for OCI config file path and profile name
      2. Prompts for tenancy OCID
      3. Stores config path in DPAPI vault (encrypted)
      4. Validates OCI connectivity and discovers resources
      5. Shows summary, then asks what to do

    Subsequent Runs:
      Loads OCI config path from vault and reconnects.

    Prerequisites:
      1. OCI.PSModules installed (Install-Module OCI.PSModules)
      2. OCI config file (~/.oci/config) with valid API key
      3. Appropriate IAM policies for read access

.PARAMETER TenancyId
    OCI tenancy OCID. Required for non-interactive mode.

.PARAMETER ConfigFile
    Path to OCI config file. Default: ~/.oci/config.

.PARAMETER Profile
    OCI config profile name. Default: DEFAULT.

.PARAMETER Region
    Override OCI region for discovery.

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
    OCI.PSModules handles API request signing via config file.
    OCI REST API monitors in WUG require OCI request-signing to work
    (the monitors store URLs for reference; actual polling may need
    a script-based approach for OCI's signature-based auth).

.EXAMPLE
    .\Setup-OCI-Discovery.ps1
    # Interactive mode.

.EXAMPLE
    .\Setup-OCI-Discovery.ps1 -TenancyId 'ocid1.tenancy.oc1..aaaaaa' -Action PushToWUG -NonInteractive
    # Scheduled mode.

.EXAMPLE
    .\Setup-OCI-Discovery.ps1 -TenancyId 'ocid1.tenancy.oc1..aaa' -Region 'us-ashburn-1' -Action ExportJSON
    # Discover in specific region and export.
#>
[CmdletBinding()]
param(
    [string]$TenancyId,

    [string]$ConfigFile,

    [string]$Profile = 'DEFAULT',

    [string]$Region,

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

# --- Load helpers -------------------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-OCI.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== OCI Discovery ===" -ForegroundColor Cyan
Write-Host ""

# Resolve config file
if (-not $ConfigFile) {
    $defaultConfig = Join-Path $env:USERPROFILE '.oci\config'
    if ($NonInteractive) {
        $ConfigFile = $defaultConfig
    }
    else {
        $cfgInput = Read-Host -Prompt "OCI config file [default: $defaultConfig]"
        $ConfigFile = if ([string]::IsNullOrWhiteSpace($cfgInput)) { $defaultConfig } else { $cfgInput.Trim() }
    }
}

if (-not (Test-Path $ConfigFile)) {
    Write-Error "OCI config file not found: $ConfigFile"
    return
}

# Resolve profile
if (-not $PSBoundParameters.ContainsKey('Profile') -and -not $NonInteractive) {
    $profInput = Read-Host -Prompt "OCI profile [default: $Profile]"
    if (-not [string]::IsNullOrWhiteSpace($profInput)) { $Profile = $profInput.Trim() }
}

# Resolve tenancy ID
if (-not $TenancyId) {
    if ($NonInteractive) {
        # Try to extract from config file
        try {
            $configContent = Get-Content $ConfigFile -Raw
            if ($configContent -match 'tenancy\s*=\s*(ocid1\.tenancy\.[^\s]+)') {
                $TenancyId = $Matches[1]
            }
        }
        catch { }
        if (-not $TenancyId) { Write-Error 'No tenancy ID specified. Pass -TenancyId parameter.'; return }
    }
    else {
        # Try to extract default from config
        $defaultTenancy = $null
        try {
            $configContent = Get-Content $ConfigFile -Raw
            if ($configContent -match 'tenancy\s*=\s*(ocid1\.tenancy\.[^\s]+)') {
                $defaultTenancy = $Matches[1]
            }
        }
        catch { }
        $tenancyPrompt = if ($defaultTenancy) { "Tenancy OCID [default: $defaultTenancy]" } else { "Tenancy OCID" }
        $tenancyInput = Read-Host -Prompt $tenancyPrompt
        $TenancyId = if ([string]::IsNullOrWhiteSpace($tenancyInput) -and $defaultTenancy) { $defaultTenancy } else { $tenancyInput.Trim() }
    }
}

if (-not $TenancyId) { Write-Error 'No tenancy OCID provided.'; return }
Write-Host "Tenancy: $TenancyId" -ForegroundColor Cyan
Write-Host "Config:  $ConfigFile (profile: $Profile)" -ForegroundColor Cyan
if ($Region) { Write-Host "Region:  $Region" -ForegroundColor Cyan }
Write-Host ""

# ==============================================================================
# STEP 2: Authentication (OCI config file)
# ==============================================================================
Write-Host "Validating OCI connectivity..." -ForegroundColor Cyan
try {
    $connectSplat = @{}
    if ($ConfigFile) { $connectSplat['ConfigFile'] = $ConfigFile }
    if ($Profile -and $Profile -ne 'DEFAULT') { $connectSplat['Profile'] = $Profile }
    Connect-OCIProfile @connectSplat
    Write-Host "OCI authentication successful." -ForegroundColor Green
}
catch {
    Write-Error "OCI authentication failed: $_"
    return
}
Write-Host ""

# ==============================================================================
# STEP 3: Discover -- query OCI APIs
# ==============================================================================
Write-Host "Querying OCI tenancy..." -ForegroundColor Cyan

$ociCredential = @{
    ConfigFile = $ConfigFile
    Profile    = $Profile
    TenancyId  = $TenancyId
}
if ($Region) { $ociCredential['Region'] = $Region }

$plan = Invoke-Discovery -ProviderName 'OCI' `
    -Target $TenancyId `
    -Credential $ociCredential

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check OCI permissions and tenancy access."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================
$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $devType = $item.Attributes['OCI.DeviceType']
    switch ($devType) {
        'Compute' {
            $key  = "compute:$($item.Attributes['OCI.InstanceId'])"
            $name = $item.Attributes['OCI.InstanceId']
            # Use the monitor name to derive friendly name
            if ($item.Name -match 'OCI Compute Health - (.+)$') { $name = $Matches[1] }
            $ip   = $item.Attributes['OCI.IPAddress']
        }
        'DBSystem' {
            $key  = "db:$($item.Attributes['OCI.DBSystemId'])"
            $name = $item.Attributes['OCI.DBSystemId']
            if ($item.Name -match 'OCI DB Health - (.+)$') { $name = $Matches[1] }
            $ip   = $item.Attributes['OCI.IPAddress']
        }
        'AutonomousDB' {
            $key  = "adb:$($item.Attributes['OCI.AutonomousDbId'])"
            $name = $item.Attributes['OCI.AutonomousDbId']
            if ($item.Name -match 'OCI ADB Health - (.+)$') { $name = $Matches[1] }
            $ip   = $item.Attributes['OCI.IPAddress']
        }
        'LoadBalancer' {
            $key  = "lb:$($item.Attributes['OCI.LoadBalancerId'])"
            $name = $item.Attributes['OCI.LoadBalancerId']
            if ($item.Name -match 'OCI LB Health - (.+)$') { $name = $Matches[1] }
            $ip   = $item.Attributes['OCI.IPAddress']
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

$computeDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'Compute' })
$dbDevices      = @($devicePlan.Values | Where-Object { $_.Type -eq 'DBSystem' })
$adbDevices     = @($devicePlan.Values | Where-Object { $_.Type -eq 'AutonomousDB' })
$lbDevices      = @($devicePlan.Values | Where-Object { $_.Type -eq 'LoadBalancer' })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Compute Instances:      $($computeDevices.Count)" -ForegroundColor White
Write-Host "  DB Systems:             $($dbDevices.Count)" -ForegroundColor White
Write-Host "  Autonomous Databases:   $($adbDevices.Count)" -ForegroundColor White
Write-Host "  Load Balancers:         $($lbDevices.Count)" -ForegroundColor White
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

        $stats = @{ HealthCreated = 0; HealthSkipped = 0; HealthFailed = 0; DevicesCreated = 0; DevicesFound = 0; CredsAssigned = 0 }
        $wugDeviceMap = @{}
        $deviceKeys = @($devicePlan.Keys | Sort-Object)
        $devTotal = $deviceKeys.Count

        # ---- 1. Create/find REST API credential ---
        # OCI uses request signing, not simple bearer tokens;
        # we create a placeholder credential for the REST API monitors
        Write-Host ""
        Write-Host "Setting up OCI REST API credential in WUG..." -ForegroundColor Cyan
        $credName = "OCI API"
        $ociCredId = $null

        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName -View basic)
            if ($existingCreds.Count -eq 0) { $existingCreds = @(Get-WUGCredential -SearchValue $credName -View basic) }
            if ($existingCreds.Count -gt 0) {
                $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                if ($matchCred) { $ociCredId = $matchCred.id; Write-Host "  Found existing credential (ID: $ociCredId)" -ForegroundColor Green }
            }
        }
        catch { }

        if (-not $ociCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                $credResult = Add-WUGCredential -Name $credName `
                    -Description "OCI API credential (auto-created by discovery)" `
                    -Type restapi `
                    -RestApiUsername '' `
                    -RestApiPassword '' `
                    -RestApiAuthType '0' `
                    -RestApiIgnoreCertErrors 'False'
                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) { $ociCredId = $credResult.data.idMap.resultId }
                    elseif ($credResult.PSObject.Properties['resourceId']) { $ociCredId = $credResult.resourceId }
                    elseif ($credResult.PSObject.Properties['id']) { $ociCredId = $credResult.id }
                    if ($ociCredId) { Write-Host "  Created credential (ID: $ociCredId)" -ForegroundColor Green }
                }
            }
            catch { Write-Verbose "Credential creation failed: $_" }
            if (-not $ociCredId) {
                Write-Warning "Could not create REST API credential."
                Write-Warning "OCI uses request signing -- REST API monitors may need script-based polling."
            }
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
                    description     = 'OCI RestApi active monitor'
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
            $displayName = "$($dev.Name) (OCI)"
            $deviceId = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $match = $searchResults | Where-Object { $_.displayName -eq $dev.Name -or $_.displayName -eq $displayName } | Select-Object -First 1
                    if ($match) { $deviceId = $match.id }
                }
            }
            catch { }

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
                $displayName = "$($dev.Name) (OCI)"

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
                    Brand                  = 'Oracle Cloud'
                    Note                   = "OCI $($dev.Type) (auto-created by discovery)"
                    NoDefaultActiveMonitor = $true
                }
                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($ociCredId) { $splat['CredentialRestApi'] = $credName }
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

        # ---- 2d. Update existing devices ---
        if ($existingDevices.Count -gt 0) {
            Write-Host "  Updating $($existingDevices.Count) existing devices..." -ForegroundColor Cyan
            foreach ($key in $existingDevices.Keys) {
                $deviceId = [int]$existingDevices[$key]
                $dev = $devicePlan[$key]

                if ($ociCredId) {
                    try { $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $ociCredId -Assign; $stats.CredsAssigned++ }
                    catch { }
                }

                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) { $actMonitorIds += $existingActiveNames[$actItem.Name] }
                }
                if ($actMonitorIds.Count -gt 0) {
                    try { Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $actMonitorIds -ErrorAction Stop } catch { }
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
        Write-Host "Note: OCI REST API uses request signing. Monitors may need script-based polling." -ForegroundColor Yellow
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'oci-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'oci-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate OCI HTML Dashboard from discovery data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building OCI dashboard from discovery data..." -ForegroundColor Cyan

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
            $dashPath = Join-Path $OutputDir 'OCI-Dashboard.html'

            if (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
                Export-DynamicDashboardHtml -Data $dashboardRows `
                    -OutputPath $dashPath `
                    -ReportTitle 'OCI Discovery Dashboard' `
                    -CardField 'Device','Type' `
                    -StatusField 'Status'
            }
            else {
                Write-Warning "No dashboard function available. Exporting as JSON instead."
                $jsonPath = Join-Path $OutputDir "OCI-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).json"
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
                $wugDashPath = Join-Path $nmConsolePath 'OCI-Dashboard.html'
                try {
                    Copy-Item -Path $dashPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/OCI-Dashboard.html" -ForegroundColor Cyan
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
Write-Host "Re-run anytime to discover new OCI resources." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCsgMCjfKjyE5GU
# 6KvwPIUGj8btzkAZCLg9X1gYMI4rKKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgZPQcn0yGtkpAD4VR43UlqP9uo12/8vah
# mC7p4KwDRZ8wDQYJKoZIhvcNAQEBBQAEggIA2tbm8qrY71en3ts9c/HAKiwWsgMm
# bJ7piXRFygyz5z7MsRAnz9kJms29poJPFo9D7pgcB34T6RSCoP3nhPIzqvL2oU/Q
# CTcsjiEsAuDeZLBpJUb1ne/pabxjFgjg+rDL7kCppRPzEWR/MK47HUmTY3Lwf+7T
# HrsJRB085XMllrQxueZWN1q+p00dfscJa5p8s58KOjcmbQMmRyLEFKL6yq1/CoXH
# fM++KvJ/DMpW44I6bdlCqemoUGfUbEoG5CH4ZNyFyHdhShwK4zWZVOHdo0TyajOf
# NG6qlV/Cfotrl5FmLn4ZamODGNqrzkQ+byM6xiQaVZKTF2i9Da0N7lAJIQ/ithSD
# 8e0CrepvXk9T8AaVH1ywlDxFtmOiPg4AtZqqGRmTmYhu2SZ8ETDa8Oj1QzKtpWRk
# mQ78LE1nO08QjfANeHrEx8/UtgslA97BruYxsqgPI958PZ3pJwonm9gXY+YG6EHq
# ynOgOMk3JClWeNZ516sF44sciDzk+2m7feYss6wKVhTz24ThKOmdhGFrfx5jGSbi
# LTmIiReARepeqwoTRvBcTSpUioPfjfkoApABCyMds7QaGGco5FXFAY2nM1ile6s5
# eGFH3ScJgc+yJSEBYdJAbp8OPMSGVlP78wEhCqxteMjkItQXiioIgosUY6vMpzYN
# /qU1nj28dpnGqtw=
# SIG # End signature block
