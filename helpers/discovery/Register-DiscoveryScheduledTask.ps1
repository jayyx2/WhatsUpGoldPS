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
    [ValidateSet('AWS', 'Azure', 'Bigleaf', 'Docker', 'F5', 'Fortinet', 'GCP', 'HyperV', 'Nutanix', 'OCI', 'Proxmox', 'VMware')]
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
    [ValidateSet('AWS', 'Azure', 'Bigleaf', 'Docker', 'F5', 'Fortinet', 'GCP', 'HyperV', 'Nutanix', 'OCI', 'Proxmox', 'VMware')]
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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
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
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAu+/QZFwo+mQQW
# ZoDjbT2y88FcgcZqeUa5CvP/LsOUmqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgtcgiWhRJ3z3r4327+4d76Y++Ic0TqJeR
# 5z7PmfkyHW4wDQYJKoZIhvcNAQEBBQAEggIAXRD/yFu5BZnzd6ME4IpgWv17iWxO
# 6+WIuI0baBLMVoWzsJDjsV8gDZM4ogwu0dB9GqCRikv1w0Wtj2nECC4ge2frzR+/
# BEPrxoZWM3LA58ReNpDkAtxx+9kKW9iUAhm56jACtPZEWQ1CzNjKqiDO/zUyqCur
# DJA/W/sXDdwMylFRdIodbBwBnnUAa3cTz0ejPTMd2xHWAx/M246+1f7NR5FmtWV0
# Ng9faedUjcE71lrdsBcZPZ18uVNXf467yRX+g2seBRuJUo6lJBQltU/5zbZsR8wn
# qfgxoNQ3MWRGk1k9fPgjc8CYIhuBnQIUgELKhg5axnytrPE1jhuvOitGWmc4/LAg
# PqLvH28I3pgbqnZpUBVx/A41L09Um1XFFtLgve0eA+UT4KQP17zn4NuILO4svSt7
# twhZwN4GMncx+pVa9TFpkaO4NcAT1j4Yzbquz8QEPXlPvhXTymZqzk2WSxI2LaD1
# lO0vRpH1aHSDCUGxLO4GjOcUyAeHd2Q0/gZqVvH9ygxtQ3C+qukphdIedA31zcW0
# Y1aOCAzPwWiSufXhXaX2Hc23kszW7thwVNYc2oo6B2R49VwBOWZ3LkpWKDt7st3l
# bOe0d7uEqekh9ZNzNgnQU8IrgIuYC8AE1pVXaaUk/2qJ+C2twaihy5y7a6lA35xM
# IXLWiqi6O4M77F4=
# SIG # End signature block
