<#
.SYNOPSIS
Updates or changes a device attribute in WhatsUp Gold.

.DESCRIPTION
The Set-WUGDeviceAttribute function allows you to update or change a specific attribute for a device in WhatsUp Gold. It utilizes the PUT /api/v1/devices/{deviceId}/attributes/{attributeId} endpoint to perform the update.

.PARAMETER DeviceId
The ID of the device to update.

.PARAMETER AttributeId
The ID of the attribute to update.

.PARAMETER Name
The name of the device attribute.

.PARAMETER Value
(Optional) The value for the device attribute.

.EXAMPLE
Set-WUGDeviceAttribute -DeviceId "12345" -AttributeId "56789" -Name "Location" -Value "New York"

This example updates the attribute with ID "56789" for the device with ID "12345" in WhatsUp Gold. The attribute name is set to "Location" and its value is set to "New York".

.NOTES
Author: Jason Alberino (jason@wug.ninja) 2023-06-19
Last modified: Let's see your name here YYYY-MM-DD
Reference: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#operation/Device_UpdateAttribute
#>

function Set-WUGDeviceAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceId,
        
        [Parameter(Mandatory = $true)]
        [string]$AttributeId,
        
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [string]$Value
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking
    
    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/attributes/${AttributeId}?name=${Name}&value=${Value}"

    try {
        $result = Get-WUGAPIResponse -Uri $uri -Method PUT
        return $result.data
    }
    catch {
        Write-Error "Error updating device attribute: $($_.Exception.Message)"
    }
}
