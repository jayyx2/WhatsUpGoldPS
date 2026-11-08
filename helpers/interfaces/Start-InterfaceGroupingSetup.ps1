#requires -Version 5.1
<#
.SYNOPSIS
    Guides an operator through creating or running an interface-grouping profile.
.DESCRIPTION
    Creates or reuses a saved profile, previews proposed interface groups, offers
    CSV or interactive review, and requires explicit approval before a full run.
    WUG group creation, publishing, SNMP credential creation, and scheduling are
    opt-in. Profiles contain configuration only and never store credential secrets.
.PARAMETER ProfileDirectory
    Profile JSON directory. Defaults to %ProgramData%\WhatsUpGoldPS\InterfaceGroups\Profiles.
.PARAMETER SkipSchedule
    Skip the optional scheduled-task registration prompt.
.EXAMPLE
    .\Start-InterfaceGroupingSetup.ps1
.EXAMPLE
    .\Start-InterfaceGroupingSetup.ps1 -ProfileDirectory 'D:\WUG\InterfaceProfiles' -SkipSchedule
.NOTES
    Requires Windows PowerShell 5.1+, the interface grouping helpers, and a usable
    WhatsUp Gold connection. Run from a console because the setup uses Read-Host.
.LINK
    README.md
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProfileDirectory,
    [switch]$SkipSchedule
)

function Read-InterfaceSetupChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Choices,
        [string]$Default
    )
    $choiceText = $Choices -join ', '
    while ($true) {
        $defaultText = ''
        if ($Default) { $defaultText = "; default $Default" }
        $answer = Read-Host -Prompt "$Prompt [$choiceText$defaultText; Q=Cancel]"
        if ($answer -match '^(?i:q|quit|cancel)$') { return $null }
        $answer = $answer.Trim()
        if (-not $answer -and $Default) { $answer = $Default }
        foreach ($choice in $Choices) {
            $key = ($choice -split '=', 2)[0]
            if ($answer -ieq $key) { return $key }
        }
        Write-Warning "Choose one of: $choiceText, or Q to cancel."
    }
}

function Read-InterfaceSetupText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [string]$Pattern,
        [string]$PatternMessage,
        [switch]$Required
    )
    while ($true) {
        $promptText = $Prompt
        if ($null -ne $Default) { $promptText += " (default: $Default)" }
        $answer = Read-Host -Prompt "$promptText [Q=Cancel]"
        if ($answer -match '^(?i:q|quit|cancel)$') { return $null }
        $answer = $answer.Trim()
        if (-not $answer -and $null -ne $Default) { $answer = $Default }
        if ($Required -and [string]::IsNullOrWhiteSpace($answer)) {
            Write-Warning 'A value is required, or enter Q to cancel.'
            continue
        }
        if ($Pattern -and $answer -notmatch $Pattern) {
            Write-Warning $PatternMessage
            continue
        }
        return $answer
    }
}

function Read-InterfaceSetupYesNo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $defaultKey = 'N'
    if ($Default) { $defaultKey = 'Y' }
    while ($true) {
        $answer = Read-Host -Prompt "$Prompt [Y/N; default $defaultKey; Q=Cancel]"
        if ($answer -match '^(?i:q|quit|cancel)$') { return $null }
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -match '^(?i:n|no)$') { return $false }
        Write-Warning 'Enter Y, N, or Q to cancel.'
    }
}

function Read-InterfaceSetupInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum,
        [Parameter(Mandatory)][int]$Default
    )
    while ($true) {
        $answer = Read-Host -Prompt "$Prompt ($Minimum-$Maximum; default $Default) [Q=Cancel]"
        if ($answer -match '^(?i:q|quit|cancel)$') { return $null }
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $value = 0
        if ([int]::TryParse($answer.Trim(), [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) {
            return $value
        }
        Write-Warning "Enter a whole number from $Minimum to $Maximum, or Q to cancel."
    }
}

function Read-InterfaceSetupIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [switch]$AllowZero)
    while ($true) {
        $answer = Read-Host -Prompt "$Prompt (comma-separated) [Q=Cancel]"
        if ($answer -match '^(?i:q|quit|cancel)$') { return $null }
        $parts = @($answer -split ',' | ForEach-Object { $_.Trim() })
        $valid = $parts.Count -gt 0
        $ids = [System.Collections.Generic.List[int]]::new()
        foreach ($part in $parts) {
            $id = 0
            if ($part -notmatch '^\d+$' -or -not [int]::TryParse($part, [ref]$id) -or
                ($AllowZero -and $id -lt 0) -or (-not $AllowZero -and $id -le 0)) {
                $valid = $false
                break
            }
            if (-not $ids.Contains($id)) { $ids.Add($id) }
        }
        if ($valid) { return ,@($ids.ToArray()) }
        Write-Warning 'Enter comma-separated valid IDs, or Q to cancel.'
    }
}

function Get-InterfaceSetupSlug {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $slug = ($Name -replace '[^A-Za-z0-9_-]', '-').Trim('-', '_')
    if ([string]::IsNullOrWhiteSpace($slug)) { throw 'Profile name must contain letters or digits.' }
    return $slug
}

function Save-InterfaceSetupProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Action
    )
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return $false }
    $null = Save-InterfaceGroupProfile -Path $Path -Settings $Settings -Confirm:$false -ErrorAction Stop
    return $true
}

function Read-InterfaceSetupRules {
    [CmdletBinding()]
    param()
    $rules=[System.Collections.Generic.List[object]]::new()
    while ($rules.Count -lt 100) {
        $name=Read-InterfaceSetupText -Prompt 'Group name (for example Tunnels)' -Required -Pattern '^[^;\r\n]+$' -PatternMessage 'No semicolons or newlines in group names.'
        if ($null -eq $name) {return $null}
        if ($name -ieq 'Other Interfaces') {Write-Warning 'Other Interfaces is reserved for unmatched ports.';continue}
        $value=Read-InterfaceSetupText -Prompt 'Literal matching phrase (for example tunnel to)' -Required
        if ($null -eq $value) {return $null}
        $match=Read-InterfaceSetupChoice -Prompt 'Where should this phrase match?' -Choices @('Contains','StartsWith','EndsWith','Token','Exact') -Default Contains
        if ($null -eq $match) {return $null}
        $field=Read-InterfaceSetupChoice -Prompt 'Description field' -Choices @('Any','IfAlias','IfName','IfDescr','InterfaceComment','InterfaceName') -Default Any
        if ($null -eq $field) {return $null}
        $rules.Add([pscustomobject]@{Name=$name;Value=$value;Match=$match;Field=$field})
        $more=Read-InterfaceSetupYesNo -Prompt 'Add another ordered rule?' -Default $false
        if ($null -eq $more) {return $null}
        if (-not $more) {break}
    }
    $ruleMode=Read-InterfaceSetupChoice -Prompt 'When multiple rules match' -Choices @('FirstMatch','Overlap') -Default FirstMatch
    if ($null -eq $ruleMode) {return $null}
    [pscustomobject]@{Rules=@($rules.ToArray());RuleMode=$ruleMode}
}

function Edit-InterfaceSetupSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings)
    $edited = $Settings.Clone()
    while ($true) {
        $choice = Read-InterfaceSetupChoice -Prompt 'Edit profile settings' -Choices @(
            '1=Scope', '2=Grouping', '3=Traffic window', '4=Output/publishing', '5=SNMP references', '6=Device eligibility', 'S=Save edits') -Default S
        if ($null -eq $choice) { return $null }
        if ($choice -eq 'S') { return $edited }
        switch ($choice) {
            '1' {
                $scope = Read-InterfaceSetupChoice -Prompt 'Source scope' -Choices @('1=Device IDs','2=Group IDs','3=All devices')
                if ($null -eq $scope) { return $null }
                foreach ($key in @('DeviceId','GroupId','AllDevices','ReturnHierarchy')) { $edited.Remove($key) }
                if ($scope -eq '3') { $edited.AllDevices=$true }
                else {
                    $ids=Read-InterfaceSetupIds -Prompt 'IDs'
                    if ($null -eq $ids) { return $null }
                    if ($scope -eq '1') { $edited.DeviceId=@($ids) }
                    else {
                        $edited.GroupId=@($ids)
                        $hierarchy=Read-InterfaceSetupYesNo -Prompt 'Include descendants?'
                        if ($null -eq $hierarchy) { return $null }
                        if ($hierarchy) { $edited.ReturnHierarchy=$true }
                    }
                }
            }
            '2' {
                $mode=Read-InterfaceSetupChoice -Prompt 'Mode' -Choices @('1=NamedGroups','2=AllInterfaces','3=AutoGroups','4=IntelligentGroups','5=Saved phrase rules')
                if ($null -eq $mode) { return $null }
                $edited.Mode=@{'1'='NamedGroups';'2'='AllInterfaces';'3'='AutoGroups';'4'='IntelligentGroups';'5'='Rules'}[$mode]
                foreach ($key in @('GroupName','Strategy','Rules','RuleMode')) {$edited.Remove($key)}
                if ($mode -eq '5') {
                    $ruleSettings=Read-InterfaceSetupRules
                    if ($null -eq $ruleSettings) {return $null}
                    $edited.Rules=$ruleSettings.Rules;$edited.RuleMode=$ruleSettings.RuleMode
                }
                if ($mode -eq '1') {
                    $labels=Read-InterfaceSetupText -Prompt 'Comma-separated group labels' -Required
                    if ($null -eq $labels) { return $null }
                    $edited.GroupName=@($labels -split ',' | ForEach-Object { $_.Trim() })
                }
                if ($mode -eq '4') {
                    $strategy=Read-InterfaceSetupChoice -Prompt 'Strategy' -Choices @('Prefix','Words') -Default Prefix
                    if ($null -eq $strategy) { return $null };$edited.Strategy=$strategy
                }
                if ($mode -in @('1','3')) {
                    $match=Read-InterfaceSetupChoice -Prompt 'Matching' -Choices @('Token','Exact','Contains','StartsWith','EndsWith','Substring') -Default Token
                    if ($null -eq $match) { return $null };$edited.MatchMode=$match
                }
            }
            '3' {
                $range=Read-InterfaceSetupChoice -Prompt 'Traffic window' -Choices @('lastPolled','today','yesterday','lastWeek','lastNHours','lastNDays') -Default lastPolled
                if ($null -eq $range) { return $null };$edited.Range=$range
                if ($range -match '^lastN') {
                    $count=Read-InterfaceSetupInteger -Prompt 'Hours/days' -Minimum 1 -Maximum 365 -Default 4
                    if ($null -eq $count) { return $null };$edited.RangeN=$count
                }
            }
            '4' {
                $path=Read-InterfaceSetupText -Prompt 'Output directory' -Default $edited.OutputDirectory -Required
                if ($null -eq $path) { return $null };$edited.OutputDirectory=$path
                $publish=Read-InterfaceSetupYesNo -Prompt 'Publish to local WUG?' -Default ([bool]$edited.PublishToWug)
                if ($null -eq $publish) { return $null }
                $edited.Remove('PublishToWug');$edited.Remove('PackName');$edited.Remove('NmConsolePath')
                if ($publish) {
                    $pack=Read-InterfaceSetupText -Prompt 'URL pack name' -Pattern '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$' -PatternMessage 'Use a URL-safe name of 1-80 characters.' -Required
                    if ($null -eq $pack) { return $null }
                    $console=Read-InterfaceSetupText -Prompt 'NmConsole directory (blank autodetects)'
                    if ($null -eq $console) { return $null }
                    $edited.PublishToWug=$true;$edited.PackName=$pack
                    if ($console) { $edited.NmConsolePath=$console }
                }
                $groups=Read-InterfaceSetupYesNo -Prompt 'Create owned WUG navigation groups?' -Default ([bool]$edited.CreateWugGroups)
                if ($null -eq $groups) { return $null };$edited.CreateWugGroups=[bool]$groups
            }
            '6' {
                $filter=Read-InterfaceSetupChoice -Prompt 'Devices eligible for reports and optional SNMP' -Choices @('SnmpAssigned','All') -Default SnmpAssigned
                if ($null -eq $filter) {return $null}
                $edited.DeviceFilter=$filter
            }
            '5' {
                $enabled=Read-InterfaceSetupYesNo -Prompt 'Enable SNMP?' -Default ([bool]$edited.UseSnmp)
                if ($null -eq $enabled) { return $null }
                foreach ($key in @($edited.Keys | Where-Object { $_ -like 'Snmp*' -or $_ -in @('UseSnmp','IncludeSnmpOnly') })) { $edited.Remove($key) }
                if ($enabled) {
                    $names=Read-InterfaceSetupText -Prompt 'Ordered existing vault names, comma-separated' -Required
                    if ($null -eq $names) { return $null }
                    $versions=Read-InterfaceSetupText -Prompt 'Aligned V1,V2,V3 versions, comma-separated' -Required
                    if ($null -eq $versions) { return $null }
                    $edited.UseSnmp=$true
                    $edited.SnmpCredentialNames=@($names -split ',' | ForEach-Object { $_.Trim() })
                    $edited.SnmpCredentialVersions=@($versions -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() })
                    $include=Read-InterfaceSetupYesNo -Prompt 'Include SNMP-only Unmonitored ports?' -Default $true
                    if ($null -eq $include) { return $null };$edited.IncludeSnmpOnly=$include
                }
            }
        }
    }
}

if ($WhatIfPreference) {
    Write-Warning 'WhatIf was requested; the setup wizard will not prompt, preview, or run.'
    return
}

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'InterfaceGroupingHelpers.ps1')
. (Join-Path $scriptDir 'InterfaceGroupOperations.ps1')

if (-not $ProfileDirectory) {
    $ProfileDirectory = Join-Path $env:ProgramData 'WhatsUpGoldPS\InterfaceGroups\Profiles'
}
$ProfileDirectory = [IO.Path]::GetFullPath($ProfileDirectory)
$invokeProfilePath = Join-Path $scriptDir 'Invoke-InterfaceGroupProfile.ps1'
$registerTaskPath = Join-Path $scriptDir 'Register-InterfaceGroupScheduledTask.ps1'
$newProfile = $false
$settings = $null
$profilePath = $null

$profileFiles = @()
if (Test-Path -LiteralPath $ProfileDirectory -PathType Container) {
    $profileFiles = @(Get-ChildItem -LiteralPath $ProfileDirectory -File -Filter '*.json' -ErrorAction Stop |
        Sort-Object Name)
}
$profileChoices = [System.Collections.Generic.List[string]]::new()
$profileChoices.Add('N=Create a new profile')
if ($profileFiles.Count -gt 0) { $profileChoices.Add('E=Reuse an existing profile') }
$profileMode = Read-InterfaceSetupChoice -Prompt 'Choose profile setup' -Choices ($profileChoices.ToArray())
if ($null -eq $profileMode) { Write-Verbose 'Setup cancelled at profile selection.'; return }

if ($profileMode -eq 'E') {
    $numbered = [System.Collections.Generic.List[object]]::new()
    $numberedChoices = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $profileFiles.Count; $index++) {
        $key = [string]($index + 1)
        $numbered.Add([pscustomobject]@{ Key = $key; File = $profileFiles[$index] })
        $numberedChoices.Add("$key=$($profileFiles[$index].BaseName)")
    }
    $selected = Read-InterfaceSetupChoice -Prompt 'Select a saved profile' -Choices ($numberedChoices.ToArray())
    if ($null -eq $selected) { Write-Verbose 'Setup cancelled at saved-profile selection.'; return }
    $entry = $numbered | Where-Object { $_.Key -eq $selected } | Select-Object -First 1
    if (-not $entry) { throw 'The selected profile could not be resolved.' }
    $profilePath = $entry.File.FullName
    $settings = Read-InterfaceGroupProfile -Path $profilePath
    $action=Read-InterfaceSetupChoice -Prompt 'Saved profile action' -Choices @('R=Run unchanged','M=Edit settings','C=Clone into a new profile') -Default R
    if ($null -eq $action) { return }
    if ($action -eq 'C') {
        $clone=Read-InterfaceSetupText -Prompt 'New clone name' -Pattern '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$' -PatternMessage 'Use a URL-safe name, 1-80 characters.' -Required
        if ($null -eq $clone) { return }
        $profilePath=Join-Path $ProfileDirectory "$clone.json"
        if (Test-Path -LiteralPath $profilePath) { throw 'Clone destination already exists; choose a different name.' }
        $settings.OutputDirectory=Join-Path $env:ProgramData "WhatsUpGoldPS\Output\InterfaceGroups\$clone"
        $settings.Remove('ReviewPath')
        if ($settings.PublishToWug) { $settings.PackName=$clone }
        if ($settings.CreateWugGroups) { $settings.FolderName="Interface Groups - $clone" }
        Write-Warning 'Clone uses separate output/publication/navigation names and does not copy pinned review decisions.'
        $newProfile=$true
    }
    if ($action -in @('M','C')) {
        $settings=Edit-InterfaceSetupSettings -Settings $settings
        if ($null -eq $settings) { return }
        if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings -Action 'Save edited or cloned interface profile')) { return }
    }
}
else {
    $newProfile = $true
    $name = Read-InterfaceSetupText -Prompt 'New profile name (letters, digits, hyphens, underscores)' `
        -Pattern '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$' `
        -PatternMessage 'Use 1-80 letters, digits, hyphens, or underscores; start with a letter or digit.' -Required
    if ($null -eq $name) { Write-Verbose 'Setup cancelled at profile naming.'; return }
    $slug = Get-InterfaceSetupSlug -Name $name
    $profilePath = Join-Path $ProfileDirectory "$slug.json"
    while (Test-Path -LiteralPath $profilePath) {
        Write-Warning "A profile already exists at $profilePath; choose another name or reuse the existing profile."
        $name = Read-InterfaceSetupText -Prompt 'New profile name' `
            -Pattern '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$' `
            -PatternMessage 'Use 1-80 letters, digits, hyphens, or underscores; start with a letter or digit.' -Required
        if ($null -eq $name) { Write-Verbose 'Setup cancelled at profile naming.'; return }
        $slug = Get-InterfaceSetupSlug -Name $name
        $profilePath = Join-Path $ProfileDirectory "$slug.json"
    }

    $settings = @{}
    $scope = Read-InterfaceSetupChoice -Prompt 'Choose the source inventory scope' -Choices @(
        '1=Selected device IDs', '2=Existing group IDs', '3=All accessible devices', '4=Browse device names and select IDs')
    if ($null -eq $scope) { Write-Verbose 'Setup cancelled at source-scope selection.'; return }
    switch ($scope) {
        '1' {
            $ids = Read-InterfaceSetupIds -Prompt 'Enter WUG device IDs'
            if ($null -eq $ids) { Write-Verbose 'Setup cancelled at device-ID selection.'; return }
            $settings.DeviceId = @($ids)
        }
        '2' {
            $ids = Read-InterfaceSetupIds -Prompt 'Enter existing WUG source group IDs'
            if ($null -eq $ids) { Write-Verbose 'Setup cancelled at group-ID selection.'; return }
            $settings.GroupId = @($ids)
            $hierarchy = Read-InterfaceSetupYesNo -Prompt 'Include devices in child groups?' -Default $false
            if ($null -eq $hierarchy) { Write-Verbose 'Setup cancelled at hierarchy selection.'; return }
            if ($hierarchy) { $settings.ReturnHierarchy = $true }
        }
        '3' { $settings.AllDevices = $true }
        '4' {
            Connect-InterfaceGroupServer -ErrorAction Stop
            $available=@(Get-WUGDevice -DeviceGroupID '-2' -ReturnHierarchy true -View basic -Limit 250 -ErrorAction Stop)
            $available | Select-Object id,displayName,networkAddress | Sort-Object displayName | Format-Table -AutoSize
            $ids=Read-InterfaceSetupIds -Prompt 'Choose IDs from the named list'
            if ($null -eq $ids) { return }
            $accessible=@{};foreach ($device in $available) { $accessible[[string]$device.id]=$true }
            foreach ($id in $ids) { if (-not $accessible.ContainsKey([string]$id)) { throw "Selected device $id was not in the accessible list." } }
            $settings.DeviceId=@($ids)
        }
    }

    $mode = Read-InterfaceSetupChoice -Prompt 'Choose the grouping mode' -Choices @(
        '1=NamedGroups', '2=AllInterfaces', '3=AutoGroups', '4=IntelligentGroups','5=Saved phrase rules')
    if ($null -eq $mode) { Write-Verbose 'Setup cancelled at grouping-mode selection.'; return }
    $modeMap = @{ '1' = 'NamedGroups'; '2' = 'AllInterfaces'; '3' = 'AutoGroups'; '4' = 'IntelligentGroups';'5'='Rules' }
    $settings.Mode = $modeMap[$mode]
    if ($settings.Mode -eq 'Rules') {
        $ruleSettings=Read-InterfaceSetupRules
        if ($null -eq $ruleSettings) {return}
        $settings.Rules=$ruleSettings.Rules;$settings.RuleMode=$ruleSettings.RuleMode
    }
    if ($settings.Mode -eq 'IntelligentGroups') {
        $strategy = Read-InterfaceSetupChoice -Prompt 'Choose intelligent grouping strategy' -Choices @(
            '1=Prefix (one group per interface)', '2=Words (overlapping word groups)')
        if ($null -eq $strategy) { Write-Verbose 'Setup cancelled at strategy selection.'; return }
        if ($strategy -eq '1') { $settings.Strategy = 'Prefix' } else { $settings.Strategy = 'Words' }
    }
    if ($settings.Mode -eq 'NamedGroups') {
        while ($true) {
            $labels = Read-InterfaceSetupText -Prompt 'Named group labels, comma-separated (blank keeps GroupA through GroupL)'
            if ($null -eq $labels) { Write-Verbose 'Setup cancelled at group-label selection.'; return }
            if ([string]::IsNullOrWhiteSpace($labels)) { break }
            $groupLabels = @($labels -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($groupLabels.Count -gt 0) {
                $settings.GroupName = $groupLabels
                break
            }
            Write-Warning 'At least one nonblank group label is required.'
        }
    }
    if ($settings.Mode -in @('NamedGroups', 'AutoGroups')) {
        $matchMode = Read-InterfaceSetupChoice -Prompt 'Choose literal description matching' -Choices @(
            '1=Token (default)', '2=Exact', '3=Substring','4=StartsWith','5=EndsWith','6=Contains')
        if ($null -eq $matchMode) { Write-Verbose 'Setup cancelled at match-mode selection.'; return }
        $matchMap = @{ '1' = 'Token'; '2' = 'Exact'; '3' = 'Substring';'4'='StartsWith';'5'='EndsWith';'6'='Contains' }
        $settings.MatchMode = $matchMap[$matchMode]
    }

    $range = Read-InterfaceSetupChoice -Prompt 'Choose the report window' -Choices @(
        '1=lastPolled (quick snapshot)', '2=today', '3=yesterday', '4=lastWeek',
        '5=lastNHours', '6=lastNDays')
    if ($null -eq $range) { Write-Verbose 'Setup cancelled at report-window selection.'; return }
    $rangeMap = @{ '1' = 'lastPolled'; '2' = 'today'; '3' = 'yesterday'; '4' = 'lastWeek'; '5' = 'lastNHours'; '6' = 'lastNDays' }
    $settings.Range = $rangeMap[$range]
    if ($settings.Range -in @('lastNHours', 'lastNDays')) {
        $rangeCount = Read-InterfaceSetupInteger -Prompt 'Number of hours or days' -Minimum 1 -Maximum 365 -Default 4
        if ($null -eq $rangeCount) { Write-Verbose 'Setup cancelled at range length.'; return }
        $settings.RangeN = $rangeCount
    }
    $stale = Read-InterfaceSetupInteger -Prompt 'Freshness threshold in minutes' -Minimum 1 -Maximum 525600 -Default 60
    if ($null -eq $stale) { Write-Verbose 'Setup cancelled at freshness selection.'; return }
    $settings.StaleAfterMinutes = $stale

    $snmp = Read-InterfaceSetupYesNo -Prompt 'Include optional SNMP interface discovery?' -Default $false
    if ($null -eq $snmp) { Write-Verbose 'Setup cancelled at SNMP selection.'; return }
    if ($snmp) {
        $showVaultEntries = Read-InterfaceSetupYesNo -Prompt 'Show available discovery-vault credential names and metadata-only field types?' -Default $false
        if ($null -eq $showVaultEntries) { Write-Verbose 'Setup cancelled at vault metadata selection.'; return }
        $discoveryHelpers = Join-Path (Split-Path $scriptDir -Parent) 'discovery\DiscoveryHelpers.ps1'
        if ($showVaultEntries) {
            . $discoveryHelpers
            $vaultMetadata = @(Get-DiscoveryCredential -ErrorAction Stop |
                Select-Object Name, Type, Fields)
            if ($vaultMetadata.Count -gt 0) {
                $vaultMetadata | Format-Table -Property Name, Type, Fields -AutoSize
            }
            else {
                Write-Warning 'No discovery-vault entries were listed. Enter only the credential names you want to use.'
            }
        }
        while ($true) {
            $namesText = Read-InterfaceSetupText -Prompt 'SNMP credential names in priority order, comma-separated' -Required
            if ($null -eq $namesText) { Write-Verbose 'Setup cancelled at SNMP credential selection.'; return }
            $credentialNames = @($namesText -split ',' | ForEach-Object { $_.Trim() })
            if ($credentialNames.Count -le 12 -and $credentialNames.Count -gt 0 -and
                -not @($credentialNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { break }
            Write-Warning 'Supply 1-12 nonblank SNMP credential names, in the intended attempt order.'
        }
        while ($true) {
            Write-Output 'Use V1/V2 for a Single community or Community bundle; use V3 for a Username/AuthProtocol/PrivacyProtocol bundle.'
            $versionsText = Read-InterfaceSetupText -Prompt 'Matching credential versions in the same order (V1, V2, or V3)' -Required
            if ($null -eq $versionsText) { Write-Verbose 'Setup cancelled at SNMP version selection.'; return }
            $versions = @($versionsText -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() })
            if ($versions.Count -eq $credentialNames.Count -and
                -not @($versions | Where-Object { $_ -notin @('V1', 'V2', 'V3') }).Count) { break }
            Write-Warning 'Provide one V1, V2, or V3 version for each credential name, in matching order.'
        }
        $settings.UseSnmp = $true
        $settings.SnmpCredentialNames = $credentialNames
        $settings.SnmpCredentialVersions = $versions
        $includeOnly = Read-InterfaceSetupYesNo -Prompt 'Include SNMP-only interfaces as Unmonitored?' -Default $true
        if ($null -eq $includeOnly) { Write-Verbose 'Setup cancelled at SNMP-only selection.'; return }
        $settings.IncludeSnmpOnly = [bool]$includeOnly
        $failure = Read-InterfaceSetupChoice -Prompt 'SNMP failure handling' `
            -Choices @('1=Warn and continue', '2=Stop') -Default '1'
        if ($null -eq $failure) { Write-Verbose 'Setup cancelled at SNMP failure handling.'; return }
        if ($failure -eq '1') { $settings.SnmpFailureAction = 'Warn' } else { $settings.SnmpFailureAction = 'Stop' }
        $port = Read-InterfaceSetupInteger -Prompt 'SNMP port' -Minimum 1 -Maximum 65535 -Default 161
        if ($null -eq $port) { Write-Verbose 'Setup cancelled at SNMP port.'; return }
        $settings.SnmpPort = $port
        $timeout = Read-InterfaceSetupInteger -Prompt 'SNMP timeout in milliseconds' -Minimum 500 -Maximum 60000 -Default 3000
        if ($null -eq $timeout) { Write-Verbose 'Setup cancelled at SNMP timeout.'; return }
        $settings.SnmpTimeout = $timeout

        $createCredentials = Read-InterfaceSetupYesNo -Prompt 'Create or confirm these named credentials in the local discovery vault now?' -Default $false
        if ($null -eq $createCredentials) { Write-Verbose 'Setup cancelled at SNMP credential-creation selection.'; return }
        if ($createCredentials) {
            if (-not $showVaultEntries) { . $discoveryHelpers }
            Write-Output 'For an existing vault entry, Y uses it, R resets it, and N skips it and cancels this setup. No skipped credential will be used.'
            for ($credentialIndex = 0; $credentialIndex -lt $credentialNames.Count; $credentialIndex++) {
                $credentialType = 'SNMPv2'
                if ($versions[$credentialIndex] -eq 'V3') { $credentialType = 'SNMPv3' }
                Write-Verbose "Resolving named SNMP credential '$($credentialNames[$credentialIndex])' as $credentialType."
                $resolvedCredential = Resolve-DiscoveryCredential -Name $credentialNames[$credentialIndex] `
                    -CredType $credentialType -ErrorAction Stop
                if ($null -eq $resolvedCredential) {
                    Write-Warning "Setup cancelled: credential '$($credentialNames[$credentialIndex])' was skipped. Restart setup to select another credential or disable SNMP."
                    return
                }
                $resolvedCredential = $null
            }
        }
    }

    $createGroups = Read-InterfaceSetupYesNo -Prompt 'Create opt-in WUG navigation groups during the approved run?' -Default $false
    if ($null -eq $createGroups) { Write-Verbose 'Setup cancelled at WUG group creation selection.'; return }
    if ($createGroups) {
        $settings.CreateWugGroups = $true
        $settings.FolderName = "Interface Groups - $slug"
    }
    $publish = Read-InterfaceSetupYesNo -Prompt 'Publish the generated dashboard pack to the local WUG web console?' -Default $false
    if ($null -eq $publish) { Write-Verbose 'Setup cancelled at publishing selection.'; return }
    if ($publish) {
        Write-Output 'Publishing copies to an existing local WUG installation; an API connection to a remote WUG server does not provide filesystem publishing.'
        $console = Read-InterfaceSetupText -Prompt 'Existing NmConsole directory (blank autodetects on the WUG host; Q cancels)'
        if ($null -eq $console) { Write-Verbose 'Setup cancelled at publishing directory selection.'; return }
        $settings.PublishToWug = $true
        if ($console) { $settings.NmConsolePath = $console.Trim('"') }
        $settings.PackName = "interfaces-$slug"
        if ($settings.PackName.Length -gt 80) { $settings.PackName = $slug }
    }
    $settings.OutputDirectory = Join-Path $env:ProgramData "WhatsUpGoldPS\Output\InterfaceGroups\$slug"

    if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings `
            -Action 'Save new interface grouping profile')) {
        Write-Verbose 'Profile save was declined.'
        return
    }
}

$profileSlug = [IO.Path]::GetFileNameWithoutExtension($profilePath)
$profileSlug = Get-InterfaceSetupSlug -Name $profileSlug
if (-not $settings.ContainsKey('OutputDirectory') -or
    [string]::IsNullOrWhiteSpace([string]$settings.OutputDirectory)) {
    $settings.OutputDirectory = Join-Path $env:ProgramData "WhatsUpGoldPS\Output\InterfaceGroups\$profileSlug"
    if (-not $newProfile) {
        if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings `
                -Action 'Add a profile-specific ProgramData output directory')) {
            Write-Verbose 'Profile output-directory update was declined.'
            return
        }
    }
}
$outputDirectory = [IO.Path]::GetFullPath([string]$settings.OutputDirectory)
if (-not $settings.ContainsKey('DeviceFilter') -and $settings.UseSnmp) {
    Write-Output 'Efficiency: only devices with assigned WUG SNMP credentials will be collected. Other devices are skipped before reports/probes. Edit option 6 to select All.'
    $settings.DeviceFilter='SnmpAssigned'
    if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings -Action 'Save SNMP-assigned device eligibility')) {return}
}
while ($true) {
    $readiness=Test-InterfaceGroupReadiness -ProfilePath $profilePath
    $readiness.Checks | Format-Table Check,Status,Detail -Wrap -AutoSize
    if ($readiness.ReadyToAttempt) { break }
    $failedChecks=@($readiness.Checks | Where-Object Status -eq 'Failed')
    if (@($failedChecks | Where-Object Check -eq 'Publishing configuration').Count -eq 0) {
        throw "Readiness checks failed: $(($failedChecks | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join '; ')"
    }
    Write-Output 'This saved profile still has publishing enabled. Remote WUG API access does not provide a local WUG web directory.'
    $repair=Read-InterfaceSetupChoice -Prompt 'Correct publishing before continuing' -Choices @(
        '1=Disable publishing in this profile (generate local dashboards)',
        '2=Set the existing WUG NmConsole directory') -Default '1'
    if ($null -eq $repair) { Write-Verbose 'Setup cancelled at publishing readiness correction.'; return }
    $correctedSettings=@{}
    foreach ($key in $settings.Keys) { $correctedSettings[$key]=$settings[$key] }
    if ($repair -eq '1') {
        foreach ($key in @('PublishToWug','NmConsolePath','PackName')) { $correctedSettings.Remove($key) }
    }
    else {
        $console=Read-InterfaceSetupText -Prompt 'Existing WUG NmConsole directory' -Required
        if ($null -eq $console) { Write-Verbose 'Setup cancelled at publishing directory correction.'; return }
        $correctedSettings.NmConsolePath=$console.Trim('"')
    }
    if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $correctedSettings -Action 'Save corrected publishing settings')) {
        Write-Verbose 'Publishing correction save was declined.'
        return
    }
    $settings=$correctedSettings
}
$previewPath = Join-Path $outputDirectory "$profileSlug-preview.csv"
if (-not $PSCmdlet.ShouldProcess($profilePath, "Collect inventory and write preview to $previewPath")) {
    Write-Verbose 'Preview was declined.'
    return
}
$previewResult = & $invokeProfilePath -ProfilePath $profilePath -PreviewOnly -PreviewPath $previewPath -Confirm:$false -ErrorAction Stop
Write-Output "This is what we got: $($previewResult.DeviceCount) eligible devices, $($previewResult.SkippedDeviceCount) skipped, $(@($previewResult.Inventory).Count) interfaces. Saved observations: $($previewResult.InventoryPath)"
$previewGroups = @($previewResult.Groups)
$previewResult.Inventory | Select-Object DeviceId,DeviceName | Sort-Object DeviceId -Unique | Format-Table -AutoSize
$analysis=Get-InterfaceGroupSelectionSummary -Inventory @($previewResult.Inventory) -Groups $previewGroups
Write-Output "Review: $($analysis.Unmatched) unmatched / $($analysis.Overlapping) overlapping / $($analysis.MembershipCount) memberships."
$previewGroups | Select-Object Name,InterfaceCount,MatchBasis | Format-Table -Wrap -AutoSize
$proposedInterfaces = 0
foreach ($group in $previewGroups) { $proposedInterfaces += [int]$group.InterfaceCount }
Write-Output "Proposed plan: $($previewGroups.Count) groups; $proposedInterfaces memberships across $(@($previewResult.Inventory).Count) unique interfaces. You may accept it without editing individual rows."

$reviewChoice = Read-InterfaceSetupChoice -Prompt 'Review the proposals before the full run' -Choices @(
    '1=Open CSV for optional editing', '2=Review each interface interactively', '3=Continue without edits',
    '4=Graphical browser review (download decisions CSV)')
if ($null -eq $reviewChoice) { Write-Verbose 'Setup cancelled after preview.'; return }
$reviewCsv = $previewResult.PreviewPath
$runReviewPath = $null
if ($reviewChoice -eq '1') {
    Start-Process -FilePath $reviewCsv -ErrorAction Stop
    $edited = Read-InterfaceSetupYesNo -Prompt 'Did you edit the preview CSV and want to apply those decisions?' -Default $false
    if ($null -eq $edited) { Write-Verbose 'Setup cancelled after opening the preview.'; return }
    if ($edited) {
        $runReviewPath = $reviewCsv
        $saveReview = Read-InterfaceSetupYesNo -Prompt "Copy decisions to $profileSlug-review.csv and save them in this profile?" -Default $false
        if ($null -eq $saveReview) { Write-Verbose 'Setup cancelled before saving reviewed decisions.'; return }
        if ($saveReview) {
            $durableReviewPath = Join-Path $outputDirectory "$profileSlug-review.csv"
            if (-not $PSCmdlet.ShouldProcess($durableReviewPath, 'Save reviewed interface-group decisions')) {
                Write-Verbose 'Saving reviewed decisions was declined.'
                return
            }
            $null = New-Item -ItemType Directory -Path $outputDirectory -Force -ErrorAction Stop
            Copy-Item -LiteralPath $reviewCsv -Destination $durableReviewPath -Force -ErrorAction Stop
            $settings.ReviewPath = $durableReviewPath
            if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings `
                    -Action 'Save reviewed decisions in the interface grouping profile')) {
                Write-Verbose 'Updating the profile with reviewed decisions was declined.'
                return
            }
        }
    }
}
elseif ($reviewChoice -eq '4') {
    $htmlPath=Join-Path $outputDirectory "$profileSlug-review.html"
    if (-not $PSCmdlet.ShouldProcess($htmlPath,'Write and open local graphical interface review')) { return }
    $null=Export-InterfaceGroupBrowserReview -Inventory @($previewResult.Inventory) -Groups $previewGroups -Decisions $previewResult.Decisions -Path $htmlPath -Confirm:$false
    Start-Process -FilePath $htmlPath -ErrorAction Stop
    Write-Output 'Edit groups in the browser and download the decisions CSV. The page does not write to WUG or save your profile.'
    $download=Read-InterfaceSetupText -Prompt 'Downloaded decisions CSV full path (blank continues without browser edits)'
    if ($null -eq $download) { return }
    if ($download) {
        $download=[IO.Path]::GetFullPath($download.Trim('"'))
        $decisions=@(Import-Csv -LiteralPath $download -ErrorAction Stop)
        $null=@(Set-InterfaceGroupReview -Inventory @($previewResult.Inventory) -Groups $previewGroups -Decisions $decisions)
        $runReviewPath=$download
        $saveReview=Read-InterfaceSetupYesNo -Prompt "Save downloaded decisions to $profileSlug-review.csv for future runs?" -Default $true
        if ($null -eq $saveReview) { return }
        if ($saveReview) {
            $durableReviewPath=Join-Path $outputDirectory "$profileSlug-review.csv"
            if (-not $PSCmdlet.ShouldProcess($durableReviewPath,'Save browser-reviewed grouping decisions')) { return }
            if ($download -ine [IO.Path]::GetFullPath($durableReviewPath)) { Copy-Item -LiteralPath $download -Destination $durableReviewPath -Force -ErrorAction Stop }
            $settings.ReviewPath=$durableReviewPath
            if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings -Action 'Save browser review reference in profile')) { return }
        }
    }
}
elseif ($reviewChoice -eq '2') {
    $interactivePreviewPath = Join-Path $outputDirectory "$profileSlug-interactive-review.csv"
    if (-not $PSCmdlet.ShouldProcess($profilePath, 'Interactively review interface-group proposals')) {
        Write-Verbose 'Interactive review was declined.'
        return
    }
    $reviewResult = & $invokeProfilePath -ProfilePath $profilePath -PreviewOnly -Review -Collection $previewResult.Collection `
        -PreviewPath $interactivePreviewPath -Confirm:$false -ErrorAction Stop
    $reviewCsv = $reviewResult.PreviewPath
    $runReviewPath = $reviewCsv
    $saveReview = Read-InterfaceSetupYesNo -Prompt "Save interactive decisions to $profileSlug-review.csv and this profile for future runs?" -Default $true
    if ($null -eq $saveReview) { Write-Verbose 'Setup cancelled after interactive review.'; return }
    if ($saveReview) {
        $durableReviewPath = Join-Path $outputDirectory "$profileSlug-review.csv"
        if (-not $PSCmdlet.ShouldProcess($durableReviewPath, 'Save interactively reviewed interface-group decisions')) {
            Write-Verbose 'Saving reviewed decisions was declined.'
            return
        }
        $null = New-Item -ItemType Directory -Path $outputDirectory -Force -ErrorAction Stop
        Copy-Item -LiteralPath $reviewCsv -Destination $durableReviewPath -Force -ErrorAction Stop
        $settings.ReviewPath = $durableReviewPath
        if (-not (Save-InterfaceSetupProfile -Path $profilePath -Settings $settings `
                -Action 'Save reviewed decisions in the interface grouping profile')) {
            Write-Verbose 'Updating the profile with reviewed decisions was declined.'
            return
        }
    }
}

$approved = Read-InterfaceSetupYesNo -Prompt 'Approve the full interface grouping run with the saved profile?' -Default $false
if ($null -eq $approved) { Write-Verbose 'Setup cancelled before the full run.'; return }
if (-not $approved) { Write-Verbose 'The full interface grouping run was not approved.'; return }
if (-not $PSCmdlet.ShouldProcess($profilePath, 'Run the approved interface grouping profile')) {
    Write-Verbose 'The full interface grouping run was declined.'
    return
}
$runParameters = @{ ProfilePath = $profilePath; Confirm = $false; ErrorAction = 'Stop' }
$runParameters.Collection=$previewResult.Collection
if ($runReviewPath -and -not $settings.ReviewPath) { $runParameters.ReviewPath = $runReviewPath }
elseif ($runReviewPath -and $settings.ReviewPath -ne $durableReviewPath) { $runParameters.ReviewPath = $runReviewPath }
$result = & $invokeProfilePath @runParameters

if ($result.IndexPath) {
    Write-Output "Dashboard: $($result.IndexPath)"
    Write-Output "Open it: Start-Process '$($result.IndexPath.Replace("'","''"))'"
    Write-Output "Next live refresh (no wizard): & '$invokeProfilePath' -ProfilePath '$($profilePath.Replace("'","''"))'"
    Write-Output "Offline demo (no API/SNMP): & '$invokeProfilePath' -ProfilePath '$($profilePath.Replace("'","''"))' -InventoryPath '$($previewResult.InventoryPath.Replace("'","''"))'"
}
if ($result.Publication -and $result.Publication.PublishedPath) {
    Write-Output "Published dashboard: $($result.Publication.PublishedPath)"
}

if (-not $SkipSchedule) {
    $schedule = Read-InterfaceSetupYesNo -Prompt 'Register an optional recurring scheduled refresh?' -Default $false
    if ($null -eq $schedule) { Write-Verbose 'Setup cancelled at scheduling prompt.'; return }
    if ($schedule) {
        $trigger = Read-InterfaceSetupChoice -Prompt 'Choose scheduled refresh timing' -Choices @(
            '1=Hourly', '2=Daily', '3=AtStartup')
        if ($null -eq $trigger) { Write-Verbose 'Setup cancelled at schedule timing.'; return }
        $triggerMap = @{ '1' = 'Hourly'; '2' = 'Daily'; '3' = 'AtStartup' }
        $triggerType = $triggerMap[$trigger]
        $logon = Read-InterfaceSetupChoice -Prompt 'Choose the scheduled-task logon mode explicitly' -Choices @(
            '1=S4U (unattended; may not access network or user vault)', '2=Interactive (only while logged on)')
        if ($null -eq $logon) { Write-Verbose 'Setup cancelled at task logon selection.'; return }
        $logonType = 'S4U'
        if ($logon -eq '2') { $logonType = 'Interactive' }
        $taskParameters = @{
            Register = $true
            ProfilePath = $profilePath
            TriggerType = $triggerType
            LogonType = $logonType
            Confirm = $false
            ErrorAction = 'Stop'
        }
        if ($triggerType -eq 'Hourly') {
            $interval = Read-InterfaceSetupInteger -Prompt 'Hourly repeat interval in minutes' -Minimum 5 -Maximum 1440 -Default 30
            if ($null -eq $interval) { Write-Verbose 'Setup cancelled at task interval.'; return }
            $taskParameters.RepeatIntervalMinutes = $interval
        }
        if ($triggerType -in @('Hourly', 'Daily')) {
            $time = Read-InterfaceSetupText -Prompt 'Local task start time (HH:mm)' -Default '00:00' `
                -Pattern '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' `
                -PatternMessage 'Use a 24-hour time such as 02:30.' -Required
            if ($null -eq $time) { Write-Verbose 'Setup cancelled at task start-time selection.'; return }
            $taskParameters.TimeOfDay = $time
        }
        $taskName = "InterfaceGroups-$profileSlug"
        if (-not $PSCmdlet.ShouldProcess($taskName, "Register $triggerType interface refresh ($logonType)")) {
            Write-Verbose 'Scheduled-task registration was declined.'
            return
        }
        $null = & $registerTaskPath @taskParameters
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDDtpacB0dAhDEQ
# vcdTxBsy6u3BfTfrtLvstXAuzb4eOKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCC0
# HOcxxClILVKZpeXtqN9LpbYVwVqFAUejRfYKvcge+TANBgkqhkiG9w0BAQEFAASC
# AgAX/AXfM6Zho4GQYAZ7AW6SnGLVZ6/t9db17Y+QZg6o1lIcXvzcBIGp1EVIc6yn
# JjOEX357s6P304szGqSU9f4Tl7JaHZkeRyz3MTwNgjVekKJzEgjI+8PKz9RxOT+F
# 5Fs/gj90SZyez//u7qrwPmJz513EPkgnZO9RyGUKezJKdCFrGFz5wSXonIx+WPbV
# Izp18ZDkmd42/ohCrV3RPo2TyCiq4UkmdMaUEdcDhDPKmOAwnRUbrN5CAQdbQCCc
# iNm/TTFEw0L1oLZphEeRXBj1+cwdUNQVN0EgYSvaNICDF9fWlwYSlWXHLw5rtbzS
# fvLIOWTEsM5t3F6NQSxgFUDl72U8f8jIZl/mTF8YX+UzcWy/z3bzuscP83rqC2T2
# IuE7CK27RaNDcxjgQlCPm07DAjqKXItjhaVPMUCcgHAiB1cVG1sfrDuLARgEZkQd
# hNOE6nInnn+ppZfez40e0DejRKMd54oGAdtIY3p4VaHA5GcLzW1jJqbtGeM5eXQs
# RPLnJ5Z/AboiTu/t+B4RbAopaCXpoysK6ujvg8HkyxB3wbZieN1ZAASV0KxViS51
# 7CI7WNWO342Yyy4c9QocNumyt1ivVY2cvXsyc2K5DVbzLljn0UNQoyUvSY6uXlc6
# eWsB/wewxnbD73PoshMBiL02FDR7M9BeXgvvQLp06OTOhKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzNDhaMC8GCSqGSIb3DQEJBDEiBCBmZAqtOoWn
# 3hvk+b9UhbA9J4b3PnGPR1C94ElVbL5mETANBgkqhkiG9w0BAQEFAASCAgAbUUZP
# h/4jBNevt4cdTWLbsdl9u3uEHfka3qIxP69gzmE+vrAL9TpS5/25rmX+pado77T6
# ARP2okBqMmRot4v4WGh/LVSQ6If3Xjn9fmqoRvuM1eugE60cWkP4vWKZ2KPWVHPB
# iX1lWyHmmMtvRAkWpVfKEkUVkHnwqjgK8X4Q441JP90+vmU616kQtGUhdNaHdxQY
# dG6KzxsmKlsE7HtaHjBsAS7n77dGGITSi2lO0WQhTxaDjg2Xknha9F9JHlfMqURv
# hxhQAedlLCzi6LPnxg/Vf+6d1uaU6WkzGpQKkz2yMDjXgXNF4SkOKMjyNJ3yrHvs
# Zybnnh1mjMOxagTHNkugz6PjdA1fCZSexwrXRGkdJljVylCBy1bBO9GVYr/P8E+y
# XMjqVieKEkP/wDzYPNqijjx7pk6nNxr3jYKiKgaNIChw9bqzF97XgS3W1d3f9hz+
# iAJjRY2IGkas2agUIHePgQX2M4iplWB6i7OPm66hX42egcDHI3tKs11oK1SlnEY6
# Gievv6PeOLDiuO9D8vu0hWEpSOhnoDMJfrsUk90LegYcrH4/pJWw1AwxPlVsbWFQ
# bhSXaVWMXj32S/WCxcyNrhaAEWtmFsIteFEhhWedTzA+F4j/UXz4F2EHxl13gmDG
# jQbBVHohVNRU6UgTqWNBuKSC8diaugfUvDCsuw==
# SIG # End signature block
