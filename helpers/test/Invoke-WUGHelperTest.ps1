<#
.SYNOPSIS
    End-to-end integration test harness for WhatsUpGoldPS cloud and infrastructure helpers.
.DESCRIPTION
    Tests every function in the helpers directory (AWS, Azure, GCP, OCI, Proxmox,
    Hyper-V, Nutanix) against live APIs. Prompts for credentials at runtime —
    nothing is stored on disk. Produces a unified pass/fail/skip summary and
    interactive HTML reports.
.PARAMETER TestAWS
    Include AWS helper tests. Default $true.
.PARAMETER TestAzure
    Include Azure helper tests. Default $true.
.PARAMETER TestGCP
    Include GCP helper tests. Default $true.
.PARAMETER TestOCI
    Include OCI helper tests. Default $true.
.PARAMETER TestProxmox
    Include Proxmox helper tests. Default $true.
.PARAMETER TestHyperV
    Include Hyper-V helper tests. Default $true.
.PARAMETER TestNutanix
    Include Nutanix helper tests. Default $true.
.PARAMETER AWSRegion
    Default AWS region. Prompted at runtime if omitted.
.PARAMETER AzureTenantId
    Azure tenant ID. Prompted at runtime if omitted.
.PARAMETER OutputHtmlPath
    Directory for HTML reports. Defaults to $env:TEMP.
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1
    # Prompts for all provider credentials and runs all tests.
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1 -TestAWS $false -TestGCP $false -TestOCI $false -TestProxmox $false -TestHyperV $false -TestNutanix $false
    # Runs only Azure tests.
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1 -AWSRegion "us-east-1" -OutputHtmlPath "C:\Reports"
    # Pre-sets AWS region and HTML output; prompts for secrets only.
.NOTES
    Author  : jason@wug.ninja
    Created : 2026-03-13
    Requires: Provider-specific modules are auto-installed if missing (with user consent).
#>
[CmdletBinding()]
param(
    [bool]$TestAWS     = $true,
    [bool]$TestAzure   = $true,
    [bool]$TestGCP     = $true,
    [bool]$TestOCI     = $true,
    [bool]$TestProxmox = $true,
    [bool]$TestHyperV  = $true,
    [bool]$TestNutanix = $true,
    [string]$AWSRegion,
    [string]$AzureTenantId,
    [string]$OutputHtmlPath
)

#region ── Helpers ────────────────────────────────────────────────────────────
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Record-Test {
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [string]$Status,
        [string]$Detail = ''
    )
    $script:TestResults.Add([PSCustomObject]@{
        Cmdlet   = $Cmdlet
        Endpoint = $Endpoint
        Status   = $Status
        Detail   = $Detail
    })
    $color = switch ($Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } default { 'Yellow' } }
    Write-Host "  [$Status] $Cmdlet  ($Endpoint)  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [scriptblock]$Test
    )
    try {
        $null = & $Test
        Record-Test -Cmdlet $Cmdlet -Endpoint $Endpoint -Status 'Pass'
    }
    catch {
        Record-Test -Cmdlet $Cmdlet -Endpoint $Endpoint -Status 'Fail' -Detail $_.Exception.Message
    }
}

function Assert-NotNull {
    param($Value, [string]$Message = "Value was null or empty")
    if ($null -eq $Value) { throw $Message }
}

function Assert-HasProperty {
    param($Object, [string[]]$Properties)
    foreach ($p in $Properties) {
        if ($null -eq $Object.PSObject.Properties[$p]) {
            throw "Object missing expected property: $p"
        }
    }
}

function Skip-ProviderTests {
    param([string]$Provider, [string]$Reason, [string[]]$Cmdlets)
    foreach ($c in $Cmdlets) {
        Record-Test -Cmdlet $c -Endpoint "$Provider / (skipped)" -Status 'Skipped' -Detail $Reason
    }
}

function Export-TestResultsHtml {
    param(
        [Parameter(Mandatory)]$TestResults,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$TemplatePath,
        [string]$ReportTitle = 'WhatsUpGoldPS Helper Test Results'
    )
    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "Report template not found at $TemplatePath — skipping HTML report."
        return $false
    }
    $columns = @(
        @{ field = 'Cmdlet';   title = 'Cmdlet';   sortable = $true; searchable = $true }
        @{ field = 'Endpoint'; title = 'Endpoint'; sortable = $true; searchable = $true }
        @{ field = 'Status';   title = 'Status';   sortable = $true; searchable = $true; formatter = 'formatStatus' }
        @{ field = 'Detail';   title = 'Detail';   sortable = $true; searchable = $true }
    )
    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson = @($TestResults | Select-Object Cmdlet, Endpoint, Status, Detail) | ConvertTo-Json -Depth 5 -Compress
    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@
    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $statusFn = @"

    function formatStatus(value) {
        if (value === 'Pass') return '<span class="badge bg-success">Pass</span>';
        if (value === 'Fail') return '<span class="badge bg-danger">Fail</span>';
        if (value === 'Skipped') return '<span class="badge bg-warning text-dark">Skipped</span>';
        return value;
    }

"@
    $html = $html.Replace('    function escapeHtml(text) {', "${statusFn}    function escapeHtml(text) {")
    $html = $html -replace '(?s)return rows\.map\(row => \(\{.*?\}\)\);', 'return rows;'
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    return $true
}

function Install-RequiredModule {
    param([string]$ModuleName, [string]$Provider, [string]$InstallHint)
    if (Get-Module -ListAvailable -Name $ModuleName) { return $true }
    Write-Host "  Module '$ModuleName' required for $Provider tests is not installed." -ForegroundColor Yellow
    Write-Host "  Install command: $InstallHint" -ForegroundColor DarkGray
    $choice = Read-Host "  Install now? [Y/N]"
    if ($choice -match '^[Yy]') {
        try {
            Write-Host "  Installing $ModuleName ..." -ForegroundColor DarkGray
            Invoke-Expression $InstallHint
            return $null -ne (Get-Module -ListAvailable -Name $ModuleName)
        }
        catch {
            Write-Warning "  Failed to install ${ModuleName}: $($_.Exception.Message)"
            return $false
        }
    }
    return $false
}
#endregion

#region ── Cmdlet Lists ───────────────────────────────────────────────────────
$script:AWSCmdletList = @(
    'Connect-AWSProfile','Get-AWSRegionList',
    'Get-AWSEC2Instances','Get-AWSEC2Instances (filtered)',
    'Get-AWSRDSInstances','Get-AWSRDSInstances (filtered)',
    'Get-AWSLoadBalancers','Get-AWSLoadBalancers (filtered)',
    'Resolve-AWSResourceIP (EC2)','Resolve-AWSResourceIP (RDS)','Resolve-AWSResourceIP (ELB)',
    'Get-AWSCloudWatchMetrics (EC2 default)','Get-AWSCloudWatchMetrics (EC2 single)','Get-AWSCloudWatchMetrics (RDS)',
    'Get-AWSDashboard (default)','Get-AWSDashboard (no RDS)','Get-AWSDashboard (no ELB)','Get-AWSDashboard (multi-region)',
    'Export-AWSDashboardHtml','AWS Session Cleanup'
)
$script:AzureCmdletList = @(
    'Azure Authentication','Get-AzureSubscriptions','Get-AzureResourceGroups','Get-AzureResources',
    'Get-AzureResourceMetrics (default)','Get-AzureResourceMetrics (MaxMetrics=3)',
    'Get-AzureResourceDetail (metrics)','Get-AzureResourceDetail (no metrics)',
    'Resolve-AzureResourceIP',
    'Get-AzureDashboard (no metrics)','Get-AzureDashboard (with metrics)','Get-AzureDashboard (SubId)',
    'Export-AzureDashboardHtml','Azure Session Disconnect'
)
$script:GCPCmdletList = @(
    'Connect-GCPAccount','Get-GCPProjects',
    'Get-GCPComputeInstances','Get-GCPCloudSQLInstances','Get-GCPForwardingRules',
    'Resolve-GCPResourceIP (Compute)','Resolve-GCPResourceIP (CloudSQL)','Resolve-GCPResourceIP (ForwardingRule)',
    'Get-GCPCloudMonitoringMetrics',
    'Get-GCPDashboard (default)','Get-GCPDashboard (no CloudSQL)','Get-GCPDashboard (no Forwarding)',
    'Export-GCPDashboardHtml'
)
$script:OCICmdletList = @(
    'Connect-OCIProfile','Get-OCICompartments',
    'Get-OCIComputeInstances','Get-OCIDBSystems','Get-OCIAutonomousDatabases','Get-OCILoadBalancers',
    'Resolve-OCIResourceIP (Compute)','Resolve-OCIResourceIP (DBSystem)',
    'Get-OCIMonitoringMetrics',
    'Get-OCIDashboard (default)','Get-OCIDashboard (no DB)','Get-OCIDashboard (no LB)',
    'Export-OCIDashboardHtml'
)
$script:ProxmoxCmdletList = @(
    'Connect-ProxmoxServer','Get-ProxmoxNodes',
    'Get-ProxmoxVMs','Get-ProxmoxNodeDetail','Get-ProxmoxVMDetail',
    'Get-ProxmoxDashboard','Export-ProxmoxDashboardHtml',
    'Proxmox Session Cleanup'
)
$script:HyperVCmdletList = @(
    'Connect-HypervHost','Get-HypervHostDetail',
    'Get-HypervVMs','Get-HypervVMDetail',
    'Get-HypervDashboard','Export-HypervDashboardHtml',
    'HyperV Session Cleanup'
)
$script:NutanixCmdletList = @(
    'Connect-NutanixCluster','Get-NutanixCluster',
    'Get-NutanixHosts','Get-NutanixVMs',
    'Get-NutanixHostDetail','Get-NutanixVMDetail',
    'Get-NutanixDashboard','Export-NutanixDashboardHtml'
)
#endregion

#region ── Helper File Import ─────────────────────────────────────────────────
$helpersRoot = Split-Path -Parent $PSScriptRoot

$helperFiles = @{
    AWS     = Join-Path $helpersRoot 'aws\AWSHelpers.ps1'
    Azure   = Join-Path $helpersRoot 'azure\AzureHelpers.ps1'
    GCP     = Join-Path $helpersRoot 'gcp\GCPHelpers.ps1'
    OCI     = Join-Path $helpersRoot 'oci\OCIHelpers.ps1'
    Proxmox = Join-Path $helpersRoot 'proxmox\ProxmoxHelpers.ps1'
    HyperV  = Join-Path $helpersRoot 'hyperv\HypervHelpers.ps1'
    Nutanix = Join-Path $helpersRoot 'nutanix\NutanixHelpers.ps1'
}

$providerToggle = @{
    AWS = [ref]$TestAWS;  Azure = [ref]$TestAzure; GCP = [ref]$TestGCP; OCI = [ref]$TestOCI
    Proxmox = [ref]$TestProxmox; HyperV = [ref]$TestHyperV; Nutanix = [ref]$TestNutanix
}

foreach ($provider in $helperFiles.Keys) {
    $toggle = $providerToggle[$provider]
    if ($toggle.Value) {
        $path = $helperFiles[$provider]
        if (Test-Path $path) {
            . $path
        } else {
            Write-Warning "$provider helper not found at $path — tests will be skipped."
            $toggle.Value = $false
        }
    }
}
#endregion

#region ── Dependency Checks + Auto-Install ───────────────────────────────────
Write-Host "`n─── Checking module dependencies ───" -ForegroundColor Cyan

if ($TestAWS) {
    if (-not (Install-RequiredModule -ModuleName 'AWS.Tools.EC2' -Provider 'AWS' `
        -InstallHint 'Install-Module -Name AWS.Tools.Installer -Scope CurrentUser -Force; Install-AWSToolsModule EC2,RDS,ElasticLoadBalancingV2,CloudWatch -CleanUp -Force')) {
        Write-Warning "AWS tests will be skipped."; $TestAWS = $false
    }
}
if ($TestAzure) {
    if (-not (Install-RequiredModule -ModuleName 'Az.Accounts' -Provider 'Azure' `
        -InstallHint 'Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force')) {
        Write-Warning "Azure tests will be skipped."; $TestAzure = $false
    }
}
if ($TestGCP) {
    if (-not (Install-RequiredModule -ModuleName 'GoogleCloud' -Provider 'GCP' `
        -InstallHint 'Install-Module -Name GoogleCloud -Scope CurrentUser -Force')) {
        Write-Warning "GoogleCloud module not available. GCP tests will be skipped."; $TestGCP = $false
    }
    if ($TestGCP) {
        $gcloudOk = $null -ne (Get-Command gcloud -ErrorAction SilentlyContinue)
        if (-not $gcloudOk) {
            Write-Warning "gcloud CLI not found in PATH. Install from: https://cloud.google.com/sdk/docs/install"
            Write-Warning "GCP tests will be skipped."; $TestGCP = $false
        }
    }
}
if ($TestOCI) {
    if (-not (Install-RequiredModule -ModuleName 'OCI.PSModules.Identity' -Provider 'OCI' `
        -InstallHint 'Install-Module -Name OCI.PSModules -Scope CurrentUser -Force')) {
        Write-Warning "OCI tests will be skipped."; $TestOCI = $false
    }
}
if ($TestHyperV) {
    if (-not (Get-Module -ListAvailable -Name 'Hyper-V')) {
        Write-Host "  Module 'Hyper-V' required for HyperV tests is not installed." -ForegroundColor Yellow
        Write-Host "  This is a Windows Optional Feature, not a PSGallery module." -ForegroundColor DarkGray
        Write-Host "  Install command (requires Admin + reboot): Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell" -ForegroundColor DarkGray
        $hvInstall = Read-Host "  Install now? [Y/N]"
        if ($hvInstall -match '^[Yy]') {
            try {
                Write-Host "  Enabling Hyper-V Management PowerShell feature ..." -ForegroundColor DarkGray
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All -NoRestart -ErrorAction Stop | Out-Null
                if (-not (Get-Module -ListAvailable -Name 'Hyper-V')) {
                    Write-Warning "Feature enabled but module not yet available. A reboot may be required."
                    $TestHyperV = $false
                }
            } catch {
                Write-Warning "Failed to enable feature: $($_.Exception.Message)"
                $TestHyperV = $false
            }
        } else {
            $TestHyperV = $false
        }
        if (-not $TestHyperV) { Write-Warning "Hyper-V tests will be skipped." }
    }
}

$activeProviders = @()
if ($TestAWS)     { $activeProviders += 'AWS' }
if ($TestAzure)   { $activeProviders += 'Azure' }
if ($TestGCP)     { $activeProviders += 'GCP' }
if ($TestOCI)     { $activeProviders += 'OCI' }
if ($TestProxmox) { $activeProviders += 'Proxmox' }
if ($TestHyperV)  { $activeProviders += 'HyperV' }
if ($TestNutanix) { $activeProviders += 'Nutanix' }

if ($activeProviders.Count -eq 0) {
    Write-Error "All providers are disabled or unavailable. Nothing to test."
    return
}
#endregion

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " WhatsUpGoldPS Helper End-to-End Test Suite" -ForegroundColor Cyan
Write-Host " Active providers: $($activeProviders -join ', ')" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

$outDir = if ($OutputHtmlPath) { $OutputHtmlPath } else { $env:TEMP }
$sectionCount = $activeProviders.Count + 1
$currentSection = 0

###############################################################################
#region ── AWS ────────────────────────────────────────────────────────────────
###############################################################################
$script:AWSAuthMethod = $null
$script:AWSHtmlOutPath = $null
$script:AWSDashboardData = $null

if ($TestAWS) {
    Write-Host "AWS Authentication — choose a method:" -ForegroundColor Cyan
    Write-Host "  [1] Access Key + Secret Key"
    Write-Host "  [2] Named AWS credential profile"
    Write-Host "  [S] Skip AWS tests"
    $awsChoice = Read-Host "Selection"
    switch ($awsChoice.Trim().ToUpper()) {
        '1' {
            $script:AWSAuthMethod = 'Keys'
            $script:AWSAccessKey = Read-Host "AWS Access Key ID"
            $script:AWSSecretKeySS = Read-Host "AWS Secret Access Key" -AsSecureString
        }
        '2' {
            $script:AWSAuthMethod = 'Profile'
            $script:AWSProfileName = Read-Host "AWS Profile Name"
        }
        default { $TestAWS = $false }
    }
    if ($TestAWS -and -not $AWSRegion) {
        $AWSRegion = Read-Host "AWS Region [us-east-1]"
        if ([string]::IsNullOrWhiteSpace($AWSRegion)) { $AWSRegion = 'us-east-1' }
    }
    if (-not $TestAWS) { Skip-ProviderTests -Provider 'AWS' -Reason 'User skipped' -Cmdlets $script:AWSCmdletList }
} else {
    Skip-ProviderTests -Provider 'AWS' -Reason 'Disabled or modules unavailable' -Cmdlets $script:AWSCmdletList
}

if ($TestAWS) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing AWS ..." -ForegroundColor Cyan

    $script:FirstEC2Instance = $null; $script:FirstRDSInstance = $null; $script:FirstELB = $null

    Invoke-Test -Cmdlet 'Connect-AWSProfile' -Endpoint 'AWS / Auth / Connect-AWSProfile' -Test {
        switch ($script:AWSAuthMethod) {
            'Keys' {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AWSSecretKeySS)
                try {
                    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    Connect-AWSProfile -AccessKey $script:AWSAccessKey -SecretKey $plain -Region $AWSRegion -ErrorAction Stop
                } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
            'Profile' { Connect-AWSProfile -ProfileName $script:AWSProfileName -Region $AWSRegion -ErrorAction Stop }
        }
        $regionCheck = Get-EC2Region -Region $AWSRegion -ErrorAction Stop
        if (-not $regionCheck) { throw "Region validation failed" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestAWS = $false
        Skip-ProviderTests -Provider 'AWS' -Reason 'Auth failed' -Cmdlets ($script:AWSCmdletList | Where-Object { $_ -ne 'Connect-AWSProfile' })
    }

    if ($TestAWS) {
        Invoke-Test -Cmdlet 'Get-AWSRegionList' -Endpoint 'AWS / EC2 / Get-AWSRegionList' -Test {
            $r = Get-AWSRegionList -ErrorAction Stop; Assert-NotNull $r; Assert-HasProperty $r[0] @('RegionName')
        }
        Invoke-Test -Cmdlet 'Get-AWSEC2Instances' -Endpoint 'AWS / EC2 / Get-AWSEC2Instances' -Test {
            $r = Get-AWSEC2Instances -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { Assert-HasProperty $r[0] @('InstanceId','Name','State','PrivateIP'); $script:FirstEC2Instance = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-AWSEC2Instances (filtered)' -Endpoint 'AWS / EC2 / Get-AWSEC2Instances -Region' -Test {
            $r = Get-AWSEC2Instances -Region $AWSRegion -ErrorAction Stop
            if ($r -and @($r).Count -gt 0 -and -not $script:FirstEC2Instance) { $script:FirstEC2Instance = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-AWSRDSInstances' -Endpoint 'AWS / RDS / Get-AWSRDSInstances' -Test {
            $r = Get-AWSRDSInstances -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { Assert-HasProperty $r[0] @('DBInstanceId','Engine','Status','Endpoint'); $script:FirstRDSInstance = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-AWSRDSInstances (filtered)' -Endpoint 'AWS / RDS / Get-AWSRDSInstances -Region' -Test {
            $r = Get-AWSRDSInstances -Region $AWSRegion -ErrorAction Stop
            if ($r -and @($r).Count -gt 0 -and -not $script:FirstRDSInstance) { $script:FirstRDSInstance = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-AWSLoadBalancers' -Endpoint 'AWS / ELB / Get-AWSLoadBalancers' -Test {
            $r = Get-AWSLoadBalancers -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { Assert-HasProperty $r[0] @('LoadBalancerName','Type','State','DNSName'); $script:FirstELB = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-AWSLoadBalancers (filtered)' -Endpoint 'AWS / ELB / Get-AWSLoadBalancers -Region' -Test {
            $r = Get-AWSLoadBalancers -Region $AWSRegion -ErrorAction Stop
            if ($r -and @($r).Count -gt 0 -and -not $script:FirstELB) { $script:FirstELB = $r[0] }
        }
        foreach ($t in @(@{N='EC2';V=$script:FirstEC2Instance},@{N='RDS';V=$script:FirstRDSInstance},@{N='ELB';V=$script:FirstELB})) {
            if ($t.V) {
                Invoke-Test -Cmdlet "Resolve-AWSResourceIP ($($t.N))" -Endpoint "AWS / IP / Resolve-AWSResourceIP $($t.N)" -Test {
                    Resolve-AWSResourceIP -ResourceType $t.N -Resource $t.V -ErrorAction Stop | Out-Null
                }
            } else {
                Record-Test -Cmdlet "Resolve-AWSResourceIP ($($t.N))" -Endpoint "AWS / IP / Resolve-AWSResourceIP $($t.N)" -Status 'Skipped' -Detail "No $($t.N) resources found"
            }
        }
        if ($script:FirstEC2Instance) {
            Invoke-Test -Cmdlet 'Get-AWSCloudWatchMetrics (EC2 default)' -Endpoint 'AWS / CW / EC2 default' -Test {
                Get-AWSCloudWatchMetrics -Namespace 'AWS/EC2' -DimensionName 'InstanceId' -DimensionValue $script:FirstEC2Instance.InstanceId -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-AWSCloudWatchMetrics (EC2 single)' -Endpoint 'AWS / CW / EC2 single metric' -Test {
                $r = Get-AWSCloudWatchMetrics -Namespace 'AWS/EC2' -DimensionName 'InstanceId' -DimensionValue $script:FirstEC2Instance.InstanceId -MetricNames @('CPUUtilization') -ErrorAction Stop
                if ($r -and @($r).Count -gt 0 -and $r[0].MetricName -ne 'CPUUtilization') { throw "Wrong metric returned" }
            }
        } else {
            Record-Test -Cmdlet 'Get-AWSCloudWatchMetrics (EC2 default)' -Endpoint 'AWS / CW / EC2 default' -Status 'Skipped' -Detail 'No EC2 instances'
            Record-Test -Cmdlet 'Get-AWSCloudWatchMetrics (EC2 single)' -Endpoint 'AWS / CW / EC2 single metric' -Status 'Skipped' -Detail 'No EC2 instances'
        }
        if ($script:FirstRDSInstance) {
            Invoke-Test -Cmdlet 'Get-AWSCloudWatchMetrics (RDS)' -Endpoint 'AWS / CW / RDS' -Test {
                Get-AWSCloudWatchMetrics -Namespace 'AWS/RDS' -DimensionName 'DBInstanceIdentifier' -DimensionValue $script:FirstRDSInstance.DBInstanceId -ErrorAction Stop | Out-Null
            }
        } else { Record-Test -Cmdlet 'Get-AWSCloudWatchMetrics (RDS)' -Endpoint 'AWS / CW / RDS' -Status 'Skipped' -Detail 'No RDS instances' }
        Invoke-Test -Cmdlet 'Get-AWSDashboard (default)' -Endpoint 'AWS / Dashboard / Get-AWSDashboard' -Test {
            $script:AWSDashboardData = Get-AWSDashboard -ErrorAction Stop; Assert-NotNull $script:AWSDashboardData
        }
        Invoke-Test -Cmdlet 'Get-AWSDashboard (no RDS)' -Endpoint 'AWS / Dashboard / -IncludeRDS $false' -Test { Get-AWSDashboard -IncludeRDS $false -ErrorAction Stop | Out-Null }
        Invoke-Test -Cmdlet 'Get-AWSDashboard (no ELB)' -Endpoint 'AWS / Dashboard / -IncludeELB $false' -Test { Get-AWSDashboard -IncludeELB $false -ErrorAction Stop | Out-Null }
        Invoke-Test -Cmdlet 'Get-AWSDashboard (multi-region)' -Endpoint 'AWS / Dashboard / -Regions' -Test { Get-AWSDashboard -Regions @($AWSRegion) -ErrorAction Stop | Out-Null }
        $awsTpl = Join-Path $helpersRoot 'aws\AWS-Dashboard-Template.html'
        if ($script:AWSDashboardData -and @($script:AWSDashboardData).Count -gt 0 -and (Test-Path $awsTpl)) {
            Invoke-Test -Cmdlet 'Export-AWSDashboardHtml' -Endpoint 'AWS / Export / Export-AWSDashboardHtml' -Test {
                $script:AWSHtmlOutPath = Join-Path $outDir "Get-AWSDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-AWSDashboardHtml -DashboardData $script:AWSDashboardData -OutputPath $script:AWSHtmlOutPath -ReportTitle 'WUGHelperTest AWS' -TemplatePath $awsTpl -ErrorAction Stop
                if (-not (Test-Path $script:AWSHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-AWSDashboardHtml' -Endpoint 'AWS / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── Azure ──────────────────────────────────────────────────────────────
###############################################################################
$script:AzureAuthMethod = $null; $script:AzureHtmlOutPath = $null; $script:AzureDashboardData = $null

if ($TestAzure) {
    Write-Host "`nAzure Authentication — choose a method:" -ForegroundColor Cyan
    Write-Host "  [1] Service Principal  [2] Interactive browser  [3] Current Az context  [S] Skip"
    $azChoice = Read-Host "Selection"
    switch ($azChoice.Trim().ToUpper()) {
        '1' {
            $script:AzureAuthMethod = 'ServicePrincipal'
            if (-not $AzureTenantId) { $AzureTenantId = Read-Host "Azure Tenant ID" }
            $script:AzureAppId = Read-Host "Application (Client) ID"
            $script:AzureClientSecretSS = Read-Host "Client Secret" -AsSecureString
        }
        '2' { $script:AzureAuthMethod = 'Interactive' }
        '3' { $script:AzureAuthMethod = 'Existing' }
        default { $TestAzure = $false }
    }
    if (-not $TestAzure) { Skip-ProviderTests -Provider 'Azure' -Reason 'User skipped' -Cmdlets $script:AzureCmdletList }
} else { Skip-ProviderTests -Provider 'Azure' -Reason 'Disabled or modules unavailable' -Cmdlets $script:AzureCmdletList }

if ($TestAzure) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Azure ..." -ForegroundColor Cyan

    $script:AzureTestSub = $null; $script:AzureTestRG = $null; $script:FirstAzureResource = $null

    Invoke-Test -Cmdlet 'Azure Authentication' -Endpoint 'Azure / Auth / Connect-Az*' -Test {
        switch ($script:AzureAuthMethod) {
            'ServicePrincipal' {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AzureClientSecretSS)
                try {
                    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    Connect-AzureServicePrincipal -TenantId $AzureTenantId -ApplicationId $script:AzureAppId -ClientSecret $plain -ErrorAction Stop
                } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
            'Interactive' { Connect-AzAccount -ErrorAction Stop }
            'Existing' { $ctx = Get-AzContext -ErrorAction Stop; if (-not $ctx -or -not $ctx.Account) { throw "No Az context" } }
        }
        $ctx = Get-AzContext -ErrorAction Stop; if (-not $ctx.Account) { throw "No account after auth" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestAzure = $false
        Skip-ProviderTests -Provider 'Azure' -Reason 'Auth failed' -Cmdlets ($script:AzureCmdletList | Where-Object { $_ -ne 'Azure Authentication' })
    }

    if ($TestAzure) {
        Invoke-Test -Cmdlet 'Get-AzureSubscriptions' -Endpoint 'Azure / Account / Get-AzureSubscriptions' -Test {
            $r = Get-AzureSubscriptions -ErrorAction Stop; Assert-NotNull $r
            Assert-HasProperty $r[0] @('SubscriptionId','SubscriptionName')
            $script:AzureSubs = @($r | Where-Object { $_.State -eq 'Enabled' })
            if ($script:AzureSubs.Count -eq 0) { throw "No enabled subscriptions" }
        }
        if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:AzureSubs) {
            if ($script:AzureSubs.Count -gt 1) {
                Write-Host "`nSubscriptions:"
                for ($i=0;$i -lt $script:AzureSubs.Count;$i++) { Write-Host "  [$i] $($script:AzureSubs[$i].SubscriptionName)" }
                $idx = [int](Read-Host "Index [0]"); if ($idx -lt 0 -or $idx -ge $script:AzureSubs.Count) { $idx = 0 }
                $script:AzureTestSub = $script:AzureSubs[$idx]
            } else { $script:AzureTestSub = $script:AzureSubs[0] }
            Set-AzContext -SubscriptionId $script:AzureTestSub.SubscriptionId -ErrorAction Stop | Out-Null
        }
        if ($script:AzureTestSub) {
            Invoke-Test -Cmdlet 'Get-AzureResourceGroups' -Endpoint 'Azure / Resources / Get-AzureResourceGroups' -Test {
                $r = Get-AzureResourceGroups -ErrorAction Stop; Assert-NotNull $r; $script:AzureRGs = @($r)
            }
            $script:AzureTestRGList = @()
            if ($script:AzureRGs -and $script:AzureRGs.Count -gt 0) {
                Write-Host "`nResource Groups:"
                Write-Host "  [A] All resource groups (cycle through each)"
                for ($i=0;$i -lt $script:AzureRGs.Count;$i++) { Write-Host "  [$i] $($script:AzureRGs[$i].ResourceGroupName)" }
                $rgInput = (Read-Host "Selection [A]").Trim()
                if ($rgInput -match '^\d+$') {
                    $rgIdx = [int]$rgInput
                    if ($rgIdx -ge 0 -and $rgIdx -lt $script:AzureRGs.Count) {
                        $script:AzureTestRGList = @($script:AzureRGs[$rgIdx].ResourceGroupName)
                    } else { $script:AzureTestRGList = @($script:AzureRGs[0].ResourceGroupName) }
                } else {
                    $script:AzureTestRGList = @($script:AzureRGs | ForEach-Object { $_.ResourceGroupName })
                }
            }
        }
        # Cycle through selected resource group(s)
        foreach ($currentRG in $script:AzureTestRGList) {
            $rgLabel = $currentRG
            Write-Host "    ── Resource Group: $rgLabel ──" -ForegroundColor DarkCyan

            $rgResource = $null
            Invoke-Test -Cmdlet "Get-AzureResources ($rgLabel)" -Endpoint "Azure / Resources / $rgLabel" -Test {
                $r = Get-AzureResources -ResourceGroupName $currentRG -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) { $script:_tmpRes = @($r)[0] } else { $script:_tmpRes = $null }
            }
            $rgResource = $script:_tmpRes

            if ($rgResource) {
                Invoke-Test -Cmdlet "Get-AzureResourceMetrics ($rgLabel)" -Endpoint "Azure / Monitor / $rgLabel" -Test {
                    Get-AzureResourceMetrics -ResourceId $rgResource.ResourceId -ErrorAction Stop | Out-Null
                }
                Invoke-Test -Cmdlet "Get-AzureResourceMetrics MaxMetrics ($rgLabel)" -Endpoint "Azure / Monitor / $rgLabel MaxMetrics 3" -Test {
                    $r = Get-AzureResourceMetrics -ResourceId $rgResource.ResourceId -MaxMetrics 3 -ErrorAction Stop
                    if ($r -and @($r).Count -gt 3) { throw "Got $(@($r).Count) metrics, expected <=3" }
                }
                Invoke-Test -Cmdlet "Get-AzureResourceDetail metrics ($rgLabel)" -Endpoint "Azure / Detail / $rgLabel IncludeMetrics" -Test {
                    $r = Get-AzureResourceDetail -Resource $rgResource -SubscriptionName $script:AzureTestSub.SubscriptionName -SubscriptionId $script:AzureTestSub.SubscriptionId -ResourceGroupName $currentRG -IncludeMetrics $true -ErrorAction Stop
                    Assert-HasProperty $r @('ResourceName','ResourceType','SubscriptionName','MetricsSummary')
                }
                Invoke-Test -Cmdlet "Get-AzureResourceDetail no-metrics ($rgLabel)" -Endpoint "Azure / Detail / $rgLabel NoMetrics" -Test {
                    $r = Get-AzureResourceDetail -Resource $rgResource -SubscriptionName $script:AzureTestSub.SubscriptionName -SubscriptionId $script:AzureTestSub.SubscriptionId -ResourceGroupName $currentRG -IncludeMetrics $false -ErrorAction Stop
                    Assert-HasProperty $r @('ResourceName','ResourceType','SubscriptionName','MetricsSummary')
                }
                Invoke-Test -Cmdlet "Resolve-AzureResourceIP ($rgLabel)" -Endpoint "Azure / IP / $rgLabel" -Test {
                    Resolve-AzureResourceIP -Resource $rgResource -ErrorAction Stop | Out-Null
                }
                # Capture the first resource found across all RGs for dashboard tests
                if (-not $script:FirstAzureResource) { $script:FirstAzureResource = $rgResource }
            } else {
                Record-Test -Cmdlet "Get-AzureResources ($rgLabel)" -Endpoint "Azure / Resources / $rgLabel" -Status 'Skipped' -Detail "No resources in $rgLabel"
            }
        }
        if ($script:AzureTestRGList.Count -eq 0) {
            foreach ($c in @('Get-AzureResources','Get-AzureResourceMetrics','Get-AzureResourceDetail','Resolve-AzureResourceIP')) {
                Record-Test -Cmdlet $c -Endpoint 'Azure / (skipped)' -Status 'Skipped' -Detail 'No resource groups available'
            }
        }
        if ($script:AzureTestSub) {
            Invoke-Test -Cmdlet 'Get-AzureDashboard (no metrics)' -Endpoint 'Azure / Dashboard / -IncludeMetrics $false' -Test {
                $script:AzureDashboardData = Get-AzureDashboard -SubscriptionIds @($script:AzureTestSub.SubscriptionId) -IncludeMetrics $false -ErrorAction Stop
                Assert-NotNull $script:AzureDashboardData
            }
            Invoke-Test -Cmdlet 'Get-AzureDashboard (with metrics)' -Endpoint 'Azure / Dashboard / -IncludeMetrics $true' -Test {
                Get-AzureDashboard -SubscriptionIds @($script:AzureTestSub.SubscriptionId) -IncludeMetrics $true -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-AzureDashboard (SubId)' -Endpoint 'Azure / Dashboard / -SubscriptionIds' -Test {
                Get-AzureDashboard -SubscriptionIds $script:AzureTestSub.SubscriptionId -ErrorAction Stop | Out-Null
            }
        }
        $azTpl = Join-Path $helpersRoot 'azure\Azure-Dashboard-Template.html'
        if ($script:AzureDashboardData -and @($script:AzureDashboardData).Count -gt 0 -and (Test-Path $azTpl)) {
            Invoke-Test -Cmdlet 'Export-AzureDashboardHtml' -Endpoint 'Azure / Export / Export-AzureDashboardHtml' -Test {
                $script:AzureHtmlOutPath = Join-Path $outDir "Get-AzureDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-AzureDashboardHtml -DashboardData $script:AzureDashboardData -OutputPath $script:AzureHtmlOutPath -ReportTitle 'WUGHelperTest Azure' -TemplatePath $azTpl -ErrorAction Stop
                if (-not (Test-Path $script:AzureHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-AzureDashboardHtml' -Endpoint 'Azure / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── GCP ────────────────────────────────────────────────────────────────
###############################################################################
$script:GCPHtmlOutPath = $null; $script:GCPDashboardData = $null

if ($TestGCP) {
    Write-Host "`nGCP Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Service account key file  [S] Skip"
    $gcpChoice = Read-Host "Selection"
    if ($gcpChoice.Trim().ToUpper() -eq '1') {
        $script:GCPKeyFilePath = Read-Host "Path to service account JSON key file"
        $script:GCPProject = Read-Host "GCP Project ID"
    } else { $TestGCP = $false }
    if (-not $TestGCP) { Skip-ProviderTests -Provider 'GCP' -Reason 'User skipped' -Cmdlets $script:GCPCmdletList }
} else { Skip-ProviderTests -Provider 'GCP' -Reason 'Disabled or gcloud not found' -Cmdlets $script:GCPCmdletList }

if ($TestGCP) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing GCP ..." -ForegroundColor Cyan

    $script:FirstGCPVM = $null; $script:FirstGCPSQL = $null; $script:FirstGCPFR = $null

    Invoke-Test -Cmdlet 'Connect-GCPAccount' -Endpoint 'GCP / Auth / Connect-GCPAccount' -Test {
        Connect-GCPAccount -KeyFilePath $script:GCPKeyFilePath -Project $script:GCPProject -ErrorAction Stop
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestGCP = $false
        Skip-ProviderTests -Provider 'GCP' -Reason 'Auth failed' -Cmdlets ($script:GCPCmdletList | Where-Object { $_ -ne 'Connect-GCPAccount' })
    }

    if ($TestGCP) {
        Invoke-Test -Cmdlet 'Get-GCPProjects' -Endpoint 'GCP / Projects / Get-GCPProjects' -Test {
            $r = Get-GCPProjects -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-GCPComputeInstances' -Endpoint 'GCP / Compute / Get-GCPComputeInstances' -Test {
            $r = Get-GCPComputeInstances -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstGCPVM = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-GCPCloudSQLInstances' -Endpoint 'GCP / SQL / Get-GCPCloudSQLInstances' -Test {
            $r = Get-GCPCloudSQLInstances -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstGCPSQL = $r[0] }
        }
        Invoke-Test -Cmdlet 'Get-GCPForwardingRules' -Endpoint 'GCP / LB / Get-GCPForwardingRules' -Test {
            $r = Get-GCPForwardingRules -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstGCPFR = $r[0] }
        }
        foreach ($t in @(@{N='Compute';V=$script:FirstGCPVM},@{N='CloudSQL';V=$script:FirstGCPSQL},@{N='ForwardingRule';V=$script:FirstGCPFR})) {
            if ($t.V) {
                Invoke-Test -Cmdlet "Resolve-GCPResourceIP ($($t.N))" -Endpoint "GCP / IP / $($t.N)" -Test {
                    Resolve-GCPResourceIP -ResourceType $t.N -Resource $t.V -ErrorAction Stop | Out-Null
                }
            } else { Record-Test -Cmdlet "Resolve-GCPResourceIP ($($t.N))" -Endpoint "GCP / IP / $($t.N)" -Status 'Skipped' -Detail "No $($t.N) resources" }
        }
        if ($script:FirstGCPVM) {
            Invoke-Test -Cmdlet 'Get-GCPCloudMonitoringMetrics' -Endpoint 'GCP / Monitoring / Compute' -Test {
                Get-GCPCloudMonitoringMetrics -Project $script:GCPProject -ResourceType 'gce_instance' -ResourceLabels @{ instance_id = $script:FirstGCPVM.InstanceId } -ErrorAction Stop | Out-Null
            }
        } else { Record-Test -Cmdlet 'Get-GCPCloudMonitoringMetrics' -Endpoint 'GCP / Monitoring' -Status 'Skipped' -Detail 'No compute instances' }
        Invoke-Test -Cmdlet 'Get-GCPDashboard (default)' -Endpoint 'GCP / Dashboard / Get-GCPDashboard' -Test {
            $script:GCPDashboardData = Get-GCPDashboard -ErrorAction Stop; Assert-NotNull $script:GCPDashboardData
        }
        Invoke-Test -Cmdlet 'Get-GCPDashboard (no CloudSQL)' -Endpoint 'GCP / Dashboard / -IncludeCloudSQL $false' -Test { Get-GCPDashboard -IncludeCloudSQL $false -ErrorAction Stop | Out-Null }
        Invoke-Test -Cmdlet 'Get-GCPDashboard (no Forwarding)' -Endpoint 'GCP / Dashboard / -IncludeForwardingRules $false' -Test { Get-GCPDashboard -IncludeForwardingRules $false -ErrorAction Stop | Out-Null }
        $gcpTpl = Join-Path $helpersRoot 'gcp\GCP-Dashboard-Template.html'
        if ($script:GCPDashboardData -and @($script:GCPDashboardData).Count -gt 0 -and (Test-Path $gcpTpl)) {
            Invoke-Test -Cmdlet 'Export-GCPDashboardHtml' -Endpoint 'GCP / Export / Export-GCPDashboardHtml' -Test {
                $script:GCPHtmlOutPath = Join-Path $outDir "Get-GCPDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-GCPDashboardHtml -DashboardData $script:GCPDashboardData -OutputPath $script:GCPHtmlOutPath -ReportTitle 'WUGHelperTest GCP' -TemplatePath $gcpTpl -ErrorAction Stop
                if (-not (Test-Path $script:GCPHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-GCPDashboardHtml' -Endpoint 'GCP / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── OCI ────────────────────────────────────────────────────────────────
###############################################################################
$script:OCIHtmlOutPath = $null; $script:OCIDashboardData = $null

if ($TestOCI) {
    Write-Host "`nOCI Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] OCI config file (default ~/.oci/config)  [S] Skip"
    $ociChoice = Read-Host "Selection"
    if ($ociChoice.Trim().ToUpper() -eq '1') {
        $script:OCIConfigFile = Read-Host "Config file path [~/.oci/config]"
        if ([string]::IsNullOrWhiteSpace($script:OCIConfigFile)) { $script:OCIConfigFile = Join-Path $env:USERPROFILE '.oci\config' }
        $script:OCIProfile = Read-Host "Profile name [DEFAULT]"
        if ([string]::IsNullOrWhiteSpace($script:OCIProfile)) { $script:OCIProfile = 'DEFAULT' }
        $script:OCITenancyId = Read-Host "Tenancy OCID"
    } else { $TestOCI = $false }
    if (-not $TestOCI) { Skip-ProviderTests -Provider 'OCI' -Reason 'User skipped' -Cmdlets $script:OCICmdletList }
} else { Skip-ProviderTests -Provider 'OCI' -Reason 'Disabled or modules unavailable' -Cmdlets $script:OCICmdletList }

if ($TestOCI) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing OCI ..." -ForegroundColor Cyan

    $script:FirstOCICompute = $null; $script:FirstOCIDB = $null; $script:OCITestCompartment = $null

    $ociSplat = @{}
    if ($script:OCIConfigFile) { $ociSplat['ConfigFile'] = $script:OCIConfigFile }
    if ($script:OCIProfile)    { $ociSplat['Profile'] = $script:OCIProfile }

    Invoke-Test -Cmdlet 'Connect-OCIProfile' -Endpoint 'OCI / Auth / Connect-OCIProfile' -Test {
        Connect-OCIProfile @ociSplat -ErrorAction Stop
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestOCI = $false
        Skip-ProviderTests -Provider 'OCI' -Reason 'Auth failed' -Cmdlets ($script:OCICmdletList | Where-Object { $_ -ne 'Connect-OCIProfile' })
    }

    if ($TestOCI) {
        Invoke-Test -Cmdlet 'Get-OCICompartments' -Endpoint 'OCI / Identity / Get-OCICompartments' -Test {
            $r = Get-OCICompartments -TenancyId $script:OCITenancyId @ociSplat -ErrorAction Stop; Assert-NotNull $r
            $script:OCITestCompartment = $r[0].CompartmentId
        }
        if ($script:OCITestCompartment) {
            Invoke-Test -Cmdlet 'Get-OCIComputeInstances' -Endpoint 'OCI / Compute / Get-OCIComputeInstances' -Test {
                $r = Get-OCIComputeInstances -CompartmentId $script:OCITestCompartment @ociSplat -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) { $script:FirstOCICompute = $r[0] }
            }
            Invoke-Test -Cmdlet 'Get-OCIDBSystems' -Endpoint 'OCI / DB / Get-OCIDBSystems' -Test {
                $r = Get-OCIDBSystems -CompartmentId $script:OCITestCompartment @ociSplat -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) { $script:FirstOCIDB = $r[0] }
            }
            Invoke-Test -Cmdlet 'Get-OCIAutonomousDatabases' -Endpoint 'OCI / DB / Get-OCIAutonomousDatabases' -Test {
                Get-OCIAutonomousDatabases -CompartmentId $script:OCITestCompartment @ociSplat -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-OCILoadBalancers' -Endpoint 'OCI / LB / Get-OCILoadBalancers' -Test {
                Get-OCILoadBalancers -CompartmentId $script:OCITestCompartment @ociSplat -ErrorAction Stop | Out-Null
            }
            if ($script:FirstOCICompute) {
                Invoke-Test -Cmdlet 'Resolve-OCIResourceIP (Compute)' -Endpoint 'OCI / IP / Compute' -Test {
                    Resolve-OCIResourceIP -ResourceType 'Compute' -Resource $script:FirstOCICompute -ErrorAction Stop | Out-Null
                }
            } else { Record-Test -Cmdlet 'Resolve-OCIResourceIP (Compute)' -Endpoint 'OCI / IP / Compute' -Status 'Skipped' -Detail 'No compute instances' }
            if ($script:FirstOCIDB) {
                Invoke-Test -Cmdlet 'Resolve-OCIResourceIP (DBSystem)' -Endpoint 'OCI / IP / DBSystem' -Test {
                    Resolve-OCIResourceIP -ResourceType 'DBSystem' -Resource $script:FirstOCIDB -ErrorAction Stop | Out-Null
                }
            } else { Record-Test -Cmdlet 'Resolve-OCIResourceIP (DBSystem)' -Endpoint 'OCI / IP / DBSystem' -Status 'Skipped' -Detail 'No DB systems' }
            if ($script:FirstOCICompute) {
                Invoke-Test -Cmdlet 'Get-OCIMonitoringMetrics' -Endpoint 'OCI / Monitoring / Compute' -Test {
                    Get-OCIMonitoringMetrics -CompartmentId $script:OCITestCompartment -Namespace 'oci_computeagent' -ResourceId $script:FirstOCICompute.InstanceId @ociSplat -ErrorAction Stop | Out-Null
                }
            } else { Record-Test -Cmdlet 'Get-OCIMonitoringMetrics' -Endpoint 'OCI / Monitoring' -Status 'Skipped' -Detail 'No compute instances' }
        } else {
            foreach ($c in @('Get-OCIComputeInstances','Get-OCIDBSystems','Get-OCIAutonomousDatabases','Get-OCILoadBalancers','Resolve-OCIResourceIP (Compute)','Resolve-OCIResourceIP (DBSystem)','Get-OCIMonitoringMetrics')) {
                Record-Test -Cmdlet $c -Endpoint 'OCI / (skipped)' -Status 'Skipped' -Detail 'No compartments found'
            }
        }
        Invoke-Test -Cmdlet 'Get-OCIDashboard (default)' -Endpoint 'OCI / Dashboard / Get-OCIDashboard' -Test {
            $script:OCIDashboardData = Get-OCIDashboard -TenancyId $script:OCITenancyId @ociSplat -ErrorAction Stop; Assert-NotNull $script:OCIDashboardData
        }
        Invoke-Test -Cmdlet 'Get-OCIDashboard (no DB)' -Endpoint 'OCI / Dashboard / -IncludeDBSystems $false' -Test {
            Get-OCIDashboard -TenancyId $script:OCITenancyId -IncludeDBSystems $false -IncludeAutonomousDBs $false @ociSplat -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-OCIDashboard (no LB)' -Endpoint 'OCI / Dashboard / -IncludeLoadBalancers $false' -Test {
            Get-OCIDashboard -TenancyId $script:OCITenancyId -IncludeLoadBalancers $false @ociSplat -ErrorAction Stop | Out-Null
        }
        $ociTpl = Join-Path $helpersRoot 'oci\OCI-Dashboard-Template.html'
        if ($script:OCIDashboardData -and @($script:OCIDashboardData).Count -gt 0 -and (Test-Path $ociTpl)) {
            Invoke-Test -Cmdlet 'Export-OCIDashboardHtml' -Endpoint 'OCI / Export / Export-OCIDashboardHtml' -Test {
                $script:OCIHtmlOutPath = Join-Path $outDir "Get-OCIDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-OCIDashboardHtml -DashboardData $script:OCIDashboardData -OutputPath $script:OCIHtmlOutPath -ReportTitle 'WUGHelperTest OCI' -TemplatePath $ociTpl -ErrorAction Stop
                if (-not (Test-Path $script:OCIHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-OCIDashboardHtml' -Endpoint 'OCI / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── Proxmox ────────────────────────────────────────────────────────────
###############################################################################
$script:ProxmoxHtmlOutPath = $null; $script:ProxmoxDashboardData = $null; $script:ProxmoxCookie = $null

if ($TestProxmox) {
    Write-Host "`nProxmox Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Username + Password  [S] Skip"
    $pmxChoice = Read-Host "Selection"
    if ($pmxChoice.Trim().ToUpper() -eq '1') {
        $pmxHost = Read-Host "Proxmox host or IP [default: localhost]"
        if ([string]::IsNullOrWhiteSpace($pmxHost)) { $pmxHost = 'localhost' }
        $pmxHost = $pmxHost -replace '^https?://','' -replace ':[0-9]+$',''
        $script:ProxmoxServer = "https://${pmxHost}:8006"
        Write-Host "  Using: $($script:ProxmoxServer)" -ForegroundColor DarkGray
        $pmxUser = Read-Host "Username [default: root@pam]"
        $script:ProxmoxUser = if ([string]::IsNullOrWhiteSpace($pmxUser)) { 'root@pam' } else { $pmxUser }
        Write-Host "  Using: $($script:ProxmoxUser)" -ForegroundColor DarkGray
        $script:ProxmoxPassSS = Read-Host "Password" -AsSecureString
    } else { $TestProxmox = $false }
    if (-not $TestProxmox) { Skip-ProviderTests -Provider 'Proxmox' -Reason 'User skipped' -Cmdlets $script:ProxmoxCmdletList }
} else { Skip-ProviderTests -Provider 'Proxmox' -Reason 'Disabled' -Cmdlets $script:ProxmoxCmdletList }

if ($TestProxmox) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Proxmox ..." -ForegroundColor Cyan

    $script:FirstProxmoxNode = $null; $script:FirstProxmoxVM = $null

    Invoke-Test -Cmdlet 'Connect-ProxmoxServer' -Endpoint 'Proxmox / Auth / Connect-ProxmoxServer' -Test {
        Initialize-SSLBypass
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:ProxmoxPassSS)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            $script:ProxmoxCookie = Connect-ProxmoxServer -Server $script:ProxmoxServer -Username $script:ProxmoxUser -Password $plain -ErrorAction Stop
        } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if (-not $script:ProxmoxCookie) { throw "No cookie returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestProxmox = $false
        Skip-ProviderTests -Provider 'Proxmox' -Reason 'Auth failed' -Cmdlets ($script:ProxmoxCmdletList | Where-Object { $_ -ne 'Connect-ProxmoxServer' })
    }

    if ($TestProxmox) {
        Invoke-Test -Cmdlet 'Get-ProxmoxNodes' -Endpoint 'Proxmox / Nodes / Get-ProxmoxNodes' -Test {
            $r = Get-ProxmoxNodes -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ErrorAction Stop
            Assert-NotNull $r; $script:FirstProxmoxNode = @($r)[0].node
        }
        if ($script:FirstProxmoxNode) {
            Invoke-Test -Cmdlet 'Get-ProxmoxVMs' -Endpoint 'Proxmox / VMs / Get-ProxmoxVMs' -Test {
                $r = Get-ProxmoxVMs -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -Node $script:FirstProxmoxNode -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) { $script:FirstProxmoxVM = @($r)[0] }
            }
            Invoke-Test -Cmdlet 'Get-ProxmoxNodeDetail' -Endpoint 'Proxmox / Nodes / Get-ProxmoxNodeDetail' -Test {
                Get-ProxmoxNodeDetail -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -Node $script:FirstProxmoxNode -ErrorAction Stop | Out-Null
            }
            if ($script:FirstProxmoxVM) {
                Invoke-Test -Cmdlet 'Get-ProxmoxVMDetail' -Endpoint 'Proxmox / VMs / Get-ProxmoxVMDetail' -Test {
                    Get-ProxmoxVMDetail -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -Node $script:FirstProxmoxNode -VMID $script:FirstProxmoxVM.vmid -ErrorAction Stop | Out-Null
                }
            } else { Record-Test -Cmdlet 'Get-ProxmoxVMDetail' -Endpoint 'Proxmox / VMs' -Status 'Skipped' -Detail 'No VMs on first node' }
        } else {
            Record-Test -Cmdlet 'Get-ProxmoxVMs' -Endpoint 'Proxmox / VMs' -Status 'Skipped' -Detail 'No nodes found'
            Record-Test -Cmdlet 'Get-ProxmoxNodeDetail' -Endpoint 'Proxmox / Nodes' -Status 'Skipped' -Detail 'No nodes found'
            Record-Test -Cmdlet 'Get-ProxmoxVMDetail' -Endpoint 'Proxmox / VMs' -Status 'Skipped' -Detail 'No nodes found'
        }
        Invoke-Test -Cmdlet 'Get-ProxmoxDashboard' -Endpoint 'Proxmox / Dashboard / Get-ProxmoxDashboard' -Test {
            $script:ProxmoxDashboardData = Get-ProxmoxDashboard -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ErrorAction Stop
            Assert-NotNull $script:ProxmoxDashboardData
        }
        $pmxTpl = Join-Path $helpersRoot 'proxmox\Proxmox-Dashboard-Template.html'
        if ($script:ProxmoxDashboardData -and @($script:ProxmoxDashboardData).Count -gt 0 -and (Test-Path $pmxTpl)) {
            Invoke-Test -Cmdlet 'Export-ProxmoxDashboardHtml' -Endpoint 'Proxmox / Export / Export-ProxmoxDashboardHtml' -Test {
                $script:ProxmoxHtmlOutPath = Join-Path $outDir "Get-ProxmoxDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-ProxmoxDashboardHtml -DashboardData $script:ProxmoxDashboardData -OutputPath $script:ProxmoxHtmlOutPath -ReportTitle 'WUGHelperTest Proxmox' -TemplatePath $pmxTpl -ErrorAction Stop
                if (-not (Test-Path $script:ProxmoxHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-ProxmoxDashboardHtml' -Endpoint 'Proxmox / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── Hyper-V ────────────────────────────────────────────────────────────
###############################################################################
$script:HyperVHtmlOutPath = $null; $script:HyperVDashboardData = $null; $script:HyperVSession = $null

if ($TestHyperV) {
    Write-Host "`nHyper-V Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Remote host (Credential + CIM session)  [S] Skip"
    $hvChoice = Read-Host "Selection"
    if ($hvChoice.Trim().ToUpper() -eq '1') {
        $script:HyperVHost = Read-Host "Hyper-V host name or IP"
        $script:HyperVCred = Get-Credential -Message "Hyper-V host credentials"
    } else { $TestHyperV = $false }
    if (-not $TestHyperV) { Skip-ProviderTests -Provider 'HyperV' -Reason 'User skipped' -Cmdlets $script:HyperVCmdletList }
} else { Skip-ProviderTests -Provider 'HyperV' -Reason 'Disabled or module unavailable' -Cmdlets $script:HyperVCmdletList }

if ($TestHyperV) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Hyper-V ..." -ForegroundColor Cyan

    $script:FirstHyperVVM = $null

    Invoke-Test -Cmdlet 'Connect-HypervHost' -Endpoint 'HyperV / Auth / Connect-HypervHost' -Test {
        $script:HyperVSession = Connect-HypervHost -ComputerName $script:HyperVHost -Credential $script:HyperVCred -ErrorAction Stop
        if (-not $script:HyperVSession) { throw "No CIM session returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestHyperV = $false
        Skip-ProviderTests -Provider 'HyperV' -Reason 'Auth failed' -Cmdlets ($script:HyperVCmdletList | Where-Object { $_ -ne 'Connect-HypervHost' })
    }

    if ($TestHyperV) {
        Invoke-Test -Cmdlet 'Get-HypervHostDetail' -Endpoint 'HyperV / Host / Get-HypervHostDetail' -Test {
            Get-HypervHostDetail -CimSession $script:HyperVSession -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-HypervVMs' -Endpoint 'HyperV / VMs / Get-HypervVMs' -Test {
            $r = Get-HypervVMs -CimSession $script:HyperVSession -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstHyperVVM = @($r)[0] }
        }
        if ($script:FirstHyperVVM) {
            Invoke-Test -Cmdlet 'Get-HypervVMDetail' -Endpoint 'HyperV / VMs / Get-HypervVMDetail' -Test {
                Get-HypervVMDetail -CimSession $script:HyperVSession -VM $script:FirstHyperVVM -ErrorAction Stop | Out-Null
            }
        } else { Record-Test -Cmdlet 'Get-HypervVMDetail' -Endpoint 'HyperV / VMs' -Status 'Skipped' -Detail 'No VMs on host' }
        Invoke-Test -Cmdlet 'Get-HypervDashboard' -Endpoint 'HyperV / Dashboard / Get-HypervDashboard' -Test {
            $script:HyperVDashboardData = Get-HypervDashboard -CimSessions $script:HyperVSession -ErrorAction Stop
            Assert-NotNull $script:HyperVDashboardData
        }
        $hvTpl = Join-Path $helpersRoot 'hyperv\Hyperv-Dashboard-Template.html'
        if ($script:HyperVDashboardData -and @($script:HyperVDashboardData).Count -gt 0 -and (Test-Path $hvTpl)) {
            Invoke-Test -Cmdlet 'Export-HypervDashboardHtml' -Endpoint 'HyperV / Export / Export-HypervDashboardHtml' -Test {
                $script:HyperVHtmlOutPath = Join-Path $outDir "Get-HypervDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-HypervDashboardHtml -DashboardData $script:HyperVDashboardData -OutputPath $script:HyperVHtmlOutPath -ReportTitle 'WUGHelperTest HyperV' -TemplatePath $hvTpl -ErrorAction Stop
                if (-not (Test-Path $script:HyperVHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-HypervDashboardHtml' -Endpoint 'HyperV / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── Nutanix ────────────────────────────────────────────────────────────
###############################################################################
$script:NutanixHtmlOutPath = $null; $script:NutanixDashboardData = $null; $script:NutanixHeaders = $null

if ($TestNutanix) {
    Write-Host "`nNutanix Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Prism credentials  [S] Skip"
    $nxChoice = Read-Host "Selection"
    if ($nxChoice.Trim().ToUpper() -eq '1') {
        $script:NutanixServer = Read-Host "Prism server URI (e.g. https://192.168.1.50:9440)"
        $script:NutanixCred = Get-Credential -Message "Nutanix Prism credentials"
    } else { $TestNutanix = $false }
    if (-not $TestNutanix) { Skip-ProviderTests -Provider 'Nutanix' -Reason 'User skipped' -Cmdlets $script:NutanixCmdletList }
} else { Skip-ProviderTests -Provider 'Nutanix' -Reason 'Disabled' -Cmdlets $script:NutanixCmdletList }

if ($TestNutanix) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Nutanix ..." -ForegroundColor Cyan

    $script:FirstNutanixHost = $null; $script:FirstNutanixVM = $null

    Invoke-Test -Cmdlet 'Connect-NutanixCluster' -Endpoint 'Nutanix / Auth / Connect-NutanixCluster' -Test {
        Initialize-SSLBypass
        $script:NutanixHeaders = Connect-NutanixCluster -Server $script:NutanixServer -Credential $script:NutanixCred -ErrorAction Stop
        if (-not $script:NutanixHeaders) { throw "No auth headers returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestNutanix = $false
        Skip-ProviderTests -Provider 'Nutanix' -Reason 'Auth failed' -Cmdlets ($script:NutanixCmdletList | Where-Object { $_ -ne 'Connect-NutanixCluster' })
    }

    if ($TestNutanix) {
        Invoke-Test -Cmdlet 'Get-NutanixCluster' -Endpoint 'Nutanix / Cluster / Get-NutanixCluster' -Test {
            Get-NutanixCluster -Server $script:NutanixServer -Headers $script:NutanixHeaders -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-NutanixHosts' -Endpoint 'Nutanix / Hosts / Get-NutanixHosts' -Test {
            $r = Get-NutanixHosts -Server $script:NutanixServer -Headers $script:NutanixHeaders -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstNutanixHost = @($r)[0] }
        }
        Invoke-Test -Cmdlet 'Get-NutanixVMs' -Endpoint 'Nutanix / VMs / Get-NutanixVMs' -Test {
            $r = Get-NutanixVMs -Server $script:NutanixServer -Headers $script:NutanixHeaders -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstNutanixVM = @($r)[0] }
        }
        if ($script:FirstNutanixHost) {
            Invoke-Test -Cmdlet 'Get-NutanixHostDetail' -Endpoint 'Nutanix / Hosts / Get-NutanixHostDetail' -Test {
                Get-NutanixHostDetail -HostEntity $script:FirstNutanixHost -ErrorAction Stop | Out-Null
            }
        } else { Record-Test -Cmdlet 'Get-NutanixHostDetail' -Endpoint 'Nutanix / Hosts' -Status 'Skipped' -Detail 'No hosts found' }
        if ($script:FirstNutanixVM) {
            Invoke-Test -Cmdlet 'Get-NutanixVMDetail' -Endpoint 'Nutanix / VMs / Get-NutanixVMDetail' -Test {
                Get-NutanixVMDetail -VMEntity $script:FirstNutanixVM -ErrorAction Stop | Out-Null
            }
        } else { Record-Test -Cmdlet 'Get-NutanixVMDetail' -Endpoint 'Nutanix / VMs' -Status 'Skipped' -Detail 'No VMs found' }
        Invoke-Test -Cmdlet 'Get-NutanixDashboard' -Endpoint 'Nutanix / Dashboard / Get-NutanixDashboard' -Test {
            $script:NutanixDashboardData = Get-NutanixDashboard -Server $script:NutanixServer -Headers $script:NutanixHeaders -ErrorAction Stop
            Assert-NotNull $script:NutanixDashboardData
        }
        $nxTpl = Join-Path $helpersRoot 'nutanix\Nutanix-Dashboard-Template.html'
        if ($script:NutanixDashboardData -and @($script:NutanixDashboardData).Count -gt 0 -and (Test-Path $nxTpl)) {
            Invoke-Test -Cmdlet 'Export-NutanixDashboardHtml' -Endpoint 'Nutanix / Export / Export-NutanixDashboardHtml' -Test {
                $script:NutanixHtmlOutPath = Join-Path $outDir "Get-NutanixDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-NutanixDashboardHtml -DashboardData $script:NutanixDashboardData -OutputPath $script:NutanixHtmlOutPath -ReportTitle 'WUGHelperTest Nutanix' -TemplatePath $nxTpl -ErrorAction Stop
                if (-not (Test-Path $script:NutanixHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-NutanixDashboardHtml' -Endpoint 'Nutanix / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region ── Cleanup ────────────────────────────────────────────────────────────
###############################################################################
$currentSection++
Write-Host "`n[$currentSection/$sectionCount] Cleaning up and disconnecting ..." -ForegroundColor Cyan

if ($script:AWSAuthMethod -eq 'Keys') {
    Invoke-Test -Cmdlet 'AWS Session Cleanup' -Endpoint 'AWS / Auth / Clear-AWSCredential' -Test {
        Clear-AWSCredential -StoredCredentials 'WhatsUpGoldPS_Session' -ErrorAction SilentlyContinue
    }
} elseif ($script:AWSAuthMethod -eq 'Profile') {
    Record-Test -Cmdlet 'AWS Session Cleanup' -Endpoint 'AWS / Auth / Clear-AWSCredential' -Status 'Pass' -Detail 'Profile auth — no stored creds to clear'
}

if ($script:AzureAuthMethod) {
    Invoke-Test -Cmdlet 'Azure Session Disconnect' -Endpoint 'Azure / Auth / Disconnect-AzAccount' -Test {
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
    }
}

if ($script:ProxmoxCookie) {
    Record-Test -Cmdlet 'Proxmox Session Cleanup' -Endpoint 'Proxmox / Auth / (session)' -Status 'Pass' -Detail 'Cookie cleared from memory'
    $script:ProxmoxCookie = $null
}

if ($script:HyperVSession) {
    Invoke-Test -Cmdlet 'HyperV Session Cleanup' -Endpoint 'HyperV / Auth / Remove-CimSession' -Test {
        Remove-CimSession -CimSession $script:HyperVSession -ErrorAction SilentlyContinue
    }
}

$script:AWSAccessKey = $null; $script:AWSSecretKeySS = $null; $script:AWSProfileName = $null
$script:AzureAppId = $null; $script:AzureClientSecretSS = $null
$script:ProxmoxPassSS = $null; $script:NutanixHeaders = $null; $script:NutanixCred = $null
$script:HyperVCred = $null; $script:GCPKeyFilePath = $null
#endregion

###############################################################################
#region ── Summary ────────────────────────────────────────────────────────────
###############################################################################
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$passed  = ($script:TestResults | Where-Object Status -eq 'Pass').Count
$failed  = ($script:TestResults | Where-Object Status -eq 'Fail').Count
$skipped = ($script:TestResults | Where-Object Status -eq 'Skipped').Count
$total   = $script:TestResults.Count

Write-Host "`n  Total : $total"  -ForegroundColor White
Write-Host "  Pass  : $passed"  -ForegroundColor Green
Write-Host "  Fail  : $failed"  -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skip  : $skipped" -ForegroundColor Yellow

if ($failed -gt 0) {
    Write-Host "`n  FAILED TESTS:" -ForegroundColor Red
    $script:TestResults | Where-Object Status -eq 'Fail' | ForEach-Object {
        Write-Host "    - $($_.Cmdlet)  [$($_.Endpoint)]" -ForegroundColor Red
        if ($_.Detail) { Write-Host "      $($_.Detail)" -ForegroundColor DarkRed }
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
$script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail

$reportTemplatePath = Join-Path $helpersRoot 'reports\Bootstrap-Table-Sample.html'
$script:TestResultsHtmlPath = Join-Path $outDir "Get-HelperTestResult-$(Get-Date -Format 'yyyy-MM-dd').html"

$htmlGenerated = Export-TestResultsHtml -TestResults $script:TestResults `
    -OutputPath $script:TestResultsHtmlPath -TemplatePath $reportTemplatePath

$reportFiles = @()
if ($htmlGenerated -and (Test-Path $script:TestResultsHtmlPath)) { $reportFiles += $script:TestResultsHtmlPath }
foreach ($p in @($script:AWSHtmlOutPath, $script:AzureHtmlOutPath, $script:GCPHtmlOutPath,
                 $script:OCIHtmlOutPath, $script:ProxmoxHtmlOutPath, $script:HyperVHtmlOutPath,
                 $script:NutanixHtmlOutPath)) {
    if ($p -and (Test-Path $p)) { $reportFiles += $p }
}

if ($reportFiles.Count -gt 0) {
    Write-Host "`n  HTML Reports Generated:" -ForegroundColor Cyan
    foreach ($f in $reportFiles) { Write-Host "    $f" -ForegroundColor White }
    Write-Host ""
}

$script:TestResults
#endregion

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDa3II18LxxZsqT
# gDbs8I4MzSpKS+Vdu4BPcjyvX+kcaKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgEmzTgl/5ufoalbbwEpHwHVQG8yGUg6y+
# k5jTn/XPKg0wDQYJKoZIhvcNAQEBBQAEggIAlFgasCrzex53sFmffF4gtt+Xusih
# oo27a1VUS1EG/KzflrpE9oU0DuGhKpq1rUCfvPm3xoVtRTWM/rLhXv0igGGp+zQo
# IXz1Oxk5na+u33GuFDszTcIU5iVwCzaJY1bYey5k6/z0wLH5SCONHiEcSWZbwhst
# 5Y2u11XVjMTgalWR+YFsf8VLW03TZ6jXSoYX8+XNK4xU4dPlOJ/4PA41VjUO8Juu
# NLNymrbnUk9bP9IpkmmcUpJkVUS0P+OtAid4/XZUgByhwdhDq09gZw7DqDwAAjSi
# kKPuU5sjVZ2D8cWsPunLawjCjIae6ssux1eN5rTMRHrfvzJL9BjExWUQ9k5ou2yp
# he7ePnQglVt2AaKHZxQHlmrE0Cl+n/ZAAZyQDH2v9K68TpWWTCtKoompL8axHuG9
# GWqTkSmk09jAquncGLu3OJelmPDPUWnxsy3/cONsoSiyExvf4tE7W10foZoE1+6F
# B07bKuUQKxl8RMDzYrDMoSYTyOrKwxJ+YBUe6nBTGba8XFm4X8QF4QXp07A2xj81
# nfRxPCi3pQ+jE8FytQ6WBO7KFGGFUUkd1wWvgQB7yKCi/Oc92bHKqTuechP3OfHp
# 6hJ2GBAUJV7oBYTPUXhAC9vqQnYlULwVVakTdbti5xtW99Ha3tsTSuep5ye+Ivtv
# oegEJtptaQVK/R4=
# SIG # End signature block
