<#
.SYNOPSIS
    End-to-end test for Discovery Scheduled Tasks with System DPAPI Vault.

.DESCRIPTION
    This script validates the complete scheduled task flow for discovery helpers:
    
    1. System Vault Setup - Creates/populates the LocalMachine DPAPI vault
    2. Task Registration   - Registers a scheduled task running as SYSTEM
    3. Task Execution      - Runs the task and waits for completion
    4. Output Verification - Checks for expected output files and log content
    5. Cleanup             - Optionally removes the test task and artifacts

    The test uses WindowsAttributes discovery against localhost by default since
    it requires no external infrastructure. Other providers can be tested by
    specifying credentials when prompted.

    DPAPI LocalMachine Vault:
      Credentials are encrypted using the machine key (not user key), allowing
      SYSTEM and any administrator to decrypt them. This enables scheduled tasks
      to run without storing plaintext passwords or requiring user logon.

    Output Artifacts:
      - Dashboard HTML : %ProgramData%\WhatsUpGoldPS\Output\<Provider>-Dashboard.html
      - Log files      : %ProgramData%\WhatsUpGoldPS\Output\logs\<TaskName>_*.log
      - JSON export    : %ProgramData%\WhatsUpGoldPS\Output\<Provider>-DiscoveryPlan.json

.PARAMETER Provider
    Discovery provider to test. Default: WindowsAttributes (targets localhost).
    Options: AWS, Azure, Proxmox, CiscoWLC, CUCM, Docker, WindowsAttributes, WindowsDiskIO.

.PARAMETER Target
    Target host(s) for discovery. Default varies by provider.
    - WindowsAttributes/WindowsDiskIO: localhost
    - Docker: localhost (requires Docker Engine API on port 2375)
    - Others: requires explicit target

.PARAMETER Action
    Discovery action to test. Default: Dashboard.
    Options: Dashboard, ExportJSON, ExportCSV, ShowTable, PushToWUG, DashboardAndPush.

.PARAMETER SkipVaultSetup
    Skip the interactive vault credential setup. Use when vault is already
    populated (e.g., re-running test after initial setup).

.PARAMETER SkipTaskRegistration
    Skip task registration. Use when task already exists and you only want
    to run it again.

.PARAMETER RunAsCurrentUser
    Run the task as the current user instead of SYSTEM. This uses the
    CurrentUser DPAPI vault instead of LocalMachine. Useful for debugging
    but does not test the SYSTEM vault flow.

.PARAMETER WaitTimeoutSeconds
    How long to wait for the scheduled task to complete. Default: 300 (5 min).

.PARAMETER NoCleanup
    Do not remove the scheduled task after the test. Useful for debugging
    or when you want to keep the task for future runs.

.PARAMETER OutputPath
    Base directory for output files. Default: %ProgramData%\WhatsUpGoldPS\Output.
    When running as SYSTEM, this MUST be accessible by SYSTEM (not user profile).

.PARAMETER OpenDashboard
    Open the generated dashboard in the default browser after successful test.

.PARAMETER OpenLog
    Open the task execution log in notepad after the test.

.PARAMETER Verbose
    Enable verbose output showing detailed test progress.

.EXAMPLE
    .\Invoke-WUGScheduledTaskE2ETest.ps1
    # Full E2E test with WindowsAttributes against localhost.
    # Prompts for WMI credentials, registers SYSTEM task, runs it, verifies output.

.EXAMPLE
    .\Invoke-WUGScheduledTaskE2ETest.ps1 -Provider Proxmox -Target '192.168.1.30'
    # Test Proxmox discovery. Prompts for API token/credentials.

.EXAMPLE
    .\Invoke-WUGScheduledTaskE2ETest.ps1 -SkipVaultSetup -SkipTaskRegistration -OpenLog
    # Re-run existing task and view the log (useful for debugging).

.EXAMPLE
    .\Invoke-WUGScheduledTaskE2ETest.ps1 -RunAsCurrentUser -NoCleanup
    # Test as current user (not SYSTEM) and keep the task.

.NOTES
    Author  : jason@wug.ninja
    Created : 2026-07-06
    Requires: PowerShell 5.1+, Administrator rights

    IMPORTANT: Run this script from an elevated PowerShell prompt.
    Scheduled task registration and LocalMachine DPAPI require admin rights.
#>
[CmdletBinding()]
param(
    [ValidateSet('AWS', 'Azure', 'Proxmox', 'CiscoWLC', 'CUCM', 'Docker',
                 'WindowsAttributes', 'WindowsDiskIO', 'HyperV', 'VMware',
                 'F5', 'Fortinet', 'Bigleaf', 'GCP', 'OCI', 'Nutanix')]
    [string]$Provider = 'WindowsAttributes',

    [string[]]$Target,

    [ValidateSet('Dashboard', 'ExportJSON', 'ExportCSV', 'ShowTable', 'PushToWUG', 'DashboardAndPush', 'None')]
    [string]$Action = 'Dashboard',

    [switch]$SkipVaultSetup,
    [switch]$SkipTaskRegistration,
    [switch]$RunAsCurrentUser,
    [int]$WaitTimeoutSeconds = 300,
    [switch]$NoCleanup,
    [string]$OutputPath,
    [switch]$OpenDashboard,
    [switch]$OpenLog
)

# ============================================================================
# region  Setup and Validation
# ============================================================================
$ErrorActionPreference = 'Stop'
$scriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryDir = Join-Path (Split-Path $scriptDir -Parent) 'discovery'
$timestamp    = (Get-Date).ToString('yyyyMMdd_HHmmss')

# Verify running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script requires administrator privileges. Please run from an elevated PowerShell prompt."
    return
}

# Set default targets by provider
if (-not $Target) {
    switch ($Provider) {
        'WindowsAttributes' { $Target = @('localhost') }
        'WindowsDiskIO'     { $Target = @('localhost') }
        'Docker'            { $Target = @('localhost') }
        default {
            Write-Error "Provider '$Provider' requires -Target parameter. Please specify the target host(s)."
            return
        }
    }
}

# Provider-specific parameter mapping
# Some providers use different parameter names for their target
# IsArray indicates whether the target parameter accepts multiple values
$script:ProviderParamMap = @{
    Azure    = @{ TargetParam = 'TenantId';   TargetDesc = 'Azure Tenant ID';       IsArray = $false }
    AWS      = @{ TargetParam = 'Region';     TargetDesc = 'AWS Region(s)';         IsArray = $true }
    GCP      = @{ TargetParam = 'ProjectId';  TargetDesc = 'GCP Project ID(s)';     IsArray = $true }
    OCI      = @{ TargetParam = 'TenancyId';  TargetDesc = 'OCI Tenancy OCID';      IsArray = $false }
    Proxmox  = @{ TargetParam = 'Target';     TargetDesc = 'Proxmox Host(s)';       IsArray = $true }
    HyperV   = @{ TargetParam = 'Target';     TargetDesc = 'Hyper-V Host(s)';       IsArray = $true }
    VMware   = @{ TargetParam = 'Target';     TargetDesc = 'vCenter/ESXi Host';     IsArray = $false }
    Docker   = @{ TargetParam = 'Target';     TargetDesc = 'Docker Host(s)';        IsArray = $true }
    F5       = @{ TargetParam = 'Target';     TargetDesc = 'F5 BIG-IP Host(s)';     IsArray = $true }
    Fortinet = @{ TargetParam = 'Target';     TargetDesc = 'FortiGate Host(s)';     IsArray = $true }
    Nutanix  = @{ TargetParam = 'Target';     TargetDesc = 'Nutanix Prism Host(s)'; IsArray = $true }
    CiscoWLC = @{ TargetParam = 'Target';     TargetDesc = 'Cisco WLC Host(s)';     IsArray = $true }
    CUCM     = @{ TargetParam = 'Target';     TargetDesc = 'CUCM Publisher Host';   IsArray = $true }
    Bigleaf  = @{ TargetParam = 'Target';     TargetDesc = 'Bigleaf Site Label';    IsArray = $false }
    WindowsAttributes = @{ TargetParam = 'Target'; TargetDesc = 'Windows Host(s)';  IsArray = $true }
    WindowsDiskIO = @{ TargetParam = 'Target'; TargetDesc = 'Windows Host(s)';      IsArray = $true }
}

# Get provider-specific parameter info
$providerConfig = $script:ProviderParamMap[$Provider]
if (-not $providerConfig) {
    $providerConfig = @{ TargetParam = 'Target'; TargetDesc = 'Target Host(s)' }
}

# Set output path - MUST be SYSTEM-accessible when using LocalMachine vault
if (-not $OutputPath) {
    if ($RunAsCurrentUser) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    } else {
        $OutputPath = Join-Path $env:ProgramData 'WhatsUpGoldPS\Output'
    }
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$logDir = Join-Path $OutputPath 'logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Task naming
$taskName   = "E2ETest-$Provider-$timestamp"
$taskFolder = '\WhatsUpGoldPS'

# Load discovery helpers
$helpersPath = Join-Path $discoveryDir 'DiscoveryHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    Write-Error "DiscoveryHelpers.ps1 not found at '$helpersPath'. Cannot continue."
    return
}
. $helpersPath

Write-Host ''
Write-Host '  ╔═══════════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║     Scheduled Task E2E Test - System DPAPI Vault                  ║' -ForegroundColor Cyan
Write-Host '  ╠═══════════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan
Write-Host "  ║  Provider   : $($Provider.PadRight(52))║" -ForegroundColor White
Write-Host "  ║  Target     : $((($Target -join ', ').PadRight(52)))║" -ForegroundColor White
Write-Host "  ║  Action     : $($Action.PadRight(52))║" -ForegroundColor White
Write-Host "  ║  Task Name  : $($taskName.PadRight(52))║" -ForegroundColor White
Write-Host "  ║  Output     : $(($OutputPath.Substring(0, [Math]::Min($OutputPath.Length, 52))).PadRight(52))║" -ForegroundColor White
Write-Host "  ║  Run As     : $(if ($RunAsCurrentUser) { 'Current User (DPAPI CurrentUser)' } else { 'SYSTEM (DPAPI LocalMachine)' })$((' ' * (52 - $(if ($RunAsCurrentUser) { 32 } else { 28 }))))║" -ForegroundColor $(if ($RunAsCurrentUser) { 'Yellow' } else { 'Green' })
Write-Host '  ╚═══════════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

# endregion

# ============================================================================
# region  Test Results Tracking
# ============================================================================
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:TestStartTime = Get-Date

function Record-TestStep {
    param(
        [string]$Step,
        [string]$Status,  # Pass, Fail, Skip, Info
        [string]$Detail = '',
        [int]$DurationMs = 0
    )
    $color = switch ($Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Skip' { 'Yellow' }
        'Info' { 'Cyan' }
        default { 'White' }
    }
    $icon = switch ($Status) {
        'Pass' { '[OK]' }
        'Fail' { '[X]' }
        'Skip' { '[~]' }
        'Info' { '[i]' }
        default { '[ ]' }
    }
    
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host "$Step" -ForegroundColor White -NoNewline
    if ($Detail) { Write-Host " - $Detail" -ForegroundColor DarkGray }
    else { Write-Host '' }
    
    $script:TestResults.Add([PSCustomObject]@{
        Step       = $Step
        Status     = $Status
        Detail     = $Detail
        DurationMs = $DurationMs
        Timestamp  = (Get-Date).ToString('HH:mm:ss')
    })
}

function Show-TestSummary {
    $passed = @($script:TestResults | Where-Object Status -eq 'Pass').Count
    $failed = @($script:TestResults | Where-Object Status -eq 'Fail').Count
    $skipped = @($script:TestResults | Where-Object Status -eq 'Skip').Count
    $totalMs = ((Get-Date) - $script:TestStartTime).TotalMilliseconds
    
    Write-Host ''
    Write-Host '  ═══════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
    Write-Host '  Test Summary' -ForegroundColor Cyan
    Write-Host '  ═══════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
    Write-Host "  Passed  : $passed" -ForegroundColor Green
    Write-Host "  Failed  : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host "  Skipped : $skipped" -ForegroundColor $(if ($skipped -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Host "  Duration: $([Math]::Round($totalMs / 1000, 1))s" -ForegroundColor White
    Write-Host '  ═══════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
    
    if ($failed -eq 0) {
        Write-Host '  ALL TESTS PASSED' -ForegroundColor Green
    } else {
        Write-Host '  SOME TESTS FAILED' -ForegroundColor Red
        $script:TestResults | Where-Object Status -eq 'Fail' | ForEach-Object {
            Write-Host "    - $($_.Step): $($_.Detail)" -ForegroundColor Red
        }
    }
    Write-Host ''
    
    return ($failed -eq 0)
}
# endregion

# ============================================================================
# region  Step 1: System Vault Setup
# ============================================================================
Write-Host ''
Write-Host '  Step 1: Vault Setup' -ForegroundColor Cyan
Write-Host '  -------------------' -ForegroundColor DarkCyan

if ($SkipVaultSetup) {
    Record-TestStep -Step 'Vault Setup' -Status 'Skip' -Detail 'Skipped via -SkipVaultSetup'
}
else {
    $vaultStepStart = Get-Date
    
    try {
        if ($RunAsCurrentUser) {
            # Use CurrentUser vault (default)
            Write-Host '  Using CurrentUser DPAPI vault (task will run as current user)' -ForegroundColor Yellow
            Record-TestStep -Step 'Vault Scope' -Status 'Info' -Detail 'CurrentUser (user profile)'
        }
        else {
            # Switch to LocalMachine vault for SYSTEM access
            Set-DiscoveryVaultScope -Scope LocalMachine
            Record-TestStep -Step 'Vault Scope' -Status 'Pass' -Detail 'LocalMachine (SYSTEM accessible)'
        }
        
        # Verify vault directory exists and is accessible
        $vaultPath = $script:DiscoveryVaultPath
        if (-not (Test-Path $vaultPath)) {
            Initialize-DiscoveryVault
        }
        Record-TestStep -Step 'Vault Directory' -Status 'Pass' -Detail $vaultPath
        
        # Now run the provider setup to populate credentials
        $setupScript = Join-Path $discoveryDir "Setup-$Provider-Discovery.ps1"
        if (-not (Test-Path $setupScript)) {
            throw "Setup script not found: $setupScript"
        }
        
        Write-Host ''
        Write-Host '  Running provider setup to populate vault credentials...' -ForegroundColor Yellow
        Write-Host '  (Answer the prompts to store credentials in the vault)' -ForegroundColor DarkGray
        Write-Host ''
        
        # Run setup with Action=None to just populate the vault without doing discovery
        # Handle single-value vs array parameters
        $targetValue = if ($providerConfig.IsArray) { $Target } else { $Target[0] }
        $setupArgs = @{
            $providerConfig.TargetParam = $targetValue
            Action = 'None'
            OutputPath = $OutputPath
        }
        & $setupScript @setupArgs
        
        $vaultDurationMs = [int]((Get-Date) - $vaultStepStart).TotalMilliseconds
        Record-TestStep -Step 'Vault Credential Setup' -Status 'Pass' -Detail "Credentials saved to vault" -DurationMs $vaultDurationMs
    }
    catch {
        Record-TestStep -Step 'Vault Setup' -Status 'Fail' -Detail $_.Exception.Message
        Write-Error "Vault setup failed: $_"
        Show-TestSummary
        return
    }
}
# endregion

# ============================================================================
# region  Step 2: Create Wrapper CMD File
# ============================================================================
Write-Host ''
Write-Host '  Step 2: Create Wrapper Script' -ForegroundColor Cyan
Write-Host '  ------------------------------' -ForegroundColor DarkCyan

$wrapperStepStart = Get-Date

# Build provider-specific argument string for wrapper scripts
$targetParamName = $providerConfig.TargetParam
# Build target value string for display and for wrapper script
if ($providerConfig.IsArray) {
    $targetQuoted = ($Target | ForEach-Object { "'$_'" }) -join ','
    $targetDisplayValue = $Target -join ', '
} else {
    $targetQuoted = "'$($Target[0])'"
    $targetDisplayValue = $Target[0]
}
$providerArgString = "-$targetParamName $targetQuoted -Action $Action -NonInteractive -OutputPath '$OutputPath'"

# Create a .cmd wrapper that handles directory switching and environment setup
# This pattern makes debugging easier - you can run the .cmd manually to test
$wrapperDir = Join-Path $OutputPath 'wrappers'
if (-not (Test-Path $wrapperDir)) {
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null
}

$wrapperCmdPath = Join-Path $wrapperDir "$taskName.cmd"
$wrapperPs1Path = Join-Path $wrapperDir "$taskName.ps1"

# The CMD wrapper sets up the environment and calls PowerShell
$cmdContent = @"
@echo off
REM ============================================================================
REM  Discovery Scheduled Task Wrapper - $taskName
REM  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
REM  Provider : $Provider
REM  $($providerConfig.TargetDesc) : $($Target -join ', ')
REM ============================================================================

REM Set working directory to discovery folder
cd /d "$discoveryDir"

REM Set vault scope environment variable
$(if (-not $RunAsCurrentUser) { 'set WUG_VAULT_SCOPE=LocalMachine' } else { 'REM Using CurrentUser vault' })

REM Execute the PowerShell wrapper script
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$wrapperPs1Path"

REM Capture exit code
set EXITCODE=%ERRORLEVEL%

REM Log completion
echo.
echo Exit code: %EXITCODE%
echo Completed: %DATE% %TIME%

exit /b %EXITCODE%
"@

# The PowerShell wrapper does the actual work with full logging
$ps1Content = @"

#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell wrapper for scheduled discovery task: $taskName
    Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
#>
`$ErrorActionPreference = 'Continue'
`$VerbosePreference = 'Continue'

# ============================================================================
# Logging Setup
# ============================================================================
`$logDir  = '$logDir'
`$logFile = Join-Path `$logDir ('$taskName' + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

if (-not (Test-Path `$logDir)) {
    try { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null } catch {}
}

`$transcriptStarted = `$false
try {
    Start-Transcript -Path `$logFile -Force | Out-Null
    `$transcriptStarted = `$true
} catch {
    # Fallback: write initial info to log file
    "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Start-Transcript FAILED: `$_" | Out-File -FilePath `$logFile -Encoding UTF8 -Force
}

# ============================================================================
# Task Context Information
# ============================================================================
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════════════'
Write-Host ' Discovery Scheduled Task Execution'
Write-Host '═══════════════════════════════════════════════════════════════════════'
Write-Host "Task Name   : $taskName"
Write-Host "Provider    : $Provider"
Write-Host "Target      : $($Target -join ', ')"
Write-Host "Action      : $Action"
Write-Host "DateTime    : `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "User        : `$env:USERDOMAIN\`$env:USERNAME"
Write-Host "Machine     : `$env:COMPUTERNAME"
Write-Host "PID         : `$PID"
Write-Host "WorkDir     : `$(Get-Location)"
Write-Host "Vault Scope : `$env:WUG_VAULT_SCOPE"
Write-Host "Log File    : `$logFile"
Write-Host '═══════════════════════════════════════════════════════════════════════'
Write-Host ''

# ============================================================================
# Set Vault Scope
# ============================================================================
$(if (-not $RunAsCurrentUser) { "`$env:WUG_VAULT_SCOPE = 'LocalMachine'" } else { "# Using CurrentUser vault (default)" })

# ============================================================================
# Load Discovery Helpers
# ============================================================================
`$discoveryDir = '$discoveryDir'
`$helpersPath  = Join-Path `$discoveryDir 'DiscoveryHelpers.ps1'

Write-Host "Loading DiscoveryHelpers from: `$helpersPath"
if (-not (Test-Path `$helpersPath)) {
    Write-Error "DiscoveryHelpers.ps1 not found at '`$helpersPath'"
    exit 1
}
. `$helpersPath

# ============================================================================
# Execute Discovery
# ============================================================================
`$exitCode = 0
`$setupScript = Join-Path `$discoveryDir 'Setup-$Provider-Discovery.ps1'

# Target value(s) for this provider
$(if ($providerConfig.IsArray) { "`$targetValue = @($targetQuoted)" } else { "`$targetValue = $targetQuoted" })

# Build splat for provider-specific parameters
`$runArgs = @{
    '$targetParamName' = `$targetValue
    'Action'           = '$Action'
    'NonInteractive'   = `$true
    'OutputPath'       = '$OutputPath'
}

Write-Host ''
Write-Host "Executing: `$setupScript"
Write-Host "Arguments:"
`$runArgs.GetEnumerator() | ForEach-Object { Write-Host "  -`$(`$_.Key) `$(`$_.Value)" }
Write-Host ''

try {
    & `$setupScript @runArgs
    
    if (`$LASTEXITCODE) { `$exitCode = `$LASTEXITCODE }
    
    Write-Host ''
    Write-Host 'Discovery script completed.'
}
catch {
    Write-Host ''
    Write-Host "FATAL ERROR: `$_" -ForegroundColor Red
    Write-Host `$_.ScriptStackTrace
    `$exitCode = 1
}

# ============================================================================
# Completion
# ============================================================================
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════════════'
Write-Host "Exit Code : `$exitCode"
Write-Host "Completed : `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host '═══════════════════════════════════════════════════════════════════════'

if (`$transcriptStarted) { try { Stop-Transcript } catch {} }

exit `$exitCode
"@

try {
    # Write wrapper files
    $cmdContent | Out-File -FilePath $wrapperCmdPath -Encoding ASCII -Force
    $ps1Content | Out-File -FilePath $wrapperPs1Path -Encoding UTF8 -Force
    
    $wrapperDurationMs = [int]((Get-Date) - $wrapperStepStart).TotalMilliseconds
    Record-TestStep -Step 'Create CMD Wrapper' -Status 'Pass' -Detail $wrapperCmdPath -DurationMs $wrapperDurationMs
    Record-TestStep -Step 'Create PS1 Wrapper' -Status 'Pass' -Detail $wrapperPs1Path
    
    Write-Host ''
    Write-Host '  Wrapper files created:' -ForegroundColor DarkGray
    Write-Host "    CMD: $wrapperCmdPath" -ForegroundColor Gray
    Write-Host "    PS1: $wrapperPs1Path" -ForegroundColor Gray
    Write-Host ''
    Write-Host '  To debug manually, run:' -ForegroundColor DarkGray
    Write-Host "    $wrapperCmdPath" -ForegroundColor Gray
    Write-Host ''
}
catch {
    Record-TestStep -Step 'Create Wrapper Scripts' -Status 'Fail' -Detail $_.Exception.Message
    Write-Error "Failed to create wrapper scripts: $_"
    Show-TestSummary
    return
}
# endregion

# ============================================================================
# region  Step 3: Register Scheduled Task
# ============================================================================
Write-Host ''
Write-Host '  Step 3: Register Scheduled Task' -ForegroundColor Cyan
Write-Host '  --------------------------------' -ForegroundColor DarkCyan

if ($SkipTaskRegistration) {
    Record-TestStep -Step 'Task Registration' -Status 'Skip' -Detail 'Skipped via -SkipTaskRegistration'
}
else {
    $regStepStart = Get-Date
    
    try {
        # Build the encoded command that runs our wrapper
        $fullCommand = @"
`$ErrorActionPreference = 'Continue'
Set-Location '$discoveryDir'
$(if (-not $RunAsCurrentUser) { "`$env:WUG_VAULT_SCOPE = 'LocalMachine'" })
& '$wrapperPs1Path'
exit `$LASTEXITCODE
"@
        
        $encodedBytes   = [System.Text.Encoding]::Unicode.GetBytes($fullCommand)
        $encodedCommand = [Convert]::ToBase64String($encodedBytes)
        $taskArgs       = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
        
        # Create task action
        $taskAction = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument $taskArgs `
            -WorkingDirectory $discoveryDir
        
        # Create trigger (Once, now + 1 minute for testing)
        $triggerTime = (Get-Date).AddMinutes(1)
        $taskTrigger = New-ScheduledTaskTrigger -Once -At $triggerTime
        
        # Create principal (SYSTEM or current user)
        if ($RunAsCurrentUser) {
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $taskPrincipal = New-ScheduledTaskPrincipal `
                -UserId $currentUser `
                -LogonType S4U `
                -RunLevel Limited
        }
        else {
            $taskPrincipal = New-ScheduledTaskPrincipal `
                -UserId 'SYSTEM' `
                -LogonType ServiceAccount `
                -RunLevel Highest
        }
        
        # Create settings
        $taskSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
            -MultipleInstances IgnoreNew
        
        # Create the task folder if it doesn't exist
        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        try {
            $scheduler.GetFolder($taskFolder) | Out-Null
        }
        catch {
            $rootFolder = $scheduler.GetFolder('\')
            $rootFolder.CreateFolder($taskFolder) | Out-Null
            Write-Verbose "Created task folder: $taskFolder"
        }
        
        # Register the task
        Register-ScheduledTask `
            -TaskName $taskName `
            -TaskPath $taskFolder `
            -Action $taskAction `
            -Trigger $taskTrigger `
            -Principal $taskPrincipal `
            -Settings $taskSettings `
            -Force | Out-Null
        
        $regDurationMs = [int]((Get-Date) - $regStepStart).TotalMilliseconds
        Record-TestStep -Step 'Task Registration' -Status 'Pass' -Detail "Registered as $taskFolder\$taskName" -DurationMs $regDurationMs
        
        Write-Host ''
        Write-Host "  Task registered: $taskFolder\$taskName" -ForegroundColor Green
        Write-Host "  Run as: $(if ($RunAsCurrentUser) { $currentUser } else { 'SYSTEM' })" -ForegroundColor White
        Write-Host "  Trigger: $($triggerTime.ToString('HH:mm:ss'))" -ForegroundColor White
        Write-Host ''
    }
    catch {
        Record-TestStep -Step 'Task Registration' -Status 'Fail' -Detail $_.Exception.Message
        Write-Error "Task registration failed: $_"
        Show-TestSummary
        return
    }
}
# endregion

# ============================================================================
# region  Step 4: Execute Task and Wait
# ============================================================================
Write-Host ''
Write-Host '  Step 4: Execute Task' -ForegroundColor Cyan
Write-Host '  --------------------' -ForegroundColor DarkCyan

$execStepStart = Get-Date

try {
    # Start the task immediately (don't wait for trigger)
    Write-Host '  Starting task...' -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $taskName -TaskPath "$taskFolder\"
    
    Record-TestStep -Step 'Task Start' -Status 'Pass' -Detail 'Task started'
    
    # Wait for completion with timeout
    Write-Host "  Waiting for task completion (timeout: ${WaitTimeoutSeconds}s)..." -ForegroundColor Yellow
    $waitStart = Get-Date
    $completed = $false
    $lastState = ''
    
    while (-not $completed -and ((Get-Date) - $waitStart).TotalSeconds -lt $WaitTimeoutSeconds) {
        Start-Sleep -Seconds 2
        $taskInfo = Get-ScheduledTask -TaskName $taskName -TaskPath "$taskFolder\" -ErrorAction SilentlyContinue
        
        if ($taskInfo.State -ne $lastState) {
            Write-Host "    State: $($taskInfo.State)" -ForegroundColor DarkGray
            $lastState = $taskInfo.State
        }
        
        if ($taskInfo.State -eq 'Ready') {
            $completed = $true
        }
    }
    
    $execDurationMs = [int]((Get-Date) - $execStepStart).TotalMilliseconds
    
    if ($completed) {
        # Get the last run result
        $taskRunInfo = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath "$taskFolder\"
        $lastRunResult = $taskRunInfo.LastRunTime
        $lastTaskResult = $taskRunInfo.LastTaskResult
        
        if ($lastTaskResult -eq 0) {
            Record-TestStep -Step 'Task Execution' -Status 'Pass' -Detail "Completed at $($lastRunResult.ToString('HH:mm:ss'))" -DurationMs $execDurationMs
        }
        else {
            Record-TestStep -Step 'Task Execution' -Status 'Fail' -Detail "Exit code: $lastTaskResult" -DurationMs $execDurationMs
        }
    }
    else {
        Record-TestStep -Step 'Task Execution' -Status 'Fail' -Detail "Timeout after ${WaitTimeoutSeconds}s" -DurationMs $execDurationMs
    }
}
catch {
    Record-TestStep -Step 'Task Execution' -Status 'Fail' -Detail $_.Exception.Message
}
# endregion

# ============================================================================
# region  Step 5: Verify Output
# ============================================================================
Write-Host ''
Write-Host '  Step 5: Verify Output' -ForegroundColor Cyan
Write-Host '  ---------------------' -ForegroundColor DarkCyan

$verifyStepStart = Get-Date

# Check for log file
$logFiles = @(Get-ChildItem -Path $logDir -Filter "$taskName*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($logFiles.Count -gt 0) {
    $latestLog = $logFiles[0]
    Record-TestStep -Step 'Log File Created' -Status 'Pass' -Detail $latestLog.Name
    
    # Check log content for errors
    $logContent = Get-Content $latestLog.FullName -Raw -ErrorAction SilentlyContinue
    if ($logContent -match 'FATAL|ERROR|Exception|failed') {
        Record-TestStep -Step 'Log Content Check' -Status 'Fail' -Detail 'Errors found in log'
        Write-Host ''
        Write-Host '  Log errors detected:' -ForegroundColor Red
        $logContent -split "`n" | Where-Object { $_ -match 'FATAL|ERROR|Exception|failed' } | ForEach-Object {
            Write-Host "    $_" -ForegroundColor Red
        }
    }
    elseif ($logContent -match 'completed|success|Exit Code\s*:\s*0') {
        Record-TestStep -Step 'Log Content Check' -Status 'Pass' -Detail 'No errors, success indicators found'
    }
    else {
        Record-TestStep -Step 'Log Content Check' -Status 'Info' -Detail 'No clear success/failure indicators'
    }
}
else {
    Record-TestStep -Step 'Log File Created' -Status 'Fail' -Detail 'No log file found'
}

# Check for output files based on action
$outputFiles = @()
switch ($Action) {
    'Dashboard' {
        # Search recursively — CiscoWLC puts dashboards in OutputPath\summary\dashboards\
        $dashboardFiles = @(Get-ChildItem -Path $OutputPath -Recurse -Include '*Dashboard*.html','wireless-dashboard-*.html' -ErrorAction SilentlyContinue | 
            Where-Object { $_.LastWriteTime -gt $script:TestStartTime } |
            Sort-Object LastWriteTime -Descending)
        if ($dashboardFiles.Count -gt 0) {
            $outputFiles += $dashboardFiles[0]
            Record-TestStep -Step 'Dashboard Output' -Status 'Pass' -Detail $dashboardFiles[0].Name
        }
        else {
            # Check if dashboard exists but predates test start (timing issue)
            $anyDash = @(Get-ChildItem -Path $OutputPath -Recurse -Include '*Dashboard*.html','wireless-dashboard-*.html' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
            $detail = if ($anyDash.Count -gt 0) {
                "Dashboard exists but predates test start: $($anyDash[0].Name) ($($anyDash[0].LastWriteTime.ToString('HH:mm:ss')))"
            } else {
                'No dashboard HTML found in output path or subdirectories'
            }
            Record-TestStep -Step 'Dashboard Output' -Status 'Fail' -Detail $detail
        }
    }
    'ExportJSON' {
        $jsonFiles = @(Get-ChildItem -Path $OutputPath -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $script:TestStartTime } |
            Sort-Object LastWriteTime -Descending)
        if ($jsonFiles.Count -gt 0) {
            $outputFiles += $jsonFiles[0]
            Record-TestStep -Step 'JSON Output' -Status 'Pass' -Detail $jsonFiles[0].Name
        }
        else {
            Record-TestStep -Step 'JSON Output' -Status 'Fail' -Detail 'No JSON file found'
        }
    }
    'ExportCSV' {
        $csvFiles = @(Get-ChildItem -Path $OutputPath -Filter '*.csv' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $script:TestStartTime } |
            Sort-Object LastWriteTime -Descending)
        if ($csvFiles.Count -gt 0) {
            $outputFiles += $csvFiles[0]
            Record-TestStep -Step 'CSV Output' -Status 'Pass' -Detail $csvFiles[0].Name
        }
        else {
            Record-TestStep -Step 'CSV Output' -Status 'Fail' -Detail 'No CSV file found'
        }
    }
    default {
        Record-TestStep -Step 'Output Files' -Status 'Info' -Detail "Action '$Action' may not produce output files"
    }
}

$verifyDurationMs = [int]((Get-Date) - $verifyStepStart).TotalMilliseconds
# endregion

# ============================================================================
# region  Step 6: Cleanup (optional)
# ============================================================================
Write-Host ''
Write-Host '  Step 6: Cleanup' -ForegroundColor Cyan
Write-Host '  ---------------' -ForegroundColor DarkCyan

if ($NoCleanup) {
    Record-TestStep -Step 'Cleanup' -Status 'Skip' -Detail 'Skipped via -NoCleanup'
    Write-Host ''
    Write-Host '  Task retained for future runs:' -ForegroundColor Yellow
    Write-Host "    Start-ScheduledTask -TaskName '$taskName' -TaskPath '$taskFolder\'" -ForegroundColor Gray
    Write-Host "    Get-ScheduledTaskInfo -TaskName '$taskName' -TaskPath '$taskFolder\'" -ForegroundColor Gray
    Write-Host ''
}
else {
    try {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath "$taskFolder\" -Confirm:$false -ErrorAction Stop
        Record-TestStep -Step 'Task Removal' -Status 'Pass' -Detail 'Task unregistered'
    }
    catch {
        Record-TestStep -Step 'Task Removal' -Status 'Fail' -Detail $_.Exception.Message
    }
}
# endregion

# ============================================================================
# region  Results and Open Files
# ============================================================================
$allPassed = Show-TestSummary

# Open dashboard if requested
if ($OpenDashboard -and $outputFiles.Count -gt 0) {
    $dashFile = $outputFiles | Where-Object { $_.Name -match '\.html$' } | Select-Object -First 1
    if ($dashFile) {
        Write-Host "  Opening dashboard: $($dashFile.FullName)" -ForegroundColor Cyan
        Start-Process $dashFile.FullName
    }
}

# Open log if requested
if ($OpenLog -and $logFiles.Count -gt 0) {
    Write-Host "  Opening log: $($logFiles[0].FullName)" -ForegroundColor Cyan
    Start-Process 'notepad.exe' -ArgumentList $logFiles[0].FullName
}

# Output file locations for easy access
Write-Host ''
Write-Host '  Output Locations:' -ForegroundColor Cyan
Write-Host "    Logs      : $logDir" -ForegroundColor White
Write-Host "    Output    : $OutputPath" -ForegroundColor White
Write-Host "    Wrappers  : $wrapperDir" -ForegroundColor White
Write-Host ''

if ($logFiles.Count -gt 0) {
    Write-Host '  View latest log:' -ForegroundColor DarkGray
    Write-Host "    Get-Content '$($logFiles[0].FullName)' | more" -ForegroundColor Gray
    Write-Host ''
}

# Return success/failure
return $allPassed
# endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDOUJIU5sJlvoJl
# sgnxaHUrqtnXyLSN/tBQ2O7SCjsEhaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCA1Oza9HOozPymJ7KATeQDf99Z14G7tESihMLWCePB8RDANBgkqhkiG9w0BAQEF
# AASCAgB1lLEt8FKdnnnPYCKrDHJIVUXizYr07H5IrDW+m4MS1yzf0RgSZSNHOQHi
# KCwXzN2hYw3x5/UprkbKZIl1eE9B6PXTHzAGDaKFbEUW2jXdr+ZpX3B1Cy22ts7j
# cuYZcnWBn6veQ74CHlSJ8fj4KkCayrO4KeSVpHqaRr2UiuvyUTxQFKo4k5pgDFGP
# i72oQBHiohWrTNFKgjYwbTFKEWma4CSITzECwtoLgbtkpWnrsB1BYVe9lJdvvpnX
# 9eoU4GGEVzZAkKv5EQohxjJJgPPsLMloNpY0A4MPuXMgjyue4npe80CB3MfQ6ZaT
# 2r8h3g03ix/zBCIsW5XOKKn4JztOt+OXXmrY91AZwLiGl2V+dv4cMp8iDB2UjSF7
# Jw8Q7Ev/f4BalO9kqOvLxCPMLImZc2R5KENfx1f3VvGkmmbXqJ+QFSb819aHsJG9
# A5K5y3oirmOkOp+Dggumw87YinL2/FmARCnfPW1+R1HFR+OqFBWK083MwIqr1O3N
# EnxJJtNIMRS9WhGt+qErBt9LRDGVJxRMVTUfl4H/GKCpzjAnnPjo7IPRi1szEhmD
# /wHaj1ghSlP2NihtbXFluVDLXnBP9+mp2xKsLL+naHKDfgQvHBbcmDtA8GA/PkMb
# ji+qrej8/GqyWneYy525BansH5kKwXUP4iv4xVKwAmlILU5z96GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MDcxODA4MzJaMC8GCSqGSIb3DQEJBDEiBCCLWlfG
# tU/oeiaKqj/b7yI7MRZngEZ3iWXeRV8uIF8BtjANBgkqhkiG9w0BAQEFAASCAgB+
# 3MpehpPQPJYqjYhCoTeh/5eHCzvQmQyAeMZJgyX6sFFtwiJ7J/SI9QBj5teJewwW
# RvWOArBvbU/5G/NTk83Xgx+Ts778vdEBcvrCorOw2beiRgd/vTUAPECneSAilXsu
# c9TaMk1/3e1D02nEvgM1rPtA5qRKU6tDmHk+RCObNUfnCwvy7EQ06e+oHnZ2cRyo
# RbHvYH6NYnWCuFGHIdcrP7a5BM40e6f5j6PQ8hTeEMnrLsDLV3xBMf8IvqSPZ1No
# 8PV1975d3wtyoOa4xygE10p8pQBl+FEFOWgAODEebn2zbV7WEd25lfsXZSpcgjEE
# Xo9P9jrFspMEgcF5TaSywLznqAVF2Amdb604pOZ453X8jI0RDWCg43KUArJeezn8
# ALbvBEcanjJ0YI3Gip+1iKNQlUo/iv8pe1w4eW92FpKs7YCCHHmHPeyQI+SLrzT4
# A73zFuhQiU9X+0CIutAZVkOeRtLWygBQnSUdl+Qtd0rrXPhRRnZLVJF2TMXUZFEb
# WFotE7UGEPXolDj0DPm3iO1Ftwl3cECXnZo87wrwmVRSqqCWV1JhuCSh2CEUii2y
# 1gm1wJgZJNKerVOGttMhzn2Eo3xfi8pWMZXUckpmqKvJewrPIlrYzmWV9wvXJGVc
# YRz4QJITbYQC6d/XS2h6pgEs7yCaVudi+3VYrmUv/A==
# SIG # End signature block
