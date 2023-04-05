<#
.SYNOPSIS
    Gets attributes of a device in WhatsUp Gold.

.PARAMETER DeviceID
    The ID of the device to retrieve attributes for. This parameter is required.

.PARAMETER Names
    An array of attribute names to return. If empty, all attributes will be returned.

.PARAMETER NameContains
    A string used to filter and return only attributes with names that contain the specified value. If empty, all attributes will pass.

.PARAMETER ValueContains
    A string used to filter and return only attributes with values that contain the specified value. If empty, all attributes will pass.

.PARAMETER PageId
    The page ID to return.

.PARAMETER Limit
    The maximum number of attributes/values to return.

.EXAMPLE
    Get-WUGDeviceAttributes -DeviceID "12345" -Names @("Attribute1", "Attribute2") -Limit 10
    Gets the first 10 attributes with the names "Attribute1" and "Attribute2" for the device with ID "12345".

.NOTES
    Author: Jason Alberino (jason@wug.ninja) 2023-04-02
    Last modified: Let's see your name here YYYY-MM-DD
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#operation/Device_FindAttributes
#>

function Get-WUGDeviceAttributes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$DeviceID,

        [Parameter()]
        [array]$Names,

        [Parameter()]
        [string]$NameContains,

        [Parameter()]
        [string]$ValueContains,

        [Parameter()]
        [string]$PageId,

        [Parameter()]
        [int]$Limit = 0
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; } else { Request-WUGAuthToken }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking

    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/$deviceId/attributes/-?"

    if ($names) { $querystring += "names=$names&" }
    if ($nameContains) { $querystring += "nameContains=$nameContains&" }
    if ($valueContains) { $querystring += "valueContains=$valueContains&" }
    if ($pageId) { $querystring += "pageId=$pageId&" }
    if ($limit) { $querystring += "limit=$limit&" }
    if($querystring){
        $querystring = $querystring.Trim('&')
    }
    $uri += $querystring

    Write-Debug "URI: $uri"
    Write-Debug "Global URI: $global:WhatsUpServerBaseURI"

    try {
        $response = Get-WUGAPIResponse -uri $uri -method "GET"
        return $response.data
    }
    catch {
        Write-Error "Error getting device attributes: $_"
    }
}
