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
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUwrdzeS+2Eguo/em8AfunWHBV
# EFegghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIGGjCCBAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG
# 9w0BAQwFADBWMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk
# MS0wKwYDVQQDEyRTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYw
# HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1Ymxp
# YyBDb2RlIFNpZ25pbmcgQ0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIB
# igKCAYEAmyudU/o1P45gBkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxD
# eEDIArCS2VCoVk4Y/8j6stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk
# 9vT0k2oWJMJjL9G//N523hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7Xw
# iunD7mBxNtecM6ytIdUlh08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ
# 0arWZVeffvMr/iiIROSCzKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZX
# nYvZQgWx/SXiJDRSAolRzZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+t
# AfiWu01TPhCr9VrkxsHC5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvr
# n35XGf2RPaNTO2uSZ6n9otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn
# 3UayWW9bAgMBAAGjggFkMIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaR
# XBeF5jAdBgNVHQ4EFgQUDyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYD
# VR0gBBQwEjAGBgRVHSAAMAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRw
# Oi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RS
# NDYuY3JsMHsGCCsGAQUFBwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAj
# BggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEM
# BQADggIBAAb/guF3YzZue6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXK
# ZDk8+Y1LoNqHrp22AKMGxQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWk
# vfPkKaAQsiqaT9DnMWBHVNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3d
# MapandPfYgoZ8iDL2OR3sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwF
# kvjFV3jS49ZSc4lShKK6BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZa
# PATHvNIzt+z1PHo35D/f7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8b
# kinLrYrKpii+Tk7pwL7TjRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7Ew
# oIJB0kak6pSzEu4I64U6gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TW
# SenLbjBQUGR96cFr6lEUfAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg
# 51Tbnio1lB93079WPFnYaOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoU
# KD85gnJ+t0smrWrb8dee2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGZDCCBMyg
# AwIBAgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJKoZIhvcNAQEMBQAwVDELMAkGA1UE
# BhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGln
# byBQdWJsaWMgQ29kZSBTaWduaW5nIENBIFIzNjAeFw0yMzA0MTkwMDAwMDBaFw0y
# NjA3MTgyMzU5NTlaMFUxCzAJBgNVBAYTAlVTMRQwEgYDVQQIDAtDb25uZWN0aWN1
# dDEXMBUGA1UECgwOSmFzb24gQWxiZXJpbm8xFzAVBgNVBAMMDkphc29uIEFsYmVy
# aW5vMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtiQNNQXoaqTtyDXo
# ylbCknGkvbHdB46M9bXHhYoOmMrtoJUyoph/Z6/ZeeN/Ao6XNcfp+NoDH50uQs2u
# LWVFq9brDqt3dE5YyhTjklvFL3tSfjwtH/x8aQ2yPIRN/CAg5oL/BKMwToKOJT5v
# 6wx1Ux4IkWb8tR/ID07hNd3JNrHr1bJZLthNhfMLLeSm9djqp4BfekV6bRHjNIk4
# qT4XzYp1gmvHufPpm7dXRwm1+Oufdw0Xd8kL/q7z5CIfUJDBprpn41eZb9Ut4qn/
# 1YOlz/Ud5UzzFjTtiBMyI5NdrfNe61N8WMn9kOHZQP4tW0aRX4xFXMUImSXUCp0J
# and4TpNLa/G8UyN0WcYDi0YAvJgPYYHJyZq3jFj+AsF2VCil9d6TKs61/6oklLAf
# jL3J+yxxhKPaSSAYDCLWVuM5+Lj8xm3+dxEFFpz31DkgXYJEQHZG/3Oy5IYXNRzT
# 1pVKs0v7XaKSO/k8zbGK+6hHJF6bpgZVEjjaCZ9ldc7pBW4LAatJkVkmX/rrdzlR
# qO80mKKbDF0iDxRGgXMTbr3GUF7+mHVxLA6bxpsrG4FWv+7j9ysB/Ye/VnhVP04h
# hCEh+Qefak4NuvhjEaocmaGB4+8CN+qJsEjY2rVKOXGM+ABGEzufIHHjHM7TTuOQ
# cpy8D22cGdG8TzdsC9a7iGHfnsECAwEAAaOCAa4wggGqMB8GA1UdIwQYMBaAFA8q
# yyCHKLjsb0iuK1SmKaoXpM0MMB0GA1UdDgQWBBSR7lSM0bm2siNLX8PNkO0P+O4r
# vTAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEF
# BQcDAzBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDAjAlMCMGCCsGAQUFBwIBFhdo
# dHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAEwSQYDVR0fBEIwQDA+oDyg
# OoY4aHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25p
# bmdDQVIzNi5jcmwweQYIKwYBBQUHAQEEbTBrMEQGCCsGAQUFBzAChjhodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNy
# dDAjBggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wIwYDVR0RBBww
# GoEYamFzb24uYWxiZXJpbm9AZ21haWwuY29tMA0GCSqGSIb3DQEBDAUAA4IBgQBE
# 9BBR9K/oaqEFq+B2vVA7hL9vK04FdmmqNZxUYBmf+aMDO8fZcWqaS1G4EBX3iM8w
# LKd4MEyjGH+O541I7zgWQ/c1f9yP72i5mNnp5jF2ePDpvRluKTZp77Hn9lG9f/nU
# c4LPFBV+cASXH8uDlj97dDmiiZJ/mZbYBRdXLi/0T4lkkXGboYe3SFoKD0K1cfAb
# QvKZIeBeRAsaIEJ5WgzQcxmH9VGDXxEDhXnN9VCvKBDcFsefxGiha0ovWOLbuq5K
# R9InZmHbP9X76gKRsbo4bwjuEnvALX3PfInF+A1pHNUCC0RB4lYp5qDt7JpowecL
# poD+OafTlSV4SNA9IFBUHzkmqaWuXjtpW5zVRvdKwrAA5laQw5jbdqjxtNZbgW1+
# lbVjD9rYYz+fwlr1MuvsX64Zar8Gcmbd0irbnxVpKpzVjJ5oLQTUpgRefqvMOUiV
# vtuKq53CiVkiIpv50bQtdV56CPUl5WrnEtzZW3K0FYnFzrW4ZLBKjE5+dovDTn8x
# ggMCMIIC/gIBATBpMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBS
# MzYCEQDohRsr/zNHDY0q8+DiMoexMAkGBSsOAwIaBQCgcDAQBgorBgEEAYI3AgEM
# MQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUizlgmyeEz1aPWrtq0k8QrP1H
# cPowDQYJKoZIhvcNAQEBBQAEggIAhnEtQmgYgWzGXgBcqpMpXBjOXT1i1MVKhjfO
# u7t315ggWo4gEyUpCMRj3EiVx/nc9smXPYoZSRlTYWMvxHt5oIL7SFYMQJFsVAgB
# zoCbvchDQSMTRbSrVxStOuAxXgiLi29JMny3v6b7mCigvSyYy4pG8rFsGPueTv/E
# 9mexqBjbQz3KV2EPXdoTRGIPKibJWc25m6gqZwAFFfsIsXhjppacLqiNnWlljnNF
# mvWYluUiPsjGAlag136FogC/jFZCZBdEVcGOvBsJkgqpTypCi/u7cdAuacgf8dj5
# 8ce0w2mQjJHe3aeBROpqGM4nunNb6Q2Uk4z9Mxw6wTyEt2yXaJe6JB/bVb+0kz8j
# 4cRfHpqi7Q9bqszCDTTREB8vDWA1nQRfjcF5nkgIAVZL4DKlwx702TwnbiQi2oE8
# uEoRCTpDXdEPNyIjmWhn6V1CdhGcJirvlAGYigW4q9VvUWeJB+MjTB/LaeWuIPgn
# PVUXgZSCbVBGKYf98nxbAqAOz0NidWy9/jZ1Mzo3R6bR3v/dGIUEp+pghQNa35gh
# JGBPaqf/F52SmTC8EVu2prBqyLGSlqLFpVc/vh9EAchHQaIAFV+4OJkBzN9daZSs
# we5+mSclXThN2xV2XwjuVF74PVLd3aat1XfnaxQQHHRjv0cC5/g+P4v3jNjW7dem
# 0TiIG44=
# SIG # End signature block
