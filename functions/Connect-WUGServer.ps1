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

.PARAMETER TokenEndpoint
    Specifies the endpoint for the token request. The default value is "/api/v1/token".

.PARAMETER Port
    Specifies the port number used to connect to the WhatsUp Gold server. The default value is "9644".

.PARAMETER IgnoreSSLErrors
    If this switch is present, SSL certificate validation errors will be ignored when making requests to the WhatsUp Gold server. This is useful when connecting to servers with self-signed certificates or other certificate issues.

.NOTES
    WhatsUp Gold REST API Handling Session Tokens
    https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#section/Handling-Session-Tokens

.EXAMPLE
    Connect-WUGServer
    Connect-WUGServer -serverUri 192.168.1.212 -Credential $Credential -Protocol https
    Connect-WUGServer -serverUri 192.168.1.212 -Username "admin"
    Connect-WUGServer -serverUri 192.168.1.212 -Username "admin" -Password "Password"
    Connect-WUGServer -serverUri 192.168.1.212 -Username user -Password pass -Protocol https
#>
function Connect-WUGServer {
    param (
        [Parameter(Mandatory)] [string] $serverUri,
        [Parameter(Mandatory = $false)] [ValidateSet("http", "https")] [string] $Protocol = "http",
        [Parameter()] [string] $Username,
        [Parameter()] [string] $Password,
        [System.Management.Automation.Credential()]
        [PSCredential]
        $Credential = $null,
        [switch] $IgnoreSSLErrors,
        [string] $TokenEndpoint = "/api/v1/token",
        [int32] $Port = "9644"
    )

    $global:WhatsUpServerBaseURI = "${protocol}://${serverUri}:${Port}"

    #Input validation
    if ($Credential) {$Username = $Credential.GetNetworkCredential().UserName; $Password = $Credential.GetNetworkCredential().Password;}
    elseif ($Username -and -not $Password) {$Username = $Username; $Password = (Get-Credential -UserName $Username -Message "Enter password for ${Username}").GetNetworkCredential().Password;}
    elseif ($Password -and -not $Username) {$Username = Read-Host "Enter the username associated with the password."; $Password = $Password;}
    elseif (!$Credential) {$Credential = Get-Credential; $Username = $Credential.GetNetworkCredential().UserName; $Password = $Credential.GetNetworkCredential().Password;}
    if ($Protocol -match "https") {
        # Set SSL validation callback if the IgnoreSSLErrors switch is present
        if ($IgnoreSSLErrors) {
            add-type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                    return true;
                }
            }
"@
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }
    }
    #input validation

    #Set the token URI
    $tokenUri = "${global:WhatsUpServerBaseURI}${TokenEndpoint}"
    #Set the required header(s)
    $tokenHeaders = @{"Content-Type" = "application/json" }
    #Set the required body for the token request
    $tokenBody = "grant_type=password&username=${Username}&password=${Password}"
    #Attempt to connect
    try {
        $token = Invoke-RestMethod -Uri $tokenUri -Method Post -Headers $tokenHeaders -Body $tokenBody
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