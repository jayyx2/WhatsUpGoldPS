<#
.SYNOPSIS
    Azure Discovery -- Discover all resources + metrics, push to WhatsUp Gold as
    cloud devices with per-metric REST API monitors.

.DESCRIPTION
    Discovers ALL Azure resources across ALL subscriptions the service principal
    can see, enumerates available Azure Monitor metrics for each resource, and
    builds a comprehensive monitoring plan.

    Menu options:
      [1] Push ALL resources to WhatsUp Gold
          - Adds every resource as a WUG device (0.0.0.0 for cloud-only resources)
          - Creates Azure + REST API (OAuth2) credentials in WUG library
          - Assigns credentials to each device
          - Creates one REST API Active Monitor per resource (Azure Resource Health)
          - Creates one REST API Performance Monitor per Azure metric per resource
          - Sets 15+ Azure attributes on each device (ResourceID, Type, SKU, etc.)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Generate Azure HTML dashboard
      [6] Exit (do nothing)
      [7] Test Azure credential in WUG (add, verify, delete)

    Two collection methods:
      [1] Az PowerShell modules -- uses Az.Accounts, Az.Resources, Az.Monitor
      [2] REST API (direct) -- zero external dependencies, uses Invoke-RestMethod

    First Run:
      1. Prompts for collection method and Tenant ID
      2. Prompts for Application ID, Client Secret
      3. Stores service principal in DPAPI vault (encrypted)
      4. Authenticates and discovers all subscriptions, RGs, resources, and metrics
      5. Shows summary, then asks what to do

    Subsequent Runs:
      Loads service principal from vault automatically.

    Quick Start:
      1. .\Setup-Azure-Discovery.ps1                       # interactive first run
      2. .\Setup-Azure-Discovery.ps1 -Action PushToWUG     # push to WUG
      3. .\Setup-Azure-Discovery.ps1 -Action TestCredential # verify WUG creds work
      4. .\Setup-Azure-Discovery.ps1 -TenantId 'xxx' -SubscriptionFilter all -WUGServer 192.168.74.74 -Action PushToWUG
         # fully automated — uses vault creds, no prompts

.PARAMETER TenantId
    Azure Tenant ID. Required for non-interactive mode.

.PARAMETER SubscriptionFilter
    Filter to a specific subscription ID or name. Pass 'all' or omit to discover
    all subscriptions. When provided, skips the interactive subscription prompt.

.PARAMETER UseRestApi
    Use REST API direct mode (no Az modules needed). Default: true.
    Pass -UseRestApi:$false for Az module mode.

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard,
    TestCredential, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin credentials (non-interactive WUG push).

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and parameter defaults.
    Defaults to Dashboard action. Ideal for scheduled task execution.
    When all key parameters are supplied (-TenantId, -SubscriptionFilter, -Action,
    -WUGServer), the script auto-uses vault credentials without prompting even
    without -NonInteractive. Use -NonInteractive to error instead of prompt when
    vault credentials are missing.

.PARAMETER MetricsTimespan
    How far back Azure Monitor looks when polling metrics.
    Wider windows help idle or lab environments where resources have sparse data.
    The interval always matches the timespan so a single aggregated bucket is returned.
    Valid values: PT1H (1 hour), PT6H (6 hours), PT12H (12 hours),
    P1D (1 day, default), P7D (7 days).
    In interactive mode the script prompts; pass this parameter to skip the prompt.

.NOTES
    WhatsUpGoldPS module is only needed for options [1] and [7] (WUG push/test).
    REST API mode has zero external module dependencies.
    Az module mode requires: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Monitor.

.EXAMPLE
    .\Setup-Azure-Discovery.ps1
    # Interactive mode — prompts for everything.

.EXAMPLE
    .\Setup-Azure-Discovery.ps1 -TenantId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -Action ExportJSON -NonInteractive
    # Scheduled mode — uses vault credentials, exports JSON, no prompts.
#>
[CmdletBinding()]
param(
    [string]$TenantId,

    [string]$SubscriptionFilter,

    [switch]$UseRestApi,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'MetricsDashboard', 'TestCredential', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [int]$MaxPerformanceMonitorsPerDevice = 10,

    [ValidateSet('PT1H', 'PT6H', 'PT12H', 'P1D', 'P7D')]
    [string]$MetricsTimespan = 'P1D',

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

# Default to REST API if not explicitly set
if (-not $PSBoundParameters.ContainsKey('UseRestApi')) {
    $UseRestApi = $true
}

# --- Collection method ---------------------------------------------------------
# Skip prompt when UseRestApi is already set (default true) or Action is specified
if (-not $PSBoundParameters.ContainsKey('UseRestApi') -and -not $NonInteractive -and -not $Action) {
    Write-Host ""
    Write-Host "Azure data collection method:" -ForegroundColor Cyan
    Write-Host "  [1] Az PowerShell modules (requires Az.Accounts, Az.Resources, etc.)" -ForegroundColor White
    Write-Host "  [2] REST API direct (zero external dependencies)" -ForegroundColor White
    Write-Host ""
    $methodChoice = Read-Host -Prompt "Choice [1/2, default: 2]"
    $UseRestApi = ($methodChoice -ne '1')
}

if ($UseRestApi) {
    Write-Host "Using REST API mode (no Az modules needed)." -ForegroundColor Green
}
else {
    Write-Host "Using Az PowerShell module mode." -ForegroundColor Green

    # --- Check for required Az sub-modules --------------------------------
    $requiredAzModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.Monitor')
    $missingModules = @($requiredAzModules | Where-Object { -not (Get-Module -ListAvailable -Name $_ -ErrorAction SilentlyContinue) })
    if ($missingModules.Count -gt 0) {
        Write-Warning "Required Az modules not found: $($missingModules -join ', ')"
        Write-Host "  Install with:" -ForegroundColor Yellow
        foreach ($mod in $missingModules) {
            Write-Host "    Install-Module -Name $mod -Scope CurrentUser -Force" -ForegroundColor Yellow
        }
        if ($NonInteractive) {
            Write-Error "Cannot proceed without required Az modules in non-interactive mode."
            return
        }
        Write-Host ""
        $installChoice = Read-Host -Prompt "Attempt to install missing modules now? [y/N]"
        if ($installChoice -eq 'y' -or $installChoice -eq 'Y') {
            foreach ($mod in $missingModules) {
                try {
                    Write-Host "  Installing $mod..." -ForegroundColor Cyan
                    Install-Module -Name $mod -Scope CurrentUser -Force -ErrorAction Stop
                    Write-Host "  $mod installed." -ForegroundColor Green
                }
                catch {
                    Write-Error "Failed to install ${mod}: $_"
                    return
                }
            }
            Write-Host "All required Az modules installed successfully." -ForegroundColor Green
        }
        else {
            Write-Host "Cannot proceed without required Az modules. Exiting." -ForegroundColor Red
            return
        }
    }

    # --- Pre-load required Az sub-modules to avoid version mismatch -------
    # IMPORTANT: Never use 'Import-Module Az' -- it loads all ~70 sub-modules
    # and will fail on broken ones. Only import the specific ones we need.
    $loadedAccounts = Get-Module -Name Az.Accounts
    $latestAccounts = Get-Module -ListAvailable -Name Az.Accounts |
        Sort-Object Version -Descending | Select-Object -First 1

    if ($loadedAccounts -and $latestAccounts -and $loadedAccounts.Version -lt $latestAccounts.Version) {
        Write-Warning "Az.Accounts $($loadedAccounts.Version) is loaded but $($latestAccounts.Version) is available."
        Write-Warning "Stale Az module assemblies in this session may cause errors."
        Write-Warning "Please close this PowerShell window and re-run in a fresh session."
        return
    }

    foreach ($azMod in $requiredAzModules) {
        if (-not (Get-Module -Name $azMod)) {
            $latest = Get-Module -ListAvailable -Name $azMod |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($latest) {
                try {
                    Import-Module $azMod -RequiredVersion $latest.Version -ErrorAction Stop
                    Write-Verbose "Loaded $azMod $($latest.Version)"
                }
                catch {
                    Write-Warning "Could not load ${azMod}: $($_.Exception.Message)"
                }
            }
        }
    }
}

# --- Metrics timespan window --------------------------------------------------
# Controls how far back Azure Monitor looks when polling metrics.
# Wider windows help idle / lab environments where resources have sparse data.
if (-not $PSBoundParameters.ContainsKey('MetricsTimespan') -and -not $NonInteractive -and -not $Action) {
    Write-Host ""
    Write-Host "Azure metrics lookback window:" -ForegroundColor Cyan
    Write-Host "  [1] PT1H  - 1 hour   (busy production, frequent data)" -ForegroundColor White
    Write-Host "  [2] PT6H  - 6 hours" -ForegroundColor White
    Write-Host "  [3] PT12H - 12 hours" -ForegroundColor White
    Write-Host "  [4] P1D   - 1 day    (default, good for most environments)" -ForegroundColor White
    Write-Host "  [5] P7D   - 7 days   (idle labs with sparse / no traffic)" -ForegroundColor White
    Write-Host ""
    $tsChoice = Read-Host -Prompt "Choice [1-5, default: 4]"
    $MetricsTimespan = switch ($tsChoice) {
        '1' { 'PT1H' }
        '2' { 'PT6H' }
        '3' { 'PT12H' }
        '5' { 'P7D' }
        default { 'P1D' }
    }
}
Write-Host "Metrics lookback window: $MetricsTimespan" -ForegroundColor Green

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$moduleRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Azure.ps1')

# --- Load WhatsUpGoldPS module (repo-first, fallback to installed) ------------
try {
    $repoPsd1 = Join-Path $moduleRoot 'WhatsUpGoldPS.psd1'
    if (Test-Path $repoPsd1) { Import-Module $repoPsd1 -Force -ErrorAction Stop }
    else { Import-Module WhatsUpGoldPS -ErrorAction Stop }
}
catch { Write-Warning "Could not load WhatsUpGoldPS module: $_ — WUG actions will fail." }
# Dot-source internal helper so scripts can call Get-WUGAPIResponse directly
$apiResponsePath = Join-Path $scriptDir '..\..\functions\Get-WUGAPIResponse.ps1'
if (Test-Path $apiResponsePath) { . $apiResponsePath }

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Azure Discovery ===" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 2: Service Principal Credentials (DPAPI vault)
# ==============================================================================

# --- Resolve Tenant ID --------------------------------------------------------
if (-not $TenantId) {
    if ($NonInteractive) {
        Write-Error 'Tenant ID is required for non-interactive mode. Pass -TenantId.'
        return
    }
    Write-Host ""
    $tenantInput = Read-Host -Prompt "Azure Tenant ID"
    if ([string]::IsNullOrWhiteSpace($tenantInput)) {
        Write-Error 'Tenant ID is required. Exiting.'
        return
    }
    $TenantId = $tenantInput.Trim()
}

$credSplat = @{ Name = "Azure.$TenantId.ServicePrincipal"; CredType = 'AzureSP'; ProviderLabel = 'Azure' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
# Auto-use vault creds when Action is specified (no Y/R/N prompt)
if ($Action) { $credSplat.AutoUse = $true }
$AzureCred = Resolve-DiscoveryCredential @credSplat
if (-not $AzureCred) {
    Write-Error 'No Azure credentials. Exiting.'
    return
}

# --- Resolve subscription filter (optional) -----------------------------------
if (-not $PSBoundParameters.ContainsKey('SubscriptionFilter')) {
    if ($NonInteractive -or $Action) {
        # Default to all subscriptions when running automated
        $SubscriptionFilter = $TenantId
    }
    else {
        Write-Host ""
        $subInput = Read-Host -Prompt "Filter to subscription ID or name? (blank = all subscriptions)"
        $SubscriptionFilter = if ([string]::IsNullOrWhiteSpace($subInput)) { $TenantId } else { $subInput.Trim() }
    }
}
# Normalize 'all' to TenantId (meaning: discover all subscriptions)
if (-not $SubscriptionFilter -or $SubscriptionFilter -eq 'all') { $SubscriptionFilter = $TenantId }

# ==============================================================================
# STEP 2b: Early WUG connection (when -Action requires WUG)
# ==============================================================================
# When the action is known up front (PushToWUG / TestCredential), connect to
# WUG *before* discovery so the entire pipeline runs without user interruption.
$wugConnected = $false
if ($Action -and ($Action -eq 'PushToWUG' -or $Action -eq 'TestCredential')) {
    # Only prompt for WUG server if user didn't pass -WUGServer explicitly
    if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('WUGServer')) {
        Write-Host ""
        $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
        if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
            $WUGServer = $wugInput.Trim()
        }
    }

    # Resolve WUG credentials from vault or prompt
    $wugVaultName = "WUG.$WUGServer"
    if ($WUGCredential) {
        $wugCred = $WUGCredential
    }
    else {
        $wugSplat = @{
            Name      = $wugVaultName
            CredType  = 'WUGServer'
        }
        if ($NonInteractive) { $wugSplat.NonInteractive = $true }
        else { $wugSplat.AutoUse = $true }

        $wugResolved = Resolve-DiscoveryCredential @wugSplat
        if (-not $wugResolved) {
            if ($NonInteractive) {
                Write-Error "No WUG credentials in vault for '$wugVaultName'. Run interactively first, or pass -WUGCredential."
                return
            }
            Write-Error 'WUG credential resolution cancelled.'
            return
        }
        $wugCred = $wugResolved.Credential
        if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
    }
    Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors
    $wugConnected = $true
    Write-Host "  Connected to WUG server $WUGServer" -ForegroundColor Green
}

# ==============================================================================
# STEP 3: Discover — authenticate and enumerate Azure resources
# ==============================================================================
Write-Host ""
Write-Host "Authenticating to Azure tenant $TenantId..." -ForegroundColor Cyan

$bstrAz = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzureCred.Password)
try { $plainAzSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrAz) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrAz) }
$azParts = $AzureCred.UserName -split '\|'
$plan = Invoke-Discovery -ProviderName 'Azure' `
    -Target @($SubscriptionFilter) `
    -Credential @{ TenantId = $azParts[0]; ApplicationId = $azParts[1]; ClientSecret = $plainAzSecret; UseRestApi = $UseRestApi; MetricsTimespan = $MetricsTimespan }

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check service principal permissions and connectivity."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $resName = $item.Attributes['ComputedDisplayName']
    $key = "resource:$($item.Attributes['Azure Subscription ID']):$resName"

    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name     = $resName
            IP       = $item.Attributes['Azure.IPAddress']
            Type     = $item.Attributes['Cloud Type']
            Location = $item.Attributes['Azure Location']
            Sub      = $item.Attributes['Azure Subscription ID']
            RG       = $item.Attributes['Azure Resource Group']
            State    = $item.Attributes['Azure.State']
            Attrs    = $item.Attributes
            Items    = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$withIP    = @($devicePlan.Values | Where-Object { $_.IP })
$withoutIP = @($devicePlan.Values | Where-Object { -not $_.IP })

$activeCount = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
$perfCount   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count

$uniqueSubs = @($devicePlan.Values | ForEach-Object { $_.Sub } | Select-Object -Unique)
$uniqueRGs  = @($devicePlan.Values | ForEach-Object { $_.RG } | Select-Object -Unique)
$uniqueLocs = @($devicePlan.Values | ForEach-Object { $_.Location } | Select-Object -Unique)

# Count metrics from plan items
$resWithMetrics = @($devicePlan.Values | Where-Object { $_.Attrs['Azure.MetricCount'] }).Count

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Resources:             $($devicePlan.Count)" -ForegroundColor White
Write-Host "  Resources (with IP):   $($withIP.Count)" -ForegroundColor White
Write-Host "  Resources (no IP):     $($withoutIP.Count) (will be added as 0.0.0.0 cloud resources)" -ForegroundColor White
Write-Host "  Resources with metrics: $resWithMetrics" -ForegroundColor White
Write-Host "  Subscriptions:         $($uniqueSubs.Count)" -ForegroundColor White
Write-Host "  Resource Groups:       $($uniqueRGs.Count)" -ForegroundColor White
Write-Host "  Locations:             $($uniqueLocs.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitors (health):           $activeCount  ($($devicePlan.Count) assignments)" -ForegroundColor White
Write-Host "  Performance monitors (confirmed):   $perfCount  (idle metrics with no data in P1D window were dropped)" -ForegroundColor White
Write-Host "  Total plan items:                   $($plan.Count)" -ForegroundColor White
Write-Host ""

$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    Select-Object -First 50 |
    ForEach-Object {
        $mc = $_.Attrs['Azure.MetricCount']
        [PSCustomObject]@{
            Resource = $_.Name
            Type     = $_.Type
            IP       = if ($_.IP) { $_.IP } else { '0.0.0.0' }
            Location = $_.Location
            State    = $_.State
            Metrics  = if ($mc) { $mc } else { '0' }
            Monitors = $_.Items.Count
        }
    } |
    Format-Table -AutoSize

if ($devicePlan.Count -gt 50) {
    Write-Host "  ... and $($devicePlan.Count - 50) more resources (use option [4] to see all)" -ForegroundColor Gray
}

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================

# --- Map Action parameter to menu choice number ---
$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG'         { $choice = '1' }
        'ExportJSON'        { $choice = '2' }
        'ExportCSV'         { $choice = '3' }
        'ShowTable'         { $choice = '4' }
        'Dashboard'         { $choice = '5' }
        'MetricsDashboard'  { $choice = '8' }
        'TestCredential'    { $choice = '7' }
        'None'              { $choice = '6' }
        'DashboardAndPush'  { $choice = '9' }
    }
}

if (-not $choice -and $NonInteractive) { $choice = '5' }

if (-not $choice) {
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push ALL resources to WhatsUp Gold (cloud devices + REST API metrics monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate Azure HTML dashboard"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host "  [7] Test Azure credential in WUG (add + verify + remove)"
    Write-Host "  [8] Generate Validated Metrics HTML dashboard"
    Write-Host "  [9] Dashboard + Push to WUG"
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-9]"
}

# Handle DashboardAndPush: run Dashboard then PushToWUG sequentially
if ($choice -eq '9') {
    $actionsToRun = @('5', '1')
} else {
    $actionsToRun = @($choice)
}

foreach ($currentChoice in $actionsToRun) {
switch ($currentChoice) {
    '1' {
        # ==================================================================
        # PUSH TO WHATSUP GOLD
        #
        # Strategy:
        #   1. Connect to WUG
        #   2. Create Azure credential in WUG library from vault SP
        #   3. Add each resource as a "cloud resource" device (0.0.0.0 if
        #      no IP) with Azure attributes + AzureResourceID
        #   4. Assign the Azure credential to each device
        #   5. Create REST API monitors (active + perf) per metric
        #   6. Set device roles for Azure Cloud
        # ==================================================================
        if (-not $wugConnected) {
            if (-not $NonInteractive) {
                Write-Host ""
                $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
                if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
                    $WUGServer = $wugInput.Trim()
                }
            }

            # Resolve WUG credentials from vault or prompt
            $wugVaultName = "WUG.$WUGServer"
            if ($WUGCredential) {
                $wugCred = $WUGCredential
            }
            else {
                $wugSplat = @{
                    Name      = $wugVaultName
                    CredType  = 'WUGServer'
                }
                if ($NonInteractive) { $wugSplat.NonInteractive = $true }
                else { $wugSplat.AutoUse = $true }

                $wugResolved = Resolve-DiscoveryCredential @wugSplat
                if (-not $wugResolved) {
                    if ($NonInteractive) {
                        Write-Error "No WUG credentials in vault for '$wugVaultName'. Run interactively first, or pass -WUGCredential."
                        return
                    }
                    Write-Error 'WUG credential resolution cancelled.'
                    return
                }
                $wugCred = $wugResolved.Credential
                if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
            }
            Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors
        }

        # -- Step 1: Create Azure credential in WUG --------------------------
        Write-Host ""
        Write-Host "Creating Azure credential in WUG..." -ForegroundColor Cyan

        $azCredName = "Azure SP - $TenantId"
        $wugAzCredId = $null

        # Check if credential already exists
        try {
            $existingCreds = @(Get-WUGCredential -Type azure)
            $matchCred = $existingCreds | Where-Object { $_.name -eq $azCredName } | Select-Object -First 1
            if ($matchCred) {
                $wugAzCredId = $matchCred.id
                Write-Host "  Found existing Azure credential '$azCredName' (ID: $wugAzCredId)" -ForegroundColor Green
            }
        }
        catch { Write-Verbose "Credential search returned error: $_" }

        if (-not $wugAzCredId) {
            # Extract SP credentials from vault
            $bstrWugAz = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzureCred.Password)
            try { $plainWugAzSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrWugAz) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrWugAz) }
            $wugAzParts = $AzureCred.UserName -split '\|'

            try {
                $credResult = Add-WUGCredential -Name $azCredName `
                    -Description "Azure Service Principal for tenant $TenantId (auto-created by discovery)" `
                    -Type azure `
                    -AzureSecureKey $plainWugAzSecret `
                    -AzureTenantID $wugAzParts[0] `
                    -AzureClientID $wugAzParts[1]

                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) {
                        $wugAzCredId = $credResult.data.idMap.resultId
                    }
                    elseif ($credResult.PSObject.Properties['resourceId']) {
                        $wugAzCredId = $credResult.resourceId
                    }
                    elseif ($credResult.PSObject.Properties['id']) {
                        $wugAzCredId = $credResult.id
                    }
                }
                Write-Host "  Created Azure credential '$azCredName' (ID: $wugAzCredId)" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to create Azure credential in WUG: $_"
                Write-Host "  Monitors will be created but may need manual credential assignment." -ForegroundColor Yellow
            }

        }

        # -- Step 1b: Create REST API credential (OAuth2) in WUG --------------
        Write-Host ""
        Write-Host "Creating REST API (OAuth2) credential in WUG..." -ForegroundColor Cyan

        $restCredName = "Azure REST API - $TenantId"
        $wugRestCredId = $null

        # Search for existing REST API credentials — first exact name, then any with 'azure' in name
        try {
            $existingRestCreds = @(Get-WUGCredential -Type restapi -View details)
            # 1) Exact name match
            $matchRestCred = $existingRestCreds | Where-Object { $_.name -eq $restCredName } | Select-Object -First 1
            if ($matchRestCred) {
                $wugRestCredId = $matchRestCred.id
                Write-Host "  Found existing REST API credential '$restCredName' (ID: $wugRestCredId)" -ForegroundColor Green
            }
            else {
                # 2) Any REST API credential with 'azure' in the name
                $azureRestCred = $existingRestCreds | Where-Object { $_.name -match 'azure' } | Select-Object -First 1
                if ($azureRestCred) {
                    $wugRestCredId = $azureRestCred.id
                    $restCredName = $azureRestCred.name
                    Write-Host "  Found existing Azure REST API credential '$restCredName' (ID: $wugRestCredId)" -ForegroundColor Green
                }
            }
        }
        catch { Write-Verbose "REST API credential search returned error: $_" }

        if (-not $wugRestCredId) {
            # No existing credential found — try to create one
            $bstrRestAz = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzureCred.Password)
            try { $plainRestAzSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrRestAz) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrRestAz) }
            $restAzParts = $AzureCred.UserName -split '\|'

            try {
                $restCredResult = Add-WUGCredential -Name $restCredName `
                    -Description "Azure OAuth2 client_credentials for tenant $TenantId (auto-created by discovery)" `
                    -Type restapi `
                    -RestApiAuthType '1' `
                    -RestApiGrantType '0' `
                    -RestApiTokenUrl "https://login.microsoftonline.com/$($restAzParts[0])/oauth2/v2.0/token" `
                    -RestApiClientId $restAzParts[1] `
                    -RestApiClientSecret $plainRestAzSecret `
                    -RestApiScope 'https://management.azure.com/.default'

                if ($restCredResult) {
                    if ($restCredResult.PSObject.Properties['data']) {
                        $wugRestCredId = $restCredResult.data.idMap.resultId
                    }
                    elseif ($restCredResult.PSObject.Properties['resourceId']) {
                        $wugRestCredId = $restCredResult.resourceId
                    }
                    elseif ($restCredResult.PSObject.Properties['id']) {
                        $wugRestCredId = $restCredResult.id
                    }
                }
                if ($wugRestCredId) {
                    Write-Host "  Created REST API credential '$restCredName' (ID: $wugRestCredId)" -ForegroundColor Green
                }
                else {
                    Write-Warning "Add-WUGCredential returned no ID for REST API credential."
                }
            }
            catch {
                # Creation failed (likely 400 = duplicate name) — re-search
                Write-Verbose "REST API credential create failed: $_ — re-searching..."
                try {
                    $allCreds = @(Get-WUGCredential -View details)
                    # Try exact name first, then any with 'azure' in name
                    $matchRetry = $allCreds | Where-Object { $_.name -eq $restCredName } | Select-Object -First 1
                    if (-not $matchRetry) {
                        $matchRetry = $allCreds | Where-Object { $_.name -match 'azure' -and $_.type -eq 'restapi' } | Select-Object -First 1
                    }
                    if (-not $matchRetry) {
                        $matchRetry = $allCreds | Where-Object { $_.name -match 'azure' } | Select-Object -First 1
                    }
                    if ($matchRetry) {
                        $wugRestCredId = $matchRetry.id
                        $restCredName = $matchRetry.name
                        Write-Host "  Found existing REST API credential '$restCredName' (ID: $wugRestCredId)" -ForegroundColor Green
                    }
                    else {
                        Write-Warning "Failed to create REST API credential and cannot find existing one."
                    }
                }
                catch {
                    Write-Warning "Failed to search for REST API credential in WUG: $_"
                }
            }

            # Clean up secret from memory
            $plainRestAzSecret = $null
        }

        # Clean up Azure secret from memory (deferred from Step 1)
        $plainWugAzSecret = $null

        # -- Step 2: Bulk create monitors + devices --------------------------------
        # Strategy:
        #   2a. Collect all unique active (health) monitors → create in library
        #   2b. Collect all unique perf monitors → create in library (no DeviceId)
        #   2c. Identify existing vs new devices
        #   2d. Build device templates for new devices with monitor names → Add-WUGDeviceTemplates (bulk PATCH)
        #   2e. Handle existing devices (cred assign + monitor catch-up)
        Write-Host ""
        Write-Host "Preparing bulk operations..." -ForegroundColor Cyan

        $stats = @{
            DevicesCreated  = 0
            DevicesFound    = 0
            CloudDevices    = 0
            CredsAssigned   = 0
            HealthCreated   = 0
            HealthSkipped   = 0
            HealthFailed    = 0
            PerfCreated     = 0
            PerfSkipped     = 0
            PerfFailed      = 0
        }
        $wugDeviceMap = @{}
        $deviceKeys = @($devicePlan.Keys)
        $devTotal = $deviceKeys.Count

        # ---- 2a: Create active (health) monitors in library --------------------
        Write-Host "  Creating active monitors in library..." -ForegroundColor Cyan
        $uniqueActiveMonitors = @{}  # monitorName -> item (deduplicated)
        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                $actName = $actItem.Name
                if (-not $actName -or $uniqueActiveMonitors.ContainsKey($actName)) { continue }
                if (-not $actItem.MonitorParams -or $actItem.MonitorParams.Count -eq 0) { continue }
                $uniqueActiveMonitors[$actName] = $actItem
            }
        }

        # Check which already exist in library
        $existingActiveNames = @{}  # name -> monitor library id
        foreach ($actName in @($uniqueActiveMonitors.Keys)) {
            try {
                $found = @(Get-WUGActiveMonitor -Search $actName)
                $exact = $found | Where-Object { $_.name -eq $actName } | Select-Object -First 1
                if ($exact) {
                    $existingActiveNames[$actName] = [int]$exact.id
                    $stats.HealthSkipped++
                }
            }
            catch { }
        }

        # Create missing active monitors via bulk Add-WUGMonitorTemplate
        $toCreateActive = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        if ($toCreateActive.Count -gt 0) {
            Write-Host "    Creating $($toCreateActive.Count) new active monitors (bulk)..." -ForegroundColor DarkGray

            # Build template objects for the bulk API
            $activeTemplates = @()
            $actTplIdMap = @{}  # templateId -> monitorName
            $actTplIdx = 0
            foreach ($actName in $toCreateActive) {
                $actItem = $uniqueActiveMonitors[$actName]
                $mp = $actItem.MonitorParams
                $tplId = "act_$actTplIdx"
                $actTplIdMap[$tplId] = $actName
                $actTplIdx++

                # Map RestApi params to property bags (all health monitors are RestApi type)
                $bags = @(
                    @{ name = 'MonRestApi:RestUrl';                 value = "$($mp.RestApiUrl)" }
                    @{ name = 'MonRestApi:HttpMethod';              value = if ($mp.RestApiMethod) { "$($mp.RestApiMethod)" } else { 'GET' } }
                    @{ name = 'MonRestApi:HttpTimeoutMs';           value = if ($mp.RestApiTimeoutMs) { "$($mp.RestApiTimeoutMs)" } else { '10000' } }
                    @{ name = 'MonRestApi:IgnoreCertErrors';        value = '0' }
                    @{ name = 'MonRestApi:UseAnonymousAccess';      value = if ($mp.RestApiUseAnonymous) { "$($mp.RestApiUseAnonymous)" } else { '0' } }
                    @{ name = 'MonRestApi:CustomHeader';            value = '' }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn';  value = if ($mp.RestApiDownIfResponseCodeIsIn) { "$($mp.RestApiDownIfResponseCodeIsIn)" } else { '[]' } }
                    @{ name = 'MonRestApi:ComparisonList';          value = if ($mp.RestApiComparisonList) { "$($mp.RestApiComparisonList)" } else { '[]' } }
                    @{ name = 'Cred:Type';                          value = '8192' }
                )

                $activeTemplates += @{
                    templateId      = $tplId
                    name            = $actName
                    description     = 'RestApi Monitor created via Add-WUGActiveMonitor function'
                    useInDiscovery  = $false
                    monitorTypeInfo = @{
                        baseType = 'active'
                        classId  = 'f0610672-d515-4268-bd21-ac5ebb1476ff'
                    }
                    propertyBags    = $bags
                }
            }

            try {
                # Batch into groups of 50 to avoid overloading WUG
                $batchSize = 50
                for ($bi = 0; $bi -lt $activeTemplates.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $activeTemplates.Count - 1)
                    $actBatch = @($activeTemplates[$bi..$batchEnd])
                    if ($activeTemplates.Count -gt $batchSize) {
                        $batchNum = [Math]::Floor($bi / $batchSize) + 1
                        $totalBatches = [Math]::Ceiling($activeTemplates.Count / $batchSize)
                        Write-Host "      Batch $batchNum/$totalBatches ($($actBatch.Count) monitors)..." -ForegroundColor DarkGray
                    }

                    $bulkActResult = Add-WUGMonitorTemplate -ActiveMonitors $actBatch
                    if ($bulkActResult.idMap) {
                        foreach ($mapping in $bulkActResult.idMap) {
                            $tplId = $mapping.templateId
                            $resultId = $mapping.resultId
                            if ($actTplIdMap.ContainsKey($tplId) -and $resultId) {
                                $actName = $actTplIdMap[$tplId]
                                $existingActiveNames[$actName] = [int]$resultId
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

                    if ($batchEnd -lt $activeTemplates.Count - 1) {
                        Start-Sleep -Seconds 2
                    }
                }
            }
            catch {
                Write-Warning "Bulk active monitor creation failed, falling back to one-at-a-time: $_"
                # Fallback: create one at a time
                $actIdx = 0
                foreach ($actName in $toCreateActive) {
                    if ($existingActiveNames.ContainsKey($actName)) { continue }
                    $actIdx++
                    $actItem = $uniqueActiveMonitors[$actName]
                    Write-Progress -Activity 'Creating Active Monitors' `
                        -Status "$actIdx / $($toCreateActive.Count) - $actName" `
                        -PercentComplete ([Math]::Round(($actIdx / $toCreateActive.Count) * 100))
                    try {
                        $actParams = @{
                            Type        = $actItem.MonitorType
                            Name        = $actName
                            ErrorAction = 'Stop'
                        }
                        foreach ($ak in $actItem.MonitorParams.Keys) {
                            if ($ak -ne 'Name' -and $ak -ne 'Description') {
                                $actParams[$ak] = $actItem.MonitorParams[$ak]
                            }
                        }
                        $monLibId = Add-WUGActiveMonitor @actParams
                        if ($monLibId) {
                            $existingActiveNames[$actName] = [int]$monLibId
                            $stats.HealthCreated++
                        }
                    }
                    catch {
                        Write-Warning "Failed to create active monitor '$actName': $_"
                        $stats.HealthFailed++
                    }
                }
                Write-Progress -Activity 'Creating Active Monitors' -Completed
            }
        }
        Write-Host "    Active monitors: $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor DarkGray

        # Reconcile: re-query library to catch monitors the bulk creation tracking may have missed
        try {
            $allAzureHealth = @(Get-WUGActiveMonitor -Search 'Azure Health -')
            $reconciled = 0
            foreach ($am in $allAzureHealth) {
                if ($am.name -and -not $existingActiveNames.ContainsKey($am.name)) {
                    $existingActiveNames[$am.name] = [int]$am.id
                    $reconciled++
                }
            }
            if ($reconciled -gt 0) {
                Write-Host "    Reconciled $reconciled active monitors from library" -ForegroundColor DarkGray
            }
        }
        catch { Write-Verbose "Active monitor reconciliation query failed: $_" }

        # ---- 2b: Create perf monitors in library (no DeviceId) -----------------
        Write-Host "  Creating performance monitors in library..." -ForegroundColor Cyan
        $uniquePerfMonitors = @{}  # monitorName -> item (deduplicated)
        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                $monName = $perfItem.Name
                if (-not $monName -or $uniquePerfMonitors.ContainsKey($monName)) { continue }
                $uniquePerfMonitors[$monName] = $perfItem
            }
        }

        # Check which already exist in library
        $existingPerfNames = @{}  # name -> monitor library id
        try {
            $libPerf = @(Get-WUGPerformanceMonitor -Search 'Azure -')
            foreach ($lp in $libPerf) {
                if ($lp.name) { $existingPerfNames[$lp.name] = $lp.id }
            }
        }
        catch { Write-Verbose "Could not query perf monitor library: $_" }

        $toCreatePerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        $perfAlreadyExist = $uniquePerfMonitors.Count - $toCreatePerf.Count
        $stats.PerfSkipped += $perfAlreadyExist

        # Create missing perf monitors via bulk Add-WUGMonitorTemplate (library-only, no DeviceId)
        if ($toCreatePerf.Count -gt 0) {
            Write-Host "    Creating $($toCreatePerf.Count) new perf monitors (bulk)..." -ForegroundColor DarkGray

            # Build template objects for the bulk API
            $perfTemplates = @()
            $perfTplIdMap = @{}  # templateId -> monitorName
            $perfTplIdx = 0
            foreach ($monName in $toCreatePerf) {
                $perfItem = $uniquePerfMonitors[$monName]
                $mp = $perfItem.MonitorParams
                $tplId = "perf_$perfTplIdx"
                $perfTplIdMap[$tplId] = $monName
                $perfTplIdx++

                # Map RestApi params to property bags (all perf monitors are RestApi type)
                $bags = @(
                    @{ name = 'RdcRestApi:RestUrl';            value = "$($mp.RestApiUrl)" }
                    @{ name = 'RdcRestApi:JsonPath';           value = "$($mp.RestApiJsonPath)" }
                    @{ name = 'RdcRestApi:HttpMethod';         value = if ($mp.RestApiHttpMethod) { "$($mp.RestApiHttpMethod)" } else { 'GET' } }
                    @{ name = 'RdcRestApi:HttpTimeoutMs';      value = if ($mp.RestApiHttpTimeoutMs) { "$($mp.RestApiHttpTimeoutMs)" } else { '10000' } }
                    @{ name = 'RdcRestApi:IgnoreCertErrors';   value = '0' }
                    @{ name = 'RdcRestApi:UseAnonymousAccess'; value = if ($mp.RestApiUseAnonymousAccess) { "$($mp.RestApiUseAnonymousAccess)" } else { '0' } }
                    @{ name = 'RdcRestApi:CustomHeader';       value = '' }
                )

                $perfTemplates += @{
                    templateId      = $tplId
                    name            = $monName
                    description     = 'RestApi performance monitor created via Add-WUGPerformanceMonitor'
                    monitorTypeInfo = @{
                        baseType = 'performance'
                        classId  = '987bb6a4-70f4-4f46-97c6-1c9dd1766437'
                    }
                    propertyBags    = $bags
                }
            }

            try {
                # Batch into groups of 50 to avoid overloading WUG
                $batchSize = 50
                for ($bi = 0; $bi -lt $perfTemplates.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $perfTemplates.Count - 1)
                    $perfBatch = @($perfTemplates[$bi..$batchEnd])
                    $batchNum = [Math]::Floor($bi / $batchSize) + 1
                    $totalBatches = [Math]::Ceiling($perfTemplates.Count / $batchSize)
                    Write-Host "      Batch $batchNum/$totalBatches ($($perfBatch.Count) monitors)..." -ForegroundColor DarkGray

                    $bulkPerfResult = Add-WUGMonitorTemplate -PerformanceMonitors $perfBatch
                    if ($bulkPerfResult.idMap) {
                        foreach ($mapping in $bulkPerfResult.idMap) {
                            $tplId = $mapping.templateId
                            $resultId = $mapping.resultId
                            if ($perfTplIdMap.ContainsKey($tplId) -and $resultId) {
                                $monName = $perfTplIdMap[$tplId]
                                $existingPerfNames[$monName] = "$resultId"
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

                    # Brief pause between batches to let WUG process
                    if ($batchEnd -lt $perfTemplates.Count - 1) {
                        Start-Sleep -Seconds 2
                    }
                }
            }
            catch {
                Write-Warning "Bulk perf monitor creation failed, falling back to one-at-a-time: $_"
                # Fallback: create one at a time
                $perfIdx = 0
                foreach ($monName in $toCreatePerf) {
                    if ($existingPerfNames.ContainsKey($monName)) { continue }
                    $perfIdx++
                    $perfItem = $uniquePerfMonitors[$monName]
                    Write-Progress -Activity 'Creating Perf Monitors' `
                        -Status "$perfIdx / $($toCreatePerf.Count)" `
                        -PercentComplete ([Math]::Round(($perfIdx / $toCreatePerf.Count) * 100))
                    try {
                        $perfParams = @{
                            Type        = $perfItem.MonitorType
                            Name        = $monName
                            ErrorAction = 'Stop'
                        }
                        foreach ($pk in $perfItem.MonitorParams.Keys) {
                            if ($pk -notin @('Name', 'Description', 'LastValue', 'LastTimestamp', 'MetricUnit') -and $pk -notlike '_*') {
                                $perfParams[$pk] = $perfItem.MonitorParams[$pk]
                            }
                        }
                        $result = Add-WUGPerformanceMonitor @perfParams
                        if ($result -and $result.MonitorId) {
                            $existingPerfNames[$monName] = "$($result.MonitorId)"
                            $stats.PerfCreated++
                        }
                    }
                    catch {
                        if ($_.Exception.Message -match 'already exists|duplicate') {
                            $stats.PerfSkipped++
                        }
                        else {
                            Write-Verbose "Failed to create perf monitor '$monName': $($_.Exception.Message)"
                            $stats.PerfFailed++
                        }
                    }
                }
                Write-Progress -Activity 'Creating Perf Monitors' -Completed
            }
        }
        Write-Host "    Perf monitors: $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor DarkGray

        # Reconcile: re-query library to catch perf monitors the bulk creation tracking may have missed
        try {
            $libPerfAll = @(Get-WUGPerformanceMonitor -Search 'Azure -')
            $reconciledPerf = 0
            foreach ($lp in $libPerfAll) {
                if ($lp.name -and -not $existingPerfNames.ContainsKey($lp.name)) {
                    $existingPerfNames[$lp.name] = "$($lp.id)"
                    $reconciledPerf++
                }
            }
            if ($reconciledPerf -gt 0) {
                Write-Host "    Reconciled $reconciledPerf perf monitors from library" -ForegroundColor DarkGray
            }
        }
        catch { Write-Verbose "Perf monitor reconciliation query failed: $_" }

        # ---- 2c: Identify existing vs new devices ------------------------------
        Write-Host "  Checking for existing devices..." -ForegroundColor Cyan
        $existingDevices = @{}   # key -> deviceId
        $newDeviceKeys   = [System.Collections.Generic.List[string]]::new()

        $devIdx = 0
        foreach ($key in $deviceKeys) {
            $devIdx++
            $dev = $devicePlan[$key]
            $addIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
            $displayName = "$($dev.Name) ($($dev.Type))"

            Write-Progress -Activity 'Checking existing devices' `
                -Status "$devIdx / $devTotal - $($dev.Name)" `
                -PercentComplete ([Math]::Round(($devIdx / $devTotal) * 100))

            $deviceId = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.displayName -eq $dev.Name -or
                        $_.displayName -eq $displayName -or
                        $_.hostName -eq $dev.Name
                    } | Select-Object -First 1
                    if ($existingDevice) { $deviceId = $existingDevice.id }
                }
                if (-not $deviceId -and $dev.IP) {
                    $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                    if ($searchResults.Count -gt 0) {
                        $match = $searchResults | Where-Object {
                            $_.networkAddress -eq $addIP -or $_.hostName -eq $addIP
                        } | Select-Object -First 1
                        if ($match) { $deviceId = $match.id }
                    }
                }
            }
            catch { Write-Verbose "Search for '$($dev.Name)' returned error: $_" }

            if ($deviceId) {
                $existingDevices[$key] = $deviceId
                $wugDeviceMap[$key] = $deviceId
                $stats.DevicesFound++
            }
            else {
                if ($dev.Name) {
                    $newDeviceKeys.Add($key)
                }
            }
        }
        Write-Progress -Activity 'Checking existing devices' -Completed
        Write-Host "    Found $($stats.DevicesFound) existing, $($newDeviceKeys.Count) new to create" -ForegroundColor DarkGray

        # ---- 2d: Create devices one by one via Add-WUGDeviceTemplate -----------
        if ($newDeviceKeys.Count -gt 0) {
            Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow
            $devIdx = 0

            foreach ($key in $newDeviceKeys) {
                $devIdx++
                $dev = $devicePlan[$key]
                $addIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
                $displayName = "$($dev.Name) ($($dev.Type))"

                Write-Progress -Activity 'Creating devices' `
                    -Status "$devIdx / $($newDeviceKeys.Count) - $displayName" `
                    -PercentComplete ([Math]::Round(($devIdx / $newDeviceKeys.Count) * 100))

                # Build attributes array
                $devAttrs = @()
                foreach ($attrName in $dev.Attrs.Keys) {
                    $attrVal = $dev.Attrs[$attrName]
                    if ($attrVal) { $devAttrs += @{ name = $attrName; value = "$attrVal" } }
                }

                # Collect unique active monitor names
                $actNames = @()
                $seenActNames = @{}
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name) -and -not $seenActNames.ContainsKey($actItem.Name)) {
                        $actNames += $actItem.Name
                        $seenActNames[$actItem.Name] = $true
                    }
                }

                # Collect unique performance monitor names
                $perfNames = @()
                $seenPerfNames = @{}
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name) -and -not $seenPerfNames.ContainsKey($perfItem.Name)) {
                        $perfNames += $perfItem.Name
                        $seenPerfNames[$perfItem.Name] = $true
                    }
                }

                # Cap performance monitors per device if limit is set
                if ($MaxPerformanceMonitorsPerDevice -gt 0 -and $perfNames.Count -gt $MaxPerformanceMonitorsPerDevice) {
                    Write-Verbose "Capping perf monitors for '$displayName': $($perfNames.Count) -> $MaxPerformanceMonitorsPerDevice"
                    $perfNames = $perfNames | Select-Object -First $MaxPerformanceMonitorsPerDevice
                }

                # Skip devices with no monitors at all
                if ($actNames.Count -eq 0 -and $perfNames.Count -eq 0) {
                    Write-Verbose "Skipping '$displayName' — no monitors to assign."
                    continue
                }

                $devNote = "Azure $($dev.Type) cloud resource (auto-created by discovery)"

                # Build splat for Add-WUGDeviceTemplate
                $splat = @{
                    displayName   = $displayName
                    DeviceAddress = $addIP
                    Hostname      = $dev.Name
                    Brand         = 'Azure'
                    Note          = $devNote
                }

                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($azCredName -and $wugAzCredId)    { $splat['CredentialAzure']   = $azCredName }
                if ($restCredName -and $wugRestCredId) { $splat['CredentialRestApi'] = $restCredName }

                if ($actNames.Count -gt 0) {
                    $splat['ActiveMonitors'] = $actNames
                } else {
                    # No health monitor for this resource type — skip default Ping
                    $splat['NoDefaultActiveMonitor'] = $true
                }

                if ($perfNames.Count -gt 0) {
                    # Don't include perf monitors in the device template — the template API
                    # doesn't support pollingIntervalMinutes, so monitors get the default 10 min.
                    # Instead we assign them separately after creation using
                    # Add-WUGPerformanceMonitorToDevice which properly sets the polling interval.
                }

                try {
                    $devResult = Add-WUGDeviceTemplate @splat

                    if ($devResult -and -not $devResult.error) {
                        # Extract device ID from result
                        $newDeviceId = $null
                        if ($devResult.idMap) {
                            $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId
                        } elseif ($devResult.PSObject.Properties['resultId']) {
                            $newDeviceId = $devResult.resultId
                        }
                        if ($newDeviceId) {
                            $wugDeviceMap[$key] = $newDeviceId

                            # Assign perf monitors separately with 60-min interval
                            if ($perfNames.Count -gt 0) {
                                $perfMonIds = @()
                                foreach ($pn in $perfNames) {
                                    if ($existingPerfNames.ContainsKey($pn)) {
                                        $perfMonIds += [int]$existingPerfNames[$pn]
                                    }
                                }
                                if ($perfMonIds.Count -gt 0) {
                                    try {
                                        Add-WUGPerformanceMonitorToDevice -DeviceId $newDeviceId -MonitorId $perfMonIds -PollingIntervalMinutes 60 -ErrorAction Stop
                                    }
                                    catch {
                                        Write-Verbose "Perf monitor assign error for new device $newDeviceId`: $_"
                                    }
                                }
                            }
                        }
                        $stats.DevicesCreated++
                        if (-not $dev.IP) { $stats.CloudDevices++ }
                        Write-Verbose "Created device '$displayName' (ID: $newDeviceId)"
                    } else {
                        $errMsg = if ($devResult.error) { $devResult.error } else { 'Unknown error' }
                        Write-Warning "Failed to create device '$displayName': $errMsg"
                    }
                }
                catch {
                    Write-Warning "Error creating device '$displayName': $_"
                }
            }

            Write-Progress -Activity 'Creating devices' -Completed
            Write-Host "    Devices: $($stats.DevicesCreated) created ($($stats.CloudDevices) cloud)" -ForegroundColor Green
        }

        # ---- 2e: Handle existing devices (credential + monitor assignment) -----
        if ($existingDevices.Count -gt 0) {
            Write-Host "  Updating $($existingDevices.Count) existing devices (credentials + monitors)..." -ForegroundColor Cyan
            $existIdx = 0
            foreach ($key in $existingDevices.Keys) {
                $existIdx++
                $deviceId = [int]$existingDevices[$key]
                $dev = $devicePlan[$key]

                Write-Progress -Activity 'Updating existing devices' `
                    -Status "$existIdx / $($existingDevices.Count) - $($dev.Name)" `
                    -PercentComplete ([Math]::Round(($existIdx / $existingDevices.Count) * 100))

                # Assign credentials
                if ($wugAzCredId) {
                    try {
                        $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $wugAzCredId -Assign
                        $stats.CredsAssigned++
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Azure credential assign error for device $deviceId`: $_"
                        }
                    }
                }
                if ($wugRestCredId) {
                    try {
                        $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $wugRestCredId -Assign
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "REST API credential assign error for device $deviceId`: $_"
                        }
                    }
                }

                # Assign active monitors via Add-WUGActiveMonitorToDevice
                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) {
                        $actMonitorIds += $existingActiveNames[$actItem.Name]
                    }
                }
                if ($actMonitorIds.Count -gt 0) {
                    try {
                        Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $actMonitorIds -ErrorAction Stop
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Active monitor assign error for device $deviceId`: $_"
                        }
                    }
                }

                # Assign perf monitors via Add-WUGPerformanceMonitorToDevice
                $perfMonitorIds = @()
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name)) {
                        $perfMonitorIds += [int]$existingPerfNames[$perfItem.Name]
                    }
                }
                # Cap performance monitors per device if limit is set
                if ($MaxPerformanceMonitorsPerDevice -gt 0 -and $perfMonitorIds.Count -gt $MaxPerformanceMonitorsPerDevice) {
                    Write-Verbose "Capping perf monitors for existing device $deviceId`: $($perfMonitorIds.Count) -> $MaxPerformanceMonitorsPerDevice"
                    $perfMonitorIds = $perfMonitorIds | Select-Object -First $MaxPerformanceMonitorsPerDevice
                }
                if ($perfMonitorIds.Count -gt 0) {
                    try {
                        Add-WUGPerformanceMonitorToDevice -DeviceId $deviceId -MonitorId $perfMonitorIds -PollingIntervalMinutes 60 -ErrorAction Stop
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Perf monitor assign error for device $deviceId`: $_"
                        }
                    }
                }
            }
            Write-Progress -Activity 'Updating existing devices' -Completed
        }

        Write-Host ""
        Write-Host "=== WUG Push Complete ===" -ForegroundColor Green
        Write-Host "  Devices: $($stats.DevicesCreated) created ($($stats.CloudDevices) cloud), $($stats.DevicesFound) existing" -ForegroundColor White
        Write-Host "  Azure credential:             $(if ($wugAzCredId) { $wugAzCredId } else { 'FAILED' })" -ForegroundColor $(if ($wugAzCredId) { 'White' } else { 'Red' })
        Write-Host "  REST API credential:          $(if ($wugRestCredId) { $wugRestCredId } else { 'FAILED' })" -ForegroundColor $(if ($wugRestCredId) { 'White' } else { 'Red' })
        Write-Host "  Credentials assigned:         $($stats.CredsAssigned) (existing devices)" -ForegroundColor White
        Write-Host "  Health monitors created:      $($stats.HealthCreated)" -ForegroundColor White
        Write-Host "  Health monitors skipped:      $($stats.HealthSkipped) (already exist)" -ForegroundColor White
        if ($stats.HealthFailed -gt 0) {
            Write-Host "  Health monitors failed:       $($stats.HealthFailed)" -ForegroundColor Red
        }
        Write-Host "  Performance monitors created: $($stats.PerfCreated)" -ForegroundColor White
        Write-Host "  Performance monitors skipped: $($stats.PerfSkipped) (already exist)" -ForegroundColor White
        if ($stats.PerfFailed -gt 0) {
            Write-Host "  Performance monitors failed:  $($stats.PerfFailed)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Done! Azure cloud resources and monitors pushed to WhatsUp Gold." -ForegroundColor Green
        Write-Host "  Each resource has Azure + REST API credentials, REST API health monitor, and REST API performance monitors." -ForegroundColor DarkGray
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'azure-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'azure-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate Azure HTML Dashboard from plan data (no re-fetch)
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dp = $devicePlan[$key]
            $a  = $dp.Attrs

            # Build CloudResourceID for display
            $cloudResId = if ($a['SYS:CloudResourceID']) { $a['SYS:CloudResourceID'] } else { '' }
            $azureResId = if ($a['SYS:AzureResourceID']) { $a['SYS:AzureResourceID'] } else { '' }

            $dashboardRows += [PSCustomObject]@{
                ResourceName      = $dp.Name
                ResourceType      = $dp.Type
                ProvisioningState = $dp.State
                IPAddress         = if ($dp.IP) { $dp.IP } else { '0.0.0.0' }
                Location          = $dp.Location
                Subscription      = $dp.Sub
                ResourceGroup     = $dp.RG
                Kind              = if ($a['Azure.Kind']) { $a['Azure.Kind'] } else { 'N/A' }
                Sku               = if ($a['Azure.Sku']) { $a['Azure.Sku'] } else { 'N/A' }
                MetricCount       = if ($a['Azure.MetricCount']) { $a['Azure.MetricCount'] } else { '0' }
                Tags              = if ($a['Azure.Tags']) { $a['Azure.Tags'] } else { '' }
                CloudResourceID   = $cloudResId
                AzureResourceID   = $azureResId
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashReportTitle = "Azure Dashboard"
            $dashTempPath = Join-Path $OutputDir 'Azure-Dashboard.html'

            $null = Export-AzureDiscoveryDashboardHtml `
                -DashboardData $dashboardRows `
                -OutputPath $dashTempPath `
                -ReportTitle $dashReportTitle

            Write-Host ""
            Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
            $dSucceeded = @($dashboardRows | Where-Object { $_.ProvisioningState -eq 'Succeeded' }).Count
            $dOther     = $dashboardRows.Count - $dSucceeded
            Write-Host "  Resources: $($dashboardRows.Count)  |  Succeeded: $dSucceeded  |  Other: $dOther" -ForegroundColor White

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashPath = Join-Path $nmConsolePath 'Azure-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/Azure-Dashboard.html" -ForegroundColor Cyan
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
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\Azure-Dashboard.html'" -ForegroundColor Cyan
            }
        }
    }
    '7' {
        # ==================================================================
        # TEST CREDENTIAL: Add Azure credential to WUG, verify, then remove
        # ==================================================================
        Write-Host ""
        Write-Host "=== Azure Credential Test ===" -ForegroundColor Cyan
        Write-Host "  This will:" -ForegroundColor White
        Write-Host "    1. Create a test Azure credential in WUG" -ForegroundColor White
        Write-Host "    2. Verify it was created successfully" -ForegroundColor White
        Write-Host "    3. Delete the test credential" -ForegroundColor White
        Write-Host ""

        if (-not $wugConnected) {
            if (-not $NonInteractive) {
                $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
                if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
                    $WUGServer = $wugInput.Trim()
                }
            }

            # Resolve WUG credentials from vault or prompt
            $wugVaultName = "WUG.$WUGServer"
            if ($WUGCredential) {
                $wugCred = $WUGCredential
            }
            else {
                $wugSplat = @{
                    Name      = $wugVaultName
                    CredType  = 'WUGServer'
                }
                if ($NonInteractive) { $wugSplat.NonInteractive = $true }
                else { $wugSplat.AutoUse = $true }

                $wugResolved = Resolve-DiscoveryCredential @wugSplat
                if (-not $wugResolved) {
                    if ($NonInteractive) {
                        Write-Error "No WUG credentials in vault for '$wugVaultName'. Run interactively first, or pass -WUGCredential."
                        return
                    }
                    Write-Error 'WUG credential resolution cancelled.'
                    return
                }
                $wugCred = $wugResolved.Credential
                if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
            }
            Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors
        }

        $testCredName = "Azure Test - $(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $testPassed = $true

        # Step 1: Create test Azure credential
        Write-Host ""
        Write-Host "Step 1: Creating test Azure credential '$testCredName'..." -ForegroundColor Cyan
        $bstrTest = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzureCred.Password)
        try { $plainTestSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrTest) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrTest) }
        $testParts = $AzureCred.UserName -split '\|'
        $testCredId = $null

        try {
            $testResult = Add-WUGCredential -Name $testCredName `
                -Description 'Temporary test credential -- safe to delete' `
                -Type azure `
                -AzureSecureKey $plainTestSecret `
                -AzureTenantID $testParts[0] `
                -AzureClientID $testParts[1]

            if ($testResult) {
                if ($testResult.PSObject.Properties['data']) {
                    $testCredId = $testResult.data.idMap.resultId
                }
                elseif ($testResult.PSObject.Properties['resourceId']) {
                    $testCredId = $testResult.resourceId
                }
                elseif ($testResult.PSObject.Properties['id']) {
                    $testCredId = $testResult.id
                }
            }
            $plainTestSecret = $null

            if ($testCredId) {
                Write-Host "  PASS: Created credential ID: $testCredId" -ForegroundColor Green
            }
            else {
                Write-Host "  FAIL: Credential created but could not extract ID from response." -ForegroundColor Red
                Write-Host "  Response: $($testResult | ConvertTo-Json -Depth 3 -Compress)" -ForegroundColor DarkGray
                $testPassed = $false
            }
        }
        catch {
            Write-Host "  FAIL: $($_)" -ForegroundColor Red
            $testPassed = $false
            $plainTestSecret = $null
        }

        # Step 2: Verify credential exists
        if ($testCredId) {
            Write-Host ""
            Write-Host "Step 2: Verifying credential exists..." -ForegroundColor Cyan
            try {
                $verifyCred = Get-WUGCredential -CredentialId $testCredId
                if ($verifyCred) {
                    Write-Host "  PASS: Found credential '$($verifyCred.name)' (type: $($verifyCred.type))" -ForegroundColor Green
                }
                else {
                    Write-Host "  FAIL: Credential ID $testCredId not found." -ForegroundColor Red
                    $testPassed = $false
                }
            }
            catch {
                Write-Host "  FAIL: Could not verify credential: $_" -ForegroundColor Red
                $testPassed = $false
            }
        }

        # Step 3: Delete test credentials
        Write-Host ""
        Write-Host "Step 3: Deleting test credentials..." -ForegroundColor Cyan
        if ($testCredId) {
            try {
                $delResult = Set-WUGCredential -CredentialId $testCredId -Remove -Confirm:$false
                Write-Host "  PASS: Deleted Azure credential $testCredId" -ForegroundColor Green
            }
            catch {
                Write-Host "  FAIL: Could not delete Azure credential $testCredId`: $_" -ForegroundColor Red
                Write-Host "  Manual cleanup: Set-WUGCredential -CredentialId '$testCredId' -Remove" -ForegroundColor Yellow
                $testPassed = $false
            }
        }
        # Summary
        Write-Host ""
        if ($testPassed) {
            Write-Host "=== ALL TESTS PASSED ===" -ForegroundColor Green
            Write-Host "  Azure credentials can be created, verified, and deleted in WUG." -ForegroundColor White
            Write-Host "  You can safely use option [1] to push resources to WhatsUp Gold." -ForegroundColor White
        }
        else {
            Write-Host "=== SOME TESTS FAILED ===" -ForegroundColor Red
            Write-Host "  Review the errors above and check WUG API configuration." -ForegroundColor Yellow
        }
    }
    '8' {
        # ----------------------------------------------------------------
        # Generate Validated Azure Metrics HTML Dashboard
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building validated metrics dashboard..." -ForegroundColor Cyan

        $metricsRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dp = $devicePlan[$key]
            $perfItems = @($dp.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })
            foreach ($pi in $perfItems) {
                $mp = $pi.MonitorParams
                $rawVal = $mp['LastValue']
                $fmtVal = if ($null -ne $rawVal -and $rawVal -ne 'N/A') {
                    try { [math]::Round([double]$rawVal, 4) } catch { "$rawVal" }
                } else { 'N/A' }
                $metricsRows += [PSCustomObject]@{
                    Resource        = $dp.Name
                    ResourceType    = $dp.Type
                    Location        = $dp.Location
                    MetricName      = if ($mp['_MetricName']) { $mp['_MetricName'] } else { 'N/A' }
                    LastValue       = $fmtVal
                    Unit            = if ($mp['MetricUnit']) { $mp['MetricUnit'] } else { '' }
                    Aggregation     = if ($mp['_Aggregation']) { $mp['_Aggregation'] } else { 'N/A' }
                    JsonPath        = if ($mp['RestApiJsonPath']) { $mp['RestApiJsonPath'] } else { '' }
                    LastSeen        = if ($mp['LastTimestamp']) { $mp['LastTimestamp'] } else { '' }
                    Subscription    = $dp.Sub
                    ResourceGroup   = $dp.RG
                    MonitorName     = $pi.Name
                }
            }
        }

        if ($metricsRows.Count -eq 0) {
            Write-Warning "No validated metric monitors found in the discovery plan."
        }
        else {
            $metricsDashPath = Join-Path $OutputDir 'Azure-Metrics-Dashboard.html'
            $metricsTitle = "Azure Validated Metrics Dashboard"

            $null = Export-AzureDiscoveryDashboardHtml `
                -DashboardData $metricsRows `
                -OutputPath $metricsDashPath `
                -ReportTitle $metricsTitle

            Write-Host ""
            Write-Host "Metrics dashboard generated: $metricsDashPath" -ForegroundColor Green

            $uniqueResources = @($metricsRows | ForEach-Object { $_.Resource } | Select-Object -Unique).Count
            $uniqueMetrics   = @($metricsRows | ForEach-Object { $_.MetricName } | Select-Object -Unique).Count
            Write-Host "  Resources: $uniqueResources  |  Unique Metrics: $uniqueMetrics  |  Total Monitors: $($metricsRows.Count)" -ForegroundColor White

            # Group by resource type for quick summary
            $byType = $metricsRows | Group-Object ResourceType | Sort-Object Count -Descending
            foreach ($g in $byType) {
                $typeMetrics = @($g.Group | ForEach-Object { $_.MetricName } | Select-Object -Unique).Count
                Write-Host "    $($g.Name): $($g.Count) monitors ($typeMetrics unique metrics)" -ForegroundColor DarkGray
            }

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugMetricsPath = Join-Path $nmConsolePath 'Azure-Metrics-Dashboard.html'
                try {
                    Copy-Item -Path $metricsDashPath -Destination $wugMetricsPath -Force
                    Write-Host "Copied to WUG: $wugMetricsPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/Azure-Metrics-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                    Write-Host "  Manual copy: Copy-Item '$metricsDashPath' '$wugMetricsPath'" -ForegroundColor Yellow
                }
            }
        }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "Re-run anytime to discover new Azure resources." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCByImqR+dFigsHA
# 5FzaFyMocJpWD2MBZRN5cj8sc/hvxqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgT8/vK0tMSnYWbW/14uaGtpwRNGospjws
# M+G83kaD7mwwDQYJKoZIhvcNAQEBBQAEggIAo3fXyQCq8TuRBHTqy6ewA6STzUSn
# JRKl8HCob6aTFsyQbEDUwZuASOoDz9rR5Csh4HuIteZ5IgeqwxQDJXYVoP/Iz1JH
# lXjeoThG5rPTgO+zTl7MEp83b+bl4xaiTI+K8eLXP9GOxeLMwJ+5pkwTDaroGcdh
# h6s+LA8ZC02ootZbtxaJ88Lxblph/xnKaL6IaSJK3XZQpd0le5KgLEXNdeyLC3Xt
# oSvBuhn9hUJ7FK4iMoOeDMWTdtIWOtKNdED5wUPPKrsOSsYq7fIe11HTSeU+5tfH
# ASuNXN7LyjFMZhqA1WpKKl9xPB4x3j7vzdC59H1KkMEmy3jby0CPxhEy8Aje1vvN
# heSQGW0hochEl4haQlHKXNFKjFd3JKUzscIeM22r3tJ+59hf+VMds1B4T0dJrJJB
# KgThys9AVV4LNKztn13pww3EPD+1Rrf1+2Nb79Vf+I4nB5O9eV8E0jGi8Cx3shzV
# V4QKD38vLTg8cLIAwHT6B8bMRIJcBuSeGF5NXTlGRDlFWRoeRgcW/roYG/dJN6to
# TlOPNa4zcTX3BgiighZ95GyspWdJRKlXnhAmUaO1buRhILEbBrKb/Ta65KKLA3Sv
# SR9Iup0abda6KOqIpryU6nF6UAhYQde3Gr4EUzE+53Ob719clJhAL1YfsR8s0HiR
# lvMG2ZdYzCTGHRo=
# SIG # End signature block
