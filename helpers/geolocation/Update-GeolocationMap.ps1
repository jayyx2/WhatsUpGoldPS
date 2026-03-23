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

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAVuOss2ol0Y7bP
# 2bMDmP29b50uKQ0ubo4K3iqL1GpkZKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgcLcJ2lxuCI890o64WKTHgLZltYxjNzeV
# SWYqA2HYKqAwDQYJKoZIhvcNAQEBBQAEggIA4WZichMimpdUFARpKxOT9+1iy6Yp
# nTmz5KmgCxggJ/AzvYADpzODXqcvNfVub6jMEdAL2KOJq3IaFOYOOF9QAgr58lDA
# 3MWcPyJ3V05NN+pvNDlaYdB9kGPq3rzOJGrobXlelumEZdGuFCtZw/DkQA5Y6c8x
# OE8CfisBQQE/Ig/8V+TuMdaQ+GjQXVUC22SCAif2HQAKZ6zt8790gvmkipIn8CQe
# yK6R8Oe1ZK6fPEEp4aVfJRXvf5f/lhjZkfbR+co2HTg+SpetMZG6pgCcXd9rh70j
# SrCYPhlsHnpw2P3G0MMoiyK5LOaOpXgug9d+NZUWljt8Ew+kglvwHxQxGylmZTfm
# EzFtfC7aCk6f9K5NG35ZWxEiiAo5fJVeGP1ZzMwfvkAQp08UwqOMN5FEgsOvFvBk
# aXuiEpyJJyhRNJbctePpHkY6gKSxT/wpz9ugteDGSBY0130Kgw7QBs24EJwdSbpc
# tsc3tRptztR1e+rytPmKCov957XXcDDMS7hpJ7jh3lxf/rvMEyXMjhv2yxYol5c5
# UV2Nodrplr4sBuYf/66bUlAPRg2b9va4ExcRrIaUI3sxw/dKZvmuamt67efF7FRU
# bjWcz7gJ4bijJ2hd46ZH4RZDTGLZgFqvhhxWwGMlViR3D74zUDbMM7rPaB47lPOM
# w+Aw334+DqCczQ4=
# SIG # End signature block
