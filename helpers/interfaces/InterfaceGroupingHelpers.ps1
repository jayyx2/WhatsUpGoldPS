#requires -Version 5.1
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$functionDir = Join-Path $scriptDir '..\..\functions'
foreach ($dependency in @('Get-WUGAPIResponse', 'Get-WUGDevice', 'Get-WUGDeviceReport', 'Get-WUGDeviceCredential',
        'Get-WUGDeviceGroup', 'Add-WUGDeviceGroup', 'Add-WUGDeviceGroupMember')) {
    . (Join-Path $functionDir "$dependency.ps1")
}
. (Join-Path $scriptDir '..\reports\Export-DynamicDashboardHtml.ps1')
. (Join-Path $scriptDir 'InterfaceGroupWorkflowHelpers.ps1')
. (Join-Path $scriptDir 'InterfaceGroupPolicyHelpers.ps1')
. (Join-Path $scriptDir 'InterfaceGroupLocalExport.ps1')
. (Join-Path $scriptDir 'InterfaceGroupBrowserReview.ps1')
. (Join-Path $functionDir 'Connect-WUGServer.ps1')
. (Join-Path $scriptDir '..\reports\DashboardPublishingHelpers.ps1')
. (Join-Path $scriptDir 'InterfaceDashboardAssets.ps1')

function Connect-InterfaceGroupServer {
    <#
    .SYNOPSIS
        Reuses an existing WUG session or connects using the saved vault connection.
    .DESCRIPTION
        Uses Connect-WUGServer -AutoConnect without prompting. A missing vault or
        unsuccessful connection terminates. Credentials are never supplied here.
    .EXAMPLE
        Connect-InterfaceGroupServer
    .NOTES
        Uses the existing Connect-WUGServer vault and SSL behavior.
    .LINK
        ..\..\docs\interface-grouping.md
    #>
    [CmdletBinding()]
    param()
    if ($global:WhatsUpServerBaseURI -and $global:WUGBearerHeaders) { return }
    Connect-WUGServer -AutoConnect -ErrorAction Stop | Out-Null
    if (-not $global:WhatsUpServerBaseURI -or -not $global:WUGBearerHeaders) {
        throw 'WUG connection did not establish a usable API session.'
    }
}

function Resolve-InterfaceGroupDevice {
    <#
    .SYNOPSIS
        Resolves explicit devices, existing WUG groups, or all accessible devices.
    .PARAMETER DeviceId
        Explicit WUG device IDs.
    .PARAMETER GroupId
        Existing source device groups, unrelated to output navigation groups.
    .PARAMETER AllDevices
        Select all accessible devices.
    .PARAMETER ReturnHierarchy
        Include child groups for GroupId scope.
    .PARAMETER ApiMaxRetries
        Existing API wrapper's bounded transient retry count, 0-10 (default 3).
    .PARAMETER CancellationPath
        Optional signal file; presence cancels before the next scope query.
    .EXAMPLE
        Resolve-InterfaceGroupDevice -GroupId 41 -ReturnHierarchy
    .NOTES
        Deduplicates overlapping scopes. Empty or invalid scopes terminate.
    .LINK
        ..\..\docs\interface-grouping.md
    #>
    [CmdletBinding(DefaultParameterSetName = 'Device')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Device')]
        [ValidateNotNullOrEmpty()][int[]]$DeviceId,
        [Parameter(Mandatory, ParameterSetName = 'Group')]
        [ValidateNotNullOrEmpty()][int[]]$GroupId,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$AllDevices,
        [Parameter(ParameterSetName = 'Group')][switch]$ReturnHierarchy,
        [ValidateRange(0,10)][int]$ApiMaxRetries = 3,
        [string]$CancellationPath
    )
    if ($null -eq $PSDefaultParameterValues) {$PSDefaultParameterValues=@{}}
    else {$PSDefaultParameterValues = $PSDefaultParameterValues.Clone()}
    $PSDefaultParameterValues['Get-WUGAPIResponse:MaxRetries'] = $ApiMaxRetries
    Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
    $ids = @()
    if ($PSCmdlet.ParameterSetName -eq 'Device') {
        $ids = @($DeviceId)
    }
    else {
        $sourceGroups = @($GroupId)
        if ($PSCmdlet.ParameterSetName -eq 'All') {
            if (-not $AllDevices) { throw '-AllDevices must be enabled.' }
            $sourceGroups = @(-2)
        }
        foreach ($id in @($sourceGroups | Select-Object -Unique)) {
            Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
            if ($id -lt 0 -and $id -ne -2) { throw "Invalid source GroupId: $id" }
            $hierarchy = 'false'
            if ($ReturnHierarchy -or $PSCmdlet.ParameterSetName -eq 'All') { $hierarchy = 'true' }
            $devices = @(Get-WUGDevice -DeviceGroupID ([string]$id) -ReturnHierarchy $hierarchy `
                -View id -Limit 250 -ErrorAction Stop)
            $ids += @($devices | ForEach-Object { [int]$_.id })
        }
    }
    if ($ids.Count -eq 0) { throw 'No accessible WUG devices were returned for the requested scope.' }
    foreach ($id in @($ids | Select-Object -Unique)) {
        if ($id -lt 1) { throw "Invalid DeviceId: $id" }
        $id
    }
}

function ConvertTo-InterfaceGroupInventory {
    <#
    .SYNOPSIS
        Joins WUG interface assignments and traffic without confusing WUG IDs with ifIndex.
    .DESCRIPTION
        Uses the built-in Interface monitor's numeric argument and the trailing
        (ifIndex) in WUG traffic descriptions. Library descriptions are not aliases.
        Missing or disabled monitors never imply an Up state.
    .PARAMETER DeviceId
        WUG device identifier.
    .PARAMETER DeviceName
        Display name for the device.
    .PARAMETER Monitors
        AssignedMonitor objects from the status view.
    .PARAMETER Traffic
        InterfaceTraffic report objects, including historical series.
    .EXAMPLE
        ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router -Monitors $m -Traffic $t
    .NOTES
        Internal standalone helper; no module exports.
    .LINK
        https://docs.ipswitch.com/NM/WhatsUpGold2026/02_Guides/rest_api/index.html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$DeviceId,
        [Parameter(Mandatory)][string]$DeviceName,
        [AllowEmptyCollection()][object[]]$Monitors = @(),
        [AllowEmptyCollection()][object[]]$Traffic = @()
    )
    $interfaces = [ordered]@{}
    $performance = @($Monitors | Where-Object {
        $_.type -eq 'performance' -and $_.monitorTypeClassId -eq '3d199773-46ef-4cbb-b992-7076612c7668'
    })
    foreach ($monitor in @($Monitors | Where-Object {
        $_.type -eq 'active' -and $_.monitorTypeClassId -eq 'd6d02d69-a418-483a-93ea-20dd2af2d135'
    })) {
        $index = [string]$monitor.active.argument
        if ($index -notmatch '^[1-9][0-9]*$') {
            Write-Warning "Device ${DeviceId}: interface assignment $($monitor.id) has no usable ifIndex; excluded."
            continue
        }
        if (-not $interfaces.Contains($index)) {
            $interfaces[$index] = @{ Index = $index; Active = @(); Traffic = @() }
        }
        $interfaces[$index].Active += $monitor
    }
    foreach ($report in $Traffic) {
        if ([string]::IsNullOrWhiteSpace([string]$report.interfaceId)) {
            throw "Device ${DeviceId}: traffic row is missing its WUG interfaceId."
        }
        $index = ''
        if ([string]$report.interfaceName -match '\(([1-9][0-9]*)\)\s*$') {
            $index = $Matches[1]
            $key = $index
        }
        else {
            $key = "report:$($report.interfaceId)"
            Write-Warning "Device ${DeviceId}: '$($report.interfaceName)' has no trailing ifIndex; status cannot be joined."
        }
        if (-not $interfaces.Contains($key)) {
            $interfaces[$key] = @{ Index = $index; Active = @(); Traffic = @() }
        }
        $interfaces[$key].Traffic += $report
    }
    foreach ($key in $interfaces.Keys) {
        $item = $interfaces[$key]
        $enabled = @($item.Active | Where-Object { $_.enabled -eq $true })
        $states = @($enabled | ForEach-Object {
            if ([string]$_.status -match '^(Up|Down|Maintenance|Unknown)(?:\s|$)') { $Matches[1] }
            else { 'Unknown' }
        })
        $state = 'Unknown'
        if ($item.Active.Count -gt 0 -and $enabled.Count -eq 0) { $state = 'Disabled' }
        else {
            foreach ($candidate in @('Down', 'Maintenance', 'Unknown', 'Up')) {
                if ($states -contains $candidate) { $state = $candidate; break }
            }
        }
        $latest = $item.Traffic | Sort-Object pollTimeUtc -Descending | Select-Object -First 1
        $comments = @($item.Active | ForEach-Object { $_.active.comment } | Where-Object { $_ } | Select-Object -Unique)
        $names = @($item.Traffic | ForEach-Object { $_.interfaceName } | Where-Object { $_ } | Select-Object -Unique)
        $samples = @(
            foreach ($report in $item.Traffic) {
                $points = @($report.series | Where-Object { $null -ne $_ })
                if ($points.Count -eq 0) { $points = @($report) }
                foreach ($point in $points) {
                    [pscustomobject]@{
                        PollTimeUtc = $point.pollTimeUtc
                        RxBps = $point.rxSpeedAvg
                        TxBps = $point.txSpeedAvg
                        RxPercent = $point.rxPercentAvg
                        TxPercent = $point.txPercentAvg
                    }
                }
            }
        )
        [pscustomobject]@{
            DeviceId = $DeviceId
            DeviceName = $DeviceName
            IfIndex = $item.Index
            InterfaceComment = $comments -join '; '
            InterfaceName = $names -join '; '
            Status = $state
            StatusDetail = @($item.Active | ForEach-Object { $_.status }) -join '; '
            ActiveAssignmentIds = @($item.Active | ForEach-Object { [string]$_.id })
            PerformanceAssignmentIds = @($performance | ForEach-Object { [string]$_.id })
            PerformanceEnabled = @($performance | Where-Object { $_.enabled -eq $true }).Count -gt 0
            TrafficInterfaceIds = @($item.Traffic | ForEach-Object { [string]$_.interfaceId } | Select-Object -Unique)
            TrafficAvailable = $item.Traffic.Count -gt 0
            RxBps = $latest.rxSpeedAvg
            TxBps = $latest.txSpeedAvg
            RxPercent = $latest.rxPercentAvg
            TxPercent = $latest.txPercentAvg
            PollTimeUtc = $latest.pollTimeUtc
            SecondsSincePoll = $latest.timeFromLastPollSeconds
            Samples = $samples
        }
    }
}

function Get-InterfaceGroupInventory {
    <#
    .SYNOPSIS
        Collects interface status and traffic through the WUG API.
    .PARAMETER DeviceId
        Explicit device scope; duplicates are queried once.
    .PARAMETER Range
        Report window. Default lastNHours.
    .PARAMETER RangeN
        Number of hours/days for a lastN window.
    .PARAMETER ApiMaxRetries
        Existing API wrapper's transient retries, 0-10; default 3, no nested retry loop.
    .PARAMETER CancellationPath
        Optional cancellation file, checked between devices and monitor pages.
    .PARAMETER DeviceMetadata
        Optional shared lookup filled with basic device objects for SNMP reuse.
    .EXAMPLE
        Get-InterfaceGroupInventory -DeviceId 818 -Range lastNHours -RangeN 4
    .NOTES
        Requires an existing Connect-WUGServer connection. API failures terminate.
    .LINK
        https://docs.ipswitch.com/NM/WhatsUpGold2026/02_Guides/rest_api/index.html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][int[]]$DeviceId,
        [ValidateSet('lastPolled', 'today', 'yesterday', 'lastWeek', 'lastNHours', 'lastNDays')]
        [string]$Range = 'lastNHours',
        [ValidateRange(1, 365)][int]$RangeN = 4,
        [ValidateRange(0,10)][int]$ApiMaxRetries = 3,
        [string]$CancellationPath,
        [hashtable]$DeviceMetadata
    )
    if (-not $global:WhatsUpServerBaseURI -or -not $global:WUGBearerHeaders) {
        throw 'Not connected. Run Connect-WUGServer before collecting interfaces.'
    }
    if ($null -eq $PSDefaultParameterValues) {$PSDefaultParameterValues=@{}}
    else {$PSDefaultParameterValues = $PSDefaultParameterValues.Clone()}
    $PSDefaultParameterValues['Get-WUGAPIResponse:MaxRetries'] = $ApiMaxRetries
    $devices = @($DeviceId | Select-Object -Unique)
    $completed = 0
    try {
    foreach ($id in $devices) {
        Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
        Write-Progress -Id 6200 -Activity 'Collecting WUG interface inventory' -Status "Device $id ($($completed + 1)/$($devices.Count))" -PercentComplete ([int](100 * $completed / $devices.Count))
        if ($id -lt 1) { throw "Invalid DeviceId: $id" }
        $device = @(Get-WUGDevice -DeviceId $id -View basic -ErrorAction Stop)
        if ($device.Count -ne 1) { throw "Expected one device for ID $id; received $($device.Count)." }
        if ($null -ne $DeviceMetadata) {$DeviceMetadata[[string]$id]=$device[0]}
        $name = [string]$device[0].displayName
        if (-not $name) { $name = [string]$device[0].hostName }
        if (-not $name) { $name = [string]$id }
        $monitors = [System.Collections.Generic.List[object]]::new()
        $page = $null
        $seenPages = @{}
        do {
            Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
            $uri = "$global:WhatsUpServerBaseURI/api/v1/devices/$id/monitors/-?type=all&view=status&limit=250"
            if ($page) { $uri += "&pageId=$([uri]::EscapeDataString($page))" }
            $response = Get-WUGAPIResponse -Uri $uri -Method GET -ErrorAction Stop
            foreach ($monitor in @($response.data)) {
                if ($null -ne $monitor) { $monitors.Add($monitor) }
            }
            $page = [string]$response.paging.nextPageId
            if ($page) {
                if ($seenPages.ContainsKey($page)) { throw "Repeated monitor page for device ${id}: $page" }
                $seenPages[$page] = $true
            }
        } while ($page)
        $parameters = @{ DeviceId = $id; ReportType = 'InterfaceTraffic'; Range = $Range; Limit = 250; ErrorAction = 'Stop' }
        if ($Range -match '^lastN') { $parameters.RangeN = $RangeN }
        $traffic = @(Get-WUGDeviceReport @parameters)
        ConvertTo-InterfaceGroupInventory -DeviceId $id -DeviceName $name -Monitors $monitors.ToArray() -Traffic $traffic
        $completed++
    }
    }
    finally { Write-Progress -Id 6200 -Activity 'Collecting WUG interface inventory' -Completed }
}

function Get-InterfaceGroupLabel {
    <#
    .SYNOPSIS
        Detects Group-prefixed labels in WUG interface comments and descriptions.
    .DESCRIPTION
        Recognizes case-insensitive tokens containing letters, digits, underscores
        or hyphens. Returns distinct labels, not inferred raw SNMP aliases.
    .PARAMETER Inventory
        Normalized interface inventory.
    .EXAMPLE
        $labels = @(Get-InterfaceGroupLabel -Inventory $inventory)
    .NOTES
        Empty inventory or descriptions without labels return no labels.
    .LINK
        ..\..\docs\interface-grouping.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)
    $labels = @(
        foreach ($row in $Inventory) {
            foreach ($description in @($row.InterfaceComment, $row.InterfaceName, $row.IfAlias, $row.IfName, $row.IfDescr)) {
                foreach ($match in [regex]::Matches([string]$description,
                        '(?i)(?<![A-Za-z0-9_-])Group[A-Za-z0-9_-]+(?![A-Za-z0-9_-])')) {
                    if ($match.Value -match '(?i)^Group[-_]*[A-Za-z0-9]') { $match.Value }
                }
            }
        }
    )
    $labels | Sort-Object -Unique
}

function Select-IntelligentInterfaceGroup {
    <#
    .SYNOPSIS
        Infers repeated meaningful description prefixes or words after full collection.
    .DESCRIPTION
        Removes IP addresses, basic port names, numbers and generic infrastructure
        words. Prefix chooses shared leading phrases (up to three words), preferring
        longer phrases, and assigns each interface once. Words allows overlapping
        groups for repeated meaningful words. At least two interfaces are required.
        All unmatched interfaces remain in Other Interfaces.
    .PARAMETER Inventory
        Complete normalized inventory for the selected device scope.
    .PARAMETER Strategy
        Prefix or Words; default Prefix.
    .EXAMPLE
        Select-IntelligentInterfaceGroup -Inventory $inventory -Strategy Prefix
    .NOTES
        Deterministic local heuristics, not semantic AI or an authorization boundary.
        Inference is based only on WUG descriptions; no external service is used.
    .LINK
        ..\..\docs\interface-grouping.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [ValidateSet('Prefix', 'Words')][string]$Strategy = 'Prefix'
    )
    $stopWords = @{}
    foreach ($word in @('to', 'from', 'the', 'and', 'for', 'of', 'on', 'in', 'via',
            'interface', 'interfaces', 'port', 'ports', 'slot', 'cpu', 'ethernet',
            'gigabitethernet', 'tengigabitethernet', 'fastethernet', 'twentyfivegige',
            'fortygigabitethernet', 'hundredgige', 'vlan', 'loopback', 'null', 'bridge',
            'virtual', 'adapter', 'network', 'connection', 'link', 'uplink', 'downlink',
            'lo', 'switch', 'new', 'primary', 'backup', 'unknown', 'default', 'unassigned')) {
        $stopWords[$word] = $true
    }
    $candidates = @{}
    for ($rowIndex = 0; $rowIndex -lt $Inventory.Count; $rowIndex++) {
        $row = $Inventory[$rowIndex]
        $rowCandidates = @{}
        foreach ($description in @($row.InterfaceComment, $row.InterfaceName, $row.IfAlias, $row.IfName, $row.IfDescr)) {
            $text = ([string]$description).ToLowerInvariant()
            $text = [regex]::Replace($text, '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b', ' ')
            $text = [regex]::Replace($text, '(?<!\w)(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]{0,}(?:/\d+)?', ' ')
            $text = [regex]::Replace($text,
                '(?<![a-z0-9])(?:[a-z]*gigabit[a-z]*|fastethernet|ethernet|twentyfivegige|hundredgige|fortygige|gi|te|fa|ge|xe|eth|eno|ens|enp|lo|loopback|null|vlan|vl|port|sfp|switch|br|vmbr|veth|tap|fwbr|fwpr|fwln|ra|rai)\s*\d[a-z0-9/.:_-]*', ' ')
            $tokens = @(
                foreach ($match in [regex]::Matches($text, '[a-z][a-z0-9]*')) {
                    $token = $match.Value
                    if ($token.Length -ge 2 -and -not $stopWords.ContainsKey($token)) { $token }
                }
            )
            if ($Strategy -eq 'Words') {
                foreach ($token in $tokens) { $rowCandidates[$token] = $true }
            }
            else {
                for ($length = 1; $length -le [Math]::Min(3, $tokens.Count); $length++) {
                    $phrase = $tokens[0..($length - 1)] -join ' '
                    $rowCandidates[$phrase] = $true
                }
            }
        }
        foreach ($label in $rowCandidates.Keys) {
            if (-not $candidates.ContainsKey($label)) {
                $candidates[$label] = [System.Collections.Generic.List[int]]::new()
            }
            $candidates[$label].Add($rowIndex)
        }
    }
    $ranked = @(
        foreach ($label in $candidates.Keys) {
            if ($candidates[$label].Count -ge 2) {
                [pscustomobject]@{
                    Label = $label; Length = @($label -split ' ').Count
                    Count = $candidates[$label].Count
                }
            }
        }
    )
    $ranked = @($ranked | Sort-Object @{ Expression = 'Length'; Descending = $true },
        @{ Expression = 'Count'; Descending = $true }, Label)
    $assigned = @{}
    $groups = @()
    foreach ($candidate in $ranked) {
        $indices = @($candidates[$candidate.Label] | Where-Object {
            $Strategy -eq 'Words' -or -not $assigned.ContainsKey([string]$_)
        })
        if ($indices.Count -lt 2) { continue }
        $rows = @(
            foreach ($index in $indices) {
                $assigned[[string]$index] = $true
                $Inventory[$index]
            }
        )
        $groups += [pscustomobject]@{
            Name = $candidate.Label
            MatchBasis = "Repeated meaningful $Strategy description match: '$($candidate.Label)' (minimum 2 interfaces)"
            Interfaces = $rows; InterfaceCount = $rows.Count
        }
    }
    $other = @(
        for ($index = 0; $index -lt $Inventory.Count; $index++) {
            if (-not $assigned.ContainsKey([string]$index)) { $Inventory[$index] }
        }
    )
    $groups | Sort-Object Name
    [pscustomobject]@{
        Name = 'Other Interfaces'; MatchBasis = 'No repeated meaningful description match; includes basic port names and unique descriptions'
        Interfaces = $other; InterfaceCount = $other.Count
    }
}

function Select-InterfaceGroups {
    <#
    .SYNOPSIS
        Groups interfaces by literal case-insensitive substrings in WUG descriptions.
    .PARAMETER Inventory
        Normalized interface inventory.
    .PARAMETER GroupName
        Names to find, e.g. GroupA through GroupL. Overlapping matches are retained.
        .PARAMETER MatchMode
            Substring (legacy helper default), Token boundaries, or whole-description Exact.
    .EXAMPLE
        Select-InterfaceGroups -Inventory $inventory -GroupName GroupA,GroupB
    .NOTES
        Empty groups remain visible; names are not regex or wildcard expressions.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$GroupName,
        [ValidateSet('Substring', 'Contains','StartsWith','EndsWith','Token', 'Exact')][string]$MatchMode = 'Substring'
    )
    foreach ($name in @($GroupName | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Group names cannot be blank.' }
        $rows = @($Inventory | Where-Object {
            $matched = $false
            foreach ($description in @($_.InterfaceComment, $_.InterfaceName, $_.IfAlias, $_.IfName, $_.IfDescr)) {
                $text = [string]$description
                $matched = $matched -or (Test-InterfaceGroupTextMatch -Text $text -Value $name -Match $MatchMode)
            }
            $matched
        })
        [pscustomobject]@{ Name = $name; Interfaces = $rows; InterfaceCount = $rows.Count
            MatchBasis = "Literal case-insensitive $MatchMode description match: '$name'" }
    }
}

function Sync-InterfaceNavigationGroups {
    <#
    .SYNOPSIS
        Adds whole-device navigation groups, without changing interface assignments.
    .DESCRIPTION
        Pre-checks immediate child names and existing membership. Additive only;
        never removes devices. Existing groups must carry this helper's ownership marker.
    .PARAMETER Groups
        Output from Select-InterfaceGroups.
    .PARAMETER ParentGroupId
        Existing parent for the helper's isolated folder.
    .PARAMETER FolderName
        Name of the owned folder.
    .EXAMPLE
        Sync-InterfaceNavigationGroups -Groups $groups -ParentGroupId 0 -WhatIf
    .NOTES
        WUG device groups cannot restrict users to individual interface monitors.
    .LINK
        https://docs.ipswitch.com/NM/WhatsUpGold2026/02_Guides/rest_api/index.html
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [ValidateRange(0, 2147483647)][int]$ParentGroupId = 0,
        [ValidateNotNullOrEmpty()][string]$FolderName = 'Interface Grouping POC'
    )
    $marker = 'WhatsUpGoldPS InterfaceGrouping: whole-device navigation; dashboards filter interfaces.'
    $children = @(Get-WUGDeviceGroup -ConfigGroupId $ParentGroupId -Children -ErrorAction Stop)
    $folder = @($children | Where-Object { $_.name -eq $FolderName })
    if ($folder.Count -gt 1) { throw "Multiple child groups named '$FolderName' under $ParentGroupId." }
    if ($folder.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess("$ParentGroupId/$FolderName", 'Create interface navigation folder')) {
            Write-Warning 'Folder creation skipped; child group and membership writes also skipped.'
            return
        }
        $folder = @(Add-WUGDeviceGroup -ParentGroupId $ParentGroupId -Name $FolderName -Description $marker -Confirm:$false -ErrorAction Stop)
        if ($folder.Count -ne 1 -or -not $folder[0].id) { throw 'Folder creation returned no group ID.' }
    }
    $definition = Get-WUGDeviceGroup -ConfigGroupId $folder[0].id -Definition -ErrorAction Stop
    if ($definition.description -ne $marker -or $definition.groupType -ne 'static') {
        throw "Folder '$FolderName' is not an owned static navigation group."
    }
    $children = @(Get-WUGDeviceGroup -ConfigGroupId $folder[0].id -Children -ErrorAction Stop)
    foreach ($group in $Groups) {
        $child = @($children | Where-Object { $_.name -eq $group.Name })
        if ($child.Count -gt 1) { throw "Multiple child groups named '$($group.Name)'." }
        if ($child.Count -eq 0) {
            if (-not $PSCmdlet.ShouldProcess("$FolderName/$($group.Name)", 'Create interface navigation group')) { continue }
            $child = @(Add-WUGDeviceGroup -ParentGroupId $folder[0].id -Name $group.Name -Description $marker -Confirm:$false -ErrorAction Stop)
            if ($child.Count -ne 1 -or -not $child[0].id) { throw "No group ID returned for '$($group.Name)'." }
            $children += $child
        }
        $definition = Get-WUGDeviceGroup -ConfigGroupId $child[0].id -Definition -ErrorAction Stop
        if ($definition.description -ne $marker -or $definition.groupType -ne 'static') {
            throw "Group '$($group.Name)' is not an owned static navigation group."
        }
        $existing = @{}
        foreach ($device in @(Get-WUGDevice -DeviceGroupID $child[0].id -ReturnHierarchy false -View id -ErrorAction Stop)) {
            $existing[[string]$device.id] = $true
        }
        $missing = @($group.Interfaces | ForEach-Object { [string]$_.DeviceId } | Select-Object -Unique |
            Where-Object { -not $existing.ContainsKey($_) })
        $added = 0
        if ($missing.Count -gt 0 -and $PSCmdlet.ShouldProcess($group.Name, "Add $($missing.Count) whole-device member(s)")) {
            $result = Add-WUGDeviceGroupMember -GroupId $child[0].id -DeviceId $missing -Confirm:$false -ErrorAction Stop
            if ($result.errors) { throw "Membership errors for '$($group.Name)': $($result.errors | ConvertTo-Json -Compress)" }
            $verified = @(Get-WUGDevice -DeviceGroupID $child[0].id -ReturnHierarchy false -View id -ErrorAction Stop)
            foreach ($id in $missing) {
                if (@($verified | Where-Object { [string]$_.id -eq $id }).Count -eq 0) {
                    throw "Device $id was not added to group '$($group.Name)'."
                }
            }
            $added = $missing.Count
        }
        [pscustomobject]@{ Name = $group.Name; FolderId = $folder[0].id; GroupId = $child[0].id; AddedDevices = $added }
    }
}

function Write-InterfaceGroupDashboardStage {
    <#
    .SYNOPSIS
        Exports a dashboard pack with per-group status and traffic drill-down.
    .PARAMETER Groups
        Output from Select-InterfaceGroups.
    .PARAMETER OutputDirectory
        Dashboard pack destination. Use a dedicated folder.
    .PARAMETER RangeLabel
        Human-readable report window.
    .PARAMETER Inventory
        Complete scope inventory for unique health counts, including unmatched interfaces.
    .PARAMETER SnmpCoverage
        Optional device-ID to SNMP result map, including devices with no interface rows.
    .PARAMETER StaleAfterMinutes
        Traffic timestamp age threshold. Historical ranges may intentionally be stale.
    .EXAMPLE
        Export-InterfaceGroupDashboards -Groups $groups -OutputDirectory C:\Reports\Interfaces
    .NOTES
        Snapshot reports, not a live portal or authorization boundary. Standard
        dashboard dependencies are loaded from CDN. Inventory JSON contains poll history.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$RangeLabel = 'lastNHours (4)',
        [AllowEmptyCollection()][object[]]$Inventory,
        [ValidateRange(1, 525600)][int]$StaleAfterMinutes = 60,
        [hashtable]$SnmpCoverage,
        [hashtable]$CollectionContext,
        [string]$CancellationPath
    )
    if (-not $PSBoundParameters.ContainsKey('Inventory')) { $Inventory = @($Groups | ForEach-Object { $_.Interfaces }) }
    Add-InterfaceGroupFreshness -Inventory $Inventory -StaleAfterMinutes $StaleAfterMinutes
    $health = Get-InterfaceGroupHealth -Inventory $Inventory
    $seenPages = @{}
    foreach ($group in $Groups) {
        $page = Get-WUGDashboardGroupPageName -Name $group.Name
        if ($seenPages.ContainsKey($page)) { throw "Duplicate normalized group name: $($group.Name)" }
        $seenPages[$page] = $true
        $group | Add-Member -NotePropertyName PageName -NotePropertyValue $page -Force
    }
    $stamp = [DateTime]::UtcNow.ToString('u')
    $directory = [IO.Path]::GetFullPath($OutputDirectory)
    $previous = $null
    $snapshotPath = Join-Path $directory 'inventory-snapshot.json'
    if (Test-Path -LiteralPath $snapshotPath) { $previous = Get-Content -LiteralPath $snapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
    $snapshot = New-InterfaceGroupSnapshot -Inventory $Inventory -Groups $Groups -SnmpCoverage $SnmpCoverage -CollectionContext $CollectionContext -Previous $previous
    $changes = @(Compare-InterfaceGroupSnapshot -Current $snapshot -Previous $previous)
    $changeRows = [System.Collections.Generic.List[string]]::new()
    foreach ($change in $changes) {
        $values = @($change.DeviceName, $change.InterfaceKey, $change.Change, $change.Classification, $change.UncertainSnmpCoverage,
            $change.PreviousGroups, $change.CurrentGroups)
        $cells = @($values | ForEach-Object { '<td>' + [Net.WebUtility]::HtmlEncode([string]$_) + '</td>' }) -join ''
        $changeRows.Add("<tr>$cells</tr>")
    }
    $changeNote = "$($changes.Count) changed interfaces since the previous successful local export."
    if (-not $previous -or [string]$previous.Server -ine [string]$snapshot.Server) { $changeNote = 'First export for this server/output: change baseline created; no comparison yet.' }
    if ($previous -and $previous.SchemaVersion -eq 1) { $changeNote += ' Legacy snapshot upgraded; configuration comparison starts with this export.' }
    $changeHtml = "<section><h2>Grouping changes</h2><p>$changeNote Failed/partial SNMP can cause uncertain apparent changes; review coverage before acting. ConfigurationChange denotes changed collection/review settings, not confirmed physical device changes.</p><div style='overflow:auto'><table><thead><tr><th>Device</th><th>Interface key</th><th>Change</th><th>Classification</th><th>Uncertain SNMP</th><th>Previous groups</th><th>Current groups</th></tr></thead><tbody>$($changeRows -join '')</tbody></table></div></section>"
    $coverageRows = [System.Collections.Generic.List[string]]::new()
    foreach ($device in @($SnmpCoverage.Keys | Sort-Object)) {
        $coverageRows.Add("<li>Device $([Net.WebUtility]::HtmlEncode([string]$device)): $([Net.WebUtility]::HtmlEncode([string]$SnmpCoverage[$device]))</li>")
    }
    if ($coverageRows.Count) { $changeHtml = "<section><h2>SNMP device coverage</h2><ul>$($coverageRows -join '')</ul></section>$changeHtml" }
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    }
    $encoding = [Text.UTF8Encoding]::new($true)
    $links = [System.Collections.Generic.List[string]]::new()
    $number = 0
    foreach ($group in $Groups) {
        Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
        $number++
        $fileName = $group.PageName
        $title = [System.Net.WebUtility]::HtmlEncode([string]$group.Name)
        $path = Join-Path $directory $fileName
        $rows = @($group.Interfaces | Select-Object InterfaceKey, DeviceId, DeviceName, IfIndex, InterfaceComment,
            InterfaceName, IfAlias, IfName, IfDescr, SnmpStatus, InventorySource, Status, StatusDetail, TrafficAvailable, PerformanceEnabled,
            RxBps, TxBps, RxPercent, TxPercent, PollTimeUtc, SecondsSincePoll, Freshness, LastSampleUtc, AgeMinutes)
        if ($rows.Count -gt 0) {
            $null = Export-DynamicDashboardHtml -Data $rows -OutputPath $path -ReportTitle "Interfaces - $title" `
                -CardField Status,DeviceName -StatusField Status -IndexUrl 'index.html' -ExportPrefix "interfaces-$number" `
                -ThresholdField @{ Field = 'RxPercent'; Warning = 80; Critical = 95 },
                    @{ Field = 'TxPercent'; Warning = 80; Critical = 95 }
            $html = [IO.File]::ReadAllText($path)
            # The shared template defaults to raw HTML cells; these inventory cells are text.
            $html = $html.Replace('columns: ', 'escape: true, columns: ')
            $html = $html.Replace('class="collapse" id="detailsSection"', 'class="collapse show" id="detailsSection"')
            $html = $html.Replace('aria-expanded="false"', 'aria-expanded="true"')
            $html = $html.Replace('bi-chevron-right" id="detailsChevron"', 'bi-chevron-down" id="detailsChevron"')
        }
        else {
            $html = "<!doctype html><html><head><meta charset='utf-8'><title>$title</title></head><body><h1>$title</h1><p>No matching interfaces. Check WUG assignment comments and traffic descriptions.</p><a href='index.html'>Back to groups</a></body></html>"
        }
        $json = ConvertTo-Json -InputObject @($group.Interfaces) -Depth 12 -Compress
        $json = $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
        $detail = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Interface-Group-Details.html'))
        $detail = $detail.Replace('INTERFACE_GROUP_DATA', $json)
        $groupHealth = Get-InterfaceGroupHealth -Inventory @($group.Interfaces)
        $detail = "<section style='margin:24px' aria-label='Snapshot health'><h2>Snapshot health</h2><p>Generated $stamp | Traffic older than $StaleAfterMinutes minutes is stale (historical windows may intentionally be old).</p><p>$($groupHealth.Down) Down / $($groupHealth.Stale) stale / $($groupHealth.MissingOrInvalidTime) missing, invalid or future timestamps / $($groupHealth.MissingActiveMonitor) missing active monitors / $($groupHealth.MissingPerformanceCollector) missing and $($groupHealth.DisabledPerformanceCollector) disabled performance collectors.</p><p>$($groupHealth.SnmpOnly) SNMP-only unmonitored / $($groupHealth.SnmpFailedOrPartial) incomplete or failed SNMP metadata.</p></section>$detail"
        if ($group.MatchBasis) {
            $basis = [System.Net.WebUtility]::HtmlEncode([string]$group.MatchBasis)
            $detail = "<p style='margin:24px'>Grouping: $basis</p>$detail"
        }
        $html = $html.Replace('</body>', "$detail</body>")
        $html = ConvertTo-OfflineInterfaceDashboardHtml -Html $html
        [IO.File]::WriteAllText($path, $html, $encoding)
        $down = @($group.Interfaces | Where-Object Status -eq Down).Count
        $unknown = @($group.Interfaces | Where-Object { $_.Status -ne 'Up' -and $_.Status -ne 'Down' }).Count
        $basis = [System.Net.WebUtility]::HtmlEncode([string]$group.MatchBasis)
        $summary=Get-InterfaceGroupCardSummary -Inventory @($group.Interfaces)
        $top=[System.Collections.Generic.List[string]]::new()
        foreach ($consumer in $summary.TopConsumers) {
            $label=[Net.WebUtility]::HtmlEncode([string]$consumer.Label)
            $rate=Format-InterfaceGroupRate -Bps $consumer.TotalBps
            $fresh=[Net.WebUtility]::HtmlEncode([string]$consumer.Freshness)
            $top.Add("<li>$label : $rate ($fresh)</li>")
        }
        $traffic='Traffic unavailable; no complete valid snapshots.'
        if ($summary.RateRows) { $traffic="RX $(Format-InterfaceGroupRate $summary.RxBps) / TX $(Format-InterfaceGroupRate $summary.TxBps) from $($summary.RateRows) complete snapshots (not necessarily simultaneous)." }
        $related=@($changes | Where-Object { @(([string]$_.CurrentGroups -split ';') + ([string]$_.PreviousGroups -split ';')) -contains $group.Name })
        $uncertain=@($related | Where-Object UncertainSnmpCoverage -eq $true).Count
        $links.Add("<a class='card' href='$fileName'><h2>$title</h2><strong>$($group.InterfaceCount) interfaces</strong><p>$($summary.Monitored) active-monitored / $($summary.Unmonitored) without active monitoring / $($groupHealth.SnmpOnly) SNMP-only</p><p>$down down / $unknown unknown, maintenance, disabled or unmonitored</p><p>$($groupHealth.Stale) stale / $($groupHealth.MissingOrInvalidTime) missing or suspect timestamps</p><p>$traffic</p><h3>Top traffic consumers (RX+TX)</h3><ul>$($top -join '')</ul><p>$($related.Count) changed / $uncertain uncertain SNMP changes</p><p>$basis</p></a>")
    }
    $window = [System.Net.WebUtility]::HtmlEncode($RangeLabel)
    $indexHtml = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Interface Groups</title>
<style>body{margin:0;background:#0f172a;color:#e2e8f0;font:16px system-ui}main{max-width:1200px;margin:auto;padding:40px}h1{font-size:40px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:18px}.card{padding:24px;border:1px solid #334155;border-radius:16px;background:#1e293b;color:inherit;text-decoration:none}.card:hover{border-color:#38bdf8}h2{color:#38bdf8}.note{color:#94a3b8;line-height:1.6}</style></head>
<body><main><h1>Interface Groups</h1><p class="note">WUG status + traffic snapshots | $window | Generated $stamp<br>Each category explains its matching rules. WUG navigation groups contain whole devices; these dashboards show only matching interfaces. Not an access-control boundary.</p><h2>Selected scope health (unique interfaces, not summed groups)</h2><p>$($health.Interfaces) interfaces / $($health.Down) Down / $($health.UnknownOrDisabled) unknown, maintenance or disabled / $($health.Stale) stale / $($health.MissingOrInvalidTime) missing or suspect timestamps.</p><p class="note">$($health.MissingActiveMonitor) missing active monitors / $($health.MissingPerformanceCollector) missing and $($health.DisabledPerformanceCollector) disabled performance collectors. Traffic freshness threshold: $StaleAfterMinutes minutes. Historical ranges may intentionally contain old data. This summary includes unmatched and excluded scope interfaces.</p><div class="grid">$($links -join "`n")</div></main></body></html>
"@
    $indexHtml = $indexHtml.Replace('</main>', "$changeHtml</main>")
    $indexHtml = $indexHtml.Replace('<div class="grid">', "<p>$($health.SnmpOnly) SNMP-only unmonitored / $($health.SnmpFailedOrPartial) incomplete or failed SNMP metadata.</p><div class=`"grid`">")
    [IO.File]::WriteAllText((Join-Path $directory 'index.html'), $indexHtml, $encoding)
    [IO.File]::WriteAllText((Join-Path $directory 'groups.json'),
        (ConvertTo-Json -InputObject @($Groups) -Depth 15), $encoding)
    [IO.File]::WriteAllText((Join-Path $directory 'changes.json'), (ConvertTo-Json -InputObject $changes -Depth 5), $encoding)
    $csv = @($changes | ConvertTo-Csv -NoTypeInformation)
    if (-not $csv.Count) { $csv = @('"InterfaceKey","DeviceName","Change","UncertainSnmpCoverage","PreviousGroups","CurrentGroups","PreviousDescription","CurrentDescription","Classification"') }
    [IO.File]::WriteAllLines((Join-Path $directory 'changes.csv'), $csv, $encoding)
    $temporarySnapshot = "$snapshotPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporarySnapshot, (ConvertTo-Json -InputObject $snapshot -Depth 6), $encoding)
        Move-Item -LiteralPath $temporarySnapshot -Destination $snapshotPath -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporarySnapshot) { Remove-Item -LiteralPath $temporarySnapshot -Force -ErrorAction Stop } }
    Join-Path $directory 'index.html'
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDV93labCgs1NQ2
# dpGfepYtASe6X4AGTT3RyTkdQ8f+VaCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBx
# LKe05zQGAaLTwbEIrfLt82plgUfxcsQ++QTxz3XptDANBgkqhkiG9w0BAQEFAASC
# AgAEHnkzL/LtxI3B27CGEqjOhGtXwwsrHsnEwd5SxxzxQFNZlnmpTWUhkdDjoJ4g
# cei0ZyDdi+wdkVBGZpJRbCsoXXQw2mCKdzsuo29KpuYGSP5X94qCcOw1hkUEtWzK
# 80BkjRtJm4qlUiDYpPKet1KTOUeuoCeXocmet+ytPePQoX+tP5jm+pDvAmXPD8oM
# Cy4nDYmfTZ9o0ao4J03zTiKIj7iAT0WgjwsOlGa8R5zrukVqY7d8acqHwuAEt8OE
# neoSAyFa0BI9etEdAqGkfSxGJl19+G5cWCv6VXgoWIneTNSXYLX5XL08Il2HHTsq
# 7S//Mdg9nm/+tVAxs/CU3xz2PQ7g++kkZteB0ukTG9usUDJc0c43VmEYmUE9KpON
# Zs0b8GjDRelYpSzFUCOQ2/tK4cBbHLT554g83PRzF0zN/x/8f/IJ9tRJ+0XuYU0b
# fJbvnz48PWT6HdvlzkPoQYNC4YG5wt96gVJ0JCt0frv/DaG5QU9tH1o0VSzkc00I
# pA/xW/QvvtfYoJ/nIm/a6NQtTHecOywmZ8LPHxOLqLrtPOmku8FNGHngB5WY1/QI
# RKVK+hQcbfZg5VIkv65LHneOD6JmaTe2ape8SEPA5sGHe7nbYl4AYQVcpupb5i96
# eKj13voggZp+DGTxeLltbnwvkEvQetJIKAie3FehrL2Q66GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzMzBaMC8GCSqGSIb3DQEJBDEiBCDGo137grYH
# 3D0OFXkC98S/2afTxbjtqDPZEfbahcnufDANBgkqhkiG9w0BAQEFAASCAgCGA5ks
# 5Vc+Ztlmg9TkVB+Pv1MVUhoT3pczFMxGyrLTC/gza2fRYtnBDRWB75to3RP40t30
# QUM7hyLbEMg5FxhkGa65+NoCKqN44VXgW1hLVp7drjae0SOBCsjdAX8jhgSWaL1+
# pd1X6g0Avb8kmsF05m1AjobjGv+fRjjcM2wlyVcD81Ky60qm5kejhD7YdHZ4zM2V
# 3EN0s2uqSoRPuksrgh/jRArccpqBjGaDu1WbZ4iGQIemrCVita2VWM1YV08gMESe
# ImkRTtgOxvxPE23fznC76lJaoWQOZbaCsnAvUcoSsAmK4/Tulstzdml5/ZLrPhit
# AImuKmiE0SpvHa4YiteZEEQackn/NYjl8CaMVYaC8c3odQau9BZJMbDWLzhwlWeF
# FVHMGCehSGMTBHg83q6AM34h6ZJULx3B1h1K/iF/dxR5j3UnmDXVBdd8+Kd9MrJG
# 3MtWAkGkkHqO/Mg+I/+uwvzz2Mip3f4rlwarj6PkltuFNBNELAtYXohaYZOD9aOW
# MkJ5RnI/iTkaWi1t8k9sT11wHr57gNl0PexnH2pygAkEY5dLK7SbByG9KoQzre4t
# zR0T4WZUF3YNyM4YwgaBYtlqSQxMfa45bXYC9CpM8iDYP6oK+3REpjiueB/1tSZK
# htq0XrGva7FHyqPWsfSjiMXHZLo7u5P7okL/xQ==
# SIG # End signature block
