<#
.SYNOPSIS
    When you have the DeviceID, use Get-WUGDevice for returning
    information for the given DeviceID(s) using the WhatsUp Gold
    REST API.

.DESCRIPTION
    Get data from the WhatsUp Gold /device/{$DeviceID} endpoint or
    search all devices using /device-groups/-1/devices/-?view=overview
    &search=$SearchValue" to find the device id you need

.PARAMETER DeviceID
    The ID of the device in the WhatsUp Gold database. You can search
    for DeviceID using the Get-WUGDevices function

.PARAMETER View
    Default is card. Choose from id, basic, overview, and card.
    id: id
    basic: id, name, os, brand, role, networkAddress, hostname, notes
    overview: id, description, name, worstState, bestState, os, brand, role, networkAddress,
    hostName, notes, totalActiveMonitorsDown, totalActiveMonitors
    card: id, description, name, worstState, bestState, os, brand, role, networkAddress,
    hostName, notes, totalActiveMonitorsDown, totalActiveMonitors, downActiveMonitors

.NOTES
    WhatsUp Gold REST API is cool.

.EXAMPLE
    Get-WUGDevice -DeviceID 33
    Get-WUGDevice -DeviceID $ArrayOfDeviceIDs
    Get-WUGDevice -DeviceID 2,3,4,20
#>
function Get-WUGDevice {
    param (
        [Parameter(Mandatory = $true)] [array] $DeviceID,
        [Parameter()] [ValidateSet("id", "basic", "card", "overview")] [string] $View = "card"
     )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    $uri = $global:WhatsUpServerBaseURI
    $finaloutput = @()

    if ($DeviceID) {
        foreach ($id in $DeviceID) {
            $deviceUri = "${uri}/api/v1/devices/${id}?view=overview"
            try {
                $result = Get-WUGAPIResponse -uri $deviceUri -method "GET"
                Write-Debug "Result from Get-WUGAPIResponse -uri ${deviceUri} -method `"GET`"`r`n:${result}"
                $finaloutput += $result.data
            }
            catch {
                Write-Error "No results returned for -DeviceID ${id}. Try using -Search instead."
            }
        }
    }

    return $finaloutput
}