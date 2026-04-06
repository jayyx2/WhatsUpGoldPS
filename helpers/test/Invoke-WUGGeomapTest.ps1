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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBUQ867aw+lffnn
# 98rSHck5MA50/N5VgssrAvLriAcIsKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgVgLikBVqnPgl5rEtey8/0PEbcJ+G0OTm
# rhIWh7DbDogwDQYJKoZIhvcNAQEBBQAEggIAjb4XwGs/rCKUDoEah5IQlUbVvQJ0
# oLZfWPXXxZd+3FHH/FC3e7kH2Ay1ZUqXqJ3Voqmp8YeMhk0hf2uLWzdeMYRNqgsE
# PHFr4H1/E1xNx+THC5l5smm6IJrlwAmIffKcTQfCzEnG/El6KzYNbJ7F6B+08lQ7
# ckxDDekxqKjKM8Ig3UPAOmUm/UY8str+06C7kn99n0TkJl/ur8qGQVjOxA7Fhc7D
# ZtKlntwiV0LUOufZ8veMxDOdvhoN0q2eI8SlVvMDXSl+KOoNDqYj6l7qjh1cNviN
# aYM5z17SLCI26Iuk6VFq4PIOu/3vpfhYCOoWW2hSiL+280AwNqVKPIIJ5vODCGNo
# 9Lzk5gKTDef9nLCkfuTLjvbL81O8+HFIEzDBj/+e9gQovXqNyDqxhTlH5p4lT/EN
# UbkoliHEhLzMpDbmswU93T0Rb/3EVOfxWWDzQyQPPvGrBkPSZi4YxC4ZsNYRSlOB
# 7KEmvtDYrLG/b/EAI5RiTmilNyTuo/Tu46fIEY94L9dRbg0r/1ZTSifJ+RH58swL
# s992/tL/omjTomVZCmJZU5FQCKBBGsKq+kPqRaT+BVivTcL/Wps5SvRb7sQxlK8Z
# v7FkkY0/U+1iE8lIHX7LTsf+QBZ4+7C7Q0p/XavXqQt1ar0Tzs+xXk88KErvvrsF
# QJrFaJ+WywilEc8=
# SIG # End signature block
