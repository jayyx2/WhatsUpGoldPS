function Get-WUGAuthToken {
    # Check if the token is within 5 minutes of expiry
    if ((Get-Date).AddMinutes(5) -ge $global:expiry) {
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
        return "Refreshed authorization token which now expires at $global:expiry UTC."
    } else {
        #Write-Host "We don't need to refresh yet, token expires ${global:expiry}"
    }
}