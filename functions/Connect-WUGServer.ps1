<#
.SYNOPSIS
Connects to a WhatsUp Gold (WUG) server and obtains an OAuth 2.0 authorization token.

.DESCRIPTION
The Connect-WUGServer function establishes a connection to a WhatsUp Gold server using the specified parameters,
and obtains an authorization token using the OAuth 2.0 password grant type flow. The function validates the
input parameters and handles credential input, and also allows for ignoring SSL certificate validation errors.
The authorization token is stored in a global variable for subsequent API requests.

.PARAMETER -serverUri
The URI of the WhatsUp Gold server to connect to.

.PARAMETER -Protocol
The protocol to use for the connection (http or https). Default is http.

.PARAMETER -Username
The username to use for authentication. If not provided, the function will prompt for it.

.PARAMETER -Password
The password to use for authentication. If not provided, the function will prompt for it.

.PARAMETER -Credential
A PSCredential object containing the username and password for authentication.

.PARAMETER -TokenEndpoint
The endpoint for obtaining the OAuth 2.0 authorization token. Default is "/api/v1/token".

.PARAMETER -Port
The TCPIP port to use for the connection. Default is 9644.

.PARAMETER -IgnoreSSLErrors
A switch that allows for ignoring SSL certificate validation errors.
...which currently does not work.

.EXAMPLE
Connect-WUGServer -serverUri "whatsup.example.com" -Protocol "https" -Username "admin" -Password "mypassword"
Connects to the WhatsUp Gold server at "https://whatsup.example.com:9644" with the provided credentials, and obtains an
OAuth 2.0 authorization token.

.NOTES
Author: Jason Alberino
Version: 1.0
WhatsUp Gold REST API Handling Session Tokens: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#section/Handling-Session-Tokens

.EXAMPLE
    ###Example 1: Basic usage with prompt for username and password
    Connect-WUGServer -serverUri "wug.example.com"
    Connects to the WUG server at "http://wug.example.com:9644" with prompts for username and password.
    
    ###Example 2: Connection using a PSCredential object
    $Credential = Get-Credential
    Connect-WUGServer -serverUri "wug.example.com" -Credential $Credential -Protocol "https"
    Connects to the WUG server at "https://wug.example.com:9644" using the provided PSCredential object.
    
    ###Example 3: Connection with specified username
    Connect-WUGServer -serverUri "wug.example.com" -Username "admin"
    Connects to the WUG server at "http://wug.example.com:9644" using the specified username, with a prompt for password.
    
    ###Example 4: Connection with specified username and password
    Connect-WUGServer -serverUri "wug.example.com" -Username "admin" -Password "mypassword"
    Connects to the WUG server at "http://wug.example.com:9644" using the specified username and password.
    
    ###Example 5: Connection with custom token endpoint
    Connect-WUGServer -serverUri "wug.example.com" -TokenEndpoint "/api/v2/token"
    Connects to the WUG server at "http://wug.example.com:9644" using the default username and password, but obtains
    the OAuth 2.0 authorization token from the custom endpoint "/api/v2/token".
    
    ###Example 6: Connection with custom port and SSL protocol
    Connect-WUGServer -serverUri "wug.example.com" -Port 8443 -Protocol "https"
    Connects to the WUG server at "https://wug.example.com:8443" using the default username and password,
    with SSL certificate validation enabled.
    
    ###Example 7: Connection with SSL protocol and ignoring SSL errors
    Connect-WUGServer -serverUri "wug.example.com" -Protocol "https" -IgnoreSSLErrors
    Connects to the WUG server at "https://wug.example.com:9644" using the default username and password,
    but ignores SSL certificate validation errors.

#>
function Connect-WUGServer {
    param (
        [Parameter(Mandatory = $true)] [string] $serverUri,
        [Parameter(Mandatory = $false)] [ValidateSet("http", "https")] [string] $Protocol = "http",
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Username,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Password,
        [System.Management.Automation.Credential()][PSCredential]$Credential = $null,
        [Parameter()] [ValidateNotNullOrEmpty()][ValidatePattern("^(/[a-zA-Z0-9]+)+/?$")] [string] $TokenEndpoint = "/api/v1/token",
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