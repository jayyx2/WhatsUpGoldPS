<#
.SYNOPSIS
    Generates an interactive Leaflet HTML map showing geolocated WhatsUp Gold devices and groups.
.DESCRIPTION
    Scheduled-task–friendly script that reads the saved configuration from
    Setup-GeolocationConfig.ps1, authenticates to the WhatsUp Gold REST API
    using the stored (DPAPI-encrypted) refresh token, queries devices and groups
    for location data, and produces a self-contained HTML file with an interactive
    Leaflet map.

    Designed to be run unattended via Windows Task Scheduler.

    If the refresh token has expired or is invalid, the script will exit with a
    clear error telling the administrator to re-run Setup-GeolocationConfig.ps1.
.PARAMETER ConfigPath
    Path to the configuration JSON file created by Setup-GeolocationConfig.ps1.
    Default: geolocation-config.json in the same directory as this script.
.PARAMETER OutputPath
    Full path for the generated HTML map file.
    Default: Geolocation-Map.html in the system temp directory.
.PARAMETER OpenBrowser
    Automatically open the generated HTML map in the default browser.
.EXAMPLE
    .\Update-GeolocationMap.ps1

    Uses the default config and output paths.
.EXAMPLE
    .\Update-GeolocationMap.ps1 -OutputPath "C:\inetpub\wwwroot\wug-map.html"

    Generates the map to a web server directory.
.EXAMPLE
    .\Update-GeolocationMap.ps1 -OpenBrowser

    Generates the map and opens it in the default browser.
.NOTES
    Author  : jason@wug.ninja
    Version : 1.0.0
    Date    : 2025-07-15
    Requires: PowerShell 5.1+, configuration file from Setup-GeolocationConfig.ps1
#>

param(
    [string]$ConfigPath,
    [string]$OutputPath,
    [switch]$OpenBrowser
)

# ----- Resolve paths -----
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'geolocation-config.json' }
if (-not $OutputPath) { $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) 'Geolocation-Map.html' }

# ----- Load helpers -----
$helpersPath = Join-Path $scriptDir 'GeolocationHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    throw "GeolocationHelpers.ps1 not found at: $helpersPath"
}
. $helpersPath

# ----- Load config -----
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath`nRun Setup-GeolocationConfig.ps1 first."
}
$savedConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

# ----- Decrypt refresh token -----
try {
    $secureToken = ConvertTo-SecureString -String $savedConfig.EncryptedRefresh -ErrorAction Stop
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $refreshToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
catch {
    throw "Failed to decrypt refresh token. You may need to re-run Setup-GeolocationConfig.ps1 as the same user on the same machine.`nError: $($_.Exception.Message)"
}

# ----- SSL bypass -----
if ($savedConfig.IgnoreSSL) { Initialize-GeoSSLBypass }

# ----- Authenticate using refresh token -----
$baseUri  = "$($savedConfig.Protocol)://$($savedConfig.ServerUri):$($savedConfig.Port)"
$tokenUri = "$baseUri/api/v1/token"
$headers  = @{ "Content-Type" = "application/json" }
$body     = "grant_type=refresh_token&refresh_token=$refreshToken"

Write-Host "Authenticating to $baseUri..." -ForegroundColor Yellow

try {
    $token = Invoke-RestMethod -Uri $tokenUri -Method Post -Headers $headers -Body $body -ErrorAction Stop
}
catch {
    throw "Authentication failed. The refresh token may have expired.`nRe-run Setup-GeolocationConfig.ps1 to obtain a new token.`nError: $($_.Exception.Message)"
}

if (-not $token.access_token -or -not $token.refresh_token) {
    throw "Token response missing required fields. Re-run Setup-GeolocationConfig.ps1."
}

# Build runtime config
$config = @{
    BaseUri       = $baseUri
    _AccessToken  = $token.access_token
    _RefreshToken = $token.refresh_token
    _TokenType    = $token.token_type
    _Expiry       = (Get-Date).AddSeconds($token.expires_in)
}

Write-Host "Authenticated. Token expires at $($config._Expiry)." -ForegroundColor Green

# ----- Update stored refresh token for next run -----
try {
    $newSecure = ConvertTo-SecureString -String $token.refresh_token -AsPlainText -Force
    $newEncrypted = ConvertFrom-SecureString -SecureString $newSecure
    $savedConfig.EncryptedRefresh = $newEncrypted
    $savedConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Verbose "Updated stored refresh token for next run."
}
catch {
    Write-Warning "Could not update stored refresh token: $($_.Exception.Message)"
}

# ----- Gather geolocation data -----
Write-Host "Querying devices and groups for location data..." -ForegroundColor Yellow

$geoParams = @{
    Config         = $config
    IncludeDevices = if ($null -ne $savedConfig.IncludeDevices) { $savedConfig.IncludeDevices } else { $true }
    IncludeGroups  = if ($null -ne $savedConfig.IncludeGroups)  { $savedConfig.IncludeGroups }  else { $true }
}
if ($savedConfig.GroupName -and $savedConfig.GroupName -ne 'All') {
    $geoParams.GroupName = $savedConfig.GroupName
}
if ($savedConfig.UseBuiltinCoords) {
    $geoParams.UseBuiltinCoords = $true
}

$geoData = Get-GeolocationData @geoParams

if ($geoData.Count -eq 0) {
    Write-Warning "No geolocated devices or groups found. The map will be empty."
}
else {
    Write-Host "Found $($geoData.Count) markers ($(@($geoData | Where-Object { $_.Type -eq 'Device' }).Count) devices, $(@($geoData | Where-Object { $_.Type -eq 'Group' }).Count) groups)." -ForegroundColor Green
}

# ----- Export HTML map -----
$exportParams = @{
    Data        = @($geoData)
    OutputPath  = $OutputPath
    DefaultLat  = if ($savedConfig.DefaultLat)  { $savedConfig.DefaultLat }  else { 39.8283 }
    DefaultLng  = if ($savedConfig.DefaultLng)  { $savedConfig.DefaultLng }  else { -98.5795 }
    DefaultZoom = if ($savedConfig.DefaultZoom) { $savedConfig.DefaultZoom } else { 5 }
}
if ($savedConfig.WugConsoleUrl) {
    $exportParams.WugBaseUrl = $savedConfig.WugConsoleUrl
}

Export-GeolocationMapHtml @exportParams

# ----- Open in browser -----
if ($OpenBrowser) {
    Start-Process $OutputPath
}

Write-Host "Done. Map generated at: $OutputPath" -ForegroundColor Cyan
