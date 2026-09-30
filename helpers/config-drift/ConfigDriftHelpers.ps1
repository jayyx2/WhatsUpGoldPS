#requires -Version 5.1
<#
.SYNOPSIS
    Configuration drift auditing with a self-contained baseline store.
.DESCRIPTION
    Provides golden-configuration tracking, line-level diffing, policy rule
    evaluation and cross-device consistency checks without depending on Git or
    any other external tool. Baselines are kept in a local folder with a JSON
    index, hashed with SHA-256, and versioned by timestamp.

    This complements WhatsUp Gold Config Management rather than replacing it:
    it adds custom policy checks, peer-group comparison and dashboard output.

    Every function except Get-ConfigViaSsh is pure, so the whole engine can be
    tested offline.
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+, helpers/ssh/WhatsUpGoldPS.Ssh for SSH collection.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>

# ============================================================================
# region  Normalization
# ============================================================================

function Get-ConfigVendorProfile {
    <#
    .SYNOPSIS
        Returns collection commands and volatile-line ignore patterns per platform.
    .PARAMETER Name
        Profile name: cisco-ios, cisco-nxos, cisco-asa, linux, generic.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('cisco-ios', 'cisco-nxos', 'cisco-asa', 'linux', 'generic')]
        [string]$Name = 'generic'
    )

    $profiles = @{
        'cisco-ios' = @{
            Command       = @('show running-config')
            SetupCommand  = @('terminal length 0')
            PromptPattern = '(?m)^[^\r\n]*[>#]\s*$'
            CommentPrefix = '!'
            IgnorePattern = @(
                '^Building configuration',
                '^Current configuration\s*:',
                '^!\s*Last configuration change',
                '^!\s*NVRAM config last updated',
                '^ntp clock-period',
                '^!\s*Time:'
            )
            IgnoreBlock   = @(
                @{ Start = '^crypto pki certificate chain'; End = '^\s*quit\s*$' }
            )
        }
        'cisco-nxos' = @{
            Command       = @('show running-config')
            SetupCommand  = @('terminal length 0')
            PromptPattern = '(?m)^[^\r\n]*[>#]\s*$'
            CommentPrefix = '!'
            IgnorePattern = @(
                '^!Time:',
                '^!Command:',
                '^!Running configuration last done'
            )
            IgnoreBlock   = @(
                @{ Start = '^crypto ca certificate'; End = '^\s*quit\s*$' }
            )
        }
        'cisco-asa' = @{
            Command       = @('show running-config')
            SetupCommand  = @('terminal pager 0')
            PromptPattern = '(?m)^[^\r\n]*[>#]\s*$'
            CommentPrefix = '!'
            IgnorePattern = @(
                '^:\s*Saved',
                '^:\s*Written by',
                '^:\s*Serial Number',
                '^:\s*Hardware'
            )
            IgnoreBlock   = @(
                @{ Start = '^crypto ca certificate chain'; End = '^\s*quit\s*$' }
            )
        }
        'linux' = @{
            Command       = @()
            SetupCommand  = @()
            PromptPattern = '(?m)^[^\r\n]*[\$#]\s*$'
            CommentPrefix = '#'
            IgnorePattern = @(
                '^\s*#\s*Generated on',
                '^\s*#\s*Last modified'
            )
            IgnoreBlock   = @(
                @{ Start = '^-+BEGIN [A-Z ]*(CERTIFICATE|PRIVATE KEY)-+'; End = '^-+END [A-Z ]*(CERTIFICATE|PRIVATE KEY)-+' }
            )
        }
        'generic' = @{
            Command       = @()
            SetupCommand  = @()
            PromptPattern = '(?m)^[^\r\n]*[>#\$]\s*$'
            CommentPrefix = ''
            IgnorePattern = @()
            IgnoreBlock   = @()
        }
    }

    $selected = $profiles[$Name]
    return [pscustomobject]@{
        Name          = $Name
        Command       = @($selected.Command)
        SetupCommand  = @($selected.SetupCommand)
        PromptPattern = $selected.PromptPattern
        CommentPrefix = $selected.CommentPrefix
        IgnorePattern = @($selected.IgnorePattern)
        IgnoreBlock   = @($selected.IgnoreBlock)
    }
}

function Get-ConfigSection {
    <#
    .SYNOPSIS
        Splits a configuration into indentation-based sections.
    .DESCRIPTION
        A section starts at a non-indented line and includes the indented lines
        beneath it. A comment line such as "!" terminates the current section.
        Global one-line commands come back as single-line sections, so every
        line belongs to exactly one section.
    .OUTPUTS
        Objects with Header, StartIndex, EndIndex and Lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()]$Config,
        [string]$CommentPrefix = ''
    )

    $lines = @()
    if ($Config -is [string]) { $lines = @($Config -split "`r?`n") }
    elseif ($null -ne $Config) { $lines = @($Config) }

    $sections = [System.Collections.Generic.List[object]]::new()
    $current = $null

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $text = ([string]$lines[$i]).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($CommentPrefix -and $text.Trim().StartsWith($CommentPrefix)) {
            $current = $null
            continue
        }

        if ($text -match '^[ \t]') {
            if ($current) { $current.EndIndex = $i; $current.Lines.Add($text) }
            continue
        }

        $current = [pscustomobject]@{
            Header     = $text
            StartIndex = $i
            EndIndex   = $i
            Lines      = [System.Collections.Generic.List[string]]::new()
        }
        $current.Lines.Add($text)
        $sections.Add($current)
    }

    return @($sections)
}

function ConvertTo-NormalizedConfig {
    <#
    .SYNOPSIS
        Normalizes a configuration into comparable lines.
    .DESCRIPTION
        Drops volatile lines matching IgnorePattern, optionally removes comments
        and blank lines, and trims trailing whitespace so cosmetic changes do not
        register as drift.
    .PARAMETER IgnorePattern
        Regular expressions for lines that must never count as drift.
    .PARAMETER IgnoreBlock
        Hashtables with Start and End regular expressions. The anchor line is
        kept so a deleted block is still detected, but the volatile body is
        dropped. Use this for certificate chains and key material that are
        regenerated without any real configuration change.
    .PARAMETER IgnoreSection
        Wildcard patterns matched against section headers. The header is kept and
        the indented body is dropped. Easier than IgnoreBlock because there is no
        terminator to get right.
    .PARAMETER IncludePattern
        When supplied, only lines matching one of these expressions are audited.
    .PARAMETER IncludeBlock
        When supplied, only lines inside these Start/End regions are audited.
        The Start line is kept and the End line is treated as a terminator.
    .PARAMETER IncludeSection
        Wildcard patterns matched against section headers, for example
        'interface *'. Include filters combine, so a line survives when it
        matches any of IncludePattern, IncludeBlock or IncludeSection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()]$Config,
        [string[]]$IgnorePattern = @(),
        [hashtable[]]$IgnoreBlock = @(),
        [string[]]$IgnoreSection = @(),
        [string[]]$IncludePattern = @(),
        [hashtable[]]$IncludeBlock = @(),
        [string[]]$IncludeSection = @(),
        [string]$CommentPrefix = '',
        [switch]$KeepComments,
        [switch]$KeepBlankLines
    )

    $lines = @()
    if ($Config -is [string]) { $lines = @($Config -split "`r?`n") }
    elseif ($null -ne $Config) { $lines = @($Config) }

    $activeIncludeBlocks = @(@($IncludeBlock) | Where-Object { $null -ne $_ -and $_.Start })
    $activeIncludePatterns = @(@($IncludePattern) | Where-Object { $_ })
    $activeIncludeSections = @(@($IncludeSection) | Where-Object { $_ })
    $activeIgnoreSections = @(@($IgnoreSection) | Where-Object { $_ })

    $inIncludedSection = New-Object 'bool[]' ($lines.Count)
    $inIgnoredSectionBody = New-Object 'bool[]' ($lines.Count)

    if ($activeIncludeSections.Count -gt 0 -or $activeIgnoreSections.Count -gt 0) {
        foreach ($section in @(Get-ConfigSection -Config $lines -CommentPrefix $CommentPrefix)) {
            foreach ($pattern in $activeIncludeSections) {
                if ($section.Header -like $pattern) {
                    for ($i = $section.StartIndex; $i -le $section.EndIndex; $i++) { $inIncludedSection[$i] = $true }
                    break
                }
            }
            foreach ($pattern in $activeIgnoreSections) {
                if ($section.Header -like $pattern) {
                    for ($i = $section.StartIndex + 1; $i -le $section.EndIndex; $i++) { $inIgnoredSectionBody[$i] = $true }
                    break
                }
            }
        }
    }

    $useInclude = ($activeIncludeBlocks.Count -gt 0 -or $activeIncludePatterns.Count -gt 0 -or $activeIncludeSections.Count -gt 0)

    $kept = [System.Collections.Generic.List[string]]::new()
    $includeEndPattern = $null
    $blockEndPattern = $null

    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $text = ([string]$lines[$idx]).TrimEnd()

        if ($useInclude) {
            $selected = $false
            if ($includeEndPattern) {
                if ($text -match $includeEndPattern) { $includeEndPattern = $null }
                else { $selected = $true }
            }
            else {
                foreach ($block in $activeIncludeBlocks) {
                    if ($text -match $block.Start) {
                        $selected = $true
                        if ($block.End) { $includeEndPattern = $block.End }
                        break
                    }
                }
                if (-not $selected -and $inIncludedSection[$idx]) { $selected = $true }
                if (-not $selected) {
                    foreach ($pattern in $activeIncludePatterns) {
                        if ($text -match $pattern) { $selected = $true; break }
                    }
                }
            }
            if (-not $selected) { continue }
        }

        if ($blockEndPattern) {
            if ($text -match $blockEndPattern) { $blockEndPattern = $null }
            continue
        }

        if ($inIgnoredSectionBody[$idx]) { continue }

        if (-not $KeepBlankLines -and [string]::IsNullOrWhiteSpace($text)) { continue }

        if (-not $KeepComments -and $CommentPrefix -and $text.Trim().StartsWith($CommentPrefix)) { continue }

        $skip = $false
        foreach ($pattern in @($IgnorePattern)) {
            if (-not $pattern) { continue }
            if ($text -match $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }

        $startedBlock = $false
        foreach ($block in @($IgnoreBlock)) {
            if ($null -eq $block -or -not $block.Start) { continue }
            if ($text -match $block.Start) {
                $kept.Add($text)
                $blockEndPattern = $block.End
                $startedBlock = $true
                break
            }
        }
        if ($startedBlock) { continue }

        $kept.Add($text)
    }

    return @($kept)
}

function Get-ConfigHash {
    <#
    .SYNOPSIS
        Returns the SHA-256 hash of normalized configuration lines.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

# endregion

# ============================================================================
# region  Diff engine
# ============================================================================

function Get-ConfigDiff {
    <#
    .SYNOPSIS
        Produces a line-level diff between a baseline and a current configuration.
    .DESCRIPTION
        Trims the common prefix and suffix, then runs a longest-common-subsequence
        comparison on the remaining block. Added means present now but not in the
        baseline; Removed means present in the baseline but missing now.

        When the differing block is too large for the LCS matrix, the function
        falls back to an unordered set comparison so very large configurations
        still return a usable result.
    .PARAMETER MaxMatrixCells
        Upper bound on LCS matrix size before falling back to set comparison.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Reference,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Difference,
        [int]$MaxMatrixCells = 1000000,
        [switch]$IncludeUnchanged
    )

    $refLines = @($Reference)
    $difLines = @($Difference)
    $results = [System.Collections.Generic.List[object]]::new()

    function Add-DiffRow {
        param($List, [string]$Operation, $ReferenceLine, $DifferenceLine, [string]$Text)
        $List.Add([pscustomobject]@{
            Operation      = $Operation
            ReferenceLine  = $ReferenceLine
            DifferenceLine = $DifferenceLine
            Text           = $Text
        })
    }

    $start = 0
    while ($start -lt $refLines.Count -and $start -lt $difLines.Count -and $refLines[$start] -ceq $difLines[$start]) {
        if ($IncludeUnchanged) { Add-DiffRow $results 'Unchanged' ($start + 1) ($start + 1) $refLines[$start] }
        $start++
    }

    $endRef = $refLines.Count - 1
    $endDif = $difLines.Count - 1
    while ($endRef -ge $start -and $endDif -ge $start -and $refLines[$endRef] -ceq $difLines[$endDif]) {
        $endRef--
        $endDif--
    }

    $midRef = @()
    if ($endRef -ge $start) { $midRef = @($refLines[$start..$endRef]) }
    $midDif = @()
    if ($endDif -ge $start) { $midDif = @($difLines[$start..$endDif]) }

    $m = $midRef.Count
    $n = $midDif.Count

    if ($m -eq 0 -and $n -eq 0) {
        # Only the trimmed suffix remains.
    }
    elseif ($m -eq 0) {
        for ($j = 0; $j -lt $n; $j++) { Add-DiffRow $results 'Added' $null ($start + $j + 1) $midDif[$j] }
    }
    elseif ($n -eq 0) {
        for ($i = 0; $i -lt $m; $i++) { Add-DiffRow $results 'Removed' ($start + $i + 1) $null $midRef[$i] }
    }
    elseif (([double]$m + 1) * ([double]$n + 1) -gt $MaxMatrixCells) {
        $refCounts = @{}
        foreach ($line in $midRef) {
            if ($refCounts.ContainsKey($line)) { $refCounts[$line] = $refCounts[$line] + 1 } else { $refCounts[$line] = 1 }
        }
        foreach ($line in $midDif) {
            if ($refCounts.ContainsKey($line) -and $refCounts[$line] -gt 0) { $refCounts[$line] = $refCounts[$line] - 1 }
            else { Add-DiffRow $results 'Added' $null $null $line }
        }
        foreach ($key in @($refCounts.Keys)) {
            for ($c = 0; $c -lt $refCounts[$key]; $c++) { Add-DiffRow $results 'Removed' $null $null $key }
        }
    }
    else {
        # Flat array: PowerShell 5.1 reads $a[$i,$j] on an int[,] as an index list, not a 2D index.
        $width = $n + 1
        $lcs = New-Object 'int[]' (($m + 1) * $width)
        for ($i = $m - 1; $i -ge 0; $i--) {
            $rowBase = $i * $width
            $nextBase = ($i + 1) * $width
            for ($j = $n - 1; $j -ge 0; $j--) {
                if ($midRef[$i] -ceq $midDif[$j]) {
                    $lcs[$rowBase + $j] = $lcs[$nextBase + $j + 1] + 1
                }
                elseif ($lcs[$nextBase + $j] -ge $lcs[$rowBase + $j + 1]) {
                    $lcs[$rowBase + $j] = $lcs[$nextBase + $j]
                }
                else {
                    $lcs[$rowBase + $j] = $lcs[$rowBase + $j + 1]
                }
            }
        }

        $i = 0
        $j = 0
        while ($i -lt $m -and $j -lt $n) {
            if ($midRef[$i] -ceq $midDif[$j]) {
                if ($IncludeUnchanged) { Add-DiffRow $results 'Unchanged' ($start + $i + 1) ($start + $j + 1) $midRef[$i] }
                $i++
                $j++
            }
            elseif ($lcs[(($i + 1) * $width) + $j] -ge $lcs[($i * $width) + $j + 1]) {
                Add-DiffRow $results 'Removed' ($start + $i + 1) $null $midRef[$i]
                $i++
            }
            else {
                Add-DiffRow $results 'Added' $null ($start + $j + 1) $midDif[$j]
                $j++
            }
        }
        while ($i -lt $m) { Add-DiffRow $results 'Removed' ($start + $i + 1) $null $midRef[$i]; $i++ }
        while ($j -lt $n) { Add-DiffRow $results 'Added' $null ($start + $j + 1) $midDif[$j]; $j++ }
    }

    if ($IncludeUnchanged) {
        $tailRef = $endRef + 1
        $tailDif = $endDif + 1
        while ($tailRef -lt $refLines.Count -and $tailDif -lt $difLines.Count) {
            Add-DiffRow $results 'Unchanged' ($tailRef + 1) ($tailDif + 1) $refLines[$tailRef]
            $tailRef++
            $tailDif++
        }
    }

    return @($results)
}

function Format-ConfigDiff {
    <#
    .SYNOPSIS
        Renders diff rows as unified-style text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Diff)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $Diff) {
        switch ($row.Operation) {
            'Added' { $lines.Add('+ ' + $row.Text) }
            'Removed' { $lines.Add('- ' + $row.Text) }
            default { $lines.Add('  ' + $row.Text) }
        }
    }
    return ($lines -join "`n")
}

# endregion

# ============================================================================
# region  Baseline store
# ============================================================================

function ConvertTo-SafeDeviceKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceKey)

    $safe = [regex]::Replace($DeviceKey, '[^A-Za-z0-9._-]', '_')
    $safe = [regex]::Replace($safe, '\.{2,}', '_')
    $safe = $safe.Trim('.')
    if (-not $safe) { $safe = 'device' }
    return $safe
}

function Initialize-ConfigBaselineStore {
    <#
    .SYNOPSIS
        Creates the baseline store folder and index if they do not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StorePath)

    if (-not (Test-Path -LiteralPath $StorePath)) {
        New-Item -ItemType Directory -Path $StorePath -Force | Out-Null
    }
    $configDir = Join-Path $StorePath 'configs'
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    $indexPath = Join-Path $StorePath 'index.json'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        @{ version = 1; revisions = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $indexPath -Encoding UTF8
    }
    return $StorePath
}

function Get-ConfigBaselineIndex {
    <#
    .SYNOPSIS
        Returns all baseline revisions recorded in the store.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $indexPath = Join-Path $StorePath 'index.json'
    if (-not (Test-Path -LiteralPath $indexPath)) { return @() }

    $raw = Get-Content -LiteralPath $indexPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed -or $null -eq $parsed.revisions) { return @() }
    return @($parsed.revisions)
}

function Save-ConfigBaselineIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Revisions
    )

    $indexPath = Join-Path $StorePath 'index.json'
    @{ version = 1; revisions = @($Revisions) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $indexPath -Encoding UTF8
}

function Save-ConfigBaseline {
    <#
    .SYNOPSIS
        Stores a configuration revision, skipping writes when nothing changed.
    .PARAMETER Approve
        Marks the revision as the golden configuration for the device.
    .PARAMETER Force
        Writes a revision even when the hash matches the latest stored one.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$DeviceKey,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Config,
        [string]$Note = '',
        [switch]$Approve,
        [switch]$Force
    )

    Initialize-ConfigBaselineStore -StorePath $StorePath | Out-Null

    $safeKey = ConvertTo-SafeDeviceKey -DeviceKey $DeviceKey
    $hash = Get-ConfigHash -Lines $Config
    $revisions = @(Get-ConfigBaselineIndex -StorePath $StorePath)
    $existing = @($revisions | Where-Object { $_.deviceKey -eq $DeviceKey })
    $latest = $existing | Select-Object -Last 1

    if ($latest -and $latest.hash -eq $hash -and -not $Force -and -not $Approve) {
        return [pscustomobject]@{
            DeviceKey = $DeviceKey
            Hash      = $hash
            Timestamp = $latest.timestamp
            Approved  = [bool]$latest.approved
            Created   = $false
            Path      = (Join-Path $StorePath $latest.file)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($DeviceKey, 'Save configuration baseline')) { return $null }

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $fileStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $relativePath = Join-Path (Join-Path 'configs' $safeKey) "$fileStamp-$($hash.Substring(0, 8)).txt"
    $fullPath = Join-Path $StorePath $relativePath
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    ($Config -join "`n") | Set-Content -LiteralPath $fullPath -Encoding UTF8

    $revision = [pscustomobject]@{
        deviceKey = $DeviceKey
        timestamp = $timestamp
        hash      = $hash
        file      = $relativePath
        note      = $Note
        approved  = [bool]$Approve
        lineCount = @($Config).Count
    }

    Save-ConfigBaselineIndex -StorePath $StorePath -Revisions (@($revisions) + @($revision))

    return [pscustomobject]@{
        DeviceKey = $DeviceKey
        Hash      = $hash
        Timestamp = $timestamp
        Approved  = [bool]$Approve
        Created   = $true
        Path      = $fullPath
    }
}

function Get-ConfigBaselineHistory {
    <#
    .SYNOPSIS
        Returns stored revisions for a device, oldest first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$DeviceKey
    )

    return @(Get-ConfigBaselineIndex -StorePath $StorePath | Where-Object { $_.deviceKey -eq $DeviceKey })
}

function Get-ConfigBaseline {
    <#
    .SYNOPSIS
        Loads a stored baseline configuration for a device.
    .PARAMETER Golden
        Return the most recent approved revision instead of the most recent revision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$DeviceKey,
        [switch]$Golden
    )

    $history = @(Get-ConfigBaselineHistory -StorePath $StorePath -DeviceKey $DeviceKey)
    if ($history.Count -eq 0) { return $null }

    if ($Golden) {
        $approved = @($history | Where-Object { $_.approved })
        if ($approved.Count -eq 0) { return $null }
        $revision = $approved[-1]
    }
    else {
        $revision = $history[-1]
    }

    $fullPath = Join-Path $StorePath $revision.file
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }

    $content = Get-Content -LiteralPath $fullPath -Raw
    $lines = @()
    if ($null -ne $content) { $lines = @($content -split "`r?`n") }
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }

    return [pscustomobject]@{
        DeviceKey = $DeviceKey
        Timestamp = $revision.timestamp
        Hash      = $revision.hash
        Approved  = [bool]$revision.approved
        Note      = $revision.note
        Path      = $fullPath
        Lines     = $lines
    }
}

# endregion

# ============================================================================
# region  Policy and peer comparison
# ============================================================================

function Get-ConfigPolicyPack {
    <#
    .SYNOPSIS
        Returns a ready-made set of policy rules.
    .DESCRIPTION
        Saves writing common hardening rules by hand. The returned hashtables can
        be passed straight to Test-ConfigPolicy or Invoke-ConfigDriftAudit, and
        can be extended with your own rules.
    .PARAMETER Name
        cisco-hardening, cisco-snmp, or linux-ssh.
    .EXAMPLE
        Invoke-ConfigDriftAudit -Target r1 -Config $cfg -StorePath .\base -Rule (Get-ConfigPolicyPack cisco-hardening)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('cisco-hardening', 'cisco-snmp', 'linux-ssh')]
        [string]$Name
    )

    switch ($Name) {
        'cisco-hardening' {
            return @(
                @{ Id = 'Telnet disabled'; MustNotMatch = 'transport input .*telnet'; Severity = 'Fail' },
                @{ Id = 'AAA enabled'; MustMatch = '^aaa new-model'; Severity = 'Fail' },
                @{ Id = 'HTTP server disabled'; MustMatch = '^no ip http server'; Severity = 'Warn' },
                @{ Id = 'Password encryption enabled'; MustMatch = '^service password-encryption'; Severity = 'Warn' },
                @{ Id = 'No cleartext enable password'; MustNotMatch = '^enable password '; Severity = 'Fail' },
                @{ Id = 'SSH version 2'; MustMatch = '^ip ssh version 2'; Severity = 'Warn' },
                @{ Id = 'Logging configured'; MustMatch = '^logging (host|server) '; Severity = 'Warn' },
                @{ Id = 'Exec timeout set'; MustMatch = 'exec-timeout'; Severity = 'Warn' }
            )
        }
        'cisco-snmp' {
            return @(
                @{ Id = 'No default SNMP community'; MustNotMatch = '^snmp-server community (public|private)\b'; Severity = 'Fail' },
                @{ Id = 'No read-write SNMP'; MustNotMatch = '^snmp-server community \S+ RW'; Severity = 'Fail' },
                @{ Id = 'SNMP configured'; MustMatch = '^snmp-server '; Severity = 'Warn' }
            )
        }
        'linux-ssh' {
            return @(
                @{ Id = 'SSH root login disabled'; MustNotMatch = '(?i)^\s*permitrootlogin\s+yes'; Severity = 'Fail' },
                @{ Id = 'SSH empty passwords disabled'; MustNotMatch = '(?i)^\s*permitemptypasswords\s+yes'; Severity = 'Fail' },
                @{ Id = 'SSH password auth disabled'; MustNotMatch = '(?i)^\s*passwordauthentication\s+yes'; Severity = 'Warn' },
                @{ Id = 'SSH X11 forwarding disabled'; MustNotMatch = '(?i)^\s*x11forwarding\s+yes'; Severity = 'Warn' }
            )
        }
    }
}

function Test-ConfigPolicy {
    <#
    .SYNOPSIS
        Evaluates configuration lines against policy rules.
    .PARAMETER Rule
        Hashtables with Id, optional Description, Severity (Fail or Warn),
        and either MustMatch or MustNotMatch as a regular expression.
    .EXAMPLE
        Test-ConfigPolicy -Config $lines -Target r1 -Rule @{Id='NO-TELNET'; MustNotMatch='transport input .*telnet'}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Config,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Rule,
        [string]$Target = ''
    )

    $checks = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Rule)) {
        if (-not $item.ContainsKey('Id')) { continue }

        $severity = 'Fail'
        if ($item.ContainsKey('Severity') -and $item['Severity']) { $severity = [string]$item['Severity'] }

        $description = [string]$item['Id']
        if ($item.ContainsKey('Description') -and $item['Description']) { $description = [string]$item['Description'] }

        $status = 'Unknown'
        $detail = ''
        $value = ''

        if ($item.ContainsKey('MustMatch') -and $item['MustMatch']) {
            $pattern = [string]$item['MustMatch']
            $hits = @($Config | Where-Object { $_ -match $pattern })
            if ($hits.Count -gt 0) {
                $status = 'Pass'
                $value = "$($hits.Count) match(es)"
                $detail = $hits[0]
            }
            else {
                $status = $severity
                $value = 'missing'
                $detail = "Required pattern not found: $pattern"
            }
        }
        elseif ($item.ContainsKey('MustNotMatch') -and $item['MustNotMatch']) {
            $pattern = [string]$item['MustNotMatch']
            $hits = @($Config | Where-Object { $_ -match $pattern })
            if ($hits.Count -eq 0) {
                $status = 'Pass'
                $value = 'absent'
            }
            else {
                $status = $severity
                $value = "$($hits.Count) match(es)"
                $detail = ($hits | Select-Object -First 3) -join ' | '
            }
        }
        else {
            $detail = 'Rule defines neither MustMatch nor MustNotMatch.'
        }

        $checks.Add([pscustomobject]@{
            Target   = $Target
            Category = 'Policy'
            Check    = $description
            Status   = $status
            Value    = $value
            Detail   = $detail
        })
    }

    return @($checks)
}

function Compare-ConfigPeerGroup {
    <#
    .SYNOPSIS
        Finds configuration lines that most peers share but some devices are missing.
    .PARAMETER ConfigMap
        Hashtable of device name to normalized configuration lines.
    .PARAMETER ConsensusPercent
        Percentage of devices that must share a line before a missing line counts as drift.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$ConfigMap,
        [ValidateRange(1, 100)][int]$ConsensusPercent = 80,
        [string[]]$IgnorePattern = @()
    )

    $devices = @($ConfigMap.Keys)
    $checks = [System.Collections.Generic.List[object]]::new()
    if ($devices.Count -lt 2) { return @($checks) }

    $lineOwners = @{}
    foreach ($device in $devices) {
        $seen = @{}
        foreach ($line in @($ConfigMap[$device])) {
            $text = ([string]$line).Trim()
            if (-not $text) { continue }
            $skip = $false
            foreach ($pattern in @($IgnorePattern)) {
                if ($pattern -and $text -match $pattern) { $skip = $true; break }
            }
            if ($skip -or $seen.ContainsKey($text)) { continue }
            $seen[$text] = $true
            if (-not $lineOwners.ContainsKey($text)) { $lineOwners[$text] = [System.Collections.Generic.List[string]]::new() }
            $lineOwners[$text].Add($device)
        }
    }

    $threshold = [Math]::Ceiling($devices.Count * ($ConsensusPercent / 100.0))

    $missingByDevice = @{}
    foreach ($device in $devices) { $missingByDevice[$device] = [System.Collections.Generic.List[string]]::new() }

    foreach ($line in @($lineOwners.Keys)) {
        $owners = @($lineOwners[$line])
        if ($owners.Count -ge $threshold -and $owners.Count -lt $devices.Count) {
            foreach ($device in $devices) {
                if ($owners -notcontains $device) { $missingByDevice[$device].Add($line) }
            }
        }
    }

    foreach ($device in $devices) {
        $missing = @($missingByDevice[$device])
        if ($missing.Count -eq 0) {
            $checks.Add([pscustomobject]@{
                Target   = $device
                Category = 'PeerGroup'
                Check    = 'Peer configuration consistency'
                Status   = 'Pass'
                Value    = '0 missing'
                Detail   = "Consistent with $ConsensusPercent% peer consensus."
            })
        }
        else {
            $checks.Add([pscustomobject]@{
                Target   = $device
                Category = 'PeerGroup'
                Check    = 'Peer configuration consistency'
                Status   = 'Warn'
                Value    = "$($missing.Count) missing"
                Detail   = (($missing | Select-Object -First 5) -join ' | ')
            })
        }
    }

    return @($checks)
}

# endregion

# ============================================================================
# region  Collection and orchestration
# ============================================================================

function Compare-ConfigRevision {
    <#
    .SYNOPSIS
        Diffs two stored revisions of the same device.
    .DESCRIPTION
        Answers "what changed between these two dates" without leaving PowerShell.
        From and To accept a 1-based revision number, a negative offset from the
        newest revision, 'latest', or 'golden'.
    .EXAMPLE
        Compare-ConfigRevision -StorePath .\baselines -DeviceKey SW1 -From golden -To latest
    .EXAMPLE
        Compare-ConfigRevision -StorePath .\baselines -DeviceKey SW1 -From -1 -To latest
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$DeviceKey,
        [Parameter(Mandatory = $true)]$From,
        $To = 'latest'
    )

    $history = @(Get-ConfigBaselineHistory -StorePath $StorePath -DeviceKey $DeviceKey)
    if ($history.Count -eq 0) { throw "No revisions stored for '$DeviceKey'." }

    function Resolve-Revision {
        param($Selector, $History)

        if ($Selector -is [string]) {
            if ($Selector -eq 'latest') { return $History[-1] }
            if ($Selector -eq 'golden') {
                $approved = @($History | Where-Object { $_.approved })
                if ($approved.Count -eq 0) { throw "No approved revision stored." }
                return $approved[-1]
            }
        }

        $number = 0
        if (-not [int]::TryParse([string]$Selector, [ref]$number)) { throw "Invalid revision selector: $Selector" }
        if ($number -lt 0) {
            $index = $History.Count + $number - 1
            if ($index -lt 0) { throw "Offset $number goes past the oldest revision." }
            return $History[$index]
        }
        if ($number -lt 1 -or $number -gt $History.Count) { throw "Revision $number is out of range (1..$($History.Count))." }
        return $History[$number - 1]
    }

    $fromRevision = Resolve-Revision -Selector $From -History $history
    $toRevision = Resolve-Revision -Selector $To -History $history

    function Read-RevisionLines {
        param($Revision, [string]$StorePath)
        $path = Join-Path $StorePath $Revision.file
        if (-not (Test-Path -LiteralPath $path)) { throw "Revision file missing: $path" }
        $content = Get-Content -LiteralPath $path -Raw
        $lines = @()
        if ($null -ne $content) { $lines = @($content -split "`r?`n") }
        if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
        return $lines
    }

    $fromLines = Read-RevisionLines -Revision $fromRevision -StorePath $StorePath
    $toLines = Read-RevisionLines -Revision $toRevision -StorePath $StorePath
    $diff = @(Get-ConfigDiff -Reference $fromLines -Difference $toLines)

    return [pscustomobject]@{
        DeviceKey     = $DeviceKey
        FromTimestamp = $fromRevision.timestamp
        ToTimestamp   = $toRevision.timestamp
        FromHash      = $fromRevision.hash
        ToHash        = $toRevision.hash
        AddedLines    = @($diff | Where-Object { $_.Operation -eq 'Added' }).Count
        RemovedLines  = @($diff | Where-Object { $_.Operation -eq 'Removed' }).Count
        Diff          = $diff
    }
}

function Get-ConfigViaSsh {
    <#
    .SYNOPSIS
        Retrieves a device configuration over SSH.
    .DESCRIPTION
        Runs one or more commands and returns their combined output. By default
        the SSH exec channel is used. Devices that need a real terminal (enable
        mode, menus, control characters, pagers) should use -Shell.
    .PARAMETER Command
        One or more commands whose output forms the configuration. Defaults to
        the vendor profile command.
    .PARAMETER SetupCommand
        Commands run before collection whose output is discarded, such as
        disabling the pager. Defaults to the vendor profile setup command.
    .PARAMETER Shell
        Use an interactive shell instead of the exec channel.
    .PARAMETER PreStep
        Raw shell steps sent before the setup commands. Use for control
        characters such as Ctrl+Z or for navigating a menu. Implies -Shell.
    .PARAMETER EnablePassword
        Privileged-mode password. Implies -Shell.
    .EXAMPLE
        Get-ConfigViaSsh -Target sw1 -Username admin -SecurePassword $pw -Profile cisco-ios
    .EXAMPLE
        # Several commands make up the full configuration
        Get-ConfigViaSsh -Target sw1 -Username admin -SecurePassword $pw `
            -Command 'show running-config','show vlan brief'
    .EXAMPLE
        # Escape a vendor menu with Ctrl+Z before collecting
        Get-ConfigViaSsh -Target box1 -Username admin -SecurePassword $pw -Shell `
            -PreStep @(@{ Send = [char]26; NoNewline = $true; Collect = $false }) `
            -Command 'show running-config'
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
        [string[]]$Command,
        [string[]]$SetupCommand,
        [switch]$Shell,
        [object[]]$PreStep,
        [System.Security.SecureString]$EnablePassword,
        [string]$EnableCommand = 'enable',
        [string]$PromptPattern,
        [ValidateSet('cisco-ios', 'cisco-nxos', 'cisco-asa', 'linux', 'generic')]
        [string]$Profile = 'generic',
        [string]$SshModulePath
    )

    $vendor = Get-ConfigVendorProfile -Name $Profile
    if (-not $Command) { $Command = @($vendor.Command) }
    if (-not $PSBoundParameters.ContainsKey('SetupCommand')) { $SetupCommand = @($vendor.SetupCommand) }
    if (-not $PromptPattern) { $PromptPattern = $vendor.PromptPattern }

    $Command = @($Command | Where-Object { $_ })
    if ($Command.Count -eq 0) { throw "No command specified and profile '$Profile' has no default command." }

    if (-not $SshModulePath) {
        $SshModulePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'helpers\ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psm1'
        if (-not (Test-Path -LiteralPath $SshModulePath)) {
            $SshModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psm1'
        }
    }
    if (-not (Test-Path -LiteralPath $SshModulePath)) { throw "SSH module not found: $SshModulePath" }
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

    $useShell = ($Shell -or $PreStep -or $EnablePassword)
    $session = New-SshSession @splat
    try {
        if ($useShell) {
            $steps = [System.Collections.Generic.List[object]]::new()
            foreach ($pre in @($PreStep)) { if ($null -ne $pre) { $steps.Add($pre) } }
            foreach ($setup in @($SetupCommand)) {
                if ($setup) { $steps.Add(@{ Send = $setup; Collect = $false }) }
            }
            foreach ($cmd in $Command) { $steps.Add($cmd) }

            $shellSplat = @{
                Session        = $session
                Step           = $steps.ToArray()
                TimeoutSeconds = $TimeoutSeconds
            }
            if ($PromptPattern) { $shellSplat['PromptPattern'] = $PromptPattern }
            if ($EnablePassword) {
                $shellSplat['EnablePassword'] = $EnablePassword
                $shellSplat['EnableCommand'] = $EnableCommand
            }

            $shellResult = Invoke-SshShellCommand @shellSplat
            $output = $shellResult.Output
            $errorText = ''
        }
        else {
            $full = (@($SetupCommand | Where-Object { $_ }) + $Command) -join ' ; '
            $result = Invoke-SshCommand -Session $session -Command ($full -replace "`r", '') -TimeoutSeconds $TimeoutSeconds
            $output = $result.Output
            $errorText = $result.Error
        }
    }
    finally {
        Close-SshSession -Session $session
    }

    if (-not $output) {
        throw "No configuration returned from ${Target}. stderr: $errorText"
    }
    return $output
}

function Get-ConfigDriftTarget {
    <#
    .SYNOPSIS
        Resolves audit targets from a WhatsUp Gold device group.
    .DESCRIPTION
        Returns one object per device with the address to connect to and the WUG
        device id, so results can be published back later. Requires an active
        session created by Connect-WUGServer.
    .PARAMETER GroupName
        Device group name. Omit to search all devices.
    .PARAMETER SearchValue
        Optional device search filter.
    .EXAMPLE
        Get-ConfigDriftTarget -GroupName 'Routers'
    #>
    [CmdletBinding()]
    param(
        [string]$GroupName,
        [string]$SearchValue,
        [int]$Limit = 250
    )

    if (-not (Get-Command Get-WUGDevice -ErrorAction SilentlyContinue)) {
        throw 'The WhatsUpGoldPS module is not loaded. Import it and run Connect-WUGServer first.'
    }

    $groupId = '-1'
    if ($GroupName) {
        $groups = @(Get-WUGDeviceGroup -SearchValue $GroupName)
        $match = $groups | Where-Object { $_.name -eq $GroupName } | Select-Object -First 1
        if (-not $match) { $match = $groups | Select-Object -First 1 }
        if (-not $match) { throw "Device group not found: $GroupName" }
        $groupId = [string]$match.id
    }

    $deviceSplat = @{ DeviceGroupID = $groupId; View = 'card'; Limit = $Limit }
    if ($SearchValue) { $deviceSplat['SearchValue'] = $SearchValue }
    $devices = @(Get-WUGDevice @deviceSplat)

    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $devices) {
        $address = $null
        foreach ($name in @('networkAddress', 'address', 'hostName', 'displayName')) {
            if ($device.PSObject.Properties[$name] -and $device.PSObject.Properties[$name].Value) {
                $address = [string]$device.PSObject.Properties[$name].Value
                break
            }
        }
        if (-not $address) { continue }

        $displayName = $address
        if ($device.PSObject.Properties['displayName'] -and $device.displayName) { $displayName = [string]$device.displayName }

        $targets.Add([pscustomobject]@{
            Target   = $address
            Name     = $displayName
            DeviceId = $device.id
        })
    }

    return @($targets)
}

function Publish-ConfigDriftToWUG {
    <#
    .SYNOPSIS
        Writes drift audit results back to WhatsUp Gold as device attributes.
    .DESCRIPTION
        Sets ConfigDrift.* attributes on the matching device so drift becomes
        visible and alertable inside WhatsUp Gold. Requires an active session
        created by Connect-WUGServer.
    .PARAMETER Audit
        Result objects from Invoke-ConfigDriftAudit.
    .PARAMETER DeviceId
        Device id to update. When omitted the device is looked up by target name.
    .PARAMETER AttributePrefix
        Attribute name prefix. Default ConfigDrift.
    .EXAMPLE
        $result | Publish-ConfigDriftToWUG -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]$Audit,
        [int]$DeviceId,
        [string]$AttributePrefix = 'ConfigDrift'
    )

    begin {
        if (-not (Get-Command Set-WUGDeviceAttribute -ErrorAction SilentlyContinue)) {
            throw 'The WhatsUpGoldPS module is not loaded. Import it and run Connect-WUGServer first.'
        }
        $published = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in @($Audit)) {
            $resolvedId = $DeviceId
            if (-not $resolvedId -and $item.PSObject.Properties['DeviceId'] -and $item.DeviceId) {
                $resolvedId = [int]$item.DeviceId
            }
            if (-not $resolvedId) {
                $found = @(Get-WUGDevice -SearchValue $item.Target -View id) | Select-Object -First 1
                if ($found) { $resolvedId = [int]$found.id }
            }
            if (-not $resolvedId) {
                Write-Warning "No WUG device matched '$($item.Target)'; skipping."
                continue
            }

            $status = 'Clean'
            if ($item.DriftDetected) { $status = 'Drift' }

            $attributes = [ordered]@{
                "$AttributePrefix.Status"      = $status
                "$AttributePrefix.LastChecked" = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                "$AttributePrefix.Added"       = [string]$item.AddedLines
                "$AttributePrefix.Removed"     = [string]$item.RemovedLines
                "$AttributePrefix.Hash"        = [string]$item.Hash
            }

            if (-not $PSCmdlet.ShouldProcess("Device $resolvedId ($($item.Target))", "Set $AttributePrefix attributes")) { continue }

            foreach ($name in $attributes.Keys) {
                try {
                    Set-WUGDeviceAttribute -DeviceId $resolvedId -Name $name -Value $attributes[$name] -ErrorAction Stop | Out-Null
                }
                catch {
                    Write-Warning "Failed to set '$name' on device ${resolvedId}: $($_.Exception.Message)"
                }
            }

            $published.Add([pscustomobject]@{
                Target   = $item.Target
                DeviceId = $resolvedId
                Status   = $status
            })
        }
    }

    end { return @($published) }
}

function Get-ConfigDriftVaultCredential {
    <#
    .SYNOPSIS
        Loads SSH credentials for drift audits from the DPAPI discovery vault.
    .DESCRIPTION
        Reuses the credential vault in helpers/discovery so scheduled runs never
        prompt. The stored credential may be a single secret (treated as the
        password) or a bundle with Username, Password, KeyFile or KeyPassphrase
        fields.
    .PARAMETER Name
        Vault credential name saved with Save-DiscoveryCredential.
    .EXAMPLE
        Get-ConfigDriftVaultCredential -Name 'NetworkAdmin'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DiscoveryHelpersPath
    )

    if (-not (Get-Command Get-DiscoveryCredential -ErrorAction SilentlyContinue)) {
        if (-not $DiscoveryHelpersPath) {
            $DiscoveryHelpersPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'discovery\DiscoveryHelpers.ps1'
        }
        if (-not (Test-Path -LiteralPath $DiscoveryHelpersPath)) {
            throw "DiscoveryHelpers.ps1 not found: $DiscoveryHelpersPath"
        }
        . $DiscoveryHelpersPath
    }

    $stored = Get-DiscoveryCredential -Name $Name
    if (-not $stored) { throw "Vault credential '$Name' not found. Save it with Save-DiscoveryCredential first." }

    $result = [ordered]@{
        Username       = $null
        SecurePassword = $null
        KeyFile        = $null
        KeyPassphrase  = $null
    }

    if ($stored -is [System.Collections.IDictionary]) {
        foreach ($key in @($stored.Keys)) {
            $value = [string]$stored[$key]
            switch -Regex ($key) {
                '^(?i)user(name)?$' { $result['Username'] = $value }
                '^(?i)pass(word)?$' { $result['SecurePassword'] = (ConvertTo-SecureString $value -AsPlainText -Force) }
                '^(?i)key(file|path)$' { $result['KeyFile'] = $value }
                '^(?i)key(pass|passphrase)$' { $result['KeyPassphrase'] = $value }
            }
        }
    }
    else {
        $result['SecurePassword'] = ConvertTo-SecureString ([string]$stored) -AsPlainText -Force
    }

    return [pscustomobject]$result
}

function Invoke-ConfigDriftAudit {
    <#
    .SYNOPSIS
        Compares a configuration against its stored baseline and policy rules.
    .DESCRIPTION
        Normalizes the supplied configuration, diffs it against the stored
        baseline (golden revision when -UseGolden is set), evaluates policy
        rules, and returns both dashboard-ready checks and the raw diff.
    .PARAMETER Config
        Raw configuration text or lines. Supply this to audit without SSH.
    .PARAMETER UpdateBaseline
        Store the current configuration as a new revision after auditing.
    .EXAMPLE
        Invoke-ConfigDriftAudit -Target r1 -Config $text -StorePath .\baselines -Profile cisco-ios
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()]$Config,
        [Parameter(Mandatory = $true)][string]$StorePath,
        [ValidateSet('cisco-ios', 'cisco-nxos', 'cisco-asa', 'linux', 'generic')]
        [string]$Profile = 'generic',
        [string[]]$IgnorePattern = @(),
        [hashtable[]]$IgnoreBlock = @(),
        [string[]]$IgnoreSection = @(),
        [string[]]$IncludePattern = @(),
        [hashtable[]]$IncludeBlock = @(),
        [string[]]$IncludeSection = @(),
        [hashtable[]]$Rule,
        [switch]$UseGolden,
        [switch]$UpdateBaseline,
        [switch]$ApproveBaseline
    )

    $vendor = Get-ConfigVendorProfile -Name $Profile
    $allIgnore = @($vendor.IgnorePattern) + @($IgnorePattern)
    $allBlocks = @($vendor.IgnoreBlock) + @($IgnoreBlock)

    $current = @(ConvertTo-NormalizedConfig -Config $Config -IgnorePattern $allIgnore -IgnoreBlock $allBlocks `
        -IgnoreSection $IgnoreSection -IncludePattern $IncludePattern -IncludeBlock $IncludeBlock `
        -IncludeSection $IncludeSection -CommentPrefix $vendor.CommentPrefix)
    $currentHash = Get-ConfigHash -Lines $current

    Initialize-ConfigBaselineStore -StorePath $StorePath | Out-Null
    $baseline = Get-ConfigBaseline -StorePath $StorePath -DeviceKey $Target -Golden:$UseGolden

    $checks = [System.Collections.Generic.List[object]]::new()
    $diff = @()
    $added = 0
    $removed = 0
    $driftDetected = $false

    if ($null -eq $baseline) {
        $checks.Add([pscustomobject]@{
            Target   = $Target
            Category = 'Drift'
            Check    = 'Configuration drift'
            Status   = 'Unknown'
            Value    = 'no baseline'
            Detail   = 'No stored baseline yet; this run establishes one.'
        })
    }
    else {
        $diff = @(Get-ConfigDiff -Reference $baseline.Lines -Difference $current)
        $added = @($diff | Where-Object { $_.Operation -eq 'Added' }).Count
        $removed = @($diff | Where-Object { $_.Operation -eq 'Removed' }).Count
        $driftDetected = ($added + $removed) -gt 0

        $status = 'Pass'
        if ($driftDetected) { $status = 'Fail' }

        $checks.Add([pscustomobject]@{
            Target   = $Target
            Category = 'Drift'
            Check    = 'Configuration drift'
            Status   = $status
            Value    = "+$added/-$removed"
            Detail   = "Compared against baseline $($baseline.Timestamp) ($($baseline.Hash.Substring(0,8)))."
        })
    }

    if ($Rule) {
        foreach ($policyCheck in @(Test-ConfigPolicy -Config $current -Rule $Rule -Target $Target)) {
            $checks.Add($policyCheck)
        }
    }

    $savedRevision = $null
    if ($UpdateBaseline -or $ApproveBaseline) {
        $savedRevision = Save-ConfigBaseline -StorePath $StorePath -DeviceKey $Target -Config $current `
            -Note "drift audit +$added/-$removed" -Approve:$ApproveBaseline
    }

    return [pscustomobject]@{
        Target        = $Target
        CollectedAt   = (Get-Date)
        Hash          = $currentHash
        BaselineHash  = $(if ($baseline) { $baseline.Hash } else { $null })
        DriftDetected = $driftDetected
        AddedLines    = $added
        RemovedLines  = $removed
        LineCount     = $current.Count
        Checks        = @($checks)
        Diff          = $diff
        Lines         = $current
        Revision      = $savedRevision
    }
}

# endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBlrsdstckAThBJ
# 3PXbzaz3OsaBqYj/1aY27N90lWTpWKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAi1QK8hHCAM+MhgYT3s52HL7oY2BaT+Xbp6RZPvqVv+jANBgkqhkiG9w0BAQEF
# AASCAgAG9JM+6qFuYpKhReXdgf+joD/2DS47tVN5PnvXfHPxqaoMipkNCFvwRKo2
# MQhmoibjESZvE1KE4ZQAgq/ihpF3tcQHH8iJM/X/WUUmF8OSK6u/lggnRQVQJim2
# 3f5rfDsFcKaO9K9BaqLwJsxA+ylyY1e8m7gti4e/7K+6V02WbtQ63qxPFlebWG8V
# OfRkBJlTAkjiyEdPz2rcMpgjSZ1rcCEoBgRtqmbrudc1wp4gWPHDYLdd6oJ+ZsI8
# v1wObsJVcYxM8m6H1G+vbIRGIiBVsoFPRdMnxt5vsG4w2dkEoMRBsGstXQtjS3/l
# Tw4GHYEQKQV2a694RtX1cydZPxqToLIvw9m1qX2N2M1/AnoNGH1PIy8dqQqbneSD
# ogawb1wh+7nNRXubPGBHdKPUfGmJkGAlRQ+NiyLjT6BqPXKSquBBUeJ1fJzjiFiW
# BTFXf2wtojL+bnp2xouaHvj/g1lKib0ZMwltI/fZZS/sMHXazvQTyM7Wc1X9OMlU
# 2nWOcha8JOGKrSsuQt8Q/Nuskq3yr0kUOuN9LQKw3Hne5iuTQvbMRyE9HQDIaevU
# 5eVkLdcSTb4e6XJb73O9B2XqltcJeBwzE38OFYbL2WJO8TU9JpANJD/tZDEyBT/e
# NNBLeb/aeY0dFIHyHcTleEUoW8RS/Udrq1Kw4gkw6kHXlaj2baGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkxOTM3MzVaMC8GCSqGSIb3DQEJBDEiBCBrcC7S
# Pyj13d7vSRk2nLe+pPVrk30iUdspBZt8SBeqAjANBgkqhkiG9w0BAQEFAASCAgCB
# JVMeJWXILoIYfTZnx4KbstEbxhNSyMBZQpGQKA0p+5KAIyAxTvfsgf97qV88uAta
# ymSdE+BGB9dOiDpnlFgwhvMBN1CVztlZ8ralYYBqq52JPnSUDZeeJUjwrr/8QEAX
# nv/RTB9eszR2CoETPW56ZSpzkgf/EhSJ/jTSBQxgdyBuGrNe4QLupRzhTSuVn2h+
# iXBmrr1OY/xcb3Bgr148NlvN0ZXSM/fHQfu0G2zQaDZwK+gwvnxj6EM6okdA9cEi
# /yPKcLKnNKV/kYvZNDsqQA5yRgTJllZ746Di6Sti6+qb+6qiuq2TsHrz8oF7EopP
# rAaRywzW9HknODTyw4yw3mLjGf0p6gU7q3gBsI8xT47cOroGKGfdaoUa1bvk4KFx
# YFQSFFqP7PXDheB9slVCHvd+rnsI5kEWMjQbjQV6/rUPj09ZABWdH4Z9ktv6gazC
# 3xLPuKru9Hubi6PvTWYTj2w8DxiT/NlM/20gPNGqtbvWLpNaiaxI6TsfaiX3c8w6
# 6n3w8jtIvzeXVMjlvY0GsXLVoQg5vyPJWo0JR/GYPXxRUZ9CyyDIXKFW+qsXVohF
# ifP06Cjlxi4zBnb7xWlaQ0Am+1wksR+0tRQU+qpaBR6DEDIybXcgbsoR9ndYykvx
# WApWcjV9zwXBVJzAgCE5dj4U8GZ7azncOQBmdW2hQQ==
# SIG # End signature block
