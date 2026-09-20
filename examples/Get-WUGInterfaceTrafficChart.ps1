<#!
.SYNOPSIS
    Generates a standalone HTML chart for WhatsUp Gold interface traffic.

.DESCRIPTION
    Queries the WhatsUp Gold interface traffic report for one or more devices or
    a device group, then writes a self-contained HTML/JavaScript/CSS chart. The
    generated page has no runtime dependency on a charting library or web server.

    The report API returns one row per interface sample. This example keeps the
    samples intact and lets the browser group them into device/interface series.
    It supports the same report time presets and custom UTC date range exposed by
    Get-WUGDeviceReport and Get-WUGDeviceGroupReport with -ReportType InterfaceTraffic.

.PARAMETER DeviceId
    One or more device IDs to query. Use this or GroupId, not both.

.PARAMETER GroupId
    One or more device group IDs to query. The default value -2 means All Devices.

.PARAMETER ReturnHierarchy
    Include devices from child groups when GroupId is used.

.PARAMETER Range
    WUG report time preset. Use custom with RangeStartUtc and RangeEndUtc.

.PARAMETER RangeN
    Number used by lastNSeconds, lastNMinutes, lastNHours, lastNDays,
    lastNWeeks, and lastNMonths.

.PARAMETER RangeStartUtc
    UTC start time for a custom range, for example 2026-08-01T00:00:00Z.

.PARAMETER RangeEndUtc
    UTC end time for a custom range, for example 2026-09-01T00:00:00Z.

.PARAMETER OutputPath
    Destination for the generated HTML file. Defaults to the temporary folder.

.PARAMETER OpenDashboard
    Opens the generated HTML file in the default browser.

.EXAMPLE
    .\Get-WUGInterfaceTrafficChart.ps1 -GroupId 5 -Range lastWeek -OpenDashboard
.EXAMPLE
    .\Get-WUGInterfaceTrafficChart.ps1 -DeviceId 101,102 -Range lastNDays -RangeN 3

.EXAMPLE
    .\Get-WUGInterfaceTrafficChart.ps1 -GroupId 5 -Range custom `
        -RangeStartUtc '2026-08-01T00:00:00Z' `
        -RangeEndUtc '2026-09-01T00:00:00Z'

.NOTES
    Requires an active WhatsUpGoldPS connection. The HTML file contains the
    returned report data, so protect it according to your environment's policy.
#>
[CmdletBinding(DefaultParameterSetName = 'Group')]
param(
    [Parameter(ParameterSetName = 'Device', Mandatory = $true)]
    [int[]]$DeviceId,

    [Parameter(ParameterSetName = 'Group')]
    [int[]]$GroupId = @(-2),

    [Parameter(ParameterSetName = 'Group')]
    [ValidateSet('true', 'false')]
    [string]$ReturnHierarchy = 'false',

    [ValidateSet('today', 'lastPolled', 'yesterday', 'lastWeek', 'lastMonth', 'lastQuarter',
                 'weekToDate', 'monthToDate', 'quarterToDate', 'lastNSeconds', 'lastNMinutes',
                 'lastNHours', 'lastNDays', 'lastNWeeks', 'lastNMonths', 'custom')]
    [string]$Range = 'lastWeek',

    [int]$RangeN = 1,
    [string]$RangeStartUtc,
    [string]$RangeEndUtc,
    [string]$OutputPath,
    [switch]$OpenDashboard
)

if (-not (Get-Module -Name WhatsUpGoldPS)) {
    Import-Module (Join-Path $PSScriptRoot '..\WhatsUpGoldPS.psd1') -ErrorAction Stop
}
if (-not $global:WUGBearerHeaders) {
    throw 'Not connected to WhatsUp Gold. Run Connect-WUGServer first.'
}
if ($Range -eq 'custom' -and (-not $RangeStartUtc -or -not $RangeEndUtc)) {
    throw '-Range custom requires both -RangeStartUtc and -RangeEndUtc.'
}
if ($Range -ne 'custom' -and ($RangeStartUtc -or $RangeEndUtc)) {
    throw '-RangeStartUtc and -RangeEndUtc are only valid with -Range custom.'
}
if ($Range -match '^lastN' -and $RangeN -lt 1) {
    throw '-RangeN must be greater than zero for a lastN range.'
}

$reportParameters = @{
    Range = $Range
}
if ($Range -match '^lastN') { $reportParameters['RangeN'] = $RangeN }
if ($Range -eq 'custom') {
    $reportParameters['RangeStartUtc'] = $RangeStartUtc
    $reportParameters['RangeEndUtc'] = $RangeEndUtc
}

$deviceIds = @()
if ($PSCmdlet.ParameterSetName -eq 'Device') {
    $deviceIds = @($DeviceId)
    $scopeLabel = "Devices: $($DeviceId -join ', ')"
}
else {
    Write-Verbose "Resolving devices in group IDs: $($GroupId -join ', ')"
    foreach ($id in $GroupId) {
        $deviceParameters = @{ DeviceGroupID = [string]$id; View = 'card'; Limit = 250 }
        if ($ReturnHierarchy -eq 'true') { $deviceParameters['ReturnHierarchy'] = 'true' }
        $groupDevices = @(Get-WUGDevice @deviceParameters)
        $deviceIds += @($groupDevices | ForEach-Object { [int]$_.id })
    }
    $deviceIds = @($deviceIds | Select-Object -Unique)
    $scopeLabel = "Groups: $($GroupId -join ', ')"
}

if ($deviceIds.Count -eq 0) {
    throw 'No devices were found in the selected scope.'
}

# Device reports contain the historical points in each interface row's series property.
$reportParameters['ReportType'] = 'InterfaceTraffic'
$data = [System.Collections.Generic.List[object]]::new()
foreach ($id in $deviceIds) {
    Write-Verbose "Fetching interface traffic for device ID: $id"
    $deviceRows = @(& 'WhatsUpGoldPS\Get-WUGDeviceReport' -DeviceId $id @reportParameters)
    foreach ($row in $deviceRows) {
        $points = @($row.series)
        if ($points.Count -eq 0) {
            $data.Add($row)
            continue
        }
        foreach ($point in $points) {
            $pointRow = [ordered]@{}
            foreach ($property in $row.PSObject.Properties) {
                if ($property.Name -ne 'series') { $pointRow[$property.Name] = $property.Value }
            }
            foreach ($property in $point.PSObject.Properties) {
                $pointRow[$property.Name] = $property.Value
            }
            $data.Add([PSCustomObject]$pointRow)
        }
    }
}
$data = @($data)

if ($data.Count -eq 0) {
    throw 'The report returned no interface traffic samples for the selected scope and time range.'
}

if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $env:TEMP "WhatsUpGold-InterfaceTraffic-$stamp.html"
}
$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$json = ConvertTo-Json -InputObject @($data) -Depth 8 -Compress
# Prevent a device or interface name from closing the data script element.
$json = $json.Replace('<', '\u003c')
$title = "WhatsUp Gold Interface Traffic - $scopeLabel"
$titleJson = ConvertTo-Json $title -Compress
$rangeJson = ConvertTo-Json $Range -Compress
$scopeJson = ConvertTo-Json $scopeLabel -Compress

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
:root { color-scheme: light; --ink:#17212b; --muted:#5d6b78; --line:#d9e1e7; --paper:#f5f7f8; --panel:#ffffff; --accent:#007f86; --accent2:#ef8354; }
* { box-sizing:border-box; }
body { margin:0; background:linear-gradient(135deg,#edf4f1 0%,#f8f6f1 55%,#e9f0f3 100%); color:var(--ink); font:15px/1.45 Segoe UI, sans-serif; }
main { max-width:1440px; margin:auto; padding:28px 4vw 48px; }
header { border-bottom:1px solid var(--line); margin-bottom:18px; padding-bottom:18px; }
h1 { margin:0 0 4px; font:700 clamp(25px,3vw,42px)/1.05 Georgia, serif; letter-spacing:0; }
.subtitle,.hint { color:var(--muted); }
.toolbar { display:flex; flex-wrap:wrap; gap:12px; align-items:end; background:var(--panel); border:1px solid var(--line); padding:14px; box-shadow:0 8px 24px #19313c12; }
label { display:flex; flex-direction:column; gap:4px; color:var(--muted); font-size:12px; font-weight:600; }
select,button { min-height:38px; border:1px solid #b8c6ce; background:#fff; color:var(--ink); padding:8px 11px; font:inherit; }
button { cursor:pointer; background:var(--ink); color:#fff; border-color:var(--ink); }
button:hover { background:var(--accent); border-color:var(--accent); }
.stats { display:flex; flex-wrap:wrap; gap:10px; margin:18px 0; }
.stat { min-width:145px; background:#ffffffb8; border-left:4px solid var(--accent); padding:9px 13px; }
.stat strong { display:block; font-size:21px; }
.stat span { color:var(--muted); font-size:12px; }
.chart-panel { background:var(--panel); border:1px solid var(--line); padding:12px; box-shadow:0 8px 24px #19313c12; }
.interface-menu { position:relative; min-width:250px; flex:2 1 360px; }
.interface-menu summary { display:flex; align-items:center; justify-content:space-between; min-height:38px; border:1px solid #b8c6ce; background:#fff; color:var(--ink); padding:8px 11px; cursor:pointer; list-style:none; }
.interface-menu summary::-webkit-details-marker { display:none; }
.interface-menu summary:after { content:'\25BE'; color:var(--muted); margin-left:10px; }
.interface-menu[open] summary:after { content:'\25B4'; }
.selection-summary { color:var(--muted); font-size:12px; font-weight:400; margin-left:8px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.interface-menu-panel { position:absolute; z-index:4; top:calc(100% + 6px); left:0; right:0; min-width:320px; padding:10px; background:#fff; border:1px solid var(--line); box-shadow:0 12px 30px #19313c26; }
.interface-search { display:block; margin-bottom:8px; color:var(--muted); font-size:12px; font-weight:600; }
.interface-search input { width:100%; margin-top:4px; }
.interface-list { max-height:220px; overflow:auto; border:1px solid var(--line); background:#fbfcfd; padding:4px; }
.interface-option { display:flex; align-items:flex-start; gap:8px; padding:6px 5px; color:var(--ink); font-size:12px; font-weight:400; cursor:pointer; }
.interface-option[hidden] { display:none; }
.interface-option:hover { background:#eaf3f2; }
.interface-option input { flex:0 0 auto; width:15px; height:15px; margin:0; accent-color:var(--accent); }
.picker-actions { display:flex; gap:6px; margin-top:5px; }
.picker-actions button { min-height:28px; padding:4px 8px; font-size:12px; }
.chart-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(520px,1fr)); gap:14px; align-items:start; }
.device-column { min-width:0; }
.device-column h2 { margin:0 0 8px; padding:9px 10px; background:#17212b; color:#fff; font:600 15px/1.2 Segoe UI,sans-serif; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.device-interfaces { display:grid; gap:14px; }
.interface-card { position:relative; border:1px solid var(--line); background:#fff; padding:10px; min-width:0; }
.interface-card > h3 { margin:0 0 7px; font:600 15px/1.2 Segoe UI,sans-serif; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.interface-card h2 { margin:0 0 7px; font:600 15px/1.2 Segoe UI,sans-serif; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pair { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
.mini-chart { position:relative; min-width:0; }
.mini-chart h3 { margin:0 0 2px; color:var(--muted); font-size:11px; font-weight:600; text-transform:uppercase; }
.mini-chart canvas { display:block; width:100%; height:190px; min-height:0; border-top:1px solid var(--line); }
.tooltip { position:absolute; display:none; z-index:2; max-width:min(360px,80vw); pointer-events:none; background:#17212b; color:#fff; padding:8px 10px; font-size:11px; line-height:1.4; box-shadow:0 5px 16px #17212b40; }
.tooltip strong { color:#fff; }
.legend { display:flex; flex-wrap:wrap; gap:5px 13px; margin:8px 4px 0; color:var(--muted); font-size:11px; }
.legend span:before { content:''; display:inline-block; width:16px; height:3px; margin:0 5px 3px 0; background:var(--color); }
.hint { margin:12px 3px 0; font-size:12px; }
@media (max-width:640px) { main { padding:20px 12px 32px; } .toolbar>* { flex:1 1 145px; } .chart-grid { grid-template-columns:1fr; } .pair { grid-template-columns:1fr; } }
</style>
</head>
<body>
<main>
<header><h1>Interface traffic</h1><div class="subtitle" id="scope"></div></header>
<section class="toolbar" aria-label="Chart controls">
<label>Device<select id="device"></select></label>
<details class="interface-menu" id="interfaceMenu"><summary>Choose interfaces <span class="selection-summary" id="selectionSummary"></span></summary><div class="interface-menu-panel"><label class="interface-search">Search interfaces<input id="interfaceSearch" type="search" placeholder="Type 3 or more characters"></label><div class="interface-list" id="interfaceList" aria-label="Interfaces to display"></div><span class="picker-actions"><button id="selectAll" type="button">Select all</button><button id="clearAll" type="button">Clear</button></span></div></details>
<label>Metric<select id="metric"><option value="avg">Combined average</option><option value="min">Combined minimum</option><option value="max">Combined maximum</option><option value="all">Minimum + average + maximum</option></select></label>
<button id="csv" type="button">Download CSV</button>
</section>
<section class="stats"><div class="stat"><strong id="sampleCount">0</strong><span>samples</span></div><div class="stat"><strong id="seriesCount">0</strong><span>interfaces</span></div><div class="stat"><strong id="peak">0</strong><span>peak traffic</span></div><div class="stat"><strong id="p95Receive">0</strong><span>95th percentile receive</span></div><div class="stat"><strong id="p95Transmit">0</strong><span>95th percentile transmit</span></div></section>
<section class="chart-panel"><div class="chart-grid" id="chartGrid"></div><div class="legend" id="legend"></div><div class="hint">Choose the interfaces to display. Receive and transmit are shown side by side; hover either chart for exact values.</div></section>
</main>
<script>
const rows = $json;
const reportTitle = $titleJson;
const scopeLabel = $scopeJson;
const reportRange = $rangeJson;
const deviceSelect = document.getElementById('device');
const interfaceList = document.getElementById('interfaceList');
const interfaceSearch = document.getElementById('interfaceSearch');
const metricSelect = document.getElementById('metric');
const chartGrid = document.getElementById('chartGrid');
const selectionSummary = document.getElementById('selectionSummary');
const directionColors = { rx:'#007f86', tx:'#ef8354' };
const colors = { min:directionColors.rx, avg:directionColors.rx, max:directionColors.tx };
const value = (row, name) => { const key = Object.keys(row).find(k => k.toLowerCase() === name.toLowerCase()); return row[key]; };
const text = (row, name) => String(value(row, name) ?? 'Unknown');
const numeric = (row, name) => { const number = Number(value(row, name)); return Number.isFinite(number) ? number : 0; };
const deviceName = row => text(row, 'deviceName');
const interfaceName = row => text(row, 'interfaceName') + (value(row,'interfaceId') != null ? ' [' + text(row,'interfaceId') + ']' : '');
const seriesKey = row => deviceName(row) + ' / ' + interfaceName(row);
const series = new Map();
rows.forEach(row => { const key = seriesKey(row); if (!series.has(key)) series.set(key, []); series.get(key).push(row); });
series.forEach(points => points.sort((a,b) => new Date(value(a,'pollTimeUtc')) - new Date(value(b,'pollTimeUtc'))));
const devices = [...new Set(rows.map(deviceName))].sort();
const storageKey = 'wug-interface-traffic:' + scopeLabel + ':' + reportRange;
let savedSettings = {};
try { savedSettings = JSON.parse(localStorage.getItem(storageKey) || '{}') || {}; } catch (error) { savedSettings = {}; }
document.title = reportTitle;
document.getElementById('scope').textContent = scopeLabel + ' | Range: ' + reportRange + ' | ' + rows.length + ' API rows';
document.getElementById('sampleCount').textContent = rows.length.toLocaleString();
document.getElementById('seriesCount').textContent = series.size.toLocaleString();
function option(select, label, val) { const item = document.createElement('option'); item.textContent = label; item.value = val; select.appendChild(item); }
option(deviceSelect, 'All devices', '*'); devices.forEach(d => option(deviceSelect, d, d));
if (devices.includes(savedSettings.device)) deviceSelect.value = savedSettings.device;
if (['avg','min','max','all'].includes(savedSettings.metric)) metricSelect.value = savedSettings.metric;
function filteredKeys() { return [...series.keys()].filter(key => deviceSelect.value === '*' || key.startsWith(deviceSelect.value + ' / ')).sort(); }
function selectedInterfaceKeys() { return [...interfaceList.querySelectorAll('input:checked')].map(input => input.value); }
function saveSettings() { try { localStorage.setItem(storageKey, JSON.stringify({ device:deviceSelect.value, metric:metricSelect.value, interfaces:selectedInterfaceKeys() })); } catch (error) {} }
function updateSelectionSummary() { const selected = selectedInterfaceKeys(); selectionSummary.textContent = selected.length ? selected.length + ' selected' : 'None selected'; }
function filterInterfaceOptions() { const query = interfaceSearch.value.trim().toLowerCase(); const active = query.length >= 3; interfaceList.querySelectorAll('.interface-option').forEach(label => { label.hidden = active && !label.textContent.toLowerCase().includes(query); }); }
function refreshInterfaces() { const old = new Set(selectedInterfaceKeys()); const preferred = old.size ? old : new Set(savedSettings.interfaces || []); interfaceList.innerHTML = ''; filteredKeys().forEach(key => { const label = document.createElement('label'); label.className = 'interface-option'; const input = document.createElement('input'); input.type = 'checkbox'; input.value = key; input.checked = preferred.size ? preferred.has(key) : interfaceList.children.length < 6; const text = document.createElement('span'); text.textContent = key; label.append(input,text); interfaceList.appendChild(label); }); filterInterfaceOptions(); renderCharts(); }
function selectedSeries() { const selected = new Set(selectedInterfaceKeys()); return [...series.entries()].filter(([key]) => selected.has(key)); }
function modes() { return metricSelect.value === 'all' ? ['min','avg','max'] : [metricSelect.value]; }
function amount(row, mode, direction) { const prefix = direction === 'rx' ? 'rx' : 'tx'; if (mode === 'min') return numeric(row,prefix+'SpeedMin'); if (mode === 'max') return numeric(row,prefix+'SpeedMax'); return numeric(row,prefix+'SpeedAvg'); }
function percentile(values, fraction) { const sorted = values.filter(Number.isFinite).sort((a,b) => a-b); if (!sorted.length) return 0; const index = (sorted.length - 1) * fraction; const lower = Math.floor(index); const upper = Math.ceil(index); return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower); }
function percentileFor(selected, direction) { const values = selected.flatMap(([,points]) => points.map(row => amount(row,'avg',direction))); return percentile(values,0.95); }
function escapeHtml(input) { return String(input).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character])); }
function formatBytes(number) { const units = ['b/s','Kb/s','Mb/s','Gb/s','Tb/s']; let n = Math.abs(number), unit = 0; while (n >= 1000 && unit < units.length - 1) { n /= 1000; unit++; } return (number < 0 ? '-' : '') + n.toFixed(n >= 100 ? 0 : 2) + ' ' + units[unit]; }
function drawMini(canvas, points, direction, title) { const context = canvas.getContext('2d'), rect = canvas.getBoundingClientRect(), ratio = window.devicePixelRatio || 1; canvas.width=rect.width*ratio; canvas.height=rect.height*ratio; context.setTransform(ratio,0,0,ratio,0,0); const width=rect.width,height=rect.height,pad={left:50,right:8,top:8,bottom:25}, all=points.flatMap(row=>modes().map(mode=>({row,time:new Date(value(row,'pollTimeUtc')).getTime(),amount:amount(row,mode,direction)}))).filter(point=>Number.isFinite(point.time)), minTime=Math.min(...all.map(point=>point.time)),maxTime=Math.max(...all.map(point=>point.time)),maxValue=Math.max(...all.map(point=>point.amount),1),plotW=width-pad.left-pad.right,plotH=height-pad.top-pad.bottom; context.clearRect(0,0,width,height); context.fillStyle='#fff';context.fillRect(0,0,width,height);context.font='10px Segoe UI';context.fillStyle='#5d6b78'; for(let i=0;i<=3;i++){const y=pad.top+plotH-(i/3)*plotH;context.strokeStyle='#e1e7eb';context.beginPath();context.moveTo(pad.left,y);context.lineTo(width-pad.right,y);context.stroke();context.fillText(formatBytes(maxValue*i/3),2,y+3);} const xLabel=t=>new Date(t).toLocaleDateString([], {month:'short',day:'numeric'});context.fillText(xLabel(minTime),pad.left,height-7);context.textAlign='right';context.fillText(xLabel(maxTime),width-pad.right,height-7);context.textAlign='left'; modes().forEach(mode=>{const visible=points.map(row=>({row,time:new Date(value(row,'pollTimeUtc')).getTime(),amount:amount(row,mode,direction)})).filter(point=>Number.isFinite(point.time));context.strokeStyle=colors[mode];context.fillStyle=colors[mode];context.lineWidth=1.5;context.beginPath();visible.forEach((point,index)=>{const x=pad.left+((point.time-minTime)/Math.max(maxTime-minTime,1))*plotW,y=pad.top+plotH-(point.amount/maxValue)*plotH;if(index===0)context.moveTo(x,y);else context.lineTo(x,y);});context.stroke();visible.forEach(point=>{const x=pad.left+((point.time-minTime)/Math.max(maxTime-minTime,1))*plotW,y=pad.top+plotH-(point.amount/maxValue)*plotH;context.beginPath();context.arc(x,y,2.5,0,Math.PI*2);context.fill();});}); canvas.addEventListener('mousemove',event=>{const x=event.offsetX,target=minTime+(x-pad.left)/Math.max(plotW,1)*Math.max(maxTime-minTime,1),nearest=points.reduce((best,row)=>Math.abs(new Date(value(row,'pollTimeUtc')).getTime()-target)<Math.abs(new Date(value(best,'pollTimeUtc')).getTime()-target)?row:best,points[0]),tip=canvas.parentElement.querySelector('.tooltip');tip.innerHTML='<strong>'+escapeHtml(new Date(value(nearest,'pollTimeUtc')).toLocaleString())+'</strong><br>'+escapeHtml(title)+' receive/transmit: '+formatBytes(amount(nearest,'avg',direction));tip.style.display='block';tip.style.left=Math.min(event.offsetX+10,rect.width-180)+'px';tip.style.top=Math.max(4,event.offsetY-25)+'px';}); canvas.addEventListener('mouseleave',()=>{const tip=canvas.parentElement.querySelector('.tooltip');tip.style.display='none';}); }
function renderCharts(){
    const selected = selectedSeries();
    const activeModes = modes();
    chartGrid.innerHTML = '';
    updateSelectionSummary();
    saveSettings();
    if (!selected.length) {
        chartGrid.innerHTML = '<div class="hint">Select at least one interface.</div>';
        document.getElementById('p95Receive').textContent = '0';
        document.getElementById('p95Transmit').textContent = '0';
        return;
    }
    const columns = new Map();
    selected.forEach(([key,points]) => {
        const name = deviceName(points[0]);
        if (!columns.has(name)) { columns.set(name, []); }
        columns.get(name).push([key,points]);
    });
    let peak = 0;
    columns.forEach((entries,name) => {
        const column = document.createElement('section');
        column.className = 'device-column';
        const heading = document.createElement('h2');
        heading.textContent = name;
        column.appendChild(heading);
        const interfaceContainer = document.createElement('div');
        interfaceContainer.className = 'device-interfaces';
        column.appendChild(interfaceContainer);
        chartGrid.appendChild(column);
        entries.forEach(([key,points]) => {
            const card = document.createElement('article');
            card.className = 'interface-card';
            const title = document.createElement('h3');
            title.textContent = key.substring(name.length + 3);
            card.appendChild(title);
            const pair = document.createElement('div');
            pair.className = 'pair';
            card.appendChild(pair);
            interfaceContainer.appendChild(card);
            [['rx','Receive'],['tx','Transmit']].forEach(([direction,label]) => {
                const wrap = document.createElement('div');
                wrap.className = 'mini-chart';
                const chartTitle = document.createElement('h3');
                chartTitle.textContent = label;
                const chart = document.createElement('canvas');
                const tip = document.createElement('div');
                tip.className = 'tooltip';
                wrap.append(chartTitle,chart,tip);
                pair.appendChild(wrap);
                drawMini(chart,points,direction,label);
                attachTooltip(chart,tip,points,direction,label);
                points.forEach(row => activeModes.forEach(mode => { peak = Math.max(peak,amount(row,mode,direction)); }));
            });
        });
    });
    document.getElementById('sampleCount').textContent = selected.reduce((total,[,points]) => total + points.length,0).toLocaleString();
    document.getElementById('seriesCount').textContent = selected.length.toLocaleString();
    document.getElementById('peak').textContent = formatBytes(peak);
    document.getElementById('p95Receive').textContent = formatBytes(percentileFor(selected,'rx'));
    document.getElementById('p95Transmit').textContent = formatBytes(percentileFor(selected,'tx'));
    document.getElementById('legend').innerHTML = activeModes.map(mode => '<span style="--color:'+colors[mode]+'">'+mode.toUpperCase()+'</span>').join('');
}
const renderChartsBase = renderCharts;
renderCharts = function() { renderChartsBase(); document.getElementById('legend').innerHTML = '<span style="--color:'+directionColors.rx+'">RECEIVE</span><span style="--color:'+directionColors.tx+'">TRANSMIT</span>'; };
deviceSelect.addEventListener('change', refreshInterfaces); interfaceSearch.addEventListener('input', filterInterfaceOptions); interfaceList.addEventListener('change', renderCharts); metricSelect.addEventListener('change', renderCharts); document.getElementById('selectAll').addEventListener('click',()=>{interfaceList.querySelectorAll('input').forEach(input=>input.checked=true);renderCharts();}); document.getElementById('clearAll').addEventListener('click',()=>{interfaceList.querySelectorAll('input').forEach(input=>input.checked=false);renderCharts();}); window.addEventListener('resize',renderCharts);
document.getElementById('csv').addEventListener('click', () => { const lines = [['deviceName','interfaceName','interfaceId','pollTimeUtc','rxSpeedAvg','txSpeedAvg','totalAvg']]; selectedSeries().forEach(([,points]) => points.forEach(row => lines.push(['deviceName','interfaceName','interfaceId','pollTimeUtc','rxSpeedAvg','txSpeedAvg','totalAvg'].map(k=>String(value(row,k) ?? '').replace(/"/g,'""'))))); const blob = new Blob([lines.map(line=>line.map(v=>'"'+v+'"').join(',')).join('\n')],{type:'text/csv'}); const link=document.createElement('a'); link.href=URL.createObjectURL(blob); link.download='interface-traffic.csv'; link.click(); URL.revokeObjectURL(link.href); });
function attachTooltip(canvas, tip, points, direction, label) {
    canvas.addEventListener('mousemove', event => {
        const rect = canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const times = points.map(row => new Date(value(row,'pollTimeUtc')).getTime()).filter(Number.isFinite);
        if (!times.length) { return; }
        const minTime = Math.min(...times);
        const maxTime = Math.max(...times);
        const targetTime = minTime + (x - 50) / Math.max(rect.width - 58, 1) * Math.max(maxTime - minTime, 1);
        const row = points.reduce((closest,current) => Math.abs(new Date(value(current,'pollTimeUtc')).getTime() - targetTime) < Math.abs(new Date(value(closest,'pollTimeUtc')).getTime() - targetTime) ? current : closest, points[0]);
        const timestamp = new Date(value(row,'pollTimeUtc')).toLocaleString();
        tip.innerHTML = '<strong>' + escapeHtml(label) + '</strong><br>' + escapeHtml(timestamp) + '<br>Minimum: ' + formatBytes(amount(row,'min',direction)) + '<br>Average: ' + formatBytes(amount(row,'avg',direction)) + '<br>Maximum: ' + formatBytes(amount(row,'max',direction));
        tip.style.display = 'block';
        tip.style.left = Math.min(Math.max(x + 12, 4), Math.max(rect.width - 190, 4)) + 'px';
        tip.style.top = Math.max(event.clientY - rect.top - 46, 4) + 'px';
    });
    canvas.addEventListener('mouseleave', () => { tip.style.display = 'none'; });
}
function drawMini(canvas, points, direction, title) {
    const context = canvas.getContext('2d');
    const rect = canvas.getBoundingClientRect();
    const ratio = window.devicePixelRatio || 1;
    const width = rect.width;
    const height = rect.height;
    const pad = { left:50, right:8, top:8, bottom:25 };
    const times = points.map(row => new Date(value(row,'pollTimeUtc')).getTime()).filter(Number.isFinite);
    const minTime = Math.min(...times);
    const maxTime = Math.max(...times);
    const maxValue = Math.max(...points.flatMap(row => modes().map(mode => amount(row,mode,direction))), 1);
    const plotW = width - pad.left - pad.right;
    const plotH = height - pad.top - pad.bottom;
    canvas.width = width * ratio;
    canvas.height = height * ratio;
    context.setTransform(ratio,0,0,ratio,0,0);
    context.clearRect(0,0,width,height);
    context.fillStyle = '#fff';
    context.fillRect(0,0,width,height);
    context.font = '10px Segoe UI';
    context.fillStyle = '#5d6b78';
    for (let index = 0; index <= 3; index++) {
        const y = pad.top + plotH - (index / 3) * plotH;
        context.strokeStyle = '#e1e7eb';
        context.beginPath();
        context.moveTo(pad.left,y);
        context.lineTo(width-pad.right,y);
        context.stroke();
        context.fillText(formatBytes(maxValue * index / 3),2,y+3);
    }
    modes().forEach(mode => {
        const visible = points.map(row => ({ row, time:new Date(value(row,'pollTimeUtc')).getTime(), amount:amount(row,mode,direction) })).filter(point => Number.isFinite(point.time));
        context.strokeStyle = directionColors[direction];
        context.fillStyle = directionColors[direction];
        context.lineWidth = 1.5;
        context.setLineDash(mode === 'min' ? [5,4] : mode === 'max' ? [2,3] : []);
        context.beginPath();
        visible.forEach((point,index) => {
            const x = pad.left + ((point.time-minTime) / Math.max(maxTime-minTime,1)) * plotW;
            const y = pad.top + plotH - (point.amount / maxValue) * plotH;
            if (index === 0) { context.moveTo(x,y); } else { context.lineTo(x,y); }
        });
        context.stroke();
        visible.forEach(point => {
            const x = pad.left + ((point.time-minTime) / Math.max(maxTime-minTime,1)) * plotW;
            const y = pad.top + plotH - (point.amount / maxValue) * plotH;
            context.beginPath();
            context.arc(x,y,2.5,0,Math.PI*2);
            context.fill();
        });
    });
    context.setLineDash([]);
    context.fillStyle = '#5d6b78';
    context.fillText(new Date(minTime).toLocaleDateString([], {month:'short',day:'numeric'}),pad.left,height-7);
    context.textAlign = 'right';
    context.fillText(new Date(maxTime).toLocaleDateString([], {month:'short',day:'numeric'}),width-pad.right,height-7);
    context.textAlign = 'left';
}
refreshInterfaces();
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $OutputPath
if ($OpenDashboard) { Start-Process $OutputPath }
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBIRP7X8RbZ9W/h
# W+SQF4wjO5D6DpICVGdowWsl/ig8tKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQghVRwWk4ro5TP4dzsEG3du9ugcMhOF8Sw
# Jc9F6GMoIfswDQYJKoZIhvcNAQEBBQAEggIAxYBR/ySyveQAGWxzVau5/8Aaxcjv
# a1Hqiu8gkptTSOFZUcB+uSPN+a6W1aVcJ5xCogrnvWvkuLJhHtSiIVxQKWFbGEx7
# Gq46g1KHOLQcpWCU98sr/hKcwW1IHumaLCgAGpUE+1VuMCfCU4g5pjIWK3AKy5W1
# noSOaMhqneBKTzDkeCeKDK7STJ1FWzc+ggovbRJaKohLefN1QR15Zyo0Of5Ss3iI
# 0utsPpgKHUL2hSjzpGx0lHCJoFWaSYzecUERmkis1+4/SnEmzAvSAHl6YSVzV46Y
# CntKlm884Fk5q4b/sIPHYoCRd3V4MeFel37TVHvPYK5AHX2KXFrg22EsTJFJ85kE
# AjlbA/yMpbPrqW7a/rvxStcOk0/ScWjQGEkXp4QvvmuQ4BEjsCgq7+iJuFbET/6t
# bVhaGo45WkYIdysZlLTqvVa1uJ9oqjc5Xi0itgMIst9zVXbV8gIGc8io29SR6aeu
# wB8qSVXVfWj+8+5YilJPBC5Xejh2izkvFQm84CxT2x1NvqM6A0A5kmD7bAwPS9ez
# nrTynUtMa+By4dtZ0o0I/GNp6wTcEeZkwkjr15s0WgI0aOFIejdcIYqpEDkLr1jL
# xdwyPK1DVFFMzEgX1fHeVcvU/3p4KMFU+yf91yn09XFOzlQ2Tb2dS46zo+Gyihcd
# eebt1ECLvBxq9eI=
# SIG # End signature block
