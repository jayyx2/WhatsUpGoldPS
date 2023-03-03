<#
.SYNOPSIS
Get WhatsUp Gold devices data using the WhatsUp Gold REST API.

.DESCRIPTION
Retrieves a list of all devices in WhatsUp Gold or a filtered list of devices by name or IP address.

.PARAMETER Name
Filters the list of devices by a name or a partial name.

.PARAMETER IPAddress
Filters the list of devices by an IP address.

.PARAMETER GroupID
Filters the list of devices by a device group ID.

.PARAMETER View
The view to use for the devices data, such as overview or detail.

.PARAMETER Count
The maximum number of devices to return. The default value is 100.

.EXAMPLE
Get-WUGDevices
Retrieves a list of all devices in WhatsUp Gold.

.EXAMPLE
Get-WUGDevices -Name "server"
Retrieves a list of devices whose name contains the string "server".

.EXAMPLE
Get-WUGDevices -IPAddress "192.168.0.1"
Retrieves a list of devices with the IP address 192.168.0.1.

.EXAMPLE
Get-WUGDevices -GroupID 5 -View detail
Retrieves a list of devices in device group 5, with detailed information.

.EXAMPLE
Get-WUGDevices -Name "switch" -Count 50
Retrieves a list of the first 50 devices whose name contains the string "switch".
#>

function Get-WUGDevices {
    param (
        [Parameter()] [string] $SearchValue
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    $uri = ${global:WhatsUpServerBaseURI}
    $uri += "/api/v1/device-groups/-1/devices/-?view=id&limit=500"

    if ($SearchValue) {
        $uri += "&search=${SearchValue}"
    }
    else {
        $SearchValue = Read-Host "Enter the search value either IP, hostname, or display name."
    }

    $allDevices = @()
    do {
        $result = Get-WUGAPIResponse -uri $uri -method "GET"
        $devices = ${result}.data.devices.id
        $allDevices += $devices
        $pageInfo = ${result}.paging

        if (${pageInfo}.nextPageId){
            $uri = $global:WhatsUpServerBaseURI + "/api/v1/device-groups/-1/devices/-?view=id&limit=200&pageId=$(${pageInfo}.nextPageId)&search=${SearchValue}"
        }
    } while (${pageInfo}.nextPageId)

    return $allDevices
}