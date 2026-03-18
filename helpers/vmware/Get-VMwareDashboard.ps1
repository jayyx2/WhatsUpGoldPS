<#
.SYNOPSIS
    Generates an interactive HTML dashboard report for VMware vSphere environments.
.DESCRIPTION
    Orchestration script that connects to a vCenter Server or ESXi host,
    collects cluster, datastore, host, and VM details (CPU, memory, disk,
    network, performance metrics), and produces a searchable, sortable
    Bootstrap Table HTML dashboard. Output includes both a JSON data file
    and a self-contained HTML report.
.PARAMETER VMwareServer
    The hostname or IP address of the vCenter Server or ESXi host.
    If omitted, prompts interactively.
.PARAMETER VMwareCredential
    A PSCredential for authenticating to the vSphere environment.
    If omitted, prompts interactively via Get-Credential.
.PARAMETER IgnoreSSLErrors
    Skip SSL certificate validation for self-signed certificates.
.EXAMPLE
    .\Get-VMwareDashboard.ps1

    Prompts for vCenter host and credentials, then generates the dashboard.
.EXAMPLE
    .\Get-VMwareDashboard.ps1 -VMwareServer "vcenter01.lab.local" -VMwareCredential (Get-Credential)

    Generates a dashboard for a specific vCenter Server.
.EXAMPLE
    .\Get-VMwareDashboard.ps1 -VMwareServer "192.168.1.100" -IgnoreSSLErrors

    Connects with self-signed cert bypass.
.OUTPUTS
    System.Void
    Produces a JSON file (vmware_dashboard.json) and an HTML dashboard
    (VMware-Dashboard.html) in the system temp directory, then opens the HTML in the default browser.
.NOTES
    Author  : jason@wug.ninja
    Version : 1.0.0
    Date    : 2026-03-17
    Requires: PowerShell 5.1+, VMware PowerCLI, VMwareHelpers.ps1 in the same directory.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$VMwareServer,

    [Parameter(Mandatory = $false)]
    [pscredential]$VMwareCredential,

    [Parameter(Mandatory = $false)]
    [switch]$IgnoreSSLErrors
)

# --- Configuration -----------------------------------------------------------
$helpersPath = Join-Path $PSScriptRoot "VMwareHelpers.ps1"
if (Test-Path $helpersPath) {
    . $helpersPath
}
else {
    throw "VMwareHelpers.ps1 not found at $helpersPath. Ensure it is in the same directory."
}

if (Get-Module -ListAvailable -Name WhatsUpGoldPS) {
    if (-not (Get-Module -Name WhatsUpGoldPS)) {
        Import-Module -Name WhatsUpGoldPS
    }
}

# --- Input prompts -----------------------------------------------------------
if (-not $VMwareServer) {
    $VMwareServer = Read-Host -Prompt "Enter vCenter / ESXi hostname or IP"
}

if (-not $VMwareServer -or $VMwareServer.Trim() -eq '') {
    throw "A vCenter or ESXi host must be specified."
}

if (-not $VMwareCredential) {
    $VMwareCredential = Get-Credential -Message "Enter VMware vSphere credentials"
}

# Output paths
$outputDir = if ($env:TEMP) { $env:TEMP } else { "C:\temp" }
$jsonPath  = Join-Path $outputDir "vmware_dashboard.json"
$htmlPath  = Join-Path $outputDir "VMware-Dashboard.html"
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- Connect and collect data ------------------------------------------------
Write-Host "Connecting to $VMwareServer ..." -ForegroundColor Cyan
try {
    $splat = @{ Server = $VMwareServer; Credential = $VMwareCredential }
    if ($IgnoreSSLErrors) { $splat["IgnoreSSLErrors"] = $true }
    $connection = Connect-VMware @splat
    Write-Host "  Connected to $VMwareServer ($($connection.ProductLine) $($connection.Version))" -ForegroundColor Green
}
catch {
    throw "Failed to connect to ${VMwareServer}: $($_.Exception.Message)"
}

Write-Host "`nCollecting host and VM data..." -ForegroundColor Cyan
$dashboardData = Get-VMwareDashboard

if (-not $dashboardData -or $dashboardData.Count -eq 0) {
    Write-Warning "No data collected. Exiting."
    Disconnect-VMware -ErrorAction SilentlyContinue
    return
}

# --- Summary -----------------------------------------------------------------
$hosts      = @($dashboardData | Where-Object { $_.Type -eq 'Host' }).Count
$vms        = @($dashboardData | Where-Object { $_.Type -eq 'VM' }).Count
$poweredOn  = @($dashboardData | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
$poweredOff = @($dashboardData | Where-Object { $_.PowerState -eq 'PoweredOff' }).Count
$suspended  = $dashboardData.Count - $poweredOn - $poweredOff

Write-Host "`n--- VMware Summary ---" -ForegroundColor Yellow
Write-Host "  ESXi Hosts     : $hosts"  -ForegroundColor Cyan
Write-Host "  Virtual Machines: $vms"
Write-Host "  Powered On     : $poweredOn"  -ForegroundColor Green
Write-Host "  Powered Off    : $poweredOff" -ForegroundColor Red
if ($suspended -gt 0) { Write-Host "  Suspended      : $suspended" -ForegroundColor DarkYellow }

# --- Generate outputs --------------------------------------------------------
$dashboardData | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Force -Encoding UTF8
Write-Host "`nJSON data written to $jsonPath" -ForegroundColor Yellow

$templatePath = Join-Path $PSScriptRoot "VMware-Dashboard-Template.html"
Export-VMwareDashboardHtml -DashboardData $dashboardData -OutputPath $htmlPath -ReportTitle "VMware vSphere Dashboard" -TemplatePath $templatePath
Write-Host "HTML dashboard written to $htmlPath" -ForegroundColor Yellow

# --- Cleanup -----------------------------------------------------------------
Disconnect-VMware -ErrorAction SilentlyContinue

# --- Optional: Open in browser -----------------------------------------------
$openBrowser = Read-Host -Prompt "Open dashboard in browser? (Y/N)"
if ($openBrowser -match '^[Yy]') {
    Start-Process $htmlPath
}

Write-Host "`nDone." -ForegroundColor Green
