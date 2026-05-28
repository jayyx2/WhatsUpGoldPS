<#
.SYNOPSIS
    Copies discovery dashboard HTML files to the WhatsUp Gold web console
    directory and optionally registers a Windows Scheduled Task for recurring copies.

.DESCRIPTION
    Discovery provider scripts (Setup-*-Discovery.ps1) generate dashboard HTML
    files in a local output directory. This script copies all *-Dashboard.html
    files to a 'dashboards' subdirectory under the WUG NmConsole folder so they
    are accessible via the web UI (e.g.
    https://wugserver/NmConsole/dashboards/Proxmox-Dashboard.html).

    A web.config is deployed into the dashboards subdirectory that denies
    anonymous access. Because the parent NmConsole site already has Forms
    authentication configured and runAllManagedModulesForAllRequests enabled,
    unauthenticated users are redirected to the WUG login page.

    Modes:
      - Default (no switches) : Copy dashboard files now.
      - -Register             : Create a Windows Scheduled Task for recurring copies.
      - -Show                 : List existing WhatsUpGoldPS copy tasks.
      - -Remove <name>        : Remove a scheduled task by name.

.PARAMETER SourcePath
    Directory containing the *-Dashboard.html files.
    Default: $env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Output

.PARAMETER Destination
    Parent NmConsole directory. Dashboards are copied into a 'dashboards'
    subdirectory under this path. Auto-detected from standard WUG install
    paths. Falls back to:
      C:\Program Files (x86)\Ipswitch\WhatsUp\Html\NmConsole

.PARAMETER Filter
    Filename filter for which dashboards to copy. Default: '*-Dashboard.html'
    Use to limit to specific providers, e.g. 'Proxmox-Dashboard.html'

.PARAMETER SkipWebConfig
    Do not deploy a web.config to the dashboards subdirectory. By default
    the script writes a web.config that denies anonymous access, forcing
    users to authenticate through the WUG login page before they can view
    dashboards.

.PARAMETER Register
    Register a Windows Scheduled Task to copy dashboards on a schedule
    instead of copying immediately.

.PARAMETER TaskName
    Name for the scheduled task. Default: 'CopyDashboards-WUG'

.PARAMETER TriggerType
    Schedule frequency: Daily, Hourly, AtStartup, Once.
    Default: Hourly.

.PARAMETER TimeOfDay
    Time to start (HH:mm format). Default: '00:00'.

.PARAMETER RepeatIntervalMinutes
    For 'Hourly' trigger: repeat interval in minutes.
    Default: 30.

.PARAMETER TaskFolder
    Task Scheduler folder. Default: '\WhatsUpGoldPS'.

.PARAMETER RunNow
    After registering the task, also perform the copy immediately.

.PARAMETER Show
    List all existing WhatsUpGoldPS scheduled tasks and exit.

.PARAMETER Remove
    Remove an existing scheduled task by name and exit.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1

    Copies all *-Dashboard.html files from the default output directory
    to the auto-detected WUG NmConsole folder.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1 -Destination 'D:\WUG\Html\NmConsole'

    Copies dashboards to a custom destination directory.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1 -Filter 'Proxmox-Dashboard.html'

    Copies only the Proxmox dashboard.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1 -Register -TriggerType Hourly -RepeatIntervalMinutes 30

    Registers a scheduled task that copies dashboards every 30 minutes.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1 -Register -TriggerType Daily -TimeOfDay '03:15' -RunNow

    Registers a daily 3:15 AM task and also copies dashboards immediately.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1 -Show

    Lists all scheduled tasks under the \WhatsUpGoldPS folder.

.EXAMPLE
    .\Copy-WUGDashboardReports.ps1 -Remove 'CopyDashboards-WUG'

    Removes the named scheduled task.

.NOTES
    Author  : jason@wug.ninja
    Created : 2025-07-14
    Requires: PowerShell 5.1+, Administrator rights for task registration
              and writing to Program Files directories.
#>
[CmdletBinding(DefaultParameterSetName = 'Copy')]
param(
    [Parameter(ParameterSetName = 'Copy')]
    [Parameter(ParameterSetName = 'Register')]
    [string]$SourcePath,

    [Parameter(ParameterSetName = 'Copy')]
    [Parameter(ParameterSetName = 'Register')]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Copy')]
    [Parameter(ParameterSetName = 'Register')]
    [string]$Filter = '*-Dashboard.html',

    [Parameter(ParameterSetName = 'Copy')]
    [Parameter(ParameterSetName = 'Register')]
    [switch]$SkipWebConfig,

    [Parameter(ParameterSetName = 'Register', Mandatory)]
    [switch]$Register,

    [Parameter(ParameterSetName = 'Register')]
    [string]$TaskName = 'CopyDashboards-WUG',

    [Parameter(ParameterSetName = 'Register')]
    [ValidateSet('Daily', 'Hourly', 'AtStartup', 'Once')]
    [string]$TriggerType = 'Hourly',

    [Parameter(ParameterSetName = 'Register')]
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$TimeOfDay = '00:00',

    [Parameter(ParameterSetName = 'Register')]
    [ValidateRange(5, 1440)]
    [int]$RepeatIntervalMinutes = 30,

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
# region  Resolve Paths
# ============================================================================
function Resolve-SourcePath {
    param([string]$Path)
    if ($Path) { return $Path }
    return Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
}

function Resolve-Destination {
    param([string]$Path)
    if ($Path) { return $Path }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
        "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
    )
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($found) { return $found }
    # Default fallback
    return "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
}

# Deploy a web.config into the dashboards subdirectory that denies anonymous
# access. The parent NmConsole site has Forms authentication configured and
# runAllManagedModulesForAllRequests enabled so the FormsAuth module runs on
# static HTML files too. The <deny users="?" /> rule triggers a redirect to
# the WUG login page for unauthenticated users.
function Deploy-WebConfig {
    param([string]$DashboardDir)

    $webConfigPath = Join-Path $DashboardDir 'web.config'

    $webConfigContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<!--
    Deployed by Copy-WUGDashboardReports.ps1
    Denies anonymous access so users must authenticate through the
    WhatsUp Gold web console before viewing dashboard reports.
    Delete this file to restore anonymous access to this folder.
-->
<configuration>
  <system.web>
    <authorization>
      <deny users="?" />
    </authorization>
    <customErrors mode="On">
      <error statusCode="401" redirect="/NmConsole" />
    </customErrors>
  </system.web>
</configuration>
'@

    try {
        $currentContent = $null
        if (Test-Path $webConfigPath) {
            $currentContent = [System.IO.File]::ReadAllText($webConfigPath)
        }
        if ($currentContent -eq $webConfigContent) {
            Write-Host '  web.config already up to date.' -ForegroundColor DarkGray
            return
        }
        [System.IO.File]::WriteAllText($webConfigPath, $webConfigContent, (New-Object System.Text.UTF8Encoding $true))
        Write-Host '  Deployed web.config (anonymous access denied -- WUG login required).' -ForegroundColor Green
    }
    catch {
        Write-Warning "  Could not deploy web.config: $_"
    }
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
# region  Copy Logic
# ============================================================================
function Copy-Dashboards {
    param(
        [string]$Source,
        [string]$Dest,
        [string]$FileFilter
    )

    if (-not (Test-Path $Source)) {
        Write-Error "Source directory not found: $Source"
        return $false
    }

    $files = Get-ChildItem -Path $Source -Filter $FileFilter -File -ErrorAction SilentlyContinue
    if (-not $files -or $files.Count -eq 0) {
        Write-Warning "No files matching '$FileFilter' found in: $Source"
        return $false
    }

    # Create destination if it does not exist
    if (-not (Test-Path $Dest)) {
        try {
            New-Item -ItemType Directory -Path $Dest -Force | Out-Null
            Write-Host "  Created destination: $Dest" -ForegroundColor Yellow
        }
        catch {
            Write-Error "Cannot create destination directory: $Dest - $_"
            return $false
        }
    }

    $copied  = 0
    $skipped = 0
    $failed  = 0

    foreach ($file in $files) {
        $destFile = Join-Path $Dest $file.Name
        try {
            # Only copy if source is newer or destination does not exist
            $shouldCopy = $true
            if (Test-Path $destFile) {
                $destItem = Get-Item $destFile
                if ($file.LastWriteTime -le $destItem.LastWriteTime) {
                    $shouldCopy = $false
                }
            }

            if ($shouldCopy) {
                Copy-Item -Path $file.FullName -Destination $destFile -Force
                Write-Host "  Copied: $($file.Name)" -ForegroundColor Green
                $copied++
            }
            else {
                Write-Host "  Skipped (up to date): $($file.Name)" -ForegroundColor DarkGray
                $skipped++
            }
        }
        catch {
            Write-Warning "  Failed: $($file.Name) - $_"
            $failed++
        }
    }

    Write-Host ''
    Write-Host "  Summary: $copied copied, $skipped up-to-date, $failed failed (of $($files.Count) total)" -ForegroundColor White
    if ($copied -gt 0) {
        Write-Host "  Dashboards available via WUG web UI at /NmConsole/dashboards/<name>.html" -ForegroundColor Cyan
    }
    return $true
}
# endregion

# ============================================================================
# region  Show -- list existing tasks
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
# region  Remove -- delete a task
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
# region  Resolve final paths
# ============================================================================
$resolvedSource  = Resolve-SourcePath -Path $SourcePath
$resolvedNmBase  = Resolve-Destination -Path $Destination
$resolvedDest    = Join-Path $resolvedNmBase 'dashboards'
# endregion

# ============================================================================
# region  Direct Copy (default mode)
# ============================================================================
if (-not $Register) {
    Write-Host ''
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host '   Copy Discovery Dashboard Reports to WUG NmConsole' -ForegroundColor Cyan
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host "   Source      : $resolvedSource" -ForegroundColor White
    Write-Host "   Destination : $resolvedDest" -ForegroundColor White
    Write-Host "   Filter      : $Filter" -ForegroundColor White
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host ''

    Copy-Dashboards -Source $resolvedSource -Dest $resolvedDest -FileFilter $Filter

    if (-not $SkipWebConfig) {
        Deploy-WebConfig -DashboardDir $resolvedDest
    }
    return
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
$scriptPath  = $MyInvocation.MyCommand.Path
$scriptArgs = ''
if ($SourcePath) {
    $scriptArgs += " -SourcePath '$resolvedSource'"
}
if ($Destination) {
    $scriptArgs += " -Destination '$resolvedDest'"
}
if ($Filter -ne '*-Dashboard.html') {
    $scriptArgs += " -Filter '$Filter'"
}
# Legacy $psArgs kept for display purposes
$psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`"$scriptArgs"

$logDir = Join-Path $resolvedSource 'logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Set-RestrictedDirectoryAcl -Path $logDir
}

# Build the full command as a proper multi-line script, then encode as Base64
# for -EncodedCommand. This avoids ALL quoting issues with Task Scheduler.
$fullCommand = @"
`$logFile = Join-Path '$logDir' ('${TaskName}_' + (Get-Date -Format yyyyMMdd_HHmmss) + '.log')
Start-Transcript -Path `$logFile -Force
try {
    & '$scriptPath'$scriptArgs
}
finally {
    Stop-Transcript
}
"@

$encodedBytes = [System.Text.Encoding]::Unicode.GetBytes($fullCommand)
$encodedCommand = [Convert]::ToBase64String($encodedBytes)
$wrapperArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

$taskAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $wrapperArgs `
    -WorkingDirectory (Split-Path $scriptPath -Parent)

$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType S4U `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew
# endregion

# ============================================================================
# region  Register Task
# ============================================================================
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host '   Register Dashboard Copy Scheduled Task' -ForegroundColor Cyan
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host "   Task Name   : $TaskName" -ForegroundColor White
Write-Host "   Folder      : $TaskFolder" -ForegroundColor White
Write-Host "   Trigger     : $TriggerType $(if ($TriggerType -eq 'Hourly') { "every ${RepeatIntervalMinutes}min" } else { "at $TimeOfDay" })" -ForegroundColor White
Write-Host "   Source      : $resolvedSource" -ForegroundColor White
Write-Host "   Destination : $resolvedDest" -ForegroundColor White
Write-Host "   Filter      : $Filter" -ForegroundColor White
Write-Host "   Logs        : $logDir" -ForegroundColor White
Write-Host "   Run As      : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor White
Write-Host "   RunNow      : $RunNow" -ForegroundColor $(if ($RunNow) { 'Green' } else { 'DarkGray' })
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
    Write-Host "  Log dir: $logDir" -ForegroundColor White
    Write-Host ''

    if ($RunNow) {
        Write-Host '  -RunNow specified -- copying dashboards now...' -ForegroundColor Yellow
        Write-Host '  =================================================================' -ForegroundColor DarkCyan
        Write-Host ''
        Copy-Dashboards -Source $resolvedSource -Dest $resolvedDest -FileFilter $Filter

        if (-not $SkipWebConfig) {
            Deploy-WebConfig -DashboardDir $resolvedDest
        }
    }
    else {
        Write-Host '  Verify with:' -ForegroundColor White
        Write-Host "    Get-ScheduledTask -TaskPath '$TaskFolder\' | Format-Table TaskName, State" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Run it now (test):' -ForegroundColor White
        Write-Host "    .\Copy-WUGDashboardReports.ps1" -ForegroundColor Gray
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
    Write-Host '  Writing to Program Files requires elevated permissions.' -ForegroundColor Yellow
    Write-Host ''
}
# endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCFk4FFWzywbQ22
# VCCmVGykOKQDVtmRU+Yt3XBf7pWyZ6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCcdxevQrR02fzGUD+ylUFJnv4nYlj+wggLWM3uuj2KZjANBgkqhkiG9w0BAQEF
# AASCAgBcbyAvgbdg1OMmBcMBVTg7MGl2/5O8cwvBBPEUEG4r5q2hcyYm64ZoP9F/
# 787mcYkBwKASuuxtnuRaXHZoZIANLlcVvnbtfYLq+mPmS77n6a72rlq8lphpZ7Bz
# 8698aYC+M/bh5Oo7hRnj5t+990LDC6dkqnpL2OCkGT23ylBnnEZapgunC1YZGJ9O
# vHO/ZE64JSTJyf0eddUxEFvqz7UTRMEFB4xtVX3iNjyWLaxNNsgmWL/tLJioJV0g
# +yFILbnBKcx2ANmrnkAdUSrWpoxNhlSAR40B/xmfW2wuUTuidTHX7cFHNPdNgAMt
# bAkuJfMHlIXR7uOgQgk1luaQ2bd1qLLx39XApIFQZgqnoYiCaHcH4e0EEIPJ1Qis
# o3nzjt6FYeIA30sfVoo7Z1jWxE+E64uk/GUGhFMVf+BEnymYED0tsYaLdzEw3UHQ
# MlLhaT43B3Lsk4bDIzk/Z70Pj+Kr9n5OnCpj/c9l5ssRuJ0709ZGyXaBkbuefj6N
# dggZzHn3ZrwjovFYsls5ipiR6BdTkaemztRPuRL2tjByw0Ne7vbLHU9oDBUJzZo/
# WbWnT/t4gFudxJP7DcEX+dhiaJOxh/6ZtAlFfcG8PGwFgY/3ZrCH3sUVE9UciQ9E
# WJhzLBqBR3PHf6Xt5iiLMQ33rBr02sQtuIDdFyUR3vnvFhKFjaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MjcxNzEwMDVaMC8GCSqGSIb3DQEJBDEiBCAkLlfr
# WDwRj1k302sM7mQLcrTe1lk5sRTtA4rw+YxSDDANBgkqhkiG9w0BAQEFAASCAgAV
# J48uge6/fpmJlPH1373GbBKbPpIIZjzDvBdrLs91GJ3IlTTZ6cosErG0MBNbMzGy
# zOjR/tP39J5OwnKE7jtFynJc5D5hQ1z9Wfh4qU4rVvAsTow1P0atxhpOhuHKioBK
# XUu2I3H6WziWJdQUFxOW2qW6EgWNhtldGHh+wsARq9k1d80D3k76kmi18cpmcmnC
# mZACMpGHkPNVR3SxxZuBul9sY484F7UX55PStGVDldGIevFkhzTMHrQDA9SbjVZT
# Zcc6qjnjkDIu/ZNuT6CQeo8r9oimRDuW9Jhxm0XE+5adpAmXEU6oYnWNFedRCroL
# 0M+dnkf2CHjHIJ8mgFG/JpB5CXDwmW9azvcdcFIjp8J5zaxlt5S6cPpwitQo0Hno
# IVui+x5IMBH2vhyPdiupdflbqKJH7oeNcK2/6KhJnkxYO/qNWjsphlBtuuUQMbTM
# QshKpP+a2hz3W/m7YojvQdqqmEhqM/wa53MpvbX0rZPksPakOpduWeJtPpOd8Mhc
# fEaEsnC/ucrml0Lu2NArCOjpJq9IHfSR6K33SnsJFff/FEyCGI/atkEs/IIH2pgq
# AniverdIGdUc7zo3Si/wqk5s/Ng5vcDsxtuwWJ8aaS1lThotCODnTZRqHml+fYfw
# vYN+c63pxjTOlHn1boQpi1P5P9IgYyBz3Cm1uM4ELw==
# SIG # End signature block
