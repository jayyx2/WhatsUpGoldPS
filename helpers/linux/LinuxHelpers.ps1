#requires -Version 5.1
<#
.SYNOPSIS
    SSH-based Linux fleet compliance collection and evaluation helpers.
.DESCRIPTION
    Collects OS, patch, systemd, disk, inode, NTP, listening port, reboot and
    SSH baseline facts from Linux/Unix hosts over SSH, then converts them into
    Pass/Warn/Fail compliance checks suitable for a dashboard or for driving
    WhatsUp Gold monitors.

    All parsing functions are pure (string in, objects out) so they can be
    tested without any network access. Only Get-LinuxComplianceInventory
    performs SSH I/O.

    These helpers target Linux/Unix hosts. Network operating systems such as
    Cisco IOS do not implement these shell commands and require their own
    vendor-specific collectors.
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+, helpers/ssh/WhatsUpGoldPS.Ssh for SSH transport.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>

function Get-LinuxComplianceCommand {
    <#
    .SYNOPSIS
        Returns the shell script used to collect all compliance facts in one SSH round trip.
    .DESCRIPTION
        Each section is delimited by a ===WUG:<name>=== marker so the output can be
        split deterministically by ConvertFrom-LinuxComplianceOutput.
    #>
    [CmdletBinding()]
    param()

    $collector = @'
echo "===WUG:hostname==="; hostname 2>/dev/null
echo "===WUG:osrelease==="; cat /etc/os-release 2>/dev/null
echo "===WUG:kernel==="; uname -r 2>/dev/null
echo "===WUG:arch==="; uname -m 2>/dev/null
echo "===WUG:uptime==="; cat /proc/uptime 2>/dev/null
echo "===WUG:patchepoch==="; if command -v rpm >/dev/null 2>&1; then rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null | sort -n | tail -1; elif [ -f /var/lib/dpkg/status ]; then stat -c %Y /var/lib/dpkg/status 2>/dev/null; fi
echo "===WUG:failedunits==="; systemctl list-units --state=failed --no-legend --plain 2>/dev/null
echo "===WUG:disk==="; df -P -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null
echo "===WUG:inode==="; df -P -i -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null
echo "===WUG:ntp==="; timedatectl show -p NTP -p NTPSynchronized 2>/dev/null
echo "===WUG:ports==="; ss -H -lntu 2>/dev/null || netstat -lntu 2>/dev/null
echo "===WUG:reboot==="; if [ -f /var/run/reboot-required ]; then echo yes; elif command -v needs-restarting >/dev/null 2>&1; then if needs-restarting -r >/dev/null 2>&1; then echo no; else echo yes; fi; else echo no; fi
echo "===WUG:sshd==="; sshd -T 2>/dev/null || cat /etc/ssh/sshd_config 2>/dev/null
echo "===WUG:end==="
'@

    # bash treats a trailing CR as part of the word, so 'fi' would never close an 'if'.
    return ($collector -replace "`r", '')
}

function ConvertFrom-LinuxComplianceOutput {
    <#
    .SYNOPSIS
        Splits marker-delimited collector output into a section name/text hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Output
    )

    $sections = @{}
    $currentName = $null
    $buffer = [System.Collections.Generic.List[string]]::new()

    foreach ($line in @($Output -split "`r?`n")) {
        if ($line.Trim() -match '^===WUG:([A-Za-z0-9_]+)===$') {
            if ($currentName) { $sections[$currentName] = ($buffer -join "`n") }
            $currentName = $Matches[1]
            $buffer = [System.Collections.Generic.List[string]]::new()
            continue
        }
        if ($currentName) { $buffer.Add($line) }
    }

    if ($currentName) { $sections[$currentName] = ($buffer -join "`n") }
    return $sections
}

function Get-LinuxSectionText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Sections,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Sections.ContainsKey($Name) -and $null -ne $Sections[$Name]) {
        return [string]$Sections[$Name]
    }
    return ''
}

function ConvertFrom-LinuxOsRelease {
    <#
    .SYNOPSIS
        Parses /etc/os-release KEY="value" pairs.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $values = @{}
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^([A-Za-z0-9_]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }

    $prettyName = ''
    if ($values.ContainsKey('PRETTY_NAME')) { $prettyName = $values['PRETTY_NAME'] }
    elseif ($values.ContainsKey('NAME')) { $prettyName = $values['NAME'] }

    $id = ''
    if ($values.ContainsKey('ID')) { $id = $values['ID'] }

    $version = ''
    if ($values.ContainsKey('VERSION_ID')) { $version = $values['VERSION_ID'] }

    return [pscustomobject]@{
        PrettyName = $prettyName
        Id         = $id
        VersionId  = $version
    }
}

function ConvertFrom-LinuxDfOutput {
    <#
    .SYNOPSIS
        Parses POSIX 'df -P' or 'df -P -i' output into usage rows.
    .DESCRIPTION
        Both block and inode output share the same six-column POSIX layout, so the
        returned Total/Used/Available values are blocks or inodes depending on input.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^\s*Filesystem') { continue }
        if ($trimmed -match '^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(.+)$') {
            $rows.Add([pscustomobject]@{
                Filesystem  = $Matches[1]
                Total       = [int64]$Matches[2]
                Used        = [int64]$Matches[3]
                Available   = [int64]$Matches[4]
                UsedPercent = [int]$Matches[5]
                MountPoint  = $Matches[6].Trim()
            })
        }
    }
    return @($rows)
}

function ConvertFrom-LinuxFailedUnit {
    <#
    .SYNOPSIS
        Parses 'systemctl list-units --state=failed --no-legend --plain' output.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $units = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(.*))?$') {
            $description = ''
            if ($Matches[5]) { $description = $Matches[5].Trim() }
            $units.Add([pscustomobject]@{
                Unit        = $Matches[1]
                Load        = $Matches[2]
                Active      = $Matches[3]
                Sub         = $Matches[4]
                Description = $description
            })
        }
    }
    return @($units)
}

function ConvertFrom-LinuxNtpStatus {
    <#
    .SYNOPSIS
        Parses 'timedatectl show -p NTP -p NTPSynchronized' key=value output.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $values = @{}
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^([A-Za-z0-9_]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }

    $enabled = $null
    if ($values.ContainsKey('NTP')) { $enabled = ($values['NTP'] -eq 'yes') }

    $synchronized = $null
    if ($values.ContainsKey('NTPSynchronized')) { $synchronized = ($values['NTPSynchronized'] -eq 'yes') }

    return [pscustomobject]@{
        Enabled      = $enabled
        Synchronized = $synchronized
    }
}

function ConvertFrom-LinuxListeningPort {
    <#
    .SYNOPSIS
        Parses listening sockets from 'ss -H -lntu' or 'netstat -lntu' output.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^(Netid|Proto|Active)') { continue }

        $protocol = $null
        $localEndpoint = $null
        $extra = ''

        if ($trimmed -match '^(tcp|udp)\S*\s+(?:LISTEN|UNCONN)\s+\d+\s+\d+\s+(\S+)\s+\S+(?:\s+(.*))?$') {
            $protocol = $Matches[1]
            $localEndpoint = $Matches[2]
            if ($Matches[3]) { $extra = $Matches[3].Trim() }
        }
        elseif ($trimmed -match '^(tcp6?|udp6?)\s+\d+\s+\d+\s+(\S+)\s+\S+(?:\s+\S+)?$') {
            $protocol = $Matches[1]
            $localEndpoint = $Matches[2]
        }

        if (-not $localEndpoint) { continue }

        $separatorIndex = $localEndpoint.LastIndexOf(':')
        if ($separatorIndex -lt 0) { continue }

        $address = $localEndpoint.Substring(0, $separatorIndex)
        $portText = $localEndpoint.Substring($separatorIndex + 1)
        $port = 0
        if (-not [int]::TryParse($portText, [ref]$port)) { continue }

        $process = ''
        if ($extra -match 'users:\(\("([^"]+)"') { $process = $Matches[1] }

        $rows.Add([pscustomobject]@{
            Protocol     = $protocol
            LocalAddress = $address
            Port         = $port
            Process      = $process
        })
    }
    return @($rows)
}

function ConvertFrom-LinuxSshdSetting {
    <#
    .SYNOPSIS
        Parses 'sshd -T' output or sshd_config into a lowercase key/value hashtable.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $settings = @{}
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^([A-Za-z][A-Za-z0-9]*)[\s=]+(.+)$') {
            $key = $Matches[1].ToLowerInvariant()
            if (-not $settings.ContainsKey($key)) {
                $settings[$key] = $Matches[2].Trim()
            }
        }
    }
    return $settings
}

function Get-LinuxComplianceFact {
    <#
    .SYNOPSIS
        Converts parsed collector sections into a single facts object.
    .PARAMETER ReferenceTime
        Time used to calculate patch age and uptime. Override for deterministic tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Sections,
        [string]$Target = '',
        [datetime]$ReferenceTime = (Get-Date)
    )

    $os = ConvertFrom-LinuxOsRelease -Text (Get-LinuxSectionText -Sections $Sections -Name 'osrelease')

    $uptimeDays = $null
    $uptimeText = (Get-LinuxSectionText -Sections $Sections -Name 'uptime').Trim()
    if ($uptimeText -match '^([0-9]+(?:\.[0-9]+)?)') {
        $uptimeDays = [Math]::Round([double]$Matches[1] / 86400, 2)
    }

    $lastPatchTime = $null
    $patchAgeDays = $null
    $patchText = (Get-LinuxSectionText -Sections $Sections -Name 'patchepoch').Trim()
    if ($patchText -match '^([0-9]{6,})$') {
        $lastPatchTime = [datetimeoffset]::FromUnixTimeSeconds([int64]$Matches[1]).LocalDateTime
        $patchAgeDays = [Math]::Round(($ReferenceTime - $lastPatchTime).TotalDays, 1)
    }

    $rebootText = (Get-LinuxSectionText -Sections $Sections -Name 'reboot').Trim()
    $rebootRequired = $null
    if ($rebootText -match '^(yes|no)$') { $rebootRequired = ($rebootText -eq 'yes') }

    $hostname = (Get-LinuxSectionText -Sections $Sections -Name 'hostname').Trim()
    $ntp = ConvertFrom-LinuxNtpStatus -Text (Get-LinuxSectionText -Sections $Sections -Name 'ntp')

    return [pscustomobject]@{
        Target         = $Target
        Hostname       = $hostname
        OsName         = $os.PrettyName
        OsId           = $os.Id
        OsVersion      = $os.VersionId
        Kernel         = (Get-LinuxSectionText -Sections $Sections -Name 'kernel').Trim()
        Architecture   = (Get-LinuxSectionText -Sections $Sections -Name 'arch').Trim()
        UptimeDays     = $uptimeDays
        LastPatchTime  = $lastPatchTime
        PatchAgeDays   = $patchAgeDays
        FailedUnits    = @(ConvertFrom-LinuxFailedUnit -Text (Get-LinuxSectionText -Sections $Sections -Name 'failedunits'))
        Disks          = @(ConvertFrom-LinuxDfOutput -Text (Get-LinuxSectionText -Sections $Sections -Name 'disk'))
        Inodes         = @(ConvertFrom-LinuxDfOutput -Text (Get-LinuxSectionText -Sections $Sections -Name 'inode'))
        NtpEnabled     = $ntp.Enabled
        NtpSynchronized = $ntp.Synchronized
        ListeningPorts = @(ConvertFrom-LinuxListeningPort -Text (Get-LinuxSectionText -Sections $Sections -Name 'ports'))
        RebootRequired = $rebootRequired
        SshdSettings   = (ConvertFrom-LinuxSshdSetting -Text (Get-LinuxSectionText -Sections $Sections -Name 'sshd'))
    }
}

function New-LinuxComplianceCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warn', 'Fail', 'Unknown')][string]$Status,
        [AllowEmptyString()][string]$Value = '',
        [AllowEmptyString()][string]$Detail = ''
    )

    return [pscustomobject]@{
        Target   = $Target
        Category = $Category
        Check    = $Check
        Status   = $Status
        Value    = $Value
        Detail   = $Detail
    }
}

function Get-LinuxComplianceCheck {
    <#
    .SYNOPSIS
        Evaluates a facts object against compliance thresholds.
    .PARAMETER AllowedPort
        When supplied, any listening port outside this list is reported as a warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Facts,
        [int]$DiskWarnPercent = 85,
        [int]$DiskFailPercent = 95,
        [int]$InodeWarnPercent = 85,
        [int]$InodeFailPercent = 95,
        [int]$PatchWarnDays = 30,
        [int]$PatchFailDays = 90,
        [int[]]$AllowedPort
    )

    $target = [string]$Facts.Target
    $checks = [System.Collections.Generic.List[object]]::new()

    $osValue = $Facts.OsName
    if (-not $osValue) { $osValue = 'unknown' }
    $osStatus = 'Pass'
    if (-not $Facts.OsName -or -not $Facts.Kernel) { $osStatus = 'Unknown' }
    $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Inventory' -Check 'OS and kernel' -Status $osStatus `
        -Value "$osValue / $($Facts.Kernel)" -Detail "Architecture: $($Facts.Architecture); uptime days: $($Facts.UptimeDays)"))

    if ($null -eq $Facts.PatchAgeDays) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Patching' -Check 'Package patch age' -Status 'Unknown' `
            -Value '' -Detail 'No package manager timestamp was returned.'))
    }
    else {
        $patchStatus = 'Pass'
        if ($Facts.PatchAgeDays -ge $PatchFailDays) { $patchStatus = 'Fail' }
        elseif ($Facts.PatchAgeDays -ge $PatchWarnDays) { $patchStatus = 'Warn' }
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Patching' -Check 'Package patch age' -Status $patchStatus `
            -Value "$($Facts.PatchAgeDays) days" -Detail "Last package change: $($Facts.LastPatchTime); warn at $PatchWarnDays, fail at $PatchFailDays days."))
    }

    $failedUnits = @($Facts.FailedUnits)
    if ($failedUnits.Count -eq 0) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Services' -Check 'Failed systemd units' -Status 'Pass' -Value '0'))
    }
    else {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Services' -Check 'Failed systemd units' -Status 'Fail' `
            -Value ([string]$failedUnits.Count) -Detail (($failedUnits | ForEach-Object { $_.Unit }) -join ', ')))
    }

    foreach ($disk in @($Facts.Disks)) {
        $diskStatus = 'Pass'
        if ($disk.UsedPercent -ge $DiskFailPercent) { $diskStatus = 'Fail' }
        elseif ($disk.UsedPercent -ge $DiskWarnPercent) { $diskStatus = 'Warn' }
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Disk' -Check "Disk usage $($disk.MountPoint)" -Status $diskStatus `
            -Value "$($disk.UsedPercent)%" -Detail "Filesystem: $($disk.Filesystem); warn at $DiskWarnPercent%, fail at $DiskFailPercent%."))
    }

    foreach ($inode in @($Facts.Inodes)) {
        $inodeStatus = 'Pass'
        if ($inode.UsedPercent -ge $InodeFailPercent) { $inodeStatus = 'Fail' }
        elseif ($inode.UsedPercent -ge $InodeWarnPercent) { $inodeStatus = 'Warn' }
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Inode' -Check "Inode usage $($inode.MountPoint)" -Status $inodeStatus `
            -Value "$($inode.UsedPercent)%" -Detail "Filesystem: $($inode.Filesystem); warn at $InodeWarnPercent%, fail at $InodeFailPercent%."))
    }

    if ($null -eq $Facts.NtpSynchronized) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Time' -Check 'NTP synchronization' -Status 'Unknown' `
            -Detail 'timedatectl did not report NTP state.'))
    }
    elseif ($Facts.NtpSynchronized) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Time' -Check 'NTP synchronization' -Status 'Pass' -Value 'synchronized'))
    }
    else {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Time' -Check 'NTP synchronization' -Status 'Fail' `
            -Value 'not synchronized' -Detail "NTP service enabled: $($Facts.NtpEnabled)"))
    }

    if ($null -eq $Facts.RebootRequired) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Patching' -Check 'Reboot required' -Status 'Unknown'))
    }
    elseif ($Facts.RebootRequired) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Patching' -Check 'Reboot required' -Status 'Warn' -Value 'yes' `
            -Detail 'Host is pending a reboot to complete updates.'))
    }
    else {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Patching' -Check 'Reboot required' -Status 'Pass' -Value 'no'))
    }

    $ports = @($Facts.ListeningPorts)
    $portList = (@($ports | ForEach-Object { "$($_.Protocol)/$($_.Port)" } | Sort-Object -Unique) -join ', ')
    if ($PSBoundParameters.ContainsKey('AllowedPort') -and $AllowedPort) {
        $unexpected = @($ports | Where-Object { $AllowedPort -notcontains $_.Port })
        if ($unexpected.Count -gt 0) {
            $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Network' -Check 'Listening ports' -Status 'Warn' `
                -Value ([string]$ports.Count) -Detail ('Unexpected: ' + ((@($unexpected | ForEach-Object { "$($_.Protocol)/$($_.Port)" } | Sort-Object -Unique)) -join ', '))))
        }
        else {
            $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Network' -Check 'Listening ports' -Status 'Pass' `
                -Value ([string]$ports.Count) -Detail $portList))
        }
    }
    else {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Network' -Check 'Listening ports' -Status 'Pass' `
            -Value ([string]$ports.Count) -Detail $portList))
    }

    $sshd = $Facts.SshdSettings
    if ($sshd -isnot [hashtable]) { $sshd = @{} }

    $baseline = @(
        @{ Key = 'permitrootlogin';      Check = 'SSH root login';            Bad = 'yes'; Status = 'Fail' },
        @{ Key = 'permitemptypasswords'; Check = 'SSH empty passwords';       Bad = 'yes'; Status = 'Fail' },
        @{ Key = 'passwordauthentication'; Check = 'SSH password auth';       Bad = 'yes'; Status = 'Warn' },
        @{ Key = 'x11forwarding';        Check = 'SSH X11 forwarding';        Bad = 'yes'; Status = 'Warn' }
    )

    foreach ($rule in $baseline) {
        if (-not $sshd.ContainsKey($rule.Key)) {
            $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Security' -Check $rule.Check -Status 'Unknown' `
                -Detail "sshd did not report $($rule.Key)."))
            continue
        }
        $value = [string]$sshd[$rule.Key]
        $status = 'Pass'
        if ($value.Trim().ToLowerInvariant() -eq $rule.Bad) { $status = $rule.Status }
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Security' -Check $rule.Check -Status $status -Value $value))
    }

    return @($checks)
}

function Get-LinuxComplianceStatus {
    <#
    .SYNOPSIS
        Reduces a set of checks to the worst observed status.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Checks)

    if (@($Checks | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { return 'Fail' }
    if (@($Checks | Where-Object { $_.Status -eq 'Warn' }).Count -gt 0) { return 'Warn' }
    if (@($Checks | Where-Object { $_.Status -eq 'Pass' }).Count -gt 0) { return 'Pass' }
    return 'Unknown'
}

function Get-LinuxComplianceSummary {
    <#
    .SYNOPSIS
        Aggregates check counts per target.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Checks)

    $summary = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($Checks | Group-Object -Property Target)) {
        $items = @($group.Group)
        $summary.Add([pscustomobject]@{
            Target  = $group.Name
            Status  = (Get-LinuxComplianceStatus -Checks $items)
            Pass    = @($items | Where-Object { $_.Status -eq 'Pass' }).Count
            Warn    = @($items | Where-Object { $_.Status -eq 'Warn' }).Count
            Fail    = @($items | Where-Object { $_.Status -eq 'Fail' }).Count
            Unknown = @($items | Where-Object { $_.Status -eq 'Unknown' }).Count
        })
    }
    return @($summary)
}

function Get-LinuxComplianceInventory {
    <#
    .SYNOPSIS
        Collects and evaluates Linux compliance facts for a single host over SSH.
    .PARAMETER Target
        Hostname or IP address of the Linux host.
    .PARAMETER Username
        SSH username.
    .PARAMETER Password
        SSH password as plaintext. Prefer -SecurePassword or -KeyFile.
    .PARAMETER SecurePassword
        SSH password as a SecureString.
    .PARAMETER KeyFile
        Private key path for key-based authentication.
    .EXAMPLE
        Get-LinuxComplianceInventory -Target 10.0.0.10 -Username audit -KeyFile ~/.ssh/id_ed25519
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Username,
        [string]$Password,
        [System.Security.SecureString]$SecurePassword,
        [string]$KeyFile,
        [string]$KeyPassphrase,
        [int]$Port = 22,
        [int]$TimeoutSeconds = 60,
        [int]$DiskWarnPercent = 85,
        [int]$DiskFailPercent = 95,
        [int]$InodeWarnPercent = 85,
        [int]$InodeFailPercent = 95,
        [int]$PatchWarnDays = 30,
        [int]$PatchFailDays = 90,
        [int[]]$AllowedPort,
        [string]$SshModulePath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'helpers\ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psm1')
    )

    if (-not (Test-Path -LiteralPath $SshModulePath)) {
        $fallback = Join-Path (Split-Path $PSScriptRoot -Parent) 'ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psm1'
        if (Test-Path -LiteralPath $fallback) { $SshModulePath = $fallback }
        else { throw "SSH module not found: $SshModulePath" }
    }
    Import-Module -Name $SshModulePath -Force -ErrorAction Stop

    $splat = @{ HostName = $Target; Port = $Port; Username = $Username; TimeoutSeconds = $TimeoutSeconds }
    if ($Password) { $splat['Password'] = $Password }
    if ($SecurePassword) { $splat['SecurePassword'] = $SecurePassword }
    if ($KeyFile) {
        $resolvedKeyFile = $null
        try { $resolvedKeyFile = (Resolve-Path -Path $KeyFile -ErrorAction Stop).ProviderPath }
        catch { throw "Key file not found: $KeyFile" }
        $splat['KeyFile'] = $resolvedKeyFile
    }
    if ($KeyPassphrase) { $splat['KeyPassphrase'] = $KeyPassphrase }

    $session = New-SshSession @splat
    try {
        $result = Invoke-SshCommand -Session $session -Command (Get-LinuxComplianceCommand) -TimeoutSeconds $TimeoutSeconds
    }
    finally {
        Close-SshSession -Session $session
    }

    $sections = ConvertFrom-LinuxComplianceOutput -Output $result.Output
    if (-not $sections.ContainsKey('end')) {
        throw "Compliance collection on $Target did not complete. stderr: $($result.Error)"
    }

    $facts = Get-LinuxComplianceFact -Sections $sections -Target $Target

    $checkSplat = @{
        Facts            = $facts
        DiskWarnPercent  = $DiskWarnPercent
        DiskFailPercent  = $DiskFailPercent
        InodeWarnPercent = $InodeWarnPercent
        InodeFailPercent = $InodeFailPercent
        PatchWarnDays    = $PatchWarnDays
        PatchFailDays    = $PatchFailDays
    }
    if ($AllowedPort) { $checkSplat['AllowedPort'] = $AllowedPort }
    $checks = @(Get-LinuxComplianceCheck @checkSplat)

    return [pscustomobject]@{
        Target      = $Target
        CollectedAt = (Get-Date)
        Status      = (Get-LinuxComplianceStatus -Checks $checks)
        Facts       = $facts
        Checks      = $checks
    }
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCLnWqaGyTMWv+h
# Ext/dQSL8curShxtLECywALJB4DmIKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCBDmJmrFpb1afaMpIi7KL8r6CCDvFx8sDOww1zI1iZRKTANBgkqhkiG9w0BAQEF
# AASCAgBeFmf6VkVDo/zZI7MQW+1f6NjlzxDSjvOUwsJJfeXsAdiHZRcAXcNRAzkl
# Iby4fJWhedaXaA3sljIZqL9l5YN+JCGiC2z2hc71/emmIENOBjeR+7lg7mNV6zNa
# 4ac5C2W71ip6yJV1CxcWiG5KqvwHt++NrN/xc7P8UIdb5StKFe8JZPDXItqGyWbp
# hSAXxoK7MXXHcoCAYW619bVuHItGBCiQDMZDZEdLqyPaHfZdWEgVHDf+jk45eZCr
# V6LA7WsHl4zpiwKfmpEtzOwA0w/B3Z+IItDkAXLREr/UWXgNbtQ4neqJvqw7u50i
# PyjQD1cMHL5EShVvugFG+oPXszD/SXWtF5KYjrnx1V2gBq1XTRZ3o8oFJcKuvyPC
# yannMdfKURIcsn8tAKC+5Nq2QY1iblKYhvMsewzzwp5DaQMU7wLApmorhcMfhkaH
# CyvRAAe8hSayj+q0K3/uDXxugwr5hvwZ7v4bO2L/LuGBvfqAo9rG1EYql/34K9S2
# cIrzbPEPCpX+3HteN7dbN/2GLlhaHESJ6O7l5E9e3GK0inyQIFdhIusKe8CjQZ6/
# yd3khnJNzb6Z5z3uzjWtmizNKlcjIvsArE+quvmjAjdlXkmhKRp4n7zk25aLOPtr
# SwpYipIJEEyivkjRzxplh4mXSohrqtDJr9jSxmjX3g3hna3mOaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkxODI1MjRaMC8GCSqGSIb3DQEJBDEiBCAnHucb
# DH0fMtmToyRphQAuWnKlJpVOBPyFJUOGxSIskTANBgkqhkiG9w0BAQEFAASCAgCQ
# 4sey5dgBZFVBGgdq+cwr66AoJcEodxBMdNwmI64jX61ZnCQgkuTJHnLpdYI2V9P4
# jajp3pSJCI5g07CkS19RNx7c0WP0oHL+DqPPMN0Xy1n/HLoCsbmJfDRjFWWDaMlZ
# JVNR/+r4q0drnwTVRgV5z8MfrbjScnfdpuX56uicyCdzosFgu3fneWsf3fkmMnXL
# nM2DVaHk4f49WhZaxRLeRN2L2V+5ZGY2DelaQmAszL79V3J6j75adqJJ3qZcLrQe
# dZ2gF0LnGsBOR2YbuPdhtd6pHyGtib2R2nxZ+xJUt6kRqZyvvUnjwK7Ww1/B3mIP
# HtM7LOZ4CbDIhWLx80GmUmbDLP3mOiHKMSlxuhSNHuTN5S7Beb7wZw1YyyoPiJCC
# /+oTxgt6v3BA7aYVH6BgOahkEAtKSxbAhEEurIDgCynVRfRsVNYgj0Csoep/s3yw
# 2Z6rzcNdY5wXRTJF41AzCwl29V6I5BjjEJjBEE1FkiM2Gj7WQ94xTw3oGNspJ1Ah
# c9O2ZWK1tpecuV9LDrkgv9Ffo+Rm57YNXbh+TNCIJM7MRS1Peg+3YrgKp7rBsy7X
# NDdJKahBmPrH9uP+nmZyiO/BclFuULXD/mDhVBu21qYnxdscqYUNgvOk7SJq9cuy
# esHzITcuDrLimETdD6Buyg99qCQW3AP6oc09ZsHhLQ==
# SIG # End signature block
