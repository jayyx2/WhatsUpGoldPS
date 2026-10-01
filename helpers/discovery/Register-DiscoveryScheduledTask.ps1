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
    Valid: any Setup-*-Discovery.ps1 provider listed in the ValidateSet.

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
        -Target '192.168.1.30' -Action Dashboard -RunNow

    Registers the task AND runs it immediately — you see all output live.

.EXAMPLE
    .\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Proxmox `
        -Target '192.168.1.30' -Action PushToWUG -TriggerType Daily -TimeOfDay '03:00'

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
    [ValidateSet('AWS', 'Azure', 'Bigleaf', 'Certificates', 'CiscoWLC', 'ConfigDrift', 'CUCM', 'Docker', 'F5', 'Fortinet', 'GCP', 'HyperV', 'Linux', 'LoadMaster', 'MSCluster', 'MSSQL', 'NetworkNeighbors', 'Nutanix', 'NvidiaSmi', 'OCI', 'Proxmox', 'Redfish', 'UniFi', 'VMware', 'WindowsAttributes', 'WindowsDiskIO')]
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
    [ValidateSet('AWS', 'Azure', 'Bigleaf', 'CiscoWLC', 'CUCM', 'Docker', 'F5', 'Fortinet', 'GCP', 'HyperV', 'LoadMaster', 'MSSQL', 'Nutanix', 'NvidiaSmi', 'OCI', 'Proxmox', 'VMware', 'WindowsAttributes', 'WindowsDiskIO')]
    [string[]]$RunnerProviders,

    [Parameter(ParameterSetName = 'Register')]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('Token', 'Password', 'ApiKey', 'SnmpV2', 'SnmpV3')]
    [string]$AuthMethod,

    [Parameter(ParameterSetName = 'Register')]
    [string]$TaskFolder = '\WhatsUpGoldPS',

    [Parameter(ParameterSetName = 'Register')]
    [switch]$RunNow,

    # Populate and use the LocalMachine DPAPI vault so the task can run as
    # SYSTEM with no user logged in. Walks you through credential entry first.
    [Parameter(ParameterSetName = 'Register')]
    [switch]$UseSystemVault,

    # Skip the interactive vault population step. Use this when you have
    # already populated the vault (e.g. via Initialize-WUGDiscoveryVault.ps1)
    # and only want to register the task.
    [Parameter(ParameterSetName = 'Register')]
    [switch]$SkipVaultPopulate,

    # PowerShell execution policy passed to the scheduled task's powershell.exe.
    # Default: Bypass (works on most systems).
    # Use RemoteSigned if your environment blocks Bypass via Group Policy
    # (scripts in Program Files are local and satisfy RemoteSigned).
    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('Bypass', 'RemoteSigned', 'Unrestricted', 'AllSigned')]
    [string]$ExecutionPolicy = 'RemoteSigned',

    # Use a plain-text wrapper .ps1 file instead of -EncodedCommand.
    # Some endpoint security products (TrendMicro, CrowdStrike, etc.) block
    # -EncodedCommand by default. This switch writes the task wrapper to a
    # .ps1 file in the output/logs directory and invokes it with -File.
    [Parameter(ParameterSetName = 'Register')]
    [Alias('NoEncodedCommand')]
    [switch]$UseEncodedCommand,

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
    Certificates = Join-Path $discoveryDir 'Setup-Certificates-Discovery.ps1'
    CiscoWLC = Join-Path $discoveryDir 'Setup-CiscoWLC-Discovery.ps1'
    ConfigDrift = Join-Path $discoveryDir 'Setup-ConfigDrift-Discovery.ps1'
    CUCM     = Join-Path $discoveryDir 'Setup-CUCM-Discovery.ps1'
    Docker   = Join-Path $discoveryDir 'Setup-Docker-Discovery.ps1'
    F5       = Join-Path $discoveryDir 'Setup-F5-Discovery.ps1'
    Fortinet = Join-Path $discoveryDir 'Setup-Fortinet-Discovery.ps1'
    GCP      = Join-Path $discoveryDir 'Setup-GCP-Discovery.ps1'
    HyperV   = Join-Path $discoveryDir 'Setup-HyperV-Discovery.ps1'
    Linux    = Join-Path $discoveryDir 'Setup-Linux-Discovery.ps1'
    LoadMaster = Join-Path $discoveryDir 'Setup-LoadMaster-Discovery.ps1'
    MSCluster = Join-Path $discoveryDir 'Setup-MSCluster-Discovery.ps1'
    MSSQL    = Join-Path $discoveryDir 'Setup-MSSQL-Discovery.ps1'
    NetworkNeighbors = Join-Path $discoveryDir 'Setup-NetworkNeighbors-Discovery.ps1'
    Nutanix  = Join-Path $discoveryDir 'Setup-Nutanix-Discovery.ps1'
    NvidiaSmi = Join-Path $discoveryDir 'Setup-NvidiaSmi-Discovery.ps1'
    OCI      = Join-Path $discoveryDir 'Setup-OCI-Discovery.ps1'
    Proxmox  = Join-Path $discoveryDir 'Setup-Proxmox-Discovery.ps1'
    Redfish  = Join-Path $discoveryDir 'Setup-Redfish-Discovery.ps1'
    UniFi    = Join-Path $discoveryDir 'Setup-UniFi-Discovery.ps1'
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
    Write-Host '     & $scriptPath -Target "192.168.1.30" -Action PushToWUG -NonInteractive' -ForegroundColor Gray
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
    Write-Host '     -NoProfile -ExecutionPolicy Bypass -File "PATH\TO\Setup-Proxmox-Discovery.ps1" -Target "192.168.1.30" -Action PushToWUG -NonInteractive' -ForegroundColor Gray
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
    Write-Error "-Provider is required when Mode is Provider. Valid: $((@($providerScripts.Keys) | Sort-Object) -join ', ')."
    return
}

if ($Mode -eq 'Provider') {
    $scriptPath = $providerScripts[$Provider]
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Provider script not found: $scriptPath"
        return
    }
    if ($Provider -eq 'UniFi' -and $Action -in @('PushToWUG', 'DashboardAndPush')) {
        Write-Error 'Scheduled UniFi WUG pushes are disabled because the scheduler cannot carry the required -AllowApiKeyInMonitorLibrary acknowledgement. Use the setup script directly for an explicitly approved push.'
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
        if ($UseSystemVault) {
            # SYSTEM cannot access %LOCALAPPDATA% — use ProgramData instead
            $OutputPath = Join-Path $env:ProgramData 'WhatsUpGoldPS\Output'
        }
        else {
            $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
        }
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

    # Build script-level arguments (no powershell.exe flags)
    # The script path is kept separate to avoid double-quote issues in -Command
    $scriptArgs = ''

    if ($Target) {
        $targetStr = ($Target | ForEach-Object { "'$_'" }) -join ','
        $scriptArgs += " -Target $targetStr"
    }
    if ($Action) {
        $scriptArgs += " -Action $Action"
    }
    if ($WUGServer) {
        $scriptArgs += " -WUGServer '$WUGServer'"
    }
    if ($OutputPath) {
        $scriptArgs += " -OutputPath '$OutputPath'"
    }
    if ($AuthMethod) {
        if ($Provider -in @('CUCM', 'CiscoWLC')) {
            # SNMP providers use -SnmpVersion instead of -AuthMethod
            $snmpVer = switch ($AuthMethod) { 'SnmpV2' { 2 } 'SnmpV3' { 3 } default { 2 } }
            $scriptArgs += " -SnmpVersion $snmpVer"
        }
        else {
            $scriptArgs += " -AuthMethod $AuthMethod"
        }
    }
    $scriptArgs += ' -NonInteractive'
    # Legacy $psArgs kept for display purposes
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy $ExecutionPolicy -File `"$scriptPath`"$scriptArgs"

    if (-not $TaskName) {
        $TaskName = "DiscoverySync-$Provider"
    }

    # ---- UseSystemVault: set LocalMachine vault scope and optionally populate ----
    if ($UseSystemVault) {
        Write-Host ''
        Write-Host '  =================================================================' -ForegroundColor DarkCyan
        Write-Host '   System Vault Setup (-UseSystemVault)' -ForegroundColor Cyan
        Write-Host '  =================================================================' -ForegroundColor DarkCyan
        Write-Host '  Task will run as SYSTEM using the LocalMachine DPAPI vault.' -ForegroundColor Yellow
        Write-Host "  Vault path: $(Join-Path $env:ProgramData 'WhatsUpGoldPS\Vault')" -ForegroundColor DarkGray
        Write-Host ''

        if ($SkipVaultPopulate) {
            Write-Host '  -SkipVaultPopulate: assuming vault is already populated.' -ForegroundColor DarkGray
            Write-Host '  Run Initialize-WUGDiscoveryVault.ps1 first if credentials are missing.' -ForegroundColor DarkGray
        }
        else {
            Write-Host '  Loading DiscoveryHelpers and switching to LocalMachine scope...' -ForegroundColor DarkGray
            . (Join-Path $discoveryDir 'DiscoveryHelpers.ps1')
            Set-DiscoveryVaultScope -Scope LocalMachine

            Write-Host ''
            Write-Host "  Running $Provider setup interactively to collect and store credentials..." -ForegroundColor Cyan
            Write-Host '  Answer the prompts -- credentials go into the LocalMachine vault.' -ForegroundColor Yellow
            Write-Host ''

            $vaultArgs = @{ Action = 'None' }
            if ($Target)     { $vaultArgs['Target']     = $Target }
            if ($WUGServer)  { $vaultArgs['WUGServer']  = $WUGServer }
            if ($AuthMethod) {
                if ($Provider -in @('CUCM', 'CiscoWLC')) {
                    $snmpVer = switch ($AuthMethod) { 'SnmpV2' { 2 } 'SnmpV3' { 3 } default { 2 } }
                    $vaultArgs['SnmpVersion'] = $snmpVer
                }
                else {
                    $vaultArgs['AuthMethod'] = $AuthMethod
                }
            }
            & $providerScripts[$Provider] @vaultArgs

            Write-Host ''
            Write-Host '  Vault populated. Registering task as SYSTEM...' -ForegroundColor Green
            Write-Host ''
        }
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

    # Build script-level arguments (no powershell.exe flags)
    $scriptPath = $runnerScript
    $scriptArgs = ' -NonInteractive'

    if ($RunnerProviders) {
        foreach ($rp in $RunnerProviders) {
            $scriptArgs += " -Run$rp 1"
        }
    }

    if ($OutputPath) {
        $scriptArgs += " -OutputPath '$OutputPath'"
    }
    # Legacy $psArgs kept for display purposes
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy $ExecutionPolicy -File `"$runnerScript`"$scriptArgs"

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
# Validate the script exists before encoding -- catches wrong path early.
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Error "Script not found at: $scriptPath -- task NOT registered."
    return
}

# Build the full command as a proper multi-line script, then encode as Base64
# for -EncodedCommand. This avoids ALL quoting issues with Task Scheduler.
#
# Wrapper design goals:
#   1. Always produce a log -- even if the main script crashes immediately.
#   2. Recreate the log directory if deleted since registration.
#   3. Log startup context (user, machine, PID, datetime, script+args) BEFORE
#      calling the script so there is always evidence the task actually fired.
#   4. Fall back to plain Out-File if Start-Transcript itself fails.
#   5. Report the script exit code explicitly at the bottom of every log.
$fullCommand = @"
`$ErrorActionPreference = 'Continue'
`$logDir  = '$logDir'
`$logBase = '${TaskName}_'

if (-not (Test-Path `$logDir)) {
    try { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null } catch {}
}
`$logFile = Join-Path `$logDir (`$logBase + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

`$transcriptStarted = `$false
try {
    Start-Transcript -Path `$logFile -Force | Out-Null
    `$transcriptStarted = `$true
} catch {
    try {
        `$msg = "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Start-Transcript FAILED: `$_``n" +
                "User=`$env:USERDOMAIN\`$env:USERNAME  Machine=`$env:COMPUTERNAME  PID=`$PID"
        `$msg | Out-File -FilePath `$logFile -Encoding UTF8 -Force
    } catch {}
}

$(if ($UseSystemVault) { "`$env:WUG_VAULT_SCOPE = 'LocalMachine'" })
Write-Host ''
Write-Host '=== Discovery Scheduled Task ==='
Write-Host 'Task     : ${TaskName}'
Write-Host 'Script   : $scriptPath'
Write-Host 'Args     :$scriptArgs'
Write-Host "Vault    : $(if ($UseSystemVault) { 'LocalMachine (SYSTEM-accessible)' } else { 'CurrentUser' })"
Write-Host "DateTime : `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "User     : `$env:USERDOMAIN\`$env:USERNAME"
Write-Host "Machine  : `$env:COMPUTERNAME"
Write-Host "PID      : `$PID"
Write-Host "WorkDir  : `$(Get-Location)"
Write-Host ''

`$exitCode = 0
try {
    & '$scriptPath'$scriptArgs
    if (`$LASTEXITCODE) { `$exitCode = `$LASTEXITCODE }
} catch {
    Write-Host "FATAL: `$_"
    Write-Host `$_.ScriptStackTrace
    `$exitCode = 1
}

Write-Host ''
Write-Host "Exit code : `$exitCode"
Write-Host "Completed : `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if (`$transcriptStarted) { try { Stop-Transcript } catch {} }
exit `$exitCode
"@

if ($UseEncodedCommand) {
    # Legacy: use -EncodedCommand (may be blocked by EDR products).
    $encodedBytes = [System.Text.Encoding]::Unicode.GetBytes($fullCommand)
    $encodedCommand = [Convert]::ToBase64String($encodedBytes)
    $wrapperArgs = "-NoProfile -NonInteractive -ExecutionPolicy $ExecutionPolicy -EncodedCommand $encodedCommand"
}
else {
    # Default: use the signed Invoke-DiscoveryTask.ps1 wrapper with -File.
    # Works with -ExecutionPolicy RemoteSigned because the wrapper is
    # Authenticode-signed as part of the module distribution.
    $taskRunner = Join-Path $discoveryDir 'Invoke-DiscoveryTask.ps1'
    if (-not (Test-Path -LiteralPath $taskRunner)) {
        Write-Warning "Invoke-DiscoveryTask.ps1 not found at: $taskRunner -- falling back to -EncodedCommand."
        $encodedBytes = [System.Text.Encoding]::Unicode.GetBytes($fullCommand)
        $encodedCommand = [Convert]::ToBase64String($encodedBytes)
        $wrapperArgs = "-NoProfile -NonInteractive -ExecutionPolicy $ExecutionPolicy -EncodedCommand $encodedCommand"
    }
    else {
        # Build the ScriptArgs string for the task runner (key=value;key=value)
        # Built directly from typed parameters to avoid quoting/parsing issues.
        $runnerParts = [System.Collections.Generic.List[string]]::new()
        if ($Target) {
            $runnerParts.Add("Target=$($Target -join ',')")
        }
        if ($Action) {
            $runnerParts.Add("Action=$Action")
        }
        if ($OutputPath) {
            $runnerParts.Add("OutputPath=$OutputPath")
        }
        if ($WUGServer) {
            $runnerParts.Add("WUGServer=$WUGServer")
        }
        if ($AuthMethod) {
            if ($Provider -in @('CUCM', 'CiscoWLC')) {
                $snmpVer = switch ($AuthMethod) { 'SnmpV2' { 2 } 'SnmpV3' { 3 } default { 2 } }
                $runnerParts.Add("SnmpVersion=$snmpVer")
            }
            else {
                $runnerParts.Add("AuthMethod=$AuthMethod")
            }
        }
        $runnerParts.Add("NonInteractive=true")
        $runnerScriptArgs = $runnerParts -join ';'

        $vaultArg = if ($UseSystemVault) { ' -VaultScope LocalMachine' } else { '' }
        $wrapperArgs = "-NoProfile -NonInteractive -ExecutionPolicy $ExecutionPolicy -File `"$taskRunner`" -Script `"$scriptPath`" -ScriptArgs `"$runnerScriptArgs`" -LogDir `"$logDir`" -TaskName `"$TaskName`"$vaultArg"
    }
}

$taskAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $wrapperArgs `
    -WorkingDirectory $discoveryDir

# Determine task principal (who the task runs as).
# SYSTEM only when -UseSystemVault is explicitly requested (requires admin + LocalMachine vault).
# Otherwise run as current user with S4U (or Interactive fallback).
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($UseSystemVault) {
    # SYSTEM runs whether logged in or not, uses LocalMachine DPAPI vault
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Limited
    $runAsLabel = 'SYSTEM (runs whether logged in or not)'
}
else {
    # Run as current user — uses their CurrentUser DPAPI vault.
    # Try S4U first (runs whether logged in or not, no password needed).
    # Falls back to Interactive if S4U is rejected (e.g., Microsoft accounts).
    $principal = $null
    try {
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Limited
    }
    catch {
        $principal = $null
    }
    if (-not $principal) {
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
        $runAsLabel = "$currentUser (runs only when logged in)"
    }
    else {
        $runAsLabel = "$currentUser (S4U, runs whether logged in or not)"
    }
}

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
Write-Host "   Script    : $scriptPath" -ForegroundColor White
Write-Host "   Args     : $scriptArgs" -ForegroundColor White
Write-Host "   Wrapper  : $(if ($wrapperArgs -match 'Invoke-DiscoveryTask') { 'Invoke-DiscoveryTask.ps1 (signed, -File)' } elseif ($wrapperArgs -match 'EncodedCommand') { '-EncodedCommand (legacy)' } else { 'direct' })" -ForegroundColor DarkGray
Write-Host "   Output    : $OutputPath" -ForegroundColor White
Write-Host "   Logs      : $logDir" -ForegroundColor White
Write-Host "   Run As    : $runAsLabel" -ForegroundColor White
Write-Host "   RunNow    : $RunNow" -ForegroundColor $(if ($RunNow) { 'Green' } else { 'DarkGray' })
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host ''

$registered = $false
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
    $registered = $true
}
catch {
    if ($UseSystemVault -or $isAdmin) {
        Write-Error "Failed to register task as SYSTEM: $_"
        return
    }
    # S4U may fail at registration time (e.g., MS accounts). Fall back to Interactive.
    Write-Host "  S4U registration failed. Falling back to Interactive (runs when logged in)..." -ForegroundColor Yellow
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
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
        $registered = $true
        Write-Host "  Note: task will only run when $currentUser is logged in." -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to register scheduled task: $_"
        return
    }
}

if ($registered) {
    Write-Host "  Task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "  Output dir : $OutputPath" -ForegroundColor White
    Write-Host "  Log dir    : $logDir" -ForegroundColor White
    Write-Host ''
    Write-Host '  -- Verify these are correct before running --' -ForegroundColor DarkCyan
    Write-Host "  Script : $scriptPath" -ForegroundColor Gray
    Write-Host "  Args   :$scriptArgs" -ForegroundColor Gray
    Write-Host "  Run as : $(if ($UseSystemVault) { 'SYSTEM (LocalMachine vault)' } else { $currentUser })" -ForegroundColor $(if ($UseSystemVault) { 'Green' } else { 'Gray' })
    Write-Host ''
    Write-Host '  Each run writes a timestamped log to:' -ForegroundColor White
    Write-Host "    $logDir" -ForegroundColor Cyan
    Write-Host '  View latest log after a run:' -ForegroundColor White
    Write-Host "    Get-ChildItem '$logDir' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content" -ForegroundColor Gray
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
                if ($Target) {
                    # Azure/OCI accept a single string via alias; all others accept string[]
                    $singleTargetProviders = @('Azure', 'OCI')
                    $runArgs['Target'] = if ($singleTargetProviders -contains $Provider) { $Target[0] } else { $Target }
                }
                if ($Action)     { $runArgs['Action']     = $Action }
                if ($WUGServer)  { $runArgs['WUGServer']  = $WUGServer }
                if ($AuthMethod) {
                    if ($Provider -in @('CUCM', 'CiscoWLC')) {
                        $snmpVer = switch ($AuthMethod) { 'SnmpV2' { 2 } 'SnmpV3' { 3 } default { 2 } }
                        $runArgs['SnmpVersion'] = $snmpVer
                    }
                    else {
                        $runArgs['AuthMethod'] = $AuthMethod
                    }
                }
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
# endregion

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUmpybbLXJZSnx7+0VThlHBLdo
# 78KggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFA6YOudxCCkjs/YhBOhySYVhyYFxMA0G
# CSqGSIb3DQEBAQUABIICAO6w+SgZm8R4Tj5shtHAZZe7O/5cOPcErE5q2QMeVhc1
# PCzjtMch3gfTFvdqdNIRaFk5j2i5JZRe9YizAao0nRAI1QcZACsRK5+IYnJC+DaT
# 8tBQoe31r952lKzNAuBvNlhBnpbbcySCmhjSFeZsP9fZMz/oqbgC9RXZ7tX6nWLw
# DOJCaiUy0RF2xmtwSIpRFQ41XC8TFDtrdx+g7LUw+fzrQ07VRnvuP2y+pCpn+Yd2
# ucrp5+47wuspMKAUNKt/Ur4wPij6K2luE0A70uEHKyWF3pASPT3StPBFlBHcBL3E
# +RmGOSsRHkpJqAhG1dyg4b0LZ43l9+k6+dfBJa91epU+R5G/pnZzLWHf8M5VWcUj
# a9h0AA5VC1J+2C48boTWrb16pHt7OirKJymf7bE25p27uvSRD4vDRUDEoctEpdZz
# I53lOUnQYOkHCkKCbTzQt5mL5py9pm68gMlTnJF+/hIyBr2E1G64Xa/4JHZeLjJC
# aNfPmfO6cJr7M9XmujGTUZ8wOMwXP8qxpciJkSPcI5qq35QGJ9PV/Y30v0UnG8M5
# zHMFJj/xQiPXO83OM9HYNjtATpSumLxetoomklfh9UfUv8hs43SlJmUdyjZXektb
# /E+Ro4KBRYofHOYyXIjlcSaZRh7WnEJuQ0vaKvb2KC4NWTpY9uJFgC+cFvJg4cTE
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDIwOVowLwYJKoZIhvcN
# AQkEMSIEIFRNmZHF92Ofn6XlRZuXA54gzinfoObAwd7Z263iwnkKMA0GCSqGSIb3
# DQEBAQUABIICAEEge4avm0gIXQMaTiUkP7vJ0+2/60B6aQXs3MoLwPq1qypb9qY5
# 9vjMZtzuUnWuuo2vNRlbFWxtS8Eba+heyiLnWZy6ShCqjxUaW59bOtZ92Zuzb0Ai
# EIyoxais07aot9V5YPamznDH+zviaRcalR5w9tpFVFvvUV2QQe5M3Lzn+rA+7m4N
# Utvb6ZWcyGreZPtqq5gxvN+nzPdQNDmzye4DffVP3l6bQFY7uS8Um7CdQDueZkc+
# KwS8LgQUhxS8xg4KQrHuRoUrbrE3JGQecACjn5DcrzVza7SunAfUBcVhnhQs1svg
# +v2EITigJjABjeXp6JtnA4pXJ2WIWc/m7Tg6FWUixVYZTmRU60nzSin6UTbPIcoQ
# 8M94bfWUsG7djiitBenvt7IVc4if9n8zUBH23Zw2lnY88vZCNnZoJdczdFfmJyAp
# A7ZeUoJwX5yu9qI+zhhVkn4r4W+FMWMjMmi0MkGWIwn4tcF3+K5AVo+BhLVPdsMO
# QXGgwyttofNcydg8I7BmzLyaQI34Sz1q45pwfVtsh4q97zeo6VE05CwNpUVv7THa
# mg3UBiX90VJO0uFtUZipZvgwAvt3HyimsnBcWspqZzTFUfliqy85tkfDmqt2DiAu
# RhTNOjhokBF6q/WoEYBc9Wm41mlVVADhd5s4otB+u2F4CHOHqJ245CvC
# SIG # End signature block
