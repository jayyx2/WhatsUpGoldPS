<#
.SYNOPSIS
    Master end-to-end discovery runner — orchestrates all discovery providers,
    generates real dashboards, and produces a WUG-ready monitor plan.

.DESCRIPTION
    Runs every registered discovery provider (AWS, Azure, F5, Fortinet,
    HyperV, LoadMaster, Proxmox, VMware) against live targets. For each provider it:

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
.PARAMETER RunBigleaf
    Include Bigleaf SD-WAN provider. Default: all run.
.PARAMETER RunDocker
    Include Docker provider. Default: all run.
.PARAMETER RunF5
    Include F5 BIG-IP provider. Default: all run.
.PARAMETER RunFortinet
    Include Fortinet FortiGate provider. Default: all run.
.PARAMETER RunGCP
    Include Google Cloud Platform provider. Default: all run.
.PARAMETER RunHyperV
    Include Hyper-V provider. Default: all run.
.PARAMETER RunLoadMaster
    Include Kemp LoadMaster provider. Default: all run.
.PARAMETER RunNutanix
    Include Nutanix AHV provider. Default: all run.
.PARAMETER RunOCI
    Include Oracle Cloud Infrastructure provider. Default: all run.
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
    [bool]$RunBigleaf,
    [bool]$RunDocker,
    [bool]$RunF5,
    [bool]$RunFortinet,
    [bool]$RunGCP,
    [bool]$RunHyperV,
    [bool]$RunLoadMaster,
    [bool]$RunNutanix,
    [bool]$RunOCI,
    [bool]$RunProxmox,
    [bool]$RunVMware,
    [string]$OutputPath,
    [switch]$SkipDashboard,
    [switch]$NonInteractive
)

# ============================================================================
# region  Smart Selective Mode
# ============================================================================
$runParams = @('RunAWS','RunAzure','RunBigleaf','RunDocker','RunF5','RunFortinet','RunGCP','RunHyperV','RunLoadMaster','RunNutanix','RunOCI','RunProxmox','RunVMware')
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
    Bigleaf  = Join-Path $discoveryDir 'DiscoveryProvider-Bigleaf.ps1'
    Docker   = Join-Path $discoveryDir 'DiscoveryProvider-Docker.ps1'
    F5       = Join-Path $discoveryDir 'DiscoveryProvider-F5.ps1'
    Fortinet = Join-Path $discoveryDir 'DiscoveryProvider-Fortinet.ps1'
    GCP      = Join-Path $discoveryDir 'DiscoveryProvider-GCP.ps1'
    HyperV      = Join-Path $discoveryDir 'DiscoveryProvider-HyperV.ps1'
    LoadMaster = Join-Path $discoveryDir 'DiscoveryProvider-LoadMaster.ps1'
    Nutanix    = Join-Path $discoveryDir 'DiscoveryProvider-Nutanix.ps1'
    OCI      = Join-Path $discoveryDir 'DiscoveryProvider-OCI.ps1'
    Proxmox  = Join-Path $discoveryDir 'DiscoveryProvider-Proxmox.ps1'
    VMware   = Join-Path $discoveryDir 'DiscoveryProvider-VMware.ps1'
}

$helperScripts = @{
    AWS      = Join-Path $helpersRoot 'aws\AWSHelpers.ps1'
    Azure    = Join-Path $helpersRoot 'azure\AzureHelpers.ps1'
    Bigleaf  = Join-Path $helpersRoot 'bigleaf\BigleafHelpers.ps1'
    Docker   = Join-Path $helpersRoot 'docker\DockerHelpers.ps1'
    F5       = Join-Path $helpersRoot 'f5\F5Helpers.ps1'
    Fortinet = Join-Path $helpersRoot 'fortinet\FortinetHelpers.ps1'
    GCP      = Join-Path $helpersRoot 'gcp\GCPHelpers.ps1'
    HyperV      = Join-Path $helpersRoot 'hyperv\HypervHelpers.ps1'
    LoadMaster = $null                                                  # No separate helper file
    Nutanix    = Join-Path $helpersRoot 'nutanix\NutanixHelpers.ps1'
    OCI      = Join-Path $helpersRoot 'oci\OCIHelpers.ps1'
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
    Bigleaf = @{
        Toggle        = [ref]$RunBigleaf
        Targets       = @('bigleaf')                 # Uses Bigleaf API (cloud-based)
        Port          = $null
        Protocol      = $null
        VaultName     = 'Bigleaf.Credential'
        CredType      = 'PSCredential'
        Modules       = @()
        HelperFile    = 'Bigleaf'
        ProviderFile  = 'Bigleaf'
        DashboardFunc = 'Export-DynamicDashboardHtml'
        DashboardFile = 'Bigleaf-Dashboard.html'
        GetDashData   = $null
    }
    Docker = @{
        Toggle        = [ref]$RunDocker
        Targets       = @('docker1.corp.local')      # Docker host(s)
        Port          = 2375
        Protocol      = 'http'
        VaultName     = $null                        # Docker API typically unauthenticated or TLS
        CredType      = $null
        Modules       = @()
        HelperFile    = 'Docker'
        ProviderFile  = 'Docker'
        DashboardFunc = 'Export-DynamicDashboardHtml'
        DashboardFile = 'Docker-Dashboard.html'
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
    GCP = @{
        Toggle        = [ref]$RunGCP
        Targets       = @('gcp')                     # Uses gcloud CLI / service account
        Port          = $null
        Protocol      = $null
        VaultName     = 'GCP.Credential'
        CredType      = 'GCPServiceAccount'
        Modules       = @()                          # Requires gcloud CLI
        HelperFile    = 'GCP'
        ProviderFile  = 'GCP'
        DashboardFunc = 'Export-DynamicDashboardHtml'
        DashboardFile = 'GCP-Dashboard.html'
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
    LoadMaster = @{
        Toggle        = [ref]$RunLoadMaster
        Targets       = @('loadmaster.corp.local')
        Port          = 443
        Protocol      = 'https'
        VaultName     = 'LoadMaster.loadmaster.corp.local.ApiKey'
        CredType      = 'BearerToken'                # API key (default auth)
        Modules       = @()
        HelperFile    = 'LoadMaster'
        ProviderFile  = 'LoadMaster'
        DashboardFunc = 'Export-LoadMasterDashboardHtml'
        DashboardFile = 'LoadMaster-Dashboard.html'
        GetDashData   = $null
    }
    Nutanix = @{
        Toggle        = [ref]$RunNutanix
        Targets       = @('nutanix-cluster.corp.local')
        Port          = 9440
        Protocol      = 'https'
        VaultName     = 'Nutanix.Credential'
        CredType      = 'PSCredential'
        Modules       = @()
        HelperFile    = 'Nutanix'
        ProviderFile  = 'Nutanix'
        DashboardFunc = 'Export-DynamicDashboardHtml'
        DashboardFile = 'Nutanix-Dashboard.html'
        GetDashData   = $null
    }
    OCI = @{
        Toggle        = [ref]$RunOCI
        Targets       = @('oci')                     # Uses OCI CLI config
        Port          = $null
        Protocol      = $null
        VaultName     = 'OCI.Credential'
        CredType      = 'OCIConfig'
        Modules       = @()                          # Requires OCI CLI or SDK
        HelperFile    = 'OCI'
        ProviderFile  = 'OCI'
        DashboardFunc = 'Export-DynamicDashboardHtml'
        DashboardFile = 'OCI-Dashboard.html'
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
        'LoadMaster' {
            $discoveryParams.Credential = @{ ApiKey = $cred }
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAFVswkEVkZY0c1
# mfsRuLPb8rngd9hIjIQNu+oQUcw93qCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCC7U6IdgoPbCgWL6UBisvk3eB1oqmj2MPKe6nJALtB0DzANBgkqhkiG9w0BAQEF
# AASCAgDWMNpJ/mC5LMZ0jypx4cu/xYURoHj5CQ/3StEqyQnfWPSozdfpV3a4B7E8
# yAmz7KQKJE28ZKMYwavr8JNCNrDw+ww6EEbf0j9nXjedbIY6hmPWrIzA7GeVAoPa
# P4GSxfC2YIodnX5VZIp8F5HHQ/HocHz5YCnAcR4QpfaCXMQWg6rdPlINv7Chp30B
# cagJ5e5nw5vV8hMlDegbIiQx7/GscUH7GIaeaFo8u3VFD7QA3yYGW6xlFjfpEUgf
# wQhBtL9JUElBk4XUk3AijDzOrnGe1BAy5fClp8WmUR8FfopLvCIoxbzdCDt9x5cI
# 7Aq/gWUY/1SkibIN9h9PrigDLKUyWuRj3BT0HBhtA1Jr0VqgHHSaG0Jz4SoFBpRr
# pf4R407fcOAwhYiRZCxiBLIKca5rq7Gngwa2+dIqYeU0YS6QAB3DFPXZAYiGHcY/
# keWI/HdPPdV/YokUlvVLjCFFtaN+AFHXkQOsQriQiMm4fDrgWGaZHiuyIMIy7Utr
# hkLdijfcB6iagtoDUj8fb9oLP5gRj8fdGaqJlazlHPjvNtBZSAsOk4Q+XyGoYh0X
# 463WRLvJ8VY523OfWOcLT/NBjg8lHxUBig5EK2NiAuBFQmvNvJ1UpVzGld8Z/lzD
# QxuZUK5doPhtCsQ38mViWtbgB88S1hhynetFzHoepC1xpeUpmaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MDgxOTQ2MDBaMC8GCSqGSIb3DQEJBDEiBCBuKsQZ
# +uGicza0yHNnsb8ENr+gt+PhLrTDziAzeRVLCjANBgkqhkiG9w0BAQEFAASCAgAp
# D6dtOUIceC55M7ULfS9zhJiMAKi5z0ESZKqFUFcTFVrwgEiAzZNmeW3+3V6zypbH
# fWN8DkDte2tYVgMtgdAchaX7QNFqtkvA7wcp8wfebtJrG3HGDGXwgZ5wLoUkmyWT
# i7w7GwSQ8EBYks7UfIGvPMNwKHTMrNNkQVGh2du3TKtVIj34EQlSGoaAT0BC+kKU
# kDCLaNA6Ea5VFXvfbP5qfMCMcXaveZ6t/FrHwz/2akUUyDNLeQc+fnWzdqyhdBHe
# cS/KPpzshaAmhXCurP/+uKpGl7U76DR1bNMMVL/xJWqoPWOWxrYKRR4oiXChnLFO
# 81Dk1QyMvEEGkteY+lDs2huiGNoVz8Wwj68/bgefmFyD8TZG65va6uWrv7N82xze
# mN3VH4XQU+go+rIR3mpnxliZUjpPpk7kiErWri/fl9qbEsYIrg60AShTPoK+C23e
# kN/lFHlO5uXhiBar61kiJKaHwzf1MVosns+fHO5AoBNHLhrHom5carAk9iMIzHO/
# xmvpt5sRvTMFdM7WTR2saCZw8oloIAbPdqMUZFuS1LbUZpO3ss1GFJ1OAx6dxc1P
# wGN3rt22CjunqXSfo20/08+xhVwaiGajx8Ev+6hOs8CsU1EohU4LAxJoucR+fdHQ
# f2jJEbFdknqavxq/KhLwhnhBZTKCJKw3SXUXojwUEQ==
# SIG # End signature block
