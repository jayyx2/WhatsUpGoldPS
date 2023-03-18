<#
.SYNOPSIS
Removes a device from the WhatsUp Gold monitoring system.

.PARAMETER DeviceId
The ID of the device to remove.

.PARAMETER DeleteDiscoveredDevices
If specified, all discovered devices associated with the device to be removed will also be deleted.

.EXAMPLE
Remove-WUGDevice -DeviceId "12345"
Removes the device with ID "12345" from the WhatsUp Gold monitoring system.

.EXAMPLE
Remove-WUGDevice -DeviceId "12345" -DeleteDiscoveredDevices
Removes the device with ID "12345" from the WhatsUp Gold monitoring system, along with all discovered devices associated with it.

.NOTES
This function requires the user to be authenticated using Connect-WUGServer before it can be run.
#>
function Remove-WUGDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$DeviceId,
        [switch]$DeleteDiscoveredDevices
    )
    
    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;} else {Update-WUGAuthToken}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking
    
    # Invoke the API
    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}"
    if ($DeleteDiscoveredDevices) {
        $uri += "?deleteDiscoveredDevices=true"
    }
    try {
        $result = Get-WUGAPIResponse -Uri $uri -Method DELETE
        if ($result.data.success) {
            Write-Output "Device $($DeviceId) removed successfully."
        } else {
            Write-Error "Failed to remove device $($DeviceId)."
        }
    } catch {
        Write-Error "Failed to remove device $($DeviceId). $($Error[0].Exception.Message)"
    }
}
