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
        [Parameter(Mandatory = $true)] [string] $serverUri,
        [Parameter(Mandatory = $false)] [ValidateSet("http", "https", ErrorMessage = "Protocol must be http or https")] [string] $Protocol = "http",
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Username,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Password,
        [System.Management.Automation.Credential()][PSCredential]$Credential = $null,
        [Parameter()] [ValidateNotNullOrEmpty()][ValidatePattern("^(/[a-zA-Z0-9]+)+/?$", ErrorMessage = "Please enter a valid token endpoint. Example: /api/v1/token")] [string] $TokenEndpoint = "/api/v1/token",
        [Parameter()] [ValidateRange(1,65535)] [int32] $Port = 9644,
        [switch] $IgnoreSSLErrors
    )

    #Input validation
    # Check if the hostname or IP address is resolvable
    $ip = $null;try {$ip = [System.Net.Dns]::GetHostAddresses($serverUri)} catch {throw "Cannot resolve hostname or IP address. Please enter a valid IP address or hostname.";}
    if ($null -eq $ip) {throw "Cannot resolve hostname or IP address, ${serverUri}. Please enter a resolvable IP address or hostname."}
    # Check if the port is open
    $tcpClient = New-Object System.Net.Sockets.TcpClient;$connectResult = $tcpClient.BeginConnect($ip, $Port, $null, $null);$waitResult = $connectResult.AsyncWaitHandle.WaitOne(500);if (!$waitResult -or !$tcpClient.Connected) {throw "The specified port, ${Port}, is not open or accepting connections."};
    #$tcpClient.EndConnect($connectResult)
    # Check if the credential was input
    if ($Credential) {$Username = $Credential.GetNetworkCredential().UserName; $Password = $Credential.GetNetworkCredential().Password;}
    elseif ($Username -and -not $Password) {$Username = $Username; $Password = (Get-Credential -UserName $Username -Message "Enter password for ${Username}").GetNetworkCredential().Password;}
    elseif ($Password -and -not $Username) {$Username = Read-Host "Enter the username associated with the password."; $Password = $Password;}
    elseif (!$Credential) {$Credential = Get-Credential; $Username = $Credential.GetNetworkCredential().UserName; $Password = $Credential.GetNetworkCredential().Password;}
    # Set SSL validation callback if the IgnoreSSLErrors switch is present
    if ($Protocol -match "https"){
        if ($IgnoreSSLErrors) {
            Write-Warning "You are ignoring SSL certificate validation errors, which can introduce security risks. Use this option with caution.";
        }
    }
    #input validation

    #Set the base URI
    $global:WhatsUpServerBaseURI = "${protocol}://${serverUri}:${Port}"
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