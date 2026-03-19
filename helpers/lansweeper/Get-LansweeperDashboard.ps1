# ---------------------------------------------------------------------------
# Get-LansweeperDashboard.ps1
# Generates an interactive HTML dashboard of Lansweeper-discovered assets.
# ---------------------------------------------------------------------------
# Usage:
#   . .\LansweeperHelpers.ps1
#   .\Get-LansweeperDashboard.ps1
# ---------------------------------------------------------------------------

param(
    [string]$Token,
    [string]$SiteId,
    [string[]]$AssetTypeFilter,
    [switch]$IncludeVulnerabilities,
    [string]$OutputDir = $env:TEMP,
    [string]$ReportTitle = 'Lansweeper Asset Dashboard'
)

# Load helpers from the same directory
$helpersPath = Join-Path $PSScriptRoot 'LansweeperHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    Write-Error "LansweeperHelpers.ps1 not found at: $helpersPath"
    return
}
. $helpersPath

# ---- Authentication ----
if (-not $script:LansweeperSession.Connected) {
    if (-not $Token) {
        $Token = Read-Host -Prompt 'Enter your Lansweeper Personal Access Token'
    }
    if (-not $Token) {
        Write-Error "A Lansweeper PAT is required."
        return
    }
    Connect-LansweeperPAT -Token $Token
}

if (-not $script:LansweeperSession.Connected) {
    Write-Error "Failed to connect to Lansweeper. Check your token and try again."
    return
}

# ---- Discover sites if none specified ----
if (-not $SiteId) {
    Write-Host "`nAuthorized sites:" -ForegroundColor Cyan
    $sites = Get-LansweeperSites
    if (-not $sites -or $sites.Count -eq 0) {
        Write-Error "No authorized sites found for this API client."
        return
    }
    for ($i = 0; $i -lt $sites.Count; $i++) {
        Write-Host "  [$i] $($sites[$i].name) ($($sites[$i].id))"
    }
    $choice = Read-Host "`nEnter site number (or press Enter for all sites)"
    if ($choice -ne '' -and $choice -match '^\d+$') {
        $idx = [int]$choice
        if ($idx -ge 0 -and $idx -lt $sites.Count) {
            $SiteId = $sites[$idx].id
            Write-Host "Selected site: $($sites[$idx].name)" -ForegroundColor Green
        }
    }
}

# ---- Collect dashboard data ----
Write-Host "`nCollecting asset data..." -ForegroundColor Cyan
$dashParams = @{}
if ($SiteId)               { $dashParams.SiteId               = $SiteId }
if ($AssetTypeFilter)      { $dashParams.AssetTypeFilter      = $AssetTypeFilter }
if ($IncludeVulnerabilities) { $dashParams.IncludeVulnerabilities = $true }

$dashboardData = Get-LansweeperDashboardData @dashParams

if (-not $dashboardData -or $dashboardData.Count -eq 0) {
    Write-Warning "No assets returned. Check filters and site permissions."
    return
}

# ---- Statistics ----
$totalAssets  = $dashboardData.Count
$uniqueTypes  = ($dashboardData | Select-Object -ExpandProperty AssetType -Unique).Count
$withIP       = ($dashboardData | Where-Object { $_.IPAddress -and $_.IPAddress -ne 'N/A' }).Count
$uniqueSites  = ($dashboardData | Select-Object -ExpandProperty Site -Unique).Count

Write-Host "`n---- Lansweeper Dashboard Summary ----" -ForegroundColor Cyan
Write-Host "  Total assets:   $totalAssets"
Write-Host "  Asset types:    $uniqueTypes"
Write-Host "  With IP:        $withIP"
Write-Host "  Sites:          $uniqueSites"

# ---- Export JSON ----
$jsonPath = Join-Path $OutputDir 'lansweeper_dashboard.json'
$dashboardData | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host "`nJSON data saved to: $jsonPath" -ForegroundColor Green

# ---- Export HTML ----
$htmlPath = Join-Path $OutputDir 'Lansweeper-Dashboard.html'
Export-LansweeperDashboardHtml -DashboardData $dashboardData -OutputPath $htmlPath -ReportTitle $ReportTitle
Write-Host "HTML dashboard saved to: $htmlPath" -ForegroundColor Green

# ---- Optional: open in browser ----
$openBrowser = Read-Host "`nOpen dashboard in browser? (Y/N)"
if ($openBrowser -eq 'Y' -or $openBrowser -eq 'y') {
    Start-Process $htmlPath
}
