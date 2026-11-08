#requires -Version 5.1
<#
.SYNOPSIS
    Runs interface grouping examples for selected devices or every accessible WUG device.
.DESCRIPTION
    NamedGroups matches supplied description substrings. AllInterfaces puts every
    API-visible interface in one dashboard. AutoGroups discovers GroupA-style tokens
    from WUG descriptions and optional raw SNMP fields, with a dashboard per label.
    IntelligentGroups infers repeated meaningful prefixes or words, retaining
    unmatched interfaces in Other Interfaces. Reuses the current WUG connection or
    auto-connects using the saved vault. WUG group creation is opt-in and additive.
.PARAMETER DeviceId
    Selected WUG device IDs.
.PARAMETER AllDevices
    Query every device accessible to the connected WUG user. May be expensive.
.PARAMETER GroupId
    Existing WUG source device groups; duplicates are queried once.
.PARAMETER ReturnHierarchy
    Include devices in child groups when GroupId is used.
.PARAMETER Mode
    NamedGroups (default), AllInterfaces, AutoGroups, or IntelligentGroups.
.PARAMETER Strategy
    Prefix (one group per interface) or Words (overlapping repeated-word groups).
    Only valid with IntelligentGroups. Both ignore basic port identifiers.
.PARAMETER GroupName
    Literal labels for NamedGroups mode; defaults to GroupA through GroupL.
.PARAMETER MatchMode
    Token (default), Exact, or legacy Substring literal matching in NamedGroups/AutoGroups.
.PARAMETER PreviewOnly
    Write an editable review CSV and return proposals without dashboard, publishing or WUG writes.
.PARAMETER BrowserReview
    Generate a local graphical review page and CSV preview only; suppress dashboard/WUG/publishing writes.
.PARAMETER BrowserReviewPath
    Optional graphical review HTML path. Requires BrowserReview; never a published dashboard file.
.PARAMETER PreviewPath
    Review CSV output path; defaults to review-preview.csv inside OutputDirectory when requested.
.PARAMETER ReviewPath
    Previously edited review CSV. Apply=True rows replace membership or exclude interfaces.
.PARAMETER Review
    Interactively review each interface before any dashboard or WUG writes; saves a preview CSV.
.PARAMETER StaleAfterMinutes
    Snapshot traffic freshness threshold, default 60 minutes. Does not change polling.
.PARAMETER UseSnmp
    Read raw ifAlias/ifName/ifDescr using selected discovery-vault credentials.
.PARAMETER SnmpCredentialNames
    Ordered vault entries (maximum 12), tried until one returns ifDescr; no guessed community.
.PARAMETER SnmpCredentialVersions
    V1, V2 or V3 aligned one-for-one with SnmpCredentialNames.
.PARAMETER IncludeSnmpOnly
    Include SNMP ports without WUG interface records, explicitly Unmonitored.
.PARAMETER SnmpFailureAction
    Warn (default) retains WUG inventory with failed/partial enrichment flags; Stop terminates.
.PARAMETER SnmpPort
    SNMP UDP port; default 161.
.PARAMETER SnmpTimeout
    Per-request SNMP timeout, 500-60000 milliseconds; default 3000.
.PARAMETER ApiMaxRetries
    Transient WUG read retries, 0-10; default 3 using the existing API wrapper.
.PARAMETER CancellationPath
    Optional signal file, checked between collection operations and before writes.
.PARAMETER CreateWugGroups
    Create owned WUG navigation groups and add whole-device members.
.PARAMETER OutputDirectory
    Dedicated dashboard folder. Existing pack files are overwritten.
.PARAMETER FolderName
    Isolated WUG folder name. Use different folders for different modes.
.PARAMETER PublishToWug
    Copy the generated HTML pack to the local WUG NmConsole with authentication configuration.
.PARAMETER NmConsolePath
    Existing WUG Html\NmConsole directory; auto-detected when publishing.
.PARAMETER PackName
    URL-safe published folder name under NmConsole\dashboards; defaults by mode.
.PARAMETER Range
    Report window; lastPolled by default for a quick example.
.PARAMETER RangeN
    Units for lastNHours or lastNDays.
.EXAMPLE
    .\Example-InterfaceGrouping.ps1 -DeviceId 818 -Mode AllInterfaces
.EXAMPLE
    .\Example-InterfaceGrouping.ps1 -AllDevices -Mode NamedGroups -CreateWugGroups -WhatIf
.EXAMPLE
    .\Example-InterfaceGrouping.ps1 -AllDevices -Mode AutoGroups -CreateWugGroups
.EXAMPLE
    .\Example-InterfaceGrouping.ps1 -DeviceId 818 -GroupName eno50,vmbr0 -CreateWugGroups
.EXAMPLE
    .\Example-InterfaceGrouping.ps1 -AllDevices -Mode IntelligentGroups -Strategy Prefix
.EXAMPLE
    .\Example-InterfaceGrouping.ps1 -GroupId 41 -ReturnHierarchy -Mode IntelligentGroups -Strategy Words -CreateWugGroups -WhatIf
.NOTES
    AllInterfaces means interfaces represented by WUG active assignments or traffic
    reports by default; opt-in SNMP can include unmonitored ports. AutoGroups recognizes literal Group-prefixed
    labels (letters/digits/underscore/hyphen), not arbitrary customer descriptions.
    WhatIf suppresses grouping WUG and local output writes, but still connects and
    collects inventory. No saved connection means an error with no interactive prompt.
    This script does not create monitors, change aliases, or enforce permissions.
.PARAMETER DeviceFilter
    All preserves existing script behavior. SnmpAssigned checks assigned WUG SNMP
    credentials and skips ineligible devices before monitors, reports and SNMP.
.PARAMETER Rules
    Mode Rules: ordered Name, Value, Match and optional Field objects. Match is
    Contains, StartsWith, EndsWith, Token or Exact; Field defaults to Any.
.PARAMETER RuleMode
    FirstMatch assigns the first matching rule; Overlap applies all matching rules.
.PARAMETER InventoryPath
    Replay saved collected-inventory.json without API/SNMP. Use a separate output
    folder. WUG navigation and publishing are forbidden for offline replay.
.PARAMETER InventoryExportPath
    Live collection cache JSON path, default OutputDirectory\collected-inventory.json.
    Saves observations, not a successful dashboard/publishing baseline.
.PARAMETER Collection
    Internal wizard reuse of the just-collected observations for review/approval.
.LINK
    ..\..\docs\interface-grouping.md
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Device')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Device')]
    [ValidateNotNullOrEmpty()][int[]]$DeviceId,
    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$AllDevices,
    [Parameter(Mandatory, ParameterSetName = 'Group')]
    [ValidateNotNullOrEmpty()][int[]]$GroupId,
    [Parameter(ParameterSetName = 'Group')][switch]$ReturnHierarchy,
    [Parameter(Mandatory, ParameterSetName = 'Cached')][string]$InventoryPath,
    [Parameter(DontShow=$true)]$Collection,
    [string]$InventoryExportPath,
    [ValidateSet('All','SnmpAssigned')][string]$DeviceFilter='All',
    [object[]]$Rules,
    [ValidateSet('FirstMatch','Overlap')][string]$RuleMode='FirstMatch',
    [ValidateSet('NamedGroups', 'AllInterfaces', 'AutoGroups', 'IntelligentGroups','Rules')]
    [string]$Mode = 'NamedGroups',
    [ValidateSet('Prefix', 'Words')][string]$Strategy = 'Prefix',
    [ValidateNotNullOrEmpty()][string[]]$GroupName = @('GroupA', 'GroupB', 'GroupC',
        'GroupD', 'GroupE', 'GroupF', 'GroupG', 'GroupH', 'GroupI', 'GroupJ', 'GroupK', 'GroupL'),
    [ValidateSet('Token', 'Exact', 'Substring','Contains','StartsWith','EndsWith')][string]$MatchMode = 'Token',
    [switch]$PreviewOnly,
    [switch]$BrowserReview,
    [string]$BrowserReviewPath,
    [string]$PreviewPath,
    [string]$ReviewPath,
    [switch]$Review,
    [ValidateRange(1, 525600)][int]$StaleAfterMinutes = 60,
    [switch]$UseSnmp,
    [ValidateCount(1, 12)][string[]]$SnmpCredentialNames,
    [ValidateSet('V1', 'V2', 'V3')][string[]]$SnmpCredentialVersions,
    [switch]$IncludeSnmpOnly,
    [ValidateSet('Warn', 'Stop')][string]$SnmpFailureAction = 'Warn',
    [ValidateRange(1, 65535)][int]$SnmpPort = 161,
    [ValidateRange(500, 60000)][int]$SnmpTimeout = 3000,
    [ValidateRange(0,10)][int]$ApiMaxRetries = 3,
    [string]$CancellationPath,
    [switch]$CreateWugGroups,
    [string]$OutputDirectory,
    [string]$FolderName,
    [switch]$PublishToWug,
    [string]$NmConsolePath,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$')][string]$PackName,
    [ValidateSet('lastPolled', 'today', 'yesterday', 'lastWeek', 'lastNHours', 'lastNDays')]
    [string]$Range = 'lastPolled',
    [ValidateRange(1, 365)][int]$RangeN = 4
)
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'InterfaceGroupingHelpers.ps1')
if ($BrowserReview) {
    if ($Review) { throw '-BrowserReview and console -Review cannot be combined.' }
    $PreviewOnly=$true
}
elseif ($BrowserReviewPath) { throw '-BrowserReviewPath requires -BrowserReview.' }
Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
$cached=$PSCmdlet.ParameterSetName -eq 'Cached' -or $null -ne $Collection
if ($PSCmdlet.ParameterSetName -eq 'Cached') {
    if ($Collection) {throw 'Use InventoryPath or Collection, not both.'}
    $Collection=Read-InterfaceGroupCollection -Path $InventoryPath
    if ($CreateWugGroups -or $PublishToWug) {throw 'Offline InventoryPath runs cannot create WUG groups or publish. Use a live profile run for those actions.'}
}
if ($Mode -eq 'Rules') {Test-InterfaceGroupRules -Rules $Rules}
elseif ($Rules -or $PSBoundParameters.ContainsKey('RuleMode')) {throw 'Rules and RuleMode require -Mode Rules.'}
if ($UseSnmp -and -not $cached) {
    if (-not $SnmpCredentialNames -or -not $SnmpCredentialVersions -or $SnmpCredentialNames.Count -ne $SnmpCredentialVersions.Count) {
        throw '-UseSnmp requires aligned, nonempty -SnmpCredentialNames and -SnmpCredentialVersions.'
    }
    . (Join-Path $scriptDir 'InterfaceGroupSnmpHelpers.ps1')
    Initialize-InterfaceGroupSnmp
    $snmpCredentials = @(Get-InterfaceGroupSnmpCredentials -Names $SnmpCredentialNames -Versions $SnmpCredentialVersions)
}
elseif (-not $UseSnmp -and @($PSBoundParameters.Keys | Where-Object { $_ -like 'Snmp*' -or $_ -eq 'IncludeSnmpOnly' }).Count -gt 0) {
    throw 'SNMP options require -UseSnmp.'
}
if ($PSBoundParameters.ContainsKey('GroupName') -and $Mode -ne 'NamedGroups') {
    throw '-GroupName is only used with -Mode NamedGroups.'
}
if ($PSBoundParameters.ContainsKey('Strategy') -and $Mode -ne 'IntelligentGroups') {
    throw '-Strategy is only used with -Mode IntelligentGroups.'
}
if (-not $PublishToWug -and ($PSBoundParameters.ContainsKey('NmConsolePath') -or $PSBoundParameters.ContainsKey('PackName'))) {
    throw '-NmConsolePath and -PackName require -PublishToWug.'
}
$scope = @{}
if ($cached) {
    Test-InterfaceGroupCollection -Collection $Collection
    foreach ($property in $Collection.SourceScope.PSObject.Properties) {$scope[$property.Name]=$property.Value}
    $DeviceId=@($Collection.DeviceIds)
    $Range=$Collection.Range;$RangeN=$Collection.RangeN
    if ($PSCmdlet.ParameterSetName -ne 'Cached' -and [string]$Collection.Server -ine [string]$global:WhatsUpServerBaseURI) {throw 'Collected inventory belongs to another WUG server; collect again before applying.'}
    Write-Warning "Reusing observations collected $($Collection.CollectedUtc). No devices, reports or SNMP are queried; this is not a live refresh."
}
elseif ($PSCmdlet.ParameterSetName -eq 'All') {
    $scope.AllDevices = $AllDevices
}
elseif ($PSCmdlet.ParameterSetName -eq 'Group') {
    $scope.GroupId = $GroupId
    $scope.ReturnHierarchy = $ReturnHierarchy
}
else { $scope.DeviceId = $DeviceId }
if (-not $cached) {
    Connect-InterfaceGroupServer -ErrorAction Stop
    $DeviceId = @(Resolve-InterfaceGroupDevice @scope -ApiMaxRetries $ApiMaxRetries -CancellationPath $CancellationPath -ErrorAction Stop)
    $candidateCount=$DeviceId.Count
    if ($DeviceFilter -eq 'SnmpAssigned') {$DeviceId=@(Select-InterfaceGroupSnmpDevice -DeviceId $DeviceId -ApiMaxRetries $ApiMaxRetries -CancellationPath $CancellationPath)}
}
$modeLabel = $Mode
if ($Mode -eq 'IntelligentGroups') { $modeLabel = "$Mode-$Strategy" }
if (-not $OutputDirectory) {
    $outputLabel=$modeLabel
    if ($PSCmdlet.ParameterSetName -eq 'Cached') {$outputLabel="Offline-$modeLabel"}
    $OutputDirectory = Join-Path $env:ProgramData "WhatsUpGoldPS\Output\InterfaceGroups\$outputLabel"
}
if ($PSCmdlet.ParameterSetName -eq 'Cached' -and [IO.Path]::GetFullPath($OutputDirectory) -ieq (Split-Path ([IO.Path]::GetFullPath($InventoryPath)) -Parent)) {
    throw 'Use a separate OutputDirectory for offline demos; never replace the live collection pack.'
}
if (-not $FolderName) { $FolderName = "Interface Grouping Example - $modeLabel" }
if (-not $PackName) { $PackName = "interfaces-$modeLabel" }
$runLock = $null
try {
if (-not $WhatIfPreference -and -not $PreviewOnly) { $runLock = Open-InterfaceGroupRunLock -OutputDirectory $OutputDirectory }
if ($cached) {
    $inventory=@($Collection.Inventory)
    $snmpCoverage=@{}
    foreach ($property in ([pscustomobject]$Collection.SnmpCoverage).PSObject.Properties) {$snmpCoverage[$property.Name]=$property.Value}
}
else {
    $deviceMetadata=@{}
    $inventory = @(Get-InterfaceGroupInventory -DeviceId $DeviceId -Range $Range -RangeN $RangeN -ApiMaxRetries $ApiMaxRetries -CancellationPath $CancellationPath -DeviceMetadata $deviceMetadata -ErrorAction Stop)
}
if ($UseSnmp -and -not $cached) {
    $snmpCoverage = @{}
    $inventory = @(Add-InterfaceGroupSnmpInventory -Inventory $inventory -DeviceId $DeviceId -Credentials $snmpCredentials `
        -IncludeSnmpOnly:$IncludeSnmpOnly -FailureAction $SnmpFailureAction -Port $SnmpPort -Timeout $SnmpTimeout -Coverage $snmpCoverage -CancellationPath $CancellationPath -DeviceMetadata $deviceMetadata)
}
if (-not $cached) {
    $Collection=[pscustomobject]@{SchemaVersion=1;Server=[string]$global:WhatsUpServerBaseURI;CollectedUtc=[DateTime]::UtcNow.ToString('o')
        SourceScope=[pscustomobject]$scope;DeviceIds=@($DeviceId);CandidateDeviceCount=$candidateCount;DeviceFilter=$DeviceFilter
        Range=$Range;RangeN=$RangeN;Inventory=@($inventory);SnmpCoverage=$snmpCoverage}
}
if (-not $InventoryExportPath) {$InventoryExportPath=Join-Path $OutputDirectory 'collected-inventory.json'}
$savedInventoryPath=$InventoryPath
if (-not $cached) {$savedInventoryPath=Export-InterfaceGroupCollection -Collection $Collection -Path $InventoryExportPath}
Add-InterfaceGroupFreshness -Inventory $inventory -StaleAfterMinutes $StaleAfterMinutes
switch ($Mode) {
    'Rules' {$groups=@(Select-InterfaceGroupRules -Inventory $inventory -Rules $Rules -RuleMode $RuleMode)}
    'IntelligentGroups' {
        $groups = @(Select-IntelligentInterfaceGroup -Inventory $inventory -Strategy $Strategy -ErrorAction Stop)
    }
    'AllInterfaces' {
        $groups = @([pscustomobject]@{
            Name = 'All Interfaces'; Interfaces = $inventory; InterfaceCount = $inventory.Count
        })
    }
    'AutoGroups' {
        $labels = @(Get-InterfaceGroupLabel -Inventory $inventory)
        if ($labels.Count -eq 0) {
            throw 'No Group-prefixed labels found in available WUG/SNMP descriptions. Use NamedGroups with your own labels, or AllInterfaces to inspect the inventory.'
        }
        $groups = @(Select-InterfaceGroups -Inventory $inventory -GroupName $labels -MatchMode $MatchMode -ErrorAction Stop)
    }
    'NamedGroups' {
        $groups = @(Select-InterfaceGroups -Inventory $inventory -GroupName $GroupName -MatchMode $MatchMode -ErrorAction Stop)
    }
}
Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
$selection = Update-InterfaceGroupSelection -Inventory $inventory -Groups $groups -OutputDirectory $OutputDirectory `
    -ReviewPath $ReviewPath -PreviewPath $PreviewPath -Review:$Review -PreviewOnly:$PreviewOnly
$reviewHtmlPath=$null
if ($BrowserReview) {
    if (-not $BrowserReviewPath) { $BrowserReviewPath=Join-Path $OutputDirectory 'interface-review.html' }
    $reviewHtmlPath=Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups @($selection.Groups) -Decisions $selection.Decisions -Path $BrowserReviewPath
}
$groups = @($selection.Groups)
$collectionContext = New-InterfaceGroupCollectionContext -Scope $scope -Mode $Mode -Strategy $Strategy -GroupName $GroupName `
    -MatchMode $MatchMode -Range $Range -RangeN $RangeN -UseSnmp ([bool]$UseSnmp) -IncludeSnmpOnly ([bool]$IncludeSnmpOnly) `
    -SnmpCredentialNames $SnmpCredentialNames -SnmpCredentialVersions $SnmpCredentialVersions -Decisions $selection.Decisions
$collectionContext.DeviceFilter=$Collection.DeviceFilter
$collectionContext.Server=$Collection.Server
$collectionContext.Offline=$PSCmdlet.ParameterSetName -eq 'Cached'
if ($Mode -eq 'Rules') {$collectionContext.Rules=ConvertTo-Json -InputObject @($Rules) -Depth 5 -Compress;$collectionContext.RuleMode=$RuleMode}
$health = Get-InterfaceGroupHealth -Inventory $inventory
if ($inventory.Count -eq 0) { Write-Warning 'No API-visible interfaces were returned for this device scope.' }
elseif (@($groups | Where-Object InterfaceCount -gt 0).Count -eq 0) {
    Write-Warning 'No descriptions matched the requested group names; dashboards will show empty groups.'
}
$navigation = @()
Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
if ($CreateWugGroups -and -not $PreviewOnly) {
    $navigation = @(Sync-InterfaceNavigationGroups -Groups $groups -FolderName $FolderName -ErrorAction Stop)
}
$indexPath = $null
if (-not $PreviewOnly -and $PSCmdlet.ShouldProcess($OutputDirectory, 'Write example interface dashboard pack')) {
    Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
    $indexPath = Export-InterfaceGroupDashboards -Groups $groups -OutputDirectory $OutputDirectory `
        -RangeLabel "$Range ($RangeN)" -Inventory $inventory -StaleAfterMinutes $StaleAfterMinutes -SnmpCoverage $snmpCoverage `
        -CollectionContext $collectionContext -CancellationPath $CancellationPath -ErrorAction Stop
}
$publication = $null
if ($PublishToWug -and -not $PreviewOnly) {
    Test-InterfaceGroupCancellation -CancellationPath $CancellationPath
    if ($indexPath) {
        $publication = Copy-WUGDashboardPack -SourcePath $OutputDirectory -NmConsolePath $NmConsolePath -PackName $PackName -ErrorAction Stop
    }
    else { Write-Warning 'No new dashboard pack was written; publishing is skipped to avoid copying stale output.' }
}
[pscustomobject]@{
    PreviewPath = $selection.PreviewPath; Decisions = $selection.Decisions; Health = $health
    ReviewHtmlPath = $reviewHtmlPath
    Mode = $Mode; Strategy = $(if ($Mode -eq 'IntelligentGroups') { $Strategy } else { $null })
    DeviceCount = @($DeviceId | Select-Object -Unique).Count
    IndexPath = $indexPath; Groups = $groups; NavigationGroups = $navigation; Inventory = $inventory
    Publication = $publication
    SnmpCoverage = $snmpCoverage
    Collection = $Collection; InventoryPath = $savedInventoryPath
    CandidateDeviceCount = $Collection.CandidateDeviceCount; SkippedDeviceCount = $Collection.CandidateDeviceCount-$DeviceId.Count
}
}
finally { if ($runLock) { $runLock.Dispose() } }

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8/oq75hUpWkZ0
# qyz4VAZ5NgeYrmwCoDC17ZRprBRv1aCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDw
# lJkQmZycPS5/KEnSdagqCMj6xCxMZ6D3O0uBOpQQnzANBgkqhkiG9w0BAQEFAASC
# AgBHHBxAiqBS6cWa8tk2M6PQiXlUOGs8UFahPj1UKKDp1fk0AbNnb65+khFyZlWR
# MSKUTmZBheMgsXr0gLLAmuMj1hW1aNDYkaNC6v0WMA+sgbDWWha7RrBT1OZ4YAdt
# QXegaQnos0H7iGvX8prV7iGqic24b8dKd70qvPG4RgWhuWDI61Dw2dQ5EZbxQEEP
# t7P16kXYKAL3964OuyHVorRTTaUmb1oSmGA3tIMBupUSSMs/FlRXBuN/o9kltPnH
# xEuUhD3a1pdplzBsvZjIJ7dvxwwx5lZPSSQboZix1WLMtAIAcIJdG4VwJGK4N82Z
# ujSoexe+jqBylSMp/M5u0Bu4IdNuix7r4CNAqNVgvVUaV027YZcieS5gN4mrx98G
# qwoa4XF6hUgJrAn0dPteTxlcgD4edERkpgpYdIzmJAfwECq5KwDXXqzgV5Y2Wnmh
# yelm8nWxm3ygLwsrJxSAiRpgptCx3mVA73ANjJGiYMPradG0udKlZthTf7MPVMhS
# 64L81abIYzH9ztGAWWt9I8S4nnmtFNs3rvFFTPu1JeiTGMoDF/WvHPeDhsaL9S4O
# gd8bGDRa/EUQld5F5tiMj4KMddRFGa+7eeYElWQOvzebvZq+YNGo5BX+8wDUnfdC
# /MGgXQIkmSfjJSOBIeWGLl/aoyW0UPb8haEK6IW12EybJ6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzMzhaMC8GCSqGSIb3DQEJBDEiBCCb6osScDlZ
# FHjYe3QRITRiuI2j+2bZUOOpSJ3RsrzQhjANBgkqhkiG9w0BAQEFAASCAgBJ1+Rj
# iQbu4lizs6KQNqG+wDGlsJF3BXlzZKNAKPXGmYR54FS0lv48y2kZYzSSENi0T69h
# uqi0+mgZNyD8Wb/D8/2b3Rig5wFcD/DIvidhn066znPRCl4FFaRTYiruQvYweJeU
# bNlnoStNBwvtKQCRoCk1+5A108yNh5Hu+rbCWuY1ylDMfV/pBmZsopo7YVUyCNYa
# IEJXlBqlIIBTtR1lMrNbhhFISFdAT5yhFGiX57i85Yintplx9xhk15qoDWjE4Bsn
# uuqalYVt7UQuVefbQp0/DfaNAw6kUlLkxcH1YwNQ1GOZ5P1VUo1ARrCu9YCPwQuc
# drdPXVwvudGJd71XaAVhrnuGs7IvAsZ1SED5+nSUB+GOXbvUdaSNdt1JoZQA4tx4
# MBEC7t/gJnBR+pC24Ua5HF5G7T4YKY4vgltV5zrUNjAFV1Zyqbz32I52p+/ULI+K
# Q3J3rsMQZXp/UWllt6W9geh0O3UmLI3Xnp7nJ4k7xQlPbytfgvzoZ+rMwB+POQYS
# PFYINohYHjoRF6f/bzJtjSXzmlJ8ptqXQUJj8EDQLM2o5GSgbhUB9pTdPoc4bNBK
# 18eNU7P7ftyjktOhypOItWP5K2Nh3neom63xaemda3yj4SWH+NoQv2HXFTaZONFJ
# Cgdic13rglPkZgfM82qZ9LORQ7KAl0Bi0yLJDA==
# SIG # End signature block
