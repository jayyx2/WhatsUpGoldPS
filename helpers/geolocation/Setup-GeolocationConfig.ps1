<#
.SYNOPSIS
    One-time setup script that configures WhatsUp Gold geolocation map generation.
.DESCRIPTION
    Interactive setup script that prompts the administrator for their WhatsUp Gold
    server connection details, validates the connection, and saves the configuration
    to a local JSON file for use by the scheduled map generation script
    (Update-GeolocationMap.ps1).

    The saved config includes the server URI, protocol, port, and an encrypted
    refresh token (encrypted with DPAPI - only the same user on the same machine
    can decrypt it). No plaintext passwords are stored.
.PARAMETER ConfigPath
    Path where the configuration file will be saved.
    Default: same directory as this script, "geolocation-config.json".
.PARAMETER WugServer
    The hostname or IP of the WhatsUp Gold server. If omitted, prompts interactively.
.PARAMETER Protocol
    http or https (default: https).
.PARAMETER Port
    The WUG API port (default: 9644).
.PARAMETER WugConsoleUrl
    The base URL of the WhatsUp Gold web console for clickable markers.
    Example: https://wug.example.com:443
    If omitted, prompts interactively.
.PARAMETER DefaultLat
    Default map centre latitude (default: 39.8283 - U.S. centre).
.PARAMETER DefaultLng
    Default map centre longitude (default: -98.5795 - U.S. centre).
.PARAMETER DefaultZoom
    Default map zoom level (default: 5).
.PARAMETER GroupName
    Optional device group name to filter devices. Default: "All".
.PARAMETER UseBuiltinCoords
    Use separate "Latitude"/"Longitude" attributes instead of a single "LatLong" attribute.
.PARAMETER IncludeDevices
    Show devices on the map (default: $true).
.PARAMETER IncludeGroups
    Show groups on the map (default: $true).
.PARAMETER IgnoreSSLErrors
    Bypass SSL certificate validation when connecting to WUG.
.EXAMPLE
    .\Setup-GeolocationConfig.ps1

    Prompts interactively for all required values.
.EXAMPLE
    .\Setup-GeolocationConfig.ps1 -WugServer "192.168.1.100" -WugConsoleUrl "https://192.168.1.100"

    Provides server details on the command line; prompts only for credentials.
.NOTES
    Author  : jason@wug.ninja
    Version : 1.0.0
    Date    : 2025-07-15
    Requires: PowerShell 5.1+, network access to WUG REST API
#>

param(
    [string]$ConfigPath,
    [string]$WugServer,
    [ValidateSet("http","https")][string]$Protocol = "https",
    [ValidateRange(1,65535)][int]$Port = 9644,
    [string]$WugConsoleUrl,
    [double]$DefaultLat   = 39.8283,
    [double]$DefaultLng   = -98.5795,
    [int]$DefaultZoom     = 5,
    [string]$GroupName    = 'All',
    [switch]$UseBuiltinCoords,
    [bool]$IncludeDevices = $true,
    [bool]$IncludeGroups  = $true,
    [switch]$IgnoreSSLErrors
)

# ----- Resolve paths -----
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'geolocation-config.json' }

# Dot-source the helpers
$helpersPath = Join-Path $scriptDir 'GeolocationHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    throw "GeolocationHelpers.ps1 not found at: $helpersPath"
}
. $helpersPath

# ----- Interactive prompts -----
Write-Host "`n=== WhatsUp Gold Geolocation Map - Setup ===" -ForegroundColor Cyan

if (-not $WugServer) {
    $WugServer = Read-Host "Enter the WhatsUp Gold server hostname or IP"
    if ([string]::IsNullOrWhiteSpace($WugServer)) { throw "Server address is required." }
}

$cred = Get-Credential -Message "Enter WhatsUp Gold credentials (used to obtain API token)"
$username = $cred.GetNetworkCredential().UserName
$password = $cred.GetNetworkCredential().Password

if (-not $WugConsoleUrl) {
    $WugConsoleUrl = Read-Host "Enter the WUG web console base URL (e.g. https://wug.example.com:443) [press Enter to skip]"
}

# ----- Connect & validate -----
Write-Host "`nConnecting to ${Protocol}://${WugServer}:${Port}..." -ForegroundColor Yellow

$connectParams = @{
    ServerUri      = $WugServer
    Username       = $username
    Password       = $password
    Protocol       = $Protocol
    Port           = $Port
}
if ($IgnoreSSLErrors) { $connectParams.IgnoreSSLErrors = $true }

$config = Connect-GeoWUGServer @connectParams

# Quick API validation - fetch product info
try {
    $apiInfo = Invoke-GeoAPI -Config $config -Endpoint "/api/v1/product/api"
    Write-Host "API version: $($apiInfo.data.apiVersion) - WhatsUp Gold $($apiInfo.data.productVersion)" -ForegroundColor Green
}
catch {
    Write-Warning "Connected but could not verify API version: $($_.Exception.Message)"
}

# ----- Encrypt refresh token with DPAPI -----
$secureToken = ConvertTo-SecureString -String $config._RefreshToken -AsPlainText -Force
$encryptedToken = ConvertFrom-SecureString -SecureString $secureToken

# ----- Build config object -----
$savedConfig = @{
    ServerUri        = $WugServer
    Protocol         = $Protocol
    Port             = $Port
    IgnoreSSL        = [bool]$IgnoreSSLErrors
    WugConsoleUrl    = $WugConsoleUrl
    EncryptedRefresh = $encryptedToken
    DefaultLat       = $DefaultLat
    DefaultLng       = $DefaultLng
    DefaultZoom      = $DefaultZoom
    GroupName        = $GroupName
    UseBuiltinCoords = [bool]$UseBuiltinCoords
    IncludeDevices   = $IncludeDevices
    IncludeGroups    = $IncludeGroups
    CreatedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    CreatedBy        = $env:USERNAME
}

# ----- Save -----
$savedConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
Write-Host "`nConfiguration saved to: $ConfigPath" -ForegroundColor Green
Write-Host "Refresh token encrypted with DPAPI - only $($env:USERNAME) on $($env:COMPUTERNAME) can decrypt it.`n" -ForegroundColor DarkGray

# ----- Print next steps -----
Write-Host "=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. Test map generation:"
Write-Host "   .\Update-GeolocationMap.ps1" -ForegroundColor White
Write-Host "2. Schedule via Windows Task Scheduler:"
Write-Host "   Action  : Start a program" -ForegroundColor White
Write-Host "   Program : powershell.exe" -ForegroundColor White
Write-Host "   Args    : -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $scriptDir 'Update-GeolocationMap.ps1')`"" -ForegroundColor White
Write-Host "   Trigger : Every 5 minutes (or as needed)`n" -ForegroundColor White
