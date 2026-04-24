<#
.SYNOPSIS
    Registers Windows Scheduled Tasks for automated discovery execution.

.DESCRIPTION
    Creates Windows Scheduled Tasks that run Setup-*-Discovery.ps1 scripts
    (or Invoke-WUGDiscoveryRunner.ps1) on a recurring schedule, fully
    non-interactive using DPAPI vault credentials.

    NOTE: For first-time setup, use Start-WUGDiscoverySetup.ps1 instead.
    That interactive wizard handles provider selection, credential configuration,
    test runs, and calls this script automatically to register scheduled tasks.
    Use this script directly only for advanced scenarios or automation.

    IMPORTANT -- DPAPI Constraint:
      The scheduled task MUST run as the same Windows user account that
      originally populated the DPAPI credential vault (interactively).
      The task must also run on the same machine. DPAPI encryption is
      tied to the user profile + machine key.

    Typical Workflow:
      1. Run Start-WUGDiscoverySetup.ps1 (recommended) OR
         Run Setup-*-Discovery.ps1 interactively once to populate the vault
      2. Run this script to register the scheduled task
      3. The task fires on schedule, reads vault creds, runs discovery silently

    Three Modes:
      - Provider   : Register a task for a single Setup-*-Discovery.ps1
      - Runner     : Register a task for Invoke-WUGDiscoveryRunner.ps1 (all providers)
      - WUGAction  : (Info only) Prints instructions for WUG Action Policy setup

.PARAMETER Mode
    'Provider' to schedule a single provider script.
    'Runner'   to schedule the full discovery runner.
    'WUGAction' to display WUG Action Policy setup instructions.

.PARAMETER Provider
    Which provider to schedule. Required when Mode = 'Provider'.
    Valid: AWS, Azure, F5, Fortinet, HyperV, Proxmox, VMware.

.PARAMETER Action
    What the discovery script should do.
    Valid: PushToWUG, ExportJSON, ExportCSV, Dashboard, ShowTable, None.
    Default: PushToWUG.

.PARAMETER Target
    Target host(s)/region(s) to pass to the provider.
    Required for most providers when Mode = 'Provider'.

.PARAMETER TaskName
    Windows Task Scheduler task name. Auto-generated if omitted.
    Example: 'DiscoverySync-Proxmox'

.PARAMETER TriggerType
    Schedule frequency: Daily, Hourly, AtStartup, Once.
    Default: Daily.

.PARAMETER TimeOfDay
    Time to run (HH:mm format). Default: '02:00' (2 AM).

.PARAMETER RepeatIntervalMinutes
    For 'Hourly' trigger: repeat interval in minutes.
    Default: 60.

.PARAMETER WUGServer
    WhatsUp Gold server address (passed through to the discovery script).

.PARAMETER RunnerProviders
    When Mode = 'Runner', which providers to include.
    Example: -RunnerProviders Proxmox,HyperV
    Default: all providers.

.PARAMETER AuthMethod
    Authentication method to pass through to the provider script.
    Currently used by Proxmox: 'Token' (API token) or 'Password' (username+password).
    Default: not specified (provider's own default is used).

.PARAMETER OutputPath
    Output directory for Runner mode. Default: $env:TEMP\DiscoveryRunner.

.PARAMETER TaskFolder
    Task Scheduler folder to create the task in. Default: '\WhatsUpGoldPS'.

.PARAMETER RunNow
    After registering the task, immediately execute the discovery in the
    current console so you can see output and verify it works. The task
    is still registered for future scheduled runs.

.PARAMETER Show
    List all existing WhatsUpGoldPS scheduled tasks and exit.

.PARAMETER Remove
    Remove an existing scheduled task by name and exit.

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Proxmox `
        -Target '192.168.1.39' -Action Dashboard -RunNow

    Registers the task AND runs it immediately — you see all output live.

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Proxmox `
        -Target '192.168.1.39' -Action PushToWUG -TriggerType Daily -TimeOfDay '03:00'

    Registers a daily 3 AM task that discovers Proxmox and pushes to WUG.

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Mode Runner -TriggerType Hourly `
        -RepeatIntervalMinutes 120 -RunnerProviders Proxmox,HyperV,VMware

    Runs the full discovery runner every 2 hours for 3 providers.

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Mode WUGAction

    Prints step-by-step instructions for setting up a WUG Recurring Action
    (Active Script Monitor or "Execute Program" Action Policy).

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Show

    Lists all scheduled tasks under the \WhatsUpGoldPS folder.

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Remove 'DiscoverySync-Proxmox'

    Removes the named scheduled task.

.NOTES
    Author  : jason@wug.ninja
    Created : 2025-07-14
    Requires: PowerShell 5.1+, Administrator rights for task registration
#>
[CmdletBinding(DefaultParameterSetName = 'Register')]
param(
    [Parameter(ParameterSetName = 'Register', Mandatory)]
    [ValidateSet('Provider', 'Runner', 'WUGAction')]
    [string]$Mode,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('AWS', 'Azure', 'Bigleaf', 'Docker', 'F5', 'Fortinet', 'GCP', 'HyperV', 'Nutanix', 'OCI', 'Proxmox', 'VMware', 'WindowsAttributes', 'WindowsDiskIO')]
    [string]$Provider,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'Dashboard', 'DashboardAndPush', 'ShowTable', 'None')]
    [string]$Action = 'PushToWUG',

    [Parameter(ParameterSetName = 'Register')]
    [string[]]$Target,

    [Parameter(ParameterSetName = 'Register')]
    [string]$TaskName,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('Daily', 'Hourly', 'AtStartup', 'Once')]
    [string]$TriggerType = 'Daily',

    [Parameter(ParameterSetName = 'Register')]
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$TimeOfDay = '02:00',

    [Parameter(ParameterSetName = 'Register')]
    [ValidateRange(5, 1440)]
    [int]$RepeatIntervalMinutes = 60,

    [Parameter(ParameterSetName = 'Register')]
    [string]$WUGServer,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('AWS', 'Azure', 'Bigleaf', 'Docker', 'F5', 'Fortinet', 'GCP', 'HyperV', 'Nutanix', 'OCI', 'Proxmox', 'VMware', 'WindowsAttributes', 'WindowsDiskIO')]
    [string[]]$RunnerProviders,

    [Parameter(ParameterSetName = 'Register')]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('Token', 'Password')]
    [string]$AuthMethod,

    [Parameter(ParameterSetName = 'Register')]
    [string]$TaskFolder = '\WhatsUpGoldPS',

    [Parameter(ParameterSetName = 'Register')]
    [switch]$RunNow,

    [Parameter(ParameterSetName = 'Show')]
    [switch]$Show,

    [Parameter(ParameterSetName = 'Remove')]
    [string]$Remove
)

# ============================================================================
# region  Paths
# ============================================================================
$scriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryDir = $scriptDir
$testDir      = Join-Path (Split-Path $scriptDir -Parent) 'test'
$runnerScript = Join-Path $testDir 'Invoke-WUGDiscoveryRunner.ps1'

$providerScripts = @{
    AWS      = Join-Path $discoveryDir 'Setup-AWS-Discovery.ps1'
    Azure    = Join-Path $discoveryDir 'Setup-Azure-Discovery.ps1'
    Bigleaf  = Join-Path $discoveryDir 'Setup-Bigleaf-Discovery.ps1'
    Docker   = Join-Path $discoveryDir 'Setup-Docker-Discovery.ps1'
    F5       = Join-Path $discoveryDir 'Setup-F5-Discovery.ps1'
    Fortinet = Join-Path $discoveryDir 'Setup-Fortinet-Discovery.ps1'
    GCP      = Join-Path $discoveryDir 'Setup-GCP-Discovery.ps1'
    HyperV   = Join-Path $discoveryDir 'Setup-HyperV-Discovery.ps1'
    Nutanix  = Join-Path $discoveryDir 'Setup-Nutanix-Discovery.ps1'
    OCI      = Join-Path $discoveryDir 'Setup-OCI-Discovery.ps1'
    Proxmox  = Join-Path $discoveryDir 'Setup-Proxmox-Discovery.ps1'
    VMware   = Join-Path $discoveryDir 'Setup-VMware-Discovery.ps1'
    WindowsAttributes = Join-Path $discoveryDir 'Setup-WindowsAttributes-Discovery.ps1'
    WindowsDiskIO = Join-Path $discoveryDir 'Setup-WindowsDiskIO-Discovery.ps1'
}

# Restrict a directory's ACL to current user + SYSTEM + Administrators
function Set-RestrictedDirectoryAcl {
    param([string]$Path)
    try {
        $item = Get-Item $Path
        $acl = $item.GetAccessControl()
        $acl.SetAccessRuleProtection($true, $false)
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($systemRule)
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($userRule)
        $item.SetAccessControl($acl)
    }
    catch { Write-Verbose "Could not restrict ACL on ${Path}: $_" }
}
# endregion

# ============================================================================
# region  Show — list existing tasks
# ============================================================================
if ($Show) {
    Write-Host ''
    Write-Host '  Scheduled Tasks in \WhatsUpGoldPS:' -ForegroundColor Cyan
    Write-Host '  -----------------------------------' -ForegroundColor DarkCyan
    try {
        $tasks = Get-ScheduledTask -TaskPath "$TaskFolder\" -ErrorAction Stop
        if ($tasks.Count -eq 0) {
            Write-Host '  (none)' -ForegroundColor Yellow
        }
        else {
            foreach ($t in $tasks) {
                $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
                $lastRun = if ($info.LastRunTime -and $info.LastRunTime -ne [datetime]::MinValue) {
                    $info.LastRunTime.ToString('yyyy-MM-dd HH:mm')
                } else { '(never)' }
                $nextRun = if ($info.NextRunTime -and $info.NextRunTime -ne [datetime]::MinValue) {
                    $info.NextRunTime.ToString('yyyy-MM-dd HH:mm')
                } else { '(none)' }
                Write-Host "  $($t.TaskName)" -ForegroundColor White -NoNewline
                Write-Host "  State=$($t.State)  Last=$lastRun  Next=$nextRun" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Host '  No tasks found (folder may not exist yet).' -ForegroundColor Yellow
    }
    Write-Host ''
    return
}
# endregion

# ============================================================================
# region  Remove — delete a task
# ============================================================================
if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $Remove -TaskPath "$TaskFolder\" -Confirm:$false -ErrorAction Stop
        Write-Host "  Removed task: $Remove" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to remove task '$Remove': $_"
    }
    return
}
# endregion

# ============================================================================
# region  WUGAction — print instructions
# ============================================================================
if ($Mode -eq 'WUGAction') {
    Write-Host ''
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host '   Running Discovery from a WhatsUp Gold Action Policy' -ForegroundColor Cyan
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  WhatsUp Gold can execute scripts via two mechanisms:' -ForegroundColor White
    Write-Host ''
    Write-Host '  --- Option A: Active Script Monitor (Recurring) ---' -ForegroundColor Yellow
    Write-Host '  1. In WUG Console, go to Settings > Libraries > Active Script Monitors' -ForegroundColor White
    Write-Host '  2. Add a new Active Script monitor (PowerShell type)' -ForegroundColor White
    Write-Host '  3. Set the script body to:' -ForegroundColor White
    Write-Host ''
    Write-Host '     $scriptPath = "PATH\TO\Setup-Proxmox-Discovery.ps1"' -ForegroundColor Gray
    Write-Host '     & $scriptPath -Target "192.168.1.39" -Action PushToWUG -NonInteractive' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  4. Assign the monitor to ANY device (the WUG server itself works)' -ForegroundColor White
    Write-Host '  5. Set the polling interval to your desired frequency' -ForegroundColor White
    Write-Host '     (e.g. 3600 seconds = hourly, 86400 = daily)' -ForegroundColor White
    Write-Host ''
    Write-Host '  IMPORTANT: WUG runs script monitors under the WUG service account' -ForegroundColor Red
    Write-Host '  (usually SYSTEM or a dedicated service account). The DPAPI vault' -ForegroundColor Red
    Write-Host '  must be populated by THAT account, or use an AES vault password:' -ForegroundColor Red
    Write-Host ''
    Write-Host '    # Run as the WUG service account to populate the vault:' -ForegroundColor Gray
    Write-Host '    PsExec -s -i powershell.exe  # Opens PS as SYSTEM' -ForegroundColor Gray
    Write-Host '    .\Setup-Proxmox-Discovery.ps1  # Interactive, populates vault' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    # OR use Set-DiscoveryVaultPassword to add AES layer that' -ForegroundColor Gray
    Write-Host '    # makes the vault portable across accounts (must load helpers first):' -ForegroundColor Gray
    Write-Host '    . .\DiscoveryHelpers.ps1' -ForegroundColor Gray
    Write-Host '    Set-DiscoveryVaultPassword  # Sets shared AES key' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  --- Option B: Action Policy "Execute Program" (Event-driven) ---' -ForegroundColor Yellow
    Write-Host '  1. Go to Settings > Actions and Policies > Action Policies' -ForegroundColor White
    Write-Host '  2. Create or edit an Action Policy' -ForegroundColor White
    Write-Host '  3. Add action: "Execute a Program"' -ForegroundColor White
    Write-Host '  4. Program: powershell.exe' -ForegroundColor White
    Write-Host '  5. Arguments:' -ForegroundColor White
    Write-Host '     -NoProfile -ExecutionPolicy Bypass -File "PATH\TO\Setup-Proxmox-Discovery.ps1" -Target "192.168.1.39" -Action PushToWUG -NonInteractive' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  6. Assign this Action Policy to any monitor on any device' -ForegroundColor White
    Write-Host '  7. The discovery runs whenever that monitor transitions state' -ForegroundColor White
    Write-Host '     (best paired with a simple Ping monitor on a reliable host)' -ForegroundColor White
    Write-Host ''
    Write-Host '  --- Option C: Full Runner via Execute Program ---' -ForegroundColor Yellow
    Write-Host '  Arguments for the full multi-provider runner:' -ForegroundColor White
    Write-Host '     -NoProfile -ExecutionPolicy Bypass -File "PATH\TO\Invoke-WUGDiscoveryRunner.ps1" -NonInteractive -RunProxmox 1 -RunHyperV 1' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host ''
    return
}
# endregion

# ============================================================================
# region  Validation
# ============================================================================
if ($Mode -eq 'Provider' -and -not $Provider) {
    Write-Error '-Provider is required when Mode is Provider. Valid: AWS, Azure, F5, Fortinet, HyperV, Proxmox, VMware.'
    return
}

if ($Mode -eq 'Provider') {
    $scriptPath = $providerScripts[$Provider]
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Provider script not found: $scriptPath"
        return
    }
}

if ($Mode -eq 'Runner' -and -not (Test-Path $runnerScript)) {
    Write-Error "Runner script not found: $runnerScript"
    return
}
# endregion

# ============================================================================
# region  Build PowerShell Arguments
# ============================================================================
if ($Mode -eq 'Provider') {
    $scriptPath = $providerScripts[$Provider]

    # --- Resolve output path (must be known before building args) ---
    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    }
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Set-RestrictedDirectoryAcl -Path $OutputPath
    }
    $logDir = Join-Path $OutputPath 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Set-RestrictedDirectoryAcl -Path $logDir
    }

    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""

    if ($Target) {
        # Pass targets as comma-separated for string[] params
        $targetStr = ($Target | ForEach-Object { "'$_'" }) -join ','
        $psArgs += " -Target $targetStr"
    }
    if ($Action) {
        $psArgs += " -Action $Action"
    }
    if ($WUGServer) {
        $psArgs += " -WUGServer '$WUGServer'"
    }
    if ($OutputPath) {
        $psArgs += " -OutputPath '$OutputPath'"
    }
    if ($AuthMethod) {
        $psArgs += " -AuthMethod $AuthMethod"
    }
    $psArgs += ' -NonInteractive'

    if (-not $TaskName) {
        $TaskName = "DiscoverySync-$Provider"
    }
}
elseif ($Mode -eq 'Runner') {
    # --- Resolve output path ---
    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    }
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Set-RestrictedDirectoryAcl -Path $OutputPath
    }
    $logDir = Join-Path $OutputPath 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Set-RestrictedDirectoryAcl -Path $logDir
    }

    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerScript`""
    $psArgs += ' -NonInteractive'

    if ($RunnerProviders) {
        foreach ($rp in $RunnerProviders) {
            $psArgs += " -Run$rp 1"
        }
    }

    if ($OutputPath) {
        $psArgs += " -OutputPath '$OutputPath'"
    }

    if (-not $TaskName) {
        if ($RunnerProviders) {
            $TaskName = "DiscoveryRunner-$($RunnerProviders -join '-')"
        }
        else {
            $TaskName = 'DiscoveryRunner-All'
        }
    }
}
# endregion

# ============================================================================
# region  Build Trigger
# ============================================================================
$timeParts = $TimeOfDay -split ':'
$startTime = (Get-Date -Hour ([int]$timeParts[0]) -Minute ([int]$timeParts[1]) -Second 0)

switch ($TriggerType) {
    'Daily' {
        $trigger = New-ScheduledTaskTrigger -Daily -At $startTime
    }
    'Hourly' {
        # Daily trigger with repetition interval
        $trigger = New-ScheduledTaskTrigger -Once -At $startTime `
            -RepetitionInterval (New-TimeSpan -Minutes $RepeatIntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 365)
    }
    'AtStartup' {
        $trigger = New-ScheduledTaskTrigger -AtStartup
    }
    'Once' {
        $trigger = New-ScheduledTaskTrigger -Once -At $startTime
    }
}
# endregion

# ============================================================================
# region  Build Task Action + Settings
# ============================================================================
# Build a -Command that starts a transcript, runs the script, then stops.
# The log file gets a timestamp so every run has its own log.
$transcriptCmd = @"
`$logFile = Join-Path '$logDir' ('${TaskName}_' + (Get-Date -Format yyyyMMdd_HHmmss) + '.log')
Start-Transcript -Path `$logFile -Force
try { & powershell.exe $psArgs }
finally { Stop-Transcript }
"@
# Collapse to one line for -Command
$oneLiner = ($transcriptCmd -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join '; '
$wrapperArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$oneLiner`""

$taskAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $wrapperArgs `
    -WorkingDirectory $discoveryDir

$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType S4U `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -MultipleInstances IgnoreNew
# endregion

# ============================================================================
# region  Register Task
# ============================================================================
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host '   Register Discovery Scheduled Task' -ForegroundColor Cyan
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host "   Task Name : $TaskName" -ForegroundColor White
Write-Host "   Folder    : $TaskFolder" -ForegroundColor White
Write-Host "   Trigger   : $TriggerType $(if ($TriggerType -eq 'Hourly') { "every ${RepeatIntervalMinutes}min" } else { "at $TimeOfDay" })" -ForegroundColor White
Write-Host "   Script    : $(if ($Mode -eq 'Provider') { $providerScripts[$Provider] } else { $runnerScript })" -ForegroundColor White
Write-Host "   Arguments : $psArgs" -ForegroundColor DarkGray
Write-Host "   Output    : $OutputPath" -ForegroundColor White
Write-Host "   Logs      : $logDir" -ForegroundColor White
Write-Host "   Run As    : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor White
Write-Host "   RunNow    : $RunNow" -ForegroundColor $(if ($RunNow) { 'Green' } else { 'DarkGray' })
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host ''

try {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskFolder `
        -Action $taskAction `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force `
        -ErrorAction Stop | Out-Null

    Write-Host "  Task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "  Output dir : $OutputPath" -ForegroundColor White
    Write-Host "  Log dir    : $logDir" -ForegroundColor White
    Write-Host ''

    if ($RunNow) {
        # Start transcript so RunNow also leaves a log
        $runLogFile = Join-Path $logDir "${TaskName}_$(Get-Date -Format yyyyMMdd_HHmmss).log"
        Start-Transcript -Path $runLogFile -Force | Out-Null

        Write-Host '  -RunNow specified — executing discovery now (in this console)...' -ForegroundColor Yellow
        Write-Host '  =================================================================' -ForegroundColor DarkCyan
        Write-Host ''

        # Execute the SAME script directly so user sees all output live
        $runArgs = @{}
        try {
            if ($Mode -eq 'Provider') {
                if ($Target)     { $runArgs['Target']     = $Target }
                if ($Action)     { $runArgs['Action']     = $Action }
                if ($WUGServer)  { $runArgs['WUGServer']  = $WUGServer }
                if ($AuthMethod) { $runArgs['AuthMethod'] = $AuthMethod }
                $runArgs['OutputPath']     = $OutputPath
                $runArgs['NonInteractive'] = $true
                & $providerScripts[$Provider] @runArgs
            }
            elseif ($Mode -eq 'Runner') {
                $runArgs['NonInteractive'] = $true
                if ($OutputPath) { $runArgs['OutputPath'] = $OutputPath }
                if ($RunnerProviders) {
                    foreach ($rp in $RunnerProviders) {
                        $runArgs["Run$rp"] = $true
                    }
                }
                & $runnerScript @runArgs
            }
        }
        finally {
            Stop-Transcript | Out-Null
        }

        Write-Host ''
        Write-Host '  =================================================================' -ForegroundColor DarkCyan
        Write-Host '  RunNow complete. Check output:' -ForegroundColor Green
        Write-Host "    $OutputPath" -ForegroundColor Cyan
        Write-Host "  Log written to:" -ForegroundColor White
        Write-Host "    $runLogFile" -ForegroundColor Cyan
        Write-Host ''
    }
    else {
        Write-Host '  Verify with:' -ForegroundColor White
        Write-Host "    Get-ScheduledTask -TaskPath '$TaskFolder\' | Format-Table TaskName, State" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Run it now (test):' -ForegroundColor White
        Write-Host "    .\Register-DiscoveryScheduledTask.ps1 -Mode $Mode $(if($Provider){"-Provider $Provider "})$(if($Target){"-Target '$($Target -join "','")' "})$(if($Action){"-Action $Action "})-RunNow" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Or via Task Scheduler:' -ForegroundColor White
        Write-Host "    Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskFolder\'" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  View last log:' -ForegroundColor White
        Write-Host "    Get-ChildItem '$logDir' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content" -ForegroundColor Gray
        Write-Host ''
    }
}
catch {
    Write-Error "Failed to register scheduled task: $_"
    Write-Host ''
    Write-Host '  If "Access Denied", run this script as Administrator.' -ForegroundColor Yellow
    Write-Host '  The task runs as YOUR account (for DPAPI vault access).' -ForegroundColor Yellow
    Write-Host ''
}
# endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB11MK3YjOtmK+4
# uo7ZjWToY06bAKhdq+oRUXsTmRz316CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCB6eUzEQJ0Nup+2ma23JaN8734U0JKLKk5H8esWCpH6oDANBgkqhkiG9w0BAQEF
# AASCAgC3jriTFW9OXQ04BYya3M0AmkEK22444/Qa0+Tdm46splJQxs1r1t6K5DdX
# uY4OSqTKKxqTCjIkor8N+97neelwAJAcViaG+KBzzpGCAp2CCIPChu82Rt29a0he
# +ajn7gnzIsjPAFGpW1ynkmjDL0WwjENIrWyu1XxkK4b4/iiSKXUk5t4cWUPYTQvA
# ncMENZz7GVw4/e337+89zx08FwKFRThEjih3ahmZ6OFQMpMy1SaSdGZZezI4r891
# ftv3E0Hezh3sccmgpchgZvu3z0l2pYY9R0HLwOmJih1ofp0MWSlexgkoOVFTs18Y
# l606mZt7nXHK4CElEiC5h/6sBlU6Lx3Nh/zNY0qNLGf6Eq0XPuBvUzycQ0y2J0ef
# U4Ln4ITzUcZyY51QSTeGipO3GRKNRcEhSKxydHYDoCmO9yO2VwiPZB69NBmoI6ru
# +fvB4y2xoTfaB2q+WziRu+NCca31rgYH72tWW4aIAbT8NLH64afvmlMl/ti+hhr/
# xTWcIqP+Qs19t7smF8Psdgb+wkaj2lCdjS8N6Gb8L3pskohJpNnQZmoI7fjsdZ4T
# Ks/hICeuoHwseHIy3gDSbtru0moufnZ6IR9xTd1GS90yLUjcVH44EXlKEdhDXuIL
# L31SWSMGe+TpJ9erb/e4PjULQtDvSZzHmz0XbuYTMt5aIYJ5NqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MTgxNzE0NDBaMC8GCSqGSIb3DQEJBDEiBCAr5fV8
# ixiWECXwN3fYEYynKQOIF/+o2IyJkoJ6AXlK1DANBgkqhkiG9w0BAQEFAASCAgA+
# TStGU8B4R9Aa90Ya6a8+UOJ/HxpX+jTHxhEruENqLSA/Axil25E/v1UN1f21vjIK
# wNRVuY0BSXq5Eq73TMv6Eg6bW6a42pY5f642hXD/FoU/0vR0Kk81+SmJYkzBIz9Z
# lypLeQ7V77MkZqL5kSEfs4DrdPRwH12zDXvf0D+HSCSYuSoIfqsc2EaSmDgJffhV
# cHs+flZr18wJJ+u87xxgCVG0yy6aS+x1uWKDKWBhwROUVZxyUhzKNGW06gnB5KKx
# enGv3GBMCke5N+QYzmhEpAK7Lp5qKp6OSXf+lf2cAr45/AW1Qb7FDPQ53BT0KeyN
# 3ZpLpIrHW/YHW0Kn5Py580Ri2zhdUJt6azb1oUoLHGIWmQXpHt/E71hub12KUaA8
# L+uUf45J+OWMOjktzrpbUhhtF8wehedbNknawBMXJw9qt+mJg2ym+5tha4UF8olH
# GL1F7ugb6wsRiuv7zIwMaMCHxp7hr0aW2scpa1yilE5JWfN9Ua8PbgiiFooLXzEw
# X9eTTVgdHThHG2xZTDdbDppjU8K28D0spfa7DRbZZ2iFTkPZlgpJUy957WgrtXdz
# r9DhHAdNU94slJ9c00q0ypnio9tuNbXRwSRuPp9l7BedCN0M1prgvppuCQuusUSu
# 68K3lo6Ok8+5wPS1xRSWZQGkllseSyA9MwCZ99ideg==
# SIG # End signature block
