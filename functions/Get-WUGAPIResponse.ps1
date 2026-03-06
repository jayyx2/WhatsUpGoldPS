<#
    .SYNOPSIS
    Sends an HTTP request to the WhatsUp Gold REST API endpoint and returns the response, handling authentication token refresh as needed.

    .DESCRIPTION
    The `Get-WUGAPIResponse` function sends an HTTP request to the specified WhatsUp Gold REST API endpoint using the specified HTTP method.
    It automatically handles authentication token expiration by refreshing the token if necessary before making the API call.
    The function returns the response from the REST API.

    This function relies on global variables and functions (`$global:WUGBearerHeaders`, `$global:WhatsUpServerBaseURI`, and `Connect-WUGServer`) to manage authentication and connection details.

    .PARAMETER Uri
    The full URI of the WhatsUp Gold REST API endpoint to connect to.

    .PARAMETER Method
    The HTTP method to use when connecting to the REST API endpoint.
    Valid options are: GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH.

    .PARAMETER Body
    The request body to include in the REST API request.
    This parameter is used for methods like POST, PUT, and PATCH where a request body is required.

    .PARAMETER RefreshMinutes
    The number of minutes before token expiration to attempt a token refresh.
    If the authentication token is set to expire within this timeframe, the function will refresh it before making the API call.
    Default is 5 minutes.

    .EXAMPLE
    # Example 1: Send a GET request to retrieve information about the API
    Get-WUGAPIResponse -Uri "https://192.168.1.212:9644/api/v1/product/api" -Method GET

    .NOTES
    *** This function should be used within all other functions when making API calls
    Author: Jason Alberino (jason@wug.ninja)
    Created: 2023-03-24
    Last Modified: 2024-09-28

    This function requires prior authentication using `Connect-WUGServer` to set up necessary global variables.
    The function also handles SSL certificate validation based on the `$global:ignoreSSLErrors` flag set in Connect-WUGServer
#>

function Get-WUGAPIResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH')][string] $Method,
        [Parameter()][string] $Body = $null,
        [Parameter()]
        [int] $RefreshMinutes = 5  # Number of minutes before expiry to refresh the token
    )

    begin {
        # Write debug information
        Write-Debug "Starting Get-WUGAPIResponse function"
        Write-Debug "URI: $Uri"
        Write-Debug "Method: $Method"
        Write-Debug "Body: $Body"

        # Global variables error checking
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            Connect-WUGServer
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Running Connect-WUGServer."
            Connect-WUGServer
        }

        # Ignore SSL errors if flag is present
        if ($global:ignoreSSLErrors) {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $Script:PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
                $Script:PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
            }
            else {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
            Write-Verbose "Ignoring SSL certificate validation errors."
        }

        # Check if the token is within specified minutes of expiry and refresh if necessary
        if ((Get-Date).AddMinutes($RefreshMinutes) -ge $global:expiry) {
            Write-Verbose "Token is about to expire or has expired. Refreshing token."
            $refreshTokenUri = "$($global:tokenUri)"
            $refreshTokenHeaders = @{ "Content-Type" = "application/json" }
            $refreshTokenBody = "grant_type=refresh_token&refresh_token=$($global:WUGRefreshToken)"

            try {
                $newToken = Invoke-RestMethod -Uri $refreshTokenUri -Method Post -Headers $refreshTokenHeaders -Body $refreshTokenBody -ErrorAction Stop

                # Update global variables with the new token information
                $global:WUGBearerHeaders = @{
                    "Content-Type"  = "application/json"
                    "Authorization" = "$($newToken.token_type) $($newToken.access_token)"
                }
                $global:WUGRefreshToken = $newToken.refresh_token
                $global:expiry = (Get-Date).AddSeconds($newToken.expires_in)

                Write-Output "Refreshed authorization token which now expires at $($global:expiry.ToUniversalTime()) UTC."
            }
            catch {
                $errorMessage = "Error refreshing token: $($_.Exception.Message)`nURI: $refreshTokenUri"
                Write-Error -Message $errorMessage
                throw $errorMessage
            }
        }
        else {
            Write-Verbose "Token is valid. Expires at $($global:expiry.ToUniversalTime()) UTC."
        }
    }

    process {
        $retryCount = 0
        $maxRetries = 1  # Number of retries after token refresh

        do {
            try {
                Write-Debug "Attempting to invoke REST method. Retry attempt: $retryCount"
                if (-not $Body) {
                    $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $global:WUGBearerHeaders -ErrorAction Stop
                    Write-Debug "Invoked REST Method without body."
                }
                else {
                    $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $global:WUGBearerHeaders -Body $Body -ErrorAction Stop
                    Write-Debug "Invoked REST Method with body."
                }
                Write-Debug "Response received: $response"
                break  # Exit loop if successful
            }
            catch [System.Net.WebException] {
                $webResponse = $_.Exception.Response
                if ($null -ne $webResponse) {
                    $statusCode = [int]$webResponse.StatusCode
                    $statusDescription = $webResponse.StatusDescription

                    # Read the response body
                    $stream = $webResponse.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    $errorMessage = "HTTP Error $statusCode ($statusDescription): $responseBody`nURI: $Uri`nMethod: $Method`nBody: $Body"
                    Write-Error $errorMessage

                    if ($statusCode -eq 401 -and $retryCount -lt $maxRetries) {
                        Write-Verbose "Received 401 Unauthorized. Attempting to refresh the auth token and retry."
                        # Refresh the auth token immediately
                        try {
                            # Refresh the token without delay
                            $refreshTokenUri = "$($global:tokenUri)"
                            $refreshTokenHeaders = @{ "Content-Type" = "application/json" }
                            $refreshTokenBody = "grant_type=refresh_token&refresh_token=$($global:WUGRefreshToken)"

                            $newToken = Invoke-RestMethod -Uri $refreshTokenUri -Method Post -Headers $refreshTokenHeaders -Body $refreshTokenBody -ErrorAction Stop

                            # Update global variables with the new token information
                            $global:WUGBearerHeaders = @{
                                "Content-Type"  = "application/json"
                                "Authorization" = "$($newToken.token_type) $($newToken.access_token)"
                            }
                            $global:WUGRefreshToken = $newToken.refresh_token
                            $global:expiry = (Get-Date).AddSeconds($newToken.expires_in)

                            Write-Output "Refreshed authorization token which now expires at $($global:expiry.ToUniversalTime()) UTC."
                            # Update retry count and continue
                            $retryCount++
                            continue  # Retry the request
                        }
                        catch {
                            $refreshError = "Error refreshing token after 401 Unauthorized: $($_.Exception.Message)`nURI: $refreshTokenUri"
                            Write-Error -Message $refreshError
                            throw $refreshError
                        }
                    }
                    else {
                        # Other HTTP errors
                        throw $errorMessage
                    }
                }
                else {
                    # No response from server
                    $errorMessage = "Network error: $($_.Exception.Message)`nURI: $Uri`nMethod: $Method`nBody: $Body"
                    Write-Error $errorMessage
                    throw $errorMessage
                }
            }
            catch {
                # Other exceptions
                $errorMessage = "Error: $($_.Exception.Message)`nURI: $Uri`nMethod: $Method`nBody: $Body"
                Write-Error $errorMessage
                throw $errorMessage
            }
        } while ($retryCount -le $maxRetries)
    }

    end {
        Write-Debug "Completed Get-WUGAPIResponse function"
        Write-Output $response
    }
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAonMx7+xQ8L6lH
# U8EZFaVUNn7+Bx9YsNyTdLaQB2qyeKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgJYdf5OWTSyaN+cNJNUFwjjicf1ZcpeQV
# Liej/p6PgeAwDQYJKoZIhvcNAQEBBQAEggIAWar6+nZHDgChbTwIoCok2kII2QwS
# DRz4S1TZ4k4MbOmca7hhsTdjvF5PHcVu93z8bfMwy3Y1fAlLi3tDMnc86diJ/WCs
# EoHd6kxRZwY58Vk9smzkPlAywKM5AQeaikufb+zXH9KLRoM/S633yAu1PN6VE5l2
# NyYNnZuNOUTnC4aGSTmXGQ/K1TYYrKY2SvdbF0LT/WqOfuArlDFa7S87BB1QVGaO
# b9Qp6UiAnnJPy3zgT6L0fq5qGMhVWqZbUSw/Xbf+jcT0KYpNnRvk/Sr24lcNGWLY
# 1BFZewVv6vygbKGoBAUnCasHXdbLnXvK9dyRVjd86EonSJSBzuN7UXu23fr2ODKO
# nUjEOVt8ksO15Trmr7YlV0a5oVg0wC2ZPDKMyAwfpTNQWnc8nii+dB6J06hnKigX
# rMNpDsQC0cSfG1x+ffvTr21Hm8DogWw0MuQPypspC6Ll5q+1hPA+IG4zyEZt0Xq/
# 50E4ODB0TgxAMx5sLUBj5EtEndvjGFU6uKjKUmBPfHTPRtc5WCWjs8Bmi1UVFiDU
# oRi+sO3xSPCtCoy//jSpUbSbnLrntkhWP36Nc8BQwPlXOu5Mgrty6sxeP4GkQDWd
# 4t7/yU2aRM8mcpxx1ZwicuLdC7ZhPbEAUXGp/mZkCTCZueP9UqGxeJiRTh83Oa+n
# 1xhildqXwJ0NqSw=
# SIG # End signature block
