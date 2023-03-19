<#
.SYNOPSIS
Creates new devices in WhatsUp Gold using device templates.

.PARAMETER -templates <array>
    The device templates to use to create the new devices.

.PARAMETER -ApplyL2 [<SwitchParameter>]
    Specifies whether Layer 2 data should be applied.

.PARAMETER -Update [<SwitchParameter>]
    Specifies whether to update existing devices with new templates.

.PARAMETER -UpdateInterfaceState [<SwitchParameter>]
    Specifies whether interface state should be updated.

.PARAMETER -UpdateInterfaceNames [<SwitchParameter>]
    Specifies whether interface names should be updated.

.PARAMETER -UpdateActiveMonitors [<SwitchParameter>]
    Specifies whether active monitors should be updated.

.DESCRIPTION
The `Add-WUGDevices` function creates new devices in WhatsUp Gold using the specified device templates. If the `-ApplyL2`
switch is specified, Layer 2 data will be applied to the new devices. If the `-Update` switch is specified, existing devices
will be updated with the new templates. If the `-UpdateInterfaceState` switch is specified, the interface state of existing
devices will be updated. If the `-UpdateInterfaceNames` switch is specified, the interface names of existing devices will be
updated. If the `-UpdateActiveMonitors` switch is specified, the active monitors of existing devices will be updated.

EXAMPLES
Add-WUGDevices -templates "Switch 1", "Router 1"

This example creates new devices in WhatsUp Gold using the "Switch 1" and "Router 1" templates.

Add-WUGDevices -templates "Switch 1", "Router 1" -ApplyL2 -Update -UpdateInterfaceState -UpdateInterfaceNames

This example creates new devices in WhatsUp Gold using the "Switch 1" and "Router 1" templates, applies Layer 2 data, updates
existing devices with the new templates, updates the interface state of existing devices, and updates the interface names of
existing devices.
#>

function Add-WUGDevices {
    param(
        [Parameter(Mandatory)] [array] $deviceTemplates,
        [switch]$ApplyL2,
        [switch]$Update,
        [switch]$UpdateInterfaceState,
        [switch]$UpdateInterfaceNames,
        [switch]$UpdateActiveMonitors
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;} else {Request-WUGAuthToken}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    $options = @("all")
    if ($ApplyL2) { $options += "l2" }
    if ($Update) { $options += "update" }
    if ($UpdateInterfaceState) { $options += "update-interface-state" }
    if ($UpdateInterfaceNames) { $options += "update-interface-names" }
    if ($UpdateActiveMonitors) { $options += "update-active-monitors" }

    $body = @{
        options = @("all")
        templates = $deviceTemplates
    } | ConvertTo-Json -Depth 10

    try {
        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/template" -method "PATCH" -body $body
        return $result.data
    }
    catch {
        Write-Error $_
    }
}