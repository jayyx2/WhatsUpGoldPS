# =============================================================================
# Geolocation Helpers for WhatsUpGoldPS
# Queries the WhatsUp Gold REST API for devices/groups with latitude/longitude
# data and generates a Leaflet-based interactive HTML map.
#
# Devices  : lat/lng stored in a device attribute named "LatLong" (format: "lat,lng")
#             OR built-in attributes "Latitude" and "Longitude"
# Groups   : lat/lng stored in the group description/note field (format: "lat,lng")
#
# Reference: https://github.com/jayyx2/wug-geolocation
# =============================================================================

# --- Internal: SSL bypass for self-signed certs ---
function Initialize-GeoSSLBypass {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
        $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
    }
    else {
        if (-not ([System.Management.Automation.PSTypeName]'GeoSSLValidator').Type) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class GeoSSLValidator {
    private static bool OnValidateCertificate(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) {
        return true;
    }
    public static void OverrideValidation() {
        ServicePointManager.ServerCertificateValidationCallback =
            new RemoteCertificateValidationCallback(OnValidateCertificate);
        ServicePointManager.Expect100Continue = false;
        ServicePointManager.DefaultConnectionLimit = 64;
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
    }
}
"@
        }
        [GeoSSLValidator]::OverrideValidation()
    }
    Write-Warning "Ignoring SSL certificate validation errors. Use this option with caution."
}

# --- Internal: REST wrapper that handles token refresh ---
function Invoke-GeoAPI {
    <#
    .SYNOPSIS
        Sends a request to the WhatsUp Gold REST API with automatic token refresh.
    .PARAMETER Config
        The configuration hashtable (from Import-GeolocationConfig).
    .PARAMETER Endpoint
        The API path (e.g. /api/v1/devices/-).
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER Body
        Optional string body for POST/PUT requests.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$Method = 'GET',
        [string]$Body
    )

    # Check if token needs refreshing (within 5 minutes of expiry)
    if ((Get-Date) -ge $Config._Expiry.AddMinutes(-5)) {
        Write-Verbose "Token expired or expiring soon. Refreshing..."
        $refreshBody = "grant_type=refresh_token&refresh_token=$($Config._RefreshToken)"
        $refreshHeaders = @{ "Content-Type" = "application/json" }
        try {
            $newToken = Invoke-RestMethod -Uri "$($Config.BaseUri)/api/v1/token" `
                -Method Post -Headers $refreshHeaders -Body $refreshBody -ErrorAction Stop
            $Config._AccessToken  = $newToken.access_token
            $Config._RefreshToken = $newToken.refresh_token
            $Config._TokenType    = $newToken.token_type
            $Config._Expiry       = (Get-Date).AddSeconds($newToken.expires_in)
            Write-Verbose "Token refreshed. Expires at $($Config._Expiry)."
        }
        catch {
            throw "Failed to refresh WUG auth token: $($_.Exception.Message)"
        }
    }

    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "$($Config._TokenType) $($Config._AccessToken)"
    }
    $uri = "$($Config.BaseUri)$Endpoint"
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
    if ($Body) { $params.Body = $Body }

    $maxRetries = if ($PSVersionTable.PSEdition -eq 'Core') { 0 } else { 2 }
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        try {
            return (Invoke-RestMethod @params)
        }
        catch {
            $isClosed = $_.Exception.Message -match 'underlying connection was closed|unexpected error occurred on a send'
            if ($isClosed -and $attempt -lt $maxRetries) {
                try {
                    $sp = [System.Net.ServicePointManager]::FindServicePoint([System.Uri]$uri)
                    $sp.CloseConnectionGroup('')
                } catch {}
                Start-Sleep -Milliseconds (300 * ($attempt + 1))
            }
            else { throw }
        }
    }
}

# --- Connect to the WUG server and get initial auth token ---
function Connect-GeoWUGServer {
    <#
    .SYNOPSIS
        Authenticates to a WhatsUp Gold server and returns a config hashtable.
    .DESCRIPTION
        Obtains an OAuth 2.0 token using password grant type from the WUG REST API.
        Returns a hashtable containing the base URI, tokens, and expiry for use
        with other Geolocation helper functions.
    .PARAMETER ServerUri
        The hostname or IP of the WhatsUp Gold server.
    .PARAMETER Username
        The username for authentication.
    .PARAMETER Password
        The password for authentication.
    .PARAMETER Protocol
        http or https (default: https).
    .PARAMETER Port
        The WUG API port (default: 9644).
    .PARAMETER IgnoreSSLErrors
        Bypass SSL certificate validation.
    .OUTPUTS
        Hashtable with keys: BaseUri, _AccessToken, _RefreshToken, _TokenType, _Expiry
    .EXAMPLE
        $config = Connect-GeoWUGServer -ServerUri "wug.example.com" -Username "admin" -Password "pass"
    #>
    param(
        [Parameter(Mandatory)][string]$ServerUri,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [ValidateSet("http","https")][string]$Protocol = "https",
        [ValidateRange(1,65535)][int]$Port = 9644,
        [switch]$IgnoreSSLErrors
    )

    if ($IgnoreSSLErrors) { Initialize-GeoSSLBypass }

    $baseUri  = "${Protocol}://${ServerUri}:${Port}"
    $tokenUri = "$baseUri/api/v1/token"
    $headers  = @{ "Content-Type" = "application/json" }
    $body     = "grant_type=password&username=${Username}&password=${Password}"

    try {
        $token = Invoke-RestMethod -Uri $tokenUri -Method Post -Headers $headers -Body $body -ErrorAction Stop
    }
    catch {
        throw "Failed to authenticate to ${baseUri}: $($_.Exception.Message)"
    }

    if (-not $token.access_token -or -not $token.refresh_token) {
        throw "Token response missing required fields."
    }

    $config = @{
        BaseUri        = $baseUri
        ServerUri      = $ServerUri
        Protocol       = $Protocol
        Port           = $Port
        IgnoreSSL      = [bool]$IgnoreSSLErrors
        _AccessToken   = $token.access_token
        _RefreshToken  = $token.refresh_token
        _TokenType     = $token.token_type
        _Expiry        = (Get-Date).AddSeconds($token.expires_in)
    }

    Write-Output "Connected to ${ServerUri}. Token expires at $($config._Expiry)."
    return $config
}

# --- Get devices with LatLong attribute ---
function Get-GeoDevicesWithLocation {
    <#
    .SYNOPSIS
        Retrieves devices that have geolocation data (LatLong attribute).
    .DESCRIPTION
        Queries all devices in WUG, then fetches their attributes looking for
        "LatLong" (single attribute with "lat,lng") or built-in "Latitude"/"Longitude".
        Returns an array of objects with device info and parsed coordinates.
    .PARAMETER Config
        The configuration hashtable from Connect-GeoWUGServer.
    .PARAMETER GroupName
        Optional device group name to filter devices. Default is all devices.
    .PARAMETER UseBuiltinCoords
        If set, uses separate "Latitude" and "Longitude" attributes instead of "LatLong".
    .OUTPUTS
        Array of PSCustomObject: Name, DeviceId, Latitude, Longitude, State, Status
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$GroupName,
        [switch]$UseBuiltinCoords
    )

    $devices = @()

    # Get device list - if group specified, get from group; otherwise get all
    if ($GroupName -and $GroupName -ne 'All') {
        # Find the group
        $groupResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/device-groups/-?search=$([uri]::EscapeDataString($GroupName))&limit=250"
        $groupId = $null
        if ($groupResult.data) {
            foreach ($g in $groupResult.data) {
                if ($g.name -eq $GroupName) { $groupId = $g.id; break }
            }
        }
        if (-not $groupId) {
            Write-Warning "Device group '$GroupName' not found. Falling back to all devices."
        }
        else {
            $deviceResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/device-groups/$groupId/devices/-?limit=250"
            if ($deviceResult.data) {
                $devices = $deviceResult.data
            }
        }
    }

    if ($devices.Count -eq 0 -and (-not $GroupName -or $GroupName -eq 'All' -or -not $groupId)) {
        # Get all devices
        $pageId = $null
        do {
            $endpoint = "/api/v1/devices/-?limit=250"
            if ($pageId) { $endpoint += "&pageId=$pageId" }
            $result = Invoke-GeoAPI -Config $Config -Endpoint $endpoint
            if ($result.data) { $devices += $result.data }
            $pageId = $result.paging.nextPageId
        } while ($pageId)
    }

    if ($devices.Count -eq 0) {
        Write-Warning "No devices found."
        return @()
    }

    Write-Verbose "Found $($devices.Count) devices. Checking for location attributes..."

    $geoDevices = @()
    $totalDevices = $devices.Count
    $currentIndex = 0

    foreach ($device in $devices) {
        $currentIndex++
        $pct = [Math]::Round(($currentIndex / $totalDevices) * 100, 0)
        Write-Progress -Activity "Fetching device locations" -Status "$currentIndex of $totalDevices" -PercentComplete $pct

        $deviceId = if ($device.id) { $device.id } else { $device.deviceId }
        if (-not $deviceId) { continue }

        try {
            $lat = $null; $lng = $null

            if ($UseBuiltinCoords) {
                # Fetch Latitude and Longitude as separate attributes
                $attrResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/devices/$deviceId/attributes/-?names=Latitude&names=Longitude&limit=10"
                if ($attrResult.data) {
                    foreach ($attr in $attrResult.data) {
                        if ($attr.name -eq 'Latitude')  { $lat = [double]$attr.value }
                        if ($attr.name -eq 'Longitude') { $lng = [double]$attr.value }
                    }
                }
            }
            else {
                # Fetch LatLong as a single attribute
                $attrResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/devices/$deviceId/attributes/-?names=LatLong&limit=10"
                if ($attrResult.data) {
                    foreach ($attr in $attrResult.data) {
                        if ($attr.name -eq 'LatLong' -and $attr.value) {
                            $parts = $attr.value -split ','
                            if ($parts.Count -ge 2) {
                                $lat = [double]$parts[0].Trim()
                                $lng = [double]$parts[1].Trim()
                            }
                        }
                    }
                }
            }

            if ($null -ne $lat -and $null -ne $lng) {
                # Get device status for state info
                $statusResult = $null
                try {
                    $statusResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/devices/$deviceId/status"
                } catch { }

                $bestState  = if ($statusResult.data) { $statusResult.data.bestState }  else { 'Unknown' }
                $worstState = if ($statusResult.data) { $statusResult.data.worstState } else { 'Unknown' }

                $geoDevices += [PSCustomObject]@{
                    Type       = 'Device'
                    Name       = if ($device.name) { $device.name } elseif ($device.displayName) { $device.displayName } else { "Device $deviceId" }
                    DeviceId   = $deviceId
                    Latitude   = $lat
                    Longitude  = $lng
                    BestState  = $bestState
                    WorstState = $worstState
                }
            }
        }
        catch {
            Write-Verbose "Error fetching attributes for device $deviceId : $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity "Fetching device locations" -Completed
    Write-Verbose "Found $($geoDevices.Count) devices with location data."
    return $geoDevices
}

# --- Get groups with lat/lng in description/note ---
function Get-GeoGroupsWithLocation {
    <#
    .SYNOPSIS
        Retrieves device groups that have geolocation data in their description.
    .DESCRIPTION
        Scans all device groups and parses their description for a "lat,lng" pattern.
        If the description field contains a valid coordinate pair, the group is included.
    .PARAMETER Config
        The configuration hashtable from Connect-GeoWUGServer.
    .OUTPUTS
        Array of PSCustomObject: Name, GroupId, Latitude, Longitude, State
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $groups = @()
    $pageId = $null
    do {
        $endpoint = "/api/v1/device-groups/-?limit=250&view=detail"
        if ($pageId) { $endpoint += "&pageId=$pageId" }
        $result = Invoke-GeoAPI -Config $Config -Endpoint $endpoint
        if ($result.data) { $groups += $result.data }
        $pageId = $result.paging.nextPageId
    } while ($pageId)

    if ($groups.Count -eq 0) {
        Write-Warning "No device groups found."
        return @()
    }

    Write-Verbose "Found $($groups.Count) groups. Checking descriptions for coordinates..."

    $geoGroups = @()

    foreach ($group in $groups) {
        $groupId = $group.id
        $groupName = $group.name

        # Get group definition to read description
        try {
            $defResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/device-groups/$groupId/definition"
        }
        catch {
            Write-Verbose "Error fetching definition for group $groupId : $($_.Exception.Message)"
            continue
        }

        $description = if ($defResult.data) { $defResult.data.description } else { $null }
        if (-not $description) { continue }

        # Try to parse "lat,lng" from the description
        if ($description -match '^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$') {
            $lat = [double]$Matches[1]
            $lng = [double]$Matches[2]

            # Validate coordinate ranges
            if ($lat -ge -90 -and $lat -le 90 -and $lng -ge -180 -and $lng -le 180) {
                $monitorState = if ($group.monitorState) { $group.monitorState } else { 'Unknown' }
                $geoGroups += [PSCustomObject]@{
                    Type       = 'Group'
                    Name       = $groupName
                    GroupId    = $groupId
                    Latitude   = $lat
                    Longitude  = $lng
                    State      = $monitorState
                }
            }
        }
    }

    Write-Verbose "Found $($geoGroups.Count) groups with location data."
    return $geoGroups
}

# --- Build combined geolocation dataset ---
function Get-GeolocationData {
    <#
    .SYNOPSIS
        Gathers all geolocated devices and groups from WhatsUp Gold.
    .DESCRIPTION
        Combines the output of Get-GeoDevicesWithLocation and Get-GeoGroupsWithLocation
        into a single dataset suitable for map rendering.
    .PARAMETER Config
        The configuration hashtable from Connect-GeoWUGServer.
    .PARAMETER GroupName
        Optional device group filter for devices. Default: all.
    .PARAMETER UseBuiltinCoords
        Use separate Latitude/Longitude attributes for devices.
    .PARAMETER IncludeDevices
        Include devices on the map (default: $true).
    .PARAMETER IncludeGroups
        Include groups on the map (default: $true).
    .OUTPUTS
        Array of PSCustomObject with Type, Name, Latitude, Longitude, and state fields.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$GroupName,
        [switch]$UseBuiltinCoords,
        [bool]$IncludeDevices = $true,
        [bool]$IncludeGroups  = $true
    )

    $allData = @()

    if ($IncludeDevices) {
        $splat = @{ Config = $Config }
        if ($GroupName)       { $splat.GroupName = $GroupName }
        if ($UseBuiltinCoords) { $splat.UseBuiltinCoords = $true }
        $allData += @(Get-GeoDevicesWithLocation @splat)
    }

    if ($IncludeGroups) {
        $allData += @(Get-GeoGroupsWithLocation -Config $Config)
    }

    Write-Verbose "Geolocation dataset: $($allData.Count) total markers."
    return $allData
}

# --- Export Leaflet HTML map ---
function Export-GeolocationMapHtml {
    <#
    .SYNOPSIS
        Generates a self-contained Leaflet HTML map from geolocation data.
    .DESCRIPTION
        Takes geolocation data and a template HTML file and produces a
        standalone HTML page with interactive Leaflet map showing device
        and group markers. The data is embedded as inline JSON so the HTML
        file can be opened directly in a browser with no server required.
    .PARAMETER Data
        Array of geolocation objects from Get-GeolocationData.
    .PARAMETER OutputPath
        Full path for the output HTML file.
    .PARAMETER TemplatePath
        Path to the Geolocation-Map-Template.html file. Defaults to same
        directory as this script.
    .PARAMETER WugBaseUrl
        The base URL of the WhatsUp Gold web console (e.g. https://wug.example.com:443).
        Used to make markers clickable - links to device/group dashboards.
    .PARAMETER DefaultLat
        Default map center latitude (default: 39.8283 - center of US).
    .PARAMETER DefaultLng
        Default map center longitude (default: -98.5795 - center of US).
    .PARAMETER DefaultZoom
        Default map zoom level (default: 5).
    .EXAMPLE
        Export-GeolocationMapHtml -Data $geoData -OutputPath "C:\Maps\WUG-Map.html"
    #>
    param(
        [Parameter(Mandatory)][array]$Data,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$TemplatePath,
        [string]$WugBaseUrl = '',
        [double]$DefaultLat  = 39.8283,
        [double]$DefaultLng  = -98.5795,
        [int]$DefaultZoom    = 5
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot 'Geolocation-Map-Template.html'
    }
    if (-not (Test-Path $TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }

    $template = Get-Content -Path $TemplatePath -Raw

    # Build JSON data
    $jsonData = ConvertTo-Json -InputObject @($Data) -Depth 5 -Compress

    # Replace placeholders in template
    $html = $template
    # Use .Replace() (not -replace) to avoid regex interpretation of JSON special chars
    $safeJson = $jsonData -replace '\\', '\\\\' -replace "'", "\\'" 
    $html = $html.Replace('%%MARKER_DATA%%',  $safeJson)
    $html = $html.Replace('%%DEFAULT_LAT%%',  $DefaultLat.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    $html = $html.Replace('%%DEFAULT_LNG%%',  $DefaultLng.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    $html = $html.Replace('%%DEFAULT_ZOOM%%', $DefaultZoom.ToString())
    $html = $html.Replace('%%WUG_BASE_URL%%', $WugBaseUrl)
    $html = $html.Replace('%%GENERATED_AT%%', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # Write output
    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8

    Write-Output "Geolocation map exported to: $OutputPath"
    return $OutputPath
}
