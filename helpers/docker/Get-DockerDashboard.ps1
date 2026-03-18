<#
.SYNOPSIS
    Generates an interactive HTML dashboard report for Docker Engine environments.
.DESCRIPTION
    Orchestration script that connects to one or more Docker Engine API endpoints,
    collects container details (CPU, memory, network, block I/O, ports), and
    produces a searchable, sortable Bootstrap Table HTML dashboard. Output
    includes both a JSON data file and a self-contained HTML report.
.PARAMETER DockerHosts
    One or more Docker host addresses (hostname or IP). If omitted, prompts interactively.
.PARAMETER Port
    Docker Engine API port. Defaults to 2375.
.PARAMETER UseTLS
    Use HTTPS instead of HTTP.
.PARAMETER SkipSSLCheck
    Bypass SSL certificate validation for self-signed certificates.
.EXAMPLE
    .\Get-DockerDashboard.ps1

    Prompts for Docker host(s), then generates the dashboard.
.EXAMPLE
    .\Get-DockerDashboard.ps1 -DockerHosts "docker01","docker02" -Port 2375

    Generates a dashboard for multiple Docker hosts.
.EXAMPLE
    .\Get-DockerDashboard.ps1 -DockerHosts "docker01" -Port 2376 -UseTLS -SkipSSLCheck

    Connects via TLS with self-signed cert bypass.
.OUTPUTS
    System.Void
    Produces a JSON file (docker_dashboard.json) and an HTML dashboard
    (Docker-Dashboard.html) in the system temp directory, then opens the HTML in the default browser.
.NOTES
    Author  : jason@wug.ninja
    Version : 1.0.0
    Date    : 2026-03-18
    Requires: PowerShell 5.1+, network access to Docker Engine API, DockerHelpers.ps1 in the same directory.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>

param (
    [Parameter(Mandatory = $false)]
    [string[]]$DockerHosts,

    [Parameter(Mandatory = $false)]
    [int]$Port = 2375,

    [Parameter(Mandatory = $false)]
    [switch]$UseTLS,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSSLCheck
)

# --- Configuration -----------------------------------------------------------
$helpersPath = Join-Path $PSScriptRoot "DockerHelpers.ps1"
if (Test-Path $helpersPath) {
    . $helpersPath
}
else {
    throw "DockerHelpers.ps1 not found at $helpersPath. Ensure it is in the same directory."
}

if (Get-Module -ListAvailable -Name WhatsUpGoldPS) {
    if (-not (Get-Module -Name WhatsUpGoldPS)) {
        Import-Module -Name WhatsUpGoldPS
    }
}

# --- Input prompts -----------------------------------------------------------
if (-not $DockerHosts -or $DockerHosts.Count -eq 0) {
    $hostInput = Read-Host -Prompt "Enter Docker host(s) - hostname or IP (comma-separated)"
    $DockerHosts = $hostInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

if (-not $DockerHosts -or $DockerHosts.Count -eq 0) {
    throw "At least one Docker host must be specified."
}

# Output paths
$outputDir = if ($env:TEMP) { $env:TEMP } else { "C:\temp" }
$jsonPath  = Join-Path $outputDir "docker_dashboard.json"
$htmlPath  = Join-Path $outputDir "Docker-Dashboard.html"
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- Connect and collect data ------------------------------------------------
$allData = @()

foreach ($host_ in $DockerHosts) {
    $scheme = if ($UseTLS) { 'https' } else { 'http' }
    Write-Host "Connecting to ${scheme}://${host_}:${Port} ..." -ForegroundColor Cyan
    try {
        $splat = @{ DockerHost = $host_; Port = $Port }
        if ($UseTLS) { $splat.UseTLS = $true }
        if ($SkipSSLCheck) { $splat.IgnoreSSLErrors = $true }
        $conn = Connect-DockerServer @splat
        Write-Host "  Connected: Docker $($conn.DockerVersion) on $($conn.OS) ($($conn.Arch))" -ForegroundColor Green

        $data = Get-DockerDashboard -Connection $conn
        if ($data) { $allData += $data }
        $containerCount = @($data | Where-Object { $_.Type -eq 'Container' }).Count
        Write-Host "  Collected $containerCount container(s) from $host_" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to connect to ${host_}: $($_.Exception.Message)"
    }
}

if (-not $allData -or $allData.Count -eq 0) {
    Write-Warning "No data collected. Exiting."
    return
}

# --- Summary -----------------------------------------------------------------
$hosts      = @($allData | Where-Object { $_.Type -eq 'Host' }).Count
$containers = @($allData | Where-Object { $_.Type -eq 'Container' }).Count
$running    = @($allData | Where-Object { $_.Type -eq 'Container' -and $_.Status -eq 'running' }).Count
$stopped    = $containers - $running

Write-Host "`n--- Docker Summary ---" -ForegroundColor Yellow
Write-Host "  Docker Hosts : $hosts"  -ForegroundColor Cyan
Write-Host "  Containers   : $containers"
Write-Host "  Running      : $running"  -ForegroundColor Green
Write-Host "  Stopped      : $stopped"  -ForegroundColor Red

# --- Generate outputs --------------------------------------------------------
$allData | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Force -Encoding UTF8
Write-Host "`nJSON data written to $jsonPath" -ForegroundColor Yellow

$templatePath = Join-Path $PSScriptRoot "Docker-Dashboard-Template.html"
Export-DockerDashboardHtml -DashboardData $allData -OutputPath $htmlPath -ReportTitle "Docker Engine Dashboard" -TemplatePath $templatePath
Write-Host "HTML dashboard written to $htmlPath" -ForegroundColor Yellow

# --- Optional: Open in browser -----------------------------------------------
$openBrowser = Read-Host -Prompt "Open dashboard in browser? (Y/N)"
if ($openBrowser -match '^[Yy]') {
    Start-Process $htmlPath
}

Write-Host "`nDone." -ForegroundColor Green
