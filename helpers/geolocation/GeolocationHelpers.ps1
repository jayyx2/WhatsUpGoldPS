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
    .DESCRIPTION
        When the WhatsUpGoldPS module is loaded and connected (global WUG bearer
        headers exist), calls are routed through Get-WUGAPIResponse for unified
        logging, token management, and integrity. When the module is not available
        (e.g. standalone scheduled-task execution), the function falls back to
        direct Invoke-RestMethod with its own token refresh logic.
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

    $uri = "$($Config.BaseUri)$Endpoint"

    # --- Prefer WhatsUpGoldPS module when loaded ---
    if ($global:WUGBearerHeaders -and $global:WhatsUpServerBaseURI -and (Get-Command 'Get-WUGAPIResponse' -ErrorAction SilentlyContinue)) {
        try {
            Write-Verbose "Invoke-GeoAPI: routing through Get-WUGAPIResponse -> $Method $Endpoint"
            $moduleParams = @{ Uri = $uri; Method = $Method }
            if ($Body) { $moduleParams.Body = $Body }
            return (Get-WUGAPIResponse @moduleParams)
        }
        catch {
            Write-Verbose "Get-WUGAPIResponse failed ($($_.Exception.Message)), falling back to direct REST."
        }
    }

    # --- Fallback: direct Invoke-RestMethod with own token refresh ---

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

        Uses a JSON location cache to avoid re-fetching coordinates for devices
        whose locations haven't changed (coordinates are static; status comes from
        the overview endpoint and is always fresh).  New or uncached devices are
        fetched with a PS 5.1-compatible runspace pool for parallelism.
    .PARAMETER Config
        The configuration hashtable from Connect-GeoWUGServer.
    .PARAMETER GroupName
        Optional device group name to filter devices. Default is all devices.
    .PARAMETER UseBuiltinCoords
        If set, uses separate "Latitude" and "Longitude" attributes instead of "LatLong".
    .PARAMETER RefreshCache
        Force re-fetch all device coordinates from the API, ignoring the cache.
    .OUTPUTS
        Array of PSCustomObject: Name, DeviceId, Latitude, Longitude, State, Status
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$GroupName,
        [switch]$UseBuiltinCoords,
        [switch]$RefreshCache
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

    # --- Location cache: device coordinates rarely change ---
    $cacheDir  = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Cache'
    $cacheFile = Join-Path $cacheDir 'geolocation-coords.json'
    $cache     = @{}
    if (-not $RefreshCache -and (Test-Path $cacheFile)) {
        try {
            $cacheRaw = Get-Content -Path $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in $cacheRaw) {
                $cache["$($entry.Id)"] = @{ Lat = [double]$entry.Lat; Lng = [double]$entry.Lng }
            }
            Write-Verbose "Loaded $($cache.Count) cached device coordinates."
        }
        catch { Write-Verbose "Cache read failed, will re-fetch all: $_" }
    }

    # Separate devices into cached (coords known) vs uncached (need API fetch)
    $cachedDevices   = @()
    $uncachedDevices = @()
    foreach ($device in $devices) {
        $deviceId = if ($device.id) { $device.id } else { $device.deviceId }
        if (-not $deviceId) { continue }
        if ($cache.ContainsKey("$deviceId")) {
            $cachedDevices += $device
        }
        else {
            $uncachedDevices += $device
        }
    }
    Write-Verbose "Cache hit: $($cachedDevices.Count), miss: $($uncachedDevices.Count)"

    # --- Fetch coordinates for uncached devices via runspace pool (PS 5.1 parallel) ---
    $fetchedCoords = @{}  # deviceId -> @{Lat;Lng}

    if ($uncachedDevices.Count -gt 0) {
        $totalUncached = $uncachedDevices.Count
        $poolSize = [Math]::Min(8, $totalUncached)
        $baseUri      = $Config.BaseUri
        $accessToken  = $Config._AccessToken
        $tokenType    = $Config._TokenType
        $useBuiltin   = [bool]$UseBuiltinCoords

        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $poolSize)
        $pool.Open()

        $scriptBlock = {
            param($BaseUri, $DeviceId, $TokenType, $AccessToken, $UseBuiltin)
            $headers = @{
                "Content-Type"  = "application/json"
                "Authorization" = "$TokenType $AccessToken"
            }
            $lat = $null; $lng = $null
            try {
                if ($UseBuiltin) {
                    $uri = "$BaseUri/api/v1/devices/$DeviceId/attributes/-?names=Latitude&names=Longitude&limit=10"
                    $result = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
                    if ($result.data) {
                        foreach ($attr in $result.data) {
                            if ($attr.name -eq 'Latitude')  { $lat = [double]$attr.value }
                            if ($attr.name -eq 'Longitude') { $lng = [double]$attr.value }
                        }
                    }
                }
                else {
                    $uri = "$BaseUri/api/v1/devices/$DeviceId/attributes/-?names=LatLong&limit=10"
                    $result = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
                    if ($result.data) {
                        foreach ($attr in $result.data) {
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
            }
            catch { }
            return @{ DeviceId = $DeviceId; Lat = $lat; Lng = $lng }
        }

        $jobs = [System.Collections.Generic.List[object]]::new()
        foreach ($device in $uncachedDevices) {
            $deviceId = if ($device.id) { $device.id } else { $device.deviceId }
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($scriptBlock)
            [void]$ps.AddArgument($baseUri)
            [void]$ps.AddArgument($deviceId)
            [void]$ps.AddArgument($tokenType)
            [void]$ps.AddArgument($accessToken)
            [void]$ps.AddArgument($useBuiltin)
            $handle = $ps.BeginInvoke()
            $jobs.Add(@{ PS = $ps; Handle = $handle; DeviceId = $deviceId })
        }

        $completed = 0
        foreach ($job in $jobs) {
            $completed++
            $pct = [Math]::Round(($completed / $totalUncached) * 100, 0)
            Write-Progress -Activity "Fetching device locations (uncached)" `
                -Status "$completed of $totalUncached" -PercentComplete $pct
            try {
                $result = $job.PS.EndInvoke($job.Handle)
                if ($result -and $null -ne $result.Lat -and $null -ne $result.Lng) {
                    $fetchedCoords["$($result.DeviceId)"] = @{ Lat = $result.Lat; Lng = $result.Lng }
                }
            }
            catch { Write-Verbose "Runspace error for device $($job.DeviceId): $_" }
            finally { $job.PS.Dispose() }
        }
        $pool.Close()
        $pool.Dispose()
        Write-Progress -Activity "Fetching device locations (uncached)" -Completed
        Write-Verbose "Fetched $($fetchedCoords.Count) new coordinates via runspace pool."
    }

    # --- Merge cached + freshly fetched coordinates ---
    $allCoords = @{}
    foreach ($k in $cache.Keys)         { $allCoords[$k] = $cache[$k] }
    foreach ($k in $fetchedCoords.Keys) { $allCoords[$k] = $fetchedCoords[$k] }

    # --- Build result objects (status from overview, coords from cache/fetch) ---
    $geoDevices = @()
    foreach ($device in $devices) {
        $deviceId = if ($device.id) { $device.id } else { $device.deviceId }
        if (-not $deviceId) { continue }
        $coords = $allCoords["$deviceId"]
        if (-not $coords) { continue }

        $bestState  = if ($device.bestState)  { $device.bestState }  else { 'Unknown' }
        $worstState = if ($device.worstState) { $device.worstState } else { 'Unknown' }

        $geoDevices += [PSCustomObject]@{
            Type                  = 'Device'
            Name                  = if ($device.name) { $device.name } elseif ($device.displayName) { $device.displayName } else { "Device $deviceId" }
            DeviceId              = $deviceId
            Latitude              = $coords.Lat
            Longitude             = $coords.Lng
            BestState             = $bestState
            WorstState            = $worstState
            TotalMonitors         = if ($device.totalActiveMonitors) { $device.totalActiveMonitors } else { 0 }
            DownMonitors          = if ($device.totalActiveMonitorsDown) { $device.totalActiveMonitorsDown } else { 0 }
            DownMonitorDetails    = if ($device.downActiveMonitors) { $device.downActiveMonitors } else { @() }
        }
    }

    # --- Update cache on disk ---
    if ($allCoords.Count -gt 0) {
        try {
            if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
            $cacheData = $allCoords.Keys | ForEach-Object {
                [PSCustomObject]@{ Id = $_; Lat = $allCoords[$_].Lat; Lng = $allCoords[$_].Lng }
            }
            $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cacheFile -Encoding UTF8 -Force
            Write-Verbose "Saved $($allCoords.Count) coordinates to cache."
        }
        catch { Write-Verbose "Failed to write location cache: $_" }
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
    .PARAMETER RefreshIntervalSeconds
        If specified, adds a meta refresh tag so the browser reloads the page
        automatically at the given interval. Useful when a scheduled task
        regenerates the HTML file. Default is 0 (disabled).
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
        [hashtable]$TileApiKeys,
        [int]$RefreshIntervalSeconds = 0
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

    # Auto-refresh meta tag (0 = disabled)
    if ($RefreshIntervalSeconds -gt 0) {
        $html = $html.Replace('%%AUTO_REFRESH%%', "<meta http-equiv=`"refresh`" content=`"$RefreshIntervalSeconds`" />")
    }
    else {
        $html = $html.Replace('%%AUTO_REFRESH%%', '')
    }

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
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBmrqdCp60vt+9m
# zTMycDAohlkSLL1N/bci2lwa2E5feKCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD6+5p4
# ANWfxQrrRezdnmNaihAUNC45BVywIzzHFjC3hzANBgkqhkiG9w0BAQEFAASCAgDA
# bmtG/QWeOOGxFFr6zWP0NwR4+X6ra5B05hPUcgL3L0wLhY6XsKZHlvPyC+7rzCF/
# L6jzkJuEgAqbhE6xfdy/0w0UG3QqG6Y7KXEmqC2RM5JFcvPQDYo3vZmNyFvQRTLA
# gx+XFYfHDoVwQNMj7JAauJ7Vvb/DmiIhMjP2xjaKQjWfhWY1QMPvhsrqMpbIfSE5
# Gp2IzFA3rYj0sBs6RxDY8woKvM7QmwChI6iNtYb+eePJVAouasFaTdCBvJOSagD/
# PetV02W6N79yMJx2oX9u7SjKY/QDRNu1+hykZrF//5/mTEPJlkiUZv267Nwp8cUt
# 6Fnon8oGo5gpt+7V0MLu1AbEIXow7z85POo9VbmVmav6c3jq35QhUtV73eYlce92
# WcMy6KcoYWXcbeUTiHrNiBNffhoZRdf0ClA9aEnEwEXQSI53/cAvmKegEWpuXxli
# l4fxUhyI+94d49fZZUadTgiHNKrJWISbbdYRYQYC7XM0NGWVc8yZ02Dlrr1tw9A1
# u66qnTDszDwKiiC0R4QEzWBjtj8rD0oM93zggcIu4CUcRHObN21inf40fC+efAmx
# FxIE2VNae4JCnEGRhG3OHhMtdjW8XLyuhDAG8j/yYAv9Xi2gh3DBL8PJulVMN+Qw
# CqpGBMPOJF8Hjqmcx31nshdNbmbJqMEYz3A/r6i80aGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzE4NTIy
# NFowPwYJKoZIhvcNAQkEMTIEMODTAZN6RxD88KsRRPrZcKS6aT17WfZqqszW6Xuz
# dL8m/zHF1x69K2bKFcWi9i+e+jANBgkqhkiG9w0BAQEFAASCAgCyywxGRJFfu9bT
# Tti+FRjA6OBu9bixg2JVx1Z4jUV4GOOYPNwdPPGtn/zCl2e7ce6DmdgMm0/4SS0S
# +E6n8BL/GRoFDV81ryEYPNXs0Bl42rIPG6KQBIPNbT8H2cTpz6fp7xK5PEUSt8b7
# GzUfaMY4H9aqp9+QCBnJXjobG91T/iPbArj3k/qaUHP/d2ONuy3YIMzVCqynFl8g
# 7vOVSmodjvEj/aM25sTPn3EfYfilQ5jvzqO1xv4kGnny8HF+vtACVSshcjFQSxYi
# AtWEVYEKgO3slmZ97MrjMa1I+aBVp9AWytZRnTity4ZU4OthRMyYdxnedrB2/lq+
# 75afSqBLgA/5UdMvKVEfephxNwLnJKLgFuUF6j+Rkt6oyGSvoW0lvULDcGI1IG45
# Cld2lb+QqozX3+8ZbwkBh9GOJDCoFkIWc1SdgDyGlHt4wARBrrAhgZboZIsA2DgJ
# n8bh7L92XR3t02+5G8GuvByQswUwGAtUhm+FR6UtF8XIuDv5i1kFMp2ClTVNL8I2
# 2hq502LWccHnjyMZIkp7a1ss5+jOLvkgJ0m/nm3vmG7iEcw0DGmw0ShLTvuw8sdb
# 1JhyBYA55O42nRrX1cN/nbM1i9cBU1oIfibgBrhUErjfJph/DLSzKSXUBx69zc8E
# nFktJP0jQFjcvEACFgXbwkkPXGKEMg==
# SIG # End signature block
