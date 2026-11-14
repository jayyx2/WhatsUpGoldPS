#requires -Version 5.1
<#
.SYNOPSIS
    Offline test harness for the Linux fleet compliance helpers.
.DESCRIPTION
    Exercises every parser and the check-evaluation logic in
    helpers/linux/LinuxHelpers.ps1 using canned collector output.
    No SSH connection, network access, or live Linux host is required.
.EXAMPLE
    .\Invoke-WUGLinuxComplianceTest.ps1
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+
#>
[CmdletBinding()]
param()

$script:Passed = 0
$script:Failed = 0

function Record-Test {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    if ($Status -eq 'Pass') { $script:Passed++; $color = 'Green' } else { $script:Failed++; $color = 'Red' }
    Write-Host "  [$Status] $Name  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    try {
        $null = & $Test
        Record-Test -Name $Name -Status 'Pass'
    }
    catch {
        Record-Test -Name $Name -Status 'Fail' -Detail $_.Exception.Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$(if ($Message) { $Message + ': ' })Expected '$Expected' but got '$Actual'"
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message = 'Expected true but got false')
    if (-not $Value) { throw $Message }
}

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
$helpersFile = Join-Path $repoRoot 'helpers\linux\LinuxHelpers.ps1'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Linux Fleet Compliance Test Harness' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

try {
    . $helpersFile
    Record-Test -Name 'Load LinuxHelpers.ps1' -Status 'Pass'
}
catch {
    Record-Test -Name 'Load LinuxHelpers.ps1' -Status 'Fail' -Detail $_.Exception.Message
    Write-Host 'FATAL: helpers failed to load.' -ForegroundColor Red
    return
}

# Epoch 1735689600 = 2025-01-01T00:00:00Z; reference time is 100 days later.
$patchEpoch = 1735689600
$referenceTime = [datetimeoffset]::FromUnixTimeSeconds($patchEpoch).LocalDateTime.AddDays(100)

$sampleOutput = @"
===WUG:hostname===
web01
===WUG:osrelease===
NAME="Ubuntu"
VERSION_ID="22.04"
ID=ubuntu
PRETTY_NAME="Ubuntu 22.04.4 LTS"
===WUG:kernel===
5.15.0-105-generic
===WUG:arch===
x86_64
===WUG:uptime===
864000.42 1700000.00
===WUG:patchepoch===
$patchEpoch
===WUG:failedunits===
nginx.service loaded failed failed A high performance web server
fail2ban.service loaded failed failed Fail2Ban Service
===WUG:disk===
Filesystem     1024-blocks     Used Available Capacity Mounted on
/dev/sda1         41251136  8123456  31000000      21% /
/dev/sdb1        103212320 98051704   5160616      96% /data
/dev/sdc1         20511312 17434615   3076697      86% /var/log
===WUG:inode===
Filesystem      Inodes   IUsed    IFree IUse% Mounted on
/dev/sda1      2621440  123456  2497984    5% /
/dev/sdb1      6553600 6357000   196600   97% /data
===WUG:ntp===
NTP=yes
NTPSynchronized=no
===WUG:ports===
tcp   LISTEN 0      128    0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0      511    0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=1044,fd=6))
udp   UNCONN 0      0      0.0.0.0:68        0.0.0.0:*
tcp   LISTEN 0      128    0.0.0.0:23        0.0.0.0:*    users:(("telnetd",pid=1500,fd=3))
===WUG:reboot===
yes
===WUG:sshd===
permitrootlogin yes
passwordauthentication yes
permitemptypasswords no
x11forwarding no
===WUG:end===
"@

$sections = ConvertFrom-LinuxComplianceOutput -Output $sampleOutput

Write-Host ''
Write-Host '--- Section parsing ---' -ForegroundColor Cyan

Invoke-Test -Name 'All sections captured' -Test {
    Assert-True ($sections.ContainsKey('hostname')) 'hostname section missing'
    Assert-True ($sections.ContainsKey('disk')) 'disk section missing'
    Assert-True ($sections.ContainsKey('end')) 'end marker missing'
}

Invoke-Test -Name 'Hostname section content' -Test {
    Assert-Equal 'web01' (Get-LinuxSectionText -Sections $sections -Name 'hostname').Trim()
}

Write-Host ''
Write-Host '--- Parsers ---' -ForegroundColor Cyan

Invoke-Test -Name 'os-release parsed' -Test {
    $os = ConvertFrom-LinuxOsRelease -Text (Get-LinuxSectionText -Sections $sections -Name 'osrelease')
    Assert-Equal 'Ubuntu 22.04.4 LTS' $os.PrettyName
    Assert-Equal 'ubuntu' $os.Id
    Assert-Equal '22.04' $os.VersionId
}

Invoke-Test -Name 'df block output parsed' -Test {
    $disks = @(ConvertFrom-LinuxDfOutput -Text (Get-LinuxSectionText -Sections $sections -Name 'disk'))
    Assert-Equal 3 $disks.Count 'disk row count'
    $data = $disks | Where-Object { $_.MountPoint -eq '/data' }
    Assert-Equal 96 $data.UsedPercent
    Assert-Equal '/dev/sdb1' $data.Filesystem
}

Invoke-Test -Name 'df inode output parsed' -Test {
    $inodes = @(ConvertFrom-LinuxDfOutput -Text (Get-LinuxSectionText -Sections $sections -Name 'inode'))
    Assert-Equal 2 $inodes.Count 'inode row count'
    Assert-Equal 97 ($inodes | Where-Object { $_.MountPoint -eq '/data' }).UsedPercent
}

Invoke-Test -Name 'Failed systemd units parsed' -Test {
    $units = @(ConvertFrom-LinuxFailedUnit -Text (Get-LinuxSectionText -Sections $sections -Name 'failedunits'))
    Assert-Equal 2 $units.Count
    Assert-Equal 'nginx.service' $units[0].Unit
    Assert-Equal 'failed' $units[0].Active
}

Invoke-Test -Name 'NTP status parsed' -Test {
    $ntp = ConvertFrom-LinuxNtpStatus -Text (Get-LinuxSectionText -Sections $sections -Name 'ntp')
    Assert-Equal $true $ntp.Enabled
    Assert-Equal $false $ntp.Synchronized
}

Invoke-Test -Name 'ss listening ports parsed' -Test {
    $ports = @(ConvertFrom-LinuxListeningPort -Text (Get-LinuxSectionText -Sections $sections -Name 'ports'))
    Assert-Equal 4 $ports.Count 'port row count'
    $ssh = $ports | Where-Object { $_.Port -eq 22 }
    Assert-Equal 'tcp' $ssh.Protocol
    Assert-Equal 'sshd' $ssh.Process
    Assert-True (@($ports | Where-Object { $_.Protocol -eq 'udp' }).Count -eq 1) 'expected one udp socket'
}

Invoke-Test -Name 'netstat listening ports parsed' -Test {
    $netstatText = @'
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
tcp6       0      0 :::443                  :::*                    LISTEN
udp        0      0 0.0.0.0:123             0.0.0.0:*
'@
    $ports = @(ConvertFrom-LinuxListeningPort -Text $netstatText)
    Assert-Equal 3 $ports.Count
    Assert-True (@($ports | Where-Object { $_.Port -eq 443 }).Count -eq 1) 'expected port 443'
}

Invoke-Test -Name 'sshd settings parsed' -Test {
    $sshd = ConvertFrom-LinuxSshdSetting -Text (Get-LinuxSectionText -Sections $sections -Name 'sshd')
    Assert-Equal 'yes' $sshd['permitrootlogin']
    Assert-Equal 'no' $sshd['x11forwarding']
}

Write-Host ''
Write-Host '--- Facts ---' -ForegroundColor Cyan

$facts = Get-LinuxComplianceFact -Sections $sections -Target 'web01' -ReferenceTime $referenceTime

Invoke-Test -Name 'Facts assembled' -Test {
    Assert-Equal 'web01' $facts.Hostname
    Assert-Equal '5.15.0-105-generic' $facts.Kernel
    Assert-Equal 'x86_64' $facts.Architecture
    Assert-Equal $true $facts.RebootRequired
}

Invoke-Test -Name 'Uptime converted to days' -Test {
    Assert-Equal 10 $facts.UptimeDays
}

Invoke-Test -Name 'Patch age computed from epoch' -Test {
    Assert-Equal 100 $facts.PatchAgeDays
}

Write-Host ''
Write-Host '--- Checks ---' -ForegroundColor Cyan

$checks = @(Get-LinuxComplianceCheck -Facts $facts -AllowedPort 22, 80)

function Get-Check {
    param([string]$Name)
    $match = $checks | Where-Object { $_.Check -eq $Name } | Select-Object -First 1
    if (-not $match) { throw "Check not found: $Name" }
    return $match
}

Invoke-Test -Name 'Disk 96% flagged Fail' -Test {
    Assert-Equal 'Fail' (Get-Check 'Disk usage /data').Status
}

Invoke-Test -Name 'Disk 86% flagged Warn' -Test {
    Assert-Equal 'Warn' (Get-Check 'Disk usage /var/log').Status
}

Invoke-Test -Name 'Disk 21% passes' -Test {
    Assert-Equal 'Pass' (Get-Check 'Disk usage /').Status
}

Invoke-Test -Name 'Inode 97% flagged Fail' -Test {
    Assert-Equal 'Fail' (Get-Check 'Inode usage /data').Status
}

Invoke-Test -Name 'Failed units flagged Fail' -Test {
    $check = Get-Check 'Failed systemd units'
    Assert-Equal 'Fail' $check.Status
    Assert-Equal '2' $check.Value
}

Invoke-Test -Name 'Unsynchronized NTP flagged Fail' -Test {
    Assert-Equal 'Fail' (Get-Check 'NTP synchronization').Status
}

Invoke-Test -Name 'Pending reboot flagged Warn' -Test {
    Assert-Equal 'Warn' (Get-Check 'Reboot required').Status
}

Invoke-Test -Name 'Patch age 100 days flagged Fail' -Test {
    Assert-Equal 'Fail' (Get-Check 'Package patch age').Status
}

Invoke-Test -Name 'Root login enabled flagged Fail' -Test {
    Assert-Equal 'Fail' (Get-Check 'SSH root login').Status
}

Invoke-Test -Name 'Password auth enabled flagged Warn' -Test {
    Assert-Equal 'Warn' (Get-Check 'SSH password auth').Status
}

Invoke-Test -Name 'Compliant sshd setting passes' -Test {
    Assert-Equal 'Pass' (Get-Check 'SSH X11 forwarding').Status
}

Invoke-Test -Name 'Unexpected port flagged Warn' -Test {
    $check = Get-Check 'Listening ports'
    Assert-Equal 'Warn' $check.Status
    Assert-True ($check.Detail -like '*23*') 'telnet port 23 should be reported'
}

Invoke-Test -Name 'Port check passes when all allowed' -Test {
    $allowedChecks = @(Get-LinuxComplianceCheck -Facts $facts -AllowedPort 22, 80, 68, 23)
    $portCheck = $allowedChecks | Where-Object { $_.Check -eq 'Listening ports' } | Select-Object -First 1
    Assert-Equal 'Pass' $portCheck.Status
}

Write-Host ''
Write-Host '--- Healthy host and summary ---' -ForegroundColor Cyan

$healthyOutput = @"
===WUG:hostname===
web02
===WUG:osrelease===
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
ID=debian
VERSION_ID="12"
===WUG:kernel===
6.1.0-18-amd64
===WUG:arch===
x86_64
===WUG:uptime===
86400.00 100000.00
===WUG:patchepoch===
$patchEpoch
===WUG:failedunits===
===WUG:disk===
Filesystem     1024-blocks    Used Available Capacity Mounted on
/dev/sda1         41251136 4123456  35000000      11% /
===WUG:inode===
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/sda1      2621440  93456 2527984    4% /
===WUG:ntp===
NTP=yes
NTPSynchronized=yes
===WUG:ports===
tcp   LISTEN 0      128    0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=800,fd=3))
===WUG:reboot===
no
===WUG:sshd===
permitrootlogin no
passwordauthentication no
permitemptypasswords no
x11forwarding no
===WUG:end===
"@

$healthySections = ConvertFrom-LinuxComplianceOutput -Output $healthyOutput
$healthyFacts = Get-LinuxComplianceFact -Sections $healthySections -Target 'web02' -ReferenceTime ([datetimeoffset]::FromUnixTimeSeconds($patchEpoch).LocalDateTime.AddDays(3))
$healthyChecks = @(Get-LinuxComplianceCheck -Facts $healthyFacts -AllowedPort 22)

Invoke-Test -Name 'Healthy host has no failures' -Test {
    $bad = @($healthyChecks | Where-Object { $_.Status -eq 'Fail' })
    Assert-Equal 0 $bad.Count "unexpected failures: $(($bad | ForEach-Object { $_.Check }) -join ', ')"
}

Invoke-Test -Name 'Healthy host overall status is Pass' -Test {
    Assert-Equal 'Pass' (Get-LinuxComplianceStatus -Checks $healthyChecks)
}

Invoke-Test -Name 'Unhealthy host overall status is Fail' -Test {
    Assert-Equal 'Fail' (Get-LinuxComplianceStatus -Checks $checks)
}

Invoke-Test -Name 'Summary aggregates per target' -Test {
    $summary = @(Get-LinuxComplianceSummary -Checks ($checks + $healthyChecks))
    Assert-Equal 2 $summary.Count
    $web01 = $summary | Where-Object { $_.Target -eq 'web01' }
    $web02 = $summary | Where-Object { $_.Target -eq 'web02' }
    Assert-Equal 'Fail' $web01.Status
    Assert-Equal 'Pass' $web02.Status
    Assert-True ($web01.Fail -ge 5) "expected several failures, got $($web01.Fail)"
}

Invoke-Test -Name 'Missing data yields Unknown, not an error' -Test {
    $emptySections = ConvertFrom-LinuxComplianceOutput -Output "===WUG:hostname===`nweb03`n===WUG:end==="
    $emptyFacts = Get-LinuxComplianceFact -Sections $emptySections -Target 'web03'
    $emptyChecks = @(Get-LinuxComplianceCheck -Facts $emptyFacts)
    Assert-True (@($emptyChecks | Where-Object { $_.Status -eq 'Unknown' }).Count -gt 0) 'expected Unknown checks'
    Assert-Equal 'Package patch age' ($emptyChecks | Where-Object { $_.Check -eq 'Package patch age' }).Check
    Assert-Equal 'Unknown' ($emptyChecks | Where-Object { $_.Check -eq 'Failed systemd units' }).Status
}

Invoke-Test -Name 'Failed systemctl collection is Unknown rather than healthy zero' -Test {
    $failedSections = ConvertFrom-LinuxComplianceOutput -Output "===WUG:failedunits===`n===WUG:failedunitsstatus===`n1`n===WUG:end==="
    $failedFacts = Get-LinuxComplianceFact -Sections $failedSections -Target 'test'
    Assert-Equal $false $failedFacts.FailedUnitsAvailable
    $failedChecks = @(Get-LinuxComplianceCheck -Facts $failedFacts)
    Assert-Equal 'Unknown' ($failedChecks | Where-Object Check -eq 'Failed systemd units').Status
}

Invoke-Test -Name 'Zero, future and overflowing patch timestamps remain unknown' -Test {
    foreach ($epoch in '000000', '999999999999999999999999', '9999999999') {
        $invalidSections = ConvertFrom-LinuxComplianceOutput -Output "===WUG:patchepoch===`n$epoch`n===WUG:end==="
        $invalidFacts = Get-LinuxComplianceFact -Sections $invalidSections -Target 'test' -ReferenceTime $referenceTime
        Assert-True ($null -eq $invalidFacts.PatchAgeDays)
    }
}

Invoke-Test -Name 'Collector command includes every section marker' -Test {
    $command = Get-LinuxComplianceCommand
    foreach ($name in @('hostname', 'osrelease', 'kernel', 'patchepoch', 'failedunits', 'disk', 'inode', 'ntp', 'ports', 'reboot', 'sshd', 'end')) {
        Assert-True ($command -like "*===WUG:$name===*") "missing marker: $name"
    }
}

Invoke-Test -Name 'Collector command uses LF line endings' -Test {
    $command = Get-LinuxComplianceCommand
    Assert-True (-not $command.Contains("`r")) 'CR characters break bash if/fi parsing'
}

Invoke-Test -Name 'Collector command has balanced if/fi keywords' -Test {
    $command = Get-LinuxComplianceCommand
    $ifCount = @([regex]::Matches($command, '(?m)(?:^|[;\s])if\s')).Count
    $fiCount = @([regex]::Matches($command, '(?m)(?:^|[;\s])fi(?:$|[;\s])')).Count
    Assert-Equal $ifCount $fiCount 'unbalanced if/fi'
}

Write-Host ''
Write-Host '--- Discovery monitor validation ---' -ForegroundColor Cyan
. (Join-Path $repoRoot 'helpers\discovery\DiscoveryHelpers.ps1')
. (Join-Path $repoRoot 'helpers\discovery\DiscoveryProvider-Linux.ps1')

& {
    function New-SshSession {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Test double matches the SSH helper signature.')]
        param($HostName, $Port, $Username, $TimeoutSeconds, $SecurePassword, $KeyFile)
        if ($KeyFile) { throw 'Password validation must not silently use the discovery key.' }
        return 'mock-session'
    }
    function Invoke-SshCommand {
        param($Session, $Command, $TimeoutSeconds)
        switch ($Command) {
            'healthy' { return [PSCustomObject]@{ ExitCode = 0; Output = 'OK'; Error = '' } }
            'unhealthy' { return [PSCustomObject]@{ ExitCode = 0; Output = 'FAILED=2'; Error = '' } }
            'numeric' { return [PSCustomObject]@{ ExitCode = 0; Output = '0'; Error = '' } }
            'empty' { return [PSCustomObject]@{ ExitCode = 0; Output = ''; Error = '' } }
            'failed' { return [PSCustomObject]@{ ExitCode = 3; Output = '0'; Error = 'Permission denied' } }
            'diagnostic' { return [PSCustomObject]@{ ExitCode = 0; Output = 'Unknown'; Error = '' } }
            'timeout' { throw 'Simulated command timeout' }
        }
    }
    function Close-SshSession { param($Session) $script:ClosedSessions++ }

    Invoke-Test -Name 'Validation distinguishes unhealthy hosts from collection failures and empty output' -Test {
        $script:ClosedSessions = 0
        $credential = New-Object PSCredential ('test', (New-Object System.Security.SecureString))
        $plan = @(
            foreach ($command in 'healthy', 'unhealthy', 'numeric', 'empty', 'failed', 'diagnostic', 'timeout') {
                $type = if ($command -in @('healthy', 'unhealthy')) { 'ActiveMonitor' } else { 'PerformanceMonitor' }
                New-DiscoveredItem -Name $command -ItemType $type -MonitorType Ssh -UniqueKey $command `
                    -MonitorParams @{ SshCommand = $command; SshExpectedOutput = 'OK' }
            }
        )
        $r = @(Test-LinuxMonitorCommands -Target 'test' -Plan $plan -Credential $credential -KeyFile 'discovery-only.key' -WarningAction SilentlyContinue)
        Assert-Equal 'Up,Down,OK,BadOutput,CommandError,BadOutput,SshError' (($r | ForEach-Object Status) -join ',')
        Assert-Equal 1 $script:ClosedSessions 'session must close even after command failures'
    }

    Invoke-Test -Name 'Linux performance monitors are reused across hosts with the same mount point' -Test {
        function Get-LinuxComplianceInventory {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Test double matches the inventory helper signature.')]
            param($Target, $Username, $SecurePassword)
            [PSCustomObject]@{
                Facts = [PSCustomObject]@{
                    OsName = 'Test Linux'; Kernel = '1'; NtpSynchronized = $true; RebootRequired = $false
                    PatchAgeDays = 1; Disks = @([PSCustomObject]@{ MountPoint = '/' }); Hostname = $Target
                    OsId = 'test'; OsVersion = '1'; Architecture = 'x86_64'; UptimeDays = 1
                    FailedUnits = @(); FailedUnitsAvailable = $true; ListeningPorts = @()
                }
                Checks = @([PSCustomObject]@{ Check = 'Failed systemd units'; Status = 'Pass' })
                Status = 'Pass'
            }
        }
        $provider = Get-DiscoveryProvider -Name Linux
        $credential = New-Object PSCredential ('test', (New-Object System.Security.SecureString))
        $a = @(& $provider.DiscoverScript @{ DeviceIP = 'host-a'; DeviceId = 1; Options = @{ Credential = $credential } })
        $b = @(& $provider.DiscoverScript @{ DeviceIP = 'host-b'; DeviceId = 2; Options = @{ Credential = $credential } })
        Assert-Equal (($a.Name | Sort-Object) -join ',') (($b.Name | Sort-Object) -join ',')
        Assert-True (@($a.Name | Where-Object { $_ -like '*host-a*' }).Count -eq 0)
    }

    Invoke-Test -Name 'Existing Linux active commands refresh without resetting other monitor properties' -Test {
        function Get-WUGMonitorLibraryMap {
            param($Type, [switch]$AsObject)
            @{
                'Linux - test' = [PSCustomObject]@{
                    id = 1
                    propertyBags = @(
                        [PSCustomObject]@{ name = 'MonSSH:Command'; value = 'old-command' }
                        [PSCustomObject]@{ name = 'MonSSH:Output'; value = 'OK' }
                        [PSCustomObject]@{ name = 'MonSSH:CredentialID'; value = '-1' }
                    )
                }
            }
        }
        function Get-WUGAPIResponse { [CmdletBinding()]param() }
        function Set-WUGActiveMonitor {
            [CmdletBinding(SupportsShouldProcess = $true)]
            param($Mode, $MonitorId, $PropertyBags)
            $script:UpdatedLinuxBags = $PropertyBags
            [PSCustomObject]@{ data = [PSCustomObject]@{ successful = 1 } }
        }
        $item = New-DiscoveredItem -Name 'Linux - test' -ItemType ActiveMonitor -MonitorType Ssh `
            -UniqueKey 'test' -MonitorParams @{ SshCommand = 'validated-command' }
        Sync-LinuxActiveMonitorCommands -Plan @($item)
        Assert-Equal 'validated-command' ($script:UpdatedLinuxBags | Where-Object name -eq 'MonSSH:Command').value
        Assert-Equal 'OK' ($script:UpdatedLinuxBags | Where-Object name -eq 'MonSSH:Output').value
        Assert-Equal '-1' ($script:UpdatedLinuxBags | Where-Object name -eq 'MonSSH:CredentialID').value
    }
}

$shell = Get-Command sh -ErrorAction SilentlyContinue
if (-not $shell) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitBash = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
        if (Test-Path $gitBash) { $shell = Get-Command $gitBash }
    }
}
if ($shell) {
    Invoke-Test -Name 'Systemctl failures never produce a healthy status or zero count' -Test {
        foreach ($kind in 'FailedUnits', 'FailedUnitCount') {
            $command = 'systemctl() { echo "permission denied" >&2; return 1; }; ' + (Get-LinuxMonitorCommand -Kind $kind)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
            $text = (& $shell.Source -c "echo $encoded | base64 -d | sh" 2>&1 | Out-String).Trim()
            Assert-Equal 3 $LASTEXITCODE
            Assert-True ($text -notmatch '(^|\n)(OK|0)($|\r?\n)') "fake healthy response: $text"
        }
    }
    Invoke-Test -Name 'Systemctl success counts only nonblank units' -Test {
        $command = 'systemctl() { printf "one.service loaded failed failed\n\ntwo.service loaded failed failed\n"; }; ' + (Get-LinuxMonitorCommand -Kind FailedUnitCount)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
        $text = (& $shell.Source -c "echo $encoded | base64 -d | sh" 2>&1 | Out-String).Trim()
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal '2' $text
    }
    Invoke-Test -Name 'Missing or invalid package timestamps fail instead of using epoch zero' -Test {
        foreach ($body in 'return 1', 'return 0', 'echo 0', 'echo 2000000') {
            $command = "rpm() { $body; }; date() { echo 1086400; }; " + (Get-LinuxMonitorCommand -Kind PatchAge)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
            $null = & $shell.Source -c "echo $encoded | base64 -d | sh" 2>&1
            Assert-Equal 3 $LASTEXITCODE "rpm stub: $body"
        }
    }
    Invoke-Test -Name 'Valid package timestamps return the measured age in days' -Test {
        $command = 'rpm() { echo 1000000; }; date() { echo 1086400; }; ' + (Get-LinuxMonitorCommand -Kind PatchAge)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
        $text = (& $shell.Source -c "echo $encoded | base64 -d | sh" 2>&1 | Out-String).Trim()
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal '1' $text
    }
    Invoke-Test -Name 'Disk commands reject missing and out-of-range usage, accepting 0 and 100 percent' -Test {
        foreach ($usage in '0%', '49%', '85%', '100%', '101%', '-') {
            $command = "df() { printf '%s\n' 'Filesystem Blocks Used Available Capacity Mounted' '/dev/test 100 0 100 $usage /data'; }; " +
                (Get-LinuxMonitorCommand -Kind DiskUsed -MountPoint "/data's volume")
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
            $text = (& $shell.Source -c "echo $encoded | base64 -d | sh" 2>&1 | Out-String).Trim()
            if ($usage -in @('0%', '49%', '85%', '100%')) {
                Assert-Equal 0 $LASTEXITCODE
                Assert-Equal ($usage.TrimEnd('%')) $text
            }
            else { Assert-Equal 3 $LASTEXITCODE }
        }
    }
}
else { Write-Warning 'POSIX command execution tests skipped: install a POSIX shell (for example Git Bash) to run them.' }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed   Failed: $script:Failed" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host '============================================================' -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBJ3BpblxasXlGI
# A//bSx/etajRbzCvljkvTJ6tyCpLdKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDP
# yfujpGjSQ4neBcs2EQ3CdN4Rfs3/A6mnzxcdTtU5STANBgkqhkiG9w0BAQEFAASC
# AgAnfNEXN7tUhaW1kVgl3XQPwCs9NEkqNLWaJz0jAKD4EJc34Fde6mAzZNdBf3Jm
# 9UNGfc80916On+sVMJeV1UZ3xOYZl1tO5AqyvcCBl7JD0QUIdQWozoZ5orpZfg57
# OlqdnTZpvNGPlVmvhZQk1aTndlDphX6zQf9ahIoB+YeXjvDv+eiN9vUHEi9cfwyN
# NefBbwoKobof/ww+ign/P2k6Z8ZXcrDkaPFGC49/7jZYfVIOPG2UdYb846vPZVvc
# A7InkxPdp2Ia7ipsjFT7zki5sTuvwlbk9Zjxvcidkutbgl8qSTGHvu2yaCw+9Uc7
# vPV5iuC/jMv+fFz4OUhNCTklx7MKrtF3qcJwCxKJoK7JUzM+d0+WbnSvkUn0/grj
# 0q6WC7Ha13lYBKyBCXGR78w0HBNiEWrL4vA28pnDwuvHt3wT1w3sgmLChC+KgCZj
# jtcmHEOOqRErcDRFQl7jqOemphIdKt3NIdqIM4zc7wwAz++fRvI8TTpFpW8aYimo
# UenF+ZOShPdzD93onBtj0mGG69/p7FEQag91zN1dTMyWpmQAhevKcPXU5PpyMDPh
# IAzIdx6jenXJcVt2Q6+pPaLW59SPCQkrjAJAcSkfMLuyTLuA5LItI5V+7i/QhlOk
# K6SImqp0ixo5jY1DeQF3yI8mZz2nzDmpzm/pf9OVxqqUdKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMxODMzMzNaMC8GCSqGSIb3DQEJBDEiBCAWv+PEdbrA
# CvgavpqrMhSKAk+IhpzmbcKsiLAv5dXp6TANBgkqhkiG9w0BAQEFAASCAgCWNPNS
# rj1a8MX3EbeJh0jbNY2KzJWafe09aOs+qpG0SDDN6ZJxgiSyvAqbVJCWrmlkCdH7
# WKl57lDTfC3uPNZfetilTkcC56y3HURfge2URT1FFcSjK9rYPa6Wixgpqs7/66El
# XMs6+vBPmKWuoNM9ctSRovDuZzL//70b19rRlstK4JH9PxUy9gtt794aF1YpubSr
# C7LmlzTydwDJwEHn9M0SoJ84yohO6fGW/GqF2hkUlTus7E5fqahngQxLw4Mh5Tfe
# mMD5CVROfIqzNuTpGEyJ87KBKekUKCoDDm3M8z/7z6E294yj72VxnQIEiT7E9EI5
# Ja/iWc6XQp4x/rXxsTw9NjTVslKgxdsyb/Ak0AhlCPe971z3s7jMgrqe5vucU3Uv
# 3RXPP1NX8qx8tZwnkD5f8ooHcy0fKZVNoa/Ce+EAI++FSmgAEhsgl3AbFdz9zA3c
# NBnkawyvVZ1OOVGdS3Sh7wWccwcpPjAzymvTD7fCmZbtMgk+Hg9N7gNMF8rS8TPw
# G8sKUzymx8MdjT+oRhDXGsHY+9bVTxDuJG+HiL/w5Gc4qxU02dhkoh1afuaTCQ1G
# ou9PxDr5WrOTSN4H4u4CnecgMMnSqC9PT4QJImj0x2IE7raWdACRthTKo0FRPQcD
# vlujCCTQhVeWKhErtweCKHIXqYMU7MpfFOfneg==
# SIG # End signature block
