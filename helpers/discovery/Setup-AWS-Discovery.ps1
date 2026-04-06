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

        Start-Process "$env:LOCALAPPDATA\DiscoveryHelpers\Output\AWS-Dashboard.html"

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
    Non-interactive default: %LOCALAPPDATA%\DiscoveryHelpers\Output.

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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
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
    Write-Host "  [1] AWS.Tools PowerShell modules (requires AWS.Tools.EC2, etc.)" -ForegroundColor White
    Write-Host "  [2] REST API direct (zero external dependencies, SigV4 signing)" -ForegroundColor White
    Write-Host ""
    $methodChoice = Read-Host -Prompt "Choice [1/2, default: 2]"
    $UseRestApi = ($methodChoice -ne '1')
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
    return
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
        if (-not $NonInteractive) {
            Write-Host ""
            $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
            if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
                $WUGServer = $wugInput.Trim()
            }
        }

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
            $wugCred = $WUGCredential
        }
        elseif ($NonInteractive) {
            $wugResolved = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -NonInteractive
            if (-not $wugResolved) {
                Write-Error 'No WUG credentials in vault. Run interactively first to cache them, or pass -WUGCredential.'
                return
            }
            $wugCred = $wugResolved.Credential
            if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
        }
        else {
            $wugCred = Get-Credential -Message "WhatsUp Gold admin credentials for $WUGServer"
        }
        Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors

        Write-Host ""
        Write-Host "Creating devices in WUG..." -ForegroundColor Cyan

        $wugDeviceMap = @{}
        $devicesCreated = 0
        $devicesFound   = 0

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $addIP = $dev.IP
            if (-not $addIP) { continue }

            $existingDevice = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.networkAddress -eq $addIP -or $_.hostName -eq $addIP -or
                        $_.displayName -eq $addIP -or $_.displayName -eq $dev.Name
                    } | Select-Object -First 1
                    if (-not $existingDevice -and $searchResults.Count -eq 1) {
                        $existingDevice = $searchResults[0]
                    }
                }
            }
            catch { Write-Verbose "Search for '$addIP' returned error: $_" }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $devicesFound++
                Write-Host "  Found: $($existingDevice.displayName) (ID: $($existingDevice.id))" -ForegroundColor Green
            }
            else {
                Write-Host "  Adding $addIP ($($dev.Name)) [$($dev.Type)]..." -ForegroundColor Yellow
                try {
                    Add-WUGDevice -IpOrName $addIP -GroupId 0 | Out-Null
                    Start-Sleep -Seconds 2
                    $newDevice = @(Get-WUGDevice -SearchValue $addIP) | Select-Object -First 1
                    if ($newDevice) {
                        $wugDeviceMap[$key] = $newDevice.id
                        $devicesCreated++
                        Write-Host "  Added: $($newDevice.displayName) (ID: $($newDevice.id))" -ForegroundColor Green
                    }
                    else { Write-Warning "Added '$addIP' but could not find it in WUG." }
                }
                catch { Write-Warning "Failed to add device '$addIP': $_" }
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing" -ForegroundColor Cyan

        Write-Host "Setting device attributes..." -ForegroundColor Cyan
        foreach ($key in @($wugDeviceMap.Keys)) {
            $devId = $wugDeviceMap[$key]
            $dev   = $devicePlan[$key]
            foreach ($attrName in $dev.Attrs.Keys) {
                try {
                    Set-WUGDeviceAttribute -DeviceId $devId -Name $attrName -Value $dev.Attrs[$attrName] | Out-Null
                }
                catch { Write-Verbose "Attribute set error for $attrName on device $devId`: $_" }
            }
        }

        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
            }
        }

        Write-Host ""
        Write-Host "Syncing monitors..." -ForegroundColor Cyan

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        Write-Host ""
        Write-Host "Sync complete!" -ForegroundColor Green
        Write-Host "  Devices in WUG:              $($wugDeviceMap.Count)" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created: $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:          $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):      $($result.Skipped)" -ForegroundColor White
        Write-Host "  Attributes set:               $($result.AttrsUpdated)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            Write-Host "  Failed:                       $($result.Failed)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Done! Monitors pushed to WhatsUp Gold." -ForegroundColor Green
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
        # Generate AWS HTML Dashboard with live data
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Fetching AWS resource data..." -ForegroundColor Cyan

        # Re-authenticate
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AWSCred.Password)
        try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

        try {
            Connect-AWSProfile -AccessKey $AWSCred.UserName -SecretKey $plainSK -Region $AWSRegions[0]
        }
        catch {
            Write-Error "Failed to connect to AWS: $_"
            return
        }

        $dashboardRows = Get-AWSDashboard -Regions $AWSRegions

        if (-not $dashboardRows -or $dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashReportTitle = "AWS Dashboard"
            $dashTempPath = Join-Path $OutputDir 'AWS-Dashboard.html'

            $null = Export-AWSDiscoveryDashboardHtml `
                -DashboardData $dashboardRows `
                -OutputPath $dashTempPath `
                -ReportTitle $dashReportTitle

            Write-Host ""
            Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
            $dEC2  = @($dashboardRows | Where-Object { $_.ResourceType -eq 'EC2' }).Count
            $dRDS  = @($dashboardRows | Where-Object { $_.ResourceType -eq 'RDS' }).Count
            $dELB  = @($dashboardRows | Where-Object { $_.ResourceType -eq 'ELB' }).Count
            $dRunning = @($dashboardRows | Where-Object { $_.State -eq 'running' -or $_.State -eq 'active' -or $_.State -eq 'available' }).Count
            Write-Host "  EC2: $dEC2  |  RDS: $dRDS  |  ELB: $dELB  |  Active: $dRunning" -ForegroundColor White

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashPath = Join-Path $nmConsolePath 'AWS-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/AWS-Dashboard.html" -ForegroundColor Cyan
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
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\AWS-Dashboard.html'" -ForegroundColor Cyan
            }
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDie2WYw0XHDn0H
# 1NwYYJCHX7G1mwnV7gfJ4eByR59osaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgcwIRXwnrmurdXap3/ThKW2aFa6tBy9Ho
# QbLWDnxojhowDQYJKoZIhvcNAQEBBQAEggIAHijHUHYRYFUjW4tSW1Hf6Uo3lGbA
# 7R4EFfqSAZ67bZJoZ1xwWTbpTwLD61fdbOdgiDLlWWjbEiI0Zi2K4bHkgGSnxRHq
# c+MZB6WfzO5JF4FsD7umk8AgIBItxVddNvb6gqJDy2fqq6uS4w0/+yPPLMzVB8CF
# l30gNp9gM5fqAV7eXvgeLLmYOlqI7cwx7V0LqGvHN+cE+YHSnpVUgjuOxhoTv4la
# 9NG1Lm7QW0Ja6hz7IMiNLa1HerbKkQhaXFft9QcresfrlfcTIN4YvjpyneB0hhoJ
# LRQxQVPfsNNpzLJ2nUpYj2yctyJzaPxdp/W+SWOcy7hpiyk5cw5SlTdF6yv8upgl
# Z1gpTMoZ4EpcNIZzWViIwShVLhp1pnacfHX84eeHRVFrS5PWlXy8BapUasq6vjw9
# pOuSsoybPBosNLVBjEUqiDQeSa5ltih7FvNhvXOFbSG5s3/sDR/fFzMhu+gxlYSA
# YwAdxvy4OCwN/AjAdQOvgZlQ93AeyLxZQOLHmEDEuT2xCuRMc6WrspXu5svJZxET
# dj/BAElG+0JrRiEqtFp0Ln8hRgAL2A12xlhKFgcIGXqV5/NYt39xZyIZfQzuKbWD
# BX027rVzK2JFaYX+KuuvP6jacFiHi40FbNnEkzPsBghIuQCsCTiJv0t6aW1jwjH8
# Amn/DDpwe5iyeSM=
# SIG # End signature block
