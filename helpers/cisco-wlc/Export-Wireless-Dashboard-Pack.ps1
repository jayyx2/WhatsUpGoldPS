#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SummaryDirectory,
    [string]$OutputDirectory,
    [string]$FullDirectory = '',
    [string]$WhatsUpGoldPsRepoPath,
    [ValidateRange(1000, 50000)] [int]$RogueVariableLimit = 20000,
    [bool]$IncludeRogues = $false,
    [bool]$IncludeCoverageDashboard = $false,
    [bool]$IncludeRfHealth = $false,
    [bool]$IncludeJoinTime = $false,
    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set dynamic defaults if not provided
$discoveryOutputBase = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
if (-not $SummaryDirectory) {
    $SummaryDirectory = Join-Path $discoveryOutputBase 'summary'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $discoveryOutputBase 'summary\dashboards'
}
if (-not $WhatsUpGoldPsRepoPath) {
    # Try to find the WhatsUpGoldPS module location
    $mod = Get-Module -Name WhatsUpGoldPS -ErrorAction SilentlyContinue
    if ($mod -and $mod.ModuleBase) {
        $WhatsUpGoldPsRepoPath = Split-Path (Split-Path $mod.ModuleBase -Parent) -Parent
    } else {
        # Fallback: assume it's in the workspace or standard location
        $WhatsUpGoldPsRepoPath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }
}

# Ensure directories exist
foreach ($dir in @($SummaryDirectory, $OutputDirectory)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Ensure-FileExists {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Publish-OfflineDependencies {
    param(
        [Parameter(Mandatory)] [string]$SourceDirectory,
        [Parameter(Mandatory)] [string]$DestinationDirectory,
        [Parameter(Mandatory)] [string[]]$HtmlPaths
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        throw "Offline dependency directory not found: $SourceDirectory"
    }

    Ensure-Directory -Path $DestinationDirectory

    Copy-Item -Path (Join-Path $SourceDirectory '*') -Destination $DestinationDirectory -Recurse -Force

    $resolvedSourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\','/')
        $sourceUriPrefix = 'file:///' + $resolvedSourceDirectory.Replace('\', '/') + '/'
    $resetAllSearchOld = @'
            setTableData(allData);
            $table.bootstrapTable('resetSearch', '');
            $table.bootstrapTable('selectPage', 1);
'@
    $resetAllSearchNew = @'
            $table.bootstrapTable('resetSearch', '');
            $table.bootstrapTable('refreshOptions', { data: allData });
            $table.bootstrapTable('selectPage', 1);
'@
    $resetFilteredSearchOld = @'
        setTableData(filtered);
        $table.bootstrapTable('resetSearch', '');
        $table.bootstrapTable('selectPage', 1);
'@
    $resetFilteredSearchNew = @'
        $table.bootstrapTable('resetSearch', '');
        $table.bootstrapTable('refreshOptions', { data: filtered });
        $table.bootstrapTable('selectPage', 1);
'@
    foreach ($htmlPath in $HtmlPaths) {
        if (-not (Test-Path -LiteralPath $htmlPath)) { continue }

        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html = $html.Replace($sourceUriPrefix, 'dependency/')
        $html = [regex]::Replace($html, '\s+crossorigin="anonymous"', '')
        $html = $html.Replace($resetAllSearchOld, $resetAllSearchNew)
        $html = $html.Replace($resetFilteredSearchOld, $resetFilteredSearchNew)
        $html | Out-File -LiteralPath $htmlPath -Encoding UTF8
    }
}

function Normalize-String {
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Normalize-DisplayKey {
    param([AllowNull()] [object]$Value)

    $text = Normalize-String $Value
    if ([string]::IsNullOrEmpty($text)) { return '' }

    $clean = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    return $clean.Trim()
}

function Test-IsPopulatedValue {
    param([AllowNull()] [object]$Value)

    if ($null -eq $Value) { return $false }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    $trimmed = $text.Trim()
    if ($trimmed -eq '0' -or $trimmed -eq '0.0.0.0') { return $false }
    return $true
}

function Remove-UnpopulatedColumns {
    param(
        [Parameter(Mandatory)] [object[]]$Rows,
        [string[]]$KeepFields = @(),
        [string]$DatasetName = 'dataset'
    )

    if (@($Rows).Count -eq 0) { return @($Rows) }

    $props = @($Rows[0].PSObject.Properties.Name)
    $keptProps = New-Object System.Collections.Generic.List[string]
    $removedProps = New-Object System.Collections.Generic.List[string]

    foreach ($p in $props) {
        if ($KeepFields -contains $p) {
            $keptProps.Add($p)
            continue
        }

        $hasData = $false
        foreach ($r in $Rows) {
            if (Test-IsPopulatedValue -Value $r.$p) {
                $hasData = $true
                break
            }
        }

        if ($hasData) { $keptProps.Add($p) } else { $removedProps.Add($p) }
    }

    if ($removedProps.Count -gt 0) {
        Write-Host "Pruned empty columns from ${DatasetName}: $($removedProps -join ', ')" -ForegroundColor Yellow
    }

    $result = foreach ($r in $Rows) {
        $row = [ordered]@{}
        foreach ($p in $keptProps) {
            $row[$p] = $r.$p
        }
        [PSCustomObject]$row
    }

    return @($result)
}

function Get-RogueTableRelativePath {
    param([string]$Oid)

    $base = '1.3.6.1.4.1.9.9.610.'
    if ([string]::IsNullOrWhiteSpace($Oid) -or -not $Oid.StartsWith($base)) {
        return ''
    }

    $parts = $Oid.Substring($base.Length).Split('.')
    if ($parts.Count -eq 0) { return '' }

    $take = [Math]::Min(4, $parts.Count)
    return ($parts[0..($take - 1)] -join '.')
}

function Get-RogueDisplayValue {
    param(
        [string]$Type,
        [string]$Value,
        [string]$HexValue
    )

    if ($Type -eq 'OctetString' -and -not [string]::IsNullOrWhiteSpace($HexValue)) {
        $hasControl = [regex]::IsMatch(([string]$Value), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')

        if ($hasControl) {
            return "0x$HexValue"
        }
    }

    return Normalize-DisplayKey $Value
}

function Get-ClientBestState {
    param([AllowNull()] [string]$Status)
    switch ((Normalize-String $Status).ToLowerInvariant()) {
        'authenticated' { 'healthy' }
        'associated' { 'healthy' }
        'idle' { 'warning' }
        'aaa-pending' { 'warning' }
        'powersave' { 'warning' }
        default { 'unknown' }
    }
}

function Get-RowStatusLabel {
    param([AllowNull()] [string]$Code)
    switch (Normalize-String $Code) {
        '1' { 'active' }
        '2' { 'notInService' }
        '3' { 'notReady' }
        '4' { 'createAndGo' }
        '5' { 'createAndWait' }
        '6' { 'destroy' }
        default { if ([string]::IsNullOrWhiteSpace((Normalize-String $Code))) { 'unknown' } else { "rowstatus-$Code" } }
    }
}

function Export-Dashboard {
    param(
        [Parameter(Mandatory)] [object[]]$Data,
        [Parameter(Mandatory)] [string]$OutputHtmlPath,
        [Parameter(Mandatory)] [string]$OutputJsonPath,
        [Parameter(Mandatory)] [string]$ReportTitle,
        [string[]]$CardField,
        [string]$StatusField,
        [string]$ExportPrefix,
        [Parameter(Mandatory)] [string]$TemplatePath,
        [string]$IndexUrl,
        [switch]$Offline
    )

    ($Data | ConvertTo-Json -Depth 20) | Out-File -LiteralPath $OutputJsonPath -Encoding UTF8
    Write-Host "  [Export-Dashboard] Wrote JSON: $($Data.Count) input rows, file=$(Split-Path $OutputJsonPath -Leaf)" -ForegroundColor DarkGray
    $reportData = @(Get-Content -LiteralPath $OutputJsonPath -Raw | ConvertFrom-Json)
    # Unwrap PS5.1 ConvertFrom-Json array nesting
    if ($reportData.Count -eq 1 -and $reportData[0] -is [System.Object[]]) {
        $reportData = $reportData[0]
    }
    Write-Host "  [Export-Dashboard] Read back: $($reportData.Count) rows" -ForegroundColor DarkGray

    $params = @{
        OutputPath = $OutputHtmlPath
        ReportTitle = $ReportTitle
        CardField = $CardField
        StatusField = $StatusField
        ExportPrefix = $ExportPrefix
        TemplatePath = $TemplatePath
    }
    if ($IndexUrl) { $params.IndexUrl = $IndexUrl }
    if ($Offline) { $params.Offline = $true }

    return ($reportData | Export-DynamicDashboardHtml @params)
}

function Add-DashboardPageHeader {
    param(
        [Parameter(Mandatory)] [string]$HtmlPath,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$ViewName,
        [int]$RowCount,
        [AllowNull()] [object]$Kpis
    )

    if (-not (Test-Path -LiteralPath $HtmlPath)) { return }

    $html = Get-Content -LiteralPath $HtmlPath -Raw
        if ($html -match 'id="dashboard-page-title"') { return }

    $titleEsc = [System.Net.WebUtility]::HtmlEncode($Title)
    $viewEsc = [System.Net.WebUtility]::HtmlEncode($ViewName)
    $subtitle = "View: $viewEsc | Rows: $RowCount"
    if ($null -ne $Kpis) {
        $subtitle += " | APs: $($Kpis.APCount), Clients: $($Kpis.ClientCount), WLANs: $($Kpis.WlanCount)"
    }
    $subtitleEsc = [System.Net.WebUtility]::HtmlEncode($subtitle)

    $headerHtml = @"
        <div id="dashboard-page-title" class="mb-3 pb-2 border-bottom">
            <h4 class="mb-1">$titleEsc</h4>
            <div class="text-muted small">$subtitleEsc</div>
        </div>
"@

        $containerMarker = '<div class="container-fluid p-3">'
    if ($html.Contains($containerMarker)) {
        $html = $html.Replace($containerMarker, "$containerMarker`r`n$headerHtml")
        $html | Out-File -LiteralPath $HtmlPath -Encoding UTF8
    }
}

$clientJsonPath = Join-Path $SummaryDirectory 'wireless-client-inventory-summary.json'
$apJsonPath = Join-Path $SummaryDirectory 'wireless-ap-inventory-summary.json'
$wlanJsonPath = Join-Path $SummaryDirectory 'wireless-wlan-inventory-summary.json'
$rogueProximityJsonPath = Join-Path $SummaryDirectory 'wireless-rogue-proximity-summary.json'
$datasetJsonPath = Join-Path $SummaryDirectory 'wireless-dashboard-datasets.json'

$rootSummaryFiles = @(
    (Join-Path $SummaryDirectory 'wireless-ap-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-dot11-client-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-dot11-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-rogue-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-rf-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-mobility-ext-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-wlan-summary.json'),
    (Join-Path $SummaryDirectory 'wireless-sys-summary.json')
)

Ensure-FileExists -Path $clientJsonPath
Ensure-FileExists -Path $apJsonPath
Ensure-FileExists -Path $wlanJsonPath
foreach ($p in $rootSummaryFiles) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Warning "Root summary not found (skipping in coverage): $p"
    }
}

Ensure-Directory -Path $OutputDirectory

$exportFnPath = Join-Path $WhatsUpGoldPsRepoPath 'helpers\reports\Export-DynamicDashboardHtml.ps1'
$templatePath = Join-Path $WhatsUpGoldPsRepoPath 'helpers\reports\Dynamic-Dashboard-Template.html'
Ensure-FileExists -Path $exportFnPath
Ensure-FileExists -Path $templatePath
$dependencySourceDirectory = Join-Path (Split-Path -Parent $exportFnPath) 'dependency'

if ([string]::IsNullOrWhiteSpace($FullDirectory)) {
    $FullDirectory = Join-Path (Split-Path -Parent $SummaryDirectory) 'wireless-full'
}

# External helper uses loose scope semantics.
Set-StrictMode -Off
. $exportFnPath

$clients = @(Get-Content -LiteralPath $clientJsonPath -Raw | ConvertFrom-Json)
$aps = @(Get-Content -LiteralPath $apJsonPath -Raw | ConvertFrom-Json)
$wlans = @(Get-Content -LiteralPath $wlanJsonPath -Raw | ConvertFrom-Json)
$rogueProximity = @()
if ($IncludeRogues -and (Test-Path -LiteralPath $rogueProximityJsonPath)) {
    $rogueProximity = @(Get-Content -LiteralPath $rogueProximityJsonPath -Raw | ConvertFrom-Json)
}

# Unwrap PS5.1 ConvertFrom-Json array nesting
if ($clients.Count -eq 1 -and $clients[0] -is [System.Object[]]) { $clients = $clients[0] }
if ($aps.Count -eq 1 -and $aps[0] -is [System.Object[]]) { $aps = $aps[0] }
if ($wlans.Count -eq 1 -and $wlans[0] -is [System.Object[]]) { $wlans = $wlans[0] }
if ($rogueProximity.Count -eq 1 -and $rogueProximity[0] -is [System.Object[]]) { $rogueProximity = $rogueProximity[0] }
$dataset = $null
if (Test-Path -LiteralPath $datasetJsonPath) {
    $dataset = Get-Content -LiteralPath $datasetJsonPath -Raw | ConvertFrom-Json
}

$apByMac = @{}
foreach ($ap in $aps) {
    $k = (Normalize-String $ap.APMac).ToUpperInvariant()
    if (-not [string]::IsNullOrWhiteSpace($k) -and -not $apByMac.ContainsKey($k)) { $apByMac[$k] = $ap }
}

$wlanByProfile = @{}
foreach ($w in $wlans) {
    $k = Normalize-String $w.ProfileName
    if (-not [string]::IsNullOrWhiteSpace($k) -and -not $wlanByProfile.ContainsKey($k)) { $wlanByProfile[$k] = $w }
}

$clientsDashboard = foreach ($c in $clients) {
    $apMac = (Normalize-String $c.APMac).ToUpperInvariant()
    $ap = if ($apByMac.ContainsKey($apMac)) { $apByMac[$apMac] } else { $null }
    $wlanProfileName = Normalize-String $c.WlanProfileName
    $wlan = if ($wlanByProfile.ContainsKey($wlanProfileName)) { $wlanByProfile[$wlanProfileName] } else { $null }
    $status = Normalize-String $c.Status

    [PSCustomObject]@{
        ClientMac = Normalize-String $c.ClientMac
        ClientIP = Normalize-String $c.ClientIP
        Username = Normalize-DisplayKey $c.Username
        SSID = Normalize-DisplayKey $c.SSID
        WlanProfileName = Normalize-DisplayKey $wlanProfileName
        Status = $status
        BestState = Get-ClientBestState -Status $status
        DeviceType = Normalize-String $c.DeviceType
        AuthMode = Normalize-String $c.AuthMode
        AccessVLAN = Normalize-String $c.AccessVLAN
        Channel = Normalize-String $c.Channel
        APName = if ($null -ne $ap) { Normalize-String $ap.APName } else { '' }
        APMac = Normalize-String $c.APMac
        APControllerPrimary = if ($null -ne $ap) { Normalize-String $ap.PrimaryControllerAddress } else { '' }
        APControllerSecondary = if ($null -ne $ap) { Normalize-String $ap.SecondaryControllerAddress } else { '' }
    }
}
$clientsDashboard = @($clientsDashboard | Sort-Object SSID, APName, ClientMac)
$clientsDashboard = Remove-UnpopulatedColumns -Rows $clientsDashboard -KeepFields @('ClientMac','ClientIP','Username','SSID','WlanProfileName','Status','BestState','APName','APMac') -DatasetName 'clients'

$clientsByAp = @{}
foreach ($row in $clientsDashboard) {
    $k = (Normalize-String $row.APMac).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($k)) { continue }
    if (-not $clientsByAp.ContainsKey($k)) { $clientsByAp[$k] = New-Object System.Collections.Generic.List[object] }
    $clientsByAp[$k].Add($row)
}

$bssidDashboard = foreach ($bssid in $clientsByAp.Keys) {
    $cl = @($clientsByAp[$bssid].ToArray())
    $ssidGroups = @($cl | Group-Object SSID | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Sort-Object Count -Descending)
    $profileGroups = @($cl | Group-Object WlanProfileName | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Sort-Object Count -Descending)
    $topSsid = if ($ssidGroups.Count -gt 0) { $ssidGroups[0].Name } else { '' }
    $profiles = @($profileGroups | Select-Object -First 5 -ExpandProperty Name) -join ', '
    $sampleApName = @($cl | Where-Object { -not [string]::IsNullOrWhiteSpace($_.APName) } | Select-Object -First 1 -ExpandProperty APName)

    [PSCustomObject]@{
        BSSIDMac = $bssid
        APNameHint = if ($sampleApName.Count -gt 0) { $sampleApName[0] } else { '' }
        ClientCount = @($cl).Count
        DistinctSsidCount = @($ssidGroups).Count
        TopSSID = $topSsid
        TopProfiles = $profiles
        BestState = if (@($cl).Count -gt 0) { 'active' } else { 'idle' }
    }
}
$bssidDashboard = @($bssidDashboard | Sort-Object -Property @(
    @{ Expression = 'ClientCount'; Descending = $true },
    @{ Expression = 'BSSIDMac'; Descending = $false }
))

$apDashboard = @()
if ($dataset -and $dataset.PSObject.Properties.Name -contains 'ApOperational' -and @($dataset.ApOperational).Count -gt 0) {
    $apDashboard = @($dataset.ApOperational | ForEach-Object {
        [PSCustomObject]@{
            APName = Normalize-String $_.APName
            APMac = Normalize-String $_.APMac
            Dot11Slots = Normalize-String $_.Dot11Slots
            ClientCount = $_.ClientCount
            DistinctSsidCount = $_.DistinctSsidCount
            TopSSID = Normalize-String $_.TopSSID
            ControllerPrimary = Normalize-String $_.ControllerPrimary
            ControllerSecondary = Normalize-String $_.ControllerSecondary
            ControllerTertiary = Normalize-String $_.ControllerTertiary
            SiteTagName = Normalize-String $_.SiteTagName
            RfTagName = Normalize-String $_.RfTagName
            PolicyTagName = Normalize-String $_.PolicyTagName
            DomainName = Normalize-String $_.DomainName
            FilterName = Normalize-String $_.FilterName
            UsbSerialNumber = Normalize-String $_.UsbSerialNumber
            ApUptime = Normalize-String $_.ApUptime
            LastChange = Normalize-String $_.LastChange
            BestState = Normalize-String $_.BestState
            AdminStatus = Normalize-String $_.AdminStatus
            PowerStatus = Normalize-String $_.PowerStatus
            FailoverPriority = Normalize-String $_.FailoverPriority
            LastRebootReason = Normalize-String $_.LastRebootReason
            SubMode = Normalize-String $_.SubMode
            AntennaBandMode = Normalize-String $_.AntennaBandMode
            CpuCurrentPct = Normalize-String $_.CpuCurrentPct
            CpuAvgPct = Normalize-String $_.CpuAvgPct
            MemCurrentPct = Normalize-String $_.MemCurrentPct
            MemAvgPct = Normalize-String $_.MemAvgPct
            AssocClientCount = Normalize-String $_.AssocClientCount
            ActiveClientCount = Normalize-String $_.ActiveClientCount
        }
    })
} else {
    $apDashboard = foreach ($ap in $aps) {
        $apMac = (Normalize-String $ap.APMac).ToUpperInvariant()
        $cl = @()
        if (-not [string]::IsNullOrWhiteSpace($apMac) -and $clientsByAp.ContainsKey($apMac)) {
            $cl = @($clientsByAp[$apMac].ToArray())
        }
        $ssidGroups = $cl | Group-Object SSID | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Sort-Object Count -Descending
        $topSsid = if ($ssidGroups) { $ssidGroups[0].Name } else { '' }

        [PSCustomObject]@{
            APName = Normalize-String $ap.APName
            APMac = Normalize-String $ap.APMac
            Dot11Slots = Normalize-String $ap.Dot11Slots
            ClientCount = @($cl).Count
            DistinctSsidCount = @($ssidGroups).Count
            TopSSID = $topSsid
            ControllerPrimary = Normalize-String $ap.PrimaryControllerAddress
            ControllerSecondary = Normalize-String $ap.SecondaryControllerAddress
            ControllerTertiary = Normalize-String $ap.TertiaryControllerAddress
            SiteTagName = Normalize-String $ap.SiteTagName
            RfTagName = Normalize-String $ap.RfTagName
            PolicyTagName = Normalize-String $ap.PolicyTagName
            DomainName = Normalize-String $ap.DomainName
            FilterName = Normalize-String $ap.FilterName
            UsbSerialNumber = Normalize-String $ap.UsbSerialNumber
            ApUptime = Normalize-String $ap.ApUptime
            LastChange = Normalize-String $ap.LastChange
            BestState = if (@($cl).Count -gt 0) { 'active' } else { 'idle' }
            AdminStatus = Normalize-String $ap.AdminStatus
            PowerStatus = Normalize-String $ap.PowerStatus
            FailoverPriority = Normalize-String $ap.FailoverPriority
            LastRebootReason = Normalize-String $ap.LastRebootReason
            SubMode = Normalize-String $ap.SubMode
            AntennaBandMode = Normalize-String $ap.AntennaBandMode
            CpuCurrentPct = Normalize-String $ap.CpuCurrentPct
            CpuAvgPct = Normalize-String $ap.CpuAvgPct
            MemCurrentPct = Normalize-String $ap.MemCurrentPct
            MemAvgPct = Normalize-String $ap.MemAvgPct
            AssocClientCount = Normalize-String $ap.AssocClientCount
            ActiveClientCount = Normalize-String $ap.ActiveClientCount
        }
    }
}
$apDashboard = @($apDashboard | Sort-Object -Property @(
    @{ Expression = 'ClientCount'; Descending = $true },
    @{ Expression = 'APName'; Descending = $false }
))
$apDashboard = Remove-UnpopulatedColumns -Rows $apDashboard -KeepFields @('APName','APMac','ClientCount','DistinctSsidCount','TopSSID','BestState') -DatasetName 'aps'

$apJoinCount = @($apDashboard | Where-Object { [int]$_.ClientCount -gt 0 }).Count
if ($apJoinCount -eq 0) {
    Write-Warning 'No client-to-AP joins were found; AP client/SSID rollups will be marked as unavailable for this run.'
    $apDashboard = @($apDashboard | ForEach-Object {
        [PSCustomObject]@{
            APName = $_.APName
            APMac = $_.APMac
            Dot11Slots = $_.Dot11Slots
            ClientCount = ''
            DistinctSsidCount = ''
            TopSSID = 'unavailable'
            ControllerPrimary = $_.ControllerPrimary
            ControllerSecondary = $_.ControllerSecondary
            ControllerTertiary = $_.ControllerTertiary
            ApUptime = $_.ApUptime
            LastChange = $_.LastChange
            BestState = $_.BestState
        }
    })
}

$clientsByWlan = @{}
foreach ($row in $clientsDashboard) {
    $wlanProfileName = Normalize-String $row.WlanProfileName
    if (-not $clientsByWlan.ContainsKey($wlanProfileName)) { $clientsByWlan[$wlanProfileName] = New-Object System.Collections.Generic.List[object] }
    $clientsByWlan[$wlanProfileName].Add($row)
}

$wlanDashboard = foreach ($w in $wlans) {
    $wlanProfileName = Normalize-String $w.ProfileName
    $cl = @()
    if (-not [string]::IsNullOrWhiteSpace($wlanProfileName) -and $clientsByWlan.ContainsKey($wlanProfileName)) {
        $cl = @($clientsByWlan[$wlanProfileName].ToArray())
    }
    $apCount = @($cl | Group-Object APMac | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) }).Count
    $statusText = Get-RowStatusLabel -Code (Normalize-String $w.RowStatus)
    [PSCustomObject]@{
        WlanIndex = Normalize-String $w.WlanIndex
        ProfileName = $wlanProfileName
        SSID = Normalize-String $w.SSID
        ClientCount = @($cl).Count
        APCount = $apCount
        RowStatusCode = Normalize-String $w.RowStatus
        RowStatus = $statusText
        IsWired = Normalize-String $w.IsWired
        NACSupport = Normalize-String $w.NACSupport
        MaxClientsAllowedPerRadio = Normalize-String $w.MaxClientsAllowedPerRadio
        BestState = if ($statusText -eq 'active') { 'active' } else { 'warning' }
    }
}
$wlanDashboard = @($wlanDashboard | Sort-Object -Property @(
    @{ Expression = 'ClientCount'; Descending = $true },
    @{ Expression = 'ProfileName'; Descending = $false }
))
$wlanDashboard = Remove-UnpopulatedColumns -Rows $wlanDashboard -KeepFields @('WlanIndex','ProfileName','SSID','ClientCount','APCount','RowStatus','BestState') -DatasetName 'wlans'

$rootCoverage = @()
foreach ($file in $rootSummaryFiles) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $rows = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
    foreach ($r in $rows) {
        $varCount = 0
        try { $varCount = [int]$r.VariableCount } catch { $varCount = 0 }
        $health = if ($varCount -eq 0) { 'empty' } elseif ($varCount -lt 100) { 'small' } else { 'active' }
        $rootCoverage += [PSCustomObject]@{
            Root = Normalize-String $r.Root
            TableRelativePath = Normalize-String $r.TableRelativePath
            TableOidPrefix = Normalize-String $r.TableOidPrefix
            VariableCount = $varCount
            DistinctColumnCount = Normalize-String $r.DistinctColumnCount
            DistinctIndexCount = Normalize-String $r.DistinctIndexCount
            TypeBreakdown = Normalize-String $r.TypeBreakdown
            BestState = $health
        }
    }
}
$rootCoverage = if ($IncludeRogues) {
    @($rootCoverage)
} else {
    @($rootCoverage | Where-Object { $_.Root -ne 'rogue' })
}
$rootCoverage = @($rootCoverage | Sort-Object -Property @(
    @{ Expression = 'VariableCount'; Descending = $true },
    @{ Expression = 'Root'; Descending = $false }
))

$rogueTables = @($rootCoverage | Where-Object { $_.Root -eq 'rogue' } | Sort-Object VariableCount -Descending)

$rogueVariables = @()
$rogueJsonlPath = Join-Path $FullDirectory 'wireless-rogue.jsonl'
if ($IncludeRogues -and (Test-Path -LiteralPath $rogueJsonlPath)) {
    $reader = [System.IO.StreamReader]::new($rogueJsonlPath)
    try {
        $count = 0
        while (($null -ne ($line = $reader.ReadLine())) -and $count -lt $RogueVariableLimit) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $item = $line | ConvertFrom-Json
            $oid = Normalize-String $item.OID
            $type = Normalize-String $item.Type
            $value = Normalize-String $item.Value
            $hexValue = if ($item.PSObject.Properties.Name -contains 'HexValue') { Normalize-String $item.HexValue } else { '' }

            $rogueVariables += [PSCustomObject]@{
                TableRelativePath = Get-RogueTableRelativePath -Oid $oid
                OID = $oid
                Type = $type
                DisplayValue = Get-RogueDisplayValue -Type $type -Value $value -HexValue $hexValue
                HexValue = $hexValue
            }
            $count++
        }
    }
    finally {
        $reader.Dispose()
    }

    $rogueVariables = @($rogueVariables | Sort-Object TableRelativePath, OID)
    Write-Host "Built rogue variable view: $($rogueVariables.Count) rows (limit=$RogueVariableLimit)" -ForegroundColor Cyan
} elseif ($IncludeRogues) {
    Write-Warning "Rogue JSONL not found for detail dashboard: $rogueJsonlPath"
}

$dashboardDefs = @(
    [PSCustomObject]@{
        Name = 'clients'
        Title = 'Wireless Clients by SSID and State'
        Data = $clientsDashboard
        CardField = @('BestState','SSID')
        StatusField = 'BestState'
    },
    [PSCustomObject]@{
        Name = 'aps'
        Title = 'Wireless Access Point Health'
        Data = $apDashboard
        CardField = @('BestState')
        StatusField = 'BestState'
    },
    [PSCustomObject]@{
        Name = 'bssid-activity'
        Title = 'Wireless BSSID Activity (Client-Reported)'
        Data = $bssidDashboard
        CardField = @('BestState')
        StatusField = 'BestState'
    },
    [PSCustomObject]@{
        Name = 'wlans'
        Title = 'Wireless WLAN Inventory and Load'
        Data = $wlanDashboard
        CardField = @('BestState')
        StatusField = 'BestState'
    },
    [PSCustomObject]@{
        Name = 'coverage'
        Title = 'Wireless SNMP Table Coverage'
        Data = $rootCoverage
        CardField = @('Root','BestState')
        StatusField = 'BestState'
    },
    [PSCustomObject]@{
        Name = 'rogue-proximity'
        Title = 'Detected Rogue Access Points'
        Data = $rogueProximity
        CardField = @('SSID','Channel')
        StatusField = ''
    }
)

if (-not $IncludeRogues) {
    $dashboardDefs = @($dashboardDefs | Where-Object { $_.Name -ne 'rogue-proximity' })
}

if (-not $IncludeCoverageDashboard) {
    $dashboardDefs = @($dashboardDefs | Where-Object { $_.Name -ne 'coverage' })
}

$artifactRows = @()
foreach ($d in $dashboardDefs) {
    if (@($d.Data).Count -eq 0) {
        Write-Warning "Skipping dashboard '$($d.Name)' because it has no rows."
        continue
    }

    $htmlPath = Join-Path $OutputDirectory ("wireless-dashboard-$($d.Name).html")
    $jsonPath = Join-Path $OutputDirectory ("wireless-dashboard-$($d.Name)-data.json")

    $finalTitle = $d.Title

    $null = Export-Dashboard `
        -Data @($d.Data) `
        -OutputHtmlPath $htmlPath `
        -OutputJsonPath $jsonPath `
        -ReportTitle $finalTitle `
        -CardField $d.CardField `
        -StatusField $d.StatusField `
        -ExportPrefix ("wireless_dashboard_$($d.Name)") `
        -TemplatePath $templatePath `
        -IndexUrl 'wireless-dashboard-index.html' `
        -Offline:$Offline

    $kpisForHeader = $null
    if ($dataset -and $dataset.Kpis) {
        $kpisForHeader = $dataset.Kpis
    }

    Add-DashboardPageHeader `
        -HtmlPath $htmlPath `
        -Title $d.Title `
        -ViewName $d.Name `
        -RowCount @($d.Data).Count `
        -Kpis $kpisForHeader

    $artifactRows += [PSCustomObject]@{
        Dashboard = $d.Name
        Title = $d.Title
        Rows = @($d.Data).Count
        Html = $htmlPath
        DataJson = $jsonPath
    }

    Write-Host "Generated dashboard: $($d.Name) ($(@($d.Data).Count) rows)" -ForegroundColor Green
}

if ($Offline -and $artifactRows.Count -gt 0) {
    Publish-OfflineDependencies `
        -SourceDirectory $dependencySourceDirectory `
        -DestinationDirectory (Join-Path $OutputDirectory 'dependency') `
        -HtmlPaths @($artifactRows | ForEach-Object { $_.Html })
}

$indexPath = Join-Path $OutputDirectory 'wireless-dashboard-index.html'
$indexRowsHtml = ($artifactRows | ForEach-Object {
    $name = [System.IO.Path]::GetFileName($_.Html)
    $title = $_.Title
    $rows = $_.Rows
    '<tr><td><a href="{0}">{1}</a></td><td>{2}</td><td>{0}</td></tr>' -f $name, $title, $rows
}) -join [Environment]::NewLine

$indexContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Wireless Dashboard Index</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; background: #f6f8fb; color: #1f2937; }
    .wrap { background: #fff; border: 1px solid #d1d5db; border-radius: 10px; padding: 20px; max-width: 1100px; }
    h1 { margin-top: 0; font-size: 1.4rem; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #e5e7eb; padding: 10px; text-align: left; }
    th { background: #f3f4f6; }
    a { color: #2563eb; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .hint { color: #4b5563; margin-bottom: 14px; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Wireless Dashboard Pack</h1>
    <p class="hint">Distinct dashboards generated from linked wireless datasets. Join keys included in tables (AP MAC, AP Name, WLAN profile/SSID) so cross-navigation can happen via filtering/search.</p>
    <table>
      <thead>
        <tr><th>Dashboard</th><th>Rows</th><th>File</th></tr>
      </thead>
      <tbody>
$indexRowsHtml
      </tbody>
    </table>
  </div>
</body>
</html>
"@

$indexContent | Out-File -LiteralPath $indexPath -Encoding UTF8

$manifestPath = Join-Path $OutputDirectory 'wireless-dashboard-pack-manifest.json'
($artifactRows | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $manifestPath -Encoding UTF8

if (-not $IncludeRogues) {
    foreach ($stale in @(
        'wireless-dashboard-rogue-proximity.html',
        'wireless-dashboard-rogue-proximity-data.json'
    )) {
        $stalePath = Join-Path $OutputDirectory $stale
        if (Test-Path -LiteralPath $stalePath) {
            Remove-Item -LiteralPath $stalePath -Force
        }
    }
}

# Clean up old rogue-tables and rogue-variables dashboards (replaced by rogue-proximity)
foreach ($stale in @(
    'wireless-dashboard-rogue-tables.html',
    'wireless-dashboard-rogue-tables-data.json',
    'wireless-dashboard-rogue-variables.html',
    'wireless-dashboard-rogue-variables-data.json'
)) {
    $stalePath = Join-Path $OutputDirectory $stale
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

Write-Host ''
Write-Host 'Wireless dashboard pack export complete.' -ForegroundColor Green
Write-Host "Dashboards directory: $OutputDirectory" -ForegroundColor Green
Write-Host "Index: $indexPath" -ForegroundColor Green
Write-Host "Manifest: $manifestPath" -ForegroundColor Green

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDmE8OPeWphxzmP
# hmEPlJd78ZofUbLYYHQArcRxu+bRIqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCDLqFZTczclIap1aEtJNxfDLyZeVJGullye+YKYJclgGTANBgkqhkiG9w0BAQEF
# AASCAgBikKjw98WcoHzWRFWlJNGfgyYSNPXRpcBHuPLHa31CQw240NPBVroekixT
# uSR/3IxaoG7idhfl+6yRm0FUm7wyl4STHObuIn49KcEw+i1sF69yX6oA9EVRw8Ws
# 8PNhOcOic8MbE9cgGxp7IpvPC3+gOE8XkB8rISsbXXWWdiIgEBZh46siuwvxvp18
# FrvGrv2nvXlU+2iv8QLxDV7SK7bTDw+GE5Irto/HPJ8gvHtnS2RXS6D/HOZpAaeC
# RvESN3WxLQTTvmgx4NNFHNSCbIbMWzNJfmALWiMNWXwygdtdcQx5mDfykEEXjJlA
# OOBhbR5/Smj0R0O/4nP/SsRDq3mFDun7e1i/DfASwo7KTetVCZwzdkWe/xzYJibj
# w9yQTf4W8NNC00CIDiecgFWAYrGrMHqEGuryuVNVdjqxLvhu/LK3gYrJWMpS3YSm
# FCkkwKhk2mI5Owa6IE+ue6hvCOz+0LOyKYofnMSC+xx/sRrndNOFi/ediS0vVUj/
# ftUZumEcLM7AAU2ZPuiei31surTkVVX2zQ2Pv/x7AUdZvOjKkMA7sF1RLo+CgaN7
# 8+1HupE5tBbW7rJQWcxSxZmbUC7g+JsdVrDoac0/lNK+IWzRSC9OyHuWgWEL5vHv
# 2vdFuR6S7LeK48YzWcWhevHLCx2QE2T3M7/bmZjDMLhcHYl53aGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA2MjUxNjA1NDZaMC8GCSqGSIb3DQEJBDEiBCCqeLGb
# tRxfnZdxeazYBUM6RtVzke0GL/BYGNqFCkW6+jANBgkqhkiG9w0BAQEFAASCAgBI
# x8ufdLT/qlzcmm6Alxdw4EOl2FGSMYy/2fLbgCVzfM887hwGUHOFIZBikQdSsg6J
# y47HOmfb+eVE47JwwV0ax3RmPgqamIwCZltoFJHtDulB7As2OIycCeL9b0MYabI+
# pNAxgib9oqxTpwX0o9yNOykUgxHXDiRaE1oduyS9LHCdVEqGi0tJo0ul6T3EKO4p
# EkL+lyUYoNGHmRc3wXlCKch4eY5t7Ff3sF29sPkLm2N7ifmcdZgd2kP49Rt4nVLJ
# rKnAhmIaPf6T3Rv4cuVfoXay684LSgkn/DE6vYC8Pf0poJTxn4eyf8jH/eIAv1wn
# QGRNhr7WXe4zE52eala/yqeMTLznrTHTjxuHu6s4hR7VbW6ep7mOmN1976hhtFZN
# BlCdWJxUsV/sinJsswTmoNjw03phLfw7ZaNB7iCckhtT/ncmAwneAbACiiDwh6aM
# IM8dCGI03Vn6JkhfyZeX+0QY2C6uI4Xd3QbLyBC7wVZ/m9Gu2iXHRneVsgoU3DeF
# xtFcHBF+KF/ZPKiBjISJuHOFr1QyZVZOp4p2NQN5FLgDduwu10G0OPwFjtD3NGA5
# G8MqO6wQlIvBQXd7mQOCaRI0D5mgiZYyVY67LHT1CZ0NkVCr0SxwXfSK23Og5X5a
# ceH6VXPVP3GWX8WQcbdvBpHg6hsD2zz0/+SBAB0xxQ==
# SIG # End signature block
