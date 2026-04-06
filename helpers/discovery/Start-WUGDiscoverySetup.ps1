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
    Default: $env:LOCALAPPDATA\DiscoveryHelpers\Output

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
    [string]$OutputPath
)

# ============================================================================
# region  Init
# ============================================================================
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent

# Dot-source shared helpers
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
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
        CredVault   = 'Azure.Credential'
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
    GCP      = @{
        Label       = 'Google Cloud Platform (GCP)'
        Script      = 'Setup-GCP-Discovery.ps1'
        TargetLabel = 'GCP project ID(s) (comma-separated)'
        TargetDefault = ''
        TargetParam = 'Target'
        CredType    = 'FilePath'
        CredVault   = 'GCP.KeyFile'
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
    OCI      = @{
        Label       = 'Oracle Cloud Infrastructure (OCI)'
        Script      = 'Setup-OCI-Discovery.ps1'
        TargetLabel = 'OCI tenancy OCID (or blank to use config file)'
        TargetDefault = ''
        TargetParam = 'TenancyId'
        CredType    = 'FilePath'
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
        $credResolved = Resolve-DiscoveryCredential @credSplat
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
                    Action         = 'Dashboard'
                    OutputPath     = $OutputPath
                    NonInteractive = $true
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

                # Add auth method
                if ($cfg.AuthMethod) {
                    $runArgs['AuthMethod'] = $cfg.AuthMethod
                }

                # Add API port
                if ($cfg.ApiPort) {
                    $runArgs['ApiPort'] = $cfg.ApiPort
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
                    Write-Host '  You may need to run as Administrator.' -ForegroundColor Yellow
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
    Write-Host '  (e.g. https://wugserver/NmConsole/Proxmox-Dashboard.html)' -ForegroundColor Gray
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

            try {
                $copyArgs = @{
                    Register   = $true
                    SourcePath = $OutputPath
                    Destination = $nmPath
                }
                & $copyScript @copyArgs
                Write-Host '  Dashboard copy task registered.' -ForegroundColor Green
            }
            catch {
                Write-Host "  Failed to register dashboard copy task: $_" -ForegroundColor Red
                Write-Host '  You may need to run as Administrator.' -ForegroundColor Yellow
                Write-Host "  Manual: .\Copy-WUGDashboardReports.ps1 -SourcePath '$OutputPath' -Destination '$nmPath'" -ForegroundColor Gray
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
Write-Host "  Credential vault: $env:LOCALAPPDATA\DiscoveryHelpers\Vault" -ForegroundColor White
Write-Host ''
Write-Host '  What to do next:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Run a single provider:' -ForegroundColor White
Write-Host '    .\Setup-Proxmox-Discovery.ps1 -Target 192.168.1.39 -Action Dashboard' -ForegroundColor Gray
Write-Host ''
Write-Host '  Run non-interactively (uses vault creds):' -ForegroundColor White
Write-Host '    .\Setup-Proxmox-Discovery.ps1 -Target 192.168.1.39 -Action PushToWUG -NonInteractive' -ForegroundColor Gray
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDzWVIpFF1epGl8
# sJl7NkJMqaZh7fJbis+sKEVmlX+d7qCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgd3iUh8N+an33JsHHzUaBwoaEkdaG3UFg
# 4jK+m9Rug74wDQYJKoZIhvcNAQEBBQAEggIAFiyy28cVV6bzWauqkiHr/7Qqkufk
# 7lsc6d2alG0dhZLqDJ+PJOjdK4+zLKuoGAMdZRy8N3rXWVrUipWJf/44YQsUgFEr
# Ny6RvmPUIc/Grou9KClMUQxSm91qYTXCTGHjhHAvgk/RbkZ+3X8lqvpKBj+/gVvq
# IFdXQ2DDPKycANho5LGbQmD+TqEJGMzF3Qx3MphY7Hl+E8ifQ6vLaIhNDpdHRUd/
# lso9UaZTH9dS101ulOlDiI86ygLQtXGojXJxMlvJ7bah6jymD1PGi/QZ7/domiwf
# F+E/R1cWDfe9AGtc/lSKy6DnHO1gqZTzPd+3jfFE0m6zvOoFQ+QGgl6cX6wUl0dd
# IgzkCSsOHW3CcAKZV4DQ+fC5khtcBHuMAJapXj8V9WQ/LXzCLJLX5m4UMniEQxSw
# zOAL0rPsmD9i25Vwu0gQ/1Y5OOhEfUw2+zHC85eCmn+i+eKx9B7ym6ZxH4Qq16Pn
# REXsSbMHYQskF1IMnG8vsGfj3E3eyuM/BSJIcz9xd8EepKzndsTUpSMnXR3F6pvs
# Dtyu6E6hVb73vkTOuTZBUiAyBG4IgLq2A+YOrW1lLsuv5s+tzTl4CsHF8Hg554hu
# UXOHh9yfYpX+QpQ6qrDtlEEzyMjO4ATQnXXr6Acd4ZJHoTmTbJ+S9snNp9MCw84K
# bMC4XOteYA3rl+Y=
# SIG # End signature block
