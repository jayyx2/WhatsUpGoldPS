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
echo "===WUG:failedunits==="; systemctl list-units --state=failed --no-legend --plain 2>/dev/null; failed_units_status=$?
echo "===WUG:failedunitsstatus==="; echo "$failed_units_status"
echo "===WUG:disk==="; df -P -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null
echo "===WUG:inode==="; df -P -i -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null
echo "===WUG:ntp==="; timedatectl show -p NTP -p NTPSynchronized 2>/dev/null
echo "===WUG:ports==="; ss -H -lntu 2>/dev/null || netstat -lntu 2>/dev/null
echo "===WUG:reboot==="; if [ -f /var/run/reboot-required ]; then echo yes; elif command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r >/dev/null 2>&1; r=$?; case "$r" in 0) echo no;; 1) echo yes;; *) echo unknown;; esac; elif [ -f /var/lib/dpkg/status ]; then echo no; else echo unknown; fi
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
    $patchEpoch = 0L
    if ([long]::TryParse($patchText, [ref]$patchEpoch) -and $patchEpoch -gt 0 -and
        $patchEpoch -le ([datetimeoffset]$ReferenceTime).ToUnixTimeSeconds()) {
        $lastPatchTime = [datetimeoffset]::FromUnixTimeSeconds($patchEpoch).LocalDateTime
        $patchAgeDays = [Math]::Round(($ReferenceTime - $lastPatchTime).TotalDays, 1)
    }

    $rebootText = (Get-LinuxSectionText -Sections $Sections -Name 'reboot').Trim()
    $rebootRequired = $null
    if ($rebootText -match '^(yes|no)$') { $rebootRequired = ($rebootText -eq 'yes') }

    $hostname = (Get-LinuxSectionText -Sections $Sections -Name 'hostname').Trim()
    $ntp = ConvertFrom-LinuxNtpStatus -Text (Get-LinuxSectionText -Sections $Sections -Name 'ntp')
    $failedUnitsAvailable = $Sections.ContainsKey('failedunits')
    if ($Sections.ContainsKey('failedunitsstatus')) {
        $failedUnitsAvailable = (Get-LinuxSectionText -Sections $Sections -Name 'failedunitsstatus').Trim() -eq '0'
    }

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
        FailedUnitsAvailable = $failedUnitsAvailable
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
    if ($Facts.PSObject.Properties['FailedUnitsAvailable'] -and -not $Facts.FailedUnitsAvailable) {
        $checks.Add((New-LinuxComplianceCheck -Target $target -Category 'Services' -Check 'Failed systemd units' -Status 'Unknown' `
            -Detail 'systemctl failed or did not return a collection result.'))
    }
    elseif ($failedUnits.Count -eq 0) {
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
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBF6DNjoedWD4ec
# w/cc0I67Bzsvmra2d8FE5brX3EPCsqCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# J3ztOZkDvPuU5Mv8hXxXK+3boFCpqa2uR2dr7f/MFjANBgkqhkiG9w0BAQEFAASC
# AgDimJnwWtwA2gL68JAoGz6sW4sLy3PGYo2eGSi7WK5FKMvsY3295sQqlK/OhvY0
# 7WoRdFYBZeAIZe66vFMAgkZ6OrLa117Ayx7H8zQm6RBlHYXbBsVNsIhuzvHKF00j
# Ifcoc1V7RORxkhpnb8oxt0non0nXggNZmO45m7HGcNDN8lxw8xQneappfOyDG8Vk
# uoYndVlLUkUlLQ0QSYdytnW7fS1FFxZSsy8evthS03S4zbNLTHq0KLpbX0/nR/6W
# dCumrKFveCLkuhypssjVe26mIsVhU/BtG5Kc28ChA+hbDU68CWIV/dPpjzcpwVJf
# ABQLFIumYSxBynY32KJuyuIxXRx+UBjtaSq9nlRmUluiG7GPtprYZ32f/FcveunS
# ZWhhTmPOtTuA9sM2vNPHEl6SxPcoUXaZTlVu6u1Z6l7ArC4sjyloiIeKSCS3fi7r
# dXc/g+9AiqpKaGWpvP8XMrqq4b5qP9JRSiM+lwsPWYnjoGh2BZkCYhtwpCJ8YbQj
# zWwyT1pIU1ORERyrUjqyWfnAGusyUjB0L5X3KhhMNlYXepZ/SsbDGfOFpBLjsT1T
# duRYJiPkQ8gNr+cWnD+NcNWLuQjMKcjEju0Y8IJdD1HWXX/wFHczgPB8h6AA0G2u
# tUHgtcDewQ0+Siir5VTprqhssmqKm01mLDSct35Gei5YT6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMxODMzMjhaMC8GCSqGSIb3DQEJBDEiBCC1Mri3gDJ3
# G0+z6xSimJB/SVLZqiUdFIfEK+2TglvfHjANBgkqhkiG9w0BAQEFAASCAgA6G2YG
# C51OE5dehuIFzeQNqbKlH6Q/7YvpFMWshSHJnz7s8Tqd8jP4/fTV7qsTGgeuqfc3
# Vr5gUdUDI3/c1vYB93nqxWIsCOBeL5Yzn3GCpf1FzKK5gHNIP02feq7V6+Y1InN0
# 2OQGlPM/Mi3q2QMZIaYQdLcrAizABoRVpotPuO1rR0iYyppT+Jl2t4j9ozWyQMCR
# eiwUWMMfwX0QUvlKkVOn6DO+bVvy7M3QBxjardZltsjMX46ThuN//qnSsIMZmHGc
# 1O2oZ3GrY7ZnWg1Woze71ESrjHR9/ZD1VDc/C7n3OdKQ2FiGm6hV7e3SqblyAUUy
# MuuyYEYjdeCDtiOQZvwl7SIz2pltuYR9cqchOlc/AlA5ufFCGn8t2P4ze70+XYHW
# /VCDgIK3vvBhxVKvCcYAdTMCPqGTCKo7e6otas09zHjZV1a8MhAOzvmN2KV55HLW
# iFqiEfkHD4Ix2nVuK09kdGtdcIsNz4LUDgtMO4doutJ2GABYllIZCLMCB1cwkQdo
# /8XdjLDR/PiNatRXLP1V6fANKb1RLD5x/9eyXoH3kgnCmdx6atspU7v07RIy8xBy
# fEF8ayW139GRxrCWVdEiFruw8KfhWwBvhpZD70yUIGqI9YEJ7caGR/0oHUL8yjVD
# l3uWyPn12HNDHgRU6cCEvnZiPzOYbOzp1HRtQw==
# SIG # End signature block
