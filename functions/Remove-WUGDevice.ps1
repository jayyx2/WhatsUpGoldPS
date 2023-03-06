function Remove-WUGDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$DeviceId,
        [switch]$DeleteDiscoveredDevices
    )
    
    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
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
