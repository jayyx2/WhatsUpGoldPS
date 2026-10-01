<#
.SYNOPSIS
    Guided first-time setup wizard for WhatsUpGoldPS Discovery.

.DESCRIPTION
    Interactive wizard that walks a new user through the complete setup:

      Step 1 - WhatsUp Gold server connection (optional)
      Step 2 - Provider selection (which cloud/infra platforms to discover)
      Step 3 - Per-provider configuration (targets, credentials, auth methods)
      Step 4 - Test discovery run per provider
      Step 5 - Optionally schedule recurring discovery tasks
      Step 6 - Optionally schedule dashboard copy to WUG web console

    All credentials are stored in the local DPAPI-encrypted vault so
    future runs (interactive or scheduled) are seamless.

    Run this script once interactively. After that, providers can be
    run individually via Setup-*-Discovery.ps1 -NonInteractive, or
    on a schedule via Register-DiscoveryScheduledTask.ps1.

.PARAMETER SkipWUG
    Skip WhatsUp Gold server configuration (discovery-only mode).

.PARAMETER SkipTest
    Skip the test discovery run for each configured provider.

.PARAMETER SkipSchedule
    Skip the scheduled task registration prompts.

.PARAMETER OutputPath
    Output directory for discovery results and dashboards.
    Default: $env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Output

.EXAMPLE
    .\Start-WUGDiscoverySetup.ps1

    Full guided setup with all steps.

.EXAMPLE
    .\Start-WUGDiscoverySetup.ps1 -SkipWUG

    Set up providers for dashboard/export only (no WUG integration).

.EXAMPLE
    .\Start-WUGDiscoverySetup.ps1 -SkipTest -SkipSchedule

    Configure providers and credentials only; skip test runs and scheduling.

.NOTES
    Author  : jason@wug.ninja
    Created : 2025-07-14
    Requires: PowerShell 5.1+
#>
[CmdletBinding()]
param(
    [switch]$SkipWUG,
    [switch]$SkipTest,
    [switch]$SkipSchedule,
    [string]$OutputPath,

    # Vault scope for DPAPI credential encryption.
    # LocalMachine (default): any administrator or SYSTEM process on this machine
    #   can decrypt. Required for scheduled tasks running as SYSTEM.
    # CurrentUser: only your user account on this machine can decrypt.
    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$VaultScope = 'LocalMachine'
)

# ============================================================================
# region  Init
# ============================================================================
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent

# Dot-source shared helpers
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')

# Set vault scope before any credential operations
if ($VaultScope -eq 'LocalMachine') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host ''
        Write-Host '  [WARNING] LocalMachine vault requires administrator rights.' -ForegroundColor Yellow
        Write-Host '  Credentials will be readable by SYSTEM scheduled tasks ONLY if this' -ForegroundColor Yellow
        Write-Host '  wizard is run as Administrator. Re-run elevated for scheduled task support.' -ForegroundColor Yellow
        Write-Host '  Falling back to CurrentUser vault for this session.' -ForegroundColor DarkGray
        Write-Host ''
        $VaultScope = 'CurrentUser'
    }
}
Set-DiscoveryVaultScope -Scope $VaultScope
Write-Verbose "Vault scope: $VaultScope  Path: $script:DiscoveryVaultPath"

if (-not $OutputPath) {
    if ($VaultScope -eq 'LocalMachine') {
        $OutputPath = Join-Path $env:ProgramData 'WhatsUpGoldPS\Output'
    }
    else {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    }
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Provider metadata - defines what each provider needs
$providerDefs = [ordered]@{
    AWS      = @{
        Label       = 'Amazon Web Services (AWS)'
        Script      = 'Setup-AWS-Discovery.ps1'
        TargetLabel = 'AWS region(s) (comma-separated, or "all")'
        TargetDefault = 'all'
        TargetParam = 'Region'
        CredType    = 'AWSKeys'
        CredVault   = 'AWS.Credential'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires IAM Access Key + Secret Key with EC2/RDS/ELB read permissions.'
    }
    Azure    = @{
        Label       = 'Microsoft Azure'
        Script      = 'Setup-Azure-Discovery.ps1'
        TargetLabel = 'Subscription ID or name filter (blank = all subscriptions)'
        TargetDefault = ''
        TargetParam = 'SubscriptionFilter'
        CredType    = 'AzureSP'
        CredVault   = 'Azure'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires a Service Principal (App Registration) with Reader role.'
    }
    Bigleaf  = @{
        Label       = 'Bigleaf Networks'
        Script      = 'Setup-Bigleaf-Discovery.ps1'
        TargetLabel = 'Bigleaf API target'
        TargetDefault = 'bigleaf'
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'Bigleaf.Credential'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires Bigleaf portal username + password.'
    }
    CUCM     = @{
        Label       = 'Cisco Unified Communications Manager (CUCM)'
        Script      = 'Setup-CUCM-Discovery.ps1'
        TargetLabel = 'CUCM host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = 'CUCM.Snmp'
        AuthChoices = @(
            @{ Key = '1'; Label = 'SNMP v2c (community string)'; Value = 'SnmpV2' }
            @{ Key = '2'; Label = 'SNMP v3 (user/auth/privacy)'; Value = 'SnmpV3' }
        )
        ApiPort     = $null
        Notes       = 'Runs on the WUG server using SharpSnmpLib and generates a phone inventory dashboard plus optional SNMPTable phone status monitors.'
    }
    CiscoWLC = @{
        Label       = 'Cisco Wireless LAN Controller (WLC)'
        Script      = 'Setup-CiscoWLC-Discovery.ps1'
        TargetLabel = 'WLC host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = 'CiscoWLC.Snmp'
        AuthChoices = @(
            @{ Key = '1'; Label = 'SNMP v2c (community string)'; Value = 'SnmpV2' }
            @{ Key = '2'; Label = 'SNMP v3 (user/auth/privacy)'; Value = 'SnmpV3' }
        )
        ApiPort     = $null
        Notes       = 'Discovers APs, clients, WLANs via SNMP LWAPP MIBs. Generates wireless dashboard and optional WUG monitors.'
    }
    Docker   = @{
        Label       = 'Docker Hosts'
        Script      = 'Setup-Docker-Discovery.ps1'
        TargetLabel = 'Docker host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 2375
        Notes       = 'Docker API must be exposed (default port 2375). No credentials needed.'
    }
    F5       = @{
        Label       = 'F5 BIG-IP'
        Script      = 'Setup-F5-Discovery.ps1'
        TargetLabel = 'F5 BIG-IP host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 443
        Notes       = 'Requires iControl REST API access (admin or resource-admin role).'
    }
    Fortinet = @{
        Label       = 'Fortinet FortiGate'
        Script      = 'Setup-Fortinet-Discovery.ps1'
        TargetLabel = 'FortiGate host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'BearerToken'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 443
        Notes       = 'Requires a REST API token from FortiGate (System > Administrators > REST API).'
    }
    UniFi = @{
        Label       = 'UniFi Network Controller'
        Script      = 'Setup-UniFi-Discovery.ps1'
        TargetLabel = 'Local UniFi OS console - IP or FQDN (single controller)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'BearerToken'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 443
        Notes       = 'Uses the local read-only Network API key. WUG push stores that key in REST monitor templates and requires explicit opt-in; scheduled WUG pushes are disabled.'
    }
    GCP      = @{
        Label       = 'Google Cloud Platform (GCP)'
        Script      = 'Setup-GCP-Discovery.ps1'
        TargetLabel = 'GCP project ID(s) (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = 'GCP.ServiceAccount'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires a service account JSON key file with Compute Viewer role.'
    }
    HyperV   = @{
        Label       = 'Microsoft Hyper-V'
        Script      = 'Setup-HyperV-Discovery.ps1'
        TargetLabel = 'Hyper-V host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires WinRM/CIM access with Hyper-V admin permissions.'
    }
    LoadMaster = @{
        Label       = 'Kemp LoadMaster'
        Script      = 'Setup-LoadMaster-Discovery.ps1'
        TargetLabel = 'LoadMaster host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = $null
        AuthChoices = @(
            @{ Key = '1'; Label = 'API Key (recommended for WUG monitoring)'; Value = 'ApiKey'; CredType = 'BearerToken' }
            @{ Key = '2'; Label = 'bal:password (standalone discovery or Basic Auth)'; Value = 'Password'; CredType = 'PSCredential' }
        )
        ApiPort     = 443
        Notes       = 'Requires LoadMaster firmware 7.2.50+ for APIv2 JSON support.'
    }
    MSCluster = @{
        Label       = 'Microsoft Failover Cluster (WSFC/MSCS)'
        Script      = 'Setup-MSCluster-Discovery.ps1'
        TargetLabel = 'Any cluster node - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'Windows.WMI.Credential.1'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'One node discovers the whole cluster. Requires WMI/DCOM access with local admin rights. Node-local counters go on the nodes; clustered role availability goes on the role virtual IPs. Shares credentials with Windows Attributes.'
    }
    MSSQL    = @{
        Label       = 'Microsoft SQL Server (WMI performance counters)'
        Script      = 'Setup-MSSQL-Discovery.ps1'
        TargetLabel = 'SQL Server Windows host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'Windows.WMI.Credential.1'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Discovers SQL instances and databases over WMI and creates WMI Formatted performance monitors. Requires local admin rights. Shares credentials with Windows Attributes.'
    }
    Nutanix  = @{
        Label       = 'Nutanix AHV / Prism'
        Script      = 'Setup-Nutanix-Discovery.ps1'
        TargetLabel = 'Nutanix Prism Central host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 9440
        Notes       = 'Requires Prism Central admin or viewer credentials.'
    }
    NvidiaSmi = @{
        Label       = 'NVIDIA GPU (nvidia-smi via SSH)'
        Script      = 'Setup-NvidiaSmi-Discovery.ps1'
        TargetLabel = 'Linux GPU host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'NvidiaSmi.Ssh'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires SSH access to Linux hosts with nvidia-smi installed. Creates WUG SSH performance monitors.'
    }
    OCI      = @{
        Label       = 'Oracle Cloud Infrastructure (OCI)'
        Script      = 'Setup-OCI-Discovery.ps1'
        TargetLabel = 'OCI tenancy OCID (or blank to use config file)'
        TargetDefault = ''
        TargetParam = 'TenancyId'
        CredType    = 'OCIConfig'
        CredVault   = 'OCI.Config'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires an OCI config file (~/.oci/config) with API signing key.'
    }
    Proxmox  = @{
        Label       = 'Proxmox VE'
        Script      = 'Setup-Proxmox-Discovery.ps1'
        TargetLabel = 'Proxmox host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = $null
        AuthChoices = @(
            @{ Key = '1'; Label = 'API Token (recommended for WUG monitoring)'; Value = 'Token'; CredType = 'BearerToken' }
            @{ Key = '2'; Label = 'Username + Password (standalone discovery only)'; Value = 'Password'; CredType = 'PSCredential' }
        )
        ApiPort     = 8006
        Notes       = 'API token: Datacenter > Permissions > API Tokens. Needs PVEAuditor role.'
    }
    Redfish  = @{
        Label       = 'Redfish BMC (HPE iLO, Dell iDRAC, Lenovo XCC, Supermicro)'
        Script      = 'Setup-Redfish-Discovery.ps1'
        TargetLabel = 'BMC address(es) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 443
        Notes       = 'Requires a read-only BMC account. The default deep walk takes about two minutes per BMC.'
    }
    NetworkNeighbors = @{
        Label       = 'Network Neighbors (BGP, EIGRP, CDP, LLDP via SNMP)'
        Script      = 'Setup-NetworkNeighbors-Discovery.ps1'
        TargetLabel = 'Router/switch address(es) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'SNMPv2'
        CredVault   = 'Cisco.Snmp'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Walks BGP4, EIGRP, CDP and LLDP MIBs. Creates SNMP table monitors per protocol and a BGP established monitor per peer.'
    }
    Certificates = @{
        Label       = 'TLS Certificates (expiry and trust)'
        Script      = 'Setup-Certificates-Discovery.ps1'
        TargetLabel = 'Host(s) serving TLS - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = $null
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Probes ports 443 and 8443 by default. Creates a WUG Certificate monitor per endpoint. No credentials needed.'
    }
    Linux    = @{
        Label       = 'Linux Hosts (SSH compliance: NTP, patches, disks, systemd)'
        Script      = 'Setup-Linux-Discovery.ps1'
        TargetLabel = 'Linux host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'Linux.Ssh'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires SSH access. Creates WUG SSH active and performance monitors plus Linux.* attributes.'
    }
    ConfigDrift = @{
        Label       = 'Configuration Drift (SSH baseline, diff and policy)'
        Script      = 'Setup-ConfigDrift-Discovery.ps1'
        TargetLabel = 'Cisco IOS device(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'ConfigDrift.Ssh'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Pulls running configs over SSH (cisco-ios profile by default). First run stores the baseline; later runs publish ConfigDrift.* attributes.'
    }
    VMware   = @{
        Label       = 'VMware vCenter / ESXi'
        Script      = 'Setup-VMware-Discovery.ps1'
        TargetLabel = 'vCenter or ESXi host - IP or FQDN'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = $null
        AuthChoices = $null
        ApiPort     = 443
        Notes       = 'Requires vSphere API access (read-only role sufficient for discovery).'
    }
    WindowsAttributes = @{
        Label       = 'Windows Attributes (WMI inventory)'
        Script      = 'Setup-WindowsAttributes-Discovery.ps1'
        TargetLabel = 'Windows host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'Windows.WMI.Credential.1'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires WMI/DCOM or WinRM access with local admin permissions.'
    }
    WindowsDiskIO = @{
        Label       = 'Windows Disk IO (WMI performance monitors)'
        Script      = 'Setup-WindowsDiskIO-Discovery.ps1'
        TargetLabel = 'Windows host(s) - IP or FQDN (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'PSCredential'
        CredVault   = 'Windows.WMI.Credential.1'
        AuthChoices = $null
        ApiPort     = $null
        Notes       = 'Requires WMI/DCOM or WinRM access with local admin permissions. Shares credentials with Windows Attributes.'
    }
}
# endregion

# ============================================================================
# region  Helper: section header
# ============================================================================
function Write-WizardHeader {
    param([string]$Title, [string]$Step)
    Write-Host ''
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    if ($Step) {
        Write-Host "   STEP $Step - $Title" -ForegroundColor Cyan
    }
    else {
        Write-Host "   $Title" -ForegroundColor Cyan
    }
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-WizardNote {
    param([string]$Text)
    Write-Host "  $Text" -ForegroundColor Gray
}
# endregion

# ============================================================================
# region  Banner
# ============================================================================
Clear-Host
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host '   WhatsUpGoldPS Discovery - First-Time Setup Wizard' -ForegroundColor White
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  This wizard will walk you through:' -ForegroundColor White
Write-Host ''
Write-Host '    1. WhatsUp Gold server connection' -ForegroundColor White
Write-Host '    2. Select discovery providers (cloud + infrastructure)' -ForegroundColor White
Write-Host '    3. Configure targets and credentials for each provider' -ForegroundColor White
Write-Host '    4. Test discovery for each provider' -ForegroundColor White
Write-Host '    5. Schedule recurring discovery tasks' -ForegroundColor White
Write-Host '    6. Schedule dashboard copy to WUG web console' -ForegroundColor White
Write-Host ''
Write-Host '  All credentials are encrypted in a local DPAPI vault.' -ForegroundColor Gray
Write-Host '  You can re-run this wizard at any time to add/change providers.' -ForegroundColor Gray
Write-Host ''
Write-Host '  Press Ctrl+C at any time to exit.' -ForegroundColor DarkGray
Write-Host ''
$null = Read-Host -Prompt '  Press Enter to begin'
# endregion

# ============================================================================
# region  STEP 1 - WUG Server
# ============================================================================
$wugConfigured = $false
$wugServer = $null

if (-not $SkipWUG) {
    Write-WizardHeader -Title 'WhatsUp Gold Server Connection' -Step '1'

    Write-Host '  Do you want to connect to a WhatsUp Gold server?' -ForegroundColor Cyan
    Write-Host '  This enables pushing discovered devices and monitors into WUG.' -ForegroundColor Gray
    Write-Host '  (You can skip this and use dashboards/exports only)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [Y] Yes - configure WUG server connection' -ForegroundColor White
    Write-Host '  [N] No  - discovery-only mode (dashboards, JSON, CSV)' -ForegroundColor White
    Write-Host ''
    $wugChoice = Read-Host -Prompt '  Choice [Y/N, default: Y]'

    if ($wugChoice -notmatch '^[Nn]') {
        # Use the existing vault-backed credential resolver
        $wugResolved = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -ProviderLabel 'WhatsUp Gold'
        if ($wugResolved) {
            $wugConfigured = $true
            # Parse the stored connection to get the server address
            if ($wugResolved -is [hashtable] -and $wugResolved.Server) {
                $wugServer = $wugResolved.Server
            }
            elseif ($wugResolved -is [string] -and $wugResolved -match '\|') {
                $parts = $wugResolved -split '\|'
                $wugServer = $parts[0]
            }
            Write-Host ''
            Write-Host '  WUG server connection configured and saved to vault.' -ForegroundColor Green
        }
        else {
            Write-Host ''
            Write-Host '  WUG server not configured. You can still use dashboards and exports.' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ''
        Write-Host '  Skipped WUG server setup. You can configure it later by running:' -ForegroundColor Yellow
        Write-Host '    Connect-WUGServer' -ForegroundColor Gray
        Write-Host '  or re-running this wizard.' -ForegroundColor Gray
    }
}
else {
    Write-Host ''
    Write-WizardNote 'WUG server setup skipped (-SkipWUG).'
}
# endregion

# ============================================================================
# region  STEP 2 - Provider Selection
# ============================================================================
Write-WizardHeader -Title 'Select Discovery Providers' -Step '2'

Write-Host '  Which platforms do you want to discover?' -ForegroundColor Cyan
Write-Host '  Enter the numbers separated by commas (e.g. 1,4,11)' -ForegroundColor Gray
Write-Host ''

$providerKeys = @($providerDefs.Keys)
for ($i = 0; $i -lt $providerKeys.Count; $i++) {
    $key = $providerKeys[$i]
    $def = $providerDefs[$key]
    $num = '{0,2}' -f ($i + 1)
    Write-Host "  [$num] $($def.Label)" -ForegroundColor White
}
Write-Host ''
Write-Host '  [ A] All providers' -ForegroundColor DarkGray
Write-Host ''

$selInput = Read-Host -Prompt '  Selection'
$selectedProviders = @()

if ($selInput -match '^[Aa]') {
    $selectedProviders = $providerKeys
}
else {
    $nums = $selInput -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    foreach ($n in $nums) {
        if ($n -ge 1 -and $n -le $providerKeys.Count) {
            $selectedProviders += $providerKeys[$n - 1]
        }
    }
}

if ($selectedProviders.Count -eq 0) {
    Write-Host ''
    Write-Host '  No providers selected. Exiting.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host "  Selected $($selectedProviders.Count) provider(s):" -ForegroundColor Green
foreach ($sp in $selectedProviders) {
    Write-Host "    - $($providerDefs[$sp].Label)" -ForegroundColor White
}
# endregion

# ============================================================================
# region  STEP 3 - Per-Provider Configuration
# ============================================================================
Write-WizardHeader -Title 'Configure Providers' -Step '3'

$providerConfigs = @{}

foreach ($provKey in $selectedProviders) {
    $def = $providerDefs[$provKey]

    Write-Host ''
    Write-Host "  --- $($def.Label) ---" -ForegroundColor Cyan
    if ($def.Notes) {
        Write-Host "  $($def.Notes)" -ForegroundColor Gray
    }
    Write-Host ''

    # --- Target ---
    $targetValue = $null
    if ($def.TargetLabel) {
        $prompt = "  $($def.TargetLabel)"
        if ($def.TargetDefault) {
            $prompt += " [default: $($def.TargetDefault)]"
        }
        $targetInput = Read-Host -Prompt $prompt
        if ([string]::IsNullOrWhiteSpace($targetInput)) {
            $targetValue = $def.TargetDefault
        }
        else {
            $targetValue = $targetInput
        }

        if ([string]::IsNullOrWhiteSpace($targetValue) -and $provKey -notin @('Azure', 'OCI')) {
            Write-Host '  No target specified - skipping this provider.' -ForegroundColor Yellow
            continue
        }
    }

    # --- Auth method (Proxmox-style multi-choice) ---
    $authMethod = $null
    $credType = $def.CredType
    if ($def.AuthChoices) {
        Write-Host ''
        Write-Host '  Authentication method:' -ForegroundColor Cyan
        foreach ($ac in $def.AuthChoices) {
            Write-Host "    [$($ac.Key)] $($ac.Label)" -ForegroundColor White
        }
        Write-Host ''
        $authInput = Read-Host -Prompt "  Choice [default: $($def.AuthChoices[0].Key)]"
        if ([string]::IsNullOrWhiteSpace($authInput)) { $authInput = $def.AuthChoices[0].Key }
        $selected = $def.AuthChoices | Where-Object { $_.Key -eq $authInput }
        if ($selected) {
            $authMethod = $selected.Value
            $credType = $selected.CredType
        }
        else {
            $authMethod = $def.AuthChoices[0].Value
            $credType = $def.AuthChoices[0].CredType
        }
    }

    # --- API port ---
    $apiPort = $def.ApiPort
    if ($apiPort) {
        $portInput = Read-Host -Prompt "  API port [default: $apiPort]"
        if ($portInput -match '^\d+$') { $apiPort = [int]$portInput }
    }

    # --- Credentials ---
    $credResolved = $null
    if ($credType) {
        # Build vault name
        $vaultName = $def.CredVault
        if (-not $vaultName) {
            # Dynamic vault name based on first target
            $firstTarget = if ($targetValue -match ',') { ($targetValue -split ',')[0].Trim() } else { $targetValue }
            if ($authMethod -eq 'Token') {
                $vaultName = "$provKey.$firstTarget.Token"
            }
            elseif ($credType -eq 'BearerToken') {
                $vaultName = "$provKey.$firstTarget.Token"
            }
            else {
                $vaultName = "$provKey.$firstTarget.Credential"
            }
        }

        Write-Host ''
        $credSplat = @{
            Name          = $vaultName
            CredType      = $credType
            ProviderLabel = $provKey
        }
        try {
            $credResolved = Resolve-DiscoveryCredential @credSplat
        }
        catch {
            Write-Host "  Error resolving credential for ${provKey}: $_" -ForegroundColor Red
            Write-Host "  Skipping $provKey." -ForegroundColor Yellow
            continue
        }
        if (-not $credResolved) {
            Write-Host "  Credential not provided - skipping $provKey." -ForegroundColor Yellow
            continue
        }
        Write-Host ''
    }

    # Store config
    $providerConfigs[$provKey] = @{
        Target     = $targetValue
        AuthMethod = $authMethod
        ApiPort    = $apiPort
        CredType   = $credType
        Credential = $credResolved
        Script     = Join-Path $scriptDir $def.Script
    }

    Write-Host "  $provKey configured." -ForegroundColor Green
}

if ($providerConfigs.Count -eq 0) {
    Write-Host ''
    Write-Host '  No providers were fully configured. Exiting.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host "  $($providerConfigs.Count) provider(s) configured successfully." -ForegroundColor Green
# endregion

# ============================================================================
# region  STEP 4 - Test Discovery
# ============================================================================
if (-not $SkipTest) {
    Write-WizardHeader -Title 'Test Discovery Run' -Step '4'

    Write-Host '  Run a test discovery for each configured provider?' -ForegroundColor Cyan
    Write-Host '  This verifies connectivity and credentials are working.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [Y] Yes - run test discovery (recommended)' -ForegroundColor White
    Write-Host '  [N] No  - skip testing' -ForegroundColor White
    Write-Host ''
    $testChoice = Read-Host -Prompt '  Choice [Y/N, default: Y]'

    if ($testChoice -notmatch '^[Nn]') {
        foreach ($provKey in $providerConfigs.Keys) {
            $cfg = $providerConfigs[$provKey]
            Write-Host ''
            Write-Host "  Testing $provKey..." -ForegroundColor Cyan

            try {
                $runArgs = @{
                    Action     = 'Dashboard'
                    OutputPath = $OutputPath
                }
                # SNMP-based providers handle their own credential prompts during first run
                # and save to vault. Other providers already have creds resolved.
                $snmpProviders = @('CUCM', 'CiscoWLC')
                if ($provKey -notin $snmpProviders) {
                    $runArgs['NonInteractive'] = $true
                }

                # Add target
                $targetParam = $providerDefs[$provKey].TargetParam
                if ($targetParam -and $cfg.Target) {
                    if ($cfg.Target -match ',') {
                        $runArgs[$targetParam] = ($cfg.Target -split ',' | ForEach-Object { $_.Trim() })
                    }
                    else {
                        $runArgs[$targetParam] = $cfg.Target
                    }
                }

                # Add auth method (SNMP providers use -SnmpVersion instead of -AuthMethod)
                if ($cfg.AuthMethod) {
                    if ($provKey -in $snmpProviders) {
                        switch ($cfg.AuthMethod) {
                            'SnmpV2' { $runArgs['SnmpVersion'] = 2 }
                            'SnmpV3' { $runArgs['SnmpVersion'] = 3 }
                        }
                    }
                    else {
                        $runArgs['AuthMethod'] = $cfg.AuthMethod
                    }
                }

                # Add API port (CUCM doesn't use this - SnmpPort is defaulted internally)
                if ($cfg.ApiPort) {
                    $runArgs['ApiPort'] = $cfg.ApiPort
                }

                # Extract TenantId for Azure (stored in PSCredential UserName as "TenantId|AppId")
                if ($provKey -eq 'Azure' -and $cfg.Credential -is [PSCredential]) {
                    $azParts = $cfg.Credential.UserName -split '\|', 2
                    if ($azParts.Count -ge 1 -and $azParts[0]) {
                        $runArgs['TenantId'] = $azParts[0]
                    }
                }

                & $cfg.Script @runArgs

                Write-Host "  $provKey - test passed." -ForegroundColor Green
                $providerConfigs[$provKey]['TestPassed'] = $true
            }
            catch {
                Write-Host "  $provKey - test FAILED: $_" -ForegroundColor Red
                $providerConfigs[$provKey]['TestPassed'] = $false
            }
        }

        # Summary
        Write-Host ''
        Write-Host '  Test Results:' -ForegroundColor Cyan
        foreach ($provKey in $providerConfigs.Keys) {
            $status = if ($providerConfigs[$provKey]['TestPassed']) { 'PASS' } else { 'FAIL' }
            $color  = if ($providerConfigs[$provKey]['TestPassed']) { 'Green' } else { 'Red' }
            Write-Host "    $provKey : $status" -ForegroundColor $color
        }
    }
    else {
        Write-Host '  Skipped test discovery.' -ForegroundColor DarkGray
    }
}
else {
    Write-WizardNote 'Test discovery skipped (-SkipTest).'
}
# endregion

# ============================================================================
# region  STEP 5 - Schedule Discovery Tasks
# ============================================================================
if (-not $SkipSchedule) {
    Write-WizardHeader -Title 'Schedule Recurring Discovery' -Step '5'

    Write-Host '  Do you want to schedule automatic recurring discovery?' -ForegroundColor Cyan
    Write-Host '  This creates Windows Scheduled Tasks that run discovery' -ForegroundColor Gray
    Write-Host '  on a schedule using your saved vault credentials.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [Y] Yes - schedule tasks' -ForegroundColor White
    Write-Host '  [N] No  - skip scheduling (run manually)' -ForegroundColor White
    Write-Host ''
    $schedChoice = Read-Host -Prompt '  Choice [Y/N, default: N]'

    if ($schedChoice -match '^[Yy]') {
        # Check if running as Administrator (required for Register-ScheduledTask)
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
        if (-not $isAdmin) {
            Write-Host ''
            Write-Host '  NOTE: A UAC elevation prompt will appear to register the tasks.' -ForegroundColor Yellow
        }

        # Choose action for scheduled runs
        Write-Host ''
        Write-Host '  What should scheduled discovery do?' -ForegroundColor Cyan
        Write-Host '  [1] Push to WUG (create/update devices + monitors)' -ForegroundColor White
        Write-Host '  [2] Generate dashboards only' -ForegroundColor White
        Write-Host '  [3] Dashboard + Push to WUG' -ForegroundColor White
        Write-Host '  [4] Export JSON' -ForegroundColor White
        Write-Host ''
        $actionChoice = Read-Host -Prompt '  Choice [1-4, default: 3]'
        $schedAction = switch ($actionChoice) {
            '1' { 'PushToWUG' }
            '2' { 'Dashboard' }
            '4' { 'ExportJSON' }
            default { 'DashboardAndPush' }
        }

        # Choose frequency
        Write-Host ''
        Write-Host '  How often should discovery run?' -ForegroundColor Cyan
        Write-Host '  [1] Every hour' -ForegroundColor White
        Write-Host '  [2] Every 2 hours' -ForegroundColor White
        Write-Host '  [3] Every 4 hours' -ForegroundColor White
        Write-Host '  [4] Daily at a set time' -ForegroundColor White
        Write-Host ''
        $freqChoice = Read-Host -Prompt '  Choice [1-4, default: 2]'

        $schedTrigger = 'Hourly'
        $schedInterval = 120
        $schedTime = '02:00'

        switch ($freqChoice) {
            '1' { $schedInterval = 60 }
            '3' { $schedInterval = 240 }
            '4' {
                $schedTrigger = 'Daily'
                $timeInput = Read-Host -Prompt '  Time of day (HH:mm) [default: 02:00]'
                if ($timeInput -match '^\d{1,2}:\d{2}$') { $schedTime = $timeInput }
            }
            default { $schedInterval = 120 }
        }

        # Register task for each provider
        $regScript = Join-Path $scriptDir 'Register-DiscoveryScheduledTask.ps1'

        if (-not (Test-Path $regScript)) {
            Write-Host "  Register-DiscoveryScheduledTask.ps1 not found. Skipping." -ForegroundColor Yellow
        }
        else {
            if ($isAdmin) {
                # Already elevated — register directly
                foreach ($provKey in $providerConfigs.Keys) {
                    $cfg = $providerConfigs[$provKey]
                    Write-Host ''
                    Write-Host "  Registering scheduled task for $provKey..." -ForegroundColor Cyan

                    try {
                        $regArgs = @{
                            Mode        = 'Provider'
                            Provider    = $provKey
                            Action      = $schedAction
                            TriggerType = $schedTrigger
                            OutputPath  = $OutputPath
                        }
                        if ($VaultScope -eq 'LocalMachine') {
                            $regArgs['UseSystemVault']    = $true
                            $regArgs['SkipVaultPopulate'] = $true
                        }
                        if ($cfg.Target) {
                            if ($cfg.Target -match ',') {
                                $regArgs['Target'] = ($cfg.Target -split ',' | ForEach-Object { $_.Trim() })
                            }
                            else {
                                $regArgs['Target'] = @($cfg.Target)
                            }
                        }
                        if ($cfg.AuthMethod) {
                            $regArgs['AuthMethod'] = $cfg.AuthMethod
                        }
                        if ($wugServer) {
                            $regArgs['WUGServer'] = $wugServer
                        }
                        if ($schedTrigger -eq 'Hourly') {
                            $regArgs['RepeatIntervalMinutes'] = $schedInterval
                        }
                        else {
                            $regArgs['TimeOfDay'] = $schedTime
                        }

                        & $regScript @regArgs
                        Write-Host "  $provKey - task registered." -ForegroundColor Green
                    }
                    catch {
                        Write-Host "  $provKey - failed to register task: $_" -ForegroundColor Red
                    }
                }
            }
            else {
                # Not elevated — build temporary script and self-elevate via UAC
                Write-Host ''
                Write-Host '  Launching elevated prompt to register tasks...' -ForegroundColor Cyan

                $tempScript = Join-Path $env:TEMP "DiscoverySyncRegister_$(Get-Date -Format yyyyMMdd_HHmmss).ps1"
                $sl = [System.Collections.Generic.List[string]]::new()
                [void]$sl.Add('# Elevated scheduled task registration')
                [void]$sl.Add("`$ErrorActionPreference = 'Stop'")
                [void]$sl.Add("`$regScript = '$($regScript -replace "'","''")'")
                [void]$sl.Add('')

                foreach ($provKey in $providerConfigs.Keys) {
                    $cfg = $providerConfigs[$provKey]
                    [void]$sl.Add("Write-Host '  Registering $provKey...' -ForegroundColor Cyan")
                    [void]$sl.Add('try {')
                    [void]$sl.Add("    `$a = @{")
                    [void]$sl.Add("        Mode        = 'Provider'")
                    [void]$sl.Add("        Provider    = '$provKey'")
                    [void]$sl.Add("        Action      = '$schedAction'")
                    [void]$sl.Add("        TriggerType = '$schedTrigger'")
                    [void]$sl.Add("        OutputPath  = '$($OutputPath -replace "'","''")'")
                    [void]$sl.Add('    }')
                    if ($cfg.Target) {
                        if ($cfg.Target -match ',') {
                            $tArr = ($cfg.Target -split ',' | ForEach-Object { "'$($_.Trim())'" }) -join ', '
                            [void]$sl.Add("    `$a['Target'] = @($tArr)")
                        }
                        else {
                            [void]$sl.Add("    `$a['Target'] = @('$($cfg.Target)')")
                        }
                    }
                    if ($cfg.AuthMethod) {
                        [void]$sl.Add("    `$a['AuthMethod'] = '$($cfg.AuthMethod)'")
                    }
                    if ($wugServer) {
                        [void]$sl.Add("    `$a['WUGServer'] = '$wugServer'")
                    }
                    if ($schedTrigger -eq 'Hourly') {
                        [void]$sl.Add("    `$a['RepeatIntervalMinutes'] = $schedInterval")
                    }
                    else {
                        [void]$sl.Add("    `$a['TimeOfDay'] = '$schedTime'")
                    }
                    [void]$sl.Add('    & $regScript @a')
                    [void]$sl.Add("    Write-Host '  $provKey - task registered.' -ForegroundColor Green")
                    [void]$sl.Add('} catch {')
                    [void]$sl.Add("    Write-Host `"  $provKey - FAILED: `$_`" -ForegroundColor Red")
                    [void]$sl.Add('}')
                    [void]$sl.Add('')
                }

                [void]$sl.Add("Write-Host ''")
                [void]$sl.Add("Write-Host '  Press Enter to close...' -ForegroundColor Gray")
                [void]$sl.Add('Read-Host')

                ($sl -join "`r`n") | Set-Content -Path $tempScript -Encoding UTF8

                try {
                    Start-Process powershell -Verb RunAs -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tempScript
                    ) -Wait
                    Write-Host '  Elevated registration complete.' -ForegroundColor Green
                }
                catch {
                    Write-Host "  Failed to launch elevated prompt: $_" -ForegroundColor Red
                    Write-Host '  Run this wizard as Administrator to register tasks.' -ForegroundColor Yellow
                }
                finally {
                    Remove-Item $tempScript -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        Write-Host '  Skipped scheduling. You can schedule later with:' -ForegroundColor DarkGray
        Write-Host '    .\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider <name> ...' -ForegroundColor Gray
    }
}
else {
    Write-WizardNote 'Scheduling skipped (-SkipSchedule).'
}
# endregion

# ============================================================================
# region  STEP 6 - Dashboard Copy Task
# ============================================================================
if (-not $SkipSchedule) {
    Write-WizardHeader -Title 'Dashboard Copy to WUG Web Console' -Step '6'

    Write-Host '  Do you want to automatically copy dashboard HTML files' -ForegroundColor Cyan
    Write-Host '  to the WUG web console so they are accessible via browser?' -ForegroundColor Gray
    Write-Host '  (e.g. https://wugserver/NmConsole/dashboards/Proxmox-Dashboard.html)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [Y] Yes - schedule dashboard copy' -ForegroundColor White
    Write-Host '  [N] No  - skip' -ForegroundColor White
    Write-Host ''
    $dashChoice = Read-Host -Prompt '  Choice [Y/N, default: Y]'

    if ($dashChoice -notmatch '^[Nn]') {
        $copyScript = Join-Path $scriptDir 'Copy-WUGDashboardReports.ps1'

        if (-not (Test-Path $copyScript)) {
            Write-Host '  Copy-WUGDashboardReports.ps1 not found. Skipping.' -ForegroundColor Yellow
        }
        else {
            # Detect or ask for NmConsole path
            $nmCandidates = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmPath = $nmCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

            if (-not $nmPath) {
                Write-Host '  WUG NmConsole directory not found at default locations.' -ForegroundColor Yellow
                $nmInput = Read-Host -Prompt '  Enter the NmConsole path (or press Enter to use default)'
                if ($nmInput) {
                    $nmPath = $nmInput
                }
                else {
                    $nmPath = "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                }
            }

            Write-Host "  Destination: $nmPath" -ForegroundColor White
            Write-Host ''

            # Check if running as Administrator
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )

            if ($isAdmin) {
                try {
                    $copyArgs = @{
                        Register    = $true
                        SourcePath  = $OutputPath
                        Destination = $nmPath
                    }
                    & $copyScript @copyArgs
                    Write-Host '  Dashboard copy task registered.' -ForegroundColor Green
                }
                catch {
                    Write-Host "  Failed to register dashboard copy task: $_" -ForegroundColor Red
                }
            }
            else {
                Write-Host '  Launching elevated prompt to register copy task...' -ForegroundColor Yellow

                $tempScript = Join-Path $env:TEMP "DashboardCopyRegister_$(Get-Date -Format yyyyMMdd_HHmmss).ps1"
                $cmd = @(
                    "`$copyScript = '$($copyScript -replace "'","''")'",
                    'try {',
                    "    & `$copyScript -Register -SourcePath '$($OutputPath -replace "'","''")' -Destination '$($nmPath -replace "'","''")'",
                    "    Write-Host '  Dashboard copy task registered.' -ForegroundColor Green",
                    '} catch {',
                    "    Write-Host `"  FAILED: `$_`" -ForegroundColor Red",
                    '}',
                    "Write-Host ''",
                    "Write-Host '  Press Enter to close...' -ForegroundColor Gray",
                    'Read-Host'
                ) -join "`r`n"
                $cmd | Set-Content -Path $tempScript -Encoding UTF8

                try {
                    Start-Process powershell -Verb RunAs -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tempScript
                    ) -Wait
                    Write-Host '  Elevated registration complete.' -ForegroundColor Green
                }
                catch {
                    Write-Host "  Failed to launch elevated prompt: $_" -ForegroundColor Red
                    Write-Host "  Manual: .\Copy-WUGDashboardReports.ps1 -SourcePath '$OutputPath' -Destination '$nmPath'" -ForegroundColor Gray
                }
                finally {
                    Remove-Item $tempScript -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        Write-Host '  Skipped dashboard copy scheduling.' -ForegroundColor DarkGray
        Write-Host "  Manual: .\Copy-WUGDashboardReports.ps1" -ForegroundColor Gray
    }
}
# endregion

# ============================================================================
# region  Summary
# ============================================================================
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host '   Setup Complete!' -ForegroundColor Green
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host ''

if ($wugConfigured) {
    Write-Host '  WUG Server     : Configured (saved in vault)' -ForegroundColor Green
}
else {
    Write-Host '  WUG Server     : Not configured (discovery-only mode)' -ForegroundColor Yellow
}

Write-Host "  Providers      : $($providerConfigs.Count) configured" -ForegroundColor White
foreach ($provKey in $providerConfigs.Keys) {
    $testLabel = ''
    if ($providerConfigs[$provKey].ContainsKey('TestPassed')) {
        $testLabel = if ($providerConfigs[$provKey]['TestPassed']) { ' (tested OK)' } else { ' (test failed)' }
    }
    Write-Host "    - $provKey$testLabel" -ForegroundColor White
}

Write-Host "  Output dir     : $OutputPath" -ForegroundColor White
Write-Host "  Credential vault: $env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Vault" -ForegroundColor White
Write-Host ''
Write-Host '  What to do next:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Run a single provider:' -ForegroundColor White
Write-Host '    .\Setup-Proxmox-Discovery.ps1 -Target 192.168.1.30 -Action Dashboard' -ForegroundColor Gray
Write-Host ''
Write-Host '  Run non-interactively (uses vault creds):' -ForegroundColor White
Write-Host '    .\Setup-Proxmox-Discovery.ps1 -Target 192.168.1.30 -Action PushToWUG -NonInteractive' -ForegroundColor Gray
Write-Host ''
Write-Host '  View scheduled tasks:' -ForegroundColor White
Write-Host '    .\Register-DiscoveryScheduledTask.ps1 -Show' -ForegroundColor Gray
Write-Host ''
Write-Host '  Copy dashboards manually:' -ForegroundColor White
Write-Host '    .\Copy-WUGDashboardReports.ps1' -ForegroundColor Gray
Write-Host ''
Write-Host '  Re-run this wizard:' -ForegroundColor White
Write-Host '    .\Start-WUGDiscoverySetup.ps1' -ForegroundColor Gray
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host ''
# endregion

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUHifeEZufb4OMi3Us8aPtixrZ
# 5RyggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG
# 9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkw
# FwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1
# cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBi
# MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
# d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3Qg
# RzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAi
# MGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnny
# yhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE
# 5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm
# 7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5
# w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsD
# dV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1Z
# XUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS0
# 0mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hk
# pjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m8
# 00ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+i
# sX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB
# /zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReui
# r/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0w
# azAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUF
# BzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVk
# SURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAG
# BgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9
# mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxS
# A8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/
# 6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSM
# b++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt
# 9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGGjCC
# BAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG9w0BAQwFADBWMQswCQYD
# VQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0
# aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAw
# WhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcg
# Q0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAmyudU/o1P45g
# BkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxDeEDIArCS2VCoVk4Y/8j6
# stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk9vT0k2oWJMJjL9G//N52
# 3hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7XwiunD7mBxNtecM6ytIdUl
# h08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ0arWZVeffvMr/iiIROSC
# zKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZXnYvZQgWx/SXiJDRSAolR
# zZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+tAfiWu01TPhCr9VrkxsHC
# 5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvrn35XGf2RPaNTO2uSZ6n9
# otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn3UayWW9bAgMBAAGjggFk
# MIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaRXBeF5jAdBgNVHQ4EFgQU
# DyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYDVR0gBBQwEjAGBgRVHSAA
# MAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRwOi8vY3JsLnNlY3RpZ28u
# Y29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYuY3JsMHsGCCsGAQUF
# BwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0
# aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAjBggrBgEFBQcwAYYXaHR0
# cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBAAb/guF3YzZu
# e6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXKZDk8+Y1LoNqHrp22AKMG
# xQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWkvfPkKaAQsiqaT9DnMWBH
# VNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3dMapandPfYgoZ8iDL2OR3
# sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwFkvjFV3jS49ZSc4lShKK6
# BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZaPATHvNIzt+z1PHo35D/f
# 7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8bkinLrYrKpii+Tk7pwL7T
# jRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7EwoIJB0kak6pSzEu4I64U6
# gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TWSenLbjBQUGR96cFr6lEU
# fAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg51Tbnio1lB93079WPFnY
# aOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoUKD85gnJ+t0smrWrb8dee
# 2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGPjCCBKagAwIBAgIQB5zg5NEUf4XN
# OXPPdi036zANBgkqhkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP
# U2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNp
# Z25pbmcgQ0EgUjM2MB4XDTI2MDIwOTAwMDAwMFoXDTI5MDQyMTIzNTk1OVowVTEL
# MAkGA1UEBhMCVVMxFDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNv
# biBBbGJlcmlubzEXMBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDzemjeAdcmFpCOW+UwY9yNFVf6XhE6x2+hGOAR
# xsbfAKfnk/lqRKSchLUWD8RJjSS9wN/AZIO5sMzxN/9TSue9GQQrgY0gJ+JkgyIC
# Ll2Z78gTvVtTkLOXeuzJSS1ABLn5dfLTq90k9Q3jvYEo0EgBOTapdEA8T55vdzmQ
# aJ/hc9wphPs9zMAHtoeCnbUQJwqsDPv1e4gXW8PiTsaJacfu0VYxsj66ExDSBt6X
# v4Srz2+dNZX/LgQAAy3Y2a+YqfLyFm3/Oe2MNQbtdJ1SOx1t3hPApef/3da4mx5c
# 080C37bVvpPg2hbCmQQS+epeGAJSFUbKzohNZHR2GMeiBqxAPNPUe/k2QPQ8xqsh
# Yr/apiQGy+Hw8HrQ3siKvjs7c9S7xHcvEXHdCQWPieEtHgxBSAN19DfFXC3gMGmy
# m/QI7pSl8FHqgiS7ze/QifdFE2W9viPrWpo9HZ/iCjBLCeL+BoMe9rMRa/ful84q
# HbU4OS7n9sXevj4YWpjsRdqcfSzm4QSyxDMkbAh2SM1WThSrvQaR0B+7nxgfkmvN
# E5YtP+ixMp/fmzGFotrbZ+pSzj04VzIkGqKEVKuqtrt/heEmj5cVRSyOziVTIWq+
# p1uo6AbxC0yT5gDUjIw0kRQ3x0QnRm2bC/5HhCyTcvo2XLRelb8UBIxTPP22s7uq
# mIawOwIDAQABo4IBiTCCAYUwHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhek
# zQwwHQYDVR0OBBYEFOmBdKNA+QFYSh21aHK/BmkiAYmwMA4GA1UdDwEB/wQEAwIH
# gDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEw
# NQYMKwYBBAGyMQECAQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5j
# b20vQ1BTMAgGBmeBDAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNl
# Y3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5Bggr
# BgEFBQcBAQRtMGswRAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdo
# dHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAYEABCLJuMZz
# nf7WTFaysIt3aAF7wsDgP0WEJxSQ+0f20kEbt8FxCuKPUiHn8ntfAf6uH4QZITQC
# bhL00ABn6m26caMNNyeT6w06dVjwlm1yl/Ds/bxliRcicURn7ZHc2eeyRNNLMpxD
# EvFwsCzvT99jMkfWfVEa6Yizyfa0I3xzG9QVHb2jWsqJpu2liwJw/l+45uqPLDU+
# QJ9XMBAKG+6G1gzOrF/d8KYcCTQSQLLR/Ts7Oi8CEjl+rCkuwipvTdyqfITlLntG
# RwLWXRZeqObtdsMvs84nhhCOdHypze+xXzShTlipUujicJQK3GxXoAeSvPS3BOYj
# UpmjN1TAdgA1dRRHIxkh8OJU4NVsfljADHZf+5273xcSfbrubTYk+eAdLPpWTvx8
# 7cF2EFHM3bBaJ96Y7Da7JPWZWpQYuUh5CLvheoO7VohL967VQKZiUZy5FK9l6tmu
# J27JVAreIyrOVF+FdZ0l/DjPvgF6MlRjvok4+8/qZelxPRsP03eliiirMIIGtDCC
# BJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcN
# MjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQg
# RzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URed
# Ta2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW
# 2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH
# ++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7
# RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBY
# qHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk8
# 1coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqU
# JfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3h
# j0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW/
# /1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyO
# Di7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIsp
# zOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
# BBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8u
# Zz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3
# BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDov
# L2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4IC
# AQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXj
# DNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoa
# lhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQY
# K9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId
# +ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQC
# qjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yo
# sn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ
# 1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk
# 43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEd
# mcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjl
# gp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQIC
# EAhP3DNPfkVO28MPj/mSGDUwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0y
# NjA4MDUwMDAwMDBaFw0zNzExMDQyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJT
# QTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI2IDEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC2e6byyf7NSvjUm0xls/04xjD4fAkOkbnGQi7+Wpx8
# 1iYxfzViaxSIctuH3KSl5YEYpMuFgGsA31N2D9ATMbfZdw5uaAhuWevQKhDdZIB4
# NnqcfpfpWQXJiQnDdAElETC+bhSEvNLGbA8DtwUpFMQ4yyYQSPqomT92osQAv6hB
# i47ATZS6JfVWe6XxhF4jJZ3iSAuf2Cros1czRSmWRHqMv9AfGZvp8ygYElhudpQj
# tcPpwoOl6QrZJUyV3iINvN4cO05prGV0fkjG426xDr2d3z9lcSIHkdvGPdGUrXdx
# fVbgOUVcp2/8ISEzwKPW++Wa+E2ujI91EZtukGWDJ/xZ27k3oHKEXBRGfRTqjOU+
# jE3ba/5++JSE/7oNHnjs5mekExYN96LV/mxUbCKJb8pBNY4r3uD7hEmk/M81XhVg
# wDA7aMzYC3LZBg9WY5BMmbSay5ecmtJuXaB/0nKWmQmVZeqTVDgsmzHP5MQuhAJk
# iWNuC9MmCg9TZHXbJ2/yLVSov9p16UDTLtT0+aa1vN71fHeu1qMLlLNB3WOB/ADC
# xr3S/1hxI92Z6jKgEED/btwIvbfuXkNNhg8MtDg43c4tMZae9FvqMOt/9PvmAxF9
# TNIsIFB8G6yb36ZJZGUL8N/pL971DyLXcK6HM5PYnH5X+eVtczhCgHCVQCF6XDAl
# PQIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUFMljijAu1Er7
# bpTz5uNAfvXszeIwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYD
# VR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcB
# AQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0G
# CCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYD
# VR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAjcU6YR6dUgrfmawJgH59KECxa9Ji8sEi2g10CBDaMiqsaxWyW5cwlT/6ZF5s
# FznazqVsoC85U9dqLOYqQwst+UQQoNlDHgKRLa3xoc+OReFreFhnTXSG0Vrd2E2C
# ZqUfm+5a+He1MJ/h+tNLuA+0Zzhn/Fo+FDYAHWZHx4R79ZsfRFYe9UiXpXBDf6Dk
# Uo183Y38NYmR/XfDYf7YZ+oR9t3flbDwK+hgGMs0gNNp1w9Z2CyOyI5or/sSwomA
# uNQ0hWC9xoU4stD8aWsD7RkcmgVRs6vlIk3zPKQ+ylcheWkMlj+CoVRlFE55pv0Z
# WCaFt04lwP/rdGHE9qEVQZtyRE42ox7oNgC/r+Y4bSlZ3dw9K2x1xLtu6PkPKeLB
# FjzKigwfqm3Hm+k/+lnME8F5kPZTgiy2HLEHklpryqs6QHnPXrRNeIzkAMyylnRN
# 8P0wmirS0WkU+ywpEWFZ4QNg+9xS43tTuW9x0eXh7NDc1P/sV+zWxHXKH8tFt1nc
# HdVzqrZaYPyYMLSn2TOXajveJW1L3joiQSPsWRGxkbDDW15jERFE4LvjnGu2O9zD
# 1nLJSMdlYZEikl4w2w+q4IN/R+TIe0H4ngCI1moJCTbevGH4punIxM1Uoi0nmX3Z
# K+XbRT01uowE5ViXWHng0RgsmrX/EdYUo80r3TfMlkD0/YMxggYzMIIGLwIBATBo
# MFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNV
# BAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+F
# zTlzz3YtN+swCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFBl+QmEDwFPESdKMcVvwepIPqZNQMA0G
# CSqGSIb3DQEBAQUABIICACRHczBQH7PpL1nj0IA9w4RNG7I4lKFKw7hX9qi430UZ
# C35vEtMsM8FN5it3DrbLvmOW3bYwF8x7fzJ+e0sW/kmUIh2Yiyv6CAUUqGdnnI7w
# Rl5dzPG6+XeAM25JQZOfonN7eMlZB3GRFGILiEm8zB1MoXZVanbky79briNvwQG8
# SXeb/J40FodDVkxLMmEFf+jZtUVc00ZXdEJQf2nVM+KEiQg+gCg5zlc5hjuRUGmx
# Tm/hG/XT43Ij3pux99038kW74Dm50EEGJSp4Sx5ZR0mNhXrNN2CFLdZnHNF4SPad
# TrEtYIpfvFHzc8eMrRSk0BZOq7GGup/GJkPwZ6xoYr0JTAF9fMmeyleEg7FruT5Z
# te6Mxd1qm/wT4x0U69jUYOw8n2A2Q4EYen4MmQpRKbG0nGn+/wxkUWxXEpQ1bN1z
# JtDQU3LlDGxnF9D2QifZPgXG5Z+IGYFfn/IW/961/BHLrukN9dJuO3k+tF1qc6L9
# wPnEo9HAB+CFfMfNrPex+sMZ62qH31TjLIAS1XURORuIXv3Oea6c88UT2phlKnN6
# 3eRx0QFpisQUuvrgd/DwdzkAFijLO+aQQWzsLorMfEG6gG6szC+xW29j7VobUjTA
# ewUvrUcuodbBHyfJEz1U/bkE6fGRbPaCOyFgPHfxHXeijquCi9NglUFdji6xaTyb
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDIxMlowLwYJKoZIhvcN
# AQkEMSIEIJ9Z6LTYJRGerectNGbei3oHbgdgpspvwR6iEejnNwaUMA0GCSqGSIb3
# DQEBAQUABIICAAmAYpg0U/MXGM+2F1jPvtnIekwYvJjIGVSMEVu6Jls/RMRaoZi/
# 2Fw+bbCDi8Rvmk4WvrSw0+zZBrVafhEldlWN1OL9bFH5SJ41GGCkSw2hryoorRYF
# QcNI2ECWUCGkq6rAvVusrjY5cnszna6PuHKRlOy5HWqNt7LXAIb3ZiuyqF5WEtY7
# lTkw6TmwhbW8YG1RqAF2C8Xkz7t86k80ulX+69YwWWsrzpwkklhMWRzhqOiX/i8k
# f/ItMircJMlfeC3ewyB7KVjFoIiYtjryzR6EnhKr5/DaWanT/WeU63o4aPStzhSl
# U9rmg0XmLWLd/UPPhSRysYKKBtfq1h5iC0z5Tb5Pfx4pouMXPEehqCR+mwkWcyHd
# Q6Vrpvq6zuR7roPVc+ICJlwFTtOE+I8kJ2QW1CcJ+vKb7MK9XgOToqAQLm58JMNK
# 5dfJbfmTFI49ooTUOYVUXdyo3QRbdCA4hG4Q6ryr8Ck98qfAOIB1HqnIrKuOyf32
# 45ZvyL+rCoe8xWRZwPvvH7L7ZVP+0ul0sirkeZ1pvsnnhqAr+UjLIo6lsYz01av1
# yBuvIaJzdGx/enxTmYu44Qd0YuDa6xKj2GlUdp6CdC3JQftKSyEBte63tKLekAug
# EcMDqrnTqUoU78oY7NvsJlvnnI7/B2OoBstHLJli0Wrt+QnCZ3Dc1Ito
# SIG # End signature block
