# =============================================================================
# Certificate Dashboard Report Generator
# Uses CertificateHelpers.ps1 to scan one or more IP addresses across multiple
# TCP ports, discover TLS certificates, and produce an interactive HTML
# dashboard showing certificate health, expiration status, and optional
# WhatsUp Gold device enrichment.
#
# Prerequisites:
#   - PowerShell 5.1+ or PowerShell 7+
#   - Network access to target hosts on the scanned TCP ports
#
# Usage:
#   .\Get-CertificateDashboard.ps1                                                  # Prompts for IPs, default ports (443, 8443)
#   .\Get-CertificateDashboard.ps1 -IPAddresses "10.0.0.1"                          # Single IP, default ports
#   .\Get-CertificateDashboard.ps1 -IPAddresses "10.0.0.1","10.0.0.2"              # Multiple IPs
#   .\Get-CertificateDashboard.ps1 -IPAddresses (Get-Content .\hosts.txt)           # IPs from a file
#   .\Get-CertificateDashboard.ps1 -IPAddresses "10.0.0.1" -TcpPorts 443,8443,4443 # Custom port list
#   .\Get-CertificateDashboard.ps1 -UseWUGDevices                                   # Pull IPs from WhatsUp Gold
#   # Then open the generated HTML file in a browser.
# =============================================================================

param (
    [Parameter(Mandatory = $false)]
    [string[]]$IPAddresses,

    [Parameter(Mandatory = $false)]
    [int[]]$TcpPorts = @(443, 8443),

    [Parameter(Mandatory = $false)]
    [int]$ConnectTimeoutMs = 5000,

    [Parameter(Mandatory = $false)]
    [int]$WarningDays = 90,

    [Parameter(Mandatory = $false)]
    [int]$CriticalDays = 30,

    [Parameter(Mandatory = $false)]
    [switch]$UseWUGDevices,

    [Parameter(Mandatory = $false)]
    [string]$WUGServerUri,

    [Parameter(Mandatory = $false)]
    [pscredential]$WUGCredential
)

# --- Configuration -----------------------------------------------------------
# Dot-source the certificate helpers
$helpersPath = Join-Path $PSScriptRoot "CertificateHelpers.ps1"
if (Test-Path $helpersPath) {
    . $helpersPath
}
else {
    throw "CertificateHelpers.ps1 not found at $helpersPath. Ensure it is in the same directory."
}

# Import WhatsUpGoldPS module if available (for WUG integration)
if (Get-Module -ListAvailable -Name WhatsUpGoldPS) {
    if (-not (Get-Module -Name WhatsUpGoldPS)) {
        Import-Module -Name WhatsUpGoldPS
    }
}

# --- Resolve IP addresses ----------------------------------------------------
if ($UseWUGDevices) {
    # Connect to WUG if not already connected
    if (-not $global:WUGBearerHeaders) {
        if (-not $WUGServerUri) {
            $WUGServerUri = Read-Host -Prompt "Enter WhatsUp Gold server URI (e.g. 192.168.1.100)"
        }
        if (-not $WUGCredential) {
            $WUGCredential = Get-Credential -Message "Enter WhatsUp Gold credentials"
        }
        Connect-WUGServer -serverUri $WUGServerUri -Credential $WUGCredential -IgnoreSSLErrors -Protocol https
    }

    Write-Host "Retrieving device list from WhatsUp Gold..." -ForegroundColor Cyan
    $wugDevices = Get-WUGDevice -View overview
    $IPAddresses = @($wugDevices | ForEach-Object { $_.networkAddress } | Where-Object { $_ })
    Write-Host "  Found $($IPAddresses.Count) devices in WhatsUp Gold." -ForegroundColor Green
}

if (-not $IPAddresses -or $IPAddresses.Count -eq 0) {
    $hostInput = Read-Host -Prompt "Enter IP address(es) or hostname(s) (comma-separated)"
    $IPAddresses = $hostInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

if (-not $IPAddresses -or $IPAddresses.Count -eq 0) {
    throw "At least one IP address or hostname must be specified."
}

Write-Host "`nScanning $($IPAddresses.Count) host(s) across port(s): $($TcpPorts -join ', ')" -ForegroundColor Cyan
Write-Host "Timeout: ${ConnectTimeoutMs}ms | Warning: ${WarningDays}d | Critical: ${CriticalDays}d`n" -ForegroundColor DarkGray

# Output paths
$outputDir = if ($env:TEMP) { $env:TEMP } else { "C:\temp" }
$jsonPath  = Join-Path $outputDir "certificate_dashboard.json"
$htmlPath  = Join-Path $outputDir "Certificate-Dashboard.html"

# Ensure output directory exists
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- Discover certificates ---------------------------------------------------
$rawCerts = Get-CertificateInfo -IPAddresses $IPAddresses -TcpPorts $TcpPorts -ConnectTimeoutMs $ConnectTimeoutMs

if (-not $rawCerts -or $rawCerts.Count -eq 0) {
    Write-Warning "No certificates discovered from any host. Exiting."
    return
}

Write-Host "`nDiscovered $($rawCerts.Count) certificate(s) across all hosts." -ForegroundColor Green

# --- Build dashboard data ----------------------------------------------------
$dashboardData = Get-CertificateDashboard -CertificateData $rawCerts -WarningDays $WarningDays -CriticalDays $CriticalDays

# Summary
$expired  = @($dashboardData | Where-Object { $_.Status -eq 'Expired' }).Count
$critical = @($dashboardData | Where-Object { $_.Status -eq 'Critical' }).Count
$warning  = @($dashboardData | Where-Object { $_.Status -eq 'Warning' }).Count
$healthy  = @($dashboardData | Where-Object { $_.Status -eq 'Healthy' }).Count
$unknown  = @($dashboardData | Where-Object { $_.Status -eq 'Unknown' }).Count

Write-Host "`n--- Certificate Health Summary ---" -ForegroundColor Yellow
if ($expired  -gt 0) { Write-Host "  Expired:  $expired"  -ForegroundColor Red }
if ($critical -gt 0) { Write-Host "  Critical: $critical" -ForegroundColor Red }
if ($warning  -gt 0) { Write-Host "  Warning:  $warning"  -ForegroundColor DarkYellow }
if ($healthy  -gt 0) { Write-Host "  Healthy:  $healthy"  -ForegroundColor Green }
if ($unknown  -gt 0) { Write-Host "  Unknown:  $unknown"  -ForegroundColor Gray }

# --- Generate outputs --------------------------------------------------------
# JSON export
$dashboardData | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Force -Encoding UTF8
Write-Host "`nJSON data written to $jsonPath" -ForegroundColor Yellow

# HTML dashboard
$templatePath = Join-Path $PSScriptRoot "Certificate-Dashboard-Template.html"
Export-CertificateDashboardHtml -DashboardData $dashboardData -OutputPath $htmlPath -ReportTitle "Certificate Dashboard" -TemplatePath $templatePath
Write-Host "HTML dashboard written to $htmlPath" -ForegroundColor Yellow

# --- Optional: Open in browser -----------------------------------------------
$openBrowser = Read-Host -Prompt "Open dashboard in browser? (Y/N)"
if ($openBrowser -match '^[Yy]') {
    Start-Process $htmlPath
}

# --- Optional: WUG Certificate Monitor Integration --------------------------
# If WhatsUpGoldPS is loaded, you can auto-create certificate monitors.
# Uncomment below to use:
#
# if ($global:WUGBearerHeaders) {
#     foreach ($entry in $dashboardData) {
#         $IPaddr = $entry.IPAddress
#         $monitorId = Add-WUGActiveMonitor -Type Certificate -Name "https://${IPaddr}" `
#             -CertOption url -CertPath "https://${IPaddr}" `
#             -CertCheckExpires $true -CertExpiresDays $CriticalDays
#         $deviceId = (Get-WUGDevice -SearchValue $IPaddr).id
#         Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $monitorId `
#             -ActionPolicyName "Jason Notifications" -PollingIntervalSeconds 86400
#         Write-Host "Monitor created for $IPaddr"
#     }
#     Write-Host "Certificate monitors synced to WhatsUp Gold." -ForegroundColor Green
# }

Write-Host "`nDone." -ForegroundColor Green

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBLxDLaIzA4yZ4B
# BdkoVdKmYNnBvI1dk8gHTxnXjv52nKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgJtQoj4a5Q2xKHBK+mK4Y+2A19IkPeXa2
# lVNNzxATyvswDQYJKoZIhvcNAQEBBQAEggIAi+ZtMqidrcQ25dr+j0ki5R0MIqUu
# F9egt/+jcA6GzWAgxN8rfQaPqxdOvOMJx/JMpaOOjXFOYCqXrNxxw7h5ecelVhVJ
# dVoynnxrhTc8g8yRpg+4b1lwwTbvnTHqanxy9jB4BrIJkaEeXrKz/xMUsC2HWrDu
# SQJKf7x5K7Gpdyp5GCFXiR8B9tYVropsMqztiV0uf2u0Dnnbuof6wQkOjk+9itxa
# PlmwN+lK8uMHRosMXex3Y8JC68EEYnE97PywKqcmMLrcbcByl7QyZfNgP4nvSgz8
# Wd4Pu7c6jkm0x91ZAS9lAYOC7XqKDzMbMI/pNSkjGAzEJHW/7v1BPoetNmLn5lzT
# si3uJJaop0T+dYtoN0+1lvMiEGEfJqq8HhzM0ttvyDG0QQuxOYO5z4YdtM3LNS4p
# ye/Dg6QMoB/1D01sK02pOSYDAqwrPm/9pg69RBaVD1rc+tCOBXT4YKPj1iIobdRV
# xFpO9rZZ3IEpX8AORsNr85IAS03wgWwxU7z7SPIMvlcqjTyMggvaIlI9Up5TFUNC
# 12oS+JOdLbggECGgPqvkfyo5rT9BRLwJjFw1glLjOGM+nRIrcjBbTDID+Z/2lq1D
# kiWLCNiLmolsja0XxNZT7I9d1phXteKySeJjHYIBLWkx0Bq+3zL0MSwzg3IoyweT
# z1pLN+b2tL2Hvx4=
# SIG # End signature block
