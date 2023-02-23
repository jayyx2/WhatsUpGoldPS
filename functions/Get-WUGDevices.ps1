function Get-WUGDevices {
    param (
        [Parameter()] [string] $SearchValue
    )

    if (-not $global:WUGBearerHeaders) {
        Write-Output "Authorization token not found. Please run Connect-WUGServer to connect to the WhatsUp Gold server."
        return
    }

    if (-not $global:WhatsUpServerBaseURI) {
        Write-Output "Base URI not found. Please run Connect-WUGServer to connect to the WhatsUp Gold server."
        return
    }

    $uri = $global:WhatsUpServerBaseURI
    $uri += "/api/v1/device-groups/-1/devices/-?view=id&limit=0"

    if ($SearchValue) {
        $uri += "&search=$SearchValue"
    }

    $result = Get-WUGAPIResponse -uri $uri -method "GET"
    return $result.data.devices.id
}
