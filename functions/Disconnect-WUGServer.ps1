<#
.SYNOPSIS
Disconnects from a WhatsUp Gold (WUG) server and clears global variables set by Connect-WUGServer.

.DESCRIPTION
The Disconnect-WUGServer function disconnects from the WhatsUp Gold server by clearing the global variables
set by the Connect-WUGServer function. This includes the authorization header, token expiration time, base URI,
token URI, and refresh token. Once disconnected, any subsequent API requests will fail until a new connection
is established using Connect-WUGServer.

.EXAMPLE
Disconnect-WUGServer
Disconnects from the connected WhatsUp Gold server and clears the global variables.

.NOTES
Author: Your Name
Version: 1.0

#>

function Disconnect-WUGServer {
    if ($global:WhatsUpServerBaseURI) {
        Write-Host "You've disconnected from $global:WhatsUpServerBaseURI"
    } else {
        Write-Host "No active connection found."
    }

    # Clear global variables
    $global:WUGBearerHeaders = $null
    $global:expiry = $null
    $global:WhatsUpServerBaseURI = $null
    $global:tokenUri = $null
    $global:WUGRefreshToken = $null
}
