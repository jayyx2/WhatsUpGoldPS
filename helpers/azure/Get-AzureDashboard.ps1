<#
.SYNOPSIS
    Generates an interactive HTML dashboard report for Azure environments.
.DESCRIPTION
    Orchestration script that authenticates to Azure (via service principal or
    existing session), enumerates resources across subscriptions and resource groups,
    and produces a searchable, sortable Bootstrap Table HTML dashboard. Optionally
    includes Azure Monitor metrics. Output includes both a JSON data file and a
    self-contained HTML report.
.PARAMETER TenantId
    Azure AD tenant ID for service principal authentication. Use with ApplicationId
    and ClientSecret. If omitted, uses the existing Azure session.
.PARAMETER ApplicationId
    Azure AD application (client) ID for service principal authentication.
.PARAMETER ClientSecret
    Client secret for the Azure AD application.
.PARAMETER SubscriptionIds
    Optional array of subscription IDs to limit scope. If omitted, scans all
    enabled subscriptions.
.PARAMETER IncludeMetrics
    Fetch Azure Monitor metrics for each resource. Can increase API calls
    significantly on large environments.
.EXAMPLE
    .\Get-AzureDashboard.ps1

    Uses the existing Azure session and scans all accessible subscriptions.
.EXAMPLE
    .\Get-AzureDashboard.ps1 -SubscriptionIds "xxxx-yyyy"

    Generates a dashboard for a specific subscription.
.EXAMPLE
    .\Get-AzureDashboard.ps1 -TenantId $tid -ApplicationId $aid -ClientSecret $secret

    Authenticates via service principal and scans all subscriptions.
.EXAMPLE
    .\Get-AzureDashboard.ps1 -SubscriptionIds "xxxx-yyyy" -IncludeMetrics

    Generates a dashboard with Azure Monitor metric data included.
.OUTPUTS
    System.Void
    Produces a JSON file (azure_dashboard.json) and an HTML dashboard
    (Azure-Dashboard.html) in the system temp directory, then opens the HTML in the default browser.
.NOTES
    Author  : jason@wug.ninja
    Version : 1.0.0
    Date    : 2025-07-15
    Requires: PowerShell 5.1+, Az PowerShell modules, AzureHelpers.ps1 in the same directory.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ApplicationId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeMetrics
)

# --- Configuration -----------------------------------------------------------
$helpersPath = Join-Path $PSScriptRoot "AzureHelpers.ps1"
if (Test-Path $helpersPath) {
    . $helpersPath
}
else {
    throw "AzureHelpers.ps1 not found at $helpersPath. Ensure it is in the same directory."
}

if (Get-Module -ListAvailable -Name WhatsUpGoldPS) {
    if (-not (Get-Module -Name WhatsUpGoldPS)) {
        Import-Module -Name WhatsUpGoldPS
    }
}

# --- Authenticate ------------------------------------------------------------
if ($TenantId -and $ApplicationId -and $ClientSecret) {
    Connect-AzureServicePrincipal -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret
}
else {
    Write-Host "No service principal specified. Using existing Azure session..." -ForegroundColor Yellow
    try {
        Get-AzContext -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "No active Azure session. Running Connect-AzAccount..." -ForegroundColor Cyan
        Connect-AzAccount
    }
}

# Output paths
$outputDir = if ($env:TEMP) { $env:TEMP } else { "C:\temp" }
$jsonPath  = Join-Path $outputDir "azure_dashboard.json"
$htmlPath  = Join-Path $outputDir "Azure-Dashboard.html"
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- Collect data ------------------------------------------------------------
Write-Host "`nEnumerating Azure resources..." -ForegroundColor Cyan
$dashboardData = Get-AzureDashboard -SubscriptionIds $SubscriptionIds -IncludeMetrics $IncludeMetrics

if (-not $dashboardData -or $dashboardData.Count -eq 0) {
    Write-Warning "No resources collected. Exiting."
    return
}

# --- Summary -----------------------------------------------------------------
$succeeded = @($dashboardData | Where-Object { $_.ProvisioningState -in 'Succeeded','Running','Available','Ready' }).Count
$other     = $dashboardData.Count - $succeeded
$subs      = @($dashboardData | Select-Object -ExpandProperty Subscription -Unique).Count
$rgs       = @($dashboardData | Select-Object -ExpandProperty ResourceGroup -Unique).Count

Write-Host "`n--- Azure Summary ---" -ForegroundColor Yellow
Write-Host "  Total:         $($dashboardData.Count)"
Write-Host "  Succeeded:     $succeeded" -ForegroundColor Green
Write-Host "  Other:         $other" -ForegroundColor Red
Write-Host "  Subscriptions: $subs | Resource Groups: $rgs"

# --- Generate outputs --------------------------------------------------------
$dashboardData | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Force -Encoding UTF8
Write-Host "`nJSON data written to $jsonPath" -ForegroundColor Yellow

$templatePath = Join-Path $PSScriptRoot "Azure-Dashboard-Template.html"
Export-AzureDashboardHtml -DashboardData $dashboardData -OutputPath $htmlPath -ReportTitle "Azure Dashboard" -TemplatePath $templatePath
Write-Host "HTML dashboard written to $htmlPath" -ForegroundColor Yellow

# --- Optional: Open in browser -----------------------------------------------
if ($env:OS -match 'Windows') {
    $openBrowser = Read-Host -Prompt "Open dashboard in browser? (Y/N)"
    if ($openBrowser -match '^[Yy]') {
        Start-Process $htmlPath
    }
}

Write-Host "Done." -ForegroundColor Green

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBwxPlQ1i7Zo5Nw
# 3tuqihAKL5Aapzz/fV5Wcf9ffB7YY6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg8Da81rUp09ZuITSbLZnOJCdV1RW6bMRQ
# Se5vr0g7ZhkwDQYJKoZIhvcNAQEBBQAEggIAC8GJ1it2AZcOc7BhzhgvvT9876VA
# t2YHUdy0SZJTCJ5sng0Ca+lWUtMGGEx1G0rmJzTU9wBDNhQKW8R+b/os6MtAgUOT
# dHXIgLq+RbzfdKg8xoufSgxO71tTh/rwoFBLcqWm0LKX33i7Qo/gBnywCGgZzZfE
# mgsPDhfuu/lNVIUAhcRwMex2uvFwq6R578IRPEvzN0vgyb+lQNiyNdK1G0FBG6Q1
# WDtZKyP7LJCDeCNvO8iQtVNJA3tx8zZxO425Tdx8D9GS0k6VNalwS87rPthWJAoY
# EsbJvKG7rKm+vYzrOa5/rGR/oQvedRdecF4UTvF3DLRtMaalkQ5aEhMEEMpc16/v
# H1PYyHv3nYPUq+Pxm2u/+HeWLUnTR16Uf6Dv1MnVV+4UzLcEsLeEwgRqjf2nzuUB
# o8iiwwVQ0IslQWBl7mlsV2cZoReemQlAM/mA7MARCopEjmHzT/lHr3EFIN7nG2ek
# 7S+FB/w39S+CuZ69x+oNACZUXMSP19DILeLBzpnZvgWhdhcyADidnPGuTJQCqf63
# D7UAM5zBt/g836CrWMcaUfmCJLrDlMFS8XHaTtenxUKnTmdBoHhAyt3CF+Qy9KwH
# wumMv4fEnaOuSJy82Ww4XakMhO0lKoeXj/im8G1D3oORukqyFlO51JLcnXV12HZW
# KNIRK0w8UJwYduQ=
# SIG # End signature block
