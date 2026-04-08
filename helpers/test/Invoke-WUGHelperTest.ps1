<#
.SYNOPSIS
    End-to-end integration test harness for WhatsUpGoldPS cloud and infrastructure helpers.
.DESCRIPTION
    Tests every function in the helpers directory (AWS, Azure, GCP, OCI, Proxmox,
    Hyper-V, Nutanix, Fortinet, VMware, Certificates, F5, Docker, Geolocation) against live APIs. Prompts for credentials at runtime -
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
.PARAMETER TestVMware
    Include VMware vSphere helper tests. Default $true.
.PARAMETER TestCertificates
    Include Certificate discovery helper tests. Default $true.
.PARAMETER TestF5
    Include F5 BIG-IP helper tests. Default $true.
.PARAMETER TestDocker
    Include Docker Engine helper tests. Default $true.
.PARAMETER TestGeolocation
    Include Geolocation map helper tests. Default $true.
.PARAMETER TestDiscovery
    Include Discovery Runner end-to-end tests (runs Invoke-WUGDiscoveryRunner.ps1
    using DPAPI vault credentials in non-interactive mode). Default $true.
.PARAMETER AWSRegion
    Default AWS region. Prompted at runtime if omitted.
.PARAMETER AzureTenantId
    Azure tenant ID. Prompted at runtime if omitted.
.PARAMETER OutputHtmlPath
    Directory for HTML reports. Defaults to $env:TEMP.
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1
    # Runs ALL provider tests (prompts for credentials at runtime).
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1 -TestAzure 1
    # Runs only Azure tests; all other providers are automatically skipped.
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1 -TestProxmox 1 -TestFortinet 1
    # Runs only Proxmox and Fortinet tests; everything else is skipped.
.EXAMPLE
    .\Invoke-WUGHelperTest.ps1 -AWSRegion "us-east-1" -OutputHtmlPath "C:\Reports"
    # Pre-sets AWS region and HTML output; runs all tests, prompts for secrets only.
.NOTES
    Author  : jason@wug.ninja
    Created : 2026-03-13
    Requires: Provider-specific modules are auto-installed if missing (with user consent).
#>
[CmdletBinding()]
param(
    [bool]$TestAWS,
    [bool]$TestAzure,
    [bool]$TestGCP,
    [bool]$TestOCI,
    [bool]$TestProxmox,
    [bool]$TestHyperV,
    [bool]$TestNutanix,
    [bool]$TestFortinet,
    [bool]$TestVMware,
    [bool]$TestCertificates,
    [bool]$TestF5,
    [bool]$TestDocker,
    [bool]$TestGeolocation,
    [bool]$TestBigleaf,
    [bool]$TestLansweeper,
    [bool]$TestDiscovery,
    [switch]$IncludeSkipped,
    [string]$AWSRegion,
    [string]$AzureTenantId,
    [string]$OutputHtmlPath
)

# If any Test* parameter was explicitly specified, only run those; otherwise run all.
$testParams = @('TestAWS','TestAzure','TestGCP','TestOCI','TestProxmox','TestHyperV','TestNutanix','TestFortinet','TestVMware','TestCertificates','TestF5','TestDocker','TestGeolocation','TestBigleaf','TestLansweeper','TestDiscovery')
$anyExplicit = $testParams | Where-Object { $PSBoundParameters.ContainsKey($_) }
if ($anyExplicit) {
    foreach ($p in $testParams) {
        if (-not $PSBoundParameters.ContainsKey($p)) {
            Set-Variable -Name $p -Value $false
        }
    }
} else {
    foreach ($p in $testParams) { Set-Variable -Name $p -Value $true }
}

#region -- Helpers ------------------------------------------------------------
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

#region -- Cmdlet Lists -------------------------------------------------------
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
    'Azure REST Authentication','Get-AzureSubscriptionsREST','Get-AzureResourceGroupsREST',
    'Get-AzureResourcesREST','Get-AzureSubscriptionResourcesREST','Get-AzureNetworkDataREST',
    'Resolve-AzureResourceIPREST','Get-AzureResourceMetricsREST',
    'Get-AzureResourceDetail','Get-AzureDashboard',
    'Export-AzureDashboardHtml'
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
$script:VMwareCmdletList = @(
    'Connect-VMware','Get-VMwareClusters','Get-VMwareDatastores',
    'Get-VMwareHosts','Get-VMwareHostDetail',
    'Get-VMwareVMs','Get-VMwareVMDetail',
    'Get-VMwareDashboard','Export-VMwareDashboardHtml',
    'VMware Session Cleanup'
)
$script:CertificatesCmdletList = @(
    'Get-CertificateInfo','Get-CertificateDashboard','Export-CertificateDashboardHtml'
)
$script:F5CmdletList = @(
    'Connect-F5Server','Get-F5SystemInfo',
    'Get-F5VirtualServers','Get-F5VirtualServerStats',
    'Get-F5Pools','Get-F5PoolMembers','Get-F5PoolMemberStats',
    'Get-F5Nodes',
    'Get-F5Dashboard','Export-F5DashboardHtml',
    'F5 Session Cleanup'
)
$script:DockerCmdletList = @(
    'Connect-DockerServer','Get-DockerSystemInfo',
    'Get-DockerContainers','Get-DockerContainerDetail','Get-DockerContainerStats',
    'Get-DockerNetworks','Get-DockerVolumes','Get-DockerImages',
    'Get-DockerDashboard','Export-DockerDashboardHtml'
)
$script:GeolocationCmdletList = @(
    'Connect-GeoWUGServer','Get-GeoDevicesWithLocation','Get-GeoGroupsWithLocation',
    'Get-GeolocationData','Export-GeolocationMapHtml'
)
$script:BigleafCmdletList = @(
    'Connect-BigleafAPI','Get-BigleafSites','Get-BigleafSiteStatus',
    'Get-BigleafCircuitStatus','Get-BigleafDeviceStatus','Get-BigleafSiteRisks',
    'Get-BigleafAccounts','Get-BigleafCompanies','Get-BigleafMetadata',
    'Get-BigleafDashboard','Export-BigleafDashboardHtml',
    'Bigleaf Session Cleanup'
)
$script:LansweeperCmdletList = @(
    'Connect-LansweeperPAT','Get-LansweeperCurrentUser','Get-LansweeperSites',
    'Get-LansweeperSiteInfo','Get-LansweeperAssetTypes','Get-LansweeperAssetGroups',
    'Get-LansweeperAssets','Get-LansweeperAssetDetails',
    'Get-LansweeperSources','Get-LansweeperAccounts',
    'Disconnect-Lansweeper'
)
$script:FortinetCmdletList = @(
    'Connect-FortiGate',
    # System
    'Get-FortiGateSystemStatus','Get-FortiGateSystemResources','Get-FortiGateHAStatus',
    'Get-FortiGateHAChecksums','Get-FortiGateFirmware','Get-FortiGateLicenseStatus',
    'Get-FortiGateGlobalSettings','Get-FortiGateAdmins',
    'Get-FortiGateSystemDashboard','Export-FortiGateSystemDashboardHtml',
    # Network
    'Get-FortiGateInterfaces','Get-FortiGateInterfaceConfig','Get-FortiGateZones',
    'Get-FortiGateRoutes','Get-FortiGateIPv6Routes','Get-FortiGateStaticRoutes',
    'Get-FortiGateARP','Get-FortiGateDHCPLeases','Get-FortiGateDHCPServers','Get-FortiGateDNS',
    'Get-FortiGateNetworkDashboard','Export-FortiGateNetworkDashboardHtml',
    # Firewall
    'Get-FortiGateFirewallPolicies','Get-FortiGateAddresses','Get-FortiGateAddressGroups',
    'Get-FortiGateServices','Get-FortiGateServiceGroups','Get-FortiGateSchedules',
    'Get-FortiGateIPPools','Get-FortiGateVIPs','Get-FortiGateShapingPolicies',
    'Get-FortiGateFirewallDashboard','Export-FortiGateFirewallDashboardHtml',
    # VPN
    'Get-FortiGateIPSecTunnels','Get-FortiGateIPSecPhase1','Get-FortiGateIPSecPhase2',
    'Get-FortiGateSSLVPNSessions','Get-FortiGateSSLVPNSettings',
    'Get-FortiGateVPNDashboard','Export-FortiGateVPNDashboardHtml',
    # SD-WAN
    'Get-FortiGateSDWANMembers','Get-FortiGateSDWANHealthCheck','Get-FortiGateSDWANConfig',
    'Get-FortiGateSDWANHealthCheckConfig','Get-FortiGateSDWANRules','Get-FortiGateSDWANZones',
    'Get-FortiGateSDWANDashboard','Export-FortiGateSDWANDashboardHtml',
    # Security Profiles
    'Get-FortiGateAntivirusProfiles','Get-FortiGateIPSSensors','Get-FortiGateWebFilterProfiles',
    'Get-FortiGateAppControlProfiles','Get-FortiGateDLPSensors','Get-FortiGateDNSFilterProfiles',
    'Get-FortiGateSSLSSHProfiles',
    'Get-FortiGateSecurityDashboard','Export-FortiGateSecurityDashboardHtml',
    # User & Auth
    'Get-FortiGateLocalUsers','Get-FortiGateUserGroups','Get-FortiGateLDAPServers',
    'Get-FortiGateRADIUSServers','Get-FortiGateActiveAuthUsers','Get-FortiGateFortiTokens',
    'Get-FortiGateSAMLSP',
    'Get-FortiGateUserAuthDashboard','Export-FortiGateUserAuthDashboardHtml',
    # Wireless
    'Get-FortiGateManagedAPs','Get-FortiGateWiFiClients','Get-FortiGateRogueAPs',
    'Get-FortiGateSSIDs','Get-FortiGateWTPProfiles',
    'Get-FortiGateWirelessDashboard','Export-FortiGateWirelessDashboardHtml',
    # Switch
    'Get-FortiGateManagedSwitches','Get-FortiGateSwitchPorts','Get-FortiGateSwitchConfig',
    'Get-FortiGateSwitchVLANs','Get-FortiGateSwitchLLDP',
    'Get-FortiGateSwitchDashboard','Export-FortiGateSwitchDashboardHtml',
    # Endpoint
    'Get-FortiGateEMSEndpoints','Get-FortiGateEMSConfig','Get-FortiGateSecurityRating',
    'Get-FortiGateEndpointProfiles',
    'Get-FortiGateEndpointDashboard','Export-FortiGateEndpointDashboardHtml',
    # Log
    'Get-FortiGateTrafficLogs','Get-FortiGateEventLogs','Get-FortiGateUTMLogs',
    'Get-FortiGateLogStats','Get-FortiGateFortiGuardStatus','Get-FortiGateAlertMessages',
    'Get-FortiGateLogDashboard','Export-FortiGateLogDashboardHtml',
    # FortiManager (optional)
    'Connect-FortiManager','Get-FortiManagerSystemStatus','Get-FortiManagerADOMs',
    'Get-FortiManagerDevices','Get-FortiManagerPolicyPackages',
    'Get-FortiManagerDashboard','Export-FortiManagerDashboardHtml',
    # Cleanup
    'Disconnect-FortiGate','Disconnect-FortiManager'
)
#endregion

#region -- Helper File Import -------------------------------------------------
$helpersRoot = Split-Path -Parent $PSScriptRoot

$helperFiles = @{
    AWS     = Join-Path $helpersRoot 'aws\AWSHelpers.ps1'
    Azure   = Join-Path $helpersRoot 'azure\AzureHelpers.ps1'
    GCP     = Join-Path $helpersRoot 'gcp\GCPHelpers.ps1'
    OCI     = Join-Path $helpersRoot 'oci\OCIHelpers.ps1'
    Proxmox = Join-Path $helpersRoot 'proxmox\ProxmoxHelpers.ps1'
    HyperV  = Join-Path $helpersRoot 'hyperv\HypervHelpers.ps1'
    Nutanix  = Join-Path $helpersRoot 'nutanix\NutanixHelpers.ps1'
    Fortinet = Join-Path $helpersRoot 'fortinet\FortinetHelpers.ps1'
    VMware   = Join-Path $helpersRoot 'vmware\VMwareHelpers.ps1'
    Certificates = Join-Path $helpersRoot 'certificates\CertificateHelpers.ps1'
    F5       = Join-Path $helpersRoot 'f5\F5Helpers.ps1'
    Docker   = Join-Path $helpersRoot 'docker\DockerHelpers.ps1'
    Geolocation = Join-Path $helpersRoot 'geolocation\GeolocationHelpers.ps1'
    Bigleaf  = Join-Path $helpersRoot 'bigleaf\BigleafHelpers.ps1'
    Lansweeper = Join-Path $helpersRoot 'lansweeper\LansweeperHelpers.ps1'
}

$providerToggle = @{
    AWS = [ref]$TestAWS;  Azure = [ref]$TestAzure; GCP = [ref]$TestGCP; OCI = [ref]$TestOCI
    Proxmox = [ref]$TestProxmox; HyperV = [ref]$TestHyperV; Nutanix = [ref]$TestNutanix
    Fortinet = [ref]$TestFortinet
    VMware   = [ref]$TestVMware
    Certificates = [ref]$TestCertificates
    F5       = [ref]$TestF5
    Docker   = [ref]$TestDocker
    Geolocation = [ref]$TestGeolocation
    Bigleaf  = [ref]$TestBigleaf
    Lansweeper = [ref]$TestLansweeper
}

# Always load DiscoveryHelpers (vault, credential, WUG integration functions)
$discoveryHelpersPath = Join-Path $helpersRoot 'discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) {
    . $discoveryHelpersPath
} else {
    Write-Warning "DiscoveryHelpers.ps1 not found at $discoveryHelpersPath - vault credential functions will be unavailable."
}

foreach ($provider in $helperFiles.Keys) {
    $toggle = $providerToggle[$provider]
    if ($toggle.Value) {
        $path = $helperFiles[$provider]
        if (Test-Path $path) {
            . $path
        } else {
            Write-Warning "$provider helper not found at $path - tests will be skipped."
            $toggle.Value = $false
        }
    }
}
#endregion

#region -- Dependency Checks + Auto-Install -----------------------------------
Write-Host "`n--- Checking module dependencies ---" -ForegroundColor Cyan

if ($TestAWS) {
    if (-not (Install-RequiredModule -ModuleName 'AWS.Tools.EC2' -Provider 'AWS' `
        -InstallHint 'Install-Module -Name AWS.Tools.Installer -Scope CurrentUser -Force; Install-AWSToolsModule EC2,RDS,ElasticLoadBalancingV2,CloudWatch -CleanUp -Force')) {
        Write-Warning "AWS tests will be skipped."; $TestAWS = $false
    }
}
# Azure: no external module dependency required (REST-only)
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
if ($TestVMware) {
    if (-not (Install-RequiredModule -ModuleName 'VMware.VimAutomation.Core' -Provider 'VMware' `
        -InstallHint 'Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force')) {
        Write-Warning "VMware tests will be skipped."; $TestVMware = $false
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
if ($TestFortinet) { $activeProviders += 'Fortinet' }
if ($TestVMware)  { $activeProviders += 'VMware' }
if ($TestCertificates) { $activeProviders += 'Certificates' }
if ($TestF5)      { $activeProviders += 'F5' }
if ($TestDocker)  { $activeProviders += 'Docker' }
if ($TestGeolocation) { $activeProviders += 'Geolocation' }
if ($TestBigleaf) { $activeProviders += 'Bigleaf' }
if ($TestLansweeper) { $activeProviders += 'Lansweeper' }

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
#region -- AWS ----------------------------------------------------------------
###############################################################################
$script:AWSAuthMethod = $null
$script:AWSHtmlOutPath = $null
$script:AWSDashboardData = $null

if ($TestAWS) {
    Write-Host "AWS Authentication - choose a method:" -ForegroundColor Cyan
    Write-Host "  [1] Access Key + Secret Key (DPAPI vault)"
    Write-Host "  [2] Named AWS credential profile"
    Write-Host "  [S] Skip AWS tests"
    $awsChoice = Read-Host "Selection"
    switch ($awsChoice.Trim().ToUpper()) {
        '1' {
            $script:AWSAuthMethod = 'Keys'
            $script:AWSKeysCred = Resolve-DiscoveryCredential -Name 'AWS.Credential' -CredType AWSKeys -ProviderLabel 'AWS' -DeferSave
            if ($script:AWSKeysCred) {
                $script:AWSAccessKey    = $script:AWSKeysCred.UserName
                $script:AWSSecretKeySS  = $script:AWSKeysCred.Password
            } else { $TestAWS = $false }
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
                Write-Host "    Connecting with AccessKey=$($script:AWSAccessKey) Region=$AWSRegion" -ForegroundColor DarkGray
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AWSSecretKeySS)
                try {
                    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    Connect-AWSProfile -AccessKey $script:AWSAccessKey -SecretKey $plain -Region $AWSRegion -ErrorAction Stop
                } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
            'Profile' {
                Write-Host "    Connecting with Profile=$($script:AWSProfileName) Region=$AWSRegion" -ForegroundColor DarkGray
                Connect-AWSProfile -ProfileName $script:AWSProfileName -Region $AWSRegion -ErrorAction Stop
            }
        }
        $regionCheck = Get-EC2Region -Region $AWSRegion -ErrorAction Stop
        if (-not $regionCheck) { throw "Region validation failed" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:AWSAuthMethod -eq 'Keys' -and $script:AWSKeysCred) {
        Save-ResolvedCredential -Name 'AWS.Credential' -CredType AWSKeys -Value $script:AWSKeysCred
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        if ($script:AWSAuthMethod -eq 'Keys') {
            Remove-DiscoveryCredential -Name 'AWS.Credential' -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        }
        $TestAWS = $false
        Skip-ProviderTests -Provider 'AWS' -Reason 'Auth failed' -Cmdlets ($script:AWSCmdletList | Where-Object { $_ -ne 'Connect-AWSProfile' })
    }

    if ($TestAWS) {
        # -- Enumerate all enabled regions for multi-region scanning --
        $script:AWSAllRegions = @()
        Invoke-Test -Cmdlet 'Get-AWSRegionList' -Endpoint 'AWS / EC2 / Get-AWSRegionList' -Test {
            $r = Get-AWSRegionList -ErrorAction Stop; Assert-NotNull $r; Assert-HasProperty $r[0] @('RegionName')
            $script:AWSAllRegions = @($r | Select-Object -ExpandProperty RegionName | Sort-Object)
            Write-Host "    Enabled regions: $($script:AWSAllRegions.Count) ($($script:AWSAllRegions -join ', '))" -ForegroundColor DarkGray
        }

        # -- Scan EC2 across all regions --
        Invoke-Test -Cmdlet 'Get-AWSEC2Instances' -Endpoint 'AWS / EC2 / Get-AWSEC2Instances (all regions)' -Test {
            foreach ($rgn in $script:AWSAllRegions) {
                $r = Get-AWSEC2Instances -Region $rgn -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) {
                    if (-not $script:FirstEC2Instance) {
                        Assert-HasProperty $r[0] @('InstanceId','Name','State','PrivateIP')
                        $script:FirstEC2Instance = $r[0]
                    }
                    Write-Host "    $rgn : $(@($r).Count) EC2 instances" -ForegroundColor DarkGray
                }
            }
        }
        Invoke-Test -Cmdlet 'Get-AWSEC2Instances (filtered)' -Endpoint "AWS / EC2 / Get-AWSEC2Instances -Region $AWSRegion" -Test {
            $r = Get-AWSEC2Instances -Region $AWSRegion -ErrorAction Stop
            if ($r -and @($r).Count -gt 0 -and -not $script:FirstEC2Instance) { $script:FirstEC2Instance = $r[0] }
        }

        # -- Scan RDS across all regions --
        Invoke-Test -Cmdlet 'Get-AWSRDSInstances' -Endpoint 'AWS / RDS / Get-AWSRDSInstances (all regions)' -Test {
            foreach ($rgn in $script:AWSAllRegions) {
                $r = Get-AWSRDSInstances -Region $rgn -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) {
                    if (-not $script:FirstRDSInstance) {
                        Assert-HasProperty $r[0] @('DBInstanceId','Engine','Status','Endpoint')
                        $script:FirstRDSInstance = $r[0]
                    }
                    Write-Host "    $rgn : $(@($r).Count) RDS instances" -ForegroundColor DarkGray
                }
            }
        }
        Invoke-Test -Cmdlet 'Get-AWSRDSInstances (filtered)' -Endpoint "AWS / RDS / Get-AWSRDSInstances -Region $AWSRegion" -Test {
            $r = Get-AWSRDSInstances -Region $AWSRegion -ErrorAction Stop
            if ($r -and @($r).Count -gt 0 -and -not $script:FirstRDSInstance) { $script:FirstRDSInstance = $r[0] }
        }

        # -- Scan ELB across all regions --
        Invoke-Test -Cmdlet 'Get-AWSLoadBalancers' -Endpoint 'AWS / ELB / Get-AWSLoadBalancers (all regions)' -Test {
            foreach ($rgn in $script:AWSAllRegions) {
                $r = Get-AWSLoadBalancers -Region $rgn -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) {
                    if (-not $script:FirstELB) {
                        Assert-HasProperty $r[0] @('LoadBalancerName','Type','State','DNSName')
                        $script:FirstELB = $r[0]
                    }
                    Write-Host "    $rgn : $(@($r).Count) load balancers" -ForegroundColor DarkGray
                }
            }
        }
        Invoke-Test -Cmdlet 'Get-AWSLoadBalancers (filtered)' -Endpoint "AWS / ELB / Get-AWSLoadBalancers -Region $AWSRegion" -Test {
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
        Invoke-Test -Cmdlet 'Get-AWSDashboard (multi-region)' -Endpoint "AWS / Dashboard / -Regions ($($script:AWSAllRegions.Count) regions)" -Test {
            $allRegionData = Get-AWSDashboard -Regions $script:AWSAllRegions -ErrorAction Stop
            if ($allRegionData -and @($allRegionData).Count -gt 0) {
                Write-Host "    All-region dashboard: $(@($allRegionData).Count) resources across $($script:AWSAllRegions.Count) regions" -ForegroundColor DarkGray
                $script:AWSDashboardData = $allRegionData
            }
        }
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
#region -- Azure --------------------------------------------------------------
###############################################################################
$script:AzureHtmlOutPath = $null; $script:AzureDashboardData = $null

if ($TestAzure) {
    Write-Host "`nAzure Authentication (REST API):" -ForegroundColor Cyan
    Write-Host "  [1] Service Principal  [S] Skip"
    $azChoice = Read-Host "Selection"
    if ($azChoice.Trim().ToUpper() -eq '1') {
        if (-not $AzureTenantId) { $AzureTenantId = Read-Host "Azure Tenant ID" }
        $script:AzureSPCred = Resolve-DiscoveryCredential -Name "Azure.$AzureTenantId.ServicePrincipal" -CredType AzureSP -ProviderLabel 'Azure' -DeferSave
        if ($script:AzureSPCred) {
            $spParts = $script:AzureSPCred.UserName -split '\|', 2
            $AzureTenantId         = $spParts[0]
            $script:AzureAppId     = $spParts[1]
            $script:AzureClientSecretSS = $script:AzureSPCred.Password
        } else { $TestAzure = $false }
    } else { $TestAzure = $false }
    if (-not $TestAzure) { Skip-ProviderTests -Provider 'Azure' -Reason 'User skipped' -Cmdlets $script:AzureCmdletList }
} else { Skip-ProviderTests -Provider 'Azure' -Reason 'Disabled or modules unavailable' -Cmdlets $script:AzureCmdletList }

if ($TestAzure) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Azure ..." -ForegroundColor Cyan

    $script:AzureTestSub = $null; $script:FirstAzureResource = $null

    # -- Authenticate via REST --
    $script:AzureRESTAuthed = $false
    if ($AzureTenantId -and $script:AzureAppId -and $script:AzureClientSecretSS) {
        Invoke-Test -Cmdlet 'Azure REST Authentication' -Endpoint 'Azure / REST / Connect-AzureServicePrincipalREST' -Test {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AzureClientSecretSS)
            try {
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                Connect-AzureServicePrincipalREST -TenantId $AzureTenantId -ApplicationId $script:AzureAppId -ClientSecret $plain -ErrorAction Stop
            } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $script:AzureRESTAuthed = $true
        }
        if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:AzureSPCred) {
            Save-ResolvedCredential -Name "Azure.$AzureTenantId.ServicePrincipal" -CredType AzureSP -Value $script:AzureSPCred
        }
        if (-not $script:AzureRESTAuthed -and $AzureTenantId) {
            Remove-DiscoveryCredential -Name "Azure.$AzureTenantId.ServicePrincipal" -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        }
    }

    if ($script:AzureRESTAuthed) {
        Invoke-Test -Cmdlet 'Get-AzureSubscriptionsREST' -Endpoint 'Azure / REST / Get-AzureSubscriptionsREST' -Test {
            $r = Get-AzureSubscriptionsREST -ErrorAction Stop; Assert-NotNull $r
            Assert-HasProperty $r[0] @('SubscriptionId','SubscriptionName')
            $script:AzureRESTSubs = @($r | Where-Object { $_.State -eq 'Enabled' })
            if ($script:AzureRESTSubs.Count -eq 0) { throw "No enabled subscriptions" }
            $script:AzureTestSub = $script:AzureRESTSubs[0]
        }
    }

    if ($script:AzureRESTAuthed -and $script:AzureTestSub) {
        $restSubId = $script:AzureTestSub.SubscriptionId

        Invoke-Test -Cmdlet 'Get-AzureResourceGroupsREST' -Endpoint 'Azure / REST / Get-AzureResourceGroupsREST' -Test {
            $r = Get-AzureResourceGroupsREST -SubscriptionId $restSubId -ErrorAction Stop; Assert-NotNull $r
            $script:AzureRESTRGs = @($r)
        }

        Invoke-Test -Cmdlet 'Get-AzureResourcesREST' -Endpoint 'Azure / REST / Get-AzureResourcesREST' -Test {
            $rgName = $null
            if ($script:AzureRESTRGs -and $script:AzureRESTRGs.Count -gt 0) {
                $rgName = $script:AzureRESTRGs[0].ResourceGroupName
            }
            if (-not $rgName) { throw "No resource group available for REST test" }
            $r = Get-AzureResourcesREST -SubscriptionId $restSubId -ResourceGroupName $rgName -ErrorAction Stop
        }

        Invoke-Test -Cmdlet 'Get-AzureSubscriptionResourcesREST' -Endpoint 'Azure / REST / Get-AzureSubscriptionResourcesREST' -Test {
            $r = Get-AzureSubscriptionResourcesREST -SubscriptionId $restSubId -ErrorAction Stop
            Assert-NotNull $r
            if (@($r).Count -eq 0) { throw "No resources returned" }
            Assert-HasProperty $r[0] @('ResourceName','ResourceId','ResourceType','Location')
            if (-not $script:FirstAzureResource) { $script:FirstAzureResource = $r[0] }
        }

        Invoke-Test -Cmdlet 'Get-AzureNetworkDataREST' -Endpoint 'Azure / REST / Get-AzureNetworkDataREST' -Test {
            $r = Get-AzureNetworkDataREST -SubscriptionId $restSubId -ErrorAction Stop
            Assert-NotNull $r
            if (-not $r.ContainsKey('VMIPs'))  { throw "Missing VMIPs key in network data" }
            if (-not $r.ContainsKey('PIPs'))   { throw "Missing PIPs key in network data" }
            if (-not $r.ContainsKey('LBIPs'))  { throw "Missing LBIPs key in network data" }
        }

        if ($script:FirstAzureResource) {
            Invoke-Test -Cmdlet 'Resolve-AzureResourceIPREST' -Endpoint 'Azure / REST / Resolve-AzureResourceIPREST' -Test {
                Resolve-AzureResourceIPREST -Resource $script:FirstAzureResource -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-AzureResourceMetricsREST' -Endpoint 'Azure / REST / Get-AzureResourceMetricsREST' -Test {
                Get-AzureResourceMetricsREST -ResourceId $script:FirstAzureResource.ResourceId -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-AzureResourceDetail' -Endpoint 'Azure / REST / Get-AzureResourceDetail' -Test {
                $rgName = ''
                if ($script:FirstAzureResource.ResourceId -match '/resourceGroups/([^/]+)/') { $rgName = $Matches[1] }
                $r = Get-AzureResourceDetail -Resource $script:FirstAzureResource -SubscriptionName $script:AzureTestSub.SubscriptionName -SubscriptionId $restSubId -ResourceGroupName $rgName -IncludeMetrics $false -ErrorAction Stop
                Assert-HasProperty $r @('ResourceName','ResourceType','SubscriptionName','MetricsSummary')
            }
        } else {
            Record-Test -Cmdlet 'Resolve-AzureResourceIPREST' -Endpoint 'Azure / REST' -Status 'Skipped' -Detail 'No resource available'
            Record-Test -Cmdlet 'Get-AzureResourceMetricsREST' -Endpoint 'Azure / REST' -Status 'Skipped' -Detail 'No resource available'
            Record-Test -Cmdlet 'Get-AzureResourceDetail' -Endpoint 'Azure / REST' -Status 'Skipped' -Detail 'No resource available'
        }

        Invoke-Test -Cmdlet 'Get-AzureDashboard' -Endpoint 'Azure / REST / Get-AzureDashboard' -Test {
            $script:AzureDashboardData = Get-AzureDashboard -SubscriptionIds @($restSubId) -IncludeMetrics $false -ErrorAction Stop
            Assert-NotNull $script:AzureDashboardData
        }

        $azTpl = Join-Path $helpersRoot 'azure\Azure-Dashboard-Template.html'
        if ($script:AzureDashboardData -and @($script:AzureDashboardData).Count -gt 0 -and (Test-Path $azTpl)) {
            Invoke-Test -Cmdlet 'Export-AzureDashboardHtml' -Endpoint 'Azure / Export / Export-AzureDashboardHtml' -Test {
                $script:AzureHtmlOutPath = Join-Path $outDir "Get-AzureDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-AzureDashboardHtml -DashboardData $script:AzureDashboardData -OutputPath $script:AzureHtmlOutPath -ReportTitle 'WUGHelperTest Azure' -TemplatePath $azTpl -ErrorAction Stop
                if (-not (Test-Path $script:AzureHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-AzureDashboardHtml' -Endpoint 'Azure / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    } elseif (-not $script:AzureRESTAuthed) {
        foreach ($c in @('Get-AzureSubscriptionsREST','Get-AzureResourceGroupsREST','Get-AzureResourcesREST',
                         'Get-AzureSubscriptionResourcesREST','Get-AzureNetworkDataREST',
                         'Resolve-AzureResourceIPREST','Get-AzureResourceMetricsREST',
                         'Get-AzureResourceDetail','Get-AzureDashboard','Export-AzureDashboardHtml')) {
            Record-Test -Cmdlet $c -Endpoint 'Azure / REST' -Status 'Skipped' -Detail 'REST auth not available'
        }
    }
}
#endregion

###############################################################################
#region -- GCP ----------------------------------------------------------------
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
#region -- OCI ----------------------------------------------------------------
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
#region -- Proxmox ------------------------------------------------------------
###############################################################################
$script:ProxmoxHtmlOutPath = $null; $script:ProxmoxDashboardData = $null; $script:ProxmoxCookie = $null; $script:ProxmoxApiToken = $null; $script:ProxmoxAuthMethod = $null

if ($TestProxmox) {
    Write-Host "`nProxmox Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Username + Password (DPAPI vault)"
    Write-Host "  [2] API Token (DPAPI vault)"
    Write-Host "  [S] Skip"
    $pmxChoice = Read-Host "Selection"
    if ($pmxChoice.Trim().ToUpper() -eq '1' -or $pmxChoice.Trim().ToUpper() -eq '2') {
        $pmxHost = Read-Host "Proxmox host or IP [default: localhost]"
        if ([string]::IsNullOrWhiteSpace($pmxHost)) { $pmxHost = 'localhost' }
        $pmxHost = $pmxHost -replace '^https?://','' -replace ':[0-9]+$',''
        $script:ProxmoxServer = "https://${pmxHost}:8006"
        Write-Host "  Using: $($script:ProxmoxServer)" -ForegroundColor DarkGray
        if ($pmxChoice.Trim().ToUpper() -eq '2') {
            $script:ProxmoxAuthMethod = 'Token'
            $pmxToken = Resolve-DiscoveryCredential -Name "Proxmox.$pmxHost.Token" -CredType BearerToken -ProviderLabel 'Proxmox' -DeferSave
            if ($pmxToken) {
                $script:ProxmoxApiToken = $pmxToken
            } else { $TestProxmox = $false }
        } else {
            $script:ProxmoxAuthMethod = 'Password'
            $script:ProxmoxCred = Resolve-DiscoveryCredential -Name "Proxmox.$pmxHost.Credential" -CredType PSCredential -ProviderLabel 'Proxmox' -DeferSave
            if ($script:ProxmoxCred) {
                $script:ProxmoxUser   = $script:ProxmoxCred.UserName
                $script:ProxmoxPassSS = $script:ProxmoxCred.Password
            } else { $TestProxmox = $false }
        }
    } else { $TestProxmox = $false }
    if (-not $TestProxmox) { Skip-ProviderTests -Provider 'Proxmox' -Reason 'User skipped' -Cmdlets $script:ProxmoxCmdletList }
} else { Skip-ProviderTests -Provider 'Proxmox' -Reason 'Disabled' -Cmdlets $script:ProxmoxCmdletList }

if ($TestProxmox) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Proxmox ..." -ForegroundColor Cyan

    $script:FirstProxmoxNode = $null; $script:FirstProxmoxVM = $null

    Invoke-Test -Cmdlet 'Connect-ProxmoxServer' -Endpoint 'Proxmox / Auth / Connect-ProxmoxServer' -Test {
        Initialize-SSLBypass
        if ($script:ProxmoxAuthMethod -eq 'Token') {
            Write-Host "    Connecting to $($script:ProxmoxServer) with API token" -ForegroundColor DarkGray
            $result = Connect-ProxmoxServer -Server $script:ProxmoxServer -ApiToken $script:ProxmoxApiToken -ErrorAction Stop
            if (-not $result) { throw "Token validation failed" }
        } else {
            Write-Host "    Connecting to $($script:ProxmoxServer) as $($script:ProxmoxUser)" -ForegroundColor DarkGray
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:ProxmoxPassSS)
            try {
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                $script:ProxmoxCookie = Connect-ProxmoxServer -Server $script:ProxmoxServer -Username $script:ProxmoxUser -Password $plain -ErrorAction Stop
            } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if (-not $script:ProxmoxCookie) { throw "No cookie returned" }
        }
    }
    if ($script:ProxmoxAuthMethod -eq 'Token') {
        $pmxVaultName = "Proxmox.$($pmxHost).Token"
        if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:ProxmoxApiToken) {
            Save-ResolvedCredential -Name $pmxVaultName -CredType BearerToken -Value $script:ProxmoxApiToken
        }
    } else {
        $pmxVaultName = "Proxmox.$($pmxHost).Credential"
        if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:ProxmoxCred) {
            Save-ResolvedCredential -Name $pmxVaultName -CredType PSCredential -Value $script:ProxmoxCred
        }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name $pmxVaultName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestProxmox = $false
        Skip-ProviderTests -Provider 'Proxmox' -Reason 'Auth failed' -Cmdlets ($script:ProxmoxCmdletList | Where-Object { $_ -ne 'Connect-ProxmoxServer' })
    }

    if ($TestProxmox) {
        # Run Dashboard first -- it calls Nodes, VMs, NodeDetail, and VMDetail internally.
        # This avoids PS 5.1 connection-pool exhaustion from running them individually first.
        Invoke-Test -Cmdlet 'Get-ProxmoxDashboard' -Endpoint 'Proxmox / Dashboard / Get-ProxmoxDashboard' -Test {
            $script:ProxmoxDashboardData = Get-ProxmoxDashboard -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ApiToken $script:ProxmoxApiToken -ErrorAction Stop
            Assert-NotNull $script:ProxmoxDashboardData
        }
        $dashboardPassed = ($script:TestResults | Select-Object -Last 1).Status -eq 'Pass'

        # Validate sub-functions -- if Dashboard passed, verify via lightweight individual calls
        Invoke-Test -Cmdlet 'Get-ProxmoxNodes' -Endpoint 'Proxmox / Nodes / Get-ProxmoxNodes' -Test {
            $r = Get-ProxmoxNodes -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ApiToken $script:ProxmoxApiToken -ErrorAction Stop
            Assert-NotNull $r; $script:FirstProxmoxNode = @($r)[0].node
        }
        if ($script:FirstProxmoxNode) {
            Invoke-Test -Cmdlet 'Get-ProxmoxVMs' -Endpoint 'Proxmox / VMs / Get-ProxmoxVMs' -Test {
                $r = Get-ProxmoxVMs -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ApiToken $script:ProxmoxApiToken -Node $script:FirstProxmoxNode -ErrorAction Stop
                if ($r -and @($r).Count -gt 0) { $script:FirstProxmoxVM = @($r)[0] }
            }
            Invoke-Test -Cmdlet 'Get-ProxmoxNodeDetail' -Endpoint 'Proxmox / Nodes / Get-ProxmoxNodeDetail' -Test {
                Get-ProxmoxNodeDetail -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ApiToken $script:ProxmoxApiToken -Node $script:FirstProxmoxNode -ErrorAction Stop | Out-Null
            }
            if ($script:FirstProxmoxVM) {
                Invoke-Test -Cmdlet 'Get-ProxmoxVMDetail' -Endpoint 'Proxmox / VMs / Get-ProxmoxVMDetail' -Test {
                    Get-ProxmoxVMDetail -Server $script:ProxmoxServer -Cookie $script:ProxmoxCookie -ApiToken $script:ProxmoxApiToken -Node $script:FirstProxmoxNode -VMID $script:FirstProxmoxVM.vmid -ErrorAction Stop | Out-Null
                }
            } else { Record-Test -Cmdlet 'Get-ProxmoxVMDetail' -Endpoint 'Proxmox / VMs' -Status 'Skipped' -Detail 'No VMs on first node' }
        } else {
            Record-Test -Cmdlet 'Get-ProxmoxVMs' -Endpoint 'Proxmox / VMs' -Status 'Skipped' -Detail 'No nodes found'
            Record-Test -Cmdlet 'Get-ProxmoxNodeDetail' -Endpoint 'Proxmox / Nodes' -Status 'Skipped' -Detail 'No nodes found'
            Record-Test -Cmdlet 'Get-ProxmoxVMDetail' -Endpoint 'Proxmox / VMs' -Status 'Skipped' -Detail 'No nodes found'
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
#region -- Hyper-V ------------------------------------------------------------
###############################################################################
$script:HyperVHtmlOutPath = $null; $script:HyperVDashboardData = $null; $script:HyperVSession = $null

if ($TestHyperV) {
    Write-Host "`nHyper-V Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Remote host (Credential + CIM session)  [S] Skip"
    $hvChoice = Read-Host "Selection"
    if ($hvChoice.Trim().ToUpper() -eq '1') {
        $script:HyperVHost = Read-Host "Hyper-V host name or IP"
        $script:HyperVCred = Resolve-DiscoveryCredential -Name "HyperV.$($script:HyperVHost).Credential" -CredType PSCredential -ProviderLabel 'Hyper-V' -DeferSave
    } else { $TestHyperV = $false }
    if (-not $TestHyperV) { Skip-ProviderTests -Provider 'HyperV' -Reason 'User skipped' -Cmdlets $script:HyperVCmdletList }
} else { Skip-ProviderTests -Provider 'HyperV' -Reason 'Disabled or module unavailable' -Cmdlets $script:HyperVCmdletList }

if ($TestHyperV) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Hyper-V ..." -ForegroundColor Cyan

    $script:FirstHyperVVM = $null

    Invoke-Test -Cmdlet 'Connect-HypervHost' -Endpoint 'HyperV / Auth / Connect-HypervHost' -Test {
        Write-Host "    Connecting to $($script:HyperVHost) as $($script:HyperVCred.UserName) via CIM ..." -ForegroundColor DarkGray
        $script:HyperVSession = Connect-HypervHost -ComputerName $script:HyperVHost -Credential $script:HyperVCred -ErrorAction Stop
        if (-not $script:HyperVSession) { throw "No CIM session returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:HyperVCred) {
        Save-ResolvedCredential -Name "HyperV.$($script:HyperVHost).Credential" -CredType PSCredential -Value $script:HyperVCred
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name "HyperV.$($script:HyperVHost).Credential" -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
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
#region -- Nutanix ------------------------------------------------------------
###############################################################################
$script:NutanixHtmlOutPath = $null; $script:NutanixDashboardData = $null; $script:NutanixHeaders = $null

if ($TestNutanix) {
    Write-Host "`nNutanix Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Prism credentials  [S] Skip"
    $nxChoice = Read-Host "Selection"
    if ($nxChoice.Trim().ToUpper() -eq '1') {
        $script:NutanixServer = Read-Host "Prism server URI (e.g. https://192.168.1.50:9440)"
        $script:NutanixCred = Resolve-DiscoveryCredential -Name 'Nutanix.Prism.Credential' -CredType PSCredential -ProviderLabel 'Nutanix Prism' -DeferSave
    } else { $TestNutanix = $false }
    if (-not $TestNutanix) { Skip-ProviderTests -Provider 'Nutanix' -Reason 'User skipped' -Cmdlets $script:NutanixCmdletList }
} else { Skip-ProviderTests -Provider 'Nutanix' -Reason 'Disabled' -Cmdlets $script:NutanixCmdletList }

if ($TestNutanix) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Nutanix ..." -ForegroundColor Cyan

    $script:FirstNutanixHost = $null; $script:FirstNutanixVM = $null

    Invoke-Test -Cmdlet 'Connect-NutanixCluster' -Endpoint 'Nutanix / Auth / Connect-NutanixCluster' -Test {
        Write-Host "    Connecting to Nutanix Prism at $($script:NutanixServer) as $($script:NutanixCred.UserName) ..." -ForegroundColor DarkGray
        Initialize-SSLBypass
        $script:NutanixHeaders = Connect-NutanixCluster -Server $script:NutanixServer -Credential $script:NutanixCred -ErrorAction Stop
        if (-not $script:NutanixHeaders) { throw "No auth headers returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:NutanixCred) {
        Save-ResolvedCredential -Name 'Nutanix.Prism.Credential' -CredType PSCredential -Value $script:NutanixCred
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name 'Nutanix.Prism.Credential' -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
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
#region -- Fortinet (FortiGate + FortiManager) --------------------------------
###############################################################################
$script:FortinetHtmlOutPaths = @{}
$script:FortiGateDashboards  = @{}
$script:TestFortiManager = $false

if ($TestFortinet) {
    Write-Host "`nFortiGate Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] API Token  [2] Username + Password  [S] Skip"
    $fgChoice = Read-Host "Selection"
    switch ($fgChoice.Trim().ToUpper()) {
        '1' {
            $script:FGAuthMethod = 'Token'
            $script:FGServer = Read-Host "FortiGate host or IP"
            $fgPort = Read-Host "Port [443]"
            $script:FGPort = if ([string]::IsNullOrWhiteSpace($fgPort)) { 443 } else { [int]$fgPort }
            $script:FGToken = Resolve-DiscoveryCredential -Name "FortiGate.$($script:FGServer).Token" -CredType BearerToken -ProviderLabel 'FortiGate' -DeferSave
            if ($script:FGToken) {
                $script:FGTokenSS = ConvertTo-SecureString $script:FGToken -AsPlainText -Force
            } else {
                $TestFortinet = $false
            }
        }
        '2' {
            $script:FGAuthMethod = 'Credential'
            $script:FGServer = Read-Host "FortiGate host or IP"
            $fgPort = Read-Host "Port [443]"
            $script:FGPort = if ([string]::IsNullOrWhiteSpace($fgPort)) { 443 } else { [int]$fgPort }
            $script:FGCred = Resolve-DiscoveryCredential -Name "FortiGate.$($script:FGServer).Credential" -CredType PSCredential -ProviderLabel 'FortiGate' -DeferSave
        }
        default { $TestFortinet = $false }
    }
    if ($TestFortinet) {
        $fmgChoice = Read-Host "Also test FortiManager? [Y/N]"
        if ($fmgChoice -match '^[Yy]') {
            $script:TestFortiManager = $true
            $script:FMGServer = Read-Host "FortiManager host or IP"
            $script:FMGCred = Resolve-DiscoveryCredential -Name "FortiManager.$($script:FMGServer).Credential" -CredType PSCredential -ProviderLabel 'FortiManager' -DeferSave
        }
    }
    if (-not $TestFortinet) { Skip-ProviderTests -Provider 'Fortinet' -Reason 'User skipped' -Cmdlets $script:FortinetCmdletList }
} else { Skip-ProviderTests -Provider 'Fortinet' -Reason 'Disabled' -Cmdlets $script:FortinetCmdletList }

if ($TestFortinet) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Fortinet ..." -ForegroundColor Cyan

    # -- Auth --
    Invoke-Test -Cmdlet 'Connect-FortiGate' -Endpoint 'Fortinet / Auth / Connect-FortiGate' -Test {
        Write-Host "    Connecting to FortiGate at $($script:FGServer):$($script:FGPort) ($($script:FGAuthMethod) auth) ..." -ForegroundColor DarkGray
        switch ($script:FGAuthMethod) {
            'Token' {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:FGTokenSS)
                try {
                    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    Connect-FortiGate -Server $script:FGServer -Port $script:FGPort -APIToken $plain -IgnoreSSLErrors -ErrorAction Stop
                } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
            'Credential' {
                Connect-FortiGate -Server $script:FGServer -Port $script:FGPort -Credential $script:FGCred -IgnoreSSLErrors -ErrorAction Stop
            }
        }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass') {
        if ($script:FGAuthMethod -eq 'Token' -and $script:FGToken) {
            Save-ResolvedCredential -Name "FortiGate.$($script:FGServer).Token" -CredType BearerToken -Value $script:FGToken
        } elseif ($script:FGAuthMethod -eq 'Credential' -and $script:FGCred) {
            Save-ResolvedCredential -Name "FortiGate.$($script:FGServer).Credential" -CredType PSCredential -Value $script:FGCred
        }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        if ($script:FGAuthMethod -eq 'Token') {
            Remove-DiscoveryCredential -Name "FortiGate.$($script:FGServer).Token" -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Remove-DiscoveryCredential -Name "FortiGate.$($script:FGServer).Credential" -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestFortinet = $false
        Skip-ProviderTests -Provider 'Fortinet' -Reason 'Auth failed' -Cmdlets ($script:FortinetCmdletList | Where-Object { $_ -ne 'Connect-FortiGate' })
    }

    if ($TestFortinet) {
        # ===== System =====
        Write-Host "    -- System --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateSystemStatus' -Endpoint 'Fortinet / System / status' -Test {
            $r = Get-FortiGateSystemStatus -ErrorAction Stop; Assert-NotNull $r; Assert-HasProperty $r @('Hostname','SerialNumber')
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSystemResources' -Endpoint 'Fortinet / System / resource/usage' -Test {
            $r = Get-FortiGateSystemResources -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-FortiGateHAStatus' -Endpoint 'Fortinet / System / ha-peer' -Test {
            Get-FortiGateHAStatus -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateHAChecksums' -Endpoint 'Fortinet / System / ha-checksums' -Test {
            Get-FortiGateHAChecksums -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateFirmware' -Endpoint 'Fortinet / System / firmware' -Test {
            Get-FortiGateFirmware -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateLicenseStatus' -Endpoint 'Fortinet / System / license/status' -Test {
            Get-FortiGateLicenseStatus -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateGlobalSettings' -Endpoint 'Fortinet / System / system/global' -Test {
            $r = Get-FortiGateGlobalSettings -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-FortiGateAdmins' -Endpoint 'Fortinet / System / system/admin' -Test {
            $r = Get-FortiGateAdmins -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSystemDashboard' -Endpoint 'Fortinet / System / Dashboard' -Test {
            $script:FortiGateDashboards['System'] = Get-FortiGateSystemDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['System']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateSystemDashboardHtml' -Endpoint 'Fortinet / System / Export' -Test {
            $p = Join-Path $outDir "FortiGate-System-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateSystemDashboardHtml -DashboardData $script:FortiGateDashboards['System'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['System'] = $p
        }

        # ===== Network =====
        Write-Host "    -- Network --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateInterfaces' -Endpoint 'Fortinet / Network / interface' -Test {
            $r = Get-FortiGateInterfaces -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-FortiGateInterfaceConfig' -Endpoint 'Fortinet / Network / cmdb interface' -Test {
            $r = Get-FortiGateInterfaceConfig -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-FortiGateZones' -Endpoint 'Fortinet / Network / zone' -Test {
            Get-FortiGateZones -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateRoutes' -Endpoint 'Fortinet / Network / router/ipv4' -Test {
            Get-FortiGateRoutes -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateIPv6Routes' -Endpoint 'Fortinet / Network / router/ipv6' -Test {
            Get-FortiGateIPv6Routes -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateStaticRoutes' -Endpoint 'Fortinet / Network / router/static' -Test {
            Get-FortiGateStaticRoutes -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateARP' -Endpoint 'Fortinet / Network / arp' -Test {
            Get-FortiGateARP -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateDHCPLeases' -Endpoint 'Fortinet / Network / dhcp' -Test {
            Get-FortiGateDHCPLeases -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateDHCPServers' -Endpoint 'Fortinet / Network / dhcp/server' -Test {
            Get-FortiGateDHCPServers -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateDNS' -Endpoint 'Fortinet / Network / dns' -Test {
            $r = Get-FortiGateDNS -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-FortiGateNetworkDashboard' -Endpoint 'Fortinet / Network / Dashboard' -Test {
            $script:FortiGateDashboards['Network'] = Get-FortiGateNetworkDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Network']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateNetworkDashboardHtml' -Endpoint 'Fortinet / Network / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Network-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateNetworkDashboardHtml -DashboardData $script:FortiGateDashboards['Network'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Network'] = $p
        }

        # ===== Firewall =====
        Write-Host "    -- Firewall --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateFirewallPolicies' -Endpoint 'Fortinet / Firewall / policy' -Test {
            Get-FortiGateFirewallPolicies -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateAddresses' -Endpoint 'Fortinet / Firewall / address' -Test {
            Get-FortiGateAddresses -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateAddressGroups' -Endpoint 'Fortinet / Firewall / addrgrp' -Test {
            Get-FortiGateAddressGroups -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateServices' -Endpoint 'Fortinet / Firewall / service/custom' -Test {
            Get-FortiGateServices -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateServiceGroups' -Endpoint 'Fortinet / Firewall / service/group' -Test {
            Get-FortiGateServiceGroups -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSchedules' -Endpoint 'Fortinet / Firewall / schedule' -Test {
            Get-FortiGateSchedules -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateIPPools' -Endpoint 'Fortinet / Firewall / ippool' -Test {
            Get-FortiGateIPPools -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateVIPs' -Endpoint 'Fortinet / Firewall / vip' -Test {
            Get-FortiGateVIPs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateShapingPolicies' -Endpoint 'Fortinet / Firewall / shaping-policy' -Test {
            Get-FortiGateShapingPolicies -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateFirewallDashboard' -Endpoint 'Fortinet / Firewall / Dashboard' -Test {
            $script:FortiGateDashboards['Firewall'] = Get-FortiGateFirewallDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Firewall']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateFirewallDashboardHtml' -Endpoint 'Fortinet / Firewall / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Firewall-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateFirewallDashboardHtml -DashboardData $script:FortiGateDashboards['Firewall'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Firewall'] = $p
        }

        # ===== VPN =====
        Write-Host "    -- VPN --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateIPSecTunnels' -Endpoint 'Fortinet / VPN / ipsec' -Test {
            Get-FortiGateIPSecTunnels -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateIPSecPhase1' -Endpoint 'Fortinet / VPN / phase1-interface' -Test {
            Get-FortiGateIPSecPhase1 -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateIPSecPhase2' -Endpoint 'Fortinet / VPN / phase2-interface' -Test {
            Get-FortiGateIPSecPhase2 -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSSLVPNSessions' -Endpoint 'Fortinet / VPN / ssl' -Test {
            Get-FortiGateSSLVPNSessions -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSSLVPNSettings' -Endpoint 'Fortinet / VPN / ssl/settings' -Test {
            Get-FortiGateSSLVPNSettings -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateVPNDashboard' -Endpoint 'Fortinet / VPN / Dashboard' -Test {
            $script:FortiGateDashboards['VPN'] = Get-FortiGateVPNDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['VPN']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateVPNDashboardHtml' -Endpoint 'Fortinet / VPN / Export' -Test {
            $p = Join-Path $outDir "FortiGate-VPN-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateVPNDashboardHtml -DashboardData $script:FortiGateDashboards['VPN'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['VPN'] = $p
        }

        # ===== SD-WAN =====
        Write-Host "    -- SD-WAN --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANMembers' -Endpoint 'Fortinet / SDWAN / members' -Test {
            Get-FortiGateSDWANMembers -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANHealthCheck' -Endpoint 'Fortinet / SDWAN / health-check' -Test {
            Get-FortiGateSDWANHealthCheck -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANConfig' -Endpoint 'Fortinet / SDWAN / cmdb members' -Test {
            Get-FortiGateSDWANConfig -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANHealthCheckConfig' -Endpoint 'Fortinet / SDWAN / cmdb health-check' -Test {
            Get-FortiGateSDWANHealthCheckConfig -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANRules' -Endpoint 'Fortinet / SDWAN / service' -Test {
            Get-FortiGateSDWANRules -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANZones' -Endpoint 'Fortinet / SDWAN / zone' -Test {
            Get-FortiGateSDWANZones -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSDWANDashboard' -Endpoint 'Fortinet / SDWAN / Dashboard' -Test {
            $script:FortiGateDashboards['SDWAN'] = Get-FortiGateSDWANDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['SDWAN']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateSDWANDashboardHtml' -Endpoint 'Fortinet / SDWAN / Export' -Test {
            $p = Join-Path $outDir "FortiGate-SDWAN-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateSDWANDashboardHtml -DashboardData $script:FortiGateDashboards['SDWAN'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['SDWAN'] = $p
        }

        # ===== Security Profiles =====
        Write-Host "    -- Security Profiles --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateAntivirusProfiles' -Endpoint 'Fortinet / Security / antivirus' -Test {
            Get-FortiGateAntivirusProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateIPSSensors' -Endpoint 'Fortinet / Security / ips' -Test {
            Get-FortiGateIPSSensors -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateWebFilterProfiles' -Endpoint 'Fortinet / Security / webfilter' -Test {
            Get-FortiGateWebFilterProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateAppControlProfiles' -Endpoint 'Fortinet / Security / application' -Test {
            Get-FortiGateAppControlProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateDLPSensors' -Endpoint 'Fortinet / Security / dlp' -Test {
            Get-FortiGateDLPSensors -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateDNSFilterProfiles' -Endpoint 'Fortinet / Security / dnsfilter' -Test {
            Get-FortiGateDNSFilterProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSSLSSHProfiles' -Endpoint 'Fortinet / Security / ssl-ssh-profile' -Test {
            Get-FortiGateSSLSSHProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSecurityDashboard' -Endpoint 'Fortinet / Security / Dashboard' -Test {
            $script:FortiGateDashboards['Security'] = Get-FortiGateSecurityDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Security']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateSecurityDashboardHtml' -Endpoint 'Fortinet / Security / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Security-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateSecurityDashboardHtml -DashboardData $script:FortiGateDashboards['Security'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Security'] = $p
        }

        # ===== User & Auth =====
        Write-Host "    -- User & Auth --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateLocalUsers' -Endpoint 'Fortinet / UserAuth / user/local' -Test {
            Get-FortiGateLocalUsers -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateUserGroups' -Endpoint 'Fortinet / UserAuth / user/group' -Test {
            Get-FortiGateUserGroups -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateLDAPServers' -Endpoint 'Fortinet / UserAuth / user/ldap' -Test {
            Get-FortiGateLDAPServers -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateRADIUSServers' -Endpoint 'Fortinet / UserAuth / user/radius' -Test {
            Get-FortiGateRADIUSServers -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateActiveAuthUsers' -Endpoint 'Fortinet / UserAuth / user/firewall' -Test {
            Get-FortiGateActiveAuthUsers -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateFortiTokens' -Endpoint 'Fortinet / UserAuth / user/fortitoken' -Test {
            Get-FortiGateFortiTokens -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSAMLSP' -Endpoint 'Fortinet / UserAuth / user/saml' -Test {
            Get-FortiGateSAMLSP -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateUserAuthDashboard' -Endpoint 'Fortinet / UserAuth / Dashboard' -Test {
            $script:FortiGateDashboards['UserAuth'] = Get-FortiGateUserAuthDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['UserAuth']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateUserAuthDashboardHtml' -Endpoint 'Fortinet / UserAuth / Export' -Test {
            $p = Join-Path $outDir "FortiGate-UserAuth-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateUserAuthDashboardHtml -DashboardData $script:FortiGateDashboards['UserAuth'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['UserAuth'] = $p
        }

        # ===== Wireless =====
        Write-Host "    -- Wireless --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateManagedAPs' -Endpoint 'Fortinet / Wireless / managed_ap' -Test {
            Get-FortiGateManagedAPs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateWiFiClients' -Endpoint 'Fortinet / Wireless / client' -Test {
            Get-FortiGateWiFiClients -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateRogueAPs' -Endpoint 'Fortinet / Wireless / rogue_ap' -Test {
            Get-FortiGateRogueAPs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSSIDs' -Endpoint 'Fortinet / Wireless / vap' -Test {
            Get-FortiGateSSIDs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateWTPProfiles' -Endpoint 'Fortinet / Wireless / wtp-profile' -Test {
            Get-FortiGateWTPProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateWirelessDashboard' -Endpoint 'Fortinet / Wireless / Dashboard' -Test {
            $script:FortiGateDashboards['Wireless'] = Get-FortiGateWirelessDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Wireless']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateWirelessDashboardHtml' -Endpoint 'Fortinet / Wireless / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Wireless-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateWirelessDashboardHtml -DashboardData $script:FortiGateDashboards['Wireless'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Wireless'] = $p
        }

        # ===== Switch Controller =====
        Write-Host "    -- Switch --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateManagedSwitches' -Endpoint 'Fortinet / Switch / managed-switch' -Test {
            Get-FortiGateManagedSwitches -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSwitchPorts' -Endpoint 'Fortinet / Switch / port-stats' -Test {
            Get-FortiGateSwitchPorts -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSwitchConfig' -Endpoint 'Fortinet / Switch / cmdb managed-switch' -Test {
            Get-FortiGateSwitchConfig -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSwitchVLANs' -Endpoint 'Fortinet / Switch / vlan' -Test {
            Get-FortiGateSwitchVLANs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSwitchLLDP' -Endpoint 'Fortinet / Switch / lldp-profile' -Test {
            Get-FortiGateSwitchLLDP -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSwitchDashboard' -Endpoint 'Fortinet / Switch / Dashboard' -Test {
            $script:FortiGateDashboards['Switch'] = Get-FortiGateSwitchDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Switch']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateSwitchDashboardHtml' -Endpoint 'Fortinet / Switch / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Switch-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateSwitchDashboardHtml -DashboardData $script:FortiGateDashboards['Switch'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Switch'] = $p
        }

        # ===== Endpoint Security =====
        Write-Host "    -- Endpoint --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateEMSEndpoints' -Endpoint 'Fortinet / Endpoint / ems/status' -Test {
            Get-FortiGateEMSEndpoints -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateEMSConfig' -Endpoint 'Fortinet / Endpoint / fctems' -Test {
            Get-FortiGateEMSConfig -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateSecurityRating' -Endpoint 'Fortinet / Endpoint / security-rating' -Test {
            Get-FortiGateSecurityRating -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateEndpointProfiles' -Endpoint 'Fortinet / Endpoint / profile' -Test {
            Get-FortiGateEndpointProfiles -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateEndpointDashboard' -Endpoint 'Fortinet / Endpoint / Dashboard' -Test {
            $script:FortiGateDashboards['Endpoint'] = Get-FortiGateEndpointDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Endpoint']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateEndpointDashboardHtml' -Endpoint 'Fortinet / Endpoint / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Endpoint-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateEndpointDashboardHtml -DashboardData $script:FortiGateDashboards['Endpoint'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Endpoint'] = $p
        }

        # ===== Log & Report =====
        Write-Host "    -- Log --" -ForegroundColor DarkCyan
        Invoke-Test -Cmdlet 'Get-FortiGateTrafficLogs' -Endpoint 'Fortinet / Log / traffic' -Test {
            Get-FortiGateTrafficLogs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateEventLogs' -Endpoint 'Fortinet / Log / event' -Test {
            Get-FortiGateEventLogs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateUTMLogs' -Endpoint 'Fortinet / Log / utm' -Test {
            Get-FortiGateUTMLogs -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateLogStats' -Endpoint 'Fortinet / Log / stats' -Test {
            Get-FortiGateLogStats -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateFortiGuardStatus' -Endpoint 'Fortinet / Log / fortiguard' -Test {
            Get-FortiGateFortiGuardStatus -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateAlertMessages' -Endpoint 'Fortinet / Log / alert-email' -Test {
            Get-FortiGateAlertMessages -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-FortiGateLogDashboard' -Endpoint 'Fortinet / Log / Dashboard' -Test {
            $script:FortiGateDashboards['Log'] = Get-FortiGateLogDashboard -ErrorAction Stop
            Assert-NotNull $script:FortiGateDashboards['Log']
        }
        Invoke-Test -Cmdlet 'Export-FortiGateLogDashboardHtml' -Endpoint 'Fortinet / Log / Export' -Test {
            $p = Join-Path $outDir "FortiGate-Log-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-FortiGateLogDashboardHtml -DashboardData $script:FortiGateDashboards['Log'] -OutputPath $p -ErrorAction Stop
            if (-not (Test-Path $p)) { throw "File not created" }
            $script:FortinetHtmlOutPaths['Log'] = $p
        }

        # ===== FortiManager (optional) =====
        if ($script:TestFortiManager) {
            Write-Host "    -- FortiManager --" -ForegroundColor DarkCyan
            Invoke-Test -Cmdlet 'Connect-FortiManager' -Endpoint 'Fortinet / FMG / Auth' -Test {
                Write-Host "    Connecting to FortiManager at $($script:FMGServer) as $($script:FMGCred.UserName) ..." -ForegroundColor DarkGray
                Connect-FortiManager -Server $script:FMGServer -Credential $script:FMGCred -IgnoreSSLErrors -ErrorAction Stop
            }
            $fmgAuth = ($script:TestResults | Select-Object -Last 1).Status -eq 'Pass'
            if ($fmgAuth -and $script:FMGCred) {
                Save-ResolvedCredential -Name "FortiManager.$($script:FMGServer).Credential" -CredType PSCredential -Value $script:FMGCred
            } else {
                Remove-DiscoveryCredential -Name "FortiManager.$($script:FMGServer).Credential" -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "  Bad FortiManager credential removed from vault." -ForegroundColor Yellow
            }
            if ($fmgAuth) {
                Invoke-Test -Cmdlet 'Get-FortiManagerSystemStatus' -Endpoint 'Fortinet / FMG / sys/status' -Test {
                    $r = Get-FortiManagerSystemStatus -ErrorAction Stop; Assert-NotNull $r
                }
                Invoke-Test -Cmdlet 'Get-FortiManagerADOMs' -Endpoint 'Fortinet / FMG / adom' -Test {
                    Get-FortiManagerADOMs -ErrorAction Stop | Out-Null
                }
                Invoke-Test -Cmdlet 'Get-FortiManagerDevices' -Endpoint 'Fortinet / FMG / device' -Test {
                    Get-FortiManagerDevices -ErrorAction Stop | Out-Null
                }
                Invoke-Test -Cmdlet 'Get-FortiManagerPolicyPackages' -Endpoint 'Fortinet / FMG / pkg' -Test {
                    Get-FortiManagerPolicyPackages -ErrorAction Stop | Out-Null
                }
                Invoke-Test -Cmdlet 'Get-FortiManagerDashboard' -Endpoint 'Fortinet / FMG / Dashboard' -Test {
                    $script:FortiGateDashboards['FMG'] = Get-FortiManagerDashboard -ErrorAction Stop
                    Assert-NotNull $script:FortiGateDashboards['FMG']
                }
                Invoke-Test -Cmdlet 'Export-FortiManagerDashboardHtml' -Endpoint 'Fortinet / FMG / Export' -Test {
                    $p = Join-Path $outDir "FortiManager-$(Get-Date -Format 'yyyy-MM-dd').html"
                    Export-FortiManagerDashboardHtml -DashboardData $script:FortiGateDashboards['FMG'] -OutputPath $p -ErrorAction Stop
                    if (-not (Test-Path $p)) { throw "File not created" }
                    $script:FortinetHtmlOutPaths['FMG'] = $p
                }
            } else {
                foreach ($c in @('Get-FortiManagerSystemStatus','Get-FortiManagerADOMs','Get-FortiManagerDevices',
                                 'Get-FortiManagerPolicyPackages','Get-FortiManagerDashboard','Export-FortiManagerDashboardHtml')) {
                    Record-Test -Cmdlet $c -Endpoint 'Fortinet / FMG' -Status 'Skipped' -Detail 'FMG auth failed'
                }
            }
        } else {
            foreach ($c in @('Connect-FortiManager','Get-FortiManagerSystemStatus','Get-FortiManagerADOMs',
                             'Get-FortiManagerDevices','Get-FortiManagerPolicyPackages',
                             'Get-FortiManagerDashboard','Export-FortiManagerDashboardHtml')) {
                Record-Test -Cmdlet $c -Endpoint 'Fortinet / FMG' -Status 'Skipped' -Detail 'User chose not to test FortiManager'
            }
        }
    }
}
#endregion

###############################################################################
#region -- VMware -------------------------------------------------------------
###############################################################################
$script:VMwareHtmlOutPath = $null; $script:VMwareDashboardData = $null; $script:VMwareConnection = $null

if ($TestVMware) {
    Write-Host "`nVMware Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] vCenter / ESXi credentials  [S] Skip"
    $vmwChoice = Read-Host "Selection"
    if ($vmwChoice.Trim().ToUpper() -eq '1') {
        $script:VMwareServer = Read-Host "vCenter / ESXi host or IP"
        $script:VMwareCred = Resolve-DiscoveryCredential -Name "VMware.$($script:VMwareServer).Credential" -CredType PSCredential -ProviderLabel 'VMware vSphere' -DeferSave
    } else { $TestVMware = $false }
    if (-not $TestVMware) { Skip-ProviderTests -Provider 'VMware' -Reason 'User skipped' -Cmdlets $script:VMwareCmdletList }
} else { Skip-ProviderTests -Provider 'VMware' -Reason 'Disabled or modules unavailable' -Cmdlets $script:VMwareCmdletList }

if ($TestVMware) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing VMware ..." -ForegroundColor Cyan

    $script:FirstVMwareHost = $null; $script:FirstVMwareVM = $null

    Invoke-Test -Cmdlet 'Connect-VMware' -Endpoint 'VMware / Auth / Connect-VMware' -Test {
        Write-Host "    Connecting to VMware at $($script:VMwareServer) as $($script:VMwareCred.UserName) ..." -ForegroundColor DarkGray
        $script:VMwareConnection = Connect-VMware -Server $script:VMwareServer -Credential $script:VMwareCred -IgnoreSSLErrors -ErrorAction Stop
        if (-not $script:VMwareConnection) { throw "No connection returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:VMwareCred) {
        Save-ResolvedCredential -Name "VMware.$($script:VMwareServer).Credential" -CredType PSCredential -Value $script:VMwareCred
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name "VMware.$($script:VMwareServer).Credential" -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestVMware = $false
        Skip-ProviderTests -Provider 'VMware' -Reason 'Auth failed' -Cmdlets ($script:VMwareCmdletList | Where-Object { $_ -ne 'Connect-VMware' })
    }

    if ($TestVMware) {
        Invoke-Test -Cmdlet 'Get-VMwareClusters' -Endpoint 'VMware / Clusters / Get-VMwareClusters' -Test {
            $r = Get-VMwareClusters -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { Assert-HasProperty $r[0] @('Name','HAEnabled','DrsEnabled') }
        }
        Invoke-Test -Cmdlet 'Get-VMwareDatastores' -Endpoint 'VMware / Datastores / Get-VMwareDatastores' -Test {
            $r = Get-VMwareDatastores -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { Assert-HasProperty $r[0] @('Name','CapacityGB','FreeSpaceGB') }
        }
        Invoke-Test -Cmdlet 'Get-VMwareHosts' -Endpoint 'VMware / Hosts / Get-VMwareHosts' -Test {
            $r = Get-VMwareHosts -ErrorAction Stop
            Assert-NotNull $r; $script:FirstVMwareHost = @($r)[0]
        }
        if ($script:FirstVMwareHost) {
            Invoke-Test -Cmdlet 'Get-VMwareHostDetail' -Endpoint 'VMware / Hosts / Get-VMwareHostDetail' -Test {
                $r = Get-VMwareHostDetail -VMHost $script:FirstVMwareHost -ErrorAction Stop
                Assert-NotNull $r; Assert-HasProperty $r @('Name','IPAddress','Version','CpuCores','MemoryTotalGB')
            }
        } else { Record-Test -Cmdlet 'Get-VMwareHostDetail' -Endpoint 'VMware / Hosts' -Status 'Skipped' -Detail 'No ESXi hosts found' }
        Invoke-Test -Cmdlet 'Get-VMwareVMs' -Endpoint 'VMware / VMs / Get-VMwareVMs' -Test {
            $r = Get-VMwareVMs -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstVMwareVM = @($r)[0] }
        }
        if ($script:FirstVMwareVM) {
            Invoke-Test -Cmdlet 'Get-VMwareVMDetail' -Endpoint 'VMware / VMs / Get-VMwareVMDetail' -Test {
                $r = Get-VMwareVMDetail -VM $script:FirstVMwareVM -ErrorAction Stop
                Assert-NotNull $r; Assert-HasProperty $r @('Name','IPAddress','PowerState','NumCPU','MemoryGB')
            }
        } else { Record-Test -Cmdlet 'Get-VMwareVMDetail' -Endpoint 'VMware / VMs' -Status 'Skipped' -Detail 'No VMs found' }
        Invoke-Test -Cmdlet 'Get-VMwareDashboard' -Endpoint 'VMware / Dashboard / Get-VMwareDashboard' -Test {
            $script:VMwareDashboardData = Get-VMwareDashboard -ErrorAction Stop
            Assert-NotNull $script:VMwareDashboardData
        }
        $vmwTpl = Join-Path $helpersRoot 'vmware\VMware-Dashboard-Template.html'
        if ($script:VMwareDashboardData -and @($script:VMwareDashboardData).Count -gt 0 -and (Test-Path $vmwTpl)) {
            Invoke-Test -Cmdlet 'Export-VMwareDashboardHtml' -Endpoint 'VMware / Export / Export-VMwareDashboardHtml' -Test {
                $script:VMwareHtmlOutPath = Join-Path $outDir "Get-VMwareDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-VMwareDashboardHtml -DashboardData $script:VMwareDashboardData -OutputPath $script:VMwareHtmlOutPath -ReportTitle 'WUGHelperTest VMware' -TemplatePath $vmwTpl -ErrorAction Stop
                if (-not (Test-Path $script:VMwareHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-VMwareDashboardHtml' -Endpoint 'VMware / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region -- Certificates -------------------------------------------------------
###############################################################################
$script:CertHtmlOutPath = $null; $script:CertDashboardData = $null

if ($TestCertificates) {
    Write-Host "`nCertificate Scanning:" -ForegroundColor Cyan
    Write-Host "  [1] Scan IP addresses for TLS certificates  [S] Skip"
    $certChoice = Read-Host "Selection"
    if ($certChoice.Trim().ToUpper() -eq '1') {
        $certInput = Read-Host "IP address(es) to scan (comma-separated)"
        $script:CertIPs = $certInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $certPortInput = Read-Host "TCP port(s) [443,8443]"
        if ([string]::IsNullOrWhiteSpace($certPortInput)) {
            $script:CertPorts = @(443, 8443)
        } else {
            $script:CertPorts = $certPortInput -split ',' | ForEach-Object { [int]$_.Trim() }
        }
    } else { $TestCertificates = $false }
    if (-not $TestCertificates) { Skip-ProviderTests -Provider 'Certificates' -Reason 'User skipped' -Cmdlets $script:CertificatesCmdletList }
} else { Skip-ProviderTests -Provider 'Certificates' -Reason 'Disabled' -Cmdlets $script:CertificatesCmdletList }

if ($TestCertificates) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Certificates ..." -ForegroundColor Cyan

    $script:CertRawData = $null

    Invoke-Test -Cmdlet 'Get-CertificateInfo' -Endpoint 'Certificates / Scan / Get-CertificateInfo' -Test {
        $script:CertRawData = Get-CertificateInfo -IPAddresses $script:CertIPs -TcpPorts $script:CertPorts -ErrorAction Stop
        Assert-NotNull $script:CertRawData
        if (@($script:CertRawData).Count -gt 0) {
            Assert-HasProperty $script:CertRawData[0] @('IPAddress','Port','Subject','ExpirationDate','Thumbprint')
        }
    }
    if ($script:CertRawData -and @($script:CertRawData).Count -gt 0) {
        Invoke-Test -Cmdlet 'Get-CertificateDashboard' -Endpoint 'Certificates / Dashboard / Get-CertificateDashboard' -Test {
            $script:CertDashboardData = Get-CertificateDashboard -CertificateData $script:CertRawData -ErrorAction Stop
            Assert-NotNull $script:CertDashboardData
            Assert-HasProperty $script:CertDashboardData[0] @('IPAddress','Port','Status','DaysUntilExpiry','Subject')
        }
    } else {
        Record-Test -Cmdlet 'Get-CertificateDashboard' -Endpoint 'Certificates / Dashboard' -Status 'Skipped' -Detail 'No certificates discovered'
    }
    $certTpl = Join-Path $helpersRoot 'certificates\Certificate-Dashboard-Template.html'
    if ($script:CertDashboardData -and @($script:CertDashboardData).Count -gt 0 -and (Test-Path $certTpl)) {
        Invoke-Test -Cmdlet 'Export-CertificateDashboardHtml' -Endpoint 'Certificates / Export / Export-CertificateDashboardHtml' -Test {
            $script:CertHtmlOutPath = Join-Path $outDir "Get-CertificateDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
            Export-CertificateDashboardHtml -DashboardData $script:CertDashboardData -OutputPath $script:CertHtmlOutPath -ReportTitle 'WUGHelperTest Certificates' -TemplatePath $certTpl -ErrorAction Stop
            if (-not (Test-Path $script:CertHtmlOutPath)) { throw "File not created" }
        }
    } else { Record-Test -Cmdlet 'Export-CertificateDashboardHtml' -Endpoint 'Certificates / Export' -Status 'Skipped' -Detail 'No data or template missing' }
}
#endregion

###############################################################################
#region -- F5 BIG-IP ----------------------------------------------------------
###############################################################################
$script:F5HtmlOutPath = $null; $script:F5DashboardData = $null

if ($TestF5) {
    Write-Host "`nF5 BIG-IP Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Username + Password  [S] Skip"
    $f5Choice = Read-Host "Selection"
    if ($f5Choice.Trim().ToUpper() -eq '1') {
        $script:F5Host = Read-Host "F5 BIG-IP hostname or IP"
        $f5PortInput = Read-Host "Port [443]"
        $script:F5Port = if ([string]::IsNullOrWhiteSpace($f5PortInput)) { 443 } else { [int]$f5PortInput }
        $script:F5Cred = Resolve-DiscoveryCredential -Name "F5.$($script:F5Host).Credential" -CredType PSCredential -ProviderLabel 'F5 BIG-IP' -DeferSave
    } else { $TestF5 = $false }
    if (-not $TestF5) { Skip-ProviderTests -Provider 'F5' -Reason 'User skipped' -Cmdlets $script:F5CmdletList }
} else { Skip-ProviderTests -Provider 'F5' -Reason 'Disabled' -Cmdlets $script:F5CmdletList }

if ($TestF5) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing F5 BIG-IP ..." -ForegroundColor Cyan

    $script:FirstF5VS = $null; $script:FirstF5Pool = $null

    Invoke-Test -Cmdlet 'Connect-F5Server' -Endpoint 'F5 / Auth / Connect-F5Server' -Test {
        Write-Host "    Connecting to F5 BIG-IP at $($script:F5Host):$($script:F5Port) as $($script:F5Cred.UserName) ..." -ForegroundColor DarkGray
        Connect-F5Server -F5Host $script:F5Host -Port $script:F5Port -Credential $script:F5Cred -IgnoreSSLErrors -ErrorAction Stop
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:F5Cred) {
        Save-ResolvedCredential -Name "F5.$($script:F5Host).Credential" -CredType PSCredential -Value $script:F5Cred
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name "F5.$($script:F5Host).Credential" -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestF5 = $false
        Skip-ProviderTests -Provider 'F5' -Reason 'Auth failed' -Cmdlets ($script:F5CmdletList | Where-Object { $_ -ne 'Connect-F5Server' })
    }

    if ($TestF5) {
        Invoke-Test -Cmdlet 'Get-F5SystemInfo' -Endpoint 'F5 / System / Get-F5SystemInfo' -Test {
            $r = Get-F5SystemInfo -ErrorAction Stop; Assert-NotNull $r
        }
        Invoke-Test -Cmdlet 'Get-F5VirtualServers' -Endpoint 'F5 / VS / Get-F5VirtualServers' -Test {
            $r = Get-F5VirtualServers -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstF5VS = @($r)[0] }
        }
        if ($script:FirstF5VS) {
            Invoke-Test -Cmdlet 'Get-F5VirtualServerStats' -Endpoint 'F5 / VS / Get-F5VirtualServerStats' -Test {
                Get-F5VirtualServerStats -ErrorAction Stop | Out-Null
            }
        } else { Record-Test -Cmdlet 'Get-F5VirtualServerStats' -Endpoint 'F5 / VS / Stats' -Status 'Skipped' -Detail 'No virtual servers found' }
        Invoke-Test -Cmdlet 'Get-F5Pools' -Endpoint 'F5 / Pools / Get-F5Pools' -Test {
            $r = Get-F5Pools -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstF5Pool = @($r)[0] }
        }
        if ($script:FirstF5Pool) {
            Invoke-Test -Cmdlet 'Get-F5PoolMembers' -Endpoint 'F5 / Pools / Get-F5PoolMembers' -Test {
                Get-F5PoolMembers -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-F5PoolMemberStats' -Endpoint 'F5 / Pools / Get-F5PoolMemberStats' -Test {
                Get-F5PoolMemberStats -ErrorAction Stop | Out-Null
            }
        } else {
            Record-Test -Cmdlet 'Get-F5PoolMembers' -Endpoint 'F5 / Pools' -Status 'Skipped' -Detail 'No pools found'
            Record-Test -Cmdlet 'Get-F5PoolMemberStats' -Endpoint 'F5 / Pools' -Status 'Skipped' -Detail 'No pools found'
        }
        Invoke-Test -Cmdlet 'Get-F5Nodes' -Endpoint 'F5 / Nodes / Get-F5Nodes' -Test {
            Get-F5Nodes -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-F5Dashboard' -Endpoint 'F5 / Dashboard / Get-F5Dashboard' -Test {
            $script:F5DashboardData = Get-F5Dashboard -ErrorAction Stop
            Assert-NotNull $script:F5DashboardData
        }
        $f5Tpl = Join-Path $helpersRoot 'f5\F5-Dashboard-Template.html'
        if ($script:F5DashboardData -and @($script:F5DashboardData).Count -gt 0 -and (Test-Path $f5Tpl)) {
            Invoke-Test -Cmdlet 'Export-F5DashboardHtml' -Endpoint 'F5 / Export / Export-F5DashboardHtml' -Test {
                $script:F5HtmlOutPath = Join-Path $outDir "Get-F5DashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-F5DashboardHtml -DashboardData $script:F5DashboardData -OutputPath $script:F5HtmlOutPath -ReportTitle 'WUGHelperTest F5' -TemplatePath $f5Tpl -ErrorAction Stop
                if (-not (Test-Path $script:F5HtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-F5DashboardHtml' -Endpoint 'F5 / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region -- Geolocation --------------------------------------------------------
###############################################################################
$script:GeoHtmlOutPath = $null; $script:GeoData = $null; $script:GeoConfig = $null

if ($TestGeolocation) {
    Write-Host "`nGeolocation (WhatsUp Gold REST API):" -ForegroundColor Cyan
    Write-Host "  [1] Connect to WUG server  [S] Skip"
    $geoChoice = Read-Host "Selection"
    if ($geoChoice.Trim().ToUpper() -eq '1') {
        $script:WUGServerInfo = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -DeferSave
        if ($script:WUGServerInfo) {
            $script:GeoServer     = $script:WUGServerInfo.Server
            $script:GeoPort       = $script:WUGServerInfo.Port
            $script:GeoProtocol   = $script:WUGServerInfo.Protocol
            $script:GeoCred       = $script:WUGServerInfo.Credential
            $script:GeoIgnoreSSL  = $script:WUGServerInfo.IgnoreSSL
            $script:GeoConsoleUrl = "$($script:GeoProtocol)://$($script:GeoServer):443"
            Write-Host "  Console URL: $($script:GeoConsoleUrl)" -ForegroundColor DarkGray
        } else {
            $TestGeolocation = $false
        }
    } else { $TestGeolocation = $false }
    if (-not $TestGeolocation) { Skip-ProviderTests -Provider 'Geolocation' -Reason 'User skipped' -Cmdlets $script:GeolocationCmdletList }
} else { Skip-ProviderTests -Provider 'Geolocation' -Reason 'Disabled' -Cmdlets $script:GeolocationCmdletList }

if ($TestGeolocation) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Geolocation ..." -ForegroundColor Cyan

    Invoke-Test -Cmdlet 'Connect-GeoWUGServer' -Endpoint 'Geolocation / Auth / Connect-GeoWUGServer' -Test {
        Write-Host "    Connecting to WUG at $($script:GeoProtocol)://$($script:GeoServer):$($script:GeoPort) as $($script:GeoCred.GetNetworkCredential().UserName) ..." -ForegroundColor DarkGray
        $splat = @{
            ServerUri = $script:GeoServer
            Username  = $script:GeoCred.GetNetworkCredential().UserName
            Password  = $script:GeoCred.GetNetworkCredential().Password
            Protocol  = $script:GeoProtocol
            Port      = $script:GeoPort
        }
        if ($script:GeoIgnoreSSL) { $splat.IgnoreSSLErrors = $true }
        $script:GeoConfig = Connect-GeoWUGServer @splat -ErrorAction Stop
        if (-not $script:GeoConfig) { throw "No config returned" }
    }
    # Save to vault only if connection succeeded
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:WUGServerInfo) {
        Save-ResolvedCredential -Name 'WUG.Server' -CredType WUGServer -Value $script:WUGServerInfo
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name 'WUG.Server' -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestGeolocation = $false
        Skip-ProviderTests -Provider 'Geolocation' -Reason 'Connection failed' -Cmdlets ($script:GeolocationCmdletList | Where-Object { $_ -ne 'Connect-GeoWUGServer' })
    }

    if ($TestGeolocation) {
        Invoke-Test -Cmdlet 'Get-GeoDevicesWithLocation' -Endpoint 'Geolocation / Devices / Get-GeoDevicesWithLocation' -Test {
            $r = Get-GeoDevicesWithLocation -Config $script:GeoConfig -ErrorAction Stop
            # Result may be empty if no devices have LatLong attribute - that's OK
        }
        Invoke-Test -Cmdlet 'Get-GeoGroupsWithLocation' -Endpoint 'Geolocation / Groups / Get-GeoGroupsWithLocation' -Test {
            $r = Get-GeoGroupsWithLocation -Config $script:GeoConfig -ErrorAction Stop
        }
        Invoke-Test -Cmdlet 'Get-GeolocationData' -Endpoint 'Geolocation / Data / Get-GeolocationData' -Test {
            $script:GeoData = Get-GeolocationData -Config $script:GeoConfig -ErrorAction Stop
            Assert-NotNull $script:GeoData
        }
        $geoTpl = Join-Path $helpersRoot 'geolocation\Geolocation-Map-Template.html'
        if ($script:GeoData -and @($script:GeoData).Count -gt 0 -and (Test-Path $geoTpl)) {
            Invoke-Test -Cmdlet 'Export-GeolocationMapHtml' -Endpoint 'Geolocation / Export / Export-GeolocationMapHtml' -Test {
                $script:GeoHtmlOutPath = Join-Path $outDir "Geolocation-Map-$(Get-Date -Format 'yyyy-MM-dd').html"
                $exportSplat = @{
                    Data         = @($script:GeoData)
                    OutputPath   = $script:GeoHtmlOutPath
                    TemplatePath = $geoTpl
                }
                if ($script:GeoConsoleUrl) { $exportSplat.WugBaseUrl = $script:GeoConsoleUrl }
                Export-GeolocationMapHtml @exportSplat -ErrorAction Stop
                if (-not (Test-Path $script:GeoHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-GeolocationMapHtml' -Endpoint 'Geolocation / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region -- Docker -------------------------------------------------------------
###############################################################################
$script:DockerHtmlOutPath = $null; $script:DockerDashboardData = $null; $script:DockerConnection = $null

if ($TestDocker) {
    Write-Host "`nDocker Engine API:" -ForegroundColor Cyan
    Write-Host "  [1] Connect to Docker host (HTTP/HTTPS)  [S] Skip"
    $dkrChoice = Read-Host "Selection"
    if ($dkrChoice.Trim().ToUpper() -eq '1') {
        $script:DockerHost = Read-Host "Docker host (hostname or IP)"
        $dkrPort = Read-Host "Port [2375]"
        $script:DockerPort = if ([string]::IsNullOrWhiteSpace($dkrPort)) { 2375 } else { [int]$dkrPort }
        $dkrTLS = Read-Host "Use TLS? [Y/N, default N]"
        $script:DockerUseTLS = $dkrTLS -match '^[Yy]'
        $dkrSSL = Read-Host "Ignore SSL errors? [Y/N, default Y]"
        $script:DockerIgnoreSSL = if ($dkrSSL -match '^[Nn]') { $false } else { $true }
    } else { $TestDocker = $false }
    if (-not $TestDocker) { Skip-ProviderTests -Provider 'Docker' -Reason 'User skipped' -Cmdlets $script:DockerCmdletList }
} else { Skip-ProviderTests -Provider 'Docker' -Reason 'Disabled' -Cmdlets $script:DockerCmdletList }

if ($TestDocker) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Docker ..." -ForegroundColor Cyan

    $script:FirstDockerContainer = $null

    Invoke-Test -Cmdlet 'Connect-DockerServer' -Endpoint 'Docker / Auth / Connect-DockerServer' -Test {
        $splat = @{ DockerHost = $script:DockerHost; Port = $script:DockerPort }
        if ($script:DockerUseTLS) { $splat.UseTLS = $true }
        if ($script:DockerIgnoreSSL) { $splat.IgnoreSSLErrors = $true }
        $script:DockerConnection = Connect-DockerServer @splat -ErrorAction Stop
        if (-not $script:DockerConnection) { throw "No connection returned" }
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        $TestDocker = $false
        Skip-ProviderTests -Provider 'Docker' -Reason 'Connection failed' -Cmdlets ($script:DockerCmdletList | Where-Object { $_ -ne 'Connect-DockerServer' })
    }

    if ($TestDocker) {
        Invoke-Test -Cmdlet 'Get-DockerSystemInfo' -Endpoint 'Docker / System / Get-DockerSystemInfo' -Test {
            $r = Get-DockerSystemInfo -Connection $script:DockerConnection -ErrorAction Stop
            Assert-NotNull $r
            Assert-HasProperty $r @('Hostname','DockerVersion','Containers','CPUs')
        }
        Invoke-Test -Cmdlet 'Get-DockerContainers' -Endpoint 'Docker / Containers / Get-DockerContainers' -Test {
            $r = Get-DockerContainers -Connection $script:DockerConnection -ErrorAction Stop
            if ($r -and @($r).Count -gt 0) { $script:FirstDockerContainer = @($r)[0] }
        }
        if ($script:FirstDockerContainer) {
            Invoke-Test -Cmdlet 'Get-DockerContainerDetail' -Endpoint 'Docker / Containers / Get-DockerContainerDetail' -Test {
                $r = Get-DockerContainerDetail -Connection $script:DockerConnection -ContainerId $script:FirstDockerContainer.Id -ErrorAction Stop
                Assert-NotNull $r
            }
            if ($script:FirstDockerContainer.State -eq 'running') {
                Invoke-Test -Cmdlet 'Get-DockerContainerStats' -Endpoint 'Docker / Containers / Get-DockerContainerStats' -Test {
                    $r = Get-DockerContainerStats -Connection $script:DockerConnection -ContainerId $script:FirstDockerContainer.Id -ErrorAction Stop
                    Assert-NotNull $r
                    Assert-HasProperty $r @('CpuPercent','MemoryUsageMB','MemoryPercent')
                }
            } else {
                Record-Test -Cmdlet 'Get-DockerContainerStats' -Endpoint 'Docker / Containers' -Status 'Skipped' -Detail 'First container not running'
            }
        } else {
            Record-Test -Cmdlet 'Get-DockerContainerDetail' -Endpoint 'Docker / Containers' -Status 'Skipped' -Detail 'No containers found'
            Record-Test -Cmdlet 'Get-DockerContainerStats' -Endpoint 'Docker / Containers' -Status 'Skipped' -Detail 'No containers found'
        }
        Invoke-Test -Cmdlet 'Get-DockerNetworks' -Endpoint 'Docker / Networks / Get-DockerNetworks' -Test {
            Get-DockerNetworks -Connection $script:DockerConnection -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-DockerVolumes' -Endpoint 'Docker / Volumes / Get-DockerVolumes' -Test {
            Get-DockerVolumes -Connection $script:DockerConnection -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-DockerImages' -Endpoint 'Docker / Images / Get-DockerImages' -Test {
            Get-DockerImages -Connection $script:DockerConnection -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-DockerDashboard' -Endpoint 'Docker / Dashboard / Get-DockerDashboard' -Test {
            $script:DockerDashboardData = Get-DockerDashboard -Connection $script:DockerConnection -ErrorAction Stop
            Assert-NotNull $script:DockerDashboardData
        }
        $dkrTpl = Join-Path $helpersRoot 'docker\Docker-Dashboard-Template.html'
        if ($script:DockerDashboardData -and @($script:DockerDashboardData).Count -gt 0 -and (Test-Path $dkrTpl)) {
            Invoke-Test -Cmdlet 'Export-DockerDashboardHtml' -Endpoint 'Docker / Export / Export-DockerDashboardHtml' -Test {
                $script:DockerHtmlOutPath = Join-Path $outDir "Get-DockerDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-DockerDashboardHtml -DashboardData $script:DockerDashboardData -OutputPath $script:DockerHtmlOutPath -ReportTitle 'WUGHelperTest Docker' -TemplatePath $dkrTpl -ErrorAction Stop
                if (-not (Test-Path $script:DockerHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-DockerDashboardHtml' -Endpoint 'Docker / Export' -Status 'Skipped' -Detail 'No data or template missing' }
    }
}
#endregion

###############################################################################
#region -- Cleanup ------------------------------------------------------------
###############################################################################
$currentSection++
Write-Host "`n[$currentSection/$sectionCount] Cleaning up and disconnecting ..." -ForegroundColor Cyan

if ($script:AWSAuthMethod -eq 'Keys') {
    Invoke-Test -Cmdlet 'AWS Session Cleanup' -Endpoint 'AWS / Auth / Remove-AWSCredentialProfile' -Test {
        Remove-AWSCredentialProfile -ProfileName 'WhatsUpGoldPS_Session' -Force -ErrorAction SilentlyContinue
    }
} elseif ($script:AWSAuthMethod -eq 'Profile') {
    Record-Test -Cmdlet 'AWS Session Cleanup' -Endpoint 'AWS / Auth / Clear-AWSCredential' -Status 'Pass' -Detail 'Profile auth - no stored creds to clear'
}

if ($script:AzureAuthMethod) {
    Invoke-Test -Cmdlet 'Azure Session Disconnect' -Endpoint 'Azure / Auth / Disconnect-AzAccount' -Test {
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
    }
}

if ($script:ProxmoxCookie -or $script:ProxmoxApiToken) {
    Record-Test -Cmdlet 'Proxmox Session Cleanup' -Endpoint 'Proxmox / Auth / (session)' -Status 'Pass' -Detail 'Auth cleared from memory'
    $script:ProxmoxCookie = $null
    $script:ProxmoxApiToken = $null
}

if ($script:HyperVSession) {
    Invoke-Test -Cmdlet 'HyperV Session Cleanup' -Endpoint 'HyperV / Auth / Remove-CimSession' -Test {
        Remove-CimSession -CimSession $script:HyperVSession -ErrorAction SilentlyContinue
    }
}

if ($TestFortinet -and (Get-Command 'Disconnect-FortiGate' -ErrorAction SilentlyContinue)) {
    Invoke-Test -Cmdlet 'Disconnect-FortiGate' -Endpoint 'Fortinet / Auth / Disconnect' -Test {
        Disconnect-FortiGate -ErrorAction SilentlyContinue
    }
}
if ($script:TestFortiManager -and (Get-Command 'Disconnect-FortiManager' -ErrorAction SilentlyContinue)) {
    Invoke-Test -Cmdlet 'Disconnect-FortiManager' -Endpoint 'Fortinet / FMG / Disconnect' -Test {
        Disconnect-FortiManager -ErrorAction SilentlyContinue
    }
}

if ($script:VMwareConnection) {
    Invoke-Test -Cmdlet 'VMware Session Cleanup' -Endpoint 'VMware / Auth / Disconnect-VMware' -Test {
        Disconnect-VMware -ErrorAction SilentlyContinue
    }
}

if ($TestF5 -and $script:F5DashboardData) {
    Record-Test -Cmdlet 'F5 Session Cleanup' -Endpoint 'F5 / Auth / (session)' -Status 'Pass' -Detail 'REST session cleared from memory'
}

$script:AWSAccessKey = $null; $script:AWSSecretKeySS = $null; $script:AWSProfileName = $null
$script:AzureAppId = $null; $script:AzureClientSecretSS = $null
$script:ProxmoxPassSS = $null; $script:NutanixHeaders = $null; $script:NutanixCred = $null
$script:HyperVCred = $null; $script:GCPKeyFilePath = $null
$script:FGTokenSS = $null; $script:FGCred = $null; $script:FMGCred = $null
$script:VMwareCred = $null; $script:VMwareConnection = $null
$script:CertIPs = $null; $script:CertPorts = $null
$script:F5Cred = $null; $script:F5Host = $null
$script:DockerConnection = $null; $script:DockerHost = $null
$script:GeoConfig = $null; $script:GeoCred = $null; $script:GeoServer = $null
$script:BigleafApiKey = $null; $script:BigleafApiKeySS = $null
$script:LansweeperPAT = $null; $script:LansweeperPATSS = $null
#endregion

###############################################################################
#region -- Bigleaf ------------------------------------------------------------
###############################################################################
$script:BigleafHtmlOutPath = $null; $script:BigleafDashboardData = $null

if ($TestBigleaf) {
    Write-Host "`nBigleaf Cloud Connect Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] API Key (HTTP Basic)  [S] Skip"
    $blChoice = Read-Host "Selection"
    if ($blChoice.Trim().ToUpper() -eq '1') {
        $script:BigleafApiKeySS = Resolve-DiscoveryCredential -Name 'Bigleaf.Credential' -CredType BearerToken -ProviderLabel 'Bigleaf' -DeferSave
    } else { $TestBigleaf = $false }
    if (-not $TestBigleaf) { Skip-ProviderTests -Provider 'Bigleaf' -Reason 'User skipped' -Cmdlets $script:BigleafCmdletList }
} else { Skip-ProviderTests -Provider 'Bigleaf' -Reason 'Disabled' -Cmdlets $script:BigleafCmdletList }

if ($TestBigleaf) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Bigleaf ..." -ForegroundColor Cyan

    Invoke-Test -Cmdlet 'Connect-BigleafAPI' -Endpoint 'Bigleaf / Auth / Connect-BigleafAPI' -Test {
        Connect-BigleafAPI -ApiKey $script:BigleafApiKeySS -ErrorAction Stop
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:BigleafApiKeySS) {
        Save-ResolvedCredential -Name 'Bigleaf.Credential' -CredType BearerToken -Value $script:BigleafApiKeySS
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name 'Bigleaf.Credential' -Confirm:`$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestBigleaf = $false
        Skip-ProviderTests -Provider 'Bigleaf' -Reason 'Auth failed' -Cmdlets ($script:BigleafCmdletList | Where-Object { $_ -ne 'Connect-BigleafAPI' })
    }

    if ($TestBigleaf) {
        $script:FirstBigleafSite = $null

        Invoke-Test -Cmdlet 'Get-BigleafSites' -Endpoint 'Bigleaf / Sites / Get-BigleafSites' -Test {
            $sites = Get-BigleafSites -ErrorAction Stop
            Assert-NotNull $sites
            if (@($sites).Count -gt 0) { $script:FirstBigleafSite = $sites[0] }
        }

        if ($script:FirstBigleafSite) {
            Invoke-Test -Cmdlet 'Get-BigleafSiteStatus' -Endpoint 'Bigleaf / Sites / Get-BigleafSiteStatus' -Test {
                Get-BigleafSiteStatus -SiteId $script:FirstBigleafSite.id -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-BigleafCircuitStatus' -Endpoint 'Bigleaf / Circuits / Get-BigleafCircuitStatus' -Test {
                Get-BigleafCircuitStatus -SiteId $script:FirstBigleafSite.id -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-BigleafDeviceStatus' -Endpoint 'Bigleaf / Devices / Get-BigleafDeviceStatus' -Test {
                Get-BigleafDeviceStatus -SiteId $script:FirstBigleafSite.id -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-BigleafSiteRisks' -Endpoint 'Bigleaf / Risks / Get-BigleafSiteRisks' -Test {
                Get-BigleafSiteRisks -SiteId $script:FirstBigleafSite.id -ErrorAction Stop | Out-Null
            }
        } else {
            foreach ($c in @('Get-BigleafSiteStatus','Get-BigleafCircuitStatus','Get-BigleafDeviceStatus','Get-BigleafSiteRisks')) {
                Record-Test -Cmdlet $c -Endpoint 'Bigleaf / (skipped)' -Status 'Skipped' -Detail 'No sites found'
            }
        }

        Invoke-Test -Cmdlet 'Get-BigleafAccounts' -Endpoint 'Bigleaf / Accounts / Get-BigleafAccounts' -Test {
            Get-BigleafAccounts -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-BigleafCompanies' -Endpoint 'Bigleaf / Companies / Get-BigleafCompanies' -Test {
            Get-BigleafCompanies -ErrorAction Stop | Out-Null
        }
        Invoke-Test -Cmdlet 'Get-BigleafMetadata' -Endpoint 'Bigleaf / Metadata / Get-BigleafMetadata' -Test {
            Get-BigleafMetadata -ErrorAction Stop | Out-Null
        }

        Invoke-Test -Cmdlet 'Get-BigleafDashboard' -Endpoint 'Bigleaf / Dashboard / Get-BigleafDashboard' -Test {
            $script:BigleafDashboardData = Get-BigleafDashboard -ErrorAction Stop
            Assert-NotNull $script:BigleafDashboardData
        }

        $blTpl = Join-Path $helpersRoot 'bigleaf\Bigleaf-Dashboard-Template.html'
        if ($script:BigleafDashboardData -and @($script:BigleafDashboardData).Count -gt 0 -and (Test-Path $blTpl)) {
            Invoke-Test -Cmdlet 'Export-BigleafDashboardHtml' -Endpoint 'Bigleaf / Export / Export-BigleafDashboardHtml' -Test {
                $script:BigleafHtmlOutPath = Join-Path $outDir "Get-BigleafDashboardResult-$(Get-Date -Format 'yyyy-MM-dd').html"
                Export-BigleafDashboardHtml -DashboardData $script:BigleafDashboardData -OutputPath $script:BigleafHtmlOutPath -TemplatePath $blTpl -ErrorAction Stop
                if (-not (Test-Path $script:BigleafHtmlOutPath)) { throw "File not created" }
            }
        } else { Record-Test -Cmdlet 'Export-BigleafDashboardHtml' -Endpoint 'Bigleaf / Export' -Status 'Skipped' -Detail 'No data or template missing' }

        Invoke-Test -Cmdlet 'Bigleaf Session Cleanup' -Endpoint 'Bigleaf / Auth / Disconnect-BigleafAPI' -Test {
            Disconnect-BigleafAPI -ErrorAction Stop
        }
    }
}
#endregion

###############################################################################
#region -- Lansweeper ---------------------------------------------------------
###############################################################################
$script:LansweeperSiteId = $null

if ($TestLansweeper) {
    Write-Host "`nLansweeper Authentication:" -ForegroundColor Cyan
    Write-Host "  [1] Personal Access Token (PAT)  [S] Skip"
    $lsChoice = Read-Host "Selection"
    if ($lsChoice.Trim().ToUpper() -eq '1') {
        $script:LansweeperPATSS = Resolve-DiscoveryCredential -Name 'Lansweeper.Credential' -CredType BearerToken -ProviderLabel 'Lansweeper' -DeferSave
    } else { $TestLansweeper = $false }
    if (-not $TestLansweeper) { Skip-ProviderTests -Provider 'Lansweeper' -Reason 'User skipped' -Cmdlets $script:LansweeperCmdletList }
} else { Skip-ProviderTests -Provider 'Lansweeper' -Reason 'Disabled' -Cmdlets $script:LansweeperCmdletList }

if ($TestLansweeper) {
    $currentSection++
    Write-Host "`n[$currentSection/$sectionCount] Testing Lansweeper ..." -ForegroundColor Cyan

    Invoke-Test -Cmdlet 'Connect-LansweeperPAT' -Endpoint 'Lansweeper / Auth / Connect-LansweeperPAT' -Test {
        Connect-LansweeperPAT -PersonalAccessToken $script:LansweeperPATSS -ErrorAction Stop
    }
    if (($script:TestResults | Select-Object -Last 1).Status -eq 'Pass' -and $script:LansweeperPATSS) {
        Save-ResolvedCredential -Name 'Lansweeper.Credential' -CredType BearerToken -Value $script:LansweeperPATSS
    }
    if (($script:TestResults | Select-Object -Last 1).Status -ne 'Pass') {
        Remove-DiscoveryCredential -Name 'Lansweeper.Credential' -Confirm:`$false -ErrorAction SilentlyContinue
        Write-Host "  Bad credential removed from vault." -ForegroundColor Yellow
        $TestLansweeper = $false
        Skip-ProviderTests -Provider 'Lansweeper' -Reason 'Auth failed' -Cmdlets ($script:LansweeperCmdletList | Where-Object { $_ -ne 'Connect-LansweeperPAT' })
    }

    if ($TestLansweeper) {
        Invoke-Test -Cmdlet 'Get-LansweeperCurrentUser' -Endpoint 'Lansweeper / User / Get-LansweeperCurrentUser' -Test {
            $user = Get-LansweeperCurrentUser -ErrorAction Stop
            Assert-NotNull $user
        }

        $script:LansweeperSites = $null
        Invoke-Test -Cmdlet 'Get-LansweeperSites' -Endpoint 'Lansweeper / Sites / Get-LansweeperSites' -Test {
            $script:LansweeperSites = Get-LansweeperSites -ErrorAction Stop
            Assert-NotNull $script:LansweeperSites
            if (@($script:LansweeperSites).Count -gt 0) {
                $script:LansweeperSiteId = $script:LansweeperSites[0].id
            }
        }

        if ($script:LansweeperSiteId) {
            Invoke-Test -Cmdlet 'Get-LansweeperSiteInfo' -Endpoint 'Lansweeper / Sites / Get-LansweeperSiteInfo' -Test {
                Get-LansweeperSiteInfo -SiteId $script:LansweeperSiteId -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-LansweeperAssetTypes' -Endpoint 'Lansweeper / Assets / Get-LansweeperAssetTypes' -Test {
                Get-LansweeperAssetTypes -SiteId $script:LansweeperSiteId -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-LansweeperAssetGroups' -Endpoint 'Lansweeper / Assets / Get-LansweeperAssetGroups' -Test {
                Get-LansweeperAssetGroups -SiteId $script:LansweeperSiteId -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-LansweeperAssets' -Endpoint 'Lansweeper / Assets / Get-LansweeperAssets' -Test {
                $assets = Get-LansweeperAssets -SiteId $script:LansweeperSiteId -Limit 5 -ErrorAction Stop
                Assert-NotNull $assets
                if (@($assets).Count -gt 0) { $script:FirstLansweeperAsset = $assets[0] }
            }
            if ($script:FirstLansweeperAsset -and $script:FirstLansweeperAsset.assetBasicInfo -and $script:FirstLansweeperAsset.assetBasicInfo.key) {
                Invoke-Test -Cmdlet 'Get-LansweeperAssetDetails' -Endpoint 'Lansweeper / Assets / Get-LansweeperAssetDetails' -Test {
                    Get-LansweeperAssetDetails -SiteId $script:LansweeperSiteId -AssetKey $script:FirstLansweeperAsset.assetBasicInfo.key -ErrorAction Stop | Out-Null
                }
            } else {
                Record-Test -Cmdlet 'Get-LansweeperAssetDetails' -Endpoint 'Lansweeper / Assets' -Status 'Skipped' -Detail 'No assets found'
            }
            Invoke-Test -Cmdlet 'Get-LansweeperSources' -Endpoint 'Lansweeper / Sources / Get-LansweeperSources' -Test {
                Get-LansweeperSources -SiteId $script:LansweeperSiteId -ErrorAction Stop | Out-Null
            }
            Invoke-Test -Cmdlet 'Get-LansweeperAccounts' -Endpoint 'Lansweeper / Accounts / Get-LansweeperAccounts' -Test {
                Get-LansweeperAccounts -SiteId $script:LansweeperSiteId -ErrorAction Stop | Out-Null
            }
        } else {
            foreach ($c in @('Get-LansweeperSiteInfo','Get-LansweeperAssetTypes','Get-LansweeperAssetGroups','Get-LansweeperAssets','Get-LansweeperAssetDetails','Get-LansweeperSources','Get-LansweeperAccounts')) {
                Record-Test -Cmdlet $c -Endpoint 'Lansweeper / (skipped)' -Status 'Skipped' -Detail 'No sites found'
            }
        }

        Invoke-Test -Cmdlet 'Disconnect-Lansweeper' -Endpoint 'Lansweeper / Auth / Disconnect-Lansweeper' -Test {
            Disconnect-Lansweeper -ErrorAction Stop
        }
    }
}
#endregion

###############################################################################
#region -- Discovery Runner ---------------------------------------------------
###############################################################################
if ($TestDiscovery) {
    Write-Host "`n=== Discovery Runner (end-to-end) ===" -ForegroundColor Magenta

    $discoveryRunnerPath = Join-Path $PSScriptRoot 'Invoke-WUGDiscoveryRunner.ps1'
    if (Test-Path $discoveryRunnerPath) {
        $discoveryOutDir = Join-Path $outDir 'DiscoveryRunner'
        if (-not (Test-Path $discoveryOutDir)) {
            New-Item -ItemType Directory -Path $discoveryOutDir -Force | Out-Null
        }

        # Map the active helper-test toggles to discovery runner params
        $drParams = @{
            OutputPath     = $discoveryOutDir
            NonInteractive = $true
        }
        if ($TestAWS)      { $drParams.RunAWS      = $true }
        if ($TestAzure)    { $drParams.RunAzure    = $true }
        if ($TestF5)       { $drParams.RunF5       = $true }
        if ($TestFortinet) { $drParams.RunFortinet = $true }
        if ($TestHyperV)   { $drParams.RunHyperV   = $true }
        if ($TestProxmox)  { $drParams.RunProxmox  = $true }
        if ($TestVMware)   { $drParams.RunVMware   = $true }

        Invoke-Test -Cmdlet 'Discovery Runner' -Endpoint 'Discovery / Runner / Execute' -Test {
            & $discoveryRunnerPath @drParams
        }

        # Collect discovery runner report if generated
        $drReports = @(Get-ChildItem -Path $discoveryOutDir -Filter 'DiscoveryRunner-Report-*.html' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($drReports.Count -gt 0) {
            $script:DiscoveryRunnerReportPath = $drReports[0].FullName
            Record-Test -Cmdlet 'Discovery Runner Report' -Endpoint $script:DiscoveryRunnerReportPath -Status 'Pass'
        }

        $drPlans = @(Get-ChildItem -Path $discoveryOutDir -Filter 'MasterPlan-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($drPlans.Count -gt 0) {
            $planContent = Get-Content -Path $drPlans[0].FullName -Raw -ErrorAction SilentlyContinue
            $planItems = ($planContent | ConvertFrom-Json -ErrorAction SilentlyContinue)
            $planItemCount = if ($planItems) { @($planItems).Count } else { 0 }
            Record-Test -Cmdlet 'Discovery Master Plan' -Endpoint $drPlans[0].FullName `
                -Status $(if ($planItemCount -gt 0) { 'Pass' } else { 'Fail' }) `
                -Detail "$planItemCount items across all providers"
        }
    }
    else {
        Record-Test -Cmdlet 'Discovery Runner' -Endpoint $discoveryRunnerPath `
            -Status 'Fail' -Detail 'Invoke-WUGDiscoveryRunner.ps1 not found'
    }
}
else {
    Skip-ProviderTests -Provider 'Discovery' -Reason 'TestDiscovery not enabled' `
        -Cmdlets @('Discovery Runner','Discovery Runner Report','Discovery Master Plan')
}
#endregion

###############################################################################
#region -- Summary ------------------------------------------------------------
###############################################################################
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Filter results for display
$displayResults = if ($IncludeSkipped) { $script:TestResults } else {
    @($script:TestResults | Where-Object Status -ne 'Skipped')
}

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
if (-not $IncludeSkipped -and $skipped -gt 0) {
    Write-Host "  ($skipped skipped tests hidden - use -IncludeSkipped to show)" -ForegroundColor DarkGray
}
if ($displayResults -and @($displayResults).Count -gt 0) {
    $displayResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail
}

$reportTemplatePath = Join-Path $helpersRoot 'reports\Bootstrap-Table-Sample.html'
$script:TestResultsHtmlPath = Join-Path $outDir "Get-HelperTestResult-$(Get-Date -Format 'yyyy-MM-dd').html"

$htmlGenerated = $false
if ($displayResults -and @($displayResults).Count -gt 0) {
    $htmlGenerated = Export-TestResultsHtml -TestResults $displayResults `
        -OutputPath $script:TestResultsHtmlPath -TemplatePath $reportTemplatePath
}

$reportFiles = @()
if ($htmlGenerated -and (Test-Path $script:TestResultsHtmlPath)) { $reportFiles += $script:TestResultsHtmlPath }
foreach ($p in @($script:AWSHtmlOutPath, $script:AzureHtmlOutPath, $script:GCPHtmlOutPath,
                 $script:OCIHtmlOutPath, $script:ProxmoxHtmlOutPath, $script:HyperVHtmlOutPath,
                 $script:NutanixHtmlOutPath, $script:VMwareHtmlOutPath,
                 $script:CertHtmlOutPath, $script:F5HtmlOutPath,
                 $script:DockerHtmlOutPath,
                 $script:GeoHtmlOutPath,
                 $script:BigleafHtmlOutPath,
                 $script:DiscoveryRunnerReportPath)) {
    if ($p -and (Test-Path $p)) { $reportFiles += $p }
}
if ($script:FortinetHtmlOutPaths) {
    foreach ($p in $script:FortinetHtmlOutPaths.Values) {
        if ($p -and (Test-Path $p)) { $reportFiles += $p }
    }
}

if ($reportFiles.Count -gt 0) {
    Write-Host "`n  HTML Reports Generated:" -ForegroundColor Cyan
    foreach ($f in $reportFiles) { Write-Host "    $f" -ForegroundColor White }
    Write-Host ""
}

$displayResults
#endregion
# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBc223cKV6J9Sss
# C7V4PCM1oFr+0NPAtGniE6Ufi+HmAaCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAKUqqn
# A67L8kp8VDhVXGObrwnIWAll3AeUQYIvF0GdEzANBgkqhkiG9w0BAQEFAASCAgAe
# vosJoqMZMiJeW+Ir7app3rKR60rhLkTAl7JEErZl/dLAjHCO4WzoL4wDfZ6UsKoL
# GILB5AtnSNVN3EaLWuE0Knl7wySXrtArXjtODa8DBcNJm1JGWXGJ06Ziz9kcMkep
# uZW7LwSCvIVNamHIPG20Z+RBTIUesQTrLls0lAt1xvrde67UNk9QUMwcmNnHzhMs
# t3mQXay2HGGasFa0LkHs9SivaSPThHP4oq6li11ZTb+nwOjha/XvTuy4e5kDBq6o
# MTgtsFGPcYSF/cgUytRj3HtYuC4e0HBwvpzdSN1idEprRcZkWAQgVyt7TM8bJYeR
# SrH/M2Rmd7wDN9g3ETUWF0Ec4NA1eq+ZPmrhrbGOoRY+VDxYps3E9JekXXh8sw83
# /bTLU/f5frNUl/rNDRyD68313MWw2/wUqb7gO84yg4ddFw5PPaVeNolxHJaGrs9c
# LoJjvU7eNpjvC47hOs0lr7yMUz8VyK9Ovbg9G4t1bBQWAokQQSUdm46WMtY+V6MI
# by1Bip9o0gREse17GjfHWAEAOEIAIp5yJwxo4IpifdlGZqQjpsvnaeFkITW8kheW
# X+3oC6hFBTemyO2Kx4i1NI+pF7QlgcRzThl1aS8pnuN7G3dKgRWqlfy5pWLHISwM
# Wn9BpYxVT74Ok7EpX0hTVd5pAo+HaZWjPxV15FdmS6GCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwODAxMzEx
# OFowPwYJKoZIhvcNAQkEMTIEMF866Y7HwdILHvtHVZ58in3TuffH/NEEshyEjSR/
# 8G1fkk1FbyXas6V8aVBQpmfxpjANBgkqhkiG9w0BAQEFAASCAgBIuKLJZXQAGPHK
# /wGjg7EFypYBWk2jKWk9GdKEligFHLwqyohpWIlHqBQfCvtSZQbM+DCQQoJ3rwCo
# 56vTWLsF0qvUpTIMwAHn7W6Qj9nrkwY4erlVRQHtpO+SSK4mtOOl0gPVsyRRx1qX
# gWBdw2iZZRvia7f2+VO2mgMwLOzyEvGkbh4pF2eQmtEnOhag5dTkh0wDKWNPBFvW
# MRTiK7uRvfLtaXJ1YWIyHPSSGUQ+rhFZsRUDebaLXgQXVYQOqmCsGCM85n/HsHD4
# SxALCMi/TQ38D8/M21pywWUW81VTFrY+mqBs+WbxOAsi4yUktcp4dzQOddU18z1O
# MzMffJnEIY3w52kmP6gcjlyaFHp802pBVLCGQ+9dQ25RDG38zEHb9znxlIJYHwUc
# yN/he6xWluq5LgPVv1N8b3pSyh5qHqUeevDo4kCHDKDO3VviF4P6lFCOS6/zxfvt
# bNX8OvYLF/QtuOaRZItpROAD1QVhtcnF6//LqjDe5v3i34Dq1Y8sx974eXC+sVeb
# iDDBvO29rSwcdN0C0aeM9vnnhNAtUeQCfmF9yug1SnEvfQ0vaQw2bhYboOI5K1fe
# mQiVgZVgMzgcsDAw5OPSGtghnBjNIVe/ND9d2WA/jXXuY+9s0nY1ojsUhiwRS9dl
# 0nepargK1yjCCKI9CMfo5tEhcrBqVQ==
# SIG # End signature block
