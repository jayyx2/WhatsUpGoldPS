<#
.SYNOPSIS
Set WhatsUp Gold device attributes using the WhatsUp Gold REST API.

.DESCRIPTION
Update or modify device attributes in WhatsUp Gold using the specified device ID and batch data. The batch data provides a flexible way to perform various attribute operations, including deleting attributes, modifying existing attributes, and adding new attributes.

.PARAMETER DeviceId
The ID of the device in the WhatsUp Gold database.

.PARAMETER BatchData
A custom object that contains the batch data for attribute operations. The batch data should include the following properties:
- `deleteAllAttributes`: A boolean indicating whether to remove all attributes from the device. This operation is mutually exclusive with other delete statements.
- `attributesToDelete`: An array of attribute IDs to remove from the device.
- `attributeNamesToDelete`: An array of attribute names to remove from the device.
- `attributeNameContainsToDelete`: An array of substring values. If an attribute name contains any of these substrings, it will be deleted.
- `attributeValueContainsToDelete`: An array of substring values. If an attribute value contains any of these substrings, the attribute will be deleted.
- `attributeToModify`: An array of objects representing attributes to modify. Each object should contain `attributeId`, `name`, and `value` properties.
- `attributesToAdd`: An array of objects representing attributes to add. Each object should contain `name` and `value` properties.

.EXAMPLE
$batchData = @{
    deleteAllAttributes = $true
    attributesToDelete = @("attributeId1", "attributeId2")
    attributeNamesToDelete = @("attributeName1", "attributeName2")
    attributeNameContainsToDelete = @("substring1", "substring2")
    attributeValueContainsToDelete = @("substring3", "substring4")
    attributeToModify = @(
        @{
            attributeId = "attributeId3"
            name = "attributeName3"
            value = "attributeValue3"
        },
        @{
            attributeId = "attributeId4"
            name = "attributeName4"
            value = "attributeValue4"
        }
    )
    attributesToAdd = @(
        @{
            name = "attributeName5"
            value = "attributeValue5"
        },
        @{
            name = "attributeName6"
            value = "attributeValue6"
        }
    )
}

Set-WUGDeviceAttributes -DeviceId "12345" -BatchData $batchData

.NOTES
Author: Jason Alberino (jason@wug.ninja) 2023-06-19
Last modified: Let's see your name here YYYY-MM-DD
Reference: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#operation/Device_BatchAttributes

#>

function Set-WUGDeviceAttributes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$DeviceId,

        [Parameter()]
        [PSCustomObject]$BatchData
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking
    
    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/attributes"

    if ($BatchData.deleteAllAttributes -and ($BatchData.attributesToDelete -or $BatchData.attributeNamesToDelete -or $BatchData.attributeNameContainsToDelete -or $BatchData.attributeValueContainsToDelete)) {
        Write-Error "Combining 'DeleteAllAttributes' with other delete statements is not allowed."
        return
    }

    try {
        $result = Invoke-RestMethod -Uri $uri -Method PUT -Headers $global:WUGBearerHeaders -ContentType 'application/json' -Body ($BatchData | ConvertTo-Json -Depth 10)
        return $result
    }
    catch {
        Write-Error "Error performing batch operation on device attributes: $($_.Exception.Message)"
    }
}
