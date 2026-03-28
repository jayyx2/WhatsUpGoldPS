<#
.SYNOPSIS
    Registers Windows Scheduled Tasks for automated discovery execution.

.DESCRIPTION
    Creates Windows Scheduled Tasks that run Setup-*-Discovery.ps1 scripts
    (or Invoke-WUGDiscoveryRunner.ps1) on a recurring schedule, fully
    non-interactive using DPAPI vault credentials.

    IMPORTANT — DPAPI Constraint:
      The scheduled task MUST run as the same Windows user account that
      originally populated the DPAPI credential vault (interactively).
      The task must also run on the same machine. DPAPI encryption is
      tied to the user profile + machine key.

    Typical Workflow:
      1. Run Setup-*-Discovery.ps1 interactively once to populate the vault
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
    [ValidateSet('AWS', 'Azure', 'F5', 'Fortinet', 'HyperV', 'Proxmox', 'VMware')]
    [string]$Provider,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'Dashboard', 'ShowTable', 'None')]
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
    [ValidateSet('AWS', 'Azure', 'F5', 'Fortinet', 'HyperV', 'Proxmox', 'VMware')]
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
    F5       = Join-Path $discoveryDir 'Setup-F5-Discovery.ps1'
    Fortinet = Join-Path $discoveryDir 'Setup-Fortinet-Discovery.ps1'
    HyperV   = Join-Path $discoveryDir 'Setup-HyperV-Discovery.ps1'
    Proxmox  = Join-Path $discoveryDir 'Setup-Proxmox-Discovery.ps1'
    VMware   = Join-Path $discoveryDir 'Setup-VMware-Discovery.ps1'
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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
    }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $logDir = Join-Path $OutputPath 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
    }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $logDir = Join-Path $OutputPath 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

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
    -RunLevel Highest

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
