<#
.SYNOPSIS
Retrieves properties of one or more devices in WhatsUp Gold.

.SYNTAX
Get-WUGDeviceProperties [-DeviceID] <array>

.DESCRIPTION
The Get-WUGDeviceProperties function allows you to retrieve properties for one or more devices in WhatsUp Gold. You can specify the device ID(s) using the -DeviceID parameter. If you do not specify this parameter, you will be prompted to enter the device ID(s).

.PARAMETERS
.PARAMETER DeviceID <array>
    Specifies the device ID(s) of the device(s) for which you want to retrieve properties.

.NOTES
    Author: Jason Alberino (jason@wug.ninja) 2023-04-02
    Last modified: Let's see your name here YYYY-MM-DD
#>
function Get-WUGDeviceProperties {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [array] $DeviceID
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; } else { Request-WUGAuthToken }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking

    $properties = @()

    foreach ($id in $DeviceID) {
        $uri = $global:WhatsUpServerBaseURI + "/api/v1/devices/$id/properties"
        try {
            $result = Get-WUGAPIResponse -uri $uri -method "GET"
            $properties += $result.data
        }
        catch {
            Write-Error "Error getting device properties for device ID ${id}: $_"
        }
    }

    return $properties
}
