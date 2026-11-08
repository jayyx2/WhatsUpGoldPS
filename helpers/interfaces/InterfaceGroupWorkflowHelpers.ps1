#requires -Version 5.1
function Get-InterfaceGroupKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Interface)
    if ($Interface.IfIndex) { return "$($Interface.DeviceId):$($Interface.IfIndex)" }
    if (@($Interface.TrafficInterfaceIds).Count -eq 0) { throw 'Interface has neither ifIndex nor traffic ID.' }
    return "$($Interface.DeviceId):report:$(@($Interface.TrafficInterfaceIds | Sort-Object) -join ',')"
}

function Get-InterfaceGroupLogDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilePath)
    $resolved = [IO.Path]::GetFullPath($ProfilePath)
    $key = (Get-WUGDashboardGroupPageName -Name $resolved).Replace('group-', 'profile-').Replace('.html', '')
    Join-Path $env:ProgramData "WhatsUpGoldPS\Output\InterfaceGroups\logs\$key"
}

function Write-InterfaceGroupRunRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Json)
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary,$Json,[Text.UTF8Encoding]::new($true))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } }
}

function Test-InterfaceGroupCancellation {
    [CmdletBinding()]
    param([string]$CancellationPath)
    if ($CancellationPath -and (Test-Path -LiteralPath $CancellationPath)) {
        throw [OperationCanceledException]::new("Interface grouping cancelled by signal file: $CancellationPath")
    }
}

function Open-InterfaceGroupRunLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputDirectory)
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
    $path = Join-Path $OutputDirectory '.interface-grouping.lock'
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe run lock path: $path" }
    }
    try { [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw "Cannot acquire interface grouping run lock (another run or filesystem error): $path. $($_.Exception.Message)" }
}

function Add-InterfaceGroupFreshness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [ValidateRange(1, 525600)][int]$StaleAfterMinutes = 60,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    foreach ($row in $Inventory) {
        $latest = $null
        $invalid = $false
        foreach ($value in @($row.PollTimeUtc) + @($row.Samples | ForEach-Object { $_.PollTimeUtc })) {
            if (-not $value) { continue }
            $parsed = [DateTimeOffset]::MinValue
            if ($value -is [DateTimeOffset]) { $parsed = $value }
            elseif ($value -is [DateTime]) {
                $date = $value
                if ($date.Kind -eq [DateTimeKind]::Unspecified) { $date = [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc) }
                $parsed = [DateTimeOffset]::new($date)
            }
            elseif (-not [DateTimeOffset]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $invalid = $true; continue }
            if ($null -eq $latest -or $parsed -gt $latest) { $latest = $parsed }
        }
        $age = $null
        $freshness = 'Missing'
        if ($null -ne $latest) {
            $age = ($Now - $latest).TotalMinutes
            if ($age -lt -5) { $freshness = 'Future' }
            elseif ($age -gt $StaleAfterMinutes) { $freshness = 'Stale' }
            else { $freshness = 'Fresh' }
        }
        elseif ($invalid) { $freshness = 'Invalid' }
        if ($invalid) { Write-Warning "Interface $(Get-InterfaceGroupKey $row) has invalid report/sample timestamps." }
        $row | Add-Member -NotePropertyName InterfaceKey -NotePropertyValue (Get-InterfaceGroupKey $row) -Force
        $row | Add-Member -NotePropertyName Freshness -NotePropertyValue $freshness -Force
        $row | Add-Member -NotePropertyName LastSampleUtc -NotePropertyValue $(if ($latest) { $latest.UtcDateTime.ToString('o') } else { $null }) -Force
        $row | Add-Member -NotePropertyName AgeMinutes -NotePropertyValue $(if ($null -ne $age) { [Math]::Round($age, 2) } else { $null }) -Force
    }
}

function Get-InterfaceGroupHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)
    $unique = @($Inventory | Sort-Object InterfaceKey -Unique)
    [pscustomobject]@{
        Interfaces = $unique.Count
        Down = @($unique | Where-Object Status -eq Down).Count
        UnknownOrDisabled = @($unique | Where-Object { $_.Status -notin @('Up', 'Down') }).Count
        Stale = @($unique | Where-Object Freshness -eq Stale).Count
        MissingOrInvalidTime = @($unique | Where-Object { $_.Freshness -in @('Missing', 'Invalid', 'Future') }).Count
        MissingActiveMonitor = @($unique | Where-Object { @($_.ActiveAssignmentIds).Count -eq 0 }).Count
        MissingPerformanceCollector = @($unique | Where-Object { @($_.PerformanceAssignmentIds).Count -eq 0 }).Count
        DisabledPerformanceCollector = @($unique | Where-Object { @($_.PerformanceAssignmentIds).Count -gt 0 -and -not $_.PerformanceEnabled }).Count
        SnmpOnly = @($unique | Where-Object InventorySource -eq 'SNMP-only').Count
        SnmpFailedOrPartial = @($unique | Where-Object { $_.SnmpStatus -in @('Failed', 'Partial', 'NotFound') }).Count
    }
}

    function Get-InterfaceGroupSelectionSummary {
        [CmdletBinding()]
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups)
        $counts=@{};$memberships=0
        foreach ($group in $Groups) {
            $seen=@{}
            foreach ($row in @($group.Interfaces)) {
                $key=Get-InterfaceGroupKey $row
                if ($seen.ContainsKey($key)) { continue };$seen[$key]=$true
                if (-not $counts.ContainsKey($key)) { $counts[$key]=0 }
                $counts[$key]++;$memberships++
            }
        }
        $unmatched=0;$overlap=0;$seen=@{}
        foreach ($row in $Inventory) {
            $key=Get-InterfaceGroupKey $row
            if ($seen.ContainsKey($key)) { continue };$seen[$key]=$true
            if (-not $counts.ContainsKey($key)) { $unmatched++ }
            elseif ($counts[$key] -gt 1) { $overlap++ }
        }
        [pscustomobject]@{Interfaces=$seen.Count;Unmatched=$unmatched;Overlapping=$overlap;MembershipCount=$memberships}
    }

    function Format-InterfaceGroupRate {
        [CmdletBinding()]
        param([double]$Bps)
        $unit='bps'
        foreach ($candidate in @('Kbps','Mbps','Gbps','Tbps')) {
            if ($Bps -lt 1000) { break }
            $Bps /= 1000;$unit=$candidate
        }
        $Bps.ToString('0.##',[Globalization.CultureInfo]::InvariantCulture) + " $unit"
    }

    function Get-InterfaceGroupCardSummary {
        [CmdletBinding()]
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)
        $rates=[System.Collections.Generic.List[object]]::new()
        $rxTotal=0.0;$txTotal=0.0;$seen=@{};$monitored=0;$unmonitored=0;$down=0
        foreach ($row in $Inventory) {
            $key=Get-InterfaceGroupKey $row
            if ($seen.ContainsKey($key)) { continue };$seen[$key]=$true
            if (@($row.ActiveAssignmentIds).Count -gt 0) { $monitored++ } else { $unmonitored++ }
            if ($row.Status -eq 'Down') { $down++ }
            if (-not $row.PollTimeUtc -or $row.Freshness -in @('Missing','Invalid','Future') -or $null -eq $row.RxBps -or $null -eq $row.TxBps) { continue }
            $rx=0.0;$tx=0.0
            if (-not [double]::TryParse([string]$row.RxBps,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$rx) -or
                -not [double]::TryParse([string]$row.TxBps,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$tx) -or
                [double]::IsNaN($rx) -or [double]::IsNaN($tx) -or [double]::IsInfinity($rx) -or [double]::IsInfinity($tx) -or $rx -lt 0 -or $tx -lt 0) {
                Write-Warning "Interface $key has invalid rate values; omitted from traffic summary."
                continue
            }
            $label=@($row.IfAlias,$row.InterfaceComment,$row.IfName,$row.InterfaceName,$row.IfDescr) | Where-Object { $_ } | Select-Object -First 1
            $rates.Add([pscustomobject]@{InterfaceKey=$key;Label="$($row.DeviceName) / $label";TotalBps=($rx+$tx);Freshness=$row.Freshness})
            $rxTotal+=$rx;$txTotal+=$tx
        }
        [pscustomobject]@{Monitored=$monitored;Unmonitored=$unmonitored;Down=$down;RateRows=$rates.Count
            RxBps=$(if ($rates.Count) { $rxTotal } else { $null });TxBps=$(if ($rates.Count) { $txTotal } else { $null })
            TopConsumers=@($rates | Sort-Object @{Expression='TotalBps';Descending=$true},InterfaceKey | Select-Object -First 5)}
    }
function New-InterfaceGroupReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups
    )
    $membership = @{}
    $reasons = @{}
    foreach ($group in $Groups) {
        foreach ($row in @($group.Interfaces)) {
            $key = Get-InterfaceGroupKey $row
            if (-not $membership.ContainsKey($key)) { $membership[$key] = [System.Collections.Generic.List[string]]::new() }
            if (-not $membership[$key].Contains([string]$group.Name)) { $membership[$key].Add([string]$group.Name) }
            if (-not $reasons.ContainsKey($key)) { $reasons[$key] = [System.Collections.Generic.List[string]]::new() }
            $reasons[$key].Add("$($group.Name): $($group.MatchBasis)")
        }
    }
    foreach ($row in $Inventory) {
        $key = Get-InterfaceGroupKey $row
        $labels = @()
        if ($membership.ContainsKey($key)) { $labels = @($membership[$key]) }
        [pscustomobject][ordered]@{
            InterfaceKey = $key; DeviceName = $row.DeviceName
            InterfaceComment = $row.InterfaceComment; InterfaceName = $row.InterfaceName
            IfAlias = $row.IfAlias; IfName = $row.IfName; IfDescr = $row.IfDescr
            ProposedGroups = $labels -join ';'; Groups = $labels -join ';'
            MatchExplanation = $(if ($reasons.ContainsKey($key)) { $reasons[$key] -join ' | ' } else { 'No selected grouping rule matched this interface.' })
            Exclude = 'False'; Apply = 'False'
        }
    }
}

function Set-InterfaceGroupReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions
    )
    $rows = @{}
    foreach ($row in $Inventory) { $rows[(Get-InterfaceGroupKey $row)] = $row }
    $overrides = @{}
    $seen = @{}
    foreach ($decision in $Decisions) {
        foreach ($column in @('InterfaceKey', 'InterfaceComment', 'InterfaceName', 'Groups', 'Exclude', 'Apply')) {
            if (-not $decision.PSObject.Properties[$column]) { throw "Review CSV is missing column '$column'." }
        }
        $key = [string]$decision.InterfaceKey
        if ($seen.ContainsKey($key)) { throw "Duplicate review interface key: $key" }
        $seen[$key] = $true
        foreach ($flag in @('Apply', 'Exclude')) {
            if ([string]$decision.$flag -notmatch '^(True|False)$') { throw "$flag must be True or False for $key." }
        }
        if ([string]$decision.Apply -ine 'True') { continue }
        if (-not $rows.ContainsKey($key)) { Write-Warning "Pinned interface $key is absent from this inventory."; continue }
        $row = $rows[$key]
        if ([string]$row.InterfaceComment -cne [string]$decision.InterfaceComment -or
            [string]$row.InterfaceName -cne [string]$decision.InterfaceName) {
            throw "Pinned interface $key has changed descriptions. Regenerate and review its decision before continuing."
        }
        foreach ($field in @('IfAlias', 'IfName', 'IfDescr')) {
            if ($decision.PSObject.Properties[$field] -and [string]$decision.$field -cne [string]$row.$field) {
                if ($row.SnmpStatus -in @('Failed', 'Partial', 'NotFound') -and $null -eq $row.$field) {
                    Write-Warning "Pinned interface ${key}: cannot validate unavailable SNMP $field; retaining its explicit decision. Review SNMP coverage."
                    continue
                }
                throw "Pinned interface $key has changed SNMP metadata ($field). Regenerate and review its decision."
            }
        }
        $labels = @()
        if ([string]$decision.Exclude -ine 'True') {
            $labels = @(([string]$decision.Groups -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
            if ($labels.Count -eq 0) { throw "Applied interface $key needs a group name or Exclude=True." }
        }
        $overrides[$key] = $labels
    }
    $buckets = [ordered]@{}
    $keepEmpty = @{}
    foreach ($group in $Groups) {
        if ([string]$group.Name -match ';' -or [string]::IsNullOrWhiteSpace([string]$group.Name)) {
            throw 'Group names must be nonblank and cannot contain semicolons when using review.'
        }
        $buckets[$group.Name] = [System.Collections.Generic.List[object]]::new()
        if (@($group.Interfaces).Count -eq 0 -or $group.Name -eq 'Other Interfaces') { $keepEmpty[$group.Name] = $true }
        foreach ($row in @($group.Interfaces)) {
            if (-not $overrides.ContainsKey((Get-InterfaceGroupKey $row))) { $buckets[$group.Name].Add($row) }
        }
    }
    foreach ($key in @($overrides.Keys | Sort-Object)) {
        foreach ($label in $overrides[$key]) {
            if (-not $buckets.Contains($label)) { $buckets[$label] = [System.Collections.Generic.List[object]]::new() }
            $buckets[$label].Add($rows[$key])
        }
    }
    foreach ($name in $buckets.Keys) {
        if ($buckets[$name].Count -eq 0 -and -not $keepEmpty.ContainsKey([string]$name)) { continue }
        [pscustomobject]@{ Name = $name; Interfaces = @($buckets[$name]); InterfaceCount = $buckets[$name].Count
            MatchBasis = 'Automatic matching with explicit per-interface review overrides (where Apply=True).' }
    }
}

function Invoke-InterfaceGroupReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions)
    foreach ($decision in $Decisions) {
        $description = @($decision.IfAlias, $decision.InterfaceComment, $decision.IfName, $decision.InterfaceName, $decision.IfDescr) | Where-Object { $_ } | Select-Object -First 1
        $answer = Read-Host "$($decision.DeviceName) / $description / $($decision.InterfaceKey) [$($decision.Groups)] -- Enter keeps, - excludes, or enter group names separated by ;"
        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        $decision.Apply = 'True'
        $decision.Exclude = 'False'
        if ($answer.Trim() -eq '-') { $decision.Exclude = 'True'; $decision.Groups = '' }
        else { $decision.Groups = $answer.Trim() }
    }
    if ((Read-Host 'Apply these decisions and continue? Type YES') -cne 'YES') { throw 'Grouping review cancelled; no report or WUG writes performed.' }
    $Decisions
}

function Export-InterfaceGroupReview {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions, [Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Write editable interface grouping review CSV')) {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $null = New-Item -ItemType Directory -Path (Split-Path $fullPath -Parent) -Force -ErrorAction Stop
        if ($Decisions.Count -eq 0) {
            [IO.File]::WriteAllText($fullPath, '"InterfaceKey","DeviceName","InterfaceComment","InterfaceName","IfAlias","IfName","IfDescr","ProposedGroups","Groups","MatchExplanation","Exclude","Apply"' + "`r`n", [Text.UTF8Encoding]::new($true))
        }

        else {
            $csv = $Decisions | ConvertTo-Csv -NoTypeInformation
            [IO.File]::WriteAllLines($fullPath, [string[]]$csv, [Text.UTF8Encoding]::new($true))
        }
        return $fullPath
    }
}

function Update-InterfaceGroupSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$ReviewPath, [string]$PreviewPath, [switch]$Review, [switch]$PreviewOnly
    )
    $proposals = @{}
    foreach ($row in @(New-InterfaceGroupReview -Inventory $Inventory -Groups $Groups)) { $proposals[$row.InterfaceKey] = $row.ProposedGroups }
    if ($ReviewPath) {
        $decisions = @(Import-Csv -LiteralPath $ReviewPath -ErrorAction Stop)
        $Groups = @(Set-InterfaceGroupReview -Inventory $Inventory -Groups $Groups -Decisions $decisions)
    }
    $preview = @(New-InterfaceGroupReview -Inventory $Inventory -Groups $Groups)
    foreach ($row in $preview) { $row.ProposedGroups = $proposals[$row.InterfaceKey] }
    if ($ReviewPath) {
        foreach ($row in $preview) {
            $prior = @($decisions | Where-Object { $_.InterfaceKey -eq $row.InterfaceKey -and $_.Apply -ieq 'True' })
            if ($prior.Count) { $row.Apply = 'True'; $row.Exclude = $prior[0].Exclude; $row.Groups = $prior[0].Groups }
        }
    }
    if ($Review) {
        if ($WhatIfPreference) { throw '-Review is interactive; use -PreviewOnly with -WhatIf instead.' }
        $preview = @(Invoke-InterfaceGroupReview -Decisions $preview)
        $Groups = @(Set-InterfaceGroupReview -Inventory $Inventory -Groups $Groups -Decisions $preview)
    }
    $written = $null
    if ($PreviewOnly -or $Review -or $PreviewPath) {
        if (-not $PreviewPath) { $PreviewPath = Join-Path $OutputDirectory 'review-preview.csv' }
        if ($ReviewPath -and [IO.Path]::GetFullPath($PreviewPath) -eq [IO.Path]::GetFullPath($ReviewPath)) {
            throw 'PreviewPath must differ from ReviewPath; never overwrite the applied decisions automatically.'
        }
        $written = Export-InterfaceGroupReview -Decisions $preview -Path $PreviewPath
    }
    [pscustomobject]@{ Groups = $Groups; Decisions = $preview; PreviewPath = $written }
}

function Read-InterfaceGroupProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $profile = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($profile.SchemaVersion -ne 1 -or -not $profile.Settings) { throw 'Expected interface profile SchemaVersion=1 and Settings object.' }
    $allowed = @('DeviceId', 'AllDevices', 'GroupId', 'ReturnHierarchy', 'Mode', 'Strategy', 'GroupName',
        'MatchMode', 'CreateWugGroups', 'OutputDirectory', 'FolderName', 'PublishToWug', 'NmConsolePath',
        'PackName', 'Range', 'RangeN', 'ReviewPath', 'StaleAfterMinutes', 'UseSnmp', 'SnmpCredentialNames',
        'SnmpCredentialVersions', 'IncludeSnmpOnly', 'SnmpFailureAction', 'SnmpPort', 'SnmpTimeout', 'ApiMaxRetries', 'CancellationPath',
        'DeviceFilter','Rules','RuleMode')
    $settings = @{}
    foreach ($property in $profile.Settings.PSObject.Properties) {
        if ($allowed -notcontains $property.Name) { throw "Unsupported profile setting '$($property.Name)'. Credentials and interactive options do not belong in profiles." }
        $settings[$property.Name] = $property.Value
    }
    foreach ($flag in @('AllDevices', 'ReturnHierarchy', 'CreateWugGroups', 'PublishToWug', 'UseSnmp', 'IncludeSnmpOnly')) {
        if ($settings.ContainsKey($flag) -and $settings[$flag] -isnot [bool]) { throw "$flag must be a JSON boolean." }
    }
    $scopes = @(@('DeviceId', 'GroupId', 'AllDevices') | Where-Object { $settings.ContainsKey($_) })
    if ($scopes.Count -ne 1 -or ($settings.ContainsKey('AllDevices') -and -not $settings.AllDevices)) { throw 'Profile must select exactly one device scope.' }
    $metadata = Get-Command (Join-Path $PSScriptRoot 'Example-InterfaceGrouping.ps1') -ErrorAction Stop
    foreach ($key in @($settings.Keys)) {
        $parameter = $metadata.Parameters[$key]
        $value = $settings[$key]
        if ($parameter.ParameterType -ne [Management.Automation.SwitchParameter]) {
            $value = [Management.Automation.LanguagePrimitives]::ConvertTo($value, $parameter.ParameterType)
        }
        foreach ($attribute in $parameter.Attributes) {
            if ($attribute -is [Management.Automation.ValidateSetAttribute]) {
                foreach ($item in @($value)) {
                    if ($attribute.ValidValues -notcontains $item) { throw "Invalid $key value: $item" }
                }
            }
            if ($attribute -is [Management.Automation.ValidateRangeAttribute] -and ($value -lt $attribute.MinRange -or $value -gt $attribute.MaxRange)) { throw "Out-of-range $key value: $value" }
            if ($attribute -is [Management.Automation.ValidatePatternAttribute] -and [string]$value -notmatch $attribute.RegexPattern) { throw "Invalid $key format." }
        }
        $settings[$key] = $value
    }
    foreach ($pathKey in @('OutputDirectory', 'ReviewPath', 'NmConsolePath', 'CancellationPath')) {
        if ($settings.ContainsKey($pathKey)) {
            if ([string]::IsNullOrWhiteSpace([string]$settings[$pathKey])) { throw "$pathKey cannot be blank." }
            if (-not [IO.Path]::IsPathRooted($settings[$pathKey])) {
                $settings[$pathKey] = [IO.Path]::GetFullPath((Join-Path (Split-Path ([IO.Path]::GetFullPath($Path)) -Parent) $settings[$pathKey]))
            }
        }
    }
    if ($settings.ContainsKey('DeviceId') -and @($settings.DeviceId | Where-Object { $_ -le 0 }).Count) { throw 'Profile device IDs must be positive.' }
    if ($settings.ContainsKey('GroupId') -and @($settings.GroupId | Where-Object { $_ -lt 0 -and $_ -ne -2 }).Count) { throw 'Profile group IDs must be nonnegative or -2.' }
    foreach ($ids in @('DeviceId', 'GroupId', 'GroupName')) {
        if ($settings.ContainsKey($ids) -and @($settings[$ids]).Count -eq 0) { throw "$ids cannot be empty." }
    }
    if ($settings.ContainsKey('GroupName') -and @($settings.GroupName | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw 'Group names cannot be blank.' }
    if ($settings.UseSnmp) {
        if (@($settings.SnmpCredentialNames).Count -lt 1 -or @($settings.SnmpCredentialNames).Count -gt 12 -or
            @($settings.SnmpCredentialNames).Count -ne @($settings.SnmpCredentialVersions).Count -or
            @($settings.SnmpCredentialNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'UseSnmp requires 1-12 aligned nonblank SnmpCredentialNames and SnmpCredentialVersions.'
        }
        $selected = @{}
        for ($index = 0; $index -lt $settings.SnmpCredentialNames.Count; $index++) {
            if ($settings.SnmpCredentialNames[$index] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Selected SNMP vault names must be simple names, not paths.' }
            $identity = "$($settings.SnmpCredentialNames[$index])/$($settings.SnmpCredentialVersions[$index])"
            if ($selected.ContainsKey($identity)) { throw "Duplicate SNMP credential/version in profile: $identity" }
            $selected[$identity] = $true
        }
    }
    elseif (@($settings.Keys | Where-Object { $_ -like 'Snmp*' -or $_ -eq 'IncludeSnmpOnly' }).Count -gt 0) { throw 'SNMP options require UseSnmp=True.' }
    $mode = 'NamedGroups'
    if ($settings.ContainsKey('Mode')) { $mode = $settings.Mode }
    if ($settings.ContainsKey('Strategy') -and $mode -ne 'IntelligentGroups') { throw 'Strategy requires IntelligentGroups.' }
    if ($settings.ContainsKey('GroupName') -and $mode -ne 'NamedGroups') { throw 'GroupName requires NamedGroups.' }
    if ($mode -eq 'Rules') {Test-InterfaceGroupRules -Rules $settings.Rules}
    elseif ($settings.ContainsKey('Rules') -or $settings.ContainsKey('RuleMode')) {throw 'Rules and RuleMode require Mode=Rules.'}
    if ($settings.ContainsKey('ReturnHierarchy') -and -not $settings.ContainsKey('GroupId')) { throw 'ReturnHierarchy requires GroupId.' }
    if (($settings.ContainsKey('PackName') -or $settings.ContainsKey('NmConsolePath')) -and -not $settings.PublishToWug) { throw 'Publishing settings require PublishToWug=True.' }
    $settings
}

function Save-InterfaceGroupProfile {
    <#
    .SYNOPSIS
        Saves reusable, credential-free interface grouping settings as JSON.
    .PARAMETER Path
        Profile JSON destination; relative settings paths resolve beside this file.
    .PARAMETER Settings
        Example-InterfaceGrouping parameters, excluding interactive and common parameters.
    .EXAMPLE
        Save-InterfaceGroupProfile -Path C:\ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\all.json -Settings @{ AllDevices=$true; Mode='AllInterfaces' }
    .NOTES
        Profiles are configuration, not credential storage. Review write permissions.
    .LINK
        README.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Settings)
    if ($PSCmdlet.ShouldProcess($Path, 'Save interface grouping profile')) {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $null = New-Item -ItemType Directory -Path (Split-Path $fullPath -Parent) -Force -ErrorAction Stop
        $json = [pscustomobject]@{ SchemaVersion = 1; Settings = $Settings } | ConvertTo-Json -Depth 6
        $temporary = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($true))
            $null = Read-InterfaceGroupProfile -Path $temporary
            Move-Item -LiteralPath $temporary -Destination $fullPath -Force -ErrorAction Stop
        }
        finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } }
        $fullPath
    }
}

function New-InterfaceGroupCollectionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Scope,
        [string]$Mode='NamedGroups',[string]$Strategy='Prefix',[string[]]$GroupName,
        [string]$MatchMode='Token',[string]$Range='lastPolled',[int]$RangeN=4,
        [bool]$UseSnmp=$false,[bool]$IncludeSnmpOnly=$false,
        [string[]]$SnmpCredentialNames,[string[]]$SnmpCredentialVersions,
        [AllowEmptyCollection()][object[]]$Decisions
    )
    $context=@{Mode=$Mode;MatchMode=$MatchMode;Range=$Range;RangeN=$RangeN;UseSnmp=$UseSnmp;IncludeSnmpOnly=$IncludeSnmpOnly}
    foreach ($key in @('DeviceId','GroupId','AllDevices','ReturnHierarchy')) { if ($Scope.ContainsKey($key)) { $context[$key]=$Scope[$key] } }
    if ($Mode -eq 'NamedGroups') { $context.GroupName=@($GroupName) }
    if ($Mode -eq 'IntelligentGroups') { $context.Strategy=$Strategy }
    if ($UseSnmp) {
        $context.SnmpCandidates=@(for ($index=0;$index -lt $SnmpCredentialNames.Count;$index++) { "$($SnmpCredentialNames[$index])/$($SnmpCredentialVersions[$index])/priority=$index" })
    }
    $rows=@(foreach ($row in @($Decisions | Where-Object Apply -eq True | Sort-Object InterfaceKey)) {
        [pscustomobject][ordered]@{
            InterfaceKey=$row.InterfaceKey
            Groups=(@(([string]$row.Groups -split ';') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique) -join ';')
            Exclude=([string]$row.Exclude).ToLowerInvariant()
            InterfaceComment=$row.InterfaceComment;InterfaceName=$row.InterfaceName;IfAlias=$row.IfAlias;IfName=$row.IfName;IfDescr=$row.IfDescr
        }
    })
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { $context.ReviewFingerprint=([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $rows -Depth 5 -Compress))))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    $context
}

function New-InterfaceGroupSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [hashtable]$SnmpCoverage, [hashtable]$CollectionContext, $Previous
    )
    $review = @(New-InterfaceGroupReview -Inventory $Inventory -Groups $Groups)
    $states = @{}
    foreach ($row in $Inventory) {
        $key=Get-InterfaceGroupKey $row
        if ($states.ContainsKey($key)) { throw "Duplicate interface identity in snapshot: $key" }
        $states[$key] = $row
    }

    $context=[ordered]@{}
    foreach ($key in @($CollectionContext.Keys | Sort-Object)) {
        $value=$CollectionContext[$key]
        if ($value -is [array]) { $value=@($value | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique) }
        $context[$key]=$value
    }
    $fingerprint=$null
    if ($context.Count) {
        $algorithm=[Security.Cryptography.SHA256]::Create()
        try { $fingerprint=([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $context -Depth 6 -Compress))))).Replace('-','').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }
    $snapshot=[pscustomobject]@{
        SchemaVersion = 2; Server = $(if ($CollectionContext -and $CollectionContext.Server) {[string]$CollectionContext.Server} else {[string]$global:WhatsUpServerBaseURI})
        CollectionContext=[pscustomobject]$context;ContextFingerprint=$fingerprint
        SnmpCoverage = $SnmpCoverage
        GeneratedUtc = [DateTime]::UtcNow.ToString('o')
        Interfaces = @(
            foreach ($row in $review) {
                [pscustomobject]@{
                    InterfaceKey = $row.InterfaceKey; DeviceName = $row.DeviceName
                    InterfaceComment = $row.InterfaceComment; InterfaceName = $row.InterfaceName
                    IfAlias = $row.IfAlias; IfName = $row.IfName; IfDescr = $row.IfDescr; Groups = $row.Groups
                    SnmpStatus = $states[$row.InterfaceKey].SnmpStatus
                    InventorySource = $states[$row.InterfaceKey].InventorySource
                }
            }
        )
        LastKnownInterfaces=@()
    }
    $known=@{}
    if ($Previous -and [string]$Previous.Server -ieq $snapshot.Server -and
        [string]$Previous.ContextFingerprint -ceq [string]$snapshot.ContextFingerprint) {
        $oldRows=@($Previous.Interfaces)
        if ($Previous.PSObject.Properties['LastKnownInterfaces']) { $oldRows=@($Previous.LastKnownInterfaces) }
        foreach ($row in $oldRows) { $known[$row.InterfaceKey]=$row }
    }
    $next=[System.Collections.Generic.List[object]]::new()
    $observed=@{}
    foreach ($row in $snapshot.Interfaces) {
        $observed[$row.InterfaceKey]=$true
        $copy=$row.PSObject.Copy()
        if ($row.SnmpStatus -in @('Failed','Partial','NotFound') -and $known.ContainsKey($row.InterfaceKey)) {
            $missingMetadata=$false
            foreach ($field in @('IfAlias','IfName','IfDescr')) {
                if ($null -eq $row.$field) {
                    $copy.$field=$known[$row.InterfaceKey].$field
                    if ($null -ne $copy.$field) { $missingMetadata=$true }
                }
            }
            if ($missingMetadata -and [string]$row.InterfaceComment -ceq [string]$known[$row.InterfaceKey].InterfaceComment -and
                [string]$row.InterfaceName -ceq [string]$known[$row.InterfaceKey].InterfaceName) {
                $copy.Groups=$known[$row.InterfaceKey].Groups
            }
        }
        $next.Add($copy)
    }
    foreach ($key in @($known.Keys | Sort-Object)) {
        if ($observed.ContainsKey($key)) { continue }
        $device=($key -split ':')[0]
        $coverage=$null
        if ($SnmpCoverage -and $SnmpCoverage.ContainsKey($device)) { $coverage=$SnmpCoverage[$device] }
        if ($known[$key].SnmpStatus -and ($coverage -in @('Failed','Partial') -or -not $coverage)) { $next.Add($known[$key]) }
    }
    $snapshot.LastKnownInterfaces=@($next)
    $snapshot
}

function Compare-InterfaceGroupSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Current, $Previous)
    if ($null -eq $Previous) { return }
    if ($Previous.SchemaVersion -notin @(1,2) -or -not $Previous.PSObject.Properties['Interfaces']) { throw 'Invalid prior interface snapshot; review the file before replacing it.' }
    if ([string]$Previous.Server -ine [string]$Current.Server) {
        Write-Warning 'WUG server changed for this output directory. Starting a new grouping-change baseline.'
        return
    }
    $before = @{}; $after = @{}; $uncertainDevices = @{}
    $configurationChanged=$Previous.SchemaVersion -eq 2 -and
        [string]$Previous.ContextFingerprint -cne [string]$Current.ContextFingerprint
    if ($configurationChanged) {
        [pscustomobject][ordered]@{
            InterfaceKey='configuration';DeviceName='Selected scope';Change='ConfigurationChanged';UncertainSnmpCoverage=$false
            PreviousGroups='';CurrentGroups='';PreviousDescription=(ConvertTo-Json -InputObject $Previous.CollectionContext -Compress -Depth 6)
            CurrentDescription=(ConvertTo-Json -InputObject $Current.CollectionContext -Compress -Depth 6)
            Classification='ConfigurationChange'
        }
    }
    $prior=@($Previous.Interfaces)
    if (-not $configurationChanged -and $Previous.PSObject.Properties['LastKnownInterfaces']) { $prior=@($Previous.LastKnownInterfaces) }
    foreach ($row in $prior) {
        if ($before.ContainsKey($row.InterfaceKey)) { throw "Duplicate prior snapshot identity: $($row.InterfaceKey)" }
        $before[$row.InterfaceKey] = $row
    }
    foreach ($row in @($Current.Interfaces)) {
        if ($after.ContainsKey($row.InterfaceKey)) { throw "Duplicate current snapshot identity: $($row.InterfaceKey)" }
        $after[$row.InterfaceKey] = $row
        if ($row.SnmpStatus -in @('Failed', 'Partial')) { $uncertainDevices[([string]$row.InterfaceKey -split ':')[0]] = $true }
    }
    if ($Current.SnmpCoverage) {
        foreach ($property in ([pscustomobject]$Current.SnmpCoverage).PSObject.Properties) {
            if ($property.Value -in @('Failed', 'Partial')) { $uncertainDevices[$property.Name] = $true }
        }
    }
    foreach ($row in @($Previous.Interfaces | Where-Object { $_.SnmpStatus })) {
        $device = ([string]$row.InterfaceKey -split ':')[0]
        if (-not $Current.SnmpCoverage -or -not ([pscustomobject]$Current.SnmpCoverage).PSObject.Properties[$device]) {
            if (-not @($Current.Interfaces | Where-Object { ([string]$_.InterfaceKey -split ':')[0] -eq $device -and $_.SnmpStatus }).Count) {
                $uncertainDevices[$device] = $true
            }
        }
    }
    foreach ($key in @(@($before.Keys) + @($after.Keys) | Sort-Object -Unique)) {
        $old = $before[$key]; $new = $after[$key]
        $uncertain = $uncertainDevices.ContainsKey(($key -split ':')[0])
        if (-not $new -and $old.SnmpStatus -and -not $configurationChanged -and
            (-not $Current.SnmpCoverage -or -not ([pscustomobject]$Current.SnmpCoverage).PSObject.Properties[($key -split ':')[0]])) { $uncertain=$true }
        $types = [System.Collections.Generic.List[string]]::new()
        if (-not $old) { $types.Add('Added') }
        elseif (-not $new) { $types.Add('Removed') }
        else {
            foreach ($field in @('InterfaceComment', 'InterfaceName', 'IfAlias', 'IfName', 'IfDescr')) {
                if ($field -like 'If*' -and $new.SnmpStatus -in @('Failed','Partial','NotFound') -and $null -eq $new.$field) { continue }
                if ([string]$old.$field -cne [string]$new.$field) { $types.Add('DescriptionsChanged'); break }
            }
            $oldGroups = @(([string]$old.Groups -split ';') | Where-Object { $_ } | Sort-Object -Unique) -join ';'
            $newGroups = @(([string]$new.Groups -split ';') | Where-Object { $_ } | Sort-Object -Unique) -join ';'
            if ($oldGroups -cne $newGroups) { $types.Add('MembershipChanged') }
        }
        if ($types.Count) {
            [pscustomobject][ordered]@{
                InterfaceKey = $key; DeviceName = $(if ($new) { $new.DeviceName } else { $old.DeviceName })
                Change = $types -join ';'; UncertainSnmpCoverage = $uncertain
                PreviousGroups = $old.Groups; CurrentGroups = $new.Groups
                PreviousDescription = @($old.InterfaceComment, $old.InterfaceName, $old.IfAlias, $old.IfName, $old.IfDescr) -join ' | '
                CurrentDescription = @($new.InterfaceComment, $new.InterfaceName, $new.IfAlias, $new.IfName, $new.IfDescr) -join ' | '
                Classification = $(if ($configurationChanged) {'ConfigurationChange'} elseif ($uncertain) {'UncertainObservation'} else {'InventoryChange'})
            }
        }
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAAT/hE32IwMVw2
# QJPzWxq9kn1qIVCIlrGuj+K497cdtqCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCJ
# Rd+8ayT4rWKG9bUfNn0NKWrJ/1Uh+Lsd2CMp/upsCjANBgkqhkiG9w0BAQEFAASC
# AgAqXbbxdZmMkzUwJQa1cHzqvaG1Mo408I8FGzKcQgt8hr8unxKnA24ZgtfuSAmd
# j4we1j3Fv1i3n8ITLImSWmX7xnmiI53bMhQSgjvetQxKGCdj42Yf0cGgWB9ivfvf
# UJwwrJq5sZDzSdi+pxHBLetxNhywg07+hrdewTuqyhhRkypZq7E3gxTfPIDlZnHR
# fBXgjZcuWAgu1jYKrQRnb2DYYomLaKo4U4vb7LembkbHNuDhH87wqLEgWg0swR7t
# YfjJ62bsglXPg2CcfAGlBLyrCrPtlgKCELdLCGMd1UFVLZ0QtDopWpl6wLs1K9MN
# Pb8Qd+j+ItQdRVFLqcI6ZHeaj9Pe72Bjl910wKQoedsoRzQbhblXL9upD7JH5FsL
# zHdzphy0zt3U6ZpARcU3GDTwiFWdnbQE2lDGUofVC/30KGjRINjT7xhAAFEI4VxC
# aL0CYv5Cxd9ooAlApHizE424bPcWXouLboTY7gpWljBpoIoSv/1Lf1yVwpRMWapS
# yH0cm6TIfQOjsouyshEq9oNN/xfc/cMuwVbTnvjS8f+9/8oN8K9XBaeCgZ+YgOIe
# La0OheuBzFX1SvXg52Ua89K32IERj40soMDIKUoTB5wjkZn7zBtwzow0FvWRVZQ3
# auwEBRCuibdemkTE/1wmkK8aPMYGwMvifrJb2b5eFsGBc6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzMzJaMC8GCSqGSIb3DQEJBDEiBCDW1Dqbq6pW
# k1iHNBNFcRkU6wid3c1pRrUXIU3G+mwRqTANBgkqhkiG9w0BAQEFAASCAgCexcOu
# SkrkCMlguHKY7TL1eRvpx7Kl7byh4cwZsuMLR/RNcwip1ZQH9Lshv4qTLidxdorE
# CzC3BtrTEHib+mmZbDFId9gfTwM4D6fcqpk8yhgfGr3aIHjhxy3hyehLL5fJCa3c
# hJfpnxnnp9uMRNrtbAE0VChPrBuJ0ng8AB4/50rNV0V1scg5FF0ye4SSEbLczEHX
# fm859Q8HvOD65OXXyl814Z+EdhjWDOixdelUSemt4vrDOfxu0pNei4jUvcEyyuB8
# pjMVrnDRKPL7SMqwLGwsKDkx2wlUMUnGs2hKggS+ABWBIKe8cAcqNhbPzqhXhmLA
# 3+Li5gDCCGx8URfgRj0nr6oEapj3HZjHAGmDWbw5HrktkVdZDenmJIBUVhpneC5E
# ikrgGyTXbqKAqiuB+/uE9SS3JxaHWZim8rT2OiPRzA1rVcI5Kckq1V+ma3P18BvA
# ITcNE1czydOGDdABVpaqOZzdgQSoxcHKJWtSBi/z5MJtv0mqrd+pLVkg0sJ6wjWF
# 8lSwHkeFgoNw5/Yn64UGUqbUpm5/vxB7xLegItNSNPpR0X7voDOduvaOwkJGIfCd
# WNPU9hZW+gsysBvpcLDcUFnTZngIqIdgQtE+rPJ3MY/Pn0mRDytebCIjvf4SanJQ
# 5KvDRe0fF2lrZXPf1iC2f4N5DYHN53BJqU5PwA==
# SIG # End signature block
