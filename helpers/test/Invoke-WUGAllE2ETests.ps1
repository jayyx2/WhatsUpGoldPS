<#
.SYNOPSIS
    Master E2E test runner for all WhatsUpGoldPS test suites.

.DESCRIPTION
    Runs every E2E test suite, captures pass/fail results with timing,
    categorises them as "Core Module" or "Helpers", and produces a unified
    HTML dashboard using Test-Dashboard-Template.html.

    Test suites:
      Core Module
        - Module Cmdlets      (Invoke-WUGModuleTest.ps1)
        - Credential API      (Invoke-WUGCredentialE2ETest.ps1)

      Helpers
        - Discovery Framework (Invoke-WUGDiscoveryHelperTest.ps1)
        - Discovery Providers (Invoke-WUGDiscoveryE2ETest.ps1)
        - Geolocation         (Invoke-WUGGeomapTest.ps1)

    WUG server credentials are resolved from the DPAPI vault
    (WUG.Server or WUG.192.168.74.74). When no vault entry exists
    and -NonInteractive is set, suites that require a WUG connection
    are skipped automatically.

.PARAMETER Category
    Run only the specified category. Default: both.

.PARAMETER IncludeSuite
    Run only the named suite(s). Tab-completes to all known names.

.PARAMETER ExcludeSuite
    Skip the named suite(s).

.PARAMETER NonInteractive
    Skip any suite that would require interactive prompts.

.PARAMETER OpenReport
    Open the unified HTML dashboard in the default browser.

.PARAMETER OutputPath
    Directory for the unified report. Default: $env:TEMP\AllE2ETests.

.EXAMPLE
    .\Invoke-WUGAllE2ETests.ps1 -NonInteractive -OpenReport

.EXAMPLE
    .\Invoke-WUGAllE2ETests.ps1 -Category Helpers -OpenReport

.EXAMPLE
    .\Invoke-WUGAllE2ETests.ps1 -IncludeSuite 'Discovery Framework','Discovery Providers'

.NOTES
    Author  : jason@wug.ninja
    Created : 2026-04-19
    Requires: PowerShell 5.1+, Windows (DPAPI vault), WhatsUpGoldPS module
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Core Module', 'Helpers')]
    [string]$Category = 'All',

    [ValidateSet('Module Cmdlets', 'Credential API', 'Discovery Framework', 'Discovery Providers', 'Geolocation')]
    [string[]]$IncludeSuite,

    [ValidateSet('Module Cmdlets', 'Credential API', 'Discovery Framework', 'Discovery Providers', 'Geolocation')]
    [string[]]$ExcludeSuite,

    [switch]$NonInteractive,
    [switch]$OpenReport,
    [string]$OutputPath
)

# ============================================================================
#region  Setup
# ============================================================================

$ErrorActionPreference = 'Continue'
$scriptDir   = Split-Path $MyInvocation.MyCommand.Path -Parent
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $OutputPath) { $OutputPath = Join-Path $env:TEMP 'AllE2ETests' }
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$masterResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$suiteTimings  = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================================
#region  Load dependencies
# ============================================================================

$discoveryHelpersPath = Join-Path $scriptDir '..\discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) {
    . $discoveryHelpersPath
    Write-Host "  Loaded DiscoveryHelpers.ps1" -ForegroundColor Green
}

# Load module for core tests
$modulePath = Join-Path $scriptDir '..\..\WhatsUpGoldPS.psd1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#region  Resolve WUG server credentials from vault
# ============================================================================

$wugServer = $null
$wugCred   = $null

$vaultNames = @('WUG.Server', 'WUG.192.168.74.74')
foreach ($vn in $vaultNames) {
    try {
        $vaultData = Get-DiscoveryCredential -Name $vn -ErrorAction SilentlyContinue
        if ($vaultData) {
            $wugParts = "$vaultData" -split '\|'
            if ($wugParts.Count -ge 5) {
                $wugServer = $wugParts[0]
                $secPw     = ConvertTo-SecureString $wugParts[4] -AsPlainText -Force
                $wugCred   = [PSCredential]::new($wugParts[3], $secPw)
                $secPw     = $null
                Write-Host "  WUG server loaded from vault: $vn ($wugServer)" -ForegroundColor Green
                break
            }
        }
    }
    catch { Write-Verbose "Vault '$vn' read failed: $_" }
}

$hasWUG = $null -ne $wugServer -and $null -ne $wugCred

if (-not $hasWUG -and -not $NonInteractive) {
    Write-Host "  No WUG vault credential found." -ForegroundColor Yellow
    $wugServer = Read-Host "  Enter WhatsUp Gold server hostname or IP (blank to skip WUG tests)"
    if ($wugServer) {
        $wugCred = Get-Credential -Message "Enter WhatsUp Gold credentials"
        $hasWUG  = $true
    }
}

# ============================================================================
#region  Define test suites
# ============================================================================

$allSuites = @(
    # ---------- Core Module ----------
    @{
        Name        = 'Module Cmdlets'
        Category    = 'Core Module'
        Script      = 'Invoke-WUGModuleTest.ps1'
        RequiresWUG = $true
        BuildParams = {
            @{
                ServerUri       = $wugServer
                Credential      = $wugCred
                IgnoreSSLErrors = $true
            }
        }
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Test   = $r.Cmdlet
                Detail = $r.Endpoint
                Status = $r.Status
                Note   = $r.Detail
            }
        }
    }
    @{
        Name        = 'Credential API'
        Category    = 'Core Module'
        Script      = 'Invoke-WUGCredentialE2ETest.ps1'
        RequiresWUG = $true
        BuildParams = {
            $p = @{}
            if ($wugServer) { $p['WUGServer'] = $wugServer }
            if ($wugCred)   { $p['Credential'] = $wugCred }
            $p
        }
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Test   = $r.Name
                Detail = $r.Group
                Status = $r.Status
                Note   = $r.Detail
            }
        }
    }

    # ---------- Helpers ----------
    @{
        Name        = 'Discovery Framework'
        Category    = 'Helpers'
        Script      = 'Invoke-WUGDiscoveryHelperTest.ps1'
        RequiresWUG = $false
        BuildParams = { @{} }
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Test   = $r.Name
                Detail = $r.Group
                Status = $r.Status
                Note   = $r.Detail
            }
        }
    }
    @{
        Name        = 'Discovery Providers'
        Category    = 'Helpers'
        Script      = 'Invoke-WUGDiscoveryE2ETest.ps1'
        RequiresWUG = $false
        BuildParams = { @{ NonInteractive = $true } }
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Test       = $r.Cmdlet
                Detail     = $r.Endpoint
                Status     = $r.Status
                Note       = $r.Detail
                Duration   = $r.Duration
                DurationMs = $r.DurationMs
            }
        }
    }
    @{
        Name        = 'Geolocation'
        Category    = 'Helpers'
        Script      = 'Invoke-WUGGeomapTest.ps1'
        RequiresWUG = $true
        BuildParams = {
            $p = @{ IgnoreSSLErrors = $true }
            if ($wugServer) { $p['ServerUri']  = $wugServer }
            if ($wugCred)   { $p['Credential'] = $wugCred }
            $p
        }
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Test   = $r.Cmdlet
                Detail = $r.Endpoint
                Status = $r.Status
                Note   = $r.Detail
            }
        }
    }
)

# ============================================================================
#region  Filter suites by category / include / exclude
# ============================================================================

$runnableSuites = $allSuites

if ($Category -ne 'All') {
    $runnableSuites = @($runnableSuites | Where-Object { $_.Category -eq $Category })
}
if ($IncludeSuite) {
    $runnableSuites = @($runnableSuites | Where-Object { $_.Name -in $IncludeSuite })
}
if ($ExcludeSuite) {
    $runnableSuites = @($runnableSuites | Where-Object { $_.Name -notin $ExcludeSuite })
}

# ============================================================================
#region  Banner
# ============================================================================

$divider = '=' * 70
Write-Host ""
Write-Host $divider -ForegroundColor Cyan
Write-Host "  WhatsUpGoldPS - Master E2E Test Runner" -ForegroundColor Cyan
Write-Host $divider -ForegroundColor Cyan
Write-Host "  Suites      : $($runnableSuites.Count)" -ForegroundColor White
Write-Host "  WUG Server  : $(if ($hasWUG) { $wugServer } else { '(none)' })" -ForegroundColor $(if ($hasWUG) { 'Green' } else { 'Yellow' })
Write-Host "  Output      : $OutputPath" -ForegroundColor White
Write-Host "  Timestamp   : $timestamp" -ForegroundColor White
Write-Host $divider -ForegroundColor Cyan
Write-Host ""

$overallSW = [System.Diagnostics.Stopwatch]::StartNew()

# ============================================================================
#region  Run each suite
# ============================================================================

$suiteIndex = 0
foreach ($suite in $runnableSuites) {
    $suiteIndex++

    # --- Skip check ---
    if ($suite.RequiresWUG -and -not $hasWUG) {
        Write-Host "  [$suiteIndex/$($runnableSuites.Count)] $($suite.Name)" -ForegroundColor White -NoNewline
        Write-Host "  SKIPPED (no WUG server)" -ForegroundColor Yellow
        $suiteTimings.Add([PSCustomObject]@{
            Suite     = $suite.Name
            Category  = $suite.Category
            Status    = 'Skipped'
            Pass      = 0
            Fail      = 0
            Skip      = 1
            Total     = 0
            Duration  = '-'
            DurationMs = 0
        })
        $masterResults.Add([PSCustomObject]@{
            Category   = $suite.Category
            Suite      = $suite.Name
            Test       = '(suite skipped)'
            Detail     = 'No WUG server credentials available'
            Status     = 'Skipped'
            Duration   = '-'
            DurationMs = 0
            Note       = ''
        })
        continue
    }

    Write-Host ""
    Write-Host "  [$suiteIndex/$($runnableSuites.Count)] $($suite.Category) / $($suite.Name)" -ForegroundColor Cyan
    Write-Host "  $('-' * 50)" -ForegroundColor DarkCyan

    $scriptPath = Join-Path $scriptDir $suite.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Host "    Script not found: $scriptPath" -ForegroundColor Red
        $suiteTimings.Add([PSCustomObject]@{
            Suite      = $suite.Name
            Category   = $suite.Category
            Status     = 'Fail'
            Pass       = 0
            Fail       = 1
            Skip       = 0
            Total      = 0
            Duration   = '-'
            DurationMs = 0
        })
        continue
    }

    # Build parameters
    $params = & $suite.BuildParams

    # Run with timing
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $suiteError = $null
    $rawOutput  = $null

    try {
        $rawOutput = & $scriptPath @params 2>&1
    }
    catch {
        $suiteError = $_.Exception.Message
    }

    $sw.Stop()
    $elapsedMs = $sw.ElapsedMilliseconds
    if ($elapsedMs -ge 60000) {
        $elapsed = '{0:0}m {1:0}s' -f [Math]::Floor($elapsedMs / 60000), [Math]::Floor(($elapsedMs % 60000) / 1000)
    }
    elseif ($elapsedMs -ge 1000) {
        $elapsed = '{0:0.0}s' -f ($elapsedMs / 1000)
    }
    else {
        $elapsed = "${elapsedMs}ms"
    }

    # Extract PSCustomObjects with a Status property (test results)
    $suiteResults = @()
    if ($rawOutput) {
        $suiteResults = @($rawOutput | Where-Object {
            $_ -is [PSCustomObject] -and $_.PSObject.Properties['Status']
        })
    }

    if ($suiteError -and $suiteResults.Count -eq 0) {
        # Suite crashed
        Write-Host "    CRASHED: $suiteError" -ForegroundColor Red
        $suiteTimings.Add([PSCustomObject]@{
            Suite      = $suite.Name
            Category   = $suite.Category
            Status     = 'Fail'
            Pass       = 0
            Fail       = 1
            Skip       = 0
            Total      = 0
            Duration   = $elapsed
            DurationMs = $elapsedMs
        })
        $masterResults.Add([PSCustomObject]@{
            Category   = $suite.Category
            Suite      = $suite.Name
            Test       = '(suite error)'
            Detail     = ''
            Status     = 'Fail'
            Duration   = $elapsed
            DurationMs = $elapsedMs
            Note       = $suiteError
        })
        continue
    }

    # Map results to common format
    $mapped = @()
    foreach ($r in $suiteResults) {
        $m = & $suite.MapResult $r
        $mapped += $m
    }

    # Calculate suite-level stats
    $sPass = @($mapped | Where-Object { $_.Status -eq 'Pass' }).Count
    $sFail = @($mapped | Where-Object { $_.Status -eq 'Fail' }).Count
    $sSkip = @($mapped | Where-Object { $_.Status -eq 'Skipped' }).Count
    $sTotal = $mapped.Count

    $suiteStatus = if ($sFail -gt 0) { 'Fail' } elseif ($sPass -gt 0) { 'Pass' } else { 'Skipped' }
    $statusColor = switch ($suiteStatus) { 'Pass' { 'Green' } 'Fail' { 'Red' } default { 'Yellow' } }

    Write-Host "    $suiteStatus" -ForegroundColor $statusColor -NoNewline
    Write-Host "  ($sPass pass, $sFail fail, $sSkip skip, $elapsed)" -ForegroundColor Gray

    $suiteTimings.Add([PSCustomObject]@{
        Suite      = $suite.Name
        Category   = $suite.Category
        Status     = $suiteStatus
        Pass       = $sPass
        Fail       = $sFail
        Skip       = $sSkip
        Total      = $sTotal
        Duration   = $elapsed
        DurationMs = $elapsedMs
    })

    # Add to master results with Category/Suite tags and suite-level timing
    $perTestMs = if ($sTotal -gt 0) { [Math]::Round($elapsedMs / $sTotal) } else { $elapsedMs }
    foreach ($m in $mapped) {
        $dur   = if ($m.PSObject.Properties['Duration']   -and $m.Duration)   { $m.Duration }   else { '' }
        $durMs = if ($m.PSObject.Properties['DurationMs'] -and $m.DurationMs) { $m.DurationMs } else { 0 }
        $masterResults.Add([PSCustomObject]@{
            Category   = $suite.Category
            Suite      = $suite.Name
            Test       = $m.Test
            Detail     = $m.Detail
            Status     = $m.Status
            Duration   = $dur
            DurationMs = $durMs
            Note       = $m.Note
        })
    }
}

$overallSW.Stop()
$overallMs = $overallSW.ElapsedMilliseconds
if ($overallMs -ge 60000) {
    $overallElapsed = '{0:0}m {1:0}s' -f [Math]::Floor($overallMs / 60000), [Math]::Floor(($overallMs % 60000) / 1000)
}
else {
    $overallElapsed = '{0:0.0}s' -f ($overallMs / 1000)
}

# ============================================================================
#region  Console Summary
# ============================================================================

Write-Host ""
Write-Host $divider -ForegroundColor Cyan
Write-Host "  MASTER RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host $divider -ForegroundColor Cyan
Write-Host ""

# Per-suite summary
foreach ($st in $suiteTimings) {
    $icon  = switch ($st.Status) { 'Pass' { '[+]' } 'Fail' { '[-]' } 'Skipped' { '[ ]' } default { '[?]' } }
    $color = switch ($st.Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'Skipped' { 'DarkGray' } default { 'Yellow' } }
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host ("{0,-14}" -f $st.Category) -ForegroundColor Gray -NoNewline
    Write-Host ("{0,-25}" -f $st.Suite) -ForegroundColor White -NoNewline
    Write-Host ("{0,4} pass  " -f $st.Pass) -ForegroundColor Green -NoNewline
    Write-Host ("{0,3} fail  " -f $st.Fail) -ForegroundColor $(if ($st.Fail -gt 0) { 'Red' } else { 'Green' }) -NoNewline
    Write-Host ("{0,3} skip  " -f $st.Skip) -ForegroundColor Yellow -NoNewline
    Write-Host ("{0,10}" -f $st.Duration) -ForegroundColor Gray
}

Write-Host ""

$totalPass = ($masterResults | Where-Object { $_.Status -eq 'Pass' }).Count
$totalFail = ($masterResults | Where-Object { $_.Status -eq 'Fail' }).Count
$totalSkip = ($masterResults | Where-Object { $_.Status -eq 'Skipped' }).Count
$totalAll  = $masterResults.Count

$overallStatus = if ($totalFail -gt 0) { 'FAIL' } else { 'PASS' }
$overallColor  = if ($totalFail -gt 0) { 'Red' } else { 'Green' }

Write-Host "  OVERALL: $overallStatus  |  Total: $totalAll  |  Pass: $totalPass  |  Fail: $totalFail  |  Skip: $totalSkip  |  Time: $overallElapsed" -ForegroundColor $overallColor
Write-Host ""

# Show failed tests
if ($totalFail -gt 0) {
    Write-Host "  FAILED TESTS:" -ForegroundColor Red
    $masterResults | Where-Object { $_.Status -eq 'Fail' } | ForEach-Object {
        Write-Host "    [$($_.Suite)] $($_.Test): $($_.Note)" -ForegroundColor Red
    }
    Write-Host ""
}

# ============================================================================
#region  Generate unified HTML dashboard
# ============================================================================

# Build data JSON
$dataRows = @($masterResults | Select-Object Category, Suite, Test, Detail, Status, Duration, DurationMs, Note)
$dataJson = ConvertTo-Json -InputObject $dataRows -Depth 5 -Compress
if ($masterResults.Count -eq 1) { $dataJson = "[$dataJson]" }

# Build suite timings JSON
$timingsData = @($suiteTimings | Select-Object Suite, Category, Status, Pass, Fail, Skip, Total, Duration, DurationMs)
$timingsJson = ConvertTo-Json -InputObject $timingsData -Depth 5 -Compress
if ($suiteTimings.Count -eq 1) { $timingsJson = "[$timingsJson]" }

# Build failed tests panel HTML
$failedPanelHtml = ''
$failedRows = @($masterResults | Where-Object { $_.Status -eq 'Fail' })
if ($failedRows.Count -gt 0) {
    $failedPanelHtml = @"
    <div class="card border-danger mb-3" id="failedPanel">
      <div class="card-header bg-danger text-white d-flex justify-content-between align-items-center" data-bs-toggle="collapse" data-bs-target="#failedBody" role="button">
        <span><i class="bi bi-exclamation-triangle-fill me-2"></i>Failed Tests ($($failedRows.Count))</span>
        <i class="bi bi-chevron-down" id="failedChevron"></i>
      </div>
      <div class="collapse show" id="failedBody">
        <div class="list-group list-group-flush">
"@
    foreach ($fr in $failedRows) {
        $escapedNote = [System.Web.HttpUtility]::HtmlEncode($fr.Note)
        $escapedTest = [System.Web.HttpUtility]::HtmlEncode($fr.Test)
        $escapedDetail = [System.Web.HttpUtility]::HtmlEncode($fr.Detail)
        $failedPanelHtml += @"
          <div class="list-group-item list-group-item-danger">
            <div class="d-flex justify-content-between align-items-start">
              <div>
                <span class="badge bg-secondary me-1">$([System.Web.HttpUtility]::HtmlEncode($fr.Suite))</span>
                <strong>$escapedTest</strong>
                <small class="text-muted ms-2">$escapedDetail</small>
              </div>
            </div>
            <div class="mt-1"><code class="text-danger">$escapedNote</code></div>
          </div>
"@
    }
    $failedPanelHtml += @"
        </div>
      </div>
    </div>
"@
}

$reportTitle = "WhatsUpGoldPS Master E2E Results - $timestamp"
$updateTime  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,shrink-to-fit=no">
    <title>$reportTitle</title>
    <link rel="icon" type="image/x-icon" href="https://wug.ninja/favicon.ico">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap/dist/css/bootstrap.min.css">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-table/dist/bootstrap-table.min.css">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons/font/bootstrap-icons.min.css">
    <script src="https://cdn.jsdelivr.net/npm/jquery/dist/jquery.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@popperjs/core/dist/umd/popper.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap/dist/js/bootstrap.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap-table/dist/bootstrap-table.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/file-saver/dist/FileSaver.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/xlsx/dist/xlsx.full.min.js"></script>
    <style>
        body { background-color: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; }
        .summary-card { border-left: 4px solid; cursor: pointer; transition: box-shadow .15s, transform .1s; user-select: none; min-width: 90px; background: #16213e; border-radius: 8px; }
        .summary-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,.3); transform: translateY(-2px); }
        .summary-card.active-filter { box-shadow: 0 0 0 2px #4cc9f0; }
        .card-total  { border-left-color: #a0a0b0; }
        .card-green  { border-left-color: #06d6a0; }
        .card-red    { border-left-color: #ef476f; }
        .card-orange { border-left-color: #ffd166; }
        .summary-card .text-muted { color: #8888aa !important; }
        .summary-card h4 { margin-bottom: 0; }
        .val-total  { color: #c0c0d0; }
        .val-green  { color: #06d6a0; font-weight: 700; }
        .val-red    { color: #ef476f; font-weight: 700; }
        .val-orange { color: #ffd166; font-weight: 700; }

        .card { background: #16213e; border-color: #2a2a4a; }
        .card-header { border-bottom-color: #2a2a4a; }

        /* Suite table */
        .suite-table { width: 100%; }
        .suite-table th { background: #0f3460; color: #e0e0e0; padding: 8px 12px; font-weight: 600; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.5px; }
        .suite-table td { padding: 8px 12px; border-top: 1px solid #2a2a4a; color: #e0e0e0; }
        .suite-row { cursor: pointer; transition: background .15s; }
        .suite-row:hover { background: #1a3a6a !important; }
        .suite-row.active { background: #1a3a6a !important; box-shadow: inset 3px 0 0 #4cc9f0; }
        .suite-row td:first-child { border-left: 3px solid transparent; }
        .suite-row.active td:first-child { border-left-color: #4cc9f0; }

        /* Badges */
        .badge-pass    { background: #06d6a0; color: #1a1a2e; }
        .badge-fail    { background: #ef476f; color: #fff; }
        .badge-skip    { background: #ffd166; color: #1a1a2e; }
        .badge-unknown { background: #6c757d; }

        /* Failed panel */
        #failedPanel { border-color: #ef476f !important; }
        #failedPanel .card-header { background: #ef476f !important; }
        #failedPanel .list-group-item { background: #2a1525; border-color: #3a2535; color: #e0e0e0; }
        #failedPanel code { color: #ff8fa3 !important; background: none; font-size: 0.9rem; }

        /* Bootstrap-table dark overrides */
        .table { color: #e0e0e0; --bs-table-bg: #16213e; --bs-table-striped-bg: #1a2744; --bs-table-hover-bg: #1a3a6a; --bs-table-border-color: #2a2a4a; }
        .table thead th { background: #0f3460 !important; color: #e0e0e0; border-color: #2a2a4a; }
        .fixed-table-toolbar .search input { background: #16213e; color: #e0e0e0; border-color: #2a2a4a; }
        .fixed-table-toolbar .btn { background: #0f3460; color: #e0e0e0; border-color: #2a2a4a; }
        .fixed-table-toolbar .btn:hover { background: #1a3a6a; }
        .fixed-table-pagination .page-link { background: #16213e; color: #e0e0e0; border-color: #2a2a4a; }
        .fixed-table-pagination .page-item.active .page-link { background: #4cc9f0; border-color: #4cc9f0; color: #1a1a2e; }
        .dropdown-menu { background: #16213e; border-color: #2a2a4a; }
        .dropdown-item { color: #e0e0e0; }
        .dropdown-item:hover { background: #1a3a6a; color: #fff; }
        caption { background: #0f3460 !important; }
        caption h6 { color: #e0e0e0 !important; }

        .status-green  { color: #06d6a0; font-weight: 600; }
        .status-red    { color: #ef476f; font-weight: 600; }
        .status-orange { color: #ffd166; font-weight: 600; }
        .status-grey   { color: #8888aa; font-weight: 600; }
        .status-dot    { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; }
        .dot-green     { background-color: #06d6a0; }
        .dot-red       { background-color: #ef476f; }
        .dot-orange    { background-color: #ffd166; }
        .dot-grey      { background-color: #8888aa; }

        .note-cell { max-width: 400px; word-break: break-word; }
        .note-fail { color: #ff8fa3; font-family: 'Cascadia Code', 'Fira Code', monospace; font-size: 0.85rem; }

        .row-counter { font-size: 0.85rem; color: #8888aa; padding: 6px 0; white-space: nowrap; }
        .fixed-table-toolbar { display: flex; align-items: center; gap: 8px; padding: 4px 0; }
        .fixed-table-toolbar > .row-counter { flex: 1; order: 1; }
        .fixed-table-toolbar > .search { order: 2; }
        .fixed-table-toolbar > .columns { order: 3; }

        .progress { background: #2a2a4a; height: 6px; border-radius: 3px; }
        .progress-bar-pass { background: #06d6a0; }
        .progress-bar-fail { background: #ef476f; }
        .progress-bar-skip { background: #ffd166; }
    </style>
</head>
<body>
<div class="container-fluid p-3">
    <!-- Header -->
    <div class="d-flex justify-content-between align-items-center mb-3">
        <h5 class="mb-0" style="color:#4cc9f0"><i class="bi bi-clipboard2-pulse me-2"></i>$reportTitle</h5>
        <small class="text-muted">$updateTime</small>
    </div>

    <!-- Summary Cards -->
    <div class="row mb-3 g-2">
        <div class="col" id="filterTotal" style="max-width:16%">
            <div class="card summary-card card-total h-100"><div class="card-body py-2 px-3">
                <div class="text-muted small">Total Tests</div><h4 id="totalTests" class="mb-0 val-total">0</h4>
            </div></div>
        </div>
        <div class="col" id="filterPass" style="max-width:16%">
            <div class="card summary-card card-green h-100"><div class="card-body py-2 px-3">
                <div class="text-muted small">Passed</div><h4 id="passTests" class="mb-0 val-green">0</h4>
            </div></div>
        </div>
        <div class="col" id="filterFail" style="max-width:16%">
            <div class="card summary-card card-red h-100"><div class="card-body py-2 px-3">
                <div class="text-muted small">Failed</div><h4 id="failTests" class="mb-0 val-red">0</h4>
            </div></div>
        </div>
        <div class="col" id="filterSkipped" style="max-width:16%">
            <div class="card summary-card card-orange h-100"><div class="card-body py-2 px-3">
                <div class="text-muted small">Skipped</div><h4 id="skipTests" class="mb-0 val-orange">0</h4>
            </div></div>
        </div>
    </div>

    <!-- Failed Tests Panel -->
    $failedPanelHtml

    <!-- Suite Timing Summary -->
    <div class="card mb-3">
      <div class="card-header bg-dark text-white d-flex justify-content-between align-items-center" data-bs-toggle="collapse" data-bs-target="#suiteSummary" role="button">
        <span><i class="bi bi-speedometer2 me-2"></i>Suite Timing Summary (Total: $overallElapsed) <small class="ms-2 text-muted">click a row to filter</small></span>
        <i class="bi bi-chevron-down" id="suiteChevron"></i>
      </div>
      <div class="collapse show" id="suiteSummary">
        <div class="card-body p-0">
          <table class="suite-table" id="suiteTable">
            <thead><tr><th>Category</th><th>Suite</th><th>Pass</th><th>Fail</th><th>Skip</th><th>Total</th><th style="width:120px">Progress</th><th>Duration</th><th>Status</th></tr></thead>
            <tbody id="suiteTableBody"></tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- Detail Table -->
    <div class="card">
      <div class="card-header d-flex justify-content-between align-items-center" style="background:#0f3460">
        <span class="text-white"><i class="bi bi-table me-2"></i>All Test Results <span id="suiteFilterLabel" class="badge bg-info ms-2" style="display:none"></span></span>
        <button class="btn btn-sm btn-outline-light" id="clearSuiteFilter" style="display:none"><i class="bi bi-x-lg me-1"></i>Clear filter</button>
      </div>
      <table id="table" data-classes="table table-striped table-bordered table-hover table-sm caption-top"
          data-show-toggle="true" data-show-columns="true" data-search="true"
          data-pagination="true" data-page-size="50" data-page-list="[25, 50, 100, 200, All]"
          data-sort-name="Status" data-sort-order="asc">
      </table>
    </div>
</div>

<script type="text/javascript">
var `$table = `$('#table'), allData = [], activeFilter = null, activeSuiteFilter = null;
var suiteTimings = $timingsJson;

function escapeHtml(t) { if(t==null)return''; return String(t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#039;'); }

function formatTestStatus(value, row) {
    if (!value) return '<span class="status-grey"><span class="status-dot dot-grey"></span>Unknown</span>';
    var v = String(value).toLowerCase();
    if (v==='pass'||v==='passed') return '<span class="status-green"><span class="status-dot dot-green"></span>' + escapeHtml(value) + '</span>';
    if (v==='fail'||v==='failed') return '<span class="status-red"><span class="status-dot dot-red"></span>' + escapeHtml(value) + '</span>';
    if (v==='skipped'||v==='skip') return '<span class="status-orange"><span class="status-dot dot-orange"></span>' + escapeHtml(value) + '</span>';
    return '<span class="status-grey"><span class="status-dot dot-grey"></span>' + escapeHtml(value) + '</span>';
}

function formatNote(value, row) {
    if (!value) return '';
    var s = String(row.Status||'').toLowerCase();
    if (s==='fail'||s==='failed') return '<span class="note-fail">' + escapeHtml(value) + '</span>';
    return '<span class="note-cell">' + escapeHtml(value) + '</span>';
}

function durationSorter(a, b, rowA, rowB) {
    var msA = (rowA && rowA.DurationMs) ? Number(rowA.DurationMs) : 0;
    var msB = (rowB && rowB.DurationMs) ? Number(rowB.DurationMs) : 0;
    return msA - msB;
}

function computeSummary(data) {
    var pass=0, fail=0, skip=0;
    data.forEach(function(r) {
        var s = String(r.Status||'').toLowerCase();
        if (s==='pass'||s==='passed') pass++; else if (s==='fail'||s==='failed') fail++; else if (s==='skipped'||s==='skip') skip++;
    });
    `$('#totalTests').text(data.length); `$('#passTests').text(pass); `$('#failTests').text(fail); `$('#skipTests').text(skip);
}

function getFilteredData() {
    var data = allData;
    if (activeSuiteFilter) {
        data = data.filter(function(r) { return r.Suite === activeSuiteFilter; });
    }
    if (activeFilter) {
        data = data.filter(function(r) {
            var s = String(r.Status||'').toLowerCase();
            switch(activeFilter) { case 'pass': return s==='pass'||s==='passed'; case 'fail': return s==='fail'||s==='failed'; case 'skipped': return s==='skipped'||s==='skip'; default: return true; }
        });
    }
    return data;
}

function applyFilters() {
    var data = getFilteredData();
    `$table.bootstrapTable('load', data);
}

function toggleStatusFilter(filterName) {
    if (activeFilter === filterName) { activeFilter = null; `$('.summary-card').removeClass('active-filter'); }
    else { activeFilter = filterName; `$('.summary-card').removeClass('active-filter'); `$('#filter' + filterName.charAt(0).toUpperCase() + filterName.slice(1) + ' .summary-card').addClass('active-filter'); }
    applyFilters();
}

function toggleSuiteFilter(suiteName) {
    if (activeSuiteFilter === suiteName) {
        activeSuiteFilter = null;
        `$('.suite-row').removeClass('active');
        `$('#suiteFilterLabel').hide(); `$('#clearSuiteFilter').hide();
    } else {
        activeSuiteFilter = suiteName;
        `$('.suite-row').removeClass('active');
        `$('.suite-row[data-suite="' + suiteName + '"]').addClass('active');
        `$('#suiteFilterLabel').text(suiteName).show(); `$('#clearSuiteFilter').show();
    }
    applyFilters();
}

function buildSuiteTable() {
    var tbody = `$('#suiteTableBody');
    suiteTimings.forEach(function(st) {
        var badgeClass = st.Status==='Pass' ? 'badge-pass' : st.Status==='Fail' ? 'badge-fail' : 'badge-skip';
        var total = st.Pass + st.Fail + st.Skip;
        var pctPass = total > 0 ? (st.Pass/total*100) : 0;
        var pctFail = total > 0 ? (st.Fail/total*100) : 0;
        var pctSkip = total > 0 ? (st.Skip/total*100) : 0;
        var passColor = st.Pass > 0 ? '#06d6a0' : '#8888aa';
        var failColor = st.Fail > 0 ? '#ef476f' : '#8888aa';
        var skipColor = st.Skip > 0 ? '#ffd166' : '#8888aa';
        tbody.append(
            '<tr class="suite-row" data-suite="' + escapeHtml(st.Suite) + '">' +
            '<td>' + escapeHtml(st.Category) + '</td>' +
            '<td><strong>' + escapeHtml(st.Suite) + '</strong></td>' +
            '<td style="color:' + passColor + '">' + st.Pass + '</td>' +
            '<td style="color:' + failColor + '">' + st.Fail + '</td>' +
            '<td style="color:' + skipColor + '">' + st.Skip + '</td>' +
            '<td>' + st.Total + '</td>' +
            '<td><div class="progress"><div class="progress-bar progress-bar-pass" style="width:' + pctPass + '%"></div><div class="progress-bar progress-bar-fail" style="width:' + pctFail + '%"></div><div class="progress-bar progress-bar-skip" style="width:' + pctSkip + '%"></div></div></td>' +
            '<td>' + escapeHtml(st.Duration) + '</td>' +
            '<td><span class="badge ' + badgeClass + '">' + escapeHtml(st.Status) + '</span></td>' +
            '</tr>'
        );
    });
}

// Export helpers
function getExportRows() { return `$table.bootstrapTable('getData', { useCurrentPage:false, includeHiddenRows:true }); }
function downloadBlob(c,f,m) { saveAs(new Blob([c],{type:m}),f); }
function escapeCsvValue(v) { var s=String(v==null?'':v); return (s.indexOf('"')!==-1||s.indexOf(',')!==-1||s.indexOf('\n')!==-1)?'"'+s.replace(/"/g,'""')+'"':s; }
function exportCsv(rows) { if(!rows.length)return; var h=Object.keys(rows[0]),l=[h.join(',')]; rows.forEach(function(r){l.push(h.map(function(k){return escapeCsvValue(r[k]);}).join(','));}); downloadBlob(l.join('\r\n'),'test_results.csv','text/csv;charset=utf-8'); }
function exportJson(rows) { downloadBlob(JSON.stringify(rows,null,2),'test_results.json','application/json;charset=utf-8'); }
function exportXlsx(rows) { if(!rows.length)return; var ws=XLSX.utils.json_to_sheet(rows),wb=XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb,ws,'TestResults'); XLSX.writeFile(wb,'test_results.xlsx'); }

`$(function () {
    // Init bootstrap-table
    `$table.bootstrapTable({
        columns: [
            { field:'Category', title:'Category', sortable:true, searchable:true },
            { field:'Suite', title:'Suite', sortable:true, searchable:true },
            { field:'Test', title:'Test', sortable:true, searchable:true },
            { field:'Detail', title:'Detail', sortable:true, searchable:true },
            { field:'Status', title:'Status', sortable:true, searchable:true, formatter: formatTestStatus },
            { field:'Duration', title:'Duration', sortable:true, sorter: durationSorter },
            { field:'DurationMs', title:'DurationMs', sortable:false, visible:false },
            { field:'Note', title:'Note / Error', sortable:true, searchable:true, formatter: formatNote }
        ],
        data: $dataJson,
        sortName: 'Status',
        sortOrder: 'asc'
    });
    allData = `$table.bootstrapTable('getData');
    computeSummary(allData);
    buildSuiteTable();

    // Summary card filters
    `$('#filterTotal').on('click', function() { toggleStatusFilter('total'); });
    `$('#filterPass').on('click', function() { toggleStatusFilter('pass'); });
    `$('#filterFail').on('click', function() { toggleStatusFilter('fail'); });
    `$('#filterSkipped').on('click', function() { toggleStatusFilter('skipped'); });

    // Suite row click filter
    `$(document).on('click', '.suite-row', function() { toggleSuiteFilter(`$(this).data('suite')); });
    `$('#clearSuiteFilter').on('click', function() { toggleSuiteFilter(activeSuiteFilter); });

    // Collapse chevrons
    `$('#suiteSummary').on('show.bs.collapse', function() { `$('#suiteChevron').removeClass('bi-chevron-right').addClass('bi-chevron-down'); })
                      .on('hide.bs.collapse', function() { `$('#suiteChevron').removeClass('bi-chevron-down').addClass('bi-chevron-right'); });
    `$('#failedBody').on('show.bs.collapse', function() { `$('#failedChevron').removeClass('bi-chevron-right').addClass('bi-chevron-down'); })
                    .on('hide.bs.collapse', function() { `$('#failedChevron').removeClass('bi-chevron-down').addClass('bi-chevron-right'); });

    // Row counter
    var `$toolbar = `$('.fixed-table-toolbar');
    if (`$toolbar.length) {
        `$toolbar.prepend('<span class="row-counter" id="rowCounter"></span>');
        var `$btnGroup = `$toolbar.find('.columns');
        if (`$btnGroup.length) {
            var `$exportBtn = `$('<div class="btn-group"><button type="button" class="btn btn-secondary dropdown-toggle" data-bs-toggle="dropdown"><i class="bi bi-download"></i> Export</button>' +
                '<ul class="dropdown-menu dropdown-menu-end"><li><a class="dropdown-item" href="#" data-type="csv">CSV</a></li><li><a class="dropdown-item" href="#" data-type="json">JSON</a></li><li><a class="dropdown-item" href="#" data-type="xlsx">XLSX</a></li></ul></div>');
            `$btnGroup.append(`$exportBtn);
        }
    }
    function updateRowCounter() {
        var shown = `$table.bootstrapTable('getData').length;
        `$('#rowCounter').text(shown === allData.length ? 'Showing ' + allData.length + ' rows' : 'Showing ' + shown + ' of ' + allData.length + ' rows');
    }
    `$table.on('post-body.bs.table', updateRowCounter);
    `$(document).on('click', '.dropdown-item[data-type]', function(e) {
        e.preventDefault(); var t=`$(this).data('type'), r=getExportRows();
        if (t==='csv') exportCsv(r); else if (t==='json') exportJson(r); else if (t==='xlsx') exportXlsx(r);
    });
    updateRowCounter();
});
</script>
</body>
</html>
"@

$reportPath = Join-Path $OutputPath "MasterE2E-Report-${timestamp}.html"
[System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($true))

Write-Host "  Dashboard: $reportPath" -ForegroundColor Green

if ($OpenReport -and (Test-Path $reportPath)) {
    Start-Process $reportPath
}

# ============================================================================
#region  Return results
# ============================================================================

$masterResults

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBcF4tZ7F70DWg/
# ODqQrgbi3F+1csGmE0jJ65UYhQbQWqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDAejWzPXNojIdhJYB/WzZvAY6QTdE15tEfF2MUFeXOfzANBgkqhkiG9w0BAQEF
# AASCAgCduvRP+I2jOnIw9HL0dIcN5vG2fYP2sO6vM9ryExdfVdPG334CsAZ3nhKO
# RB89NLRcluIHpvEiotJwuaQ2ceLAIJuDPkS+H7VZgyWDp90FoNN2KXvUd1WXu6C9
# c9pS6ZVXOGSf+ofy7xE0IfhMZeL9fzD/dtcuD8+u7/qyAyhs9Onov4kOE2UOAlzS
# lSpcKWAPLiLBU2Vi9bPAWNa4sjbOfQEUUaqTBhQkMqOXHczNVMsKqxKVx0bXZVvO
# 2qZkdeqS1s12Vad3Le8MV4eF/xEhSEehAvjNfb3mwL82RVB7r0rikWRpHzeMG9Oi
# vEFTyaWVv9bdQIA17barxWYsyPRwg1tPqWd0V4QPHyd3Yi0ETqtKQQQZ+n+c6HBB
# RF5dHVElx/Im2sDglX+Z8fsA4ykEGUBXwtMljvbKAspzBM4iXBXOaiq646XrCC9o
# n27HgA9nBJ6Hk5TFQMaXXYmJ4Y4yVuZCKEYqLiqmD8c2cW1zLS7qJ+Mabm+RvMow
# D9LoGo8O0HTr4pcHw1LLEV50w70uN1MVamjE5Ez6K672YyVeSZQnWekieIotlQfl
# 37rk9qBQP4nB20Kbj9aMyFd50PH4e2LebALITPedqQ6SwWrNHGCN1Q3fudc1QUkg
# UicSrteRbwLdnijBJ8GL6AwDcLAMy5FmV9b5jLvztkn1MjbI2KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMTI0MDZaMC8GCSqGSIb3DQEJBDEiBCCO4++U
# AKJ3Je4nKR3Q6du9gQuivQinQRS3SSf89cdFBTANBgkqhkiG9w0BAQEFAASCAgBA
# +/o3U+rWGhTzzqw6KPVe2aTVCqA4srYBTZ+p8HjqeuZS2Z0Gs8d7zpfGgcUgXTwP
# 7a5yMxNYyXx2y+lpVA7eCiO3EUL3EiUSYRXdTCAcPTzVza7ssq7tW7QK+lqRofCn
# 4BaB+VDbX5B9dGAFGpDsbrO6IrKpVOUEQ3UW7NZEd9GUN1k5Q2ofzPwTBBNk6bGC
# pIAYu7vGzY5XPqddON91ma+18uQUqnVgcaO4pSjE1PIFdW0rb0QuVW7+nUYxIzyL
# asm+g6l3M4AECIeT/dlmYbbDLRy5kXMSTKa3nK4PUOkFrm0SwKGwwgR5F9XkNISG
# f7dMlEihiIC5z5LgGk8qnrMrHk2fn/kV1T0pD+Jd0Yoyd6QCjyes6otyi+jPJ4fm
# 4luqqINvj1EHzP1TahcSgLr210HFjtbDMfdpMSYTOSVx03kcdM+iHTvPwZCpqEJZ
# 9LLY9AVf/B3FMF+dfCFb1lx1Mo4y6guZDRSBozTj/NpLx6+R38Y+hMc93/k9FmFf
# 3y7dtasRrGObSMZMvtgbSYpwjzCKKrgVaqQq0SWgrZGWNA3JKawcQCaSIjHYrTtv
# fGZ8c8IfnYmmxlwQfDETzLEsswFL9Ls5wKdVAQFjOfXzP0qCPR4/WL4GnvXtcd2Y
# j74POUtLQjLPwxG+Cyh39HUD8kU2JjTuGlu7RSlcRA==
# SIG # End signature block
