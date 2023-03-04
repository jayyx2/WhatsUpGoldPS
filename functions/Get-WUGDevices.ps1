<#
.SYNOPSIS
Get WhatsUp Gold devices data using the WhatsUp Gold REST API.

.DESCRIPTION
Retrieves a list of all devices in WhatsUp Gold or a filtered list of devices by name or IP address.

.PARAMETER SearchValue
Filters the list of devices by a name or a partial name.

.PARAMETER DeviceGroupID
Filters the list of devices by an IP address.

.PARAMETER View
Filters the list of devices by a device group ID.

.PARAMETER Limit
The view to use for the devices data, such as overview or detail.

.EXAMPLE
Get-WUGDevices
Retrieves a list of all devices in WhatsUp Gold.

#>

function Get-WUGDevices {
    param (
        [Parameter()] [string] $SearchValue,
        [Parameter()] [string] $DeviceGroupID = "-1",
        [Parameter()] [ValidateSet("id", "basic", "card", "overview")] [string] $View = "id",
        [Parameter()] [string] $Limit = "500"
     )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    $uri = ${global:WhatsUpServerBaseURI}
    $uri += "/api/v1/device-groups/${DeviceGroupID}/devices/-?view=${View}&limit=${Limit}"

    if ($SearchValue) {
        $uri += "&search=${SearchValue}"
    }
    else {
        $SearchValue = Read-Host "Enter the search value either IP, hostname, or display name."
    }

    $allDevices = @()
    do {
        $result = Get-WUGAPIResponse -uri $uri -method "GET"
        $devices = ${result}.data.devices
        $allDevices += $devices
        $pageInfo = ${result}.paging

        if (${pageInfo}.nextPageId){
            $uri = $global:WhatsUpServerBaseURI + "/api/v1/device-groups/${DeviceGroupID}/devices/-?view=${View}&limit=${Limit}&pageId=$(${pageInfo}.nextPageId)&search=${SearchValue}"
        }
    } while (${pageInfo}.nextPageId)

    return $allDevices
}