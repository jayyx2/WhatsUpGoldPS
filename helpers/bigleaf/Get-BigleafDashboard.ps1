# =============================================================================
# Bigleaf Dashboard Report Generator
# Uses BigleafHelpers.ps1 to connect to the Bigleaf Cloud Connect API,
# retrieve site/circuit/risk status, and produce an interactive HTML
# dashboard showing WAN health and optional WhatsUp Gold device enrichment.
#
# Prerequisites:
#   - PowerShell 5.1+ or PowerShell 7+
#   - Bigleaf API credentials (username + password or API token)
#   - Network access to https://api.bigleaf.net
#
# Usage:
#   .\Get-BigleafDashboard.ps1                                       # Prompts for credentials
#   .\Get-BigleafDashboard.ps1 -Credential (Get-Credential)          # Supply credentials directly
#   .\Get-BigleafDashboard.ps1 -UseWUGDevices                        # Enrich with WhatsUp Gold data
#   # Then open the generated HTML file in a browser.
# =============================================================================

param (
    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$BaseUri = "https://api.bigleaf.net/v2",

    [Parameter(Mandatory = $false)]
    [switch]$UseWUGDevices,

    [Parameter(Mandatory = $false)]
    [string]$WUGServerUri,

    [Parameter(Mandatory = $false)]
    [pscredential]$WUGCredential,

    [Parameter(Mandatory = $false)]
    [string]$ReportTitle = "Bigleaf Dashboard"
)

# --- Configuration -----------------------------------------------------------
# Dot-source the Bigleaf helpers
$helpersPath = Join-Path $PSScriptRoot "BigleafHelpers.ps1"
if (Test-Path $helpersPath) {
    . $helpersPath
}
else {
    throw "BigleafHelpers.ps1 not found at $helpersPath. Ensure it is in the same directory."
}

# Import WhatsUpGoldPS module if available (for WUG integration)
if (Get-Module -ListAvailable -Name WhatsUpGoldPS) {
    if (-not (Get-Module -Name WhatsUpGoldPS)) {
        Import-Module -Name WhatsUpGoldPS
    }
}

# --- Authenticate to Bigleaf -------------------------------------------------
if (-not $global:BigleafHeaders) {
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter Bigleaf API credentials (username + password or API token)"
    }
    Connect-BigleafAPI -Credential $Credential -BaseUri $BaseUri
}

# --- Optional: Connect to WhatsUp Gold for enrichment -----------------------
if ($UseWUGDevices -and -not $global:WUGBearerHeaders) {
    if (-not $WUGServerUri) {
        $WUGServerUri = Read-Host -Prompt "Enter WhatsUp Gold server URI (e.g. 192.168.1.100)"
    }
    if (-not $WUGCredential) {
        $WUGCredential = Get-Credential -Message "Enter WhatsUp Gold credentials"
    }
    Connect-WUGServer -serverUri $WUGServerUri -Credential $WUGCredential -IgnoreSSLErrors -Protocol https
}

# Output paths
$outputDir = if ($env:TEMP) { $env:TEMP } else { "C:\temp" }
$jsonPath  = Join-Path $outputDir "bigleaf_dashboard.json"
$htmlPath  = Join-Path $outputDir "Bigleaf-Dashboard.html"

# Ensure output directory exists
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- Build dashboard data ----------------------------------------------------
$dashboardData = Get-BigleafDashboard

if (-not $dashboardData -or $dashboardData.Count -eq 0) {
    Write-Warning "No dashboard data generated. Exiting."
    return
}

# Summary
$healthy     = @($dashboardData | Where-Object { $_.SiteStatus -eq 'healthy' }).Count
$circuitIss  = @($dashboardData | Where-Object { $_.SiteStatus -eq 'circuit-issues' }).Count
$offline     = @($dashboardData | Where-Object { $_.SiteStatus -eq 'offline' }).Count
$provisioning = @($dashboardData | Where-Object { $_.SiteStatus -eq 'provisioning' }).Count
$withRisks   = @($dashboardData | Where-Object { $_.RiskCount -gt 0 }).Count

Write-Host "`n--- Bigleaf Site Health Summary ---" -ForegroundColor Yellow
Write-Host "  Total:            $($dashboardData.Count)" -ForegroundColor White
if ($healthy     -gt 0) { Write-Host "  Healthy:          $healthy"      -ForegroundColor Green }
if ($circuitIss  -gt 0) { Write-Host "  Circuit Issues:   $circuitIss"   -ForegroundColor DarkYellow }
if ($offline     -gt 0) { Write-Host "  Offline:          $offline"      -ForegroundColor Red }
if ($provisioning -gt 0) { Write-Host "  Provisioning:     $provisioning" -ForegroundColor Cyan }
if ($withRisks   -gt 0) { Write-Host "  Sites with Risks: $withRisks"   -ForegroundColor Magenta }

# --- Generate outputs --------------------------------------------------------
# JSON export
$dashboardData | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Force -Encoding UTF8
Write-Host "`nJSON data written to $jsonPath" -ForegroundColor Yellow

# HTML dashboard
$templatePath = Join-Path $PSScriptRoot "Bigleaf-Dashboard-Template.html"
Export-BigleafDashboardHtml -DashboardData $dashboardData -OutputPath $htmlPath -ReportTitle $ReportTitle -TemplatePath $templatePath
Write-Host "HTML dashboard written to $htmlPath" -ForegroundColor Yellow

# --- Optional: Open in browser -----------------------------------------------
$openBrowser = Read-Host -Prompt "Open dashboard in browser? (Y/N)"
if ($openBrowser -match '^[Yy]') {
    Start-Process $htmlPath
}

Write-Host "`nDone." -ForegroundColor Green
