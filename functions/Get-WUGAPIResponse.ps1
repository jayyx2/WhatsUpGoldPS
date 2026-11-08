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

    .PARAMETER MaxRetries
    The number of times to retry a request that fails for a transient reason, such as a dropped
    connection or an HTTP 408/429/500/502/503/504 response. Retries use exponential backoff
    (2, 4, 8... seconds, capped at 30). Set to 0 to disable retries. Default is 3.

    .EXAMPLE
    # Example 1: Send a GET request to retrieve information about the API
    Get-WUGAPIResponse -Uri "https://192.168.1.212:9644/api/v1/product/api" -Method GET

    .NOTES
    *** This function should be used within all other functions when making API calls
    Author: Jason Alberino (jason@wug.ninja)
    Created: 2023-03-24
    Last Modified: 2026-09-30

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
        [int] $RefreshMinutes = 5,  # Number of minutes before expiry to refresh the token
        [Parameter()]
        [ValidateRange(0, 10)]
        [int] $MaxRetries = 3  # Retries for transient network/HTTP failures
    )

    begin {
        # Write debug information
        Write-Debug "Starting Get-WUGAPIResponse function"
        Write-Debug "URI: $Uri"
        Write-Debug "Method: $Method"
        Write-Debug "Body length: $(if ($Body) { $Body.Length } else { 0 }) chars"

        # Global variables error checking
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            Connect-WUGServer
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Running Connect-WUGServer."
            Connect-WUGServer
        }

        # Ignore SSL errors if flag is present (reuse the hostname-scoped callback set by Connect-WUGServer)
        if ($global:ignoreSSLErrors) {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                if ($null -eq $PSDefaultParameterValues) { $PSDefaultParameterValues = @{} }
                else { $PSDefaultParameterValues = $PSDefaultParameterValues.Clone() }
                $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
                $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
            }
            elseif (-not [System.Net.ServicePointManager]::ServerCertificateValidationCallback) {
                # Re-apply the hostname-scoped callback if it was cleared (e.g. by another module)
                if ($global:_WUGAllowedSSLHosts) {
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
                        param($sender, $certificate, $chain, $sslPolicyErrors)
                        if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
                        if ($sender -is [System.Net.HttpWebRequest]) {
                            $reqHost = ([System.Uri]$sender.RequestUri).Host.ToLower()
                            if ($global:_WUGAllowedSSLHosts -contains $reqHost) { return $true }
                        }
                        return $false
                    }
                }
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

                Write-Verbose "Refreshed authorization token. Expires at $($global:expiry.ToUniversalTime()) UTC."
            }
            catch {
                throw "Error refreshing token: $($_.Exception.Message)"
            }
        }
        else {
            Write-Verbose "Token is valid. Expires at $($global:expiry.ToUniversalTime()) UTC."
        }
    }

    process {
        $authRetryCount = 0
        $maxAuthRetries = 1  # Number of retries after token refresh
        $transientRetryCount = 0
        # A dropped send surfaces as a WebException with no response at all, so it is retried too.
        $transientStatusCodes = @(408, 429, 500, 502, 503, 504)

        do {
            try {
                Write-Debug "Attempting to invoke REST method. Auth retries: $authRetryCount, transient retries: $transientRetryCount"
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

                    $errorMessage = "HTTP Error $statusCode ($statusDescription): $responseBody`nURI: $Uri`nMethod: $Method"

                    if ($statusCode -eq 401 -and $authRetryCount -lt $maxAuthRetries) {
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

                            Write-Verbose "Refreshed authorization token. Expires at $($global:expiry.ToUniversalTime()) UTC."
                            # Update retry count and continue
                            $authRetryCount++
                            continue  # Retry the request
                        }
                        catch {
                            throw "Error refreshing token after 401 Unauthorized: $($_.Exception.Message)"
                        }
                    }

                    if ($transientStatusCodes -contains $statusCode -and $transientRetryCount -lt $MaxRetries) {
                        $transientRetryCount++
                        $delaySeconds = [int][Math]::Min(30, [Math]::Pow(2, $transientRetryCount))
                        Write-Verbose "HTTP $statusCode from $Uri. Retry $transientRetryCount of $MaxRetries in $delaySeconds second(s)."
                        Start-Sleep -Seconds $delaySeconds
                        continue
                    }

                    throw $errorMessage
                }
                else {
                    # No response object means the socket/TLS layer failed before any reply arrived.
                    if ($transientRetryCount -lt $MaxRetries) {
                        $transientRetryCount++
                        $delaySeconds = [int][Math]::Min(30, [Math]::Pow(2, $transientRetryCount))
                        Write-Verbose "Network error calling $Uri ($($_.Exception.Message)). Retry $transientRetryCount of $MaxRetries in $delaySeconds second(s)."
                        Start-Sleep -Seconds $delaySeconds
                        continue
                    }

                    throw "Network error: $($_.Exception.Message)`nURI: $Uri`nMethod: $Method"
                }
            }
            catch {
                # PowerShell 7 raises HttpRequestException rather than WebException for dropped sends.
                $exceptionTypes = $_.Exception.GetType().FullName
                if ($_.Exception.InnerException) { $exceptionTypes += " $($_.Exception.InnerException.GetType().FullName)" }

                if ($exceptionTypes -match 'HttpRequestException|SocketException|IOException|TimeoutException' -and $transientRetryCount -lt $MaxRetries) {
                    $transientRetryCount++
                    $delaySeconds = [int][Math]::Min(30, [Math]::Pow(2, $transientRetryCount))
                    Write-Verbose "Network error calling $Uri ($($_.Exception.Message)). Retry $transientRetryCount of $MaxRetries in $delaySeconds second(s)."
                    Start-Sleep -Seconds $delaySeconds
                    continue
                }

                throw "Error: $($_.Exception.Message)`nURI: $Uri`nMethod: $Method"
            }
        } while ($true)
    }

    end {
        Write-Debug "Completed Get-WUGAPIResponse function"
        return $response
    }
}
# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB92+NPRwVWOmeR
# gt+guOgY/e8OA0F53/nsJUuLT4Lv7qCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCC3
# sxoeUyL/iUrimsv6rWby6bryC1zBlto8r30iYaFTdzANBgkqhkiG9w0BAQEFAASC
# AgDJwD2jOotjExyHhs8I7DOR9sXUd+kucMzCof9pGLxbbZfQDR+wm46j6R5sAo1X
# O8Vf1AtnL8hBX88O8wfA3EgI+EX6C6zgw+Kf26jJ/wUeLMPMxQPOihrnB1yL6MjB
# w5mC5wb+j5pMHYDpJRuWKydGfiL2gOBKd1atbrltpiSPSZepCrVU8/qGsiXTKTNg
# WS6riLETqb73lKvVf9AU9gd6y7/jPZp3dY07MG3umV3kKtvqbILUmmkeLUPAxKW2
# xlT4Y3M4KMajMt7hHJyEyvOGOx9JpUomsCW1fbQZ6rF8o2Lw4MMJKRftOV9C6/6j
# AOUD0k0uaK256WAs2uXywHlo7gm5D6hYrKhJNFuXAHxRsCZXKnAxK46MbtlqsfyF
# IqtPZFixKeMnN2zkZpdO1Eer0/4U4+MLTEO99z86zhtjRx5YcAcUSPylWBChfZQV
# dRrQ4IzD2ZR0Zv732ClMy7c1FJxr2vv4PEX+u2PvQRabNKQdXMa1GX8/dJIb9/Cq
# NPui2toKuQ9zSIttBEfn+CtwUQw6pMPcf0p0pUqo0k3i4C+r9J9CY7aII24E/KXp
# T7w9bLAV71Fk/G3EkrbBfohP0TnFhpSHmkqJyUh5FDS2TeWJdMRv/0N7KKIX+luw
# 7KPrRzhx+jh4X2cKPvvukkhlP6YznHo8GY675a3aTqOFuKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMDM5MDZaMC8GCSqGSIb3DQEJBDEiBCBUCZG9GLCf
# zd3NvMXkF9orJI1OK5SunROKKlvdmE19pDANBgkqhkiG9w0BAQEFAASCAgAfffka
# +8I/sq00tmrUp5KdD+CB/MMpm/dsJTj8rAdEmYoMinrDuLBdJLX63DbIRLGmM9Bu
# MPSd0AP2Kc01qUfR48WcXDcrjhU49qUPRcUm+RPhPk/Pz5e4svk2RrA6x5InihCD
# oEtRCeBR0o5fRVre+xZBPWZHR3g5dmF60G+1Dxp1FbZQ3yhYaQ1uPg+94015f0H7
# IeecDE1LFpXEIRgedbc7ftb7tEh8PLroKLm0aw7Ghpj1xseAHysb7AzRTN1iEuD9
# F/4camEJSuCLvp0yF39Vd9yy4eJ4vIga0j+AgVCZR9c1R/FEeJfwFksCmM47vb0z
# qC9f+6h0E0JOmorigtEIrqxnPCDR+ArYXoATKAJhcD75wf6vwGG0i5GxqVr9MsMU
# czCnLp7ov14P+41sEsrV/nqM4opLz6dU5KFihRLzkzvzDcQSmTQrG8yhdG5tWiwj
# wXmykVAZzKUl+YvXw/O0esmPv59c7BPchuIgl6gSsn/oKPpW+9gqu8y2Z1rb5JPa
# ixXENoFRgNdktX+3fXG0/e4ghyRZuru3FeHJH7kQlOTnmSYNK//DklLcO+6Qn+cU
# JPckW9CcVKEh85MWAXx23EZJevpq8gsqeaAMZgAClzBLXMxllrbXkAWuijj4W6xO
# jhCbTfE/OhJwDFoBpstrrDZ6xa5rhr4IWhTCYA==
# SIG # End signature block
