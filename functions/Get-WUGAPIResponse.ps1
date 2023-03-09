<#
.SYNOPSIS
Connects to a REST API endpoint by specifying a full URI and an HTTP verb, and returns the response.

.DESCRIPTION
The Get-WUGAPIResponse function sends an HTTP request to the specified REST API endpoint using the specified HTTP verb.
The function returns the response from the REST API.

.PARAMETER Uri
The entire URI of the REST API endpoint to connect to.

.PARAMETER Method
The HTTP verb to use when connecting to the REST API endpoint.
Valid options are: GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH.

.PARAMETER body
The request body to include in the REST API request. This parameter is used for POST, PUT, and PATCH requests.

.EXAMPLE
Get-WUGAPIResponse -Uri "http://192.168.1.212:9644/api/v1/product/api" -Method GET
Sends a GET request to the specified REST API endpoint, and returns the response.

.EXAMPLE
$dataObject = (Get-WUGAPIResponse -Uri "http://192.168.1.212:9644/api/v1/product/api" -Method GET).data
Sends a GET request to the specified REST API endpoint, and assigns the 'data' property of the response to a variable.

.NOTES
Author: Jason Alberino
Version: 1.0

#>
function Get-WUGAPIResponse {
    param(
        [Parameter()] [string] $uri,
        [Parameter()] [ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH')] [string] $Method,
        [Parameter()] [string] $body
    )
    Write-Debug "Function: Get-WUGAPIResponse"
    Write-Debug "URI: $uri"
    Write-Debug "Method: $Method"
    Write-Debug "Body: $body"

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    #input validation
    if (-not $Uri) {$Uri = Read-Host "Enter the fully qualified REST API endpoint.";}
    If (-not $Method) {$Method = Read-Host "Enter the HTTP verb to use (GET, POST, PUT, DELETE, PATCH, CONNECT, OPTIONS, TRACE, HEAD).";}
    #end input validation

    If(-not $body){
        try {
            $response = Invoke-RestMethod -Uri ${Uri} -Method ${Method} -Headers ${global:WUGBearerHeaders}
            Write-Debug "Invoke-RestMethod -Uri ${Uri} -Method ${Method} -Headers ${global:WUGBearerHeaders}"
            Write-Debug "Response: ${response}"
        }
        catch {
            $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $Uri `n Method: $Method"
            Write-Error $message
            throw
        }
     } else {
            try {
                $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $global:WUGBearerHeaders -Body $body
                Write-Debug "Invoke-RestMethod -Uri ${Uri} -Method ${Method} -Headers ${global:WUGBearerHeaders} -Body ${body}"
                Write-Debug "Response: ${response}"
            }
            catch {
                $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $Uri `n Method: $Method"
                Write-Error $message
                throw
            }
        }


    return $response
}