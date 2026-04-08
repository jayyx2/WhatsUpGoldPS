<#
.SYNOPSIS
    End-to-end integration test for WhatsUpGoldPS geolocation map helpers.

.DESCRIPTION
    Connects to a WhatsUp Gold server, creates test devices and groups with
    latitude/longitude data, exercises the geolocation helper functions
    (Get-GeoDevicesWithLocation, Get-GeoGroupsWithLocation, Get-GeolocationData,
    Export-GeolocationMapHtml), and cleans up all test artefacts.

    Tests both the WhatsUpGoldPS module (attribute and group APIs) and the
    standalone GeolocationHelpers functions.

.PARAMETER ServerUri
    The WhatsUp Gold server hostname or IP. If omitted you will be prompted.

.PARAMETER Credential
    A PSCredential for authentication. If omitted you will be prompted.

.PARAMETER Port
    API port. Default 9644.

.PARAMETER Protocol
    http or https. Default https.

.PARAMETER IgnoreSSLErrors
    Pass -IgnoreSSLErrors to Connect-WUGServer when set.

.EXAMPLE
    .\Invoke-WUGGeomapTest.ps1

.EXAMPLE
    .\Invoke-WUGGeomapTest.ps1 -ServerUri "192.168.74.74" -Credential (Get-Credential)

.NOTES
    Author : Jason Alberino (jason@wug.ninja)
    Created: 2025-07-15
    Requires: WhatsUpGoldPS module loaded, GeolocationHelpers.ps1 in ../geolocation/
#>
[CmdletBinding()]
param(
    [string]$ServerUri,
    [PSCredential]$Credential,
    [int]$Port = 9644,
    [ValidateSet('http', 'https')]
    [string]$Protocol = 'https',
    [switch]$IgnoreSSLErrors
)

#region -- Helpers ------------------------------------------------------------
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Record-Test {
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [string]$Status,
        [string]$Detail = ''
    )
    $script:TestResults.Add([PSCustomObject]@{
        Cmdlet   = $Cmdlet
        Endpoint = $Endpoint
        Status   = $Status
        Detail   = $Detail
    })
    $color = switch ($Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } default { 'Yellow' } }
    Write-Host "  [$Status] $Cmdlet  ($Endpoint)  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [scriptblock]$Test
    )
    try {
        $null = & $Test
        Record-Test -Cmdlet $Cmdlet -Endpoint $Endpoint -Status 'Pass'
    }
    catch {
        Record-Test -Cmdlet $Cmdlet -Endpoint $Endpoint -Status 'Fail' -Detail $_.Exception.Message
    }
}
#endregion

#region -- Module + helper imports --------------------------------------------
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    $modulePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'WhatsUpGoldPS.psm1'
    try   { Import-Module $modulePath -Force -ErrorAction Stop }
    catch { Write-Error "Cannot load WhatsUpGoldPS module: $_"; return }
}

$geoHelpersPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\GeolocationHelpers.ps1'
if (-not (Test-Path $geoHelpersPath)) {
    Write-Error "GeolocationHelpers.ps1 not found at: $geoHelpersPath"; return
}
. $geoHelpersPath

# Load vault functions for credential resolution
$discoveryHelpersPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) { . $discoveryHelpersPath }
#endregion

#region -- Prompt for connection details --------------------------------------
if (-not $ServerUri) {
    $wugCred = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -ProviderLabel 'WhatsUp Gold' -AutoUse
    if ($wugCred) {
        $ServerUri = $wugCred.UserName
        if (-not $Credential) { $Credential = $wugCred }
    } else {
        $ServerUri = Read-Host "Enter WhatsUp Gold server hostname or IP"
    }
}
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter WhatsUp Gold credentials"
}
#endregion

#region -- Connect (WhatsUpGoldPS module) -------------------------------------
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " WhatsUpGoldPS Geolocation Map E2E Test Suite" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

$connectParams = @{
    serverUri       = $ServerUri
    Credential      = $Credential
    Port            = $Port
    Protocol        = $Protocol
    IgnoreSSLErrors = $true
}

Write-Host "[1/6] Connecting to $ServerUri via WhatsUpGoldPS ..." -ForegroundColor Cyan
Invoke-Test -Cmdlet 'Connect-WUGServer' -Endpoint 'POST /token' -Test {
    Connect-WUGServer @connectParams -ErrorAction Stop
    if (-not $global:WUGBearerHeaders) { throw "No bearer headers after connect" }
}

if (-not $global:WUGBearerHeaders) {
    Write-Host "`n  FATAL: Authentication failed. Cannot continue." -ForegroundColor Red
    $script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail
    return
}
#endregion

#region -- Connect (Geolocation Helpers - independent auth) -------------------
Write-Host "`n[2/6] Connecting via GeolocationHelpers Connect-GeoWUGServer ..." -ForegroundColor Cyan

$script:GeoConfig = $null

Invoke-Test -Cmdlet 'Connect-GeoWUGServer' -Endpoint 'POST /token (geo)' -Test {
    $username = $Credential.GetNetworkCredential().UserName
    $password = $Credential.GetNetworkCredential().Password
    $script:GeoConfig = Connect-GeoWUGServer -ServerUri $ServerUri -Username $username -Password $password `
        -Protocol $Protocol -Port $Port -IgnoreSSLErrors -ErrorAction Stop
    if (-not $script:GeoConfig._AccessToken) { throw "No access token returned" }
}

if (-not $script:GeoConfig) {
    Write-Host "`n  FATAL: Geo helper authentication failed. Cannot continue geo tests." -ForegroundColor Red
    $script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail
    return
}
#endregion

#region -- Create test artefacts with geolocation data ------------------------
Write-Host "`n[3/6] Creating test device and group with lat/lng data ..." -ForegroundColor Cyan

$script:GeoTestDeviceId = $null
$script:GeoTestGroupId  = $null
$script:GeoTestDeviceName = "WUGPS-GeoTest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$script:GeoTestGroupName  = "WUGPS-GeoGroup-$([guid]::NewGuid().ToString('N').Substring(0,8))"

# Test latitude/longitude values (New York City)
$testLat = '40.7128'
$testLng = '-74.0060'

# -- Create a test device -----------------------------------------------------
Invoke-Test -Cmdlet 'Add-WUGDeviceTemplate (geo device)' -Endpoint 'POST /devices/-/config/template' -Test {
    $result = Add-WUGDeviceTemplate -DeviceAddress '127.0.0.5' -displayName $script:GeoTestDeviceName `
        -primaryRole 'Device' -note "Geolocation test device" -Confirm:$false -ErrorAction Stop
    if (-not $result) { throw "No result" }
    $script:GeoTestDeviceId = $result.idMap.resultId
    if (-not $script:GeoTestDeviceId) { throw "No resultId" }
}

if ($script:GeoTestDeviceId) {
    Start-Sleep -Seconds 3

    # -- Set LatLong attribute (single "lat,lng" format) ----------------------
    Invoke-Test -Cmdlet 'Set-WUGDeviceAttribute (LatLong)' -Endpoint 'POST /devices/{id}/attributes/-' -Test {
        Set-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Name "LatLong" -Value "$testLat,$testLng" `
            -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # -- Verify attribute was set ---------------------------------------------
    Invoke-Test -Cmdlet 'Get-WUGDeviceAttribute (LatLong verify)' -Endpoint 'GET /devices/{id}/attributes/-' -Test {
        $attrs = Get-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Names "LatLong" -ErrorAction Stop
        $found = $false
        if ($attrs) {
            foreach ($a in @($attrs)) {
                if ($a.name -eq 'LatLong' -and $a.value -match "$testLat") { $found = $true; break }
            }
        }
        if (-not $found) { throw "LatLong attribute not found or value mismatch" }
    }

    # -- Also test separate Latitude/Longitude attributes ---------------------
    Invoke-Test -Cmdlet 'Set-WUGDeviceAttribute (Latitude)' -Endpoint 'POST /devices/{id}/attributes/-' -Test {
        Set-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Name "Latitude" -Value $testLat `
            -Confirm:$false -ErrorAction Stop | Out-Null
    }
    Invoke-Test -Cmdlet 'Set-WUGDeviceAttribute (Longitude)' -Endpoint 'POST /devices/{id}/attributes/-' -Test {
        Set-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Name "Longitude" -Value $testLng `
            -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# -- Create a test group with lat,lng in description -------------------------
Invoke-Test -Cmdlet 'Add-WUGDeviceGroup (geo group)' -Endpoint 'POST /device-groups/{id}/children' -Test {
    $result = Add-WUGDeviceGroup -ParentGroupId 0 -Name $script:GeoTestGroupName `
        -Description "$testLat,$testLng" -Confirm:$false -ErrorAction Stop
    if (-not $result) { throw "No result from Add-WUGDeviceGroup" }
    $script:GeoTestGroupId = if ($result.id) { $result.id } elseif ($result.groupId) { $result.groupId } else { $result }
}
#endregion

#region -- Test GeolocationHelpers functions ----------------------------------
Write-Host "`n[4/6] Testing GeolocationHelpers data-retrieval functions ..." -ForegroundColor Cyan

$script:GeoDeviceData = $null
$script:GeoGroupData  = $null
$script:GeoAllData    = $null

# -- Get-GeoDevicesWithLocation (LatLong attribute) ---------------------------
if ($script:GeoTestDeviceId -and $script:GeoConfig) {
    Invoke-Test -Cmdlet 'Get-GeoDevicesWithLocation (LatLong)' -Endpoint 'GET /devices/-/attributes (LatLong)' -Test {
        $result = Get-GeoDevicesWithLocation -Config $script:GeoConfig -ErrorAction Stop
        $script:GeoDeviceData = $result
        # Look for our test device in the results
        $found = $false
        if ($result) {
            foreach ($d in @($result)) {
                if ($d.Name -eq $script:GeoTestDeviceName) { $found = $true; break }
            }
        }
        if (-not $found) { throw "Test device '$($script:GeoTestDeviceName)' not found in geolocation results" }
    }

    # -- Get-GeoDevicesWithLocation (UseBuiltinCoords) ------------------------
    Invoke-Test -Cmdlet 'Get-GeoDevicesWithLocation (BuiltinCoords)' -Endpoint 'GET /devices/-/attributes (Lat+Lng)' -Test {
        $result = Get-GeoDevicesWithLocation -Config $script:GeoConfig -UseBuiltinCoords -ErrorAction Stop
        $found = $false
        if ($result) {
            foreach ($d in @($result)) {
                if ($d.Name -eq $script:GeoTestDeviceName) {
                    if ($d.Latitude -ne [double]$testLat -or $d.Longitude -ne [double]$testLng) {
                        throw "Coordinates mismatch: expected $testLat,$testLng got $($d.Latitude),$($d.Longitude)"
                    }
                    $found = $true; break
                }
            }
        }
        if (-not $found) { throw "Test device not found with builtin coords" }
    }
}

# -- Get-GeoGroupsWithLocation -----------------------------------------------
if ($script:GeoTestGroupId -and $script:GeoConfig) {
    Invoke-Test -Cmdlet 'Get-GeoGroupsWithLocation' -Endpoint 'GET /device-groups/-/definition' -Test {
        $result = Get-GeoGroupsWithLocation -Config $script:GeoConfig -ErrorAction Stop
        $script:GeoGroupData = $result
        $found = $false
        if ($result) {
            foreach ($g in @($result)) {
                if ($g.Name -eq $script:GeoTestGroupName) {
                    if ($g.Latitude -ne [double]$testLat -or $g.Longitude -ne [double]$testLng) {
                        throw "Group coordinates mismatch: expected $testLat,$testLng got $($g.Latitude),$($g.Longitude)"
                    }
                    $found = $true; break
                }
            }
        }
        if (-not $found) { throw "Test group '$($script:GeoTestGroupName)' not found in geolocation results" }
    }
}

# -- Get-GeolocationData (combined) ------------------------------------------
if ($script:GeoConfig) {
    Invoke-Test -Cmdlet 'Get-GeolocationData (all)' -Endpoint 'GET /devices + /device-groups (combined)' -Test {
        $result = Get-GeolocationData -Config $script:GeoConfig -ErrorAction Stop
        $script:GeoAllData = $result
        if ($null -eq $result -or @($result).Count -eq 0) { throw "No geolocation data returned" }
    }

    Invoke-Test -Cmdlet 'Get-GeolocationData (devices only)' -Endpoint 'GET /devices (devices only)' -Test {
        $result = Get-GeolocationData -Config $script:GeoConfig -IncludeDevices $true -IncludeGroups $false -ErrorAction Stop
        if ($result) {
            $hasGroup = $false
            foreach ($r in @($result)) { if ($r.Type -eq 'Group') { $hasGroup = $true; break } }
            if ($hasGroup) { throw "Groups should be excluded but were found" }
        }
    }

    Invoke-Test -Cmdlet 'Get-GeolocationData (groups only)' -Endpoint 'GET /device-groups (groups only)' -Test {
        $result = Get-GeolocationData -Config $script:GeoConfig -IncludeDevices $false -IncludeGroups $true -ErrorAction Stop
        if ($result) {
            $hasDevice = $false
            foreach ($r in @($result)) { if ($r.Type -eq 'Device') { $hasDevice = $true; break } }
            if ($hasDevice) { throw "Devices should be excluded but were found" }
        }
    }
}
#endregion

#region -- Test new geolocation parameters ------------------------------------
Write-Host "`n[4b/6] Testing new geolocation parameters (cache, skip, refresh) ..." -ForegroundColor Cyan

# -- Get-GeoDevicesWithLocation -RefreshCache ---------------------------------
if ($script:GeoTestDeviceId -and $script:GeoConfig) {
    Invoke-Test -Cmdlet 'Get-GeoDevicesWithLocation (-RefreshCache)' -Endpoint 'GET /devices/-/attributes (force refresh)' -Test {
        $result = Get-GeoDevicesWithLocation -Config $script:GeoConfig -RefreshCache -ErrorAction Stop
        $found = $false
        if ($result) {
            foreach ($d in @($result)) {
                if ($d.Name -eq $script:GeoTestDeviceName) { $found = $true; break }
            }
        }
        if (-not $found) { throw "Test device not found after RefreshCache" }
    }

    # Verify cache file was created
    Invoke-Test -Cmdlet 'Location cache file exists' -Endpoint '(cache file check)' -Test {
        $cacheFile = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Cache\geolocation-coords.json'
        if (-not (Test-Path $cacheFile)) { throw "Cache file not created at: $cacheFile" }
        $cacheContent = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $cacheContent -or @($cacheContent).Count -eq 0) { throw "Cache file is empty" }
    }

    # Run again WITHOUT -RefreshCache to exercise cache-hit path
    Invoke-Test -Cmdlet 'Get-GeoDevicesWithLocation (cache hit)' -Endpoint 'GET /devices/-/attributes (cached)' -Test {
        $result = Get-GeoDevicesWithLocation -Config $script:GeoConfig -ErrorAction Stop
        $found = $false
        if ($result) {
            foreach ($d in @($result)) {
                if ($d.Name -eq $script:GeoTestDeviceName) { $found = $true; break }
            }
        }
        if (-not $found) { throw "Test device not found on cached run" }
    }
}

# -- Get-GeolocationData with SkipDevices / SkipGroups equivalents ------------
if ($script:GeoConfig) {
    # IncludeDevices=$false is the equivalent of SkipDevices on the helper level
    Invoke-Test -Cmdlet 'Get-GeolocationData (skip devices)' -Endpoint 'GET /device-groups only (skip devices)' -Test {
        $result = Get-GeolocationData -Config $script:GeoConfig -IncludeDevices $false -IncludeGroups $true -ErrorAction Stop
        if ($result) {
            $hasDevice = $false
            foreach ($r in @($result)) { if ($r.Type -eq 'Device') { $hasDevice = $true; break } }
            if ($hasDevice) { throw "Devices should be excluded with SkipDevices but were found" }
        }
    }

    Invoke-Test -Cmdlet 'Get-GeolocationData (skip groups)' -Endpoint 'GET /devices only (skip groups)' -Test {
        $result = Get-GeolocationData -Config $script:GeoConfig -IncludeDevices $true -IncludeGroups $false -ErrorAction Stop
        if ($result) {
            $hasGroup = $false
            foreach ($r in @($result)) { if ($r.Type -eq 'Group') { $hasGroup = $true; break } }
            if ($hasGroup) { throw "Groups should be excluded with SkipGroups but were found" }
        }
    }
}

# -- Export-GeolocationMapHtml with -RefreshIntervalSeconds -------------------
if ($script:GeoAllData -and @($script:GeoAllData).Count -gt 0) {
    $script:RefreshMapPath = Join-Path $env:TEMP "WUGPS-GeoTest-Refresh-$(Get-Date -Format 'yyyyMMddHHmmss').html"

    Invoke-Test -Cmdlet 'Export-GeolocationMapHtml (-RefreshIntervalSeconds)' -Endpoint '(HTML auto-refresh)' -Test {
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $resultPath = Export-GeolocationMapHtml -Data @($script:GeoAllData) -OutputPath $script:RefreshMapPath `
            -TemplatePath $templatePath -RefreshIntervalSeconds 300 -ErrorAction Stop
        if (-not (Test-Path $resultPath)) { throw "Refresh map file not created" }
        $content = Get-Content $resultPath -Raw
        if ($content -notmatch 'meta http-equiv="refresh" content="300"') {
            throw "Auto-refresh meta tag not found in generated HTML"
        }
    }

    # Verify that RefreshIntervalSeconds=0 does NOT inject the tag
    Invoke-Test -Cmdlet 'Export-GeolocationMapHtml (no refresh)' -Endpoint '(HTML no auto-refresh)' -Test {
        $noRefreshPath = Join-Path $env:TEMP "WUGPS-GeoTest-NoRefresh-$(Get-Date -Format 'yyyyMMddHHmmss').html"
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $resultPath = Export-GeolocationMapHtml -Data @($script:GeoAllData) -OutputPath $noRefreshPath `
            -TemplatePath $templatePath -RefreshIntervalSeconds 0 -ErrorAction Stop
        $content = Get-Content $resultPath -Raw
        if ($content -match 'http-equiv="refresh"') {
            throw "Auto-refresh meta tag should NOT be present when interval is 0"
        }
        Remove-Item $noRefreshPath -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region -- Test map HTML export -----------------------------------------------
Write-Host "`n[5/6] Testing Export-GeolocationMapHtml ..." -ForegroundColor Cyan

$script:MapOutputPath = Join-Path $env:TEMP "WUGPS-GeoTest-Map-$(Get-Date -Format 'yyyyMMddHHmmss').html"

if ($script:GeoAllData -and @($script:GeoAllData).Count -gt 0) {
    Invoke-Test -Cmdlet 'Export-GeolocationMapHtml' -Endpoint '(HTML generation)' -Test {
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $exportParams = @{
            Data         = @($script:GeoAllData)
            OutputPath   = $script:MapOutputPath
            TemplatePath = $templatePath
            DefaultLat   = [double]$testLat
            DefaultLng   = [double]$testLng
            DefaultZoom  = 10
        }
        $resultPath = Export-GeolocationMapHtml @exportParams -ErrorAction Stop
        if (-not (Test-Path $resultPath)) { throw "Map file not created at: $resultPath" }
        $content = Get-Content $resultPath -Raw
        if ($content.Length -lt 100) { throw "Map file too small ($($content.Length) bytes)" }
        if ($content -notmatch 'leaflet') { throw "Map file does not contain Leaflet references" }
        Write-Verbose "Map generated: $resultPath ($($content.Length) bytes)"
    }

    # Verify test device marker is in the generated map
    Invoke-Test -Cmdlet 'Export-GeolocationMapHtml (verify markers)' -Endpoint '(HTML content check)' -Test {
        if (-not (Test-Path $script:MapOutputPath)) { throw "Map file missing" }
        $content = Get-Content $script:MapOutputPath -Raw
        if ($content -notmatch [regex]::Escape($script:GeoTestDeviceName)) {
            throw "Test device name not found in generated map HTML"
        }
    }
}
else {
    Record-Test -Cmdlet 'Export-GeolocationMapHtml' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No geolocation data available'
}

# Generate all-providers preview with fake API keys (kept on disk for visual review)
$script:AllProvidersMapPath = Join-Path $env:TEMP "WUGPS-GeoTest-AllProviders-$(Get-Date -Format 'yyyyMMddHHmmss').html"

if ($script:GeoAllData -and @($script:GeoAllData).Count -gt 0) {
    Invoke-Test -Cmdlet 'Export-GeolocationMapHtml (all providers)' -Endpoint '(HTML with all tile keys)' -Test {
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $fakeKeys = @{
            thunderforest  = 'test-tf-key'
            stadia         = 'test-sd-key'
            maptiler       = 'test-mt-key'
            here           = 'test-here-key'
            mapbox         = 'pk.test-mb-key'
            jawg           = 'test-jw-key'
            tomtom         = 'test-tt-key'
            openweathermap = 'test-owm-key'
        }
        $exportParams = @{
            Data         = @($script:GeoAllData)
            OutputPath   = $script:AllProvidersMapPath
            TemplatePath = $templatePath
            DefaultLat   = [double]$testLat
            DefaultLng   = [double]$testLng
            DefaultZoom  = 10
            TileApiKeys  = $fakeKeys
        }
        $resultPath = Export-GeolocationMapHtml @exportParams -ErrorAction Stop
        if (-not (Test-Path $resultPath)) { throw "All-providers map not created at: $resultPath" }
        $content = Get-Content $resultPath -Raw
        $missing = @()
        foreach ($prov in @('thunderforest','stadia','maptiler','here','mapbox','jawg','tomtom','openweathermap')) {
            if ($content -notmatch $prov) { $missing += $prov }
        }
        if ($missing.Count -gt 0) { throw "Missing provider blocks: $($missing -join ', ')" }
        if ($content -notmatch 'id="settings-panel"') { throw "Settings panel not found in output" }
        if ($content -notmatch 'Weather Overlays') { throw "Weather overlay box not found (OWM key was provided)" }
        Write-Host "  All-providers map kept at: $resultPath" -ForegroundColor Green
    }
}
else {
    Record-Test -Cmdlet 'Export-GeolocationMapHtml (all providers)' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No geolocation data available'
}
#endregion

#region -- Cleanup ------------------------------------------------------------
Write-Host "`n[6/6] Cleaning up test artefacts ..." -ForegroundColor Cyan

# Remove the test device
if ($script:GeoTestDeviceId) {
    Invoke-Test -Cmdlet 'Remove-WUGDevice (geo device)' -Endpoint 'DELETE /devices/{id}' -Test {
        Remove-WUGDevice -DeviceId $script:GeoTestDeviceId -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Remove the test group
if ($script:GeoTestGroupId) {
    Invoke-Test -Cmdlet 'Remove-WUGDeviceGroup (geo group)' -Endpoint 'DELETE /device-groups/{id}' -Test {
        Remove-WUGDeviceGroup -GroupId $script:GeoTestGroupId -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Remove generated map file
if ($script:MapOutputPath -and (Test-Path $script:MapOutputPath)) {
    Remove-Item -Path $script:MapOutputPath -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed temp map file: $($script:MapOutputPath)" -ForegroundColor DarkGray
}

# Remove refresh test map file
if ($script:RefreshMapPath -and (Test-Path $script:RefreshMapPath)) {
    Remove-Item -Path $script:RefreshMapPath -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed temp refresh map file: $($script:RefreshMapPath)" -ForegroundColor DarkGray
}

# Disconnect
Invoke-Test -Cmdlet 'Disconnect-WUGServer' -Endpoint '(session cleanup)' -Test {
    Disconnect-WUGServer -ErrorAction Stop
    if ($global:WUGBearerHeaders) { throw "Headers still set after disconnect" }
}
#endregion

#region -- Summary ------------------------------------------------------------
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " GEOLOCATION TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$passed  = ($script:TestResults | Where-Object Status -eq 'Pass').Count
$failed  = ($script:TestResults | Where-Object Status -eq 'Fail').Count
$skipped = ($script:TestResults | Where-Object Status -eq 'Skipped').Count
$total   = $script:TestResults.Count

Write-Host "`n  Total : $total" -ForegroundColor White
Write-Host "  Pass  : $passed" -ForegroundColor Green
Write-Host "  Fail  : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skip  : $skipped" -ForegroundColor Yellow

if ($failed -gt 0) {
    Write-Host "`n  FAILED TESTS:" -ForegroundColor Red
    $script:TestResults | Where-Object Status -eq 'Fail' | ForEach-Object {
        Write-Host "    - $($_.Cmdlet)  [$($_.Endpoint)]" -ForegroundColor Red
        if ($_.Detail) { Write-Host "      $($_.Detail)" -ForegroundColor DarkRed }
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan

$script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail

# Return results object
$script:TestResults
#endregion

# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAtzIrquO8IVTZc
# JPHy+vkAacz6ZvY5cKtqA5pba9DtkaCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCADNJgt
# j+PmzZcQn6shCkOW+ea9yq6ns+pf0wCSfZVuxzANBgkqhkiG9w0BAQEFAASCAgCd
# 0DmYS2OLlIMM05pVV7+g6I0+Z6zghlBPPh4fEGbGEop5/2Tl7U2uQlvr5JuF0PIx
# WYi49uXPK7jqRPqvNhN5MxVAruCkhWN1oRXqoyP5nT/dvjOGTMj8EqkZfTKqrcud
# nuZzgxk90ZQ54uz8r+vlp/7NyOgybpanOVDfM924mqwccAguRzEImLptxwSYmQkk
# sGSH574HC+h9U/pquDkTlnE3hFwVSqTOZTtiWf8Q+sBhmGo2/RgiHkmBUgx3U62L
# P5YS/ZvzmA45ihzEghEY3+R8wEtvHyf8PqY6C6NqPmnPLkD1KXI5R4pPYvlixxMN
# TAqTmWExBp7DUYFFQ9UnsCzBa/QHsobQXsP8bwuLG+UcPu0VxCzs03YpmmpUnNmJ
# nOPoeD3Ra0/Xp+8T1sR91/IqC3QJnXY7VCgH1RKaY62fNrpW+txhdSZ+8X4v0v/o
# 3SpELGBqtI14zQlzcgfrgtDpRlglUIg6sl7W/D/RfAVlbpH3fUD0Q82FLBch8F8h
# ROMXm8Od4SK7tERyhRM+zSFJcd1skwqsHQ8hkjz68YP7Uqvp2VEgAgx8I4MvV961
# s0KL9xWz+o3Nnv+K1/smOoYFXoi/bHVrI24q8zhs4LtT4qh31edGkhOz3dlf0hWT
# zFZlVJlCbfwwpPZ/oZz5zCdPlC74ybB8xBHby5XHfqGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzE4NDAx
# MlowPwYJKoZIhvcNAQkEMTIEMGaNo5RvUghFOcfGQOfbj4GSA/L4BT+UnjGHwXaJ
# 0MYYWXr4yhdnALQ46n5LjpZceDANBgkqhkiG9w0BAQEFAASCAgA9uHFwOo3ChssO
# PI5OhIKiRstGmB41zWfW+mEsdiIxCXxWMx5OO6qVfgeM0RL9NEEq0ODTkZgwTCSR
# oMSy2B1j6RHwwqPheR/JcuNqXoMpkESTTSsHzvSGM4SpDfTip1y5s1KVAsjyH4Os
# syrmDvbP7bGFviqbMLApc57Ayyb2/7yaxBhDY9T1b4/eDmfPdJjWjJOJ9aCgYpvv
# JjX2Ak4IXgRCN0J1V0j7EXkWGXyO7JQwDu4kuduiS+UACy3esXbswAres6Vde5iR
# l/uar7n+Tuyo8yloYhzhhstZieWqvPDlkwc9pkG+cHa25XRAoDDcWR8g1UGEdllF
# rUWfpKMJQYnu5CRSj1rFpuqxa+bNfEsltIG3CVJM5xAMdXIsPQhvbX+euCpDbyFp
# fRnrukV+yOQglRqUiJwxsP8NNMdKqSKdvLVcjoFliba0pZdIlFn+wpZ8whuhyrmk
# T64C5qBqbWyb7+ZcNbeQ6kVBFWQ9+Cv879OEZgqwX4IUqq7nB0MQCp0eYn5hpyOQ
# 84o8bwpf5TnuHoVkNVN72cI5DmW34FKNFdbWV3zZxdRDJ0+g2XHcQbsz86A7gMYK
# bybPU33ITOYhayTLBxmrPzXBmjPvNBm6r5ogStXxvQFgWPbaeZ+66rHNLZNaGDkz
# 6eXi5GZrKkjmU1yeIOb/v2z6I9cAMQ==
# SIG # End signature block
