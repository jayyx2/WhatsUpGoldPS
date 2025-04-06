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
        return $response
    }
}
# SIG # Begin signature block
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAnyobwzKX0/1Fs
# yDbul7wd7lCBAZaeYYeRfbiqbnNIWaCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# L9Uo2bC5a4CH2RwwggZkMIIEzKADAgECAhEA6IUbK/8zRw2NKvPg4jKHsTANBgkq
# hkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1p
# dGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgQ0EgUjM2
# MB4XDTIzMDQxOTAwMDAwMFoXDTI2MDcxODIzNTk1OVowVTELMAkGA1UEBhMCVVMx
# FDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNvbiBBbGJlcmlubzEX
# MBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQC2JA01BehqpO3INejKVsKScaS9sd0Hjoz1tceFig6Yyu2glTKimH9n
# r9l5438Cjpc1x+n42gMfnS5Cza4tZUWr1usOq3d0TljKFOOSW8Uve1J+PC0f/Hxp
# DbI8hE38ICDmgv8EozBOgo4lPm/rDHVTHgiRZvy1H8gPTuE13ck2sevVslku2E2F
# 8wst5Kb12OqngF96RXptEeM0iTipPhfNinWCa8e58+mbt1dHCbX46593DRd3yQv+
# rvPkIh9QkMGmumfjV5lv1S3iqf/Vg6XP9R3lTPMWNO2IEzIjk12t817rU3xYyf2Q
# 4dlA/i1bRpFfjEVcxQiZJdQKnQlqd3hOk0tr8bxTI3RZxgOLRgC8mA9hgcnJmreM
# WP4CwXZUKKX13pMqzrX/qiSUsB+Mvcn7LHGEo9pJIBgMItZW4zn4uPzGbf53EQUW
# nPfUOSBdgkRAdkb/c7Lkhhc1HNPWlUqzS/tdopI7+TzNsYr7qEckXpumBlUSONoJ
# n2V1zukFbgsBq0mRWSZf+ut3OVGo7zSYopsMXSIPFEaBcxNuvcZQXv6YdXEsDpvG
# mysbgVa/7uP3KwH9h79WeFU/TiGEISH5B59qTg26+GMRqhyZoYHj7wI36omwSNja
# tUo5cYz4AEYTO58gceMcztNO45BynLwPbZwZ0bxPN2wL1ruIYd+ewQIDAQABo4IB
# rjCCAaowHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhekzQwwHQYDVR0OBBYE
# FJHuVIzRubayI0tfw82Q7Q/47iu9MA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8E
# AjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEwNQYMKwYBBAGyMQEC
# AQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeB
# DAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNlY3RpZ28uY29tL1Nl
# Y3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5BggrBgEFBQcBAQRtMGsw
# RAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1Ymxp
# Y0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5z
# ZWN0aWdvLmNvbTAjBgNVHREEHDAagRhqYXNvbi5hbGJlcmlub0BnbWFpbC5jb20w
# DQYJKoZIhvcNAQEMBQADggGBAET0EFH0r+hqoQWr4Ha9UDuEv28rTgV2aao1nFRg
# GZ/5owM7x9lxappLUbgQFfeIzzAsp3gwTKMYf47njUjvOBZD9zV/3I/vaLmY2enm
# MXZ48Om9GW4pNmnvsef2Ub1/+dRzgs8UFX5wBJcfy4OWP3t0OaKJkn+ZltgFF1cu
# L/RPiWSRcZuhh7dIWgoPQrVx8BtC8pkh4F5ECxogQnlaDNBzGYf1UYNfEQOFec31
# UK8oENwWx5/EaKFrSi9Y4tu6rkpH0idmYds/1fvqApGxujhvCO4Se8Atfc98icX4
# DWkc1QILREHiVinmoO3smmjB5wumgP45p9OVJXhI0D0gUFQfOSappa5eO2lbnNVG
# 90rCsADmVpDDmNt2qPG01luBbX6VtWMP2thjP5/CWvUy6+xfrhlqvwZyZt3SKtuf
# FWkqnNWMnmgtBNSmBF5+q8w5SJW+24qrncKJWSIim/nRtC11XnoI9SXlaucS3Nlb
# crQVicXOtbhksEqMTn52i8NOfzGCAxswggMXAgEBMGkwVDELMAkGA1UEBhMCR0Ix
# GDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJs
# aWMgQ29kZSBTaWduaW5nIENBIFIzNgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJYIZI
# AWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAv
# BgkqhkiG9w0BCQQxIgQg+IxH6R00tIUhgONysvoOYtG3QBs9uI9XRRxOAYLXGEYw
# DQYJKoZIhvcNAQEBBQAEggIAKExMUvSjKqTqkPOlGZgFU0dzjKgXGll2XrYcAUdI
# glnQBmzrI87z/7XK16+d1LjfIfC5yI5hDtkg4yioBDKA0d4BlgAI1Qqlqd9RKEzW
# O+SPdKcQM4m5fWXdDSTNnUXp+BKD5cWBgK8HHSvCP+FVSEoYJN683nhuL6cROOhR
# J0DghvXAPb+a5mKMt8RCJrN+/HBOY3SgB1bfgRsYiLEpe4SNNDUK6zBkZ7HDVeU4
# 8b4t57y3Z3t3tRfkwMrxfRAPZ1dwyZUxzFzaOrKk42350VHNKLPKtrqtkuso2K8c
# +ejgGXIssS/jQgcJzk/nrMq1PgBk69+XQJPUqijMy3/q5SNxMfRHEt3eCT2PN6N5
# xuDO7F5N7fvQnnA3C9MxfHhQBn/+7J9/ymoeZpnb+ftc+7uf0deQT9mrBDdN953V
# duH9ljRDX2FGnMNZ5L8h28f0AesgjM+bHGQAGP4UUubaXGG7OTQn2ujKxMnq4r+3
# E2XvBqpKA5L6QjT1kOql60hMrdLz3Z1KLAVNkFFV4vzueVLZa/LvfETvwYCKwJfk
# yBU/MFi0tVFQaZwHW3aRxIQ9+Vn8ESUzdGDcJ+aGfC1RSRFSU4yuhOpo+Vpq0jZ5
# Yk20yHYdGLYd60icrezH2qWRGgLmq6CmkhjOH1uv98ESaG2CoEJhi4jsEpWW+xjr
# k1o=
# SIG # End signature block
