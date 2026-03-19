# ---------------------------------------------------------------------------
# discover-lansweeper-immediate-add-with-attributes.ps1
# Discovers assets from Lansweeper and adds them to WhatsUp Gold with
# custom attributes for Lansweeper metadata.
# ---------------------------------------------------------------------------
# Prerequisites:
#   - WhatsUpGoldPS module imported
#   - Lansweeper Personal Access Token (PAT) or OAuth credentials
# ---------------------------------------------------------------------------

param(
    [string]$WUGServer       = '192.168.1.250',
    [string]$LansweeperToken,
    [string]$LansweeperSiteId,
    [string[]]$AssetTypeFilter,
    [string]$WUGGroupName    = 'Lansweeper Assets',
    [switch]$IncludeMetrics
)

# ---- Load helpers ----
$helpersPath = Join-Path $PSScriptRoot 'LansweeperHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    Write-Error "LansweeperHelpers.ps1 not found at: $helpersPath"
    return
}
. $helpersPath

# ---- Authenticate to Lansweeper ----
if (-not $LansweeperToken) {
    $LansweeperToken = Read-Host -Prompt 'Enter your Lansweeper Personal Access Token'
}
if (-not $LansweeperToken) {
    Write-Error "A Lansweeper PAT is required."
    return
}
Connect-LansweeperPAT -Token $LansweeperToken

if (-not $script:LansweeperSession.Connected) {
    Write-Error "Failed to connect to Lansweeper."
    return
}

# ---- Authenticate to WhatsUp Gold ----
Write-Host "`nConnecting to WhatsUp Gold at $WUGServer..." -ForegroundColor Cyan
$WUGCred = Get-Credential -Message "Enter WhatsUp Gold credentials"
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# ---- Select Lansweeper site ----
if (-not $LansweeperSiteId) {
    $sites = Get-LansweeperSites
    if (-not $sites -or $sites.Count -eq 0) {
        Write-Error "No authorized Lansweeper sites found."
        return
    }
    Write-Host "`nAvailable Lansweeper sites:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $sites.Count; $i++) {
        Write-Host "  [$i] $($sites[$i].name) ($($sites[$i].id))"
    }
    $choice = Read-Host "Select site number"
    if ($choice -match '^\d+$') {
        $idx = [int]$choice
        if ($idx -ge 0 -and $idx -lt $sites.Count) {
            $LansweeperSiteId = $sites[$idx].id
        }
    }
    if (-not $LansweeperSiteId) {
        Write-Error "No site selected."
        return
    }
}

$siteInfo = Get-LansweeperSiteInfo -SiteId $LansweeperSiteId
Write-Host "Using Lansweeper site: $($siteInfo.name)" -ForegroundColor Green

# ---- Retrieve assets ----
Write-Host "`nRetrieving assets from Lansweeper..." -ForegroundColor Cyan

$assetFields = @(
    'assetBasicInfo.name',
    'assetBasicInfo.type',
    'assetBasicInfo.subType',
    'assetBasicInfo.typeGroup',
    'assetBasicInfo.ipAddress',
    'assetBasicInfo.mac',
    'assetBasicInfo.domain',
    'assetBasicInfo.description',
    'assetBasicInfo.firstSeen',
    'assetBasicInfo.lastSeen',
    'assetCustom.manufacturer',
    'assetCustom.model',
    'assetCustom.serialNumber',
    'assetCustom.dnsName',
    'assetCustom.stateName',
    'networks.ipAddressV4',
    'url'
)

$getParams = @{
    SiteId = $LansweeperSiteId
    Fields = $assetFields
    All    = $true
}

if ($AssetTypeFilter -and $AssetTypeFilter.Count -gt 0) {
    $conditions = @()
    foreach ($typeName in $AssetTypeFilter) {
        $conditions += @{ operator = 'EQUAL'; path = 'assetBasicInfo.type'; value = $typeName }
    }
    $getParams.Filters = @{ conjunction = 'OR'; conditions = $conditions }
}

$assets = Get-LansweeperAssets @getParams
Write-Host "Retrieved $($assets.Count) assets." -ForegroundColor Green

if (-not $assets -or $assets.Count -eq 0) {
    Write-Warning "No assets found matching criteria."
    return
}

# ---- Map Lansweeper asset types to WUG brand/OS ----
function Get-WUGBrandFromLansweeperType {
    param([string]$AssetType)
    switch -Wildcard ($AssetType) {
        'Windows'                   { return 'Microsoft' }
        'Server'                    { return 'Microsoft' }
        'Linux'                     { return 'Linux' }
        'Unix'                      { return 'Unix' }
        'ESXi server'               { return 'VMware' }
        'VMware*'                   { return 'VMware' }
        'Hyper-V*'                  { return 'Microsoft' }
        'Citrix*'                   { return 'Citrix' }
        'Apple Mac'                 { return 'Apple' }
        'Switch'                    { return 'Network' }
        'Router'                    { return 'Network' }
        'Firewall'                  { return 'Network' }
        'Wireless Access point'     { return 'Network' }
        'Printer'                   { return 'Printer' }
        'UPS'                       { return 'UPS' }
        'AWS EC2 Instance'          { return 'AWS' }
        'Azure Virtual Machine'     { return 'Azure' }
        'NAS'                       { return 'Storage' }
        'SAN'                       { return 'Storage' }
        'Load balancer'             { return 'Network' }
        default                     { return 'Other' }
    }
}

# ---- Add assets to WhatsUp Gold ----
$added = 0
$skipped = 0
$failed = 0

foreach ($asset in $assets) {
    $assetName = 'Unknown'
    $assetType = 'Unknown'
    $assetDesc = ''
    $assetDomain = ''
    $assetMac = ''
    $assetManufacturer = ''
    $assetModel = ''
    $assetSerial = ''

    if ($asset.assetBasicInfo) {
        $bi = $asset.assetBasicInfo
        if ($bi.name)        { $assetName   = "$($bi.name)" }
        if ($bi.type)        { $assetType   = "$($bi.type)" }
        if ($bi.description) { $assetDesc   = "$($bi.description)" }
        if ($bi.domain)      { $assetDomain = "$($bi.domain)" }
        if ($bi.mac)         { $assetMac    = "$($bi.mac)" }
    }
    if ($asset.assetCustom) {
        $ac = $asset.assetCustom
        if ($ac.manufacturer)  { $assetManufacturer = "$($ac.manufacturer)" }
        if ($ac.model)         { $assetModel        = "$($ac.model)" }
        if ($ac.serialNumber)  { $assetSerial       = "$($ac.serialNumber)" }
    }

    # Resolve IP address
    $ip = Resolve-LansweeperAssetIP -Asset $asset
    if (-not $ip) {
        Write-Warning "Skipping '$assetName' -- no IP address resolved."
        $skipped++
        continue
    }

    Write-Host "Adding: $assetName ($assetType) at $ip" -ForegroundColor White

    # Build custom attributes
    $assetKey = if ($asset.key) { "$($asset.key)" } else { '' }
    $assetUrl = if ($asset.url) { "$($asset.url)" } else { '' }
    $lastSeen = ''
    $firstSeen = ''
    if ($asset.assetBasicInfo) {
        if ($asset.assetBasicInfo.lastSeen) { $lastSeen = "$($asset.assetBasicInfo.lastSeen)" }
        if ($asset.assetBasicInfo.firstSeen) { $firstSeen = "$($asset.assetBasicInfo.firstSeen)" }
    }

    $attributes = @(
        @{ Name = 'Lansweeper_Source';       Value = 'Lansweeper' }
        @{ Name = 'Lansweeper_AssetKey';     Value = $assetKey }
        @{ Name = 'Lansweeper_AssetType';    Value = $assetType }
        @{ Name = 'Lansweeper_Site';         Value = "$($siteInfo.name)" }
        @{ Name = 'Lansweeper_SiteId';       Value = $LansweeperSiteId }
        @{ Name = 'Lansweeper_Domain';       Value = $assetDomain }
        @{ Name = 'Lansweeper_MAC';          Value = $assetMac }
        @{ Name = 'Lansweeper_Manufacturer'; Value = $assetManufacturer }
        @{ Name = 'Lansweeper_Model';        Value = $assetModel }
        @{ Name = 'Lansweeper_Serial';       Value = $assetSerial }
        @{ Name = 'Lansweeper_FirstSeen';    Value = $firstSeen }
        @{ Name = 'Lansweeper_LastSeen';     Value = $lastSeen }
        @{ Name = 'Lansweeper_Url';          Value = $assetUrl }
        @{ Name = 'Lansweeper_LastSync';     Value = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    )

    $brandName = Get-WUGBrandFromLansweeperType -AssetType $assetType

    $note = "Discovered by Lansweeper -- Site: $($siteInfo.name), Type: $assetType, Description: $assetDesc, Key: $assetKey"

    try {
        $newDeviceId = Add-WUGDeviceTemplate `
            -displayName $assetName `
            -DeviceAddress $ip `
            -Brand $brandName `
            -OS $assetType `
            -ActiveMonitors @('Ping') `
            -PerformanceMonitors @('Ping Latency and Availability') `
            -Attributes $attributes `
            -Note $note

        if ($newDeviceId) {
            Write-Host "  Added device ID: $newDeviceId" -ForegroundColor Green
            $added++
        } else {
            Write-Warning "  Failed to add '$assetName'."
            $failed++
        }
    }
    catch {
        Write-Warning "  Error adding '$assetName': $_"
        $failed++
    }
}

# ---- Summary ----
Write-Host "`n---- Discovery Summary ----" -ForegroundColor Cyan
Write-Host "  Total assets:  $($assets.Count)"
Write-Host "  Added to WUG:  $added"
Write-Host "  Skipped:       $skipped (no IP)"
Write-Host "  Failed:        $failed"

# ---- Cleanup ----
Disconnect-WUGServer
Disconnect-Lansweeper
Write-Host "`nDone." -ForegroundColor Green
