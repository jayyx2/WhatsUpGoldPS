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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
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
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugDashPath = Join-Path $wugDashDir 'Azure-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/Azure-Dashboard.html" -ForegroundColor Cyan
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
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\dashboards\Azure-Dashboard.html'" -ForegroundColor Cyan
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
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugMetricsPath = Join-Path $wugDashDir 'Azure-Metrics-Dashboard.html'
                try {
                    Copy-Item -Path $metricsDashPath -Destination $wugMetricsPath -Force
                    Write-Host "Copied to WUG: $wugMetricsPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/Azure-Metrics-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                    Write-Host "  Manual copy: Copy-Item '$metricsDashPath' '$wugMetricsPath'" -ForegroundColor Yellow
                }
                Deploy-DashboardWebConfig -Path $wugDashDir
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+3WvIDQuUh9d9
# 2+4fp+wTd+kzruOlwaZVyr0TvYAgeqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCBSmvfjYzijjJi8V1D6Tczg5y9bkyRGXeTp7KN1c/1HajANBgkqhkiG9w0BAQEF
# AASCAgCchUIoFoP6h9paNs1ldR76F/jlQ2V8oTVTim0zE9KekP+qOAjBwdeo8FOw
# aN+LYT1KmdTNeB5KEgtfebiLdt6+y5F9nPbhBz4T/qgdFAXH+4qEnmsoF7voW+ik
# KJFwWvhZh9Qgojogiix1uiRnNEgZfdvo2L4BzTsoc3mPKy7VB425Y5sy+MaGuxK0
# Neg/kqOC4PLXugFPutLOf7DXkabenooLVBGKidsD6jc9+IFkwWWo9o9xKUy2hvhI
# L2XzoPClWxdNfSlDEAy0jOgiF39Yv75cIyM7LHX58p6Dialus4lEbxB2YV2l44uE
# lrREEM+KZOYu6UVshnvR0Mv0TjOtWsiBH56xNr+S6jONqmE9NocG5yhDCCrxKMha
# Ykd4I1VVEitSERJqIElkonHasrs7hGpUnlJ8m+5N7nlkWRxMlXjCcbWVll654Hz9
# XPGwTdLJlb2kngeLt7NfHwm/BsyeNszsTJqQWFUlXgG+xaySTyINB8J2txKcy7eE
# Diu7qzF+ep1nIO/082wOk6fxospqVTtu+Oy6SBYgQ98up3ajjVqWf/5xsUnNiUNB
# jLFlYeQQzgITWJe+SeGGy2OdyURUgrdy0ltw+zvD6E+5le3Gg73DAnO7Djl3u8kC
# qHZzd62hwoCUgXpJxJr0n1Vp/Sl5LEFZAK5MunDFn5FRnKhSA6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MDYxOTMzMjJaMC8GCSqGSIb3DQEJBDEiBCDiqcO/
# DErmIkGt2S1SrLDfVcPOOncpbikHQYVpRjHLlzANBgkqhkiG9w0BAQEFAASCAgCv
# 4rNCB7CvTkSxcEnUsbNVXl30/p8ADmsUmXvptb+sLauXTKbcHIVE73iWjo9ldgOK
# nCSE2uFmYy3ipL5DTv4blnkNnK9468/ryFYiOtLcKdydv4+6WoLrU18uTnXoOtVz
# 7lcvwmBawubWvycuPsc2sl4ywhu3uaz4PJ4cCNyvxW7Q/1tE7yATtI5qYuVGAKyY
# ItADykIX8l7cNnEtLMYp7b+OJp6areQgBu9d+FH9GhoE/asoEbDqrbo9idAQ0ddm
# kqiYK17AN7sEiuBRGUxD3JlnRKuYXVKZRIIHAAQ3yfDpDfN2E1vdkCCtwc/pKuHm
# 9jybLTOQCYHmvQoU/X7kx0QG/Eoljb/qnqttxZXKbOVDVRNWcKjm+PItfu7kUczU
# 7bl3spkusv6kSWzwqTqZRw8VsbNQRAgAIQCQX7Bnis/TqFK7k1gU5Bdfb7lXxpOP
# p/XEutWheQiOf9wtfvJ0koTbKO+GYUGvTh+1e6jwGfPUzyXWQLADK+iWic+xG9GG
# L6Thx9wTlIKhgzLYds5NanHWRSJDXq1TZq6XDVoc7mk3Q5P2RxchQc6v6KskQ/cM
# yZ6yxmwMJqM8kQnjjnsZpRrtvFMNhd3RBJ0Nl+TUN8WZ25xe6LyaEihBq7DNwVnN
# ayBb7sAtJq1eP8Rp5xmRded6CQUw0nRu1Gmam0NbdA==
# SIG # End signature block
