<#
.SYNOPSIS
    Retrieves a specific attribute for a device in WhatsUp Gold (WUG) using the device ID and attribute ID.

.DESCRIPTION
    The Get-WugDeviceAttribute function retrieves a specific attribute for a device in WUG using the device ID and attribute ID.
    It requires the OAuth 2.0 authorization token to be set, which can be obtained using the Connect-WUGServer function.
    The function validates the input parameters and handles any errors that occur during the API request.

.PARAMETER DeviceID
    The ID of the device for which to retrieve the attribute. This parameter is mandatory.

.PARAMETER AttributeID
    The ID of the attribute to retrieve. This parameter is mandatory.

.EXAMPLE
    Get-WugDeviceAttribute -DeviceID "device1" -AttributeID "attribute1"
    Retrieves the "attribute1" attribute for "device1" in WhatsUp Gold.

.NOTES
    Author: Jason Alberino (jason@wug.ninja) 2023-04-02
    Last modified: Let's see your name here YYYY-MM-DD
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#section/Device-Attributes
#>
function Get-WUGDeviceAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$AttributeId
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking

    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/attributes/${AttributeId}"

    try {
        $result = Get-WUGAPIResponse -uri $uri -Method GET
        return $result.data
    }
    catch {
        Write-Error "Error getting device attribute: $($_.Exception.Message)"
    }
}