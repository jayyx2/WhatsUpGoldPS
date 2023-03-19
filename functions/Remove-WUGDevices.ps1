<#
.SYNOPSIS
Removes one or more devices from WhatsUp Gold. Supports removing up to 499 devices in a single batch.

.DESCRIPTION
This function removes one or more devices from WhatsUp Gold. It supports removing up to 499 devices in a single batch. If more than 499 devices need to be removed, the function automatically divides them into batches and processes each batch. The function takes two parameters: DeviceID (required) and DeleteDiscoveredDevices (optional). The DeviceID parameter specifies the ID or IDs of the device or devices to remove. The DeleteDiscoveredDevices parameter is a switch that, when used, removes all discovered resources associated with the device.

.PARAMETER DeviceID
Specifies the ID or IDs of the device or devices to remove. This parameter is mandatory.

.PARAMETER DeleteDiscoveredDevices
A switch that, when used, removes all discovered resources associated with the device. This parameter is optional.

.EXAMPLE
Remove-WUGDevices -DeviceID "123456" -DeleteDiscoveredDevices
Removes the device with ID "123456" and all of its associated discovered resources.

.EXAMPLE
Remove-WUGDevices -DeviceID "123456","789012"
Removes the devices with ID "123456" and "789012".

.EXAMPLE
$devices = Get-WUGDevice -Name "Printer"
Remove-WUGDevices -DeviceID $devices.ID
Removes all devices that have the word "Printer" in their name.

.NOTES
Author: Jason Alberino
Last Edit: 2023-03-18
Version: 1.0
#>

function Remove-WUGDevices {
    param(
        [Parameter(Mandatory)][array]$DeviceID,
        [Parameter()][bool]$DeleteDiscoveredDevices
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;} else {Request-WUGAuthToken}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    $totalDevices = $DeviceID.Count
    $batchSize = 499
    if ($totalDevices -le $batchSize) {
        $batchSize = $totalDevices
    }

    $devicesProcessed = 0
    $successes = 0

    do {
        $devices = $DeviceID[$devicesProcessed..($devicesProcessed + $batchSize - 1)]
        $devicesProcessed += $batchSize

        $body = @{
            operation = "delete"
            devices = $devices
        }

        if ($DeleteDiscoveredDevices) {
            $body["removeDiscoveredResources"] = $true
        }

        $jsonBody = $body | ConvertTo-Json -Depth 5

        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-" -method "PATCH" -body $jsonBody

        if ($result.data.success -eq $true) {
            $successes += $devices.Count
        }

        $percentComplete = ($devicesProcessed / $totalDevices) * 100
        if ($percentComplete -gt 100) {$percentComplete = 100;}
                
        Write-Progress -Activity "Removing devices" -PercentComplete $percentComplete -Status "$devicesProcessed of $totalDevices devices processed"
    } while ($devicesProcessed -lt $totalDevices)

    $result = @{
        successfulOperations = $successes
        resourcesNotAllowed = $null
        resourcesWithErros = $null
        errors = $null
        limitReached = $false
        maximumReached = $false
        success = $true
    }

    return $result
}
