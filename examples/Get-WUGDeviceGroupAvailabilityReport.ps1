<#
.SYNOPSIS
    Calculates overall ping availability percentage for a WhatsUp Gold device group.

.DESCRIPTION
    Retrieves the Ping Availability report for all devices in a device group,
    then computes:
      - Per-device availability % (from the WUG report)
      - Group-wide average availability %
      - Total downtime minutes across all devices
      - Worst-performing devices

    This gives a single "what percentage of the time were devices in this group
    reachable via ping?" number, rolled up from per-device ping monitor data.

.PARAMETER GroupId
    Device group ID. Default: -2 (All Devices).
    Find group IDs with: Get-WUGDeviceGroup

.PARAMETER Range
    Time range preset. Default: 'lastMonth'.
    Valid: today, yesterday, lastWeek, lastMonth, lastQuarter,
           weekToDate, monthToDate, quarterToDate, lastNDays, custom

.PARAMETER RangeN
    Multiplier for lastN* ranges. E.g., -Range lastNDays -RangeN 7 = last 7 days.

.PARAMETER RangeStartUtc
    Start time for custom range (UTC). Requires -Range custom.

.PARAMETER RangeEndUtc
    End time for custom range (UTC). Requires -Range custom.

.PARAMETER TopN
    Number of worst-performing devices to display. Default: 10.

.PARAMETER OutputPath
    File path for the HTML dashboard. Default: auto-generated in $env:TEMP.

.PARAMETER OpenDashboard
    Open the generated HTML dashboard in the default browser.

.EXAMPLE
    # Overall ping availability for All Devices, last 30 days
    .\Get-WUGDeviceGroupAvailabilityReport.ps1

.EXAMPLE
    # Specific group, last 7 days
    .\Get-WUGDeviceGroupAvailabilityReport.ps1 -GroupId 5 -Range lastNDays -RangeN 7

.EXAMPLE
    # Custom date range
    .\Get-WUGDeviceGroupAvailabilityReport.ps1 -GroupId 5 -Range custom `
        -RangeStartUtc '2026-07-01T00:00:00' -RangeEndUtc '2026-07-31T23:59:59'

.NOTES
    Requires: WhatsUpGoldPS module, active connection via Connect-WUGServer
    Author: jason@wug.ninja
#>
[CmdletBinding()]
param(
    [int]$GroupId = -2,

    [ValidateSet('today', 'yesterday', 'lastWeek', 'lastMonth', 'lastQuarter',
                 'weekToDate', 'monthToDate', 'quarterToDate',
                 'lastNSeconds', 'lastNMinutes', 'lastNHours', 'lastNDays',
                 'lastNWeeks', 'lastNMonths', 'custom')]
    [string]$Range = 'lastNMonths',

    [int]$RangeN = 12,

    [string]$RangeStartUtc,
    [string]$RangeEndUtc,

    [int]$TopN = 0,

    [string]$OutputPath,

    [switch]$OpenDashboard
)

# ── Prerequisites ────────────────────────────────────────────────────────────
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    Import-Module WhatsUpGoldPS -ErrorAction Stop
}
if (-not $global:WUGBearerHeaders) {
    Write-Error "Not connected to WhatsUp Gold. Run Connect-WUGServer first."
    return
}

# ── Build report parameters ──────────────────────────────────────────────────
$reportParams = @{
    GroupId    = $GroupId
    ReportType = 'PingAvailability'
    Range      = $Range
}
if ($Range -match '^lastN') {
    $reportParams['RangeN'] = $RangeN
}
if ($Range -eq 'custom') {
    if (-not $RangeStartUtc -or -not $RangeEndUtc) {
        Write-Error "Custom range requires -RangeStartUtc and -RangeEndUtc."
        return
    }
    $reportParams['RangeStartUtc'] = $RangeStartUtc
    $reportParams['RangeEndUtc']   = $RangeEndUtc
}

# ── Fetch ping availability data ─────────────────────────────────────────────
Write-Host ''
Write-Host '  Fetching Ping Availability Report...' -ForegroundColor Cyan

# Resolve group name
$groupName = "Group $GroupId"
try {
    $grp = Get-WUGDeviceGroup | Where-Object { $_.id -eq $GroupId } | Select-Object -First 1
    if ($grp -and $grp.name) { $groupName = $grp.name }
}
catch { }

Write-Host "  Group    : $groupName (ID $GroupId)" -ForegroundColor Gray
Write-Host "  Range    : $Range$(if ($Range -match '^lastN') { " (N=$RangeN)" })" -ForegroundColor Gray

$data = @(Get-WUGDeviceGroupReport @reportParams)

if ($data.Count -eq 0) {
    Write-Warning "No ping availability data returned. Check group ID and time range."
    return
}

# Compute calendar date range from the data or the requested range
$rangeEndDate = Get-Date
if ($Range -eq 'custom' -and $RangeEndUtc) {
    $rangeEndDate = [datetime]::Parse($RangeEndUtc)
}
$rangeStartDate = switch -Regex ($Range) {
    'today'          { $rangeEndDate.Date }
    'yesterday'      { $rangeEndDate.Date.AddDays(-1) }
    'lastWeek'       { $rangeEndDate.AddDays(-7) }
    'lastMonth'      { $rangeEndDate.AddMonths(-1) }
    'lastQuarter'    { $rangeEndDate.AddMonths(-3) }
    'lastNSeconds'   { $rangeEndDate.AddSeconds(-$RangeN) }
    'lastNMinutes'   { $rangeEndDate.AddMinutes(-$RangeN) }
    'lastNHours'     { $rangeEndDate.AddHours(-$RangeN) }
    'lastNDays'      { $rangeEndDate.AddDays(-$RangeN) }
    'lastNWeeks'     { $rangeEndDate.AddDays(-7 * $RangeN) }
    'lastNMonths'    { $rangeEndDate.AddMonths(-$RangeN) }
    'weekToDate'     { $rangeEndDate.Date.AddDays(-[int]$rangeEndDate.DayOfWeek) }
    'monthToDate'    { $rangeEndDate.Date.AddDays(1 - $rangeEndDate.Day) }
    'quarterToDate'  { $q = [Math]::Floor(($rangeEndDate.Month - 1) / 3) * 3 + 1; [datetime]::new($rangeEndDate.Year, $q, 1) }
    'custom'         { if ($RangeStartUtc) { [datetime]::Parse($RangeStartUtc) } else { $rangeEndDate.AddMonths(-1) } }
    default          { $rangeEndDate.AddMonths(-1) }
}
$dateRangeStr = "$($rangeStartDate.ToString('yyyy-MM-dd')) to $($rangeEndDate.ToString('yyyy-MM-dd'))"

Write-Host "  Devices  : $($data.Count)" -ForegroundColor Gray
Write-Host ''

# ── Calculate per-device stats ────────────────────────────────────────────────
$deviceStats = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($device in $data) {
    # WUG API returns percentAvailable as 0-1 fraction; convert to 0-100 scale
    $pctAvail    = [double]$device.percentAvailable * 100
    $totalMin    = [double]$device.totalTimeMinutes
    $unavailMin  = [double]$device.timeUnavailableMinutes
    $pktSent     = [int]$device.packetsSent
    $pktLost     = [int]$device.packetsLost

    $deviceStats.Add([PSCustomObject]@{
        DeviceId             = $device.id
        DeviceName           = $device.deviceName
        PercentAvailable     = [Math]::Round($pctAvail, 4)
        PercentUnavailable   = [Math]::Round(100 - $pctAvail, 4)
        TotalMinutes         = [Math]::Round($totalMin, 1)
        DowntimeMinutes      = [Math]::Round($unavailMin, 1)
        PacketsSent          = $pktSent
        PacketsLost          = $pktLost
        PercentPacketLoss    = if ($pktSent -gt 0) { [Math]::Round(($pktLost / $pktSent) * 100, 4) } else { 0 }
    })
}

# ── Roll up to group-wide average ─────────────────────────────────────────────
$totalDevices       = $deviceStats.Count
$avgAvailability    = ($deviceStats | Measure-Object -Property PercentAvailable -Average).Average
$totalDowntimeMin   = ($deviceStats | Measure-Object -Property DowntimeMinutes -Sum).Sum
$avgDowntimeMin     = ($deviceStats | Measure-Object -Property DowntimeMinutes -Average).Average
$totalMonitoredMin  = ($deviceStats | Measure-Object -Property TotalMinutes -Sum).Sum
$totalPktSent       = ($deviceStats | Measure-Object -Property PacketsSent -Sum).Sum
$totalPktLost       = ($deviceStats | Measure-Object -Property PacketsLost -Sum).Sum
$overallPktLoss     = if ($totalPktSent -gt 0) { [Math]::Round(($totalPktLost / $totalPktSent) * 100, 4) } else { 0 }
$avgPktLoss         = ($deviceStats | Measure-Object -Property PercentPacketLoss -Average).Average
$maxMonitoredMin    = ($deviceStats | Measure-Object -Property TotalMinutes -Maximum).Maximum

# Weighted availability (accounts for different monitoring periods per device)
$weightedAvail = if ($totalMonitoredMin -gt 0) {
    [Math]::Round((($totalMonitoredMin - $totalDowntimeMin) / $totalMonitoredMin) * 100, 4)
} else { 0 }

# ── Display results ───────────────────────────────────────────────────────────
$divider = '=' * 60
Write-Host $divider -ForegroundColor DarkCyan
Write-Host '  Ping Availability Summary' -ForegroundColor Cyan
Write-Host $divider -ForegroundColor DarkCyan
Write-Host ''
Write-Host "  Overall Availability (avg) :  $([Math]::Round($avgAvailability, 2))%" -ForegroundColor $(if ($avgAvailability -ge 99) { 'Green' } elseif ($avgAvailability -ge 95) { 'Yellow' } else { 'Red' })
Write-Host "  Overall Availability (wtd) :  $([Math]::Round($weightedAvail, 2))%" -ForegroundColor $(if ($weightedAvail -ge 99) { 'Green' } elseif ($weightedAvail -ge 95) { 'Yellow' } else { 'Red' })
Write-Host ''
Write-Host "  Devices monitored          :  $totalDevices" -ForegroundColor White
Write-Host "  Total monitored time       :  $([Math]::Round($totalMonitoredMin / 60, 1)) hours ($([Math]::Round($totalMonitoredMin / 1440, 1)) days)" -ForegroundColor White
Write-Host "  Total downtime             :  $([Math]::Round($totalDowntimeMin, 1)) minutes ($([Math]::Round($totalDowntimeMin / 60, 1)) hours)" -ForegroundColor White
Write-Host "  Packets sent / lost        :  $totalPktSent / $totalPktLost ($overallPktLoss% loss)" -ForegroundColor White
Write-Host ''

# ── Worst performers ──────────────────────────────────────────────────────────
if ($TopN -gt 0) {
    $worst = @($deviceStats | Sort-Object PercentAvailable | Select-Object -First $TopN)
} else {
    $worst = @($deviceStats | Sort-Object PercentAvailable)
}
if ($worst.Count -gt 0) {
    Write-Host "  Bottom $($worst.Count) Devices by Availability:" -ForegroundColor Yellow
    Write-Host "  $('-' * 56)" -ForegroundColor DarkGray
    Write-Host ('  {0,-30} {1,10} {2,12}' -f 'Device', 'Avail %', 'Down (min)') -ForegroundColor DarkGray
    Write-Host "  $('-' * 56)" -ForegroundColor DarkGray
    foreach ($d in $worst) {
        $color = if ($d.PercentAvailable -ge 99) { 'Green' } elseif ($d.PercentAvailable -ge 95) { 'Yellow' } else { 'Red' }
        $name = if ($d.DeviceName.Length -gt 28) { $d.DeviceName.Substring(0, 28) + '..' } else { $d.DeviceName }
        Write-Host ('  {0,-30} {1,9:N2}% {2,11:N1}' -f $name, $d.PercentAvailable, $d.DowntimeMinutes) -ForegroundColor $color
    }
}

Write-Host ''
Write-Host $divider -ForegroundColor DarkCyan

# ── Generate HTML Dashboard ───────────────────────────────────────────────────
$dashboardPath = $null
$reportsDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -ErrorAction SilentlyContinue) 'helpers\reports'
if (-not $reportsDir -or -not (Test-Path $reportsDir)) {
    # Try relative to script location
    $reportsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers\reports'
}
$dynDashScript = Join-Path $reportsDir 'Export-DynamicDashboardHtml.ps1'

if (Test-Path $dynDashScript) {
    . $dynDashScript

    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:TEMP "PingAvailability-Group${GroupId}-$(Get-Date -Format yyyyMMdd-HHmmss).html"
    }

    # Build per-device table data (no summary row — that goes in the banner)
    $dashData = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($d in ($deviceStats | Sort-Object PercentAvailable)) {
        $status = if ($d.PercentAvailable -ge 99.9) { 'Excellent' }
                  elseif ($d.PercentAvailable -ge 99) { 'Good' }
                  elseif ($d.PercentAvailable -ge 95) { 'Warning' }
                  else { 'Critical' }

        $dashData.Add([PSCustomObject]@{
            Device            = $d.DeviceName
            'Availability %'  = $d.PercentAvailable
            'Downtime (min)'  = $d.DowntimeMinutes
            'Monitored (hrs)' = [Math]::Round($d.TotalMinutes / 60, 1)
            'Packets Sent'    = $d.PacketsSent
            'Packets Lost'    = $d.PacketsLost
            'Packet Loss %'   = $d.PercentPacketLoss
            Status            = $status
        })
    }

    try {
        @($dashData) | Export-DynamicDashboardHtml `
            -ReportTitle "Ping Availability - $groupName ($dateRangeStr)" `
            -OutputPath $OutputPath `
            -ThresholdField @(
                @{ Field = 'Availability %'; Warning = 99; Critical = 95; Invert = $true }
                @{ Field = 'Packet Loss %'; Warning = 1; Critical = 5 }
            )

        # Inject a summary banner above the table
        $availColor = if ($avgAvailability -ge 99) { '#28a745' } elseif ($avgAvailability -ge 95) { '#fd7e14' } else { '#dc3545' }
        $summaryBanner = @"
<div style="display:flex;flex-wrap:wrap;gap:16px;margin:0 0 24px 0;justify-content:center;">
  <div style="flex:1.3;min-width:240px;max-width:340px;background:$availColor;color:#fff;border-radius:12px;padding:24px 20px;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,.15);">
    <div style="font-size:38px;font-weight:700;line-height:1;">$([Math]::Round($avgAvailability, 4))%</div>
    <div style="font-size:14px;margin-top:8px;opacity:.9;font-weight:600;">$([System.Web.HttpUtility]::HtmlEncode($groupName))</div>
    <div style="font-size:11px;margin-top:4px;opacity:.7;">$dateRangeStr</div>
  </div>
  <div style="flex:1;min-width:160px;max-width:220px;background:#f8f9fa;border:1px solid #dee2e6;border-radius:12px;padding:24px 20px;text-align:center;">
    <div style="font-size:28px;font-weight:700;color:#333;">$totalDevices</div>
    <div style="font-size:13px;color:#666;margin-top:4px;">Devices Monitored</div>
  </div>
  <div style="flex:1;min-width:160px;max-width:220px;background:#f8f9fa;border:1px solid #dee2e6;border-radius:12px;padding:24px 20px;text-align:center;">
    <div style="font-size:28px;font-weight:700;color:#dc3545;">$([Math]::Round($avgDowntimeMin, 1)) min</div>
    <div style="font-size:13px;color:#666;margin-top:4px;">Avg Downtime / Device</div>
    <div style="font-size:11px;color:#999;margin-top:2px;">Total: $([Math]::Round($totalDowntimeMin, 1)) min</div>
  </div>
  <div style="flex:1;min-width:160px;max-width:220px;background:#f8f9fa;border:1px solid #dee2e6;border-radius:12px;padding:24px 20px;text-align:center;">
    <div style="font-size:28px;font-weight:700;color:$(if ([Math]::Round($avgPktLoss, 4) -gt 1) { '#dc3545' } elseif ([Math]::Round($avgPktLoss, 4) -gt 0) { '#fd7e14' } else { '#28a745' });">$([Math]::Round($avgPktLoss, 4))%</div>
    <div style="font-size:13px;color:#666;margin-top:4px;">Avg Packet Loss</div>
    <div style="font-size:11px;color:#999;margin-top:2px;">$totalPktLost lost / $totalPktSent sent</div>
  </div>
</div>
"@
        # Insert banner before the card-groups section
        $html = Get-Content -Path $OutputPath -Raw
        # Try known div IDs in the template
        $insertPoint = -1
        foreach ($divId in @('cardGroups', 'card-groups', 'detailsSection', 'toolbar')) {
            $marker = "<div id=`"$divId`""
            $idx = $html.IndexOf($marker)
            if ($idx -gt 0) {
                # For cardGroups, insert right before it
                $insertPoint = $idx
                break
            }
        }
        if ($insertPoint -gt 0) {
            $html = $html.Insert($insertPoint, $summaryBanner)
        }
        [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($true))

        $dashboardPath = $OutputPath
        Write-Host ''
        Write-Host "  Dashboard: $OutputPath" -ForegroundColor Green
        if ($OpenDashboard) {
            Start-Process $OutputPath
        }
    }
    catch {
        Write-Warning "Dashboard generation failed: $_"
    }
}
else {
    Write-Verbose "Export-DynamicDashboardHtml.ps1 not found at $dynDashScript — skipping dashboard."
}

# ── Return structured object for pipeline use ─────────────────────────────────
[PSCustomObject]@{
    GroupId                = $GroupId
    Range                  = $Range
    DeviceCount            = $totalDevices
    AverageAvailability    = [Math]::Round($avgAvailability, 4)
    WeightedAvailability   = [Math]::Round($weightedAvail, 4)
    TotalMonitoredMinutes  = [Math]::Round($totalMonitoredMin, 1)
    TotalDowntimeMinutes   = [Math]::Round($totalDowntimeMin, 1)
    TotalPacketsSent       = $totalPktSent
    TotalPacketsLost       = $totalPktLost
    OverallPacketLoss      = $overallPktLoss
    DashboardPath          = $dashboardPath
    WorstDevices           = $worst
    AllDeviceStats         = @($deviceStats)
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCALAUHGPcc8W8+I
# Wmp4tvfnqygyXVt8bj8JNPdbDk3Sb6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDenE3vSipvBKUvF9zWtVq8IOMqdXbicAyMp9SwGahozTANBgkqhkiG9w0BAQEF
# AASCAgAJ8h6hTPpxETlIc7NiXknxULcoxR4YD08MQuwjv2Sz1QuDPLYEBNZ1+HcY
# mZTBcACgsFAvOczMIOIAdtUn3b1HbQY2HxEE/EWftBeHPuD0nCDORnLOPPa+wRy8
# PD7ByDnkIghzdT9j8w0tPia2Jtu/cuunp8sO6Q0YJ7VY0P/JGxLwpJAEfFxbIOhc
# YItphpId8/iUqQ/+yB+EjyPWFXc8EakZ1UZzAs0zlYhUy/CUrgc/1gckIic77zN8
# 0Pxa9z14l6xqv1/KzENYiHth4JW7VWXJVRxFrghEkU5D1BReCACmbzjLb5ocqDgk
# bZz1iGySGnxtAey1rGQhCf1Oh7V7RCIEauLxtj/LrciMC1lHeS48qsgS3/iE9OHJ
# 2uNVhxa4qPKustlsOA0esYJL3FORWsU/rVX8YjyJpJ95d/tFeBC88FNw7XcCqrOv
# CQXpvlPXc867nljfkLQTw+TjyrzRYYN+ads9vF+IuBEk55Ns6SONZWJIpi9RDb6Q
# 8UqbVsZwSFAE6jd45VgO4gCT6w0zxAwLEH7/9/+u7qJIHByD9TW7qKFQsjObapUO
# Ny7zMNDJ8aCHp4KzH10MLaVL9LIRj8IjfHP0eOMAk0y7ZzhVuwBgnIA7hq+/S/sT
# GLeDwB1K/4h5V38PdTKhnZ+qQuK2lUqDBVDzt097luf3SLBMjKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MzAyMDM3MDhaMC8GCSqGSIb3DQEJBDEiBCAwztqP
# a33aQDhrXsZrqm+ccw8C4cNM2NaV3TICvvrsnTANBgkqhkiG9w0BAQEFAASCAgA5
# jMvtU5bNM2RWTTxM1c1z/j5TtIxNdMrFSCzjGU96tg2qI2w1JylMJ4zbDt1DHyQq
# WW5ZjtkrlPSkT1u49QMF95omWehSlUYPYVXsd9nI5WbIBaUTHH64BVRAe0Iarvtw
# JtV4gZtY+XZiZhlZeG5n4oSlamTs2DJMrwJP/MbSB6SYzdoOT2UHcRXEN5ne/T3g
# Y08vXcVujaexb1h8Oqi2puD/JtqOZgSY167/3ApPoATAT+J+4Piww3t7Y75Q88FK
# k0uZmdQAQ34D6mHxILDT03wAXFZEipbjKI3DXEGmsDSrlabDrFEsWNSshNILvY/m
# hVL8TMEtM6h38hpov0AryL3z3QxNFefRVJIiRT3q9TQn/BGoV5W6JqZ0qee6KfDi
# uI6MMlNl4YkJ3qTbK/bbYLUVyf87HLu0Gus7yRE8S9P3B4r1j60ktnEGormNVKLl
# 23ttw5eUB2ptrTfq50K8Y9SdpUV+yPkkChRtjx4nlLlvTEOELiUQ+bBnP2Xs++bG
# mWdCfaLc7JkykMa3tJVtsNTwhKbXbcfPQCQ384dVSSFNgqHBONJFVNwc6lMu6uT9
# h1pRiq9Reg7DfzDEkjNSNYBNs4Fo5UxdUBewy4fERBv7UOWwHr44Bqa4+VBYIvKY
# 9kwcGc4FAYcwcrd/xqh3959MP26c20H2T8liPbtcHA==
# SIG # End signature block
