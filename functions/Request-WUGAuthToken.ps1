<#
.SYNOPSIS
Requests a new authorization token for the WhatsUp Gold API if the current token is within a specified threshold of expiration.

.DESCRIPTION
The Request-WUGAuthToken function is used to request a new authorization token from the WhatsUp Gold API when the current token is within a specified threshold of expiration. The default threshold is set to 5 minutes. The function refreshes the token by sending a request to the token URI with the refresh token, updating the global variables for the authorization headers, refresh token, and token expiration time accordingly.

.PARAMETER RefreshMinutes
Specifies the threshold, in minutes, before the token expiration time, at which the function should request a new authorization token. The default value is 5 minutes.

.EXAMPLE
Request-WUGAuthToken

This example demonstrates calling the Request-WUGAuthToken function to check and refresh the authorization token if necessary.

.EXAMPLE
Request-WUGAuthToken -RefreshMinutes 10

This example demonstrates calling the Request-WUGAuthToken function with a custom threshold of 10 minutes before the token expiration time to check and refresh the authorization token if necessary.

.NOTES
Author: Jason Alberino (jason@wug.ninja) 2023-03-24
Last modified: Let's see your name here YYYY-MM-DD

#>
function Request-WUGAuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$RefreshMinutes = 5
    )
    # Check if the token is within 5 minutes of expiry
    if ((Get-Date).AddMinutes($RefreshMinutes) -ge $global:expiry) {
        $refreshTokenUri = "${global:tokenUri}"
        $refreshTokenHeaders = @{"Content-Type" = "application/json" }
        $refreshTokenBody = "grant_type=refresh_token&refresh_token=$global:WUGRefreshToken"

        try {
            $newToken = Invoke-RestMethod -Uri $refreshTokenUri -Method Post -Headers $refreshTokenHeaders -Body $refreshTokenBody
        }
        catch {
            $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $refreshTokenUri"
            Write-Error -message $message
            throw
        }
        $global:WUGBearerHeaders = @{
            "Content-Type"  = "application/json"
            "Authorization" = "$($newToken.token_type) $($newToken.access_token)"
        }
        # Update the refresh_token
        $global:WUGRefreshToken = $newToken.refresh_token
        #Update expiry
        $global:expiry = (Get-Date).AddSeconds($newToken.expires_in)
        $message = "Refreshed authorization token which now expires at ${global:expiry} UTC."
        Write-Output $message -NoEnumerate
        return
    } else {
        Write-Debug "We don't need to refresh yet, token expires ${global:expiry}"
    }
}