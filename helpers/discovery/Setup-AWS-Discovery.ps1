<#
.SYNOPSIS
    AWS Cloud Discovery — scan all regions, generate dashboard, push to WUG.

.DESCRIPTION
    Discovers AWS resources (EC2 instances, RDS databases, Load Balancers)
    across ALL enabled regions by default — just like Azure discovery scans
    all subscriptions and resource groups automatically.

    =====================================================================
    QUICK START (3 steps)
    =====================================================================

    Step 1 — Run interactively ONCE to save your AWS credentials:

        .\Setup-AWS-Discovery.ps1

    Step 2 — Schedule it (runs daily at 2 AM, no prompts):

        .\Register-DiscoveryScheduledTask.ps1 -Mode Provider `
            -Provider AWS -Action Dashboard -TriggerType Daily

    Step 3 — Open the dashboard:

        Start-Process "$env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Output\AWS-Dashboard.html"

    That's it. The script scans every AWS region your IAM key can access,
    discovers all EC2/RDS/ELB resources, and generates a searchable HTML
    dashboard with sortable tables, summary cards, and CSV/JSON export.

    =====================================================================
    WHAT IT DOES
    =====================================================================

    1. Authenticates with your AWS Access Key + Secret Key (DPAPI vault)
    2. Enumerates ALL enabled AWS regions (or specific ones you choose)
    3. In each region, discovers:
         - EC2 instances (name, IP, state, type, platform, VPC, AZ)
         - RDS instances (endpoint, engine, class, state, AZ)
         - Elastic Load Balancers (DNS, type, state, VPC, AZs)
    4. Presents an action menu:
         [1] Push to WhatsUp Gold (create devices + monitors + attributes)
         [2] Export JSON   [3] Export CSV   [4] Show table
         [5] Generate HTML dashboard   [6] Exit

    Zero external dependencies when using REST API mode (default).
    AWS.Tools PowerShell modules are optional for module-based collection.

    =====================================================================
    WHATSUP GOLD INTEGRATION
    =====================================================================

    Option [1] PushToWUG does the following automatically:
      - Creates a WUG device for each AWS resource (by IP)
      - Sets rich device attributes: AWS.Region, AWS.InstanceType,
        AWS.State, AWS.VpcId, AWS.Platform, AWS.AZ, etc.
      - Creates REST API active + performance monitors
      - Use these attributes in WUG dashboards, reports, and groups

    You can also use the Cloud Resource Monitor in WUG and point it
    at these attributes for cloud-native monitoring.

    =====================================================================
    CREDENTIAL SECURITY
    =====================================================================

    - AWS Access Key + Secret Key stored in DPAPI vault (encrypted to
      your Windows user account + machine — cannot be read by other users
      or on other machines)
    - No credentials in plaintext, ever — not in scripts, logs, or history
    - First run prompts with masked input, subsequent runs auto-load
    - Optional AES-256 double encryption via Set-DiscoveryVaultPassword

.PARAMETER Region
    AWS region(s) to scan. Default: 'all' (every enabled region).

    Examples:
      -Region 'all'                          # Scan everything (default)
      -Region 'us-east-1'                    # Single region
      -Region 'us-east-1','eu-west-1'        # Multiple specific regions

    When set to 'all', the script uses the AWS DescribeRegions API to
    enumerate every region your IAM key has access to, then scans each one.

.PARAMETER UseRestApi
    Collection method. Default: $true (REST API, zero dependencies).
    Pass -UseRestApi:$false to use AWS.Tools PowerShell modules instead.

.PARAMETER Action
    What to do after discovery. Skips the interactive menu when specified.
    Valid: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, None.
    Non-interactive default: Dashboard.

.PARAMETER WUGServer
    WhatsUp Gold server address for PushToWUG. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER OutputPath
    Output directory for dashboards and exports.
    Non-interactive default: %LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Output.

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and defaults.
    Ideal for scheduled task execution via Register-DiscoveryScheduledTask.ps1.

.EXAMPLE
    .\Setup-AWS-Discovery.ps1
    # Interactive mode — scans all regions, prompts for action.

.EXAMPLE
    .\Setup-AWS-Discovery.ps1 -Action Dashboard
    # Scan all regions, generate dashboard, no other prompts.

.EXAMPLE
    .\Setup-AWS-Discovery.ps1 -Region 'us-east-1','us-west-2' -Action Dashboard
    # Scan only two regions, generate dashboard.

.EXAMPLE
    .\Setup-AWS-Discovery.ps1 -Action PushToWUG -NonInteractive
    # Scheduled mode — scan all regions, push to WUG, zero prompts.

.EXAMPLE
    .\Setup-AWS-Discovery.ps1 -Action Dashboard -NonInteractive
    # Scheduled mode — scan all regions, generate dashboard only.

.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+
    REST API mode has ZERO external module dependencies.
    Module mode requires: AWS.Tools.EC2, AWS.Tools.RDS,
      AWS.Tools.ElasticLoadBalancingV2, AWS.Tools.CloudWatch.
    WhatsUpGoldPS module is only needed for PushToWUG.

.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>
[CmdletBinding()]
param(
    [string[]]$Region = @('all'),

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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Configuration -----------------------------------------------------------

# Default to REST API if not explicitly set
if (-not $PSBoundParameters.ContainsKey('UseRestApi')) {
    $UseRestApi = $true
}

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-AWS.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== AWS Discovery ===" -ForegroundColor Cyan
Write-Host ""

# --- Collection method ---------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('UseRestApi') -and -not $NonInteractive) {
    Write-Host "AWS data collection method:" -ForegroundColor Cyan
    Write-Host "  [1] REST API direct (zero external dependencies, SigV4 signing)" -ForegroundColor White
    Write-Host "  [2] AWS.Tools PowerShell modules (requires AWS.Tools.EC2, etc.)" -ForegroundColor White
    Write-Host ""
    $methodChoice = Read-Host -Prompt "Choice [1/2, default: 1]"
    $UseRestApi = ($methodChoice -ne '2')
}

if ($UseRestApi) {
    Write-Host "Using REST API mode (no AWS.Tools modules needed)." -ForegroundColor Green
}
else {
    Write-Host "Using AWS.Tools module mode." -ForegroundColor Green

    # --- Check for AWS.Tools modules -----------------------------------------------
    if (-not (Get-Module -ListAvailable -Name AWS.Tools.EC2 -ErrorAction SilentlyContinue)) {
        Write-Warning "AWS.Tools.EC2 module not found. Install with:"
        Write-Host "  Install-Module -Name AWS.Tools.Installer -Scope CurrentUser -Force" -ForegroundColor Yellow
        Write-Host "  Install-AWSToolsModule EC2, RDS, ElasticLoadBalancingV2, CloudWatch -CleanUp" -ForegroundColor Yellow
        if ($NonInteractive) {
            Write-Error "AWS.Tools modules not found and cannot install in non-interactive mode."
            return
        }
        Write-Host ""
        $installChoice = Read-Host -Prompt "Attempt to install now? [y/N]"
        if ($installChoice -eq 'y' -or $installChoice -eq 'Y') {
            try {
                Install-Module -Name AWS.Tools.Installer -Scope CurrentUser -Force -ErrorAction Stop
                Install-AWSToolsModule EC2, RDS, ElasticLoadBalancingV2, CloudWatch, Common -CleanUp -ErrorAction Stop
                Write-Host "AWS.Tools modules installed successfully." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to install AWS.Tools modules: $_"
                return
            }
        }
        else {
            Write-Host "Cannot proceed without AWS.Tools modules. Exiting." -ForegroundColor Red
            return
        }
    }
}

# --- Resolve region(s) ---------------------------------------------------------
$AWSRegions = @($Region)

# Interactive region selection (if not specified via parameter)
if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('Region')) {
    Write-Host ""
    Write-Host "AWS region scope:" -ForegroundColor Cyan
    Write-Host "  [1] All regions (scans every enabled region — recommended)" -ForegroundColor White
    Write-Host "  [2] Specific region(s) (e.g. us-east-1, eu-west-1)" -ForegroundColor White
    Write-Host ""
    $regionChoice = Read-Host -Prompt "Choice [1/2, default: 1]"
    if ($regionChoice -eq '2') {
        $regionInput = Read-Host -Prompt "Enter region(s), comma-separated"
        if (-not [string]::IsNullOrWhiteSpace($regionInput)) {
            $AWSRegions = @($regionInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    else {
        $AWSRegions = @('all')
    }
}

if ($AWSRegions.Count -eq 0) { $AWSRegions = @('all') }

$scanLabel = if ($AWSRegions -contains 'all') { 'ALL enabled regions' } else { $AWSRegions -join ', ' }
Write-Host "Regions: $scanLabel" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 2: Credentials (DPAPI vault — encrypted, cached)
# ==============================================================================
$credSplat = @{ Name = 'AWS.Credential'; CredType = 'AWSKeys'; ProviderLabel = 'AWS' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
$AWSCred = Resolve-DiscoveryCredential @credSplat
if (-not $AWSCred) {
    Write-Error 'No AWS credentials. Exiting.'
    return
}

# ==============================================================================
# STEP 3: Discover — authenticate and enumerate AWS resources
# ==============================================================================
Write-Host ""
Write-Host "Scanning AWS: $scanLabel..." -ForegroundColor Cyan

$bstrAws = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AWSCred.Password)
try { $plainAwsSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrAws) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrAws) }

# First non-'all' region for initial connection; provider resolves 'all' dynamically
$connectRegion = ($AWSRegions | Where-Object { $_ -ne 'all' } | Select-Object -First 1)
if (-not $connectRegion) { $connectRegion = 'us-east-1' }

$plan = Invoke-Discovery -ProviderName 'AWS' `
    -Target $AWSRegions `
    -Credential @{ AccessKey = $AWSCred.UserName; SecretKey = $plainAwsSK; Region = $connectRegion; UseRestApi = $UseRestApi }

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check AWS credentials and region accessibility."
    if ($Action -ne 'Dashboard' -and $Action -ne 'DashboardAndPush') {
        return
    }
    $plan = @()
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $resName = $item.Attributes['AWS.ResourceName']
    $region  = $item.Attributes['AWS.Region']
    $key = "resource:${region}:$resName"

    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name   = $resName
            IP     = $item.Attributes['AWS.IPAddress']
            Type   = $item.Attributes['AWS.DeviceType']
            Region = $region
            State  = $item.Attributes['AWS.State']
            Attrs  = $item.Attributes
            Items  = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$withIP    = @($devicePlan.Values | Where-Object { $_.IP })
$withoutIP = @($devicePlan.Values | Where-Object { -not $_.IP })

$ec2Count = @($devicePlan.Values | Where-Object { $_.Type -eq 'EC2' }).Count
$rdsCount = @($devicePlan.Values | Where-Object { $_.Type -eq 'RDS' }).Count
$elbCount = @($devicePlan.Values | Where-Object { $_.Type -eq 'ELB' }).Count

# Discover actual regions from the plan data
$discoveredRegions = @($devicePlan.Values | Select-Object -ExpandProperty Region -Unique | Sort-Object)

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } |
    Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
    Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Total Resources:       $($devicePlan.Count)" -ForegroundColor White
Write-Host "  EC2 Instances:         $ec2Count" -ForegroundColor White
Write-Host "  RDS Instances:         $rdsCount" -ForegroundColor White
Write-Host "  Load Balancers:        $elbCount" -ForegroundColor White
Write-Host "  Resources (with IP):   $($withIP.Count)" -ForegroundColor White
Write-Host "  Resources (no IP):     $($withoutIP.Count)" -ForegroundColor White
Write-Host "  Regions with resources:$($discoveredRegions.Count)  ($($discoveredRegions -join ', '))" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    Select-Object -First 50 |
    ForEach-Object { [PSCustomObject]@{
        Resource = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { 'N/A' }
        Region   = $_.Region
        State    = $_.State
        Monitors = $_.Items.Count
    }} |
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
        'PushToWUG' { $choice = '1' }
        'ExportJSON' { $choice = '2' }
        'ExportCSV' { $choice = '3' }
        'ShowTable' { $choice = '4' }
        'Dashboard' { $choice = '5' }
        'None' { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice -and $NonInteractive) {
    $choice = '5'  # Default to Dashboard for non-interactive
}

if (-not $choice) {
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push monitors to WhatsUp Gold (creates devices + monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate AWS HTML dashboard (live data)"
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
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
        }
        else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors
        }

        # ==================================================================
        # Phase 1: Create AWS credential in WUG library
        # ==================================================================
        Write-Host ""
        Write-Host "Phase 1: AWS Credential in WUG..." -ForegroundColor Cyan

        $bstrAK = $AWSCred.UserName
        $bstrSK2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AWSCred.Password)
        try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrSK2) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrSK2) }

        $awsCredName = "AWS - $bstrAK"
        $wugAwsCredId = $null

        # Search for existing AWS credential
        try {
            $existingCreds = @(Get-WUGCredential -Type aws)
            $matchCred = $existingCreds | Where-Object { $_.name -eq $awsCredName } | Select-Object -First 1
            if ($matchCred) {
                $wugAwsCredId = $matchCred.id
                Write-Host "  Found existing AWS credential: $awsCredName (ID: $wugAwsCredId)" -ForegroundColor Green
            }
        }
        catch { Write-Verbose "AWS credential search error: $_" }

        if (-not $wugAwsCredId) {
            try {
                $newCred = Add-WUGCredential -Name $awsCredName -Type aws `
                    -AwsAccessKeyID $bstrAK `
                    -AwsSecureAccessKey $plainSK
                if ($newCred -and $newCred.id) {
                    $wugAwsCredId = $newCred.id
                    Write-Host "  Created AWS credential: $awsCredName (ID: $wugAwsCredId)" -ForegroundColor Green
                }
                elseif ($newCred -and $newCred.resourceId) {
                    $wugAwsCredId = $newCred.resourceId
                    Write-Host "  Created AWS credential: $awsCredName (ID: $wugAwsCredId)" -ForegroundColor Green
                }
                else {
                    # Re-search after potential duplicate creation
                    $existingCreds = @(Get-WUGCredential -Type aws)
                    $matchCred = $existingCreds | Where-Object { $_.name -like "*$bstrAK*" } | Select-Object -First 1
                    if ($matchCred) {
                        $wugAwsCredId = $matchCred.id
                        Write-Host "  Found AWS credential after create: $($matchCred.name) (ID: $wugAwsCredId)" -ForegroundColor Green
                    }
                }
            }
            catch {
                Write-Warning "Failed to create AWS credential: $_"
                # Try re-search
                try {
                    $existingCreds = @(Get-WUGCredential -Type aws)
                    $matchCred = $existingCreds | Where-Object { $_.name -like '*AWS*' } | Select-Object -First 1
                    if ($matchCred) {
                        $wugAwsCredId = $matchCred.id
                        Write-Host "  Using existing AWS credential: $($matchCred.name) (ID: $wugAwsCredId)" -ForegroundColor Yellow
                    }
                }
                catch { }
            }
        }

        $plainSK = $null

        if (-not $wugAwsCredId) {
            Write-Warning "No AWS credential available in WUG. CloudWatch monitors will not authenticate."
        }

        # ==================================================================
        # Phase 2: Identify existing vs new devices
        # ==================================================================
        Write-Host ""
        Write-Host "Phase 2: Identifying devices..." -ForegroundColor Cyan

        $wugDeviceMap  = @{}  # devicePlan key -> WUG device ID
        $existingKeys  = @()
        $newKeys       = @()

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $existingDevice = $null

            # Search by name first (handles cloud resources with/without IP)
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.displayName -like "*$($dev.Name)*" -or
                        $_.hostName -eq $dev.Name
                    } | Select-Object -First 1
                    if (-not $existingDevice -and $searchResults.Count -eq 1) {
                        $existingDevice = $searchResults[0]
                    }
                }
            }
            catch { Write-Verbose "Name search for '$($dev.Name)' returned error: $_" }

            # If no match by name and device has IP, search by IP
            if (-not $existingDevice -and $dev.IP) {
                try {
                    $searchResults = @(Get-WUGDevice -SearchValue $dev.IP)
                    if ($searchResults.Count -gt 0) {
                        $existingDevice = $searchResults | Where-Object {
                            $_.networkAddress -eq $dev.IP -or $_.hostName -eq $dev.IP
                        } | Select-Object -First 1
                        if (-not $existingDevice -and $searchResults.Count -eq 1) {
                            $existingDevice = $searchResults[0]
                        }
                    }
                }
                catch { Write-Verbose "IP search for '$($dev.IP)' returned error: $_" }
            }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $existingKeys += $key
                Write-Host "  Existing: $($existingDevice.displayName) (ID: $($existingDevice.id))" -ForegroundColor DarkGray
            }
            else {
                $newKeys += $key
            }
        }

        Write-Host "  Found $($existingKeys.Count) existing, $($newKeys.Count) new" -ForegroundColor Cyan

        # ==================================================================
        # Phase 3: Create new devices via Add-WUGDeviceTemplate
        # ==================================================================
        Write-Host ""
        Write-Host "Phase 3: Creating $($newKeys.Count) new devices..." -ForegroundColor Cyan

        $devicesCreated = 0
        foreach ($key in $newKeys) {
            $dev = $devicePlan[$key]
            $addIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
            $displayName = "$($dev.Name) ($($dev.Type))"

            # Collect active monitor names for this device
            $activeMonNames = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name)

            # Build attributes array for template
            $attrArray = @()
            foreach ($attrName in $dev.Attrs.Keys) {
                $attrArray += @{ name = $attrName; value = "$($dev.Attrs[$attrName])" }
            }

            # Build template params
            $templateParams = @{
                IpOrName    = $addIP
                DisplayName = $displayName
                Brand       = 'AWS'
                Attributes  = $attrArray
            }

            # Attach AWS credential if available
            if ($wugAwsCredId) {
                $templateParams.CredentialAWS = $awsCredName
            }

            # Attach active monitors (Ping) if any exist
            if ($activeMonNames.Count -gt 0) {
                $templateParams.ActiveMonitors = $activeMonNames
            }
            else {
                $templateParams.NoDefaultActiveMonitor = $true
            }

            Write-Host "  Adding: $displayName ($addIP)..." -ForegroundColor Yellow
            try {
                $templateResult = Add-WUGDeviceTemplate @templateParams
                if ($templateResult) {
                    # Extract device ID from result
                    $newDeviceId = $null
                    if ($templateResult.id) { $newDeviceId = $templateResult.id }
                    elseif ($templateResult.resourceId) { $newDeviceId = $templateResult.resourceId }
                    else {
                        # Search for newly created device
                        Start-Sleep -Milliseconds 1500
                        $newSearch = @(Get-WUGDevice -SearchValue $addIP)
                        if ($addIP -eq '0.0.0.0') {
                            $newSearch = @(Get-WUGDevice -SearchValue $dev.Name)
                        }
                        $newDevice = $newSearch | Select-Object -First 1
                        if ($newDevice) { $newDeviceId = $newDevice.id }
                    }

                    if ($newDeviceId) {
                        $wugDeviceMap[$key] = $newDeviceId
                        $devicesCreated++
                        Write-Host "    Created: ID $newDeviceId" -ForegroundColor Green
                    }
                    else {
                        Write-Warning "    Created device but could not retrieve ID for: $displayName"
                    }
                }
            }
            catch {
                Write-Warning "    Failed to create device '$displayName': $_"
                # Fallback: try basic Add-WUGDevice
                if ($addIP -ne '0.0.0.0') {
                    try {
                        Add-WUGDevice -IpOrName $addIP -GroupId 0 | Out-Null
                        Start-Sleep -Seconds 2
                        $fallbackDev = @(Get-WUGDevice -SearchValue $addIP) | Select-Object -First 1
                        if ($fallbackDev) {
                            $wugDeviceMap[$key] = $fallbackDev.id
                            $devicesCreated++
                            Write-Host "    Fallback created: $($fallbackDev.displayName) (ID: $($fallbackDev.id))" -ForegroundColor Yellow
                        }
                    }
                    catch { Write-Warning "    Fallback also failed for '$addIP': $_" }
                }
            }
        }

        Write-Host "  Devices created: $devicesCreated" -ForegroundColor Cyan

        # ==================================================================
        # Phase 4: Update existing devices (credentials + attributes)
        # ==================================================================
        if ($existingKeys.Count -gt 0) {
            Write-Host ""
            Write-Host "Phase 4: Updating $($existingKeys.Count) existing devices..." -ForegroundColor Cyan

            foreach ($key in $existingKeys) {
                $devId = $wugDeviceMap[$key]
                $dev   = $devicePlan[$key]

                # Assign AWS credential if available
                if ($wugAwsCredId) {
                    try {
                        Set-WUGDeviceCredential -DeviceId $devId -CredentialId $wugAwsCredId -Assign | Out-Null
                        Write-Verbose "  Assigned AWS credential to device $devId"
                    }
                    catch { Write-Verbose "  Credential assign error for device $devId`: $_" }
                }

                # Update attributes
                foreach ($attrName in $dev.Attrs.Keys) {
                    try {
                        Set-WUGDeviceAttribute -DeviceId $devId -Name $attrName -Value $dev.Attrs[$attrName] | Out-Null
                    }
                    catch { Write-Verbose "  Attribute set error for $attrName on device $devId`: $_" }
                }
            }
            Write-Host "  Updated attributes and credentials on $($existingKeys.Count) devices" -ForegroundColor Green
        }

        # ==================================================================
        # Phase 5: Set DeviceId on plan items + sync monitors
        # ==================================================================
        Write-Host ""
        Write-Host "Phase 5: Syncing monitors..." -ForegroundColor Cyan

        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
            }
        }

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        # ==================================================================
        # Summary
        # ==================================================================
        Write-Host ""
        Write-Host "Push complete!" -ForegroundColor Green
        Write-Host "  Devices in WUG:              $($wugDeviceMap.Count)  ($devicesCreated new, $($existingKeys.Count) existing)" -ForegroundColor White
        Write-Host "  AWS credential:               $(if ($wugAwsCredId) { $awsCredName } else { 'NONE' })" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created: $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:          $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):      $($result.Skipped)" -ForegroundColor White
        Write-Host "  Attributes set:               $($result.AttrsUpdated)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            Write-Host "  Failed:                       $($result.Failed)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Done! AWS devices + CloudWatch monitors pushed to WhatsUp Gold." -ForegroundColor Green
    }
    '2' {
        $jsonPath = Join-Path $OutputDir 'aws-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'aws-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate AWS HTML Dashboard from discovery data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building AWS dashboard from discovery data..." -ForegroundColor Cyan

        # Build dashboard rows from the already-collected $devicePlan
        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $a   = $dev.Attrs

            # Count monitors by type
            $pingCount = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
            $cwCount   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count
            $cwMetricNames = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
                ForEach-Object { $_.MonitorParams['CloudWatchMetric'] } | Where-Object { $_ }) -join ', '

            $dashboardRows += [PSCustomObject]@{
                ResourceType     = $dev.Type
                Name             = $dev.Name
                State            = $dev.State
                IPAddress        = if ($dev.IP) { $dev.IP } else { 'N/A' }
                PrivateIP        = if ($a['AWS.PrivateIP']) { $a['AWS.PrivateIP'] } else { '' }
                Region           = $dev.Region
                AvailabilityZone = if ($a['AWS.AZ']) { $a['AWS.AZ'] } else { '' }
                InstanceType     = if ($a['AWS.InstanceType']) { $a['AWS.InstanceType'] } else { '' }
                Platform         = if ($a['AWS.Platform']) { $a['AWS.Platform'] } else { '' }
                VpcId            = if ($a['AWS.VpcId']) { $a['AWS.VpcId'] } else { '' }
                InstanceId       = if ($a['AWS.InstanceId']) { $a['AWS.InstanceId'] } else { '' }
                PingMonitor      = if ($pingCount -gt 0) { 'Yes' } else { 'No' }
                CloudWatchCount  = $cwCount
                CloudWatchMetrics = $cwMetricNames
            }
        }

        if (-not $dashboardRows -or $dashboardRows.Count -eq 0) {
            Write-Host "  No resources discovered. Generating empty dashboard." -ForegroundColor Yellow
            $dashboardRows = @()
        }

        $dashReportTitle = "AWS Dashboard"
        $dashTempPath = Join-Path $OutputDir 'AWS-Dashboard.html'

        $null = Export-AWSDiscoveryDashboardHtml `
            -DashboardData $dashboardRows `
            -OutputPath $dashTempPath `
            -ReportTitle $dashReportTitle

        Write-Host ""
        Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
        if ($dashboardRows.Count -gt 0) {
            $dEC2  = @($dashboardRows | Where-Object { $_.ResourceType -eq 'EC2' }).Count
            $dRDS  = @($dashboardRows | Where-Object { $_.ResourceType -eq 'RDS' }).Count
            $dELB  = @($dashboardRows | Where-Object { $_.ResourceType -eq 'ELB' }).Count
            $dRunning = @($dashboardRows | Where-Object { $_.State -eq 'running' -or $_.State -eq 'active' -or $_.State -eq 'available' }).Count
            Write-Host "  EC2: $dEC2  |  RDS: $dRDS  |  ELB: $dELB  |  Active: $dRunning" -ForegroundColor White
        } else {
            Write-Host "  No resources found across any region." -ForegroundColor Yellow
        }

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugDashPath = Join-Path $wugDashDir 'AWS-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/AWS-Dashboard.html" -ForegroundColor Cyan
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
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\dashboards\AWS-Dashboard.html'" -ForegroundColor Cyan
            }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "Re-run anytime to discover new AWS resources." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAOiQ0afyhpOGcC
# 2Q+8E2SwbPkIiCtd7K7rV1/0J4Gtv6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBDzCvwstuMAe5LA7YThemhNaZEK9G6tri95vCHVhzodjANBgkqhkiG9w0BAQEF
# AASCAgAsaB4gBGdYYxJUXI45o8plgaWL8E1oZZHNxYvif7/WlkNnCoIhjNix9Vwn
# RF14qea1ikA763gu3arGFJBwbIIDDV3UHv+qfxtACKc30W9WHImg9AqiLa47Nxc5
# MOkKOXjLztIVnw5vk93cAry7H8MdCpGdt/Rnnn/3Wj4/Em/samAuj0UZzsaePFcv
# uPvnYPHecoglNTTf7zl2MH+LQXWuZ/jQctfqZom1a7dCpt/dkIu+H8efqkVH1az5
# n8aeYOHDvuGACYnLJSgoF5kGCHwQWAtpBkiQFRQGACVR+tQgBFBKf8bacVeAIEKk
# GFrOp3LnUBgM4sjfau7cvi7giGTOY7QRRO74nWEROCvXO9XIExdzB1o5XQxR3iwB
# 7hlcW9DwA0aOKF/mc/9AmpwbCH9HKDauPJ6mGNmL+zCvbnr9F4fxE43gmcGm6huO
# 63iZkGarZESDN17FJg0Pcq4lv2NhFX2mp/YkgFTiMyAXFAKzJJqPjwd3vo94aAO+
# 2PZd27EI486/vi/YDRyXJ8ji0kxlW/9Ed2vsWWkn7puiVn0PY6szW8RK1YTVlqSj
# sHN8/twb8aukCKuILgbliUO4x1o5cOQR0547Ra+W9qox6Cg0AzB7O9rQ4AwnhdN9
# Y5M+mpTJQTBijoBef5RVZHdicAAZBqz/k2Tn1K3HDKt6m4P1QaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MTkyMTA1MDlaMC8GCSqGSIb3DQEJBDEiBCBwZWk+
# rIC+oPFM8PvVvkfEJ0wmwZMpkgGYAq/QjRfrKDANBgkqhkiG9w0BAQEFAASCAgAx
# QgHXLC90tLTbbzgc1cug9nOv+pIH+PVINcK6qDiO3ZbUzB19bzmcZ1LJB6VxeEI0
# Tc3lcKoiE1SN/6ZeW61Ho2DkmO9eotT8kbb1vS0jjB29aSvCyh9PtarKKjh8Vx0K
# mq11ukVwrW8lcXO/Q2JGCBDTBw8wOTxWi8GMpnXxmBiOmJurCR15O772c752jvkH
# tOK82Mvj4DU6VXEzhha1jRr+YJCUEPttamH3slsOQa9Y5bBf7y+Qw9uXCKdABas9
# BErdbPyGIMdLu5q/ElKxLsUoXCH7d3v9IqYkcd1buyEqspSPTJlU7v0hugXjAJaT
# Pg2UJKyMK+BydE6vK1/ewGxMATuAEIIPS1cAf62MiMpDxmQMTCGJjqfp4vNjHGhP
# DdjkxN9M8HhXotxazdRCRKr4FxNmbg4j6ysieThFMN8vUbquXE4Pvrw3Q5SStW8L
# WzOJCYe1SjTuyrQLdfUAPsmX5NZ4gzAz38BHRGZPWleAqqeMd1q/N8Why8iHdeUE
# kOdG4PiZRXaQW+hPZX4PzLNpfhBAJ03nhMbrIda7Xj5YVFUkk9/Sb5TTUkj4prqS
# Yv1BkR3q2m+QoN7YiiE17BBhJJGN0dAUGLzjX+ea8a4x0l4NI9qjleH9zbyMQMC9
# 9CwxPPPXlK3lvZT38Ij+N5RFp4R4D3eMveSN9C9heg==
# SIG # End signature block
