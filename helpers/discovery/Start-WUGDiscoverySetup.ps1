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
    $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
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
Write-Host "  Credential vault: $env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Vault" -ForegroundColor White
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB4Y1o/Yc9pwisK
# B++ydE293ENsQCQm5CRH9TR/ykaBn6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAnG/8t7+sDTMggVlJDOY2xcs4gy+AHZmBuwQRdsXlCZTANBgkqhkiG9w0BAQEF
# AASCAgDtCxi84Stikg3iokGyKLH06atP4mrwqn8x9NER2KK0GuFiNSTfhfgt2xPK
# I980R06slRj3uBiVJy4YAc/KFc+AcHZoJYskNra98sqsiBuNSKvDOQ4kMrToJwe5
# YnwFPWJ2P4y671yuSnNJFSoss1hes4XfCmHQL4km0l3uEoBNxjkXoOuyT7no9q6q
# 7NiMm8gS94SsJurQZWq6iWyk9o3rrDshW9jk12/5NJVcOxi7RSNqIyxkL5b6XGQk
# vdUg8jW/WksO3+YojPUqYfIY7HYpxxvynBEUq/F06Dqp87KjQy7+uYdalt4I4/Sj
# XxOflcnvmfxCfvIp3hR9fzS+pNwlyRrTqX3s+7DZVdxD0l0d8SiSdOS9gB6+EZKs
# gVYkQqpPfy3NBZ5L7Q9FErmuC/J+bi5UFZtG2umgcJYSzSNCx4dHWD0R3oFX8kId
# G+0bbT8RKiD2SDNyHa4fDwHY2cY2rkFPoe9yxkxDODSLZOOohaW/wXSc+qHMdGt+
# kbp2QQuk7UR8yJt0qcnQ3sGvDAKdOgwBqb1ZUwYL9FMnMoNZ8YjXgArb5NQ9nzRS
# QI80mR3J7P5CAbGOxu45LQzRmkgUGMZm+PocZnyAajjJ7SMlTjAO1SSDqBSCBFfX
# jwiMfMp0z8aW8YCPus5iN4IlsrkTlRv++TaS4VQszQnRTxiEwKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MDYxOTMzNDZaMC8GCSqGSIb3DQEJBDEiBCCgTjyT
# 2Fm3fC35/GdT6H713haSyvbGrk13aoXZhsTngDANBgkqhkiG9w0BAQEFAASCAgAe
# 2wsmiCrcEgpTHHRqtwC66mHix82iJr2hkQzMPnxEOI3EbvxcMTdtaLqIck9AEoMc
# Q72Zkmz9Mms97xc1d8yK5dI7eWnQORMKuOVQlEg4egaQbyIn7Gjtb81PgkN0xzkk
# 4Cm6CxfgSivtR5LO1p7aNU9CUuRoY3FUaJ65AeliAdmBRe03kZpQhKuXTEiixdmN
# T6TB6B0qPm7bR0zPpB9QdnidObLBCF3dAqgiuGV7SP4LxsJy4eEBhOsY4PkTwlOl
# im/+GE7gxqK6jS68d9IQlGIo+FtmX68VF86WkkJON2YsBy+nywVs88+bU1CTzZNi
# zI8wJW57KVDkb7Xexva3AXYrCLp3V9V1mvglaHt0Qo0FBIX5ivta+Mk1rSEAGK3Q
# Clm2ov0f0GH1UlFnsIalpEKblXxnrfCoXUgsnKP1K/hfmtBUyBzK7c6DwDgHG76V
# 3SafwdiLEku71DCNIWI6NMmXjvQnw+9BEbq3f43Kz9QvsYric7IQJ4+CLjD/8Bm8
# KbQgbJp4CoaF2GDxHffgfVKTtaKsjdAW03+b/U/ZN3g4hfg02IU88h9go00u0HQE
# 7qt1DINeh3CsFnNPitcVDVHvgnfm0ILfYgMQqg3UgkeRDVtWkhTodpjqStzyAOwy
# DBh++q+JXFThlOzW08lDRBG87fv7wFYubPzYexLEVw==
# SIG # End signature block
