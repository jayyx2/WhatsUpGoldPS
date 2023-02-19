<#
.SYNOPSIS
    Connect to a REST API endpoint by specifying a full URI and a  HTTP Verb

.DESCRIPTION
    Connect to a REST API endpoint by specifying a full URI and a  HTTP Verb

.PARAMETER Uri
    The entire API endpoint, for example, http://192.168.1.212:9644/api/v1/product/api

.PARAMETER Method
    The HTTP verb to use when connecting to the REST API endpoint.
    Valid options are:
    GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH

.EXAMPLE
    Get-WUGAPIResponse -uri "http://192.168.1.212:9644/api/v1/product/api" -Method GET
    $dataObject = (Get-WUGAPIResponse -uri "http://192.168.1.212:9644/api/v1/product/api" -Method GET).data

#>
function Get-WUGAPIResponse {
    param(
        [Parameter()] [string] $uri,
        [Parameter()] [ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH')] [string] $Method
    )
    if (-not $global:WUGBearerHeaders){
        Connect-WUGServer
    }
    if ((Get-Date) -ge $global:expiry){
        Write-Error -Message "Token expired, running Connect-WUGServer"
        Connect-WUGServer
    }
    if (-not $Uri){
        $Uri = Read-Host "Enter the fully qualified REST API endpoint."
    }
    If (-not $Method){
        $Method = Read-Host "Enter the HTTP verb to use (GET, POST, PUT, DELETE, PATCH, CONNECT, OPTIONS, TRACE, HEAD)."
    }
    try {
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $global:WUGBearerHeaders
    } catch {
        $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $Uri `n Method: $Method"
        Write-Error $message
        throw
    }
    return $response
}