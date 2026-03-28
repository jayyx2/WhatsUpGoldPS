<#
.SYNOPSIS
    Master end-to-end discovery runner — orchestrates all discovery providers,
    generates real dashboards, and produces a WUG-ready monitor plan.

.DESCRIPTION
    Runs every registered discovery provider (AWS, Azure, F5, Fortinet,
    HyperV, Proxmox, VMware) against live targets. For each provider it:

      1. Loads credentials from the DPAPI vault (prompts if missing)
      2. Runs Invoke-Discovery to query the target API
      3. Exports the discovery plan (JSON + CSV)
      4. Generates the provider's HTML dashboard
      5. Records pass/fail results using the same test framework
         as Invoke-WUGHelperTest.ps1

    The combined results are written to a unified HTML report plus a
    master JSON plan that contains every discovered item across all
    providers — enough data to create WUG monitors in bulk.

    "Smart selective" mode: if you pass any -Run* parameter, only those
    providers execute. Otherwise all providers run.

.PARAMETER RunAWS
    Include AWS provider. Default: all run.
.PARAMETER RunAzure
    Include Azure provider. Default: all run.
.PARAMETER RunF5
    Include F5 BIG-IP provider. Default: all run.
.PARAMETER RunFortinet
    Include Fortinet FortiGate provider. Default: all run.
.PARAMETER RunHyperV
    Include Hyper-V provider. Default: all run.
.PARAMETER RunProxmox
    Include Proxmox VE provider. Default: all run.
.PARAMETER RunVMware
    Include VMware vSphere provider. Default: all run.
.PARAMETER OutputPath
    Directory for all output files (dashboards, plans, report).
    Defaults to $env:TEMP\DiscoveryRunner.
.PARAMETER SkipDashboard
    Skip HTML dashboard generation (plan + report only).
.PARAMETER NonInteractive
    Never prompt — skip providers whose vault credentials are missing.

.EXAMPLE
    .\Invoke-WUGDiscoveryRunner.ps1
    # Runs ALL providers, prompts for any missing credentials.

.EXAMPLE
    .\Invoke-WUGDiscoveryRunner.ps1 -RunProxmox 1 -RunHyperV 1
    # Runs only Proxmox and Hyper-V; everything else is skipped.

.EXAMPLE
    .\Invoke-WUGDiscoveryRunner.ps1 -NonInteractive -OutputPath C:\Reports
    # Runs all providers that have vault credentials — no prompts.

.NOTES
    Author  : jason@wug.ninja
    Created : 2025-07-13
    Requires: PowerShell 5.1+, DiscoveryHelpers.ps1, DiscoveryProvider-*.ps1
              Provider-specific modules (Az, AWS.Tools, VMware.PowerCLI, etc.)
              are only needed for the providers you actually run.
#>
[CmdletBinding()]
param(
    [bool]$RunAWS,
    [bool]$RunAzure,
    [bool]$RunF5,
    [bool]$RunFortinet,
    [bool]$RunHyperV,
    [bool]$RunProxmox,
    [bool]$RunVMware,
    [string]$OutputPath,
    [switch]$SkipDashboard,
    [switch]$NonInteractive
)

# ============================================================================
# region  Smart Selective Mode
# ============================================================================
$runParams = @('RunAWS','RunAzure','RunF5','RunFortinet','RunHyperV','RunProxmox','RunVMware')
$anyExplicit = $runParams | Where-Object { $PSBoundParameters.ContainsKey($_) }
if ($anyExplicit) {
    foreach ($p in $runParams) {
        if (-not $PSBoundParameters.ContainsKey($p)) {
            Set-Variable -Name $p -Value $false
        }
    }
} else {
    foreach ($p in $runParams) { Set-Variable -Name $p -Value $true }
}
# endregion

# ============================================================================
# region  Output Directory
# ============================================================================
if (-not $OutputPath) {
    $OutputPath = Join-Path $env:TEMP 'DiscoveryRunner'
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
# endregion

# ============================================================================
# region  Dot-source Helpers
# ============================================================================
$scriptDir   = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryDir = Join-Path (Split-Path $scriptDir -Parent) 'discovery'
$helpersRoot  = Split-Path $scriptDir -Parent

. (Join-Path $discoveryDir 'DiscoveryHelpers.ps1')

$providerScripts = @{
    AWS      = Join-Path $discoveryDir 'DiscoveryProvider-AWS.ps1'
    Azure    = Join-Path $discoveryDir 'DiscoveryProvider-Azure.ps1'
    F5       = Join-Path $discoveryDir 'DiscoveryProvider-F5.ps1'
    Fortinet = Join-Path $discoveryDir 'DiscoveryProvider-Fortinet.ps1'
    HyperV   = Join-Path $discoveryDir 'DiscoveryProvider-HyperV.ps1'
    Proxmox  = Join-Path $discoveryDir 'DiscoveryProvider-Proxmox.ps1'
    VMware   = Join-Path $discoveryDir 'DiscoveryProvider-VMware.ps1'
}

$helperScripts = @{
    AWS      = Join-Path $helpersRoot 'aws\AWSHelpers.ps1'
    Azure    = Join-Path $helpersRoot 'azure\AzureHelpers.ps1'
    F5       = Join-Path $helpersRoot 'f5\F5Helpers.ps1'
    Fortinet = Join-Path $helpersRoot 'fortinet\FortinetHelpers.ps1'
    HyperV   = Join-Path $helpersRoot 'hyperv\HypervHelpers.ps1'
    Proxmox  = Join-Path $helpersRoot 'proxmox\ProxmoxHelpers.ps1'
    VMware   = Join-Path $helpersRoot 'vmware\VMwareHelpers.ps1'
}
# endregion

# ============================================================================
# region  Test Framework (matches Invoke-WUGHelperTest.ps1)
# ============================================================================
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

function Export-TestResultsHtml {
    param(
        [Parameter(Mandatory)]$TestResults,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$TemplatePath,
        [string]$ReportTitle = 'Discovery Runner Results'
    )
    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "Report template not found at $TemplatePath - skipping HTML report."
        return $false
    }
    $columns = @(
        @{ field = 'Cmdlet';   title = 'Cmdlet';   sortable = $true; searchable = $true }
        @{ field = 'Endpoint'; title = 'Endpoint'; sortable = $true; searchable = $true }
        @{ field = 'Status';   title = 'Status';   sortable = $true; searchable = $true; formatter = 'formatStatus' }
        @{ field = 'Detail';   title = 'Detail';   sortable = $true; searchable = $true }
    )
    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataRows = @($TestResults | Select-Object Cmdlet, Endpoint, Status, Detail)
    $dataJson = ConvertTo-Json -InputObject $dataRows -Depth 5 -Compress
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
# endregion

# ============================================================================
# region  Provider Configurations
# ============================================================================
# Each entry defines: targets, port/protocol, vault credential name,
# module dependencies, and dashboard export function name.
# Edit targets here to match your environment.

$ProviderConfig = [ordered]@{
    AWS = @{
        Toggle        = [ref]$RunAWS
        Targets       = @('all')                     # Scan all enabled regions
        Port          = $null                        # N/A for cloud
        Protocol      = $null
        VaultName     = 'AWS.Credential'
        CredType      = 'AWSKeys'                    # AccessKeyId|SecretAccessKey
        Modules       = @('AWS.Tools.EC2','AWS.Tools.RDS','AWS.Tools.ElasticLoadBalancingV2','AWS.Tools.CloudWatch','AWS.Tools.Common')
        HelperFile    = 'AWS'
        ProviderFile  = 'AWS'
        DashboardFunc = 'Export-AWSDiscoveryDashboardHtml'
        DashboardFile = 'AWS-Dashboard.html'
        GetDashData   = $null     # Set per-provider below
    }
    Azure = @{
        Toggle        = [ref]$RunAzure
        Targets       = @('azure')                   # Placeholder — Azure uses subscription, not IP
        Port          = $null
        Protocol      = $null
        VaultName     = $null                        # Dynamic: Azure.<TenantId>.ServicePrincipal
        CredType      = 'AzureSP'                    # TenantId|ApplicationId|ClientSecret
        Modules       = @('Az.Accounts','Az.Resources','Az.Monitor')
        HelperFile    = 'Azure'
        ProviderFile  = 'Azure'
        DashboardFunc = 'Export-AzureDiscoveryDashboardHtml'
        DashboardFile = 'Azure-Dashboard.html'
        GetDashData   = $null
    }
    F5 = @{
        Toggle        = [ref]$RunF5
        Targets       = @('lb1.corp.local')
        Port          = 443
        Protocol      = 'https'
        VaultName     = 'F5.lb1.corp.local.Credential'
        CredType      = 'PSCredential'
        Modules       = @()
        HelperFile    = 'F5'
        ProviderFile  = 'F5'
        DashboardFunc = 'Export-F5DiscoveryDashboardHtml'
        DashboardFile = 'F5-Dashboard.html'
        GetDashData   = $null
    }
    Fortinet = @{
        Toggle        = [ref]$RunFortinet
        Targets       = @('fw1.corp.local')
        Port          = 443
        Protocol      = 'https'
        VaultName     = 'FortiGate-FW1'
        CredType      = 'BearerToken'                # Single API token string
        Modules       = @()
        HelperFile    = 'Fortinet'
        ProviderFile  = 'Fortinet'
        DashboardFunc = 'Export-FortinetDiscoveryDashboardHtml'
        DashboardFile = 'Fortinet-Dashboard.html'
        GetDashData   = $null
    }
    HyperV = @{
        Toggle        = [ref]$RunHyperV
        Targets       = @('192.168.74.30')
        Port          = $null
        Protocol      = $null
        VaultName     = 'HyperV.192.168.74.30.Credential'
        CredType      = 'PSCredential'
        Modules       = @()
        HelperFile    = 'HyperV'
        ProviderFile  = 'HyperV'
        DashboardFunc = 'Export-HypervDiscoveryDashboardHtml'
        DashboardFile = 'HyperV-Dashboard.html'
        GetDashData   = $null
    }
    Proxmox = @{
        Toggle        = [ref]$RunProxmox
        Targets       = @('192.168.1.39')
        Port          = 8006
        Protocol      = 'https'
        VaultName     = 'Proxmox.192.168.1.39.Token'
        CredType      = 'BearerToken'
        Modules       = @()
        HelperFile    = 'Proxmox'
        ProviderFile  = 'Proxmox'
        DashboardFunc = 'Export-ProxmoxDashboardHtml'
        DashboardFile = 'Proxmox-Dashboard.html'
        GetDashData   = $null
    }
    VMware = @{
        Toggle        = [ref]$RunVMware
        Targets       = @('vcenter.corp.local')
        Port          = 443
        Protocol      = 'https'
        VaultName     = 'VMware.vcenter.corp.local.Credential'
        CredType      = 'PSCredential'
        Modules       = @('VMware.PowerCLI')
        HelperFile    = 'VMware'
        ProviderFile  = 'VMware'
        DashboardFunc = 'Export-VMwareDashboardHtml'
        DashboardFile = 'VMware-Dashboard.html'
        GetDashData   = $null
    }
}
# endregion

# ============================================================================
# region  Credential Resolver (delegates to shared Resolve-DiscoveryCredential)
# ============================================================================
function Resolve-ProviderCredential {
    param(
        [string]$ProviderName,
        [string]$VaultName,
        [string]$CredType,
        [bool]$AllowPrompt = $true
    )

    $resolveParams = @{ ProviderLabel = $ProviderName; CredType = $CredType }

    if ($VaultName) {
        $resolveParams['Name'] = $VaultName
    } elseif ($ProviderName -eq 'Azure') {
        $resolveParams['Name'] = 'Azure'
    } else {
        if ($AllowPrompt) {
            Write-Warning "  No vault name configured for $ProviderName."
            $VaultName = Read-Host -Prompt "  Vault credential name for $ProviderName"
            if ([string]::IsNullOrWhiteSpace($VaultName)) { return $null }
            $resolveParams['Name'] = $VaultName
        } else {
            return $null
        }
    }

    if (-not $AllowPrompt) { $resolveParams['NonInteractive'] = $true }

    return (Resolve-DiscoveryCredential @resolveParams)
}
# endregion

# ============================================================================
# region  Module Check
# ============================================================================
function Test-ProviderModules {
    param([string[]]$Modules)
    foreach ($mod in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
            return $false
        }
    }
    return $true
}
# endregion

# ============================================================================
# region  MAIN — Banner
# ============================================================================
$bannerProviders = @()
foreach ($name in $ProviderConfig.Keys) {
    if ($ProviderConfig[$name].Toggle.Value) { $bannerProviders += $name }
}

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host '   WhatsUpGoldPS Discovery Runner  &#x1F977;' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host "   Providers : $($bannerProviders -join ', ')" -ForegroundColor White
Write-Host "   Output    : $OutputPath" -ForegroundColor White
Write-Host "   Timestamp : $timestamp" -ForegroundColor White
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host ''
# endregion

# ============================================================================
# region  MAIN — Provider Loop
# ============================================================================
$masterPlan = [System.Collections.Generic.List[PSCustomObject]]::new()
$providerSummary = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($providerName in $ProviderConfig.Keys) {
    $cfg = $ProviderConfig[$providerName]
    if (-not $cfg.Toggle.Value) { continue }

    Write-Host "--- $providerName ---" -ForegroundColor Cyan

    # ── Step 1: Check modules ────────────────────────────────────────────
    if ($cfg.Modules.Count -gt 0) {
        $modsOk = Test-ProviderModules -Modules $cfg.Modules
        if (-not $modsOk) {
            $missing = $cfg.Modules | Where-Object { -not (Get-Module -ListAvailable -Name $_ -ErrorAction SilentlyContinue) }
            Record-Test -Cmdlet "$providerName Module Check" -Endpoint 'Prerequisites' `
                -Status 'Skipped' -Detail "Missing modules: $($missing -join ', ')"
            $providerSummary.Add([PSCustomObject]@{
                Provider = $providerName; Status = 'Skipped'; Items = 0
                Detail = "Missing: $($missing -join ', ')"
            })
            Write-Host ''
            continue
        }
    }
    Record-Test -Cmdlet "$providerName Module Check" -Endpoint 'Prerequisites' -Status 'Pass'

    # ── Step 2: Load helper + provider scripts ───────────────────────────
    $helperPath   = $helperScripts[$cfg.HelperFile]
    $providerPath = $providerScripts[$cfg.ProviderFile]

    $loadOk = $true
    foreach ($p in @($helperPath, $providerPath)) {
        if ($p -and (Test-Path $p)) {
            try { . $p }
            catch {
                Record-Test -Cmdlet "$providerName Load Scripts" -Endpoint $p -Status 'Fail' -Detail $_.Exception.Message
                $loadOk = $false
            }
        }
        elseif ($p) {
            Record-Test -Cmdlet "$providerName Load Scripts" -Endpoint $p -Status 'Fail' -Detail 'File not found'
            $loadOk = $false
        }
    }
    if (-not $loadOk) {
        $providerSummary.Add([PSCustomObject]@{
            Provider = $providerName; Status = 'Failed'; Items = 0; Detail = 'Script load error'
        })
        Write-Host ''
        continue
    }
    Record-Test -Cmdlet "$providerName Load Scripts" -Endpoint 'Discovery' -Status 'Pass'

    # ── Step 3: Resolve credentials ──────────────────────────────────────
    $cred = Resolve-ProviderCredential -ProviderName $providerName `
        -VaultName $cfg.VaultName `
        -CredType $cfg.CredType `
        -AllowPrompt (-not $NonInteractive)

    if (-not $cred) {
        Record-Test -Cmdlet "$providerName Credentials" -Endpoint 'Vault' `
            -Status 'Skipped' -Detail 'No credential available'
        $providerSummary.Add([PSCustomObject]@{
            Provider = $providerName; Status = 'Skipped'; Items = 0; Detail = 'No credential'
        })
        Write-Host ''
        continue
    }
    Record-Test -Cmdlet "$providerName Credentials" -Endpoint 'Vault' -Status 'Pass'

    # ── Step 4: Run discovery ────────────────────────────────────────────
    $plan = $null
    $discoveryParams = @{
        ProviderName = $providerName
        Target       = $cfg.Targets
    }
    if ($cfg.Port)     { $discoveryParams.ApiPort     = $cfg.Port }
    if ($cfg.Protocol) { $discoveryParams.ApiProtocol = $cfg.Protocol }

    # Provider-specific credential passing
    switch ($providerName) {
        'AWS' {
            # AWS needs Connect-AWSProfile, not Invoke-Discovery directly
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
            try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            try {
                Connect-AWSProfile -AccessKey $cred.UserName -SecretKey $plainSK -Region $cfg.Targets[0]
                $discoveryParams.AttributeValue = 'true'
            }
            catch {
                Record-Test -Cmdlet "$providerName Connect" -Endpoint $cfg.Targets[0] `
                    -Status 'Fail' -Detail $_.Exception.Message
                $providerSummary.Add([PSCustomObject]@{
                    Provider = $providerName; Status = 'Failed'; Items = 0; Detail = 'Connect failed'
                })
                Write-Host ''
                continue
            }
        }
        'Azure' {
            # Parse TenantId|AppId from credential
            $parts = $cred.UserName -split '\|', 2
            $tenantId = $parts[0]
            $appId    = $parts[1]
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
            try { $clientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            try {
                $secSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
                $azCred = [PSCredential]::new($appId, $secSecret)
                Connect-AzAccount -ServicePrincipal -Credential $azCred -Tenant $tenantId -ErrorAction Stop | Out-Null
                $discoveryParams.AttributeValue = $tenantId
            }
            catch {
                Record-Test -Cmdlet "$providerName Connect" -Endpoint "Tenant:$tenantId" `
                    -Status 'Fail' -Detail $_.Exception.Message
                $providerSummary.Add([PSCustomObject]@{
                    Provider = $providerName; Status = 'Failed'; Items = 0; Detail = 'Auth failed'
                })
                Write-Host ''
                continue
            }
        }
        'Fortinet' {
            $discoveryParams.Credential = @{ ApiToken = $cred }
        }
        'Proxmox' {
            $discoveryParams.Credential = @{ ApiToken = $cred }
        }
        'HyperV' {
            $hvCred = $cred
            if ($cred -is [string] -and $cred -match '\|') {
                $parts = $cred -split '\|', 2
                $secPwd = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                $hvCred = [PSCredential]::new($parts[0], $secPwd)
            }
            $discoveryParams.Credential = @{
                Username     = $hvCred.UserName
                Password     = $hvCred.GetNetworkCredential().Password
                PSCredential = $hvCred
            }
        }
        'F5' {
            $f5Cred = $cred
            if ($cred -is [string] -and $cred -match '\|') {
                $parts = $cred -split '\|', 2
                $secPwd = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                $f5Cred = [PSCredential]::new($parts[0], $secPwd)
            }
            $discoveryParams.Credential = @{
                Username     = $f5Cred.UserName
                Password     = $f5Cred.GetNetworkCredential().Password
                PSCredential = $f5Cred
            }
        }
        'VMware' {
            $vmCred = $cred
            if ($cred -is [string] -and $cred -match '\|') {
                $parts = $cred -split '\|', 2
                $secPwd = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                $vmCred = [PSCredential]::new($parts[0], $secPwd)
            }
            $discoveryParams.Credential = @{
                Username     = $vmCred.UserName
                Password     = $vmCred.GetNetworkCredential().Password
                PSCredential = $vmCred
            }
        }
    }

    Invoke-Test -Cmdlet "$providerName Discovery" -Endpoint ($cfg.Targets -join ', ') -Test {
        $script:currentPlan = Invoke-Discovery @discoveryParams
        if (-not $script:currentPlan -or $script:currentPlan.Count -eq 0) {
            throw "No items discovered"
        }
    }
    $plan = $script:currentPlan

    if (-not $plan -or $plan.Count -eq 0) {
        $providerSummary.Add([PSCustomObject]@{
            Provider = $providerName; Status = 'Failed'; Items = 0; Detail = 'No items discovered'
        })
        Write-Host ''
        continue
    }

    $activeCount = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
    $perfCount   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count
    Write-Host "  Discovered $($plan.Count) items ($activeCount active, $perfCount perf)" -ForegroundColor Green

    # Add to master plan
    foreach ($item in $plan) { $masterPlan.Add($item) }

    # ── Step 5: Export plan (JSON + CSV) ─────────────────────────────────
    $planJsonPath = Join-Path $OutputPath "${providerName}-plan-${timestamp}.json"
    $planCsvPath  = Join-Path $OutputPath "${providerName}-plan-${timestamp}.csv"

    Invoke-Test -Cmdlet "$providerName Export JSON" -Endpoint $planJsonPath -Test {
        $plan | Export-DiscoveryPlan -Format JSON -Path $planJsonPath -IncludeParams
    }
    Invoke-Test -Cmdlet "$providerName Export CSV" -Endpoint $planCsvPath -Test {
        $plan | Export-DiscoveryPlan -Format CSV -Path $planCsvPath
    }

    # ── Step 6: Generate dashboard ───────────────────────────────────────
    if (-not $SkipDashboard -and $cfg.DashboardFunc) {
        $dashPath = Join-Path $OutputPath $cfg.DashboardFile
        $dashFunc = $cfg.DashboardFunc

        Invoke-Test -Cmdlet "$providerName Dashboard" -Endpoint $dashPath -Test {
            if (-not (Get-Command -Name $dashFunc -ErrorAction SilentlyContinue)) {
                throw "Dashboard function '$dashFunc' not available"
            }

            # Build dashboard data from the plan's device attributes
            $dashData = @()
            $deviceGroups = $plan | Group-Object -Property DeviceName

            foreach ($group in $deviceGroups) {
                $first = $group.Group[0]
                $attrs = $first.Attributes
                if (-not $attrs) { $attrs = @{} }

                # Generic row — providers with custom dashboard funcs may need specific shapes
                $row = [PSCustomObject]@{
                    DeviceName     = $first.DeviceName
                    DeviceIP       = $first.DeviceIP
                    Provider       = $providerName
                    ActiveMonitors = @($group.Group | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
                    PerfMonitors   = @($group.Group | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count
                    TotalItems     = $group.Group.Count
                }
                $dashData += $row
            }

            & $dashFunc -DashboardData $dashData -OutputPath $dashPath -ReportTitle "$providerName Dashboard"
        }
    }
    elseif ($SkipDashboard) {
        Record-Test -Cmdlet "$providerName Dashboard" -Endpoint '(skipped)' -Status 'Skipped' -Detail '-SkipDashboard'
    }
    else {
        Record-Test -Cmdlet "$providerName Dashboard" -Endpoint '(none)' -Status 'Skipped' -Detail 'No dashboard function'
    }

    $providerSummary.Add([PSCustomObject]@{
        Provider = $providerName; Status = 'OK'; Items = $plan.Count
        Detail = "$activeCount active, $perfCount perf"
    })

    Write-Host ''
}
# endregion

# ============================================================================
# region  Master Plan Export
# ============================================================================
Write-Host '--- Master Plan ---' -ForegroundColor Cyan

if ($masterPlan.Count -gt 0) {
    $masterJsonPath = Join-Path $OutputPath "MasterPlan-${timestamp}.json"
    $masterCsvPath  = Join-Path $OutputPath "MasterPlan-${timestamp}.csv"

    Invoke-Test -Cmdlet 'Master Plan JSON' -Endpoint $masterJsonPath -Test {
        @($masterPlan) | Export-DiscoveryPlan -Format JSON -Path $masterJsonPath -IncludeParams
    }
    Invoke-Test -Cmdlet 'Master Plan CSV' -Endpoint $masterCsvPath -Test {
        @($masterPlan) | Export-DiscoveryPlan -Format CSV -Path $masterCsvPath
    }

    Write-Host ''
    Write-Host "  Total discovered items: $($masterPlan.Count)" -ForegroundColor Green

    # Quick WUG monitor summary
    $monitorSummary = $masterPlan | Group-Object -Property { "$($_.ProviderName)/$($_.ItemType)" } |
        Sort-Object Name |
        ForEach-Object {
            [PSCustomObject]@{
                Category = $_.Name
                Count    = $_.Count
            }
        }
    Write-Host ''
    Write-Host '  WUG Monitor Blueprint:' -ForegroundColor Cyan
    foreach ($s in $monitorSummary) {
        Write-Host "    $($s.Category): $($s.Count)" -ForegroundColor White
    }
}
else {
    Record-Test -Cmdlet 'Master Plan' -Endpoint '(empty)' -Status 'Skipped' -Detail 'No items discovered'
}
# endregion

# ============================================================================
# region  Provider Summary Table
# ============================================================================
Write-Host ''
Write-Host '--- Provider Summary ---' -ForegroundColor Cyan
$providerSummary | Format-Table -AutoSize
# endregion

# ============================================================================
# region  HTML Test Report
# ============================================================================
$templatePath = Join-Path $scriptDir 'Test-Dashboard-Template.html'
$reportPath   = Join-Path $OutputPath "DiscoveryRunner-Report-${timestamp}.html"

$exported = Export-TestResultsHtml -TestResults $script:TestResults `
    -OutputPath $reportPath `
    -TemplatePath $templatePath `
    -ReportTitle "Discovery Runner — $timestamp"

if ($exported) {
    Write-Host "Test report: $reportPath" -ForegroundColor Green
}
# endregion

# ============================================================================
# region  Final Summary
# ============================================================================
$pass    = @($script:TestResults | Where-Object { $_.Status -eq 'Pass' }).Count
$fail    = @($script:TestResults | Where-Object { $_.Status -eq 'Fail' }).Count
$skipped = @($script:TestResults | Where-Object { $_.Status -eq 'Skipped' }).Count

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host '   Discovery Runner Complete' -ForegroundColor Cyan
Write-Host "   Pass: $pass  |  Fail: $fail  |  Skipped: $skipped" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
Write-Host "   Master plan items: $($masterPlan.Count)" -ForegroundColor White
Write-Host "   Output: $OutputPath" -ForegroundColor White
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host ''
# endregion

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDYkjlcUD7ZgSL7
# GDw/rAYFWqcYpkrF40NQDTOTDPUfR6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgxqXzDkYNkMUlqxAznhNKKY6P4cXHCCtF
# LI2ajzKVYbMwDQYJKoZIhvcNAQEBBQAEggIAb0TlUjy2oES4W49XOMY/nzmXNS4R
# 3TQ5MTPY1cMMmPP+PaKuwYanSIynyQ+aj5YnMSzuHKCyjPxeYFPDK4ql4/yENc9f
# NxEKDVgasiESHxK0bz5whcXk241VtqpVesbfeMC+rbYiyEKLiNtDQV8LBvOwuu+W
# mhtiC6HISK8oQM3c5mvIQeMOeNrsdPysopqk1w8X5zHFmDS1CSJMqgS4fNktwdM7
# wLABKaZoCfzZfV3DTpUgAVRoEgLXv2BY8WMiUnh860dtRy27xacPrIFfv5CIIsor
# 1bKg+71Wnkll2fNZFX9trhStsPPyekmbhnJXhyQKC1juDpRdJFdznzAa7Gt+1aa2
# rrYM9zCoXj04Y15rJL22lHG3lM+dkA+Pi1CLGVoI6gu6JdwLL7HEq5r5WjM5jVS0
# CkHLNZDmGAHQ61zMbbYK0ZrnLdPn4H83nlh0kFk44TnpqQaf8dRSNamoBCWADuiF
# UVD6J0D58vQ7oQ+SncOQBKGXRSVN8hbTtmo0DN6FD0Feb7Qrg06Q3kTv26l4tnVE
# 6P7XQuCDxuQTs7tGw2AYMP8++wPF/CQgVQyb1LAL+rqj17OblbPLoO2vecMc6JGs
# 353Nmqy/nlch6+HamXbz+eTPnfWjXOfhUxBpFEjfT14stoL9k0XwdyyZK8krz2Je
# HC7MN6BRwND+og0=
# SIG # End signature block
