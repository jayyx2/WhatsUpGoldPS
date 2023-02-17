function Get-WUGAPIResponse {
    param(
        [Parameter()] [string] $Uri,
        [Parameter()] [ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH')] [string] $Method
    )
    if (-not $global:WUGBearerHeaders -or $Global:expiry -le (Get-Date)) {
        Connect-WUGServer
    }
    if (-not $Uri){
        $Uri = Read-Host "Enter the fully qualified REST API endpoint."
    }
    If (-not $Method){
        $Method = Read-Host "Enter the HTTP verb to use (GET, POST, PUT, PATCH)."
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
