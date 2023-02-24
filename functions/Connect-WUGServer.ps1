<#
.SYNOPSIS
    Connect to a WhatsUp Gold server to obtain an authorization token to
     use for REST API requests

.DESCRIPTION
    Obtains a WhatsUp Gold REST API authorization token

.PARAMETER serverUri
    The IP address or fully-qualified domain name of the WhatsUp Gold server.

.PARAMETER Protocol
    Specify whether to use HTTP or HTTPS. HTTP is default.

.PARAMETER Username
    Plaintext username used to connect to the WhatsUp Gold Server
    INSECURE, USE AT YOUR OWN RISK! Use -Credential instead!

.PARAMETER Password
    Plaintext password used to connect to the WhatsUp Gold Server
    INSECURE, USE AT YOUR OWN RISK! Use -Credential instead!

.PARAMETER Credential
    Accepts a PowerShell credential object. Set your credential first.
    For example: $Credential = Get-Credential

.NOTES
    WhatsUp Gold REST API Handling Session Tokens
    https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#section/Handling-Session-Tokens

.EXAMPLE
    Connect-WUGServer
    Connect-WUGServer -serverUri 192.168.1.212 -Credential $Credential -Protocol https
    Connect-WUGServer -serverUri 192.168.1.212 -Username "admin"
    Connect-WUGServer -serverUri 192.168.1.212 -Username "admin" -Password "Password"
    Connect-WUGServer -server 192.168.1.212 -Username user -Password pass -Protocol https
#>
function Connect-WUGServer {
    param (
        [Parameter(Mandatory)] [string] $serverUri,
        [Parameter(Mandatory = $false)] [ValidateSet("http", "https")] [string] $Protocol = "http",
        [Parameter()] [string] $Username,
        [Parameter()] [string] $Password,
        [System.Management.Automation.Credential()]
        [PSCredential]
        $Credential = $null
    )
    $global:WhatsUpServerBaseURI = "${protocol}://${serverUri}:9644"

    if ($Credential) {
        $Username = $Credential.GetNetworkCredential().UserName
        $Password = $Credential.GetNetworkCredential().Password
    }

    if ($Password -and -not $Username) {
        $Username = Read-Host "Username is required. Username?"
        $Password = $Password
    }

    if ($Username -and -not $Password) {
        $Credential = Get-Credential -UserName $Username
        $Password = $Credential.GetNetworkCredential().Password
    }

    if (-not $Username -and -not $Credential) {
        $Credential = Get-Credential
        $Username = $Credential.GetNetworkCredential().UserName
        $Password = $Credential.GetNetworkCredential().Password
    }

    $tokenUri = "${global:WhatsUpServerBaseURI}/api/v1/token"
    $tokenHeaders = @{"Content-Type" = "application/json" }
    $tokenBody = "grant_type=password&username=${Username}&password=${Password}"

    try {
        $token = Invoke-RestMethod -Uri $tokenUri -Method Post -Headers $tokenHeaders -Body $tokenBody -SkipCertificateCheck
    }
    catch {
        $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $tokenUri"
        Write-Error -message $message
        throw
    }

    $global:WUGBearerHeaders = @{
        "Content-Type"  = "application/json"
        "Authorization" = "$($token.token_type) $($token.access_token)"
    }

    $global:expiry = (Get-Date).AddSeconds($token.expires_in)
    return "Connected to ${serverUri} to obtain authorization token for user `"${Username}`" which expires at $global:expiry UTC."
}