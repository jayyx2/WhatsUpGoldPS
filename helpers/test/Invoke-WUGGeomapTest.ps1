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
        $ServerUri = $wugCred.Server
        if (-not $Credential) { $Credential = $wugCred.Credential }
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

# Clear any stale geolocation cache to ensure clean test state
$geoCacheDir = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Cache'
foreach ($f in @('geolocation-coords.json', 'geolocation-no-coords.json')) {
    $p = Join-Path $geoCacheDir $f
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}
Write-Host "  Cleared geolocation cache files" -ForegroundColor DarkGray

$connectParams = @{
    serverUri       = $ServerUri
    Credential      = $Credential
    Port            = $Port
    Protocol        = $Protocol
    IgnoreSSLErrors = $true
}

Write-Host "[1/8] Connecting to $ServerUri via WhatsUpGoldPS ..." -ForegroundColor Cyan
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
Write-Host "`n[2/8] Connecting via GeolocationHelpers Connect-GeoWUGServer ..." -ForegroundColor Cyan

$script:GeoConfig = $null

Invoke-Test -Cmdlet 'Connect-GeoWUGServer' -Endpoint 'POST /token (geo)' -Test {
    $username = $Credential.GetNetworkCredential().UserName
    $password = $Credential.GetNetworkCredential().Password
    $script:GeoConfig = Connect-GeoWUGServer -ServerUri $ServerUri -Username $username -Password $password `
        -Protocol $Protocol -Port $Port -IgnoreSSLErrors -ErrorAction Stop
    $password = $null
    if (-not $script:GeoConfig._AccessToken) { throw "No access token returned" }
}

if (-not $script:GeoConfig) {
    Write-Host "`n  FATAL: Geo helper authentication failed. Cannot continue geo tests." -ForegroundColor Red
    $script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail
    return
}
#endregion

#region -- Create test artefacts with geolocation data ------------------------
Write-Host "`n[3/8] Creating test device and group with lat/lng data ..." -ForegroundColor Cyan

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
Write-Host "`n[4a/8] Testing GeolocationHelpers data-retrieval functions ..." -ForegroundColor Cyan

$script:GeoDeviceData = $null
$script:GeoGroupData  = $null
$script:GeoAllData    = $null

# Wait for the test device to appear in the root group device list.
# WUG may take a few seconds to index a newly created device.
if ($script:GeoTestDeviceId -and $script:GeoConfig) {
    $maxWaitSec = 30; $waitedSec = 0
    $deviceInList = $false
    while (-not $deviceInList -and $waitedSec -lt $maxWaitSec) {
        try {
            $listResult = Invoke-RestMethod -Uri "$($script:GeoConfig.BaseUri)/api/v1/device-groups/0/devices/-?view=overview&limit=500" `
                -Headers @{ "Content-Type" = "application/json"; "Authorization" = "$($script:GeoConfig._TokenType) $($script:GeoConfig._AccessToken)" } -ErrorAction Stop
            if ($listResult.data.devices) {
                foreach ($d in $listResult.data.devices) {
                    $dId = if ($d.id) { $d.id } else { $d.deviceId }
                    if ("$dId" -eq "$($script:GeoTestDeviceId)") { $deviceInList = $true; break }
                }
            }
        }
        catch { Write-Verbose "Device list check error: $_" }
        if (-not $deviceInList) { Start-Sleep -Seconds 5; $waitedSec += 5 }
    }
    if ($deviceInList) {
        Write-Host "  Test device visible in root group (waited ${waitedSec}s)" -ForegroundColor DarkGray
    } else {
        Write-Warning "Test device not in root group after ${maxWaitSec}s - scan tests may fail"
    }
}

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
Write-Host "`n[4b/8] Testing new geolocation parameters (cache, skip, refresh) ..." -ForegroundColor Cyan

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

#region -- Test Set-GeoDeviceLocations (CSV sync) -----------------------------
Write-Host "`n[4c/8] Testing Set-GeoDeviceLocations (CSV sync) ..." -ForegroundColor Cyan

if ($script:GeoTestDeviceId -and $script:GeoConfig) {
    # Get the test device's display name for CSV matching
    $script:SyncCsvPath = Join-Path $env:TEMP "WUGPS-GeoTest-Sync-$(Get-Date -Format 'yyyyMMddHHmmss').csv"
    $script:SyncCsvBadPath = Join-Path $env:TEMP "WUGPS-GeoTest-SyncBad-$(Get-Date -Format 'yyyyMMddHHmmss').csv"

    # -- Create a valid CSV with the test device and a non-existent device -----
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (create CSV)' -Endpoint '(CSV creation)' -Test {
        $csvContent = @"
DeviceName,Latitude,Longitude
$($script:GeoTestDeviceName),34.0522,-118.2437
NonExistentDevice-WUGPS-99999,51.5074,-0.1278
"@
        Set-Content -Path $script:SyncCsvPath -Value $csvContent -Encoding UTF8
        if (-not (Test-Path $script:SyncCsvPath)) { throw "CSV file not created" }
    }

    # -- Test sync with valid CSV (default LatLong mode) ----------------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (sync LatLong)' -Endpoint 'PATCH /devices/{id}/attributes/-' -Test {
        $results = Set-GeoDeviceLocations -Config $script:GeoConfig -CsvPath $script:SyncCsvPath -ErrorAction Stop
        if (-not $results -or @($results).Count -eq 0) { throw "No results returned" }
        $updated = @($results | Where-Object { $_.Status -eq 'Updated' })
        $notFound = @($results | Where-Object { $_.Status -eq 'NotFound' })
        if ($updated.Count -eq 0) { throw "Expected at least 1 Updated device, got 0" }
        if ($notFound.Count -eq 0) { throw "Expected at least 1 NotFound device, got 0" }
    }

    # -- Verify the attribute was actually updated on the device ---------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (verify attribute)' -Endpoint 'GET /devices/{id}/attributes/-' -Test {
        $attrs = Get-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Names "LatLong" -ErrorAction Stop
        $found = $false
        if ($attrs) {
            foreach ($a in @($attrs)) {
                if ($a.name -eq 'LatLong' -and $a.value -match '34\.0522') { $found = $true; break }
            }
        }
        if (-not $found) { throw "LatLong attribute not updated to CSV value (expected 34.0522)" }
    }

    # -- Test sync with UseSeparateAttributes ---------------------------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (separate attrs)' -Endpoint 'PATCH /devices/{id}/attributes/- (Lat+Lng)' -Test {
        $results = Set-GeoDeviceLocations -Config $script:GeoConfig -CsvPath $script:SyncCsvPath `
            -UseSeparateAttributes -ErrorAction Stop
        $updated = @($results | Where-Object { $_.Status -eq 'Updated' })
        if ($updated.Count -eq 0) { throw "Expected at least 1 Updated device with separate attrs" }
    }

    # -- Verify separate attributes were written ------------------------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (verify Lat+Lng)' -Endpoint 'GET /devices/{id}/attributes/- (Lat+Lng)' -Test {
        $attrs = Get-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Names "Latitude","Longitude" -ErrorAction Stop
        $latOk = $false; $lngOk = $false
        if ($attrs) {
            foreach ($a in @($attrs)) {
                if ($a.name -eq 'Latitude'  -and $a.value -match '34\.0522')   { $latOk = $true }
                if ($a.name -eq 'Longitude' -and $a.value -match '-118\.2437') { $lngOk = $true }
            }
        }
        if (-not $latOk) { throw "Latitude attribute not set correctly" }
        if (-not $lngOk) { throw "Longitude attribute not set correctly" }
    }

    # -- Test WhatIf mode (should not change anything) ------------------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (-WhatIf)' -Endpoint '(dry run)' -Test {
        # First reset LatLong back to known value
        Set-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Name "LatLong" -Value "$testLat,$testLng" `
            -Confirm:$false -ErrorAction Stop | Out-Null
        # Create CSV with different coords
        $whatIfCsv = Join-Path $env:TEMP "WUGPS-GeoTest-WhatIf-$(Get-Date -Format 'yyyyMMddHHmmss').csv"
        Set-Content -Path $whatIfCsv -Value "DeviceName,Latitude,Longitude`n$($script:GeoTestDeviceName),45.0,45.0" -Encoding UTF8
        $results = Set-GeoDeviceLocations -Config $script:GeoConfig -CsvPath $whatIfCsv -WhatIf -ErrorAction Stop
        $whatIfResults = @($results | Where-Object { $_.Status -eq 'WhatIf' })
        if ($whatIfResults.Count -eq 0) { throw "Expected WhatIf status in results" }
        # Verify attribute was NOT changed
        $attrs = Get-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Names "LatLong" -ErrorAction Stop
        foreach ($a in @($attrs)) {
            if ($a.name -eq 'LatLong' -and $a.value -match '45\.0') { throw "WhatIf should not have changed the attribute" }
        }
        Remove-Item $whatIfCsv -Force -ErrorAction SilentlyContinue
    }

    # -- Test invalid CSV (bad coordinates) -----------------------------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (bad coords)' -Endpoint '(validation)' -Test {
        $csvContent = @"
DeviceName,Latitude,Longitude
$($script:GeoTestDeviceName),999,-999
"@
        Set-Content -Path $script:SyncCsvBadPath -Value $csvContent -Encoding UTF8
        $results = Set-GeoDeviceLocations -Config $script:GeoConfig -CsvPath $script:SyncCsvBadPath -ErrorAction Stop
        $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })
        if ($skipped.Count -eq 0) { throw "Expected Skipped status for out-of-range coordinates" }
    }

    # -- Test CSV with IP column fallback -------------------------------------
    Invoke-Test -Cmdlet 'Set-GeoDeviceLocations (IP fallback)' -Endpoint 'PATCH /devices/{id}/attributes/- (IP match)' -Test {
        $csvContent = @"
DeviceName,IP,Latitude,Longitude
SomeUnknownName-WUGPS,127.0.0.5,48.8566,2.3522
"@
        $ipCsv = Join-Path $env:TEMP "WUGPS-GeoTest-IP-$(Get-Date -Format 'yyyyMMddHHmmss').csv"
        Set-Content -Path $ipCsv -Value $csvContent -Encoding UTF8
        $results = Set-GeoDeviceLocations -Config $script:GeoConfig -CsvPath $ipCsv -ErrorAction Stop
        # The test device is at 127.0.0.5 so it should match via IP
        $updated = @($results | Where-Object { $_.Status -eq 'Updated' })
        if ($updated.Count -eq 0) { throw "Expected IP-fallback match to update device" }
        Remove-Item $ipCsv -Force -ErrorAction SilentlyContinue
    }

    # Restore LatLong to original test value for subsequent tests
    Set-WUGDeviceAttribute -DeviceId $script:GeoTestDeviceId -Name "LatLong" -Value "$testLat,$testLng" `
        -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
else {
    Record-Test -Cmdlet 'Set-GeoDeviceLocations' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No test device or geo config'
}
#endregion

#region -- Test Update-GeolocationMap (Export-GeolocationMapHtml + Get-GeolocationData) ---
Write-Host "`n[4d/8] Testing Update-GeolocationMap pipeline (Get-GeolocationData + Export) ..." -ForegroundColor Cyan

if ($script:GeoConfig) {
    # -- Full pipeline: Get-GeolocationData -> Export-GeolocationMapHtml ------
    $script:UpdateMapPath = Join-Path $env:TEMP "WUGPS-GeoTest-UpdateMap-$(Get-Date -Format 'yyyyMMddHHmmss').html"

    Invoke-Test -Cmdlet 'Update-GeolocationMap pipeline (full)' -Endpoint 'GET /devices + /groups -> HTML' -Test {
        $geoData = Get-GeolocationData -Config $script:GeoConfig -ErrorAction Stop
        if (-not $geoData -or @($geoData).Count -eq 0) { throw "No geolocation data for map update" }
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $resultPath = Export-GeolocationMapHtml -Data @($geoData) -OutputPath $script:UpdateMapPath `
            -TemplatePath $templatePath -WugBaseUrl "https://$($ServerUri):$Port" -ErrorAction Stop
        if (-not (Test-Path $resultPath)) { throw "Update map file not created" }
        $content = Get-Content $resultPath -Raw
        if ($content.Length -lt 100) { throw "Map file too small" }
        if ($content -notmatch 'leaflet') { throw "Map missing Leaflet references" }
    }

    # -- Verify WugBaseUrl is embedded in the output --------------------------
    Invoke-Test -Cmdlet 'Update-GeolocationMap (WugBaseUrl)' -Endpoint '(HTML content)' -Test {
        if (-not (Test-Path $script:UpdateMapPath)) { throw "Map file missing" }
        $content = Get-Content $script:UpdateMapPath -Raw
        if ($content -notmatch [regex]::Escape($ServerUri)) {
            throw "WUG server URI not found in generated map HTML"
        }
    }

    # -- Pipeline with SkipGroups (devices only) ------------------------------
    Invoke-Test -Cmdlet 'Update-GeolocationMap (devices only)' -Endpoint 'GET /devices -> HTML (no groups)' -Test {
        $devOnlyPath = Join-Path $env:TEMP "WUGPS-GeoTest-DevOnly-$(Get-Date -Format 'yyyyMMddHHmmss').html"
        $geoData = Get-GeolocationData -Config $script:GeoConfig -IncludeDevices $true -IncludeGroups $false -ErrorAction Stop
        if ($geoData) {
            $hasGroup = $false
            foreach ($r in @($geoData)) { if ($r.Type -eq 'Group') { $hasGroup = $true; break } }
            if ($hasGroup) { throw "Groups should be excluded with IncludeGroups=false" }
            $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
            $resultPath = Export-GeolocationMapHtml -Data @($geoData) -OutputPath $devOnlyPath `
                -TemplatePath $templatePath -ErrorAction Stop
            if (-not (Test-Path $resultPath)) { throw "Devices-only map not created" }
            Remove-Item $devOnlyPath -Force -ErrorAction SilentlyContinue
        }
        else {
            throw "No device location data returned for devices-only pipeline"
        }
    }

    # -- Pipeline with SkipDevices (groups only) ------------------------------
    Invoke-Test -Cmdlet 'Update-GeolocationMap (groups only)' -Endpoint 'GET /groups -> HTML (no devices)' -Test {
        $grpOnlyPath = Join-Path $env:TEMP "WUGPS-GeoTest-GrpOnly-$(Get-Date -Format 'yyyyMMddHHmmss').html"
        $geoData = Get-GeolocationData -Config $script:GeoConfig -IncludeDevices $false -IncludeGroups $true -ErrorAction Stop
        if ($geoData) {
            $hasDevice = $false
            foreach ($r in @($geoData)) { if ($r.Type -eq 'Device') { $hasDevice = $true; break } }
            if ($hasDevice) { throw "Devices should be excluded with IncludeDevices=false" }
        }
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $resultPath = Export-GeolocationMapHtml -Data @($geoData) -OutputPath $grpOnlyPath `
            -TemplatePath $templatePath -ErrorAction Stop
        if (-not (Test-Path $resultPath)) { throw "Groups-only map not created" }
        Remove-Item $grpOnlyPath -Force -ErrorAction SilentlyContinue
    }

    # -- Pipeline with auto-refresh (simulates scheduled task output) ---------
    Invoke-Test -Cmdlet 'Update-GeolocationMap (auto-refresh)' -Endpoint '(HTML scheduled task output)' -Test {
        $autoRefreshPath = Join-Path $env:TEMP "WUGPS-GeoTest-AutoRefresh-$(Get-Date -Format 'yyyyMMddHHmmss').html"
        $geoData = Get-GeolocationData -Config $script:GeoConfig -ErrorAction Stop
        $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'geolocation\Geolocation-Map-Template.html'
        $resultPath = Export-GeolocationMapHtml -Data @($geoData) -OutputPath $autoRefreshPath `
            -TemplatePath $templatePath -RefreshIntervalSeconds 600 -ErrorAction Stop
        $content = Get-Content $resultPath -Raw
        if ($content -notmatch 'meta http-equiv="refresh" content="600"') {
            throw "Auto-refresh meta tag (600s) not found in scheduled output"
        }
        Remove-Item $autoRefreshPath -Force -ErrorAction SilentlyContinue
    }
}
else {
    Record-Test -Cmdlet 'Update-GeolocationMap pipeline' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No geo config'
}
#endregion

#region -- Test map HTML export -----------------------------------------------
Write-Host "`n[6/8] Testing Export-GeolocationMapHtml ..." -ForegroundColor Cyan

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
Write-Host "`n[7/8] Testing Export-GeolocationMapHtml (all providers) ..." -ForegroundColor Cyan
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
Write-Host "`n[8/8] Cleaning up test artefacts ..." -ForegroundColor Cyan

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

# Remove CSV sync test files
if ($script:SyncCsvPath -and (Test-Path $script:SyncCsvPath)) {
    Remove-Item -Path $script:SyncCsvPath -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed temp CSV file: $($script:SyncCsvPath)" -ForegroundColor DarkGray
}
if ($script:SyncCsvBadPath -and (Test-Path $script:SyncCsvBadPath)) {
    Remove-Item -Path $script:SyncCsvBadPath -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed temp bad-CSV file: $($script:SyncCsvBadPath)" -ForegroundColor DarkGray
}

# Remove update map test file
if ($script:UpdateMapPath -and (Test-Path $script:UpdateMapPath)) {
    Remove-Item -Path $script:UpdateMapPath -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed temp update-map file: $($script:UpdateMapPath)" -ForegroundColor DarkGray
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAxb/AS7jKE3oNO
# BE0HEYToLU4Dc9IGIi8YqW+Dwd3HJKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAc90lARQE+IwX5OYQAoVFs9xwouI6pzaau6AmXGaRZ5jANBgkqhkiG9w0BAQEF
# AASCAgCIDuT3DlVQooIQcATZYAycwys2kANLTGjw90CL859oSC2aYMbF8q+QXhlh
# cE0ShNJ/VEQCTZgbm2vzCqoyQOOVuey6EH10gkBKJ1YPvESMatdIgZramb9fIajv
# hi0xb7mUtneWhMRyxq0Qz4vOxRMy9SNQSAorau5CKihavbmL/SFackQZIeqyKdj5
# +LzWFF+AOz6bdjfWNuJhQG/brgaWPxzHF5wR57tBER7Zz6j+8zQskUk6sKhFh+8j
# tuOLb2EJDAeL7VBUQebL6zcOV7RMCMTn70YJPUrejvy+Kz5dwm0ORS8egtAhq37g
# VVZXWtA4w3yE095KNErtr8LZIgmmYW4nqBfV4NVwB/MBgRj2GgTPwGv4EcuvHygs
# 7czbxfb0QX9iTrlS9YtuisZ92OZDyXmWg1yJov0XGHsp77lK7C6s8Qd0ZD16TLMn
# HZPiqHmg2aYa/czzxzNlaV8UypcovDUwINq/NZ0smpRVDy79Js6f9uzO2u4Lt9LL
# mQ/or/DjGJtZfnXyzuUps3q/z6QBWjYhHtUiXQvApbA7E7mklKaF0nr2N8ygTWb3
# yXu6zMh0vUeU3vxAF8tWy4fZrXoU6ZhzO0Y1o0nUNnJOcWxNKQi5aXZTsZdK7lSZ
# Ur1z3efI/YJnW1nKxk+pwVq9FDurt8kr5ZhEK6ig/vta9jTTC6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjIyMTMwMzBaMC8GCSqGSIb3DQEJBDEiBCDecsEt
# jHvMobR1WEOjewX/kVmyqAjnDM5GjAfv43GSuzANBgkqhkiG9w0BAQEFAASCAgCb
# sfZjd12q8x1AExRLCjeqLWzvBbGDnSQI49MtUA6a9170fgrfycNxDeBX8m8/i/xw
# QRDXPRoUWsRJ9vn162Wu7I728jwjUIyg33z5kiH91uMP52wxjJ736KjjwDKy5PZL
# e9gumAdCsD9YK1ZqF1ySCVWFyP13mky1ZjC4HHBcW0MZG0U366PE8j8r7lFxVvsH
# TGJJ3DErNBreaWOTvzRG7YVYhMP6L9JqogPRyC0N7PVL9EO+BhapiiSoaCjidtVk
# hXAzlnSanjNJ0lO5tJv2hJkF32QfFb2r5fcK4Jp1ELHmA+0UtTrxvDOEhmE3JPyW
# r7cgaIGnGTI8WMcqPKN69Zb3XWuSnOxTJ7cHlSuyze/KoIqdbB4/nDSkoyATQ3Pt
# oC0MMDC282AjoBGGojgz9em/yTsnpvZXGUHxQOApD4UlSx66+NVhG1P/GGZhQWKp
# i5X71PzOfg2rdo5hR172zxze9NQsRv3IuE/2xUSHvr65zyToxBtr3BWv8ERUvUpC
# yyWEEzPPohPFynHEFDVrsO49Bz5nJa6gy9XSlzKsRoD3DMRzr940cangyBE85YN4
# EybIthJ4kUuLXRcn1q4hk7luQEE/vbx30w+v69aCyrB5dUnwgiOcU5LOVOcv3hIL
# rlJhm7NpqeOByRFS15+JnDOPAEvi3jQ9xE6irCTpsg==
# SIG # End signature block
