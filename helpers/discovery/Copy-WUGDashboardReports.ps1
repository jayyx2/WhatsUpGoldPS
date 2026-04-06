<#
.SYNOPSIS
    Copies discovery dashboard HTML files to the WhatsUp Gold web console
    directory and optionally registers a Windows Scheduled Task for recurring copies.

.DESCRIPTION
    Discovery provider scripts (Setup-*-Discovery.ps1) generate dashboard HTML
    files in a local output directory. This script copies all *-Dashboard.html
    files to the WUG NmConsole folder so they are accessible via the web UI
    (e.g. https://wugserver/NmConsole/Proxmox-Dashboard.html).

    Modes:
      - Default (no switches) : Copy dashboard files now.
      - -Register             : Create a Windows Scheduled Task for recurring copies.
      - -Show                 : List existing WhatsUpGoldPS copy tasks.
      - -Remove <name>        : Remove a scheduled task by name.

.PARAMETER SourcePath
    Directory containing the *-Dashboard.html files.
    Default: $env:LOCALAPPDATA\DiscoveryHelpers\Output

.PARAMETER Destination
    Directory to copy dashboards into. Auto-detected from standard WUG
    install paths. Falls back to:
      C:\Program Files (x86)\Ipswitch\WhatsUp\Html\NmConsole

.PARAMETER Filter
    Filename filter for which dashboards to copy. Default: '*-Dashboard.html'
    Use to limit to specific providers, e.g. 'Proxmox-Dashboard.html'

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
    return Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
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
        Write-Host "  Dashboards available via WUG web UI at /NmConsole/<name>.html" -ForegroundColor Cyan
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
$resolvedSource = Resolve-SourcePath -Path $SourcePath
$resolvedDest   = Resolve-Destination -Path $Destination
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
$psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
if ($SourcePath) {
    $psArgs += " -SourcePath '$resolvedSource'"
}
if ($Destination) {
    $psArgs += " -Destination '$resolvedDest'"
}
if ($Filter -ne '*-Dashboard.html') {
    $psArgs += " -Filter '$Filter'"
}

$logDir = Join-Path $resolvedSource 'logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Set-RestrictedDirectoryAcl -Path $logDir
}

# Wrap in transcript for logging
$transcriptCmd = @"
`$logFile = Join-Path '$logDir' ('${TaskName}_' + (Get-Date -Format yyyyMMdd_HHmmss) + '.log')
Start-Transcript -Path `$logFile -Force
try { & powershell.exe $psArgs }
finally { Stop-Transcript }
"@
$oneLiner = ($transcriptCmd -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join '; '
$wrapperArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$oneLiner`""

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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAh/VS3wyQ8TvhQ
# DyJS1Ka766e85ZzFmavfXw3V3bJK1KCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgY340QSfaOBecg4MLEL9SrTyXJTl3UK/0
# YUjyIcC6QqMwDQYJKoZIhvcNAQEBBQAEggIARNKc8vkTB04AocRlJk092k+90brW
# y/N+LZSzkkVtKCGHl8rayYoPKh50LiEGK+rV+DOUNmj76aadqjSdInER+f2ncWp1
# 73/ANVNcGHIPK+pvkvPfq2QUdB/EVfOrIhZGv2lz+bCEWynI9XOPEeE+NuxqUy+P
# JJphLoJ4MNoQAhyoAurT1T0LfotHVAPkR5beuUbwpvI0syprd9IdmmKRx9IkUveK
# yOgNuEVL4sZ711xZoX1DGh82IMsMPXPmqFk/q2X2T8g0ja9YRg52qIwxf6/nLcn+
# XFYm/J+FBett8hhfPf7VuaUn99o8AbtBYFfZ6r+ply+hpoDvan9g/inHyr85YEi+
# tiHJbvBhO2LLbNsU5Dvvw32C9Pj07wh0n6pIe1qjx88csqWq1QthTZUpGpFMloTJ
# 5YW+nRyXTJ9/WoDjXIVcOjvSJGn7l2SlixK1+oAhN6G9ZMsdKwKTuZ4q8SODzAVV
# aJTctM5a2VKQsIw3G58Ht7tc79OTYKiBktRYPiYIwz5SZG5bU05S/QMZbfqg6Sk/
# hVB3S4g2jxyEfojAVidXA8DrhcQW1f6ppa+SIwEdA9C67tCkv4inlDKBgM1dcP/J
# ZHV+zNOGNU45YQF/nnoXySylkpBeNKeoeD+SDa4162th9v8hK9AA4UOW4mfa5Pf4
# 95nEWjX3v1f4WjU=
# SIG # End signature block
