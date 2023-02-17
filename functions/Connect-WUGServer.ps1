#Example usage
#Connect-WUGServer -Credential $Credential -serverUri "192.168.1.212"
#Connect-WUGServer -Username "admin" -serverUri "192.168.1.212"
#Connect-WUGServer -Username "admin" -Password "PasswordHere" -serverUri "192.168.1.212"
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

    if($Credential) {
        $Username = $Credential.GetNetworkCredential().UserName
        $Password = $Credential.GetNetworkCredential().Password
    }

    if($Password -and -not $Username) {
        $Username = Read-Host "Username is required. Username?"
        $Password = $Password
    }

    if ($Username -and -not $Password) {
        $Credential = Get-Credential -UserName $Username
        $Password = $Credential.GetNetworkCredential().Password
    }

    if(-not $Username -and -not $Credential) {
        $Credential = Get-Credential
        $Username = $Credential.GetNetworkCredential().UserName
        $Password = $Credential.GetNetworkCredential().Password
    }
    $tokenUri = "${protocol}://${serverUri}:9644/api/v1/token"
    $tokenHeaders = @{"Content-Type" = "application/json"}
    $tokenBody = "grant_type=password&username=${Username}&password=${Password}"
    try {
        $token = Invoke-RestMethod -Uri $tokenUri -Method Post -Headers $tokenHeaders -Body $tokenBody -SkipCertificateCheck
    } catch {
        $message = "Error: $($_.Exception.Response.StatusDescription) `n URI: $tokenUri"
        Write-Error -message $message
        throw
    }
    $global:WUGBearerHeaders = @{
        "Content-Type" = "application/json"
        "Authorization" = "Bearer $($token.Token)"
    }
    $expiry = (Get-Date).AddSeconds($token.expires_in).ToUniversalTime().ToString("s")
    return "Connected to ${serverUri} to obtain authorization token for user `"${Username}`" which expires at $expiry UTC."
}