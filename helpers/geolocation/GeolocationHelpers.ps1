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
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
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

    Write-Verbose "Connected to ${ServerUri}. Token expires at $($config._Expiry)."
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
        if ($groupResult.data.groups) {
            foreach ($g in $groupResult.data.groups) {
                if ($g.name -eq $GroupName) { $groupId = $g.id; break }
            }
        }
        if (-not $groupId) {
            Write-Warning "Device group '$GroupName' not found. Falling back to all devices."
        }
        else {
            $deviceResult = Invoke-GeoAPI -Config $Config -Endpoint "/api/v1/device-groups/$groupId/devices/-?view=overview&limit=250"
            if ($deviceResult.data.devices) {
                $devices = $deviceResult.data.devices
            }
        }
    }

    if ($devices.Count -eq 0 -and (-not $GroupName -or $GroupName -eq 'All' -or -not $groupId)) {
        # Get all devices from root group (id=0) with overview view for inline status
        $pageId = $null
        do {
            $endpoint = "/api/v1/device-groups/0/devices/-?view=overview&limit=250"
            if ($pageId) { $endpoint += "&pageId=$pageId" }
            $result = Invoke-GeoAPI -Config $Config -Endpoint $endpoint
            if ($result.data.devices) { $devices += $result.data.devices }
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
                # Status is already available from the overview view (no extra API call)
                $bestState  = if ($device.bestState)  { $device.bestState }  else { 'Unknown' }
                $worstState = if ($device.worstState) { $device.worstState } else { 'Unknown' }

                $geoDevices += [PSCustomObject]@{
                    Type                  = 'Device'
                    Name                  = if ($device.name) { $device.name } elseif ($device.displayName) { $device.displayName } else { "Device $deviceId" }
                    DeviceId              = $deviceId
                    Latitude              = $lat
                    Longitude             = $lng
                    BestState             = $bestState
                    WorstState            = $worstState
                    TotalMonitors         = if ($device.totalActiveMonitors) { $device.totalActiveMonitors } else { 0 }
                    DownMonitors          = if ($device.totalActiveMonitorsDown) { $device.totalActiveMonitorsDown } else { 0 }
                    DownMonitorDetails    = if ($device.downActiveMonitors) { $device.downActiveMonitors } else { @() }
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
        if ($result.data.groups) { $groups += $result.data.groups }
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
    .PARAMETER TileApiKeys
        Optional hashtable of tile provider API keys to embed in the HTML file.
        Supported keys: thunderforest, stadia, maptiler, here, mapbox, jawg, tomtom, openweathermap.
        NOTE: Keys passed here are written in plaintext to the output HTML (opt-in).
        For better security, omit this parameter and enter keys via the map's
        Settings > API Keys panel instead. Keys entered in-browser are stored in
        localStorage (never written to disk in the HTML file).
    .EXAMPLE
        Export-GeolocationMapHtml -Data $geoData -OutputPath "C:\Maps\WUG-Map.html"
    .EXAMPLE
        $keys = @{ thunderforest = 'abc123'; stadia = 'xyz789' }
        Export-GeolocationMapHtml -Data $geoData -OutputPath "C:\Maps\WUG-Map.html" -TileApiKeys $keys
    #>
    param(
        [Parameter(Mandatory)][array]$Data,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$TemplatePath,
        [string]$WugBaseUrl = '',
        [double]$DefaultLat  = 39.8283,
        [double]$DefaultLng  = -98.5795,
        [int]$DefaultZoom    = 5,
        [hashtable]$TileApiKeys
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot 'Geolocation-Map-Template.html'
    }
    if (-not (Test-Path $TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }

    $template = [System.IO.File]::ReadAllText($TemplatePath)

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

    # Inject tile provider API keys
    if ($TileApiKeys -and $TileApiKeys.Count -gt 0) {
        $keysObj = @{}
        foreach ($k in $TileApiKeys.Keys) {
            $keysObj[$k.ToLower()] = $TileApiKeys[$k]
        }
        $keysJson = (ConvertTo-Json -InputObject $keysObj -Compress) -replace "'", "\\'"
        $html = $html.Replace('%%API_KEYS%%', $keysJson)
    }
    else {
        $html = $html.Replace('%%API_KEYS%%', '')
    }

    # Write output
    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8

    Write-Verbose "Geolocation map exported to: $OutputPath"
    return $OutputPath
}

# --- Import device locations from CSV and set attributes ---
function Set-GeoDeviceLocations {
    <#
    .SYNOPSIS
        Reads a CSV file and sets geolocation attributes on matching WhatsUp Gold devices.
    .DESCRIPTION
        Imports a CSV with columns DeviceName (or IP), Latitude, Longitude and writes
        those coordinates to each matched device as custom attributes in WhatsUp Gold.

        Supports two attribute modes:
        - LatLong (default): writes a single "LatLong" attribute with value "lat,lng"
        - Separate: writes individual "Latitude" and "Longitude" attributes

        Device matching is done by searching the WUG device list by name or IP.
        A detailed summary report is returned showing what was set and any misses.
    .PARAMETER Config
        The configuration hashtable from Connect-GeoWUGServer.
    .PARAMETER CsvPath
        Full path to the CSV file. Required columns: DeviceName, Latitude, Longitude.
        Optional column: IP (used as fallback search if DeviceName match fails).
    .PARAMETER UseSeparateAttributes
        If set, writes "Latitude" and "Longitude" as separate attributes instead of
        a single "LatLong" attribute.
    .PARAMETER WhatIf
        Show what would be changed without making any API calls.
    .OUTPUTS
        Array of PSCustomObject summarising each row: DeviceName, DeviceId, Status, Detail.
    .EXAMPLE
        $results = Set-GeoDeviceLocations -Config $geo -CsvPath "C:\Data\device-locations.csv"
    .EXAMPLE
        Set-GeoDeviceLocations -Config $geo -CsvPath ".\locations.csv" -UseSeparateAttributes -WhatIf
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$CsvPath,
        [switch]$UseSeparateAttributes,
        [switch]$WhatIf
    )

    if (-not (Test-Path $CsvPath)) {
        throw "CSV file not found: $CsvPath"
    }

    $csv = Import-Csv -Path $CsvPath
    if ($csv.Count -eq 0) {
        Write-Warning "CSV file is empty."
        return @()
    }

    # Validate required columns
    $headers = $csv[0].PSObject.Properties.Name
    $hasName = $headers -contains 'DeviceName'
    $hasIP   = $headers -contains 'IP'
    $hasLat  = $headers -contains 'Latitude'
    $hasLng  = $headers -contains 'Longitude'

    if (-not $hasLat -or -not $hasLng) {
        throw "CSV must have 'Latitude' and 'Longitude' columns."
    }
    if (-not $hasName -and -not $hasIP) {
        throw "CSV must have at least a 'DeviceName' or 'IP' column."
    }

    # Pre-fetch all devices for matching (avoids N search calls)
    Write-Verbose "Fetching full device list for matching..."
    $allDevices = @()
    $pageId = $null
    do {
        $endpoint = "/api/v1/device-groups/0/devices/-?view=overview&limit=250"
        if ($pageId) { $endpoint += "&pageId=$pageId" }
        $result = Invoke-GeoAPI -Config $Config -Endpoint $endpoint
        if ($result.data.devices) { $allDevices += $result.data.devices }
        $pageId = $result.paging.nextPageId
    } while ($pageId)

    Write-Verbose "Loaded $($allDevices.Count) devices for matching."

    # Build lookup tables (name -> device, IP -> device)
    $byName = @{}
    $byIP   = @{}
    foreach ($d in $allDevices) {
        $devId = if ($d.id) { $d.id } else { $d.deviceId }
        $devName = if ($d.name) { $d.name } elseif ($d.displayName) { $d.displayName } else { '' }
        $devIP = if ($d.networkAddress) { $d.networkAddress } elseif ($d.hostName) { $d.hostName } else { '' }
        if ($devName) { $byName[$devName.ToLower()] = @{ Id = $devId; Name = $devName; IP = $devIP } }
        if ($devIP)   { $byIP[$devIP.ToLower()]     = @{ Id = $devId; Name = $devName; IP = $devIP } }
    }

    $results = @()
    $totalRows = $csv.Count
    $currentRow = 0

    foreach ($row in $csv) {
        $currentRow++
        $pct = [Math]::Round(($currentRow / $totalRows) * 100, 0)
        Write-Progress -Activity "Syncing device locations" -Status "$currentRow of $totalRows" -PercentComplete $pct

        $csvName = if ($hasName -and $row.DeviceName) { $row.DeviceName.Trim() } else { '' }
        $csvIP   = if ($hasIP -and $row.IP) { $row.IP.Trim() } else { '' }
        $lat     = $row.Latitude.Trim()
        $lng     = $row.Longitude.Trim()

        # Validate coordinates
        $latNum = 0.0; $lngNum = 0.0
        if (-not [double]::TryParse($lat, [ref]$latNum) -or -not [double]::TryParse($lng, [ref]$lngNum)) {
            $results += [PSCustomObject]@{
                DeviceName = if ($csvName) { $csvName } else { $csvIP }
                DeviceId   = $null
                Status     = 'Skipped'
                Detail     = "Invalid coordinates: $lat, $lng"
            }
            continue
        }
        if ($latNum -lt -90 -or $latNum -gt 90 -or $lngNum -lt -180 -or $lngNum -gt 180) {
            $results += [PSCustomObject]@{
                DeviceName = if ($csvName) { $csvName } else { $csvIP }
                DeviceId   = $null
                Status     = 'Skipped'
                Detail     = "Coordinates out of range: $lat, $lng"
            }
            continue
        }

        # Match device
        $matched = $null
        if ($csvName) { $matched = $byName[$csvName.ToLower()] }
        if (-not $matched -and $csvIP) { $matched = $byIP[$csvIP.ToLower()] }

        if (-not $matched) {
            $results += [PSCustomObject]@{
                DeviceName = if ($csvName) { $csvName } else { $csvIP }
                DeviceId   = $null
                Status     = 'NotFound'
                Detail     = "No matching device in WUG"
            }
            continue
        }

        $deviceId = $matched.Id
        $displayLabel = if ($csvName) { $csvName } else { "$csvIP ($($matched.Name))" }

        if ($WhatIf) {
            $attrDesc = if ($UseSeparateAttributes) { "Latitude=$lat, Longitude=$lng" } else { "LatLong=$lat,$lng" }
            $results += [PSCustomObject]@{
                DeviceName = $displayLabel
                DeviceId   = $deviceId
                Status     = 'WhatIf'
                Detail     = "Would set $attrDesc"
            }
            continue
        }

        # Set attributes via PATCH (upsert)
        try {
            if ($UseSeparateAttributes) {
                $body = ConvertTo-Json -InputObject @{
                    attributesToAdd = @(
                        @{ name = 'Latitude';  value = $lat }
                        @{ name = 'Longitude'; value = $lng }
                    )
                } -Depth 5 -Compress
            }
            else {
                $body = ConvertTo-Json -InputObject @{
                    attributesToAdd = @(
                        @{ name = 'LatLong'; value = "$lat,$lng" }
                    )
                } -Depth 5 -Compress
            }

            $null = Invoke-GeoAPI -Config $Config `
                -Endpoint "/api/v1/devices/$deviceId/attributes/-" `
                -Method 'PATCH' -Body $body

            $results += [PSCustomObject]@{
                DeviceName = $displayLabel
                DeviceId   = $deviceId
                Status     = 'Updated'
                Detail     = if ($UseSeparateAttributes) { "Lat=$lat, Lng=$lng" } else { "LatLong=$lat,$lng" }
            }
        }
        catch {
            $results += [PSCustomObject]@{
                DeviceName = $displayLabel
                DeviceId   = $deviceId
                Status     = 'Error'
                Detail     = $_.Exception.Message
            }
        }
    }

    Write-Progress -Activity "Syncing device locations" -Completed

    # Summary
    $updated  = @($results | Where-Object { $_.Status -eq 'Updated' }).Count
    $notFound = @($results | Where-Object { $_.Status -eq 'NotFound' }).Count
    $skipped  = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $errors   = @($results | Where-Object { $_.Status -eq 'Error' }).Count
    Write-Verbose "Sync complete: $updated updated, $notFound not found, $skipped skipped, $errors errors."

    return $results
}

# --- Read geolocation config from the DPAPI vault ---
function Import-GeolocationConfig {
    <#
    .SYNOPSIS
        Reads the geolocation configuration and refresh token from the DPAPI vault.
    .DESCRIPTION
        Retrieves the Geolocation.Config bundle and Geolocation.RefreshToken
        from the discovery vault, converts string fields to their proper types,
        and returns a typed configuration hashtable.

        Requires DiscoveryHelpers.ps1 to be loaded first (for vault functions).
    #>
    [CmdletBinding()]
    param()

    $raw = Get-DiscoveryCredential -Name 'Geolocation.Config'
    if (-not $raw) {
        throw "Geolocation config not found in vault. Run Setup-GeolocationConfig.ps1 first."
    }

    $refreshToken = Get-DiscoveryCredential -Name 'Geolocation.RefreshToken'
    if (-not $refreshToken) {
        throw "Geolocation refresh token not found in vault. Run Setup-GeolocationConfig.ps1 first."
    }

    # Extract tile API keys from TileApiKey.* fields
    $tileApiKeys = @{}
    foreach ($key in @($raw.Keys)) {
        if ($key -like 'TileApiKey.*') {
            $provider = $key.Substring('TileApiKey.'.Length)
            $tileApiKeys[$provider] = $raw[$key]
        }
    }

    @{
        ServerUri        = $raw.ServerUri
        Protocol         = $raw.Protocol
        Port             = [int]$raw.Port
        IgnoreSSL        = [System.Convert]::ToBoolean($raw.IgnoreSSL)
        WugConsoleUrl    = $raw.WugConsoleUrl
        RefreshToken     = $refreshToken
        DefaultLat       = [double]$raw.DefaultLat
        DefaultLng       = [double]$raw.DefaultLng
        DefaultZoom      = [int]$raw.DefaultZoom
        GroupName        = $raw.GroupName
        UseBuiltinCoords = [System.Convert]::ToBoolean($raw.UseBuiltinCoords)
        IncludeDevices   = [System.Convert]::ToBoolean($raw.IncludeDevices)
        IncludeGroups    = [System.Convert]::ToBoolean($raw.IncludeGroups)
        TileApiKeys      = $tileApiKeys
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCJPlA66qc4Tn2i
# 12ColaHsiYYgtQKjezUpDiYPXAFshKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgoioW9J6Tj1RcmpUI25E3Tov3DZ0XtI3C
# cg4X5QBO69kwDQYJKoZIhvcNAQEBBQAEggIAVSAB7lq1Fe6VOhzDZ7sIGFWw9YeO
# 6/8pPrjVrxOiwEWKRuXBhrHDefz2t3eq/mulmsLxSNkB6K5c0g/2ZS/S/bk9NahE
# XBQhGPLABz+UCthWvRKLtwHMtQivUxFEw6D1Ag3mWHuh6y9thD8X5wFsdRIjp6md
# tp22OtPOFu6caTRhkBua4oejrESibzsPS78VcyrmkhTxq/1rkewC623eGgwKxTbc
# 65jue9fNDbXBw69CcNx0xFGqqIMSYriAw94pRwYEBrS1xvdBloYcWD4MJoPq7ndU
# kpLmwJ1zF2PmVSF4EeGaw/lYJ1eoL+hlLEu+HnHvnmpPx6zJ/ZEpkXSCKW7EMw6W
# EpO+Z7UQgcEJF5ZLhtEHc87tcO56aPTkEzHoWnEBIgbd07SNmJiG46TeqfYyxM6L
# 0MtiLHdZdpBEe2zU9PB7sW29uIpg3qrCVPqTxlCQ5wD9kmmXFbi97NX+UNSobS+P
# WqTY1Y7844D0+zNHRtPQZqgicQFY+hi++WO5lNozzKny5mLXnR+MGz9NtXfDCUkQ
# LGYyPlbYTAWlUvqMpoMBOjq4QBa4Z+0GLCX1D05vj5QjTWOFX4uWXTYcoTeJCkqm
# 4LW4pUUKMs5XjyxJVd/sX58I2ywpD9h/50jjCHzL1SLkSiz5CJoqCICAyoN2pfxB
# rUZFBp+3xrQLi0Y=
# SIG # End signature block
