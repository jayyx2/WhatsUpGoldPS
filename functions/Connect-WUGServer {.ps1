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

    if(-not $Username) {
        $Username = $Credential.GetNetworkCredential().UserName
    }
    if (-not $Password) {
        $Credential = Get-Credential -UserName $Username
    }

    if(-not $Password) {
        $Password = $Credential.GetNetworkCredential().Password
    }
    $tokenUri = "${protocol}://${serverUri}:9644/api/v1/token"
    $tokenHeaders = @{"Content-Type" = "application/json"}
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

    $expirationTime = [Math]::Round($token.expires_in / 60)
    $expiry = (Get-Date).AddSeconds($token.expires_in).ToUniversalTime().ToString("s")

    return "Connected to ${serverUri} to obtain authorization token for user `"${Username}`" which expires at $expiry UTC."
}
