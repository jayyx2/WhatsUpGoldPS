<#
.SYNOPSIS
    One-time setup script that configures WhatsUp Gold geolocation map generation.
.DESCRIPTION
    Interactive setup script that prompts the administrator for their WhatsUp Gold
    server connection details, validates the connection, and saves the configuration
    to the DPAPI vault for use by the scheduled map generation script
    (Update-GeolocationMap.ps1).

    The saved config includes the server URI, protocol, port, tile provider API
    keys, and a refresh token, all encrypted with DPAPI and stored in the vault
    at %LOCALAPPDATA%\DiscoveryHelpers\Vault. Only the same user on the same
    machine can decrypt them. No plaintext passwords are stored.
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

# Dot-source the helpers
$helpersPath = Join-Path $scriptDir 'GeolocationHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    throw "GeolocationHelpers.ps1 not found at: $helpersPath"
}
. $helpersPath

# Load vault functions
$discoveryHelpersPath = Join-Path (Split-Path $scriptDir -Parent) 'discovery\DiscoveryHelpers.ps1'
if (-not (Test-Path $discoveryHelpersPath)) {
    throw "DiscoveryHelpers.ps1 not found at: $discoveryHelpersPath"
}
. $discoveryHelpersPath

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

# ----- Build vault config fields -----
$configFields = @{}
foreach ($item in @(
    @('ServerUri',        $WugServer),
    @('Protocol',         $Protocol),
    @('Port',             [string]$Port),
    @('IgnoreSSL',        [string][bool]$IgnoreSSLErrors),
    @('WugConsoleUrl',    $(if ($WugConsoleUrl) { $WugConsoleUrl } else { '' })),
    @('DefaultLat',       [string]$DefaultLat),
    @('DefaultLng',       [string]$DefaultLng),
    @('DefaultZoom',      [string]$DefaultZoom),
    @('GroupName',        $GroupName),
    @('UseBuiltinCoords', [string][bool]$UseBuiltinCoords),
    @('IncludeDevices',   [string]$IncludeDevices),
    @('IncludeGroups',    [string]$IncludeGroups)
)) {
    $configFields[$item[0]] = ConvertTo-SecureString -String $item[1] -AsPlainText -Force
}

# ----- Optional tile provider API keys (DPAPI encrypted) -----
Write-Host "`n=== Tile Provider API Keys (optional) ===" -ForegroundColor Cyan
Write-Host "Add API keys for premium map layers. Press Enter to skip any provider." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Thunderforest    : https://manage.thunderforest.com/dashboard        (free: 150k tiles/month)" -ForegroundColor DarkGray
Write-Host "  Stadia Maps      : https://client.stadiamaps.com/                    (free: 200k tiles/month)" -ForegroundColor DarkGray
Write-Host "  MapTiler         : https://cloud.maptiler.com/account/keys           (free: 100k tiles/month)" -ForegroundColor DarkGray
Write-Host "  HERE             : https://developer.here.com/                       (free: 250k tiles/month)" -ForegroundColor DarkGray
Write-Host "  Mapbox           : https://account.mapbox.com/                       (free: 200k tiles/month)" -ForegroundColor DarkGray
Write-Host "  Jawg             : https://www.jawg.io/lab/                          (free: 50k tiles/month)" -ForegroundColor DarkGray
Write-Host "  TomTom           : https://developer.tomtom.com/user/register        (free: 2500 tx/day)" -ForegroundColor DarkGray
Write-Host "  OpenWeatherMap   : https://openweathermap.org/                       (free: 1k calls/day, overlays)" -ForegroundColor DarkGray

$tileKeys = @{}
$tfKey = Read-Host "`n  Thunderforest API key [Enter to skip]"
if ($tfKey) { $tileKeys.thunderforest = $tfKey }
$sdKey = Read-Host "  Stadia Maps API key [Enter to skip]"
if ($sdKey) { $tileKeys.stadia = $sdKey }
$mtKey = Read-Host "  MapTiler API key [Enter to skip]"
if ($mtKey) { $tileKeys.maptiler = $mtKey }
$hereKey = Read-Host "  HERE API key [Enter to skip]"
if ($hereKey) { $tileKeys.here = $hereKey }
$mbKey = Read-Host "  Mapbox access token [Enter to skip]"
if ($mbKey) { $tileKeys.mapbox = $mbKey }
$jawgKey = Read-Host "  Jawg access token [Enter to skip]"
if ($jawgKey) { $tileKeys.jawg = $jawgKey }
$ttKey = Read-Host "  TomTom API key [Enter to skip]"
if ($ttKey) { $tileKeys.tomtom = $ttKey }
$owmKey = Read-Host "  OpenWeatherMap API key [Enter to skip]"
if ($owmKey) { $tileKeys.openweathermap = $owmKey }

if ($tileKeys.Count -gt 0) {
    foreach ($provider in $tileKeys.Keys) {
        $configFields["TileApiKey.$provider"] = ConvertTo-SecureString -String $tileKeys[$provider] -AsPlainText -Force
    }
    Write-Host "  $($tileKeys.Count) API key(s) will be saved to the vault." -ForegroundColor Green
}
else {
    Write-Host "  No API keys configured. Only free tile layers will be available." -ForegroundColor DarkGray
}

# ----- Save to DPAPI vault -----
Save-DiscoveryCredential -Name 'Geolocation.Config' -Fields $configFields -Force `
    -Description 'Geolocation map config and API keys'

$ssRefresh = ConvertTo-SecureString -String $config._RefreshToken -AsPlainText -Force
Save-DiscoveryCredential -Name 'Geolocation.RefreshToken' -SecureSecret $ssRefresh -Force `
    -Description 'WUG refresh token for geolocation scripts'

$vaultPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Vault'
Write-Host "`nConfiguration saved to DPAPI vault: $vaultPath" -ForegroundColor Green
Write-Host "Encrypted with DPAPI - only $($env:USERNAME) on $($env:COMPUTERNAME) can decrypt it.`n" -ForegroundColor DarkGray

# ----- Print next steps -----
Write-Host "=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. Test map generation:"
Write-Host "   .\Update-GeolocationMap.ps1" -ForegroundColor White
Write-Host "2. Schedule via Windows Task Scheduler:"
Write-Host "   Action  : Start a program" -ForegroundColor White
Write-Host "   Program : powershell.exe" -ForegroundColor White
Write-Host "   Args    : -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $scriptDir 'Update-GeolocationMap.ps1')`"" -ForegroundColor White
Write-Host "   Trigger : Every 5 minutes (or as needed)`n" -ForegroundColor White

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDwJNBtso4H5Z6v
# Je2eHtEyPrGFmgbzhr9CPac1r6wa0aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgiB8Nd9n03LUS5IV+EQSjGTu85HEqV0nJ
# 4hgBvHZRfawwDQYJKoZIhvcNAQEBBQAEggIA5bZ9DdkyB0Yeiaqph8FyaBoYd4Er
# EVmfDY6W51OKJ+WCLWW3unIvM98RLR2BEBiqATT7h4KRLkekJ9bqyr7blhNAE1b7
# u0I1xAgvgmLZvfcK0h54hunEBqJV5CGek0BXWkDm/onlrqXhO2dl2e46KvG0bldj
# J31lw/g4pDc7fr9F2ZBLJrCfKig6kiO09bptaa3SanhORR3Pla3jUxf/FWwHnuy/
# gaYu26KAorRWUFcfJo7pQqGexoGn5yoFsY3aBbw4Bzyw678Wr/99NoXGNMHgRoW+
# qkJcs5T94yQSj+B4wv6Btd9As2lUjMif7eQL0lcuJfaPKFjhUii1+Hem3hUBRrCS
# LCEzjm3RNjnPyyCJxDhROHy9MH+TDZ67Oq5/r+MAqKZLDAXTBINEGlCRBqqqdjo7
# 1yEIxylISPdFKuXJ+17FF/3z3WNTvmPnzSQEsxd6n98c/lmeFCCKfGK1RjMcbws1
# e5GjSOyEqvAh5CxcexcwA7JODbC008VDT0wCbhMFQAQMEaXilXqzKwZEwMjfVKCm
# 8t9CpfEl73WYOtfzg7cExAwNhtf3hZaZhwaN1AL4jLsoR4R6lWW2GMngBxHGcI8h
# PerQQxXbDcMuIeEz6HnCzPpFn61hHoUj5QxCAPue3MGWhD4yvcjwFQFPjR1g5cXi
# UgfuNMVg495g5n4=
# SIG # End signature block
