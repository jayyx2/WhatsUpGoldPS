$Global:WUGBearerHeaders = $null
function Connect-WUGServer {
    param (
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password,
        [Parameter(Mandatory)] [string] $serverUri,
        [Parameter(Mandatory = $false)] [ValidateSet("http", "https")] [string] $Protocol = "http"
    )
    $tokenUri = "${protocol}://${serverUri}:9644/api/v1/token"
    $tokenHeaders = @{
        "Content-Type" = "application/json"
    }

    $tokenBody = "grant_type=password&username=${Username}&password=${Password}"

    try {
        $token = Invoke-RestMethod -Uri $tokenUri -Method Post -Headers $tokenHeaders -Body $tokenBody -SkipCertificateCheck
    } catch {
        $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $tokenUri"
        Write-Output -message $message
        throw
    }
    $global:WUGBearerHeaders = @{
        "Content-Type" = "application/json"
        "Authorization" = "Bearer $($token.Token)"
    }
    return "Successfully connected to WhatsUp Gold server and obtained authorization token."
}