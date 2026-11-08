#requires -Version 5.1
<#
.SYNOPSIS
    Tests local browser review generation and CSV logic offline.
.DESCRIPTION
    Uses malicious canned metadata, empty inventory, and ShouldProcess checks.
    Runs JavaScript CSV/validation tests through Node.js when it is available.
    No credentials, service, browser, or WUG connection are used.
.EXAMPLE
    powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceBrowserReviewTest.ps1
.NOTES
    Throws on failure and removes only its unique test output directory.
.LINK
    ..\..\docs\interface-grouping.md
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupBrowserReview.ps1')
$outputDirectory = Join-Path $PSScriptRoot ("browser-review-test-" + [guid]::NewGuid().ToString('N'))
function Assert-Review {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$script:cloudFixtureAncestors = @{}
$ancestor = $PSScriptRoot
while ($ancestor) {
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $ancestor -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and -not $item.LinkType) {
        $script:cloudFixtureAncestors[$item.FullName] = $true
    }
    $parent = Split-Path $ancestor -Parent
    if ($parent -eq $ancestor) { break }
    $ancestor = $parent
}
function Get-Item {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$Force)
    $item = Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
    if ($script:cloudFixtureAncestors.ContainsKey($item.FullName)) {
        # Model ordinary filesystem ancestors under OneDrive without weakening the exporter.
        return [pscustomobject]@{
            FullName = $item.FullName
            Attributes = ($item.Attributes -band (-bnot [IO.FileAttributes]::ReparsePoint))
            PSIsContainer = $item.PSIsContainer
        }
    }
    return $item
}
try {
    if ($script:cloudFixtureAncestors.Count) {
        Write-Output 'INFO: rendering fixtures model OneDrive cloud-placeholder ancestors as ordinary directories; real junctions remain blocked.'
    }
    $attack = '</script><img src=x onerror="alert(1)">&<script>alert("metadata")</script>'
    $inventory = @([pscustomobject]@{
        DeviceId = 88; IfIndex = '7'; DeviceName = $attack
        InterfaceComment = "line one`r`n`"quoted`", comment"; InterfaceName = 'Port 7'
        IfAlias = $attack; IfName = 'eth7'; IfDescr = 'Raw & <description>'
        AccessToken = 'SECRET-MUST-NOT-EXPORT'
    })
    $groups = @([pscustomobject]@{ Name = 'Group A'; MatchBasis = $attack; Interfaces = $inventory })
    $path = Join-Path $outputDirectory 'review.html'
    $whatIf = Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Path $path -WhatIf
    Assert-Review (-not (Test-Path -LiteralPath $outputDirectory)) 'WhatIf created files.'
    Assert-Review ($null -eq $whatIf) 'WhatIf returned an exported path.'
    $result = Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Path $path -Confirm:$false
    Assert-Review ($result -eq $path) 'Exporter returned the wrong path.'
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-Review ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'HTML is missing UTF-8 BOM.'
    $html = [IO.File]::ReadAllText($path)
    foreach ($unsafeName in @('index.html', 'group-01.html', ('group-' + ('a' * 64) + '.html'), 'review.csv')) {
        $rejected = $false
        try { Export-InterfaceGroupBrowserReview -Inventory @() -Groups @() -Path (Join-Path $outputDirectory $unsafeName) -Confirm:$false | Out-Null }
        catch { $rejected = $_.Exception.Message -match 'managed dashboard filename|\.html extension' }
        Assert-Review $rejected "Unsafe output name accepted: $unsafeName"
    }
    $unrelatedPath = Join-Path $outputDirectory 'unrelated.html'
    [IO.File]::WriteAllText($unrelatedPath, '<html>Do not overwrite</html>', [Text.UTF8Encoding]::new($true))
    $rejected = $false
    try { Export-InterfaceGroupBrowserReview -Inventory @() -Groups @() -Path $unrelatedPath -Confirm:$false | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'not an owned browser review' }
    Assert-Review $rejected 'Unrelated existing HTML was overwritten.'
    Assert-Review ([IO.File]::ReadAllText($unrelatedPath) -eq '<html>Do not overwrite</html>') 'Unrelated HTML content changed.'
    $junctionPath = Join-Path $outputDirectory 'linked-output'
    $targetPath = Join-Path $outputDirectory 'real-output'
    New-Item -ItemType Directory -Path $targetPath | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $targetPath -ErrorAction Stop | Out-Null
    try {
        $rejected = $false
        try { Export-InterfaceGroupBrowserReview -Inventory @() -Groups @() -Path (Join-Path $junctionPath 'review.html') -Confirm:$false | Out-Null }
        catch { $rejected = $_.Exception.Message -match 'reparse points or symbolic links' }
        Assert-Review $rejected 'Reparse ancestor was accepted.'
        Assert-Review (-not (Test-Path -LiteralPath (Join-Path $targetPath 'review.html'))) 'Review escaped through a junction.'
    }
    finally { [IO.Directory]::Delete($junctionPath) }
    Write-Output 'PASS: managed names, unrelated output files, and reparse ancestors rejected'
    Assert-Review (-not $html.Contains('SECRET-MUST-NOT-EXPORT')) 'Unrelated sensitive metadata was exported.'
    Assert-Review (-not $html.Contains($attack)) 'Executable metadata was embedded without escaping.'
    $payloadMatch = [regex]::Match($html, '<script id="review-data" type="application/json">([\s\S]*?)</script>')
    Assert-Review $payloadMatch.Success 'Missing embedded JSON.'
    $payload = $payloadMatch.Groups[1].Value
    Assert-Review (-not ($payload -match '[<>&]')) 'JSON must escape HTML metacharacters.'
    $rows = @($payload | ConvertFrom-Json)
    Assert-Review ($rows.Count -eq 1 -and $rows[0].InterfaceKey -eq '88:7') 'Stable key was not retained.'
    Assert-Review ($rows[0].IfAlias -ceq $attack -and $rows[0].DeviceName -ceq $attack) 'Raw metadata changed.'
    Assert-Review ($rows[0].Apply -eq 'True' -and $rows[0].Groups -eq 'Group A') 'Unexpected initial decisions.'
    Assert-Review ($rows[0].MatchExplanation -ceq "Group A: $attack") 'Match explanation was not retained.'
    $pin = @(New-InterfaceGroupReview -Inventory $inventory -Groups $groups)[0]
    $pin.Groups = 'Pinned group'; $pin.Apply = 'True'; $pin.Exclude = 'True'
    $pinsPath = Join-Path $outputDirectory 'pins.html'
    Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Decisions @($pin) -Path $pinsPath -Confirm:$false | Out-Null
    $pinsHtml = [IO.File]::ReadAllText($pinsPath)
    $pinsPayload = [regex]::Match($pinsHtml, '<script id="review-data" type="application/json">([\s\S]*?)</script>').Groups[1].Value
    $pins = @($pinsPayload | ConvertFrom-Json)
    Assert-Review ($pins[0].Apply -eq 'True' -and $pins[0].Exclude -eq 'True' -and $pins[0].Groups -eq 'Pinned group') 'Existing pin decisions were discarded.'
    Assert-Review ($pins[0].IfAlias -ceq $inventory[0].IfAlias -and $pins[0].InterfaceComment -ceq $inventory[0].InterfaceComment) 'Pins changed immutable metadata.'
    Assert-Review ($pin.ProposedGroups -eq 'Group A' -and $inventory[0].InterfaceName -eq 'Port 7') 'Export mutated its inputs.'
    $pin.Apply = 'False'
    Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Decisions @($pin) -Path $pinsPath -Confirm:$false | Out-Null
    $pinsHtml = [IO.File]::ReadAllText($pinsPath)
    $pinsPayload = [regex]::Match($pinsHtml, '<script id="review-data" type="application/json">([\s\S]*?)</script>').Groups[1].Value
    $pins = @($pinsPayload | ConvertFrom-Json)
    Assert-Review ($pins[0].Apply -eq 'False' -and $pins[0].Exclude -eq 'True') 'Unapplied decision flags were discarded.'
    $pin.Apply = 'True'; $pin.InterfaceComment = 'Stale description'
    $rejected = $false
    try { Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Decisions @($pin) -Path $pinsPath -Confirm:$false | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'changed descriptions' }
    Assert-Review $rejected 'Stale applied pin metadata was not rejected.'
    $pin.InterfaceComment = $inventory[0].InterfaceComment
    $rejected = $false
    try { Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Decisions @($pin, $pin) -Path $pinsPath -Confirm:$false | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'Duplicate review interface key' }
    Assert-Review $rejected 'Duplicate pins were not rejected.'
    $pin.Apply = 'Yes'; $rejected = $false
    try { Export-InterfaceGroupBrowserReview -Inventory $inventory -Groups $groups -Decisions @($pin) -Path $pinsPath -Confirm:$false | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'must be True or False' }
    Assert-Review $rejected 'Invalid pin flags were not rejected.'
    Write-Output 'PASS: existing decisions retained, inputs immutable, stale metadata/duplicate/invalid pins rejected'
    $emptyPath = Join-Path $outputDirectory 'empty.html'
    Export-InterfaceGroupBrowserReview -Inventory @() -Groups @() -Path $emptyPath -Confirm:$false | Out-Null
    $emptyHtml = [IO.File]::ReadAllText($emptyPath)
    Assert-Review ($emptyHtml.Contains('type="application/json">[]</script>')) 'Empty inventory is not a JSON array.'
    Assert-Review (-not ($html -match '\binnerHTML\b|https?://|fetch\s*\(|XMLHttpRequest')) 'Review must not use unsafe HTML or network APIs.'
    foreach ($id in @('search', 'assign-selected', 'exclude-selected', 'reset-selected', 'accept-automatic', 'preview-edits', 'download', 'validation', 'group-summary')) {
        Assert-Review ($html.Contains('id="' + $id + '"')) "Missing required UI: $id"
    }
    Write-Output 'PASS: offline rendering, safe metadata, empty inventory, and WhatIf'
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $javascriptPath = Join-Path $outputDirectory 'review-test.js'
        $javascript = @'
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync(process.argv[2], 'utf8');
const data = JSON.parse(html.match(/<script id="review-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
const scripts = Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/g));
const context = vm.createContext({});
vm.runInContext(scripts[0][1] + '\nthis.api = InterfaceGroupReview;', context);
const api = context.api;
const expected = ['InterfaceKey','DeviceName','InterfaceComment','InterfaceName','IfAlias','IfName','IfDescr','ProposedGroups','Groups','MatchExplanation','Exclude','Apply'];
assert.deepStrictEqual(Array.from(api.columns), expected);
const csv = api.decisionsCsv(data);
assert.strictEqual(Buffer.from(csv).subarray(0,3).toString('hex'), 'efbbbf');
assert.strictEqual(csv.split('\r\n')[0], '\uFEFF' + expected.map(x => '"' + x + '"').join(','));
assert(csv.includes('"line one\r\n""quoted"", comment"'));
assert(csv.includes(data[0].IfAlias.replace(/"/g, '""')));
assert.deepStrictEqual(Array.from(api.effectiveGroups(data[0])), ['Group A']);
const row = {...data[0], Groups:' ;  ;'};
assert.throws(() => api.decisionsCsv([row]), /group name/);
row.Exclude = 'True';
assert.strictEqual(api.validateRows([row]).length, 0);
assert.strictEqual(api.effectiveGroups(row).length, 0);
row.Apply = 'False';
assert.deepStrictEqual(Array.from(api.effectiveGroups(row)), ['Group A']);
row.Apply = 'True'; row.Exclude = 'False'; row.Groups = ' A ;a; B ';
assert.deepStrictEqual(Array.from(api.effectiveGroups(row)), ['A','B']);
assert.strictEqual(api.decisionsCsv([]), '\uFEFF' + expected.map(x => '"' + x + '"').join(',') + '\r\n');
const saved = api.decisionsCsv(data);
fs.writeFileSync(process.argv[3], saved);
assert.strictEqual(data[0].InterfaceName, 'Port 7');
console.log('PASS: JavaScript BOM CSV schema, escaping, validation, overlap, and effective membership');
class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.events = {}; this.attributes = {}; this.value = ''; this.textContent = ''; this.hidden = false; this.classList = {toggle(){}}; }
    appendChild(child) { this.children.push(child); return child; }
    setAttribute(name, value) { this.attributes[name] = value; }
    addEventListener(event, handler) { this.events[event] = handler; }
    click() { if (this.events.click) this.events.click(); }
    focus() { this.focused = true; }
    remove() {}
}
const controls = {};
for (const id of ['review-body','review-data','search','validation','counts','preview','group-summary','select-visible','clear-selection','bulk-groups','assign-selected','exclude-selected','reset-selected','accept-automatic','preview-edits','download']) controls[id] = new Element(id);
controls['review-data'].textContent = JSON.stringify(data);
let downloaded;
let confirmationCount = 0;
const browser = vm.createContext({
    document:{getElementById:id => controls[id], createElement:tag => new Element(tag), body:new Element('body')},
    window:{confirm:message => { confirmationCount++; assert(message.includes('Existing edits')); return true; }},
    Blob:class { constructor(parts) { this.parts = parts; } },
    URL:{createObjectURL(blob) { downloaded = blob.parts.join(''); return 'blob:local'; }, revokeObjectURL(){}},
    setTimeout:handler => handler()
});
vm.runInContext(scripts[0][1], browser);
const cells = controls['review-body'].children[0].children;
assert(controls['group-summary'].textContent.includes('Group A: 1 interface(s)'));
assert(controls['group-summary'].textContent.includes('0 unmatched; 0 overlapping'));
assert.strictEqual(cells[1].textContent, data[0].DeviceName + '\n88:7');
assert.strictEqual(cells[3].children[0].textContent, 'IfAlias: ' + data[0].IfAlias);
controls.search.value = 'missing'; controls.search.events.input();
assert.strictEqual(controls['review-body'].children[0].hidden, true);
controls['select-visible'].click();
assert(controls.counts.textContent.includes('0 selected'));
controls.search.value = '88:7'; controls.search.events.input();
controls['select-visible'].click();
controls['bulk-groups'].value = 'New A; New B';
controls['assign-selected'].click();
assert.strictEqual(cells[5].children[0].value, 'New A;New B');
assert(controls.counts.textContent.includes('1 overlapping'));
controls['preview-edits'].click();
assert(controls.preview.textContent.includes('New A; New B'));
controls['bulk-groups'].value = ''; controls['assign-selected'].click();
assert.strictEqual(cells[5].children[0].value, 'New A;New B');
assert.strictEqual(cells[6].children[0].checked, true);
assert(controls.validation.textContent.includes('No rows were changed'));
controls.search.value = 'missing'; controls.search.events.input();
assert(controls.counts.textContent.includes('1 selected (1 hidden by search'));
controls['exclude-selected'].click(); controls.download.click();
assert(downloaded.includes('"True","True"'));
assert(controls.counts.textContent.includes('1 excluded'));
const apply = cells[6].children[0]; apply.checked = false; apply.events.change();
assert(controls.preview.textContent.includes('Group A'));
assert.strictEqual(cells[3].children[0].textContent, 'IfAlias: ' + data[0].IfAlias);
controls.search.value = ''; controls.search.events.input();
controls['reset-selected'].click();
assert.strictEqual(cells[5].children[0].value, 'Group A');
assert.strictEqual(cells[6].children[0].checked, false);
assert.strictEqual(cells[7].children[0].checked, false);
cells[5].children[0].value = 'Manual'; cells[5].children[0].events.input();
cells[6].children[0].checked = true; cells[6].children[0].events.change();
controls['accept-automatic'].click();
assert.strictEqual(confirmationCount, 1);
assert.strictEqual(cells[5].children[0].value, 'Group A');
assert.strictEqual(cells[6].children[0].checked, false);
assert.strictEqual(cells[7].children[0].checked, false);
controls['accept-automatic'].click();
assert.strictEqual(confirmationCount, 1);
controls['clear-selection'].click();
controls['reset-selected'].click();
assert(controls.validation.textContent.includes('Select at least one row to reset'));
assert.strictEqual(cells[5].children[0].value, 'Group A');
controls['bulk-groups'].value = 'Unselected change'; controls['assign-selected'].click();
assert(controls.validation.textContent.includes('Select at least one row'));
assert.strictEqual(cells[5].children[0].value, 'Group A');
controls['download'].click();
assert(downloaded.includes('"False","False"'));
assert(controls.counts.textContent.includes('0 selected'));
console.log('PASS: blank/no-selection guards, hidden selection, reset/accept automatic decisions, grouped summary, CSV, and immutable metadata');
'@
        [IO.File]::WriteAllText($javascriptPath, $javascript, [Text.UTF8Encoding]::new($true))
        $csvPath = Join-Path $outputDirectory 'decisions.csv'
        & node $javascriptPath $path $csvPath
        Assert-Review ($LASTEXITCODE -eq 0) 'Node browser review logic tests failed.'
        $decisions = @(Import-Csv -LiteralPath $csvPath)
        Assert-Review ($decisions[0].InterfaceComment -ceq $inventory[0].InterfaceComment) 'Downloaded CSV changed descriptions.'
        $applied = @(Set-InterfaceGroupReview -Inventory $inventory -Groups $groups -Decisions $decisions)
        Assert-Review ($applied.Count -eq 1 -and $applied[0].Name -eq 'Group A') 'Downloaded CSV is not importer-compatible.'
        Write-Output 'PASS: downloaded CSV round-trip through existing decision importer'
    }
    else { Write-Warning 'Node.js unavailable: JavaScript CSV logic tests skipped.' }
}
finally {
    if (Test-Path -LiteralPath $outputDirectory) { Remove-Item -LiteralPath $outputDirectory -Recurse -Force }
    Remove-Item -LiteralPath Function:\Get-Item
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAmSB+kfbg4vIhZ
# j+HR2xXyJlJzIdz7PioYvWB/SK6K2KCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCB/
# zUTk7h5GD7rLbepgHMqVGCB6o1qDxQmvoAMSdFCzdTANBgkqhkiG9w0BAQEFAASC
# AgCFq+UcnRL3thGutRak6Wd1BvzgCaPIVqAm3ZhKmwa3AKd9+S0+7guQlxXzKqTQ
# 2E4KYxlVt6JO+l299dZzy0pztl4Dz7E+kFL8jf+olOnbYibqIGDLYK9+U/AM5TRj
# xK03tEpUGDM6NYffMUue+2fa2NcEorAoVSmLcvQAV4bXZ2iT6XmBSelPh25pPsbM
# ExsweRTK4dJ8eIHlb2F7Qnv9yDjedSfnNfItFwn7nR70Zmpqd/PJPK8xg80K5f9q
# u846sihsvW10el9RK9n8/YX7yZ2LxXY0RIwKZxCAvhnVi1c8Nx1P17reoZdAyMR/
# lykULu0wh8goQhaVd4MfC5BKWi4vkHGgXP15WmZZKm1E6rjDf1LsFzgCobr0ss+w
# 6ls440SxAkPD6VYn0umElvqCmxXkxe0bWUeSRmubSliPjxIm4xyb7RekgNTDLaEl
# Tv6ECR95xlLe6jq1dHBRimN/OOxgY+GLidgHPhC7fR0AvTuBBfO3YwQd87WzqXJu
# gzD0ku6TtU6cRVDvz/EZW8DLfLajO61H/Mb3PdE56nWOL+YAK0Vs5toG69lnXkk6
# ce2owD08ed/sfJ4l+J0v6r0kgXvcJro0vOQ8sq80TdkKCazKABClyI1lcAxVwnzy
# BMp8ajmg5Yygqr0ye8iuavWukKdwTV9pPWrdyvKp+VXbd6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTI3MDZaMC8GCSqGSIb3DQEJBDEiBCCaLMC322Uq
# K5Cw6X7oNsWISFqpYMLwbsEQpuL/WKPfnzANBgkqhkiG9w0BAQEFAASCAgBNLvCJ
# cq76JTQOQeDj3lIFsYVsqrBlNYw/MZyslBYEm4WsKlmSC1W8D+nGkKvSodYO7TK3
# hfPrVaE4Q9X2sdrOcAifrhBYNYXB01WkYlnodygkl4i85TnRakcJDdW2z/l5r3Xl
# tXRygv8Qk151Lfn4ckrM6Ld7qjiOznYyZU7Y+OEA1T5K4k+Tm2lcyrp16kEZvv7K
# 2rVY1ZceAXUjQdDAVngrQSVK9u8ahFDnSi4/4jlmglw67IsISME1+vqserP+1siG
# /fclVeOHUcUq4YAVBw15tfyjqhFosX6ji0xWiEkPZ/JgW2bFfLD8Ep4Uv21SPWSS
# 5SuEsA+3I0x6eKNcSCmviflCcF7l9WZBUZGu7BUrgHcdmg7KJMGD41RqY0VtacPJ
# p56+aGmjYxCcfPbfs7U5eU7wHmWhNeDBRJWJu+mD4yJzxLFzguC+LRN0VGy2qfco
# hR63gfz3aJT7wh1vcsRH0XIJJjE1+Bim5/dxZ38MRtI9LLUGecFhRYva+zHq1eG3
# U9NKiTCwW8WKnzmoN8AcPN6t2WHC9H0JuSNnlRDq4ecFQ1aRsnwMl/x84gpu5wss
# EVuP36XkJ1evmNo3CkLPPIxB6ZLcjKX7zLVIRVnrsD07FPdOR4Oiug7xZo3ZXx2v
# yIhV91VA4UmUR0WSOVRhBm07RdUkzZ/nSLF92Q==
# SIG # End signature block
