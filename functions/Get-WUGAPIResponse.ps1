function Get-WUGAPIResponse {
    param(
        [string]$uri,
        [string]$method
    )
    if (-not $Global:WUGBearerHeaders) {
        Connect-WUGServer
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Method $method -Headers $Global:WUGBearerHeaders
    } catch {
        $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $uri `n Method: $method"
        Write-Error $message
        throw
    }
    return $response
}