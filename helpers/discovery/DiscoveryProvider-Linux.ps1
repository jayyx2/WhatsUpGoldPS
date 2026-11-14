<#
.SYNOPSIS
    Collects Linux compliance facts over SSH and plans WUG SSH monitors and attributes.

.DESCRIPTION
    Wraps helpers\linux\LinuxHelpers.ps1. One SSH round trip per host gathers OS,
    patch, systemd, disk, inode, NTP, listening-port, reboot and sshd facts, which
    are evaluated into Pass/Warn/Fail checks.

    Monitor plan (all use the device's assigned WUG SSH credential):
      Active (shared library entries):
        Linux - NTP Synchronized, Linux - No Reboot Pending, Linux - No Failed Systemd Units
      Performance (shared by command/mount point):
        Disk used % per mount, failed systemd unit count, days since last package change

    Context options (ctx.Options):
      Credential (PSCredential), KeyFile, KeyPassphrase, SshPort, TimeoutSeconds,
      DiskWarnPercent, DiskFailPercent, InodeWarnPercent, InodeFailPercent,
      PatchWarnDays, PatchFailDays, AllowedPort (int[]), MaxDiskMonitors
#>

$script:LinuxHelpersPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'linux\LinuxHelpers.ps1'
if (-not (Test-Path -LiteralPath $script:LinuxHelpersPath)) { throw "Linux helpers not found: $script:LinuxHelpersPath" }
. $script:LinuxHelpersPath

if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $helpersPath = Join-Path $PSScriptRoot 'DiscoveryHelpers.ps1'
    if (-not (Test-Path $helpersPath)) { throw 'DiscoveryHelpers.ps1 is required.' }
    . $helpersPath
}

function Get-LinuxMonitorCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Ntp', 'Reboot', 'FailedUnits', 'FailedUnitCount', 'PatchAge', 'DiskUsed')][string]$Kind,
        [string]$MountPoint
    )

    switch ($Kind) {
        'Ntp' { return 'v=$(LC_ALL=C timedatectl show -p NTPSynchronized) || exit 3; case "$v" in NTPSynchronized=yes) echo yes;; NTPSynchronized=no) echo no;; *) echo "NTP state unavailable" >&2; exit 3;; esac' }
        'Reboot' { return 'if [ -f /var/run/reboot-required ]; then echo REBOOT-PENDING; elif command -v needs-restarting >/dev/null 2>&1; then LC_ALL=C needs-restarting -r >/dev/null; r=$?; case "$r" in 0) echo OK;; 1) echo REBOOT-PENDING;; *) echo "Reboot check failed (exit $r)" >&2; exit 3;; esac; elif [ -f /var/lib/dpkg/status ]; then echo OK; else echo "Reboot check unsupported" >&2; exit 3; fi' }
        { $_ -in @('FailedUnits', 'FailedUnitCount') } {
            $count = 'u=$(LC_ALL=C systemctl list-units --state=failed --no-legend --plain) || exit 3; n=$(printf "%s\n" "$u" | awk ''NF{n++}END{print n+0}''); '
            if ($Kind -eq 'FailedUnits') { return ($count + 'if [ "$n" -eq 0 ]; then echo OK; else echo FAILED=$n; fi') }
            return ($count + 'echo "$n"')
        }
        'PatchAge' { return 'if command -v rpm >/dev/null 2>&1; then p=$(LC_ALL=C rpm -qa --qf "%{INSTALLTIME}\n") || exit 3; t=$(printf "%s\n" "$p" | sort -n | tail -n 1); elif [ -f /var/lib/dpkg/status ]; then t=$(stat -c %Y /var/lib/dpkg/status) || exit 3; else echo "Package timestamp unavailable" >&2; exit 3; fi; now=$(date +%s) || exit 3; case "$t:$now" in *[!0-9:]*|:*|*:) echo "Invalid package timestamp" >&2; exit 3;; esac; if [ "$t" -le 0 ] || [ "$t" -gt "$now" ]; then echo "Package timestamp outside valid range" >&2; exit 3; fi; echo $(( (now - t) / 86400 ))' }
        'DiskUsed' {
            # Single-quote the mount for the shell; escape embedded quotes.
            $quoted = "'" + ($MountPoint -replace "'", "'\''") + "'"
            return "d=`$(LC_ALL=C df -P $quoted) || exit 3; printf '%s\n' ""`$d"" | awk 'NR==2 && `$5 ~ /^[0-9]+%`$/ {gsub(""%"","""",`$5); if ((`$5 + 0) <= 100) {print `$5; ok=1}} END{if (!ok) exit 3}'"
        }
    }
}

function Test-LinuxMonitorCommands {
    <#
    .SYNOPSIS
        Validates the exact planned commands with the same password authentication WUG uses.
    .DESCRIPTION
        Down is a successful health check reporting an unhealthy host, not a collection
        error. Failed, empty and malformed results are never eligible for provisioning.
        Key-only validation is supported for standalone runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Plan,
        [PSCredential]$Credential,
        [string]$KeyFile,
        [string]$Username,
        [int]$Port = 22,
        [int]$TimeoutSeconds = 60
    )

    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psd1'
    if (-not (Get-Command New-SshSession -ErrorAction SilentlyContinue)) { Import-Module $modulePath -ErrorAction Stop }
    $splat = @{ HostName = $Target; Port = $Port; TimeoutSeconds = $TimeoutSeconds }
    if ($Credential) {
        $splat.Username = $Credential.UserName
        $splat.SecurePassword = $Credential.Password
    }
    elseif ($KeyFile) {
        $splat.Username = $Username
        $splat.KeyFile = $KeyFile
    }
    else { throw 'Linux monitor validation requires an SSH password credential or key.' }

    $session = $null
    try {
        $session = New-SshSession @splat
        foreach ($item in @($Plan | Where-Object { $_.ItemType -in @('ActiveMonitor', 'PerformanceMonitor') })) {
            $status = 'BadOutput'
            $output = ''
            $detail = ''
            try {
                $r = Invoke-SshCommand -Session $session -Command $item.MonitorParams.SshCommand -TimeoutSeconds $TimeoutSeconds
                $output = ([string]$r.Output).Trim()
                if ($r.ExitCode -ne 0) {
                    $status = 'CommandError'
                    $detail = "exit $($r.ExitCode): $($r.Error) $output"
                }
                elseif ($item.ItemType -eq 'PerformanceMonitor') {
                    if ($output -match '^[0-9]+(\.[0-9]+)?$') { $status = 'OK' }
                    else { $detail = 'Expected one nonnegative number, not an empty or diagnostic response.' }
                }
                elseif ($output -ceq $item.MonitorParams.SshExpectedOutput) { $status = 'Up' }
                elseif (($item.MonitorParams.SshExpectedOutput -eq 'yes' -and $output -ceq 'no') -or
                    ($item.MonitorParams.SshExpectedOutput -eq 'OK' -and $output -cmatch '^(REBOOT-PENDING|FAILED=[0-9]+)$')) { $status = 'Down' }
                else { $detail = 'Expected a recognized health-check response.' }
            }
            catch { $status = 'SshError'; $detail = $_.Exception.Message }

            if ($status -notin @('OK', 'Up', 'Down')) {
                Write-Warning "Linux monitor '$($item.Name)' on ${Target}: $status - $detail"
            }
            [PSCustomObject]@{ Target = $Target; Monitor = $item.Name; Status = $status; Output = $output; Detail = $detail; Item = $item }
        }
    }
    finally {
        if ($session) { Close-SshSession -Session $session }
    }
}

function Sync-LinuxActiveMonitorCommands {
    <#
    .SYNOPSIS
        Refreshes previously created Linux SSH health commands after successful validation.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Plan)

    foreach ($dependency in 'Set-WUGActiveMonitor', 'Get-WUGAPIResponse') {
        if (-not (Get-Command $dependency -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot "..\..\functions\$dependency.ps1")
        }
    }
    $library = Get-WUGMonitorLibraryMap -Type active -AsObject
    foreach ($item in @($Plan | Where-Object ItemType -eq 'ActiveMonitor' | Sort-Object Name -Unique)) {
        if (-not $library.ContainsKey($item.Name)) { continue }
        $monitor = $library[$item.Name]
        $bag = @($monitor.propertyBags | Where-Object name -eq 'MonSSH:Command') | Select-Object -First 1
        if (-not $bag) { throw "Existing monitor '$($item.Name)' is not a compatible SSH monitor; it was not changed." }
        if ($bag.value -ceq $item.MonitorParams.SshCommand) { continue }
        if (-not $PSCmdlet.ShouldProcess($item.Name, 'Refresh validated Linux SSH health command')) { continue }
        $bags = @($monitor.propertyBags | ForEach-Object {
            @{ name = $_.name; value = $(if ($_.name -eq 'MonSSH:Command') { $item.MonitorParams.SshCommand } else { $_.value }) }
        })
        $id = if ($monitor.monitorId) { $monitor.monitorId } else { $monitor.id }
        $r = Set-WUGActiveMonitor -Mode Library -MonitorId ([string]$id) -PropertyBags $bags -Confirm:$false -ErrorAction Stop -WarningAction Stop
        if (-not $r -or $r.data.successful -ne 1) { throw "WUG did not confirm the command update for '$($item.Name)'." }
    }
}

Register-DiscoveryProvider -Name 'Linux' `
    -MatchAttribute 'DiscoveryHelper.Linux' `
    -AuthType 'BasicAuth' `
    -DefaultPort 22 `
    -DefaultProtocol 'ssh' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $options = if ($ctx.Options) { $ctx.Options } else { @{} }
        $target = [string]$ctx.DeviceIP
        $deviceId = [int]$ctx.DeviceId
        $credential = $options.Credential
        if (-not $credential -and -not $options.KeyFile) { throw 'Linux discovery needs a PSCredential or a key file.' }

        $splat = @{ Target = $target }
        if ($credential) {
            $splat['Username'] = $credential.UserName
            $splat['SecurePassword'] = $credential.Password
        }
        if ($options.KeyFile) {
            $splat['KeyFile'] = [string]$options.KeyFile
            if (-not $splat.ContainsKey('Username')) { $splat['Username'] = [string]$options.Username }
        }
        foreach ($name in 'KeyPassphrase', 'TimeoutSeconds', 'DiskWarnPercent', 'DiskFailPercent', 'InodeWarnPercent', 'InodeFailPercent', 'PatchWarnDays', 'PatchFailDays', 'AllowedPort') {
            if ($options.ContainsKey($name) -and $null -ne $options[$name]) { $splat[$name] = $options[$name] }
        }
        if ($options.SshPort) { $splat['Port'] = [int]$options.SshPort }
        $maxDisks = if ($options.MaxDiskMonitors) { [int]$options.MaxDiskMonitors } else { 20 }

        Write-Host "Linux: collecting compliance facts from $target over SSH ..." -ForegroundColor Cyan
        $inventory = Get-LinuxComplianceInventory @splat
        $facts = $inventory.Facts
        $checks = @($inventory.Checks)
        $pass = @($checks | Where-Object Status -eq 'Pass').Count
        $warn = @($checks | Where-Object Status -eq 'Warn').Count
        $fail = @($checks | Where-Object Status -eq 'Fail').Count
        Write-Host "  $($facts.OsName) / $($facts.Kernel); compliance $($inventory.Status) (pass=$pass warn=$warn fail=$fail)" -ForegroundColor Gray

        $activeBase = @{ SshContains = '1'; SshUseRegex = 'False'; SshEOLChars = 'None'; SshCredentialID = -1 }
        $perfBase = @{ SshCommandType = 'SingleCommand'; SshUseCustomRegex = '0'; SshEOLChars = 'None'; SshCredentialID = '-1' }
        $items = New-Object 'System.Collections.Generic.List[object]'

        if ($null -ne $facts.NtpSynchronized) {
            [void]$items.Add((New-DiscoveredItem -Name 'Linux - NTP Synchronized' -ItemType 'ActiveMonitor' -MonitorType 'Ssh' `
                -MonitorParams (@{ SshCommand = (Get-LinuxMonitorCommand -Kind Ntp); SshExpectedOutput = 'yes' } + $activeBase) `
                -UniqueKey 'Linux:ntp' -DeviceId $deviceId -Tags @('linux', 'ssh', 'time')))
        }
        if ($null -ne $facts.RebootRequired) {
            [void]$items.Add((New-DiscoveredItem -Name 'Linux - No Reboot Pending' -ItemType 'ActiveMonitor' -MonitorType 'Ssh' `
                -MonitorParams (@{ SshCommand = (Get-LinuxMonitorCommand -Kind Reboot); SshExpectedOutput = 'OK' } + $activeBase) `
                -UniqueKey 'Linux:reboot' -DeviceId $deviceId -Tags @('linux', 'ssh', 'patching')))
        }
        $hasSystemd = [bool]$facts.FailedUnitsAvailable
        if ($hasSystemd) {
            [void]$items.Add((New-DiscoveredItem -Name 'Linux - No Failed Systemd Units' -ItemType 'ActiveMonitor' -MonitorType 'Ssh' `
                -MonitorParams (@{ SshCommand = (Get-LinuxMonitorCommand -Kind FailedUnits); SshExpectedOutput = 'OK' } + $activeBase) `
                -UniqueKey 'Linux:failedunits' -DeviceId $deviceId -Tags @('linux', 'ssh', 'services')))
            [void]$items.Add((New-DiscoveredItem -Name 'Linux - Failed Systemd Unit Count' -ItemType 'PerformanceMonitor' -MonitorType 'Ssh' `
                -MonitorParams (@{ SshCommand = (Get-LinuxMonitorCommand -Kind FailedUnitCount) } + $perfBase) `
                -UniqueKey "Linux:${target}:failedunitcount" -DeviceId $deviceId -Tags @('linux', 'ssh', 'services')))
        }
        if ($null -ne $facts.PatchAgeDays) {
            [void]$items.Add((New-DiscoveredItem -Name 'Linux - Patch Age Days' -ItemType 'PerformanceMonitor' -MonitorType 'Ssh' `
                -MonitorParams (@{ SshCommand = (Get-LinuxMonitorCommand -Kind PatchAge) } + $perfBase) `
                -UniqueKey "Linux:${target}:patchage" -DeviceId $deviceId -Tags @('linux', 'ssh', 'patching')))
        }
        foreach ($disk in @($facts.Disks | Select-Object -First $maxDisks)) {
            [void]$items.Add((New-DiscoveredItem -Name "Linux - Disk Used % $($disk.MountPoint)" -ItemType 'PerformanceMonitor' -MonitorType 'Ssh' `
                -MonitorParams (@{ SshCommand = (Get-LinuxMonitorCommand -Kind DiskUsed -MountPoint $disk.MountPoint) } + $perfBase) `
                -UniqueKey "Linux:${target}:disk:$($disk.MountPoint)" -DeviceId $deviceId -Tags @('linux', 'ssh', 'disk')))
        }

        $failedCheckNames = @($checks | Where-Object Status -eq 'Fail' | ForEach-Object { $_.Check }) -join '; '
        $attributes = [ordered]@{
            'Linux.LastScan'           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            'Linux.Hostname'           = [string]$facts.Hostname
            'Linux.OS'                 = [string]$facts.OsName
            'Linux.OSId'               = [string]$facts.OsId
            'Linux.OSVersion'          = [string]$facts.OsVersion
            'Linux.Kernel'             = [string]$facts.Kernel
            'Linux.Architecture'       = [string]$facts.Architecture
            'Linux.UptimeDays'         = [string]$facts.UptimeDays
            'Linux.PatchAgeDays'       = [string]$facts.PatchAgeDays
            'Linux.RebootRequired'     = [string]$facts.RebootRequired
            'Linux.NtpSynchronized'    = [string]$facts.NtpSynchronized
            'Linux.FailedUnits'        = $(if ($hasSystemd) { [string]@($facts.FailedUnits).Count } else { $null })
            'Linux.ListeningPorts'     = [string]@($facts.ListeningPorts).Count
            'Linux.ComplianceStatus'   = [string]$inventory.Status
            'Linux.ComplianceFailed'   = [string]$fail
            'Linux.ComplianceWarnings' = [string]$warn
            'Linux.FailedChecks'       = $(if ($failedCheckNames) { $failedCheckNames } else { 'None' })
        }
        $cleanAttributes = @{}
        foreach ($key in $attributes.Keys) { if (-not [string]::IsNullOrWhiteSpace($attributes[$key])) { $cleanAttributes[$key] = $attributes[$key] } }

        if ($items.Count -eq 0) {
            [void]$items.Add([PSCustomObject]@{ Name = "Linux - inventory - $target"; ItemType = 'Inventory'; MonitorType = ''; MonitorParams = @{}; UniqueKey = "Linux:${target}:inventory"; DeviceId = $deviceId; Attributes = @{}; Tags = @('inventory') })
        }
        $items[0].Attributes = $cleanAttributes
        $items[0] | Add-Member -NotePropertyName 'LinuxChecks' -NotePropertyValue $checks -Force
        $items[0] | Add-Member -NotePropertyName 'LinuxFacts' -NotePropertyValue $facts -Force

        Write-Host "Linux: $target -> $(@($items | Where-Object ItemType -ne 'Inventory').Count) monitor item(s), $($cleanAttributes.Count) attribute(s)." -ForegroundColor Green
        return $items.ToArray()
    }

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBgXOvq1Jvmgfax
# wuv5tziMxRLSMWKtSlyoAjdL6aYyiKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAd
# dIR+iw4FvUW+MXEKKsCTgFXG7hl+QvmGMxhuQY6XHjANBgkqhkiG9w0BAQEFAASC
# AgB3sLrrV3FzbovYlfyN+7wWDfNgfld02WT6YYuOERCl4ZThdTApIIyuGaTK9tXD
# 8qFBl3w06/A91dTBNC+btd08Nf3YxZbmEkPI2v2jx0FxyRKWfHms6hjOF4bRGLFU
# WBp4OVFHBm/3keUwDwo/CGQcHTYIeSo1ynA5qxzX1u4oKmYYiA69hyNry1TvQrUn
# z6Er2zte0DbkB8s6PPLYmD6AL36FttthyE2dXGRyUso4TfjhGmppoD+zLMgxGN0C
# iEEvHtgRw7GwpafY8JTC1quwc+/kboBPOxg+Q/HWo4bYsj7ynCn4YsshWA4OAHMi
# WTuIPS/bWAgzCOj0k5hWJOW0KdJmyst8+W8/sWuM5BXo/yJ51xvHgsEFWdf3fcoF
# Pd6FytwTqdXgWHJPslPtR+VL4biFaYnqhxE4OWpZWXuAmCB2QqLT7MEu0Z2wJLBz
# CdTP3SU/fm0CKrUFrDp0OGZSQyenCSwJWDXUo+Mg0ruKlJExd8t3ZOggQhpwjKPf
# OJ2Ao1VBLrfXPb9pIDdamiDNWvyuRKaeH2948BCuRqLXW/NzicSQzbidjI+FGQha
# z27PNKJ2UUB6bypRxV/3ng5SU/se84iv1eGUu9Ace+4NCL13PeJOOTA/+1zby/jA
# RxmhkyjEKCh5J+YQaUdBHmMbcHSwp4YisI/g9a5t4+cgFaGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMxODMzMTJaMC8GCSqGSIb3DQEJBDEiBCBqtJiVSjwm
# vVykUjG88Z6KbfjEn2ewo7V4iAGUtjLkSjANBgkqhkiG9w0BAQEFAASCAgBezzGB
# gA9gQ+A/nFhDwQnmOC/AMuPycTPdtZU/lcD5DeckbRuxnFRhrFW9gIg1ljUeMH6Z
# pPDUNYkl0LqZTED6IQjM4vNcyXgwlYL6Rp64YMm7DLNn5ZtyaTWzYBkV2pFrdYQu
# IBT+Zi4pX3R9Pqldqj8ON75iBkn4jBBdZCMDeZGMKj9+HEOdEeA53BDgO0ZbAjSh
# wzokRllRhv5QWjrvE2v11XAoBKepWWJPoa3dO2MeX2yGqJd+z2rfdCvIi9StDNTP
# Dlhh4FLJxZ6P2ewgejE2LdA4AGSXQefZHQ5yCTYe1P0X6kPI9QJNSzF7pgLaH61u
# 2l42hn0i33K+8xO5ZILbYjKI6hG7HRXQE1pZsctqnXXbpf4LccE0RPAXAl0vcUxm
# oZwPj/Zm3AXwdHC+jsXgVB6VOa/7v7NF+c4zDWRy5N/iaAc7rWlZOX9zPGCJ+5X4
# 1mIyqzDZeBF5o1++D0Xp3Ea560/7S38cyVY8/OKZJiiMy49cr3YWL21ab8Pdpry3
# dUpZSmUV6zHf4cQx3XqXb3+FG91kDCCuF3zf87HAyUSx2YudARYGBz7P6Bsq4sWr
# 70BE7BHBXCiLP6dGUSSS3pAQ4uaQAJW0xhhqoii7Aiwlkbc4+HiGWces+mdDzaHN
# /mv+njG090F623qWvXH9HrYwVHIZ9AeC2kINvQ==
# SIG # End signature block
