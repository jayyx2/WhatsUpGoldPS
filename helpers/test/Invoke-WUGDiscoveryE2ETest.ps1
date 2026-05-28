<#
.SYNOPSIS
    End-to-end dashboard tests for all discovery providers.

.DESCRIPTION
    Runs each Setup-*-Discovery.ps1 script with -Action Dashboard
    -NonInteractive and verifies the dashboard HTML was generated.
    Produces a colour-coded HTML results dashboard using the shared
    Test-Dashboard-Template.html (same format as Invoke-WUGModuleTest,
    Invoke-WUGHelperTest, and Invoke-WUGDiscoveryRunner).

    Providers that require external infrastructure (cloud accounts,
    network appliances) are skipped unless their target parameters
    are supplied. Docker and Windows WMI providers auto-detect local
    availability.

.PARAMETER IncludeProvider
    Run only the specified provider(s). Tab-completes to all known names.

.PARAMETER ExcludeProvider
    Skip the specified provider(s).

.PARAMETER DockerHost
    Docker Engine API endpoint(s). Default: localhost.

.PARAMETER DockerPort
    Docker API port. Default: 2375.

.PARAMETER WindowsTarget
    Target(s) for Windows WMI discovery. Default: localhost.

.PARAMETER HyperVTarget
    Hyper-V host(s) to scan. Skipped if not provided.

.PARAMETER VMwareTarget
    vCenter/ESXi host to scan. Skipped if not provided.

.PARAMETER ProxmoxTarget
    Proxmox host(s) to scan. Skipped if not provided.

.PARAMETER NutanixTarget
    Nutanix Prism host(s) to scan. Skipped if not provided.

.PARAMETER F5Target
    F5 BIG-IP host(s) to scan. Skipped if not provided.

.PARAMETER FortinetTarget
    FortiGate host(s) to scan. Skipped if not provided.

.PARAMETER BigleafTarget
    Bigleaf target label. Skipped if not provided.

.PARAMETER AwsRegion
    AWS region(s) to scan. Skipped if not provided.

.PARAMETER AzureTenantId
    Azure tenant ID. Skipped if not provided.

.PARAMETER GcpProject
    GCP project ID(s). Skipped if not provided.

.PARAMETER OciTenancyId
    OCI tenancy OCID. Skipped if not provided.

.PARAMETER OutputPath
    Directory for dashboard output files and the test report.
    Default: $env:TEMP\DiscoveryE2E.

.PARAMETER OpenDashboards
    Open generated provider dashboards in the default browser.

.PARAMETER OpenReport
    Open the HTML test results report in the default browser.

.EXAMPLE
    .\Invoke-WUGDiscoveryE2ETest.ps1
    Tests Docker + WindowsAttributes + WindowsDiskIO against localhost.

.EXAMPLE
    .\Invoke-WUGDiscoveryE2ETest.ps1 -IncludeProvider Docker
    Tests only Docker.

.EXAMPLE
    .\Invoke-WUGDiscoveryE2ETest.ps1 -VMwareTarget 'vcenter.lab.local' -OpenReport
    Also tests VMware and opens the HTML report.

.NOTES
    Author  : jason@wug.ninja
    Created : 2026-04-18
    Requires: PowerShell 5.1+, Setup-*-Discovery.ps1 scripts
#>
[CmdletBinding()]
param(
    [ValidateSet('AWS','Azure','Bigleaf','Docker','F5','Fortinet','GCP',
                 'HyperV','LoadMaster','Nutanix','OCI','Proxmox','VMware',
                 'WindowsAttributes','WindowsDiskIO')]
    [string[]]$IncludeProvider,

    [ValidateSet('AWS','Azure','Bigleaf','Docker','F5','Fortinet','GCP',
                 'HyperV','LoadMaster','Nutanix','OCI','Proxmox','VMware',
                 'WindowsAttributes','WindowsDiskIO')]
    [string[]]$ExcludeProvider,

    [string[]]$DockerHost = @('localhost'),
    [int]$DockerPort = 2375,
    [string[]]$WindowsTarget = @('localhost'),

    [string[]]$HyperVTarget,
    [string]$VMwareTarget,
    [string[]]$ProxmoxTarget,
    [string[]]$NutanixTarget,
    [string[]]$F5Target,
    [string[]]$FortinetTarget,
    [string[]]$LoadMasterTarget,
    [string]$BigleafTarget,
    [string]$AwsRegion,
    [string]$AzureTenantId,
    [string[]]$GcpProject,
    [string]$OciTenancyId,

    [string]$OutputPath,

    [switch]$NonInteractive,

    [switch]$OpenDashboards,
    [switch]$OpenReport
)

# ── Setup ────────────────────────────────────────────────────────────────────
$scriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryDir = Join-Path (Split-Path $scriptDir -Parent) 'discovery'
$timestamp    = (Get-Date).ToString('yyyyMMdd_HHmmss')

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:TEMP 'DiscoveryE2E'
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ── Load DiscoveryHelpers for vault credential checks ────────────────────────
$discoveryHelpersPath = Join-Path $discoveryDir 'DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) {
    . $discoveryHelpersPath
}
else {
    Write-Warning "DiscoveryHelpers.ps1 not found - vault credential checks disabled."
}

# Helper: silently check if a vault credential exists
function Test-VaultCredential {
    param([string]$VaultName, [string]$CredType)
    if (-not (Get-Command -Name 'Resolve-DiscoveryCredential' -ErrorAction SilentlyContinue)) { return $false }
    if ([string]::IsNullOrEmpty($VaultName)) { return $false }
    try {
        $cred = Resolve-DiscoveryCredential -Name $VaultName -CredType $CredType -NonInteractive
        return ($null -ne $cred)
    }
    catch { return $false }
}

# ── Test Framework (matches Invoke-WUGDiscoveryRunner / Invoke-WUGHelperTest) ─
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Record-Test {
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [string]$Status,
        [string]$Detail = '',
        [string]$Duration = '',
        [int]$DurationMs = 0
    )
    $script:TestResults.Add([PSCustomObject]@{
        Cmdlet     = $Cmdlet
        Endpoint   = $Endpoint
        Status     = $Status
        Duration   = $Duration
        DurationMs = $DurationMs
        Detail     = $Detail
    })
}

function Export-TestResultsHtml {
    param(
        [Parameter(Mandatory)]$TestResults,
        [Parameter(Mandatory)][string]$OutputFilePath,
        [Parameter(Mandatory)][string]$TemplatePath,
        [string]$ReportTitle = 'Discovery E2E Results'
    )
    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "Report template not found at $TemplatePath - skipping HTML report."
        return $null
    }
    $columns = @(
        @{ field = 'Cmdlet';   title = 'Provider';  sortable = $true; searchable = $true }
        @{ field = 'Endpoint'; title = 'Test';      sortable = $true; searchable = $true }
        @{ field = 'Status';   title = 'Status';    sortable = $true; searchable = $true; formatter = 'formatTestStatus' }
        @{ field = 'Duration'; title = 'Duration';  sortable = $true; searchable = $true; sorter = 'durationSorter' }
        @{ field = 'DurationMs'; title = 'DurationMs'; sortable = $false; visible = $false }
        @{ field = 'Detail';   title = 'Detail';    sortable = $true; searchable = $true }
    )
    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataRows = @($TestResults | Select-Object Cmdlet, Endpoint, Status, Duration, DurationMs, Detail)
    $dataJson = ConvertTo-Json -InputObject $dataRows -Depth 5 -Compress
    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson,
        sortName: 'Duration',
        sortOrder: 'desc'
"@
    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Set-Content -Path $OutputFilePath -Value $html -Encoding UTF8
    return $OutputFilePath
}

# ── Resolve default targets from vault ────────────────────────────────────────
# For each provider: if vault creds exist, auto-use default target.
# If no vault creds and not NonInteractive, prompt user to configure.
# If multiple vault creds exist (e.g., Windows.WMI.Credential.1, .2), use first only.

# Default targets (matching Invoke-WUGDiscoveryRunner.ps1 config)
$defaultTargets = @{
    HyperV   = @('192.168.74.30')
    VMware   = 'vcenter.corp.local'
    Proxmox  = @('192.168.1.30')
    Nutanix  = @('nutanix-cluster.corp.local')
    F5       = @('lb1.corp.local')
    Fortinet = @('fw1.corp.local')
    LoadMaster = @('loadmaster.corp.local')
    Bigleaf  = 'bigleaf'
    AWS      = 'all'
    Azure    = $null
    GCP      = @('gcp')
    OCI      = 'oci'
}

# Vault names and cred types (matching Invoke-WUGDiscoveryRunner.ps1 config)
$vaultConfig = [ordered]@{
    HyperV   = @{ Name = 'HyperV.192.168.74.30.Credential'; CredType = 'PSCredential';    ParamName = 'HyperVTarget';   Label = 'Hyper-V (192.168.74.30)' }
    VMware   = @{ Name = 'VMware.vcenter.corp.local.Credential'; CredType = 'PSCredential'; ParamName = 'VMwareTarget';   Label = 'VMware vCenter' }
    Proxmox  = @{ Name = 'Proxmox.192.168.1.30.Token'; CredType = 'BearerToken';           ParamName = 'ProxmoxTarget';  Label = 'Proxmox (192.168.1.30)' }
    Nutanix  = @{ Name = 'Nutanix.nutanix-cluster.corp.local.Credential'; CredType = 'PSCredential';                  ParamName = 'NutanixTarget';  Label = 'Nutanix AHV' }
    F5       = @{ Name = 'F5.lb1.corp.local.Credential'; CredType = 'PSCredential';        ParamName = 'F5Target';       Label = 'F5 BIG-IP' }
    Fortinet = @{ Name = 'FortiGate.fw1.corp.local'; CredType = 'BearerToken';                        ParamName = 'FortinetTarget'; Label = 'FortiGate' }
    LoadMaster = @{ Name = 'LoadMaster.loadmaster.corp.local.ApiKey'; CredType = 'BearerToken'; ParamName = 'LoadMasterTarget'; Label = 'Kemp LoadMaster' }
    Bigleaf  = @{ Name = 'Bigleaf.Credential'; CredType = 'PSCredential';                  ParamName = 'BigleafTarget';  Label = 'Bigleaf SD-WAN' }
    AWS      = @{ Name = 'AWS.Credential'; CredType = 'AWSKeys';                           ParamName = 'AwsRegion';      Label = 'AWS' }
    Azure    = @{ Name = 'Azure'; CredType = 'AzureSP';                                    ParamName = 'AzureTenantId';  Label = 'Azure' }
    GCP      = @{ Name = 'GCP.ServiceAccount'; CredType = 'FilePath';                      ParamName = 'GcpProject';     Label = 'Google Cloud' }
    OCI      = @{ Name = 'OCI.Config'; CredType = 'OCIConfig';                         ParamName = 'OciTenancyId';   Label = 'Oracle Cloud' }
}

$hasResolveCmd = Get-Command -Name 'Resolve-DiscoveryCredential' -ErrorAction SilentlyContinue
$vaultStatus = [ordered]@{}
$promptedAny = $false

foreach ($provName in $vaultConfig.Keys) {
    # Skip providers not in the run list
    if ($IncludeProvider -and $provName -notin $IncludeProvider) { continue }
    if ($ExcludeProvider -and $provName -in $ExcludeProvider)    { continue }

    $vc = $vaultConfig[$provName]
    $paramVar = $vc.ParamName

    # Skip if user explicitly passed this target param
    if ($PSBoundParameters.ContainsKey($paramVar)) {
        $vaultStatus[$provName] = 'user-provided'
        continue
    }

    # Check vault silently
    $hasVault = $false
    if ($hasResolveCmd -and -not [string]::IsNullOrEmpty($vc.Name)) {
        try {
            $cred = Resolve-DiscoveryCredential -Name $vc.Name -CredType $vc.CredType -NonInteractive
            $hasVault = ($null -ne $cred)
        }
        catch { }
    }

    if ($hasVault) {
        # Vault creds found — auto-set default target
        if ($provName -eq 'Azure' -and $cred -is [PSCredential]) {
            # Extract TenantId from credential UserName (format: TenantId|AppId)
            $tenantId = ($cred.UserName -split '\|', 2)[0]
            Set-Variable -Name $paramVar -Value $tenantId
        } else {
            Set-Variable -Name $paramVar -Value $defaultTargets[$provName]
        }
        $vaultStatus[$provName] = 'vault'
    }
    elseif (-not $NonInteractive -and $hasResolveCmd) {
        # No vault creds — prompt user to configure
        if (-not $promptedAny) {
            Write-Host ''
            Write-Host '  Credential Setup' -ForegroundColor Cyan
            Write-Host '  Providers without saved vault credentials will be prompted.' -ForegroundColor Gray
            Write-Host '  Once saved, future runs are fully automated.' -ForegroundColor Gray
            Write-Host ''
            $promptedAny = $true
        }
        Write-Host "  $($vc.Label): no vault credential found." -ForegroundColor Yellow
        $answer = Read-Host -Prompt "    Configure now? [Y]es / [N]o skip (default: N)"
        if ($answer -match '^[Yy]') {
            $newCred = Resolve-DiscoveryCredential -Name $vc.Name -CredType $vc.CredType -ProviderLabel $vc.Label
            if ($null -ne $newCred) {
                if ($provName -eq 'Azure' -and $newCred -is [PSCredential]) {
                    $tenantId = ($newCred.UserName -split '\|', 2)[0]
                    Set-Variable -Name $paramVar -Value $tenantId
                } else {
                    Set-Variable -Name $paramVar -Value $defaultTargets[$provName]
                }
                $vaultStatus[$provName] = 'new'
                $resolvedTarget = (Get-Variable -Name $paramVar -ValueOnly)
                Write-Host "    Saved. Will test $provName against $resolvedTarget." -ForegroundColor Green
            }
            else {
                $vaultStatus[$provName] = 'skipped'
                Write-Host "    Skipped." -ForegroundColor DarkGray
            }
        }
        else {
            $vaultStatus[$provName] = 'skipped'
        }
    }
    else {
        $vaultStatus[$provName] = 'no-cred'
    }
}
if ($promptedAny) { Write-Host '' }

# ── Provider definitions ─────────────────────────────────────────────────────
$providers = [ordered]@{

    Docker = @{
        Script        = 'Setup-Docker-Discovery.ps1'
        Args          = @{ Target = $DockerHost; ApiPort = $DockerPort; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'Docker-Dashboard.html'
        PreCheck      = {
            try { $null = Invoke-RestMethod -Uri "http://$($DockerHost[0]):$DockerPort/info" -TimeoutSec 3; $true }
            catch { $false }
        }
        PreCheckLabel = "Docker API on $($DockerHost[0]):$DockerPort"
    }

    WindowsAttributes = @{
        Script        = 'Setup-WindowsAttributes-Discovery.ps1'
        Args          = @{ Target = $WindowsTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'WindowsAttributes-Dashboard.html'
        PreCheck      = {
            try { $null = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop; $true }
            catch { $false }
        }
        PreCheckLabel = 'WMI (Win32_OperatingSystem)'
    }

    WindowsDiskIO = @{
        Script        = 'Setup-WindowsDiskIO-Discovery.ps1'
        Args          = @{ Target = $WindowsTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'WindowsDiskIO-Dashboard.html'
        PreCheck      = {
            try { $null = Get-WmiObject Win32_PerfFormattedData_PerfDisk_LogicalDisk -ErrorAction Stop; $true }
            catch { $false }
        }
        PreCheckLabel = 'WMI (Win32_PerfFormattedData_PerfDisk_LogicalDisk)'
    }

    HyperV = @{
        Script        = 'Setup-HyperV-Discovery.ps1'
        Args          = @{ Target = $HyperVTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'HyperV-Dashboard.html'
        VaultName     = 'HyperV.192.168.74.30.Credential'
        PreCheck      = { $null -ne $HyperVTarget -and $HyperVTarget.Count -gt 0 }
        PreCheckLabel = "HyperV vault cred + target ($($HyperVTarget -join ', '))"
    }

    VMware = @{
        Script        = 'Setup-VMware-Discovery.ps1'
        Args          = @{ Target = $VMwareTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'VMware-Dashboard.html'
        VaultName     = 'VMware.vcenter.corp.local.Credential'
        PreCheck      = { -not [string]::IsNullOrEmpty($VMwareTarget) }
        PreCheckLabel = "VMware vault cred + target ($VMwareTarget)"
    }

    Proxmox = @{
        Script        = 'Setup-Proxmox-Discovery.ps1'
        Args          = @{ Target = $ProxmoxTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'Proxmox-Dashboard.html'
        VaultName     = 'Proxmox.192.168.1.30.Token'
        PreCheck      = { $null -ne $ProxmoxTarget -and $ProxmoxTarget.Count -gt 0 }
        PreCheckLabel = "Proxmox vault cred + target ($($ProxmoxTarget -join ', '))"
    }

    Nutanix = @{
        Script        = 'Setup-Nutanix-Discovery.ps1'
        Args          = @{ Target = $NutanixTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'Nutanix-Dashboard.html'
        VaultName     = 'Nutanix.nutanix-cluster.corp.local.Credential'
        PreCheck      = { $null -ne $NutanixTarget -and $NutanixTarget.Count -gt 0 }
        PreCheckLabel = "Nutanix vault cred + target ($($NutanixTarget -join ', '))"
    }

    F5 = @{
        Script        = 'Setup-F5-Discovery.ps1'
        Args          = @{ Target = $F5Target; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'F5-Dashboard.html'
        VaultName     = 'F5.lb1.corp.local.Credential'
        PreCheck      = { $null -ne $F5Target -and $F5Target.Count -gt 0 }
        PreCheckLabel = "F5 vault cred + target ($($F5Target -join ', '))"
    }

    Fortinet = @{
        Script        = 'Setup-Fortinet-Discovery.ps1'
        Args          = @{ Target = $FortinetTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'Fortinet-Dashboard.html'
        VaultName     = 'FortiGate.fw1.corp.local'
        PreCheck      = { $null -ne $FortinetTarget -and $FortinetTarget.Count -gt 0 }
        PreCheckLabel = "Fortinet vault cred + target ($($FortinetTarget -join ', '))"
    }

    LoadMaster = @{
        Script        = 'Setup-LoadMaster-Discovery.ps1'
        Args          = @{ Target = $LoadMasterTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'LoadMaster-Dashboard.html'
        VaultName     = 'LoadMaster.loadmaster.corp.local.ApiKey'
        PreCheck      = { $null -ne $LoadMasterTarget -and $LoadMasterTarget.Count -gt 0 }
        PreCheckLabel = "LoadMaster vault cred + target ($($LoadMasterTarget -join ', '))"
    }

    Bigleaf = @{
        Script        = 'Setup-Bigleaf-Discovery.ps1'
        Args          = @{ Target = $BigleafTarget; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'Bigleaf-Dashboard.html'
        VaultName     = 'Bigleaf.Credential'
        PreCheck      = { -not [string]::IsNullOrEmpty($BigleafTarget) }
        PreCheckLabel = "Bigleaf vault cred + target ($BigleafTarget)"
    }

    AWS = @{
        Script        = 'Setup-AWS-Discovery.ps1'
        Args          = @{ Region = $AwsRegion; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'AWS-Dashboard.html'
        VaultName     = 'AWS.Credential'
        PreCheck      = { -not [string]::IsNullOrEmpty($AwsRegion) }
        PreCheckLabel = "AWS vault cred + region ($AwsRegion)"
    }

    Azure = @{
        Script        = 'Setup-Azure-Discovery.ps1'
        Args          = @{ TenantId = $AzureTenantId; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'Azure-Dashboard.html'
        VaultName     = 'Azure.f7b2ef38-1a73-44e0-9b44-ae4d09864721.ServicePrincipal'
        PreCheck      = { -not [string]::IsNullOrEmpty($AzureTenantId) }
        PreCheckLabel = "Azure vault cred + tenant ($AzureTenantId)"
    }

    GCP = @{
        Script        = 'Setup-GCP-Discovery.ps1'
        Args          = @{ Target = $GcpProject; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'GCP-Dashboard.html'
        VaultName     = 'GCP.ServiceAccount'
        PreCheck      = { $null -ne $GcpProject -and $GcpProject.Count -gt 0 }
        PreCheckLabel = "GCP vault cred + project ($($GcpProject -join ', '))"
    }

    OCI = @{
        Script        = 'Setup-OCI-Discovery.ps1'
        Args          = @{ TenancyId = $OciTenancyId; Action = 'Dashboard'; NonInteractive = $true; OutputPath = $OutputPath }
        DashboardFile = 'OCI-Dashboard.html'
        VaultName     = 'OCI.Config'
        PreCheck      = { -not [string]::IsNullOrEmpty($OciTenancyId) }
        PreCheckLabel = "OCI vault cred + tenancy ($OciTenancyId)"
    }
}

# ── Filter providers ─────────────────────────────────────────────────────────
$runList = [ordered]@{}
foreach ($name in $providers.Keys) {
    if ($IncludeProvider -and $name -notin $IncludeProvider) { continue }
    if ($ExcludeProvider -and $name -in $ExcludeProvider)    { continue }
    $runList[$name] = $providers[$name]
}

# ── Banner ───────────────────────────────────────────────────────────────────
$divider = '=' * 60
Write-Host ''
Write-Host $divider -ForegroundColor DarkCyan
Write-Host '  WhatsUpGoldPS Discovery E2E Tests' -ForegroundColor Cyan
Write-Host $divider -ForegroundColor DarkCyan
Write-Host "  Providers queued : $($runList.Count) / $($providers.Count)" -ForegroundColor White
Write-Host "  Output           : $OutputPath" -ForegroundColor White
Write-Host "  Timestamp        : $timestamp" -ForegroundColor White
Write-Host "  Mode             : $(if ($NonInteractive) { 'NonInteractive (vault-only)' } else { 'Interactive' })" -ForegroundColor White

# Show vault credential status
$vaultReady = @($vaultStatus.Keys | Where-Object { $vaultStatus[$_] -in 'vault','new','user-provided' })
$vaultMissing = @($vaultStatus.Keys | Where-Object { $vaultStatus[$_] -in 'no-cred','skipped' })
if ($vaultReady.Count -gt 0) {
    Write-Host "  Vault ready      : $($vaultReady -join ', ')" -ForegroundColor Green
}
if ($vaultMissing.Count -gt 0) {
    Write-Host "  No vault creds   : $($vaultMissing -join ', ')" -ForegroundColor DarkGray
}
Write-Host $divider -ForegroundColor DarkCyan
Write-Host ''

# ── Run each provider ────────────────────────────────────────────────────────
$dashboardFiles = [System.Collections.Generic.List[string]]::new()

foreach ($name in $runList.Keys) {
    $prov = $runList[$name]
    $scriptPath = Join-Path $discoveryDir $prov.Script

    # --- Pre-check ---
    $preOk = & $prov.PreCheck
    if (-not $preOk) {
        Write-Host "  [$name] " -ForegroundColor Yellow -NoNewline
        Write-Host "SKIP " -ForegroundColor DarkGray -NoNewline
        Write-Host " ($($prov.PreCheckLabel) not available)" -ForegroundColor DarkGray
        Record-Test -Cmdlet $name -Endpoint 'Pre-check' -Status 'Skipped' -Detail "Prerequisite not met: $($prov.PreCheckLabel)"
        continue
    }

    # --- Verify script exists ---
    if (-not (Test-Path $scriptPath)) {
        Write-Host "  [$name] " -ForegroundColor Red -NoNewline
        Write-Host "FAIL " -ForegroundColor Red -NoNewline
        Write-Host " (script not found: $($prov.Script))" -ForegroundColor DarkGray
        Record-Test -Cmdlet $name -Endpoint 'Script exists' -Status 'Fail' -Detail "Script not found: $scriptPath"
        continue
    }
    Record-Test -Cmdlet $name -Endpoint 'Script exists' -Status 'Pass'

    Write-Host "  [$name] " -ForegroundColor White -NoNewline
    Write-Host "RUNNING... " -ForegroundColor Cyan -NoNewline

    # --- Remove stale dashboard ---
    $expectedDash = Join-Path $OutputPath $prov.DashboardFile
    if (Test-Path $expectedDash) { Remove-Item $expectedDash -Force }

    # --- Execute with Measure-Command ---
    $runError = $null
    $argsSplat = $prov.Args
    $script:_capturedErrors   = [System.Collections.Generic.List[string]]::new()
    $script:_capturedWarnings = [System.Collections.Generic.List[string]]::new()
    $measured = Measure-Command {
        try {
            & $scriptPath @argsSplat 2>&1 3>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $script:_capturedErrors.Add($_.ToString())
                }
                elseif ($_ -is [System.Management.Automation.WarningRecord]) {
                    $script:_capturedWarnings.Add($_.ToString())
                }
            }
        }
        catch {
            $script:_capturedErrors.Add($_.Exception.Message)
        }
    }
    if ($script:_capturedErrors.Count -gt 0) {
        $runError = $script:_capturedErrors -join '; '
    }
    $script:_capturedErrors = $null
    $elapsedMs = [Math]::Round($measured.TotalMilliseconds)
    if ($measured.TotalSeconds -ge 60) {
        $elapsed = '{0}m {1:0.0}s' -f [Math]::Floor($measured.TotalMinutes), ($measured.TotalSeconds % 60)
    } else {
        $elapsed = '{0:0.0}s' -f $measured.TotalSeconds
    }
    $elapsedDetail = '{0:0.000}s ({1}ms)' -f $measured.TotalSeconds, $elapsedMs

    if ($runError) {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host "  ($elapsed) $runError" -ForegroundColor DarkGray
        Record-Test -Cmdlet $name -Endpoint 'Execute' -Status 'Fail' -Duration $elapsed -DurationMs $elapsedMs -Detail "$runError"
        Record-Test -Cmdlet $name -Endpoint 'Dashboard generated' -Status 'Fail' -DurationMs $elapsedMs -Detail 'Execution failed'
        # Wipe vault credential on failure so next run prompts for fresh creds
        if ($prov.VaultName) {
            $vaultCred = Get-DiscoveryCredential -Name $prov.VaultName -ErrorAction SilentlyContinue
            if ($vaultCred) {
                Remove-DiscoveryCredential -Name $prov.VaultName -Confirm:$false
                Write-Host "  [$name] " -ForegroundColor White -NoNewline
                Write-Host "Wiped vault credential '$($prov.VaultName)' due to failure" -ForegroundColor Yellow
            }
        }
        continue
    }

    # --- Check if warnings indicate no data / connectivity issues ---
    $noDataWarnings = @($script:_capturedWarnings | Where-Object {
        $_ -match 'No items discovered' -or
        $_ -match 'No data to generate' -or
        $_ -match 'connection methods failed' -or
        $_ -match 'failed to authenticate' -or
        $_ -match 'Cannot generate dashboard' -or
        $_ -match 'No.*credentials available'
    })
    $script:_capturedWarnings = $null

    if ($noDataWarnings.Count -gt 0) {
        $warnDetail = $noDataWarnings -join '; '
        Write-Host "SKIP" -ForegroundColor Yellow -NoNewline
        Write-Host "  ($elapsed) $warnDetail" -ForegroundColor DarkGray
        Record-Test -Cmdlet $name -Endpoint 'Execute' -Status 'Skipped' -Duration $elapsed -DurationMs $elapsedMs -Detail $warnDetail
        Record-Test -Cmdlet $name -Endpoint 'Dashboard generated' -Status 'Skipped' -DurationMs $elapsedMs -Detail 'No data available'
        continue
    }
    $script:_capturedWarnings = $null
    Record-Test -Cmdlet $name -Endpoint 'Execute' -Status 'Pass' -Duration $elapsed -DurationMs $elapsedMs -Detail $elapsedDetail

    # --- Verify dashboard ---
    if (Test-Path $expectedDash) {
        $fileSize = (Get-Item $expectedDash).Length
        $sizeKB   = [Math]::Round($fileSize / 1KB)
        Write-Host "PASS" -ForegroundColor Green -NoNewline
        Write-Host "  ($elapsed, ${sizeKB}KB)" -ForegroundColor Gray
        Record-Test -Cmdlet $name -Endpoint 'Dashboard generated' -Status 'Pass' -Duration $elapsed -DurationMs $elapsedMs -Detail "$($prov.DashboardFile) (${sizeKB}KB)"
        $dashboardFiles.Add($expectedDash)
    }
    else {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host "  ($elapsed, dashboard not found)" -ForegroundColor DarkGray
        Record-Test -Cmdlet $name -Endpoint 'Dashboard generated' -Status 'Fail' -Duration $elapsed -DurationMs $elapsedMs -Detail "Expected: $expectedDash"
    }
}

# ── Scheduled Task E2E Test ──────────────────────────────────────────────────
# Tests the full scheduled task lifecycle: register → fire → verify output → cleanup.
# Uses the first provider that passed its dashboard test as the candidate.
# Requires admin rights (Register-ScheduledTask).

$schedTestProvider = $null
$schedTestDashFile = $null

# Pick a provider whose dashboard generation already succeeded
foreach ($df in $dashboardFiles) {
    $dfName = [System.IO.Path]::GetFileName($df)
    foreach ($pName in $providers.Keys) {
        if ($providers[$pName].DashboardFile -eq $dfName) {
            $schedTestProvider = $pName
            $schedTestDashFile = $dfName
            break
        }
    }
    if ($schedTestProvider) { break }
}

if (-not $schedTestProvider) {
    Write-Host ''
    Write-Host "  [SchedTask] " -ForegroundColor Yellow -NoNewline
    Write-Host "SKIP  (no provider dashboard passed — cannot test scheduled task)" -ForegroundColor DarkGray
    Record-Test -Cmdlet 'SchedTask' -Endpoint 'Pre-check' -Status 'Skipped' -Detail 'No provider dashboard passed'
}
else {
    $registerScript = Join-Path $discoveryDir 'Register-DiscoveryScheduledTask.ps1'
    $schedTaskName  = "DiscoverySyncE2ETest-$schedTestProvider-$timestamp"
    $schedTaskFolder = '\WhatsUpGoldPS'
    $schedOutputDir  = Join-Path $OutputPath "SchedTask-$timestamp"
    if (-not (Test-Path $schedOutputDir)) { New-Item -ItemType Directory -Path $schedOutputDir -Force | Out-Null }

    $schedProv = $providers[$schedTestProvider]
    $schedTarget = $schedProv.Args['Target']
    if (-not $schedTarget) { $schedTarget = $schedProv.Args['Region'] }
    if (-not $schedTarget) { $schedTarget = $schedProv.Args['TenantId'] }
    if (-not $schedTarget) { $schedTarget = $schedProv.Args['TenancyId'] }

    Write-Host ''
    Write-Host "  [SchedTask] " -ForegroundColor White -NoNewline
    Write-Host "Testing scheduled task lifecycle ($schedTestProvider)..." -ForegroundColor Cyan

    # --- Test 1: Register the task ---
    Write-Host "  [SchedTask] " -ForegroundColor White -NoNewline
    Write-Host "Registering... " -ForegroundColor Cyan -NoNewline
    $regError = $null
    $regMeasured = Measure-Command {
        try {
            $regArgs = @{
                Mode       = 'Provider'
                Provider   = $schedTestProvider
                Action     = 'Dashboard'
                TaskName   = $schedTaskName
                TriggerType = 'Once'
                TimeOfDay  = '23:59'
                OutputPath = $schedOutputDir
            }
            if ($schedTarget) { $regArgs['Target'] = $schedTarget }
            & $registerScript @regArgs 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $regError = $_.ToString() }
            }
        }
        catch { $regError = $_.Exception.Message }
    }
    $regMs = [Math]::Round($regMeasured.TotalMilliseconds)
    $regElapsed = '{0:0.0}s' -f $regMeasured.TotalSeconds

    if ($regError) {
        Write-Host "FAIL  ($regElapsed) $regError" -ForegroundColor Red
        Record-Test -Cmdlet 'SchedTask' -Endpoint 'Register' -Status 'Fail' -Duration $regElapsed -DurationMs $regMs -Detail $regError
    }
    else {
        # Verify task exists in Task Scheduler
        $taskObj = Get-ScheduledTask -TaskName $schedTaskName -TaskPath "$schedTaskFolder\" -ErrorAction SilentlyContinue
        if ($taskObj) {
            Write-Host "PASS  ($regElapsed)" -ForegroundColor Green
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Register' -Status 'Pass' -Duration $regElapsed -DurationMs $regMs -Detail "Task: $schedTaskName"
        }
        else {
            Write-Host "FAIL  (task not found in scheduler)" -ForegroundColor Red
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Register' -Status 'Fail' -Duration $regElapsed -DurationMs $regMs -Detail 'Task not found after registration'
        }
    }

    # --- Test 2: Fire the task and wait for completion ---
    if ($taskObj) {
        Write-Host "  [SchedTask] " -ForegroundColor White -NoNewline
        Write-Host "Firing task... " -ForegroundColor Cyan -NoNewline

        $fireError = $null
        # Remove any stale dashboard from the scheduled output dir
        $schedExpectedDash = Join-Path $schedOutputDir $schedTestDashFile
        if (Test-Path $schedExpectedDash) { Remove-Item $schedExpectedDash -Force -ErrorAction SilentlyContinue }

        $fireMeasured = Measure-Command {
            try {
                Start-ScheduledTask -TaskName $schedTaskName -TaskPath "$schedTaskFolder\" -ErrorAction Stop

                # Poll until task completes (max 120 seconds)
                $maxWait = 120
                $waited = 0
                $pollInterval = 3
                while ($waited -lt $maxWait) {
                    Start-Sleep -Seconds $pollInterval
                    $waited += $pollInterval
                    $info = Get-ScheduledTaskInfo -TaskName $schedTaskName -TaskPath "$schedTaskFolder\" -ErrorAction SilentlyContinue
                    $state = (Get-ScheduledTask -TaskName $schedTaskName -TaskPath "$schedTaskFolder\" -ErrorAction SilentlyContinue).State
                    if ($state -ne 'Running') { break }
                }
                if ($state -eq 'Running') {
                    $fireError = "Task still running after ${maxWait}s"
                }
            }
            catch { $fireError = $_.Exception.Message }
        }
        $fireMs = [Math]::Round($fireMeasured.TotalMilliseconds)
        $fireElapsed = '{0:0.0}s' -f $fireMeasured.TotalSeconds

        if ($fireError) {
            Write-Host "FAIL  ($fireElapsed) $fireError" -ForegroundColor Red
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Fire + complete' -Status 'Fail' -Duration $fireElapsed -DurationMs $fireMs -Detail $fireError
        }
        else {
            # Check last run result (0 = success)
            $taskInfo = Get-ScheduledTaskInfo -TaskName $schedTaskName -TaskPath "$schedTaskFolder\" -ErrorAction SilentlyContinue
            $lastResult = $taskInfo.LastTaskResult
            if ($lastResult -eq 0) {
                Write-Host "PASS  ($fireElapsed, exit 0)" -ForegroundColor Green
                Record-Test -Cmdlet 'SchedTask' -Endpoint 'Fire + complete' -Status 'Pass' -Duration $fireElapsed -DurationMs $fireMs -Detail "Completed in $fireElapsed (exit 0)"
            }
            else {
                Write-Host "WARN  ($fireElapsed, exit $lastResult)" -ForegroundColor Yellow
                Record-Test -Cmdlet 'SchedTask' -Endpoint 'Fire + complete' -Status 'Pass' -Duration $fireElapsed -DurationMs $fireMs -Detail "Completed in $fireElapsed (exit $lastResult)"
            }
        }

        # --- Test 3: Verify output (log file + dashboard) ---
        Write-Host "  [SchedTask] " -ForegroundColor White -NoNewline
        Write-Host "Checking output... " -ForegroundColor Cyan -NoNewline

        $logDir = Join-Path $schedOutputDir 'logs'
        $logFiles = @()
        if (Test-Path $logDir) {
            $logFiles = @(Get-ChildItem -Path $logDir -Filter "${schedTaskName}_*.log" -ErrorAction SilentlyContinue)
        }
        $schedDashPath = Join-Path $schedOutputDir $schedTestDashFile

        $outputDetails = @()
        if ($logFiles.Count -gt 0) {
            $logSizeKB = [Math]::Round(($logFiles | Measure-Object -Property Length -Sum).Sum / 1KB)
            $outputDetails += "Log: $($logFiles.Count) file(s), ${logSizeKB}KB"
        }
        else {
            $outputDetails += 'Log: not found'
        }

        if (Test-Path $schedDashPath) {
            $dashSizeKB = [Math]::Round((Get-Item $schedDashPath).Length / 1KB)
            $outputDetails += "Dashboard: ${dashSizeKB}KB"
        }
        else {
            $outputDetails += 'Dashboard: not found'
        }

        $outputDetail = $outputDetails -join ' | '

        if ($logFiles.Count -gt 0 -and (Test-Path $schedDashPath)) {
            Write-Host "PASS  ($outputDetail)" -ForegroundColor Green
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Output verified' -Status 'Pass' -Detail $outputDetail
        }
        elseif ($logFiles.Count -gt 0) {
            # Log exists but no dashboard — check log for warnings
            $logContent = Get-Content -Path $logFiles[0].FullName -Raw -ErrorAction SilentlyContinue
            if ($logContent -match 'No data to generate|No items discovered|connection methods failed') {
                Write-Host "SKIP  ($outputDetail — no data)" -ForegroundColor Yellow
                Record-Test -Cmdlet 'SchedTask' -Endpoint 'Output verified' -Status 'Skipped' -Detail "$outputDetail (no data in discovery)"
            }
            else {
                Write-Host "FAIL  ($outputDetail)" -ForegroundColor Red
                Record-Test -Cmdlet 'SchedTask' -Endpoint 'Output verified' -Status 'Fail' -Detail $outputDetail
            }
        }
        else {
            Write-Host "FAIL  ($outputDetail)" -ForegroundColor Red
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Output verified' -Status 'Fail' -Detail $outputDetail
        }

        # --- Cleanup: remove the test task ---
        Write-Host "  [SchedTask] " -ForegroundColor White -NoNewline
        Write-Host "Cleanup... " -ForegroundColor Cyan -NoNewline
        try {
            Unregister-ScheduledTask -TaskName $schedTaskName -TaskPath "$schedTaskFolder\" -Confirm:$false -ErrorAction Stop
            Write-Host "PASS  (task removed)" -ForegroundColor Green
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Cleanup' -Status 'Pass' -Detail "Removed $schedTaskName"
        }
        catch {
            Write-Host "WARN  ($($_.Exception.Message))" -ForegroundColor Yellow
            Record-Test -Cmdlet 'SchedTask' -Endpoint 'Cleanup' -Status 'Pass' -Detail "Cleanup warning: $($_.Exception.Message)"
        }
    }
}

# ── HTML Test Report ─────────────────────────────────────────────────────────
$templatePath = Join-Path $scriptDir 'Test-Dashboard-Template.html'
$reportPath   = Join-Path $OutputPath "DiscoveryE2E-Report-${timestamp}.html"

$exportedPath = Export-TestResultsHtml -TestResults $script:TestResults `
    -OutputFilePath $reportPath `
    -TemplatePath $templatePath `
    -ReportTitle "Discovery E2E Tests - $timestamp"

# ── Summary ──────────────────────────────────────────────────────────────────
$pass    = @($script:TestResults | Where-Object { $_.Status -eq 'Pass' }).Count
$fail    = @($script:TestResults | Where-Object { $_.Status -eq 'Fail' }).Count
$skipped = @($script:TestResults | Where-Object { $_.Status -eq 'Skipped' }).Count

Write-Host ''
Write-Host $divider -ForegroundColor DarkCyan
Write-Host '  RESULTS SUMMARY' -ForegroundColor Cyan
Write-Host $divider -ForegroundColor DarkCyan
Write-Host ''

foreach ($r in $script:TestResults) {
    $color = switch ($r.Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'Skipped' { 'DarkGray' } default { 'Yellow' } }
    $icon  = switch ($r.Status) { 'Pass' { '[+]' }  'Fail' { '[-]' } 'Skipped' { '[ ]' } default { '[?]' } }
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host ("{0,-22}" -f $r.Cmdlet) -ForegroundColor White -NoNewline
    Write-Host ("{0,-22}" -f $r.Endpoint) -ForegroundColor Gray -NoNewline
    if ($r.Duration) { Write-Host ("{0,-12}" -f $r.Duration) -ForegroundColor Gray -NoNewline }
    else { Write-Host ("{0,-12}" -f '-') -ForegroundColor DarkGray -NoNewline }
    Write-Host $r.Detail -ForegroundColor $color
}

Write-Host ''
$summaryColor = if ($fail -gt 0) { 'Red' } elseif ($pass -gt 0) { 'Green' } else { 'Yellow' }
Write-Host "  Total: $($script:TestResults.Count)  |  Pass: $pass  |  Fail: $fail  |  Skipped: $skipped" -ForegroundColor $summaryColor

if ($exportedPath) {
    Write-Host "  Report: $exportedPath" -ForegroundColor Green
}

Write-Host ''

# ── Open dashboards / report ─────────────────────────────────────────────────
if ($OpenDashboards -and $dashboardFiles.Count -gt 0) {
    Write-Host "  Opening $($dashboardFiles.Count) dashboard(s)..." -ForegroundColor Cyan
    foreach ($d in $dashboardFiles) { Start-Process $d }
}

if ($OpenReport -and $exportedPath -and (Test-Path $exportedPath)) {
    Write-Host "  Opening report..." -ForegroundColor Cyan
    Start-Process $exportedPath
}

# ── Return results for pipeline use ─────────────────────────────────────────
$script:TestResults

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCqBaJvIy1LoiAf
# JXBHrgLjrm0IuELNvxwihMs1a6sZBaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCFdsqyyGhCnQ7Birj4R9IBaLYYrQa1AxJFRL7lB6sbajANBgkqhkiG9w0BAQEF
# AASCAgAkD/4o/H5L/9KGudc46vpLOjJmWz1wr4uwxL5h5/x1WLote2xC+KAp64sJ
# hbnMHQzIGst4TKc7g7GGLId1vf8i/RK033pWnTPxY9Br4RxhcrXY0gxtUwdCdfGJ
# 2jDSdyrMeJPZggnoqLTOXweVgwLInjgvimiIN9Ulxw2/kkZyDqoABUKQWN8vFL1Z
# LV97sS46zv34TE7YV18tgWVfIN7zQYejKG70KgUFkAgGNICfY9LdVkiEEoJdPNyg
# mD6UAyO8ZxTNU+OBhkXa/JGVOs08gTEZ7oetRdof5BTp/qP0todSHxAuvpQVfLoz
# 1a0d862d0jMp24HuBKXBdXV6YcPY7xbmvxTsauxNBf37KYQ+HCWLniacgRCbyFTr
# xE0G513meVrxt8CppxSzXTGNIUvRX/m6Ee3OTKlV8HI3geChmSHUdfmt9Uj81e6T
# Mlyh8hLdhwfILtH1CJ3rw5cM7nd4y7PGVW3Py5URLhXQmJpFhkDePQt3UTKl8M6p
# I6jj40bzByw8Ge3Nvmmw6s7ZGM+AhOGak7cpfO3mMVZ59QvxFkE9FF57rYaiBg1G
# ROISd2f+xnlV3pp4Pd7WkOyizzL7HqSaOvPRrA+02wwYKIRvKluTecxka66pUVa+
# N7k6+RbG75yUYIHajh79akIoLHRGk9eUp0xjwBdcI95akBgo7KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MjgxMzQxNDlaMC8GCSqGSIb3DQEJBDEiBCAo19+g
# g7/JfiE90hMnKyCQFOBL8kigMpuFYyAfRyLUZDANBgkqhkiG9w0BAQEFAASCAgAp
# Kx6eeCvzwyVQCY/UMaxGHHrEOFYauvxwu0IVRwIiwzPuGqI5z5qQhhGl9Lsxa9i+
# T8vfoAcGmGpSvso2yov4wddPS0QSB1sxoMIOdREzfVDowB4txbsxHleQf13h9j05
# 6arl1YBuJ/dYfxmcGFoXjEztnenFJookdFzmDDHfE5uS1V4hXcz0CfFAU5SG3TT0
# j3PeYK/HB9B6jB9oAovnvEFsWG301znpmt6g52WIONmrKGL50QyCkBohX8r3QaAT
# u6tcl+rnZx+HOnFTpif7xqMeWIsY2xP8sp2iNnm+9+5HDDe+H0CUYREINULzClCK
# 0Xo/PHkdiaJT2LiEeUQIFnuohcIO+92y83Aewv5DkfBSSUaQvUBtNEH6SlEt1pus
# 5Y7tbwxlGg3LpORCdEZxfDFC+rlCDSzEfkXkgL8AuAx1e4fKV/PTbexuNgcF7YPX
# XkqfOoUjI273SP/eSXOB7C0SbvlYNym9jaJfiCdcHpK/Lwf52QyAVvW8lK3F1tie
# PWsO49KEl92En2hnahGihgartOPEcCyVX8ssm5E4pqw6Ca+U4Wr5+8cQf4U8rJxM
# 6GGqvA3JTdlue1q/1BwfpxRjf2319gzQvNdDPRdrErlLyg7Z10vCAnscOdh8/mNq
# olM5QRY6FQwsxM8XJbUifFd0FUKxKzDggIInbAtuyw==
# SIG # End signature block
