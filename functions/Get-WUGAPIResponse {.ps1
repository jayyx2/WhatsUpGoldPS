function Get-WUGAPIResponse {
    param(
        [string]$uri,
        [string]$method,
        [switch]$logfile
    )
    if (-not $Global:WUGBearerHeaders) {
        throw "Global headers variable not set, please run Connect-WUGServer first."
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Method $method -Headers $global:headers
    } catch {
        $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $uri `n Method: $method"
        if ($logfile) {
            #Write-Log -message $message
        } else {
            Write-Output $message
        }
        throw
    }
    return $response
}