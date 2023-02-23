<#
.SYNOPSIS
    Set WhatsUp Gold device properties using the WhatsUp Gold REST API

.DESCRIPTION
    Set data using the WhatsUp Gold API endpoint
    PUT /api/v1/devices/{deviceId}/properties

.PARAMETER DeviceID
    Required. Use Get-WUGDeviceID if you need help.

.PARAMETER DisplayName
    String value to set the display name to

.PARAMETER isWireless
    Boolean value to set the "Is Wireless?" flag

.PARAMETER collectWireless
    Boolean value to set the  wireless data collection flag

.PARAMETER keepDetailsCurrent
    Boolean value to set the keep details current flag

.PARAMETER note
    String value to set the device notes

.PARAMETER snmpOid
    String value to set the SNMP Object ID [OID format 1.3.6.4.1]

.PARAMETER actionPolicy
    An array to set the device action policy

.NOTES
    WhatsUp Gold REST API is cool.

.EXAMPLE
    Set-WUGDeviceProperties -DeviceID 33 -DisplayName "My New Display Name"
#>

#PUT /api/v1/devices/{deviceId}/properties
function Set-WUGDeviceProperties {
    param (
        [Parameter(Mandatory = $true)] [string] $DeviceID,
        [Parameter()] [string] $DisplayName,
        [Parameter()] [boolean] $isWireless,
        [Parameter()] [boolean] $collectWireless,
        [Parameter()] [boolean] $keepDetailsCurrent,
        [Parameter()] [string] $note,
        [Parameter()] [string] $snmpOid,
        [Parameter()] [array] $actionPolicy
    )

    if (-not $global:WUGBearerHeaders) {
        Write-Output "Authorization token not found. Please run Connect-WUGServer to connect to the WhatsUp Gold server."
        return
    }

    if (-not $global:WhatsUpServerBaseURI) {
        Write-Output "Base URI not found. Please run Connect-WUGServer to connect to the WhatsUp Gold server."
        return
    }

    $uri = $global:WhatsUpServerBaseURI
    $uri += "/api/v1/devices/$DeviceID/properties"

    $body = @{}
    if ($DisplayName) { $body.displayname = $DisplayName }
    if ($isWireless) { $body.iswireless = $isWireless }
    if ($collectWireless) { $body.collectwireless = $collectWireless }
    if ($keepDetailsCurrent) { $body.keepdetailscurrent = $keepDetailsCurrent }
    if ($note) { $body.note = $note }
    if ($snmpOid) { $body.snmpoid = $snmpOid }
    if ($actionPolicy) { $body.actionpolicy = $actionPolicy }
    $jsonBody = $body | ConvertTo-Json -Depth 5
    $jsonBody

    try {
        $result = Get-WUGAPIResponse -uri $uri -method "PUT" -body $jsonBody
        return $result.data
    } catch {
        Write-Error "Error setting device properties: $_"
    }
}
