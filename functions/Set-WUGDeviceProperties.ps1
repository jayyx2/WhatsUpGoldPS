<#
.SYNOPSIS
Set one or more properties of one or multiple devices in WhatsUp Gold
using the WhatsUp Gold REST API.

.DESCRIPTION
This function sets one or more properties of one or multiple devices in
WhatsUp Gold using the WhatsUp Gold REST API. You can set properties
such as the display name, whether the device is a wireless device, whether
wireless information is collected, whether device details should be kept
current, a note, SNMP OID, and an action policy.

.PARAMETER DeviceID
The device ID of the device to set properties for.

.PARAMETER DisplayName
The new display name to set for the device.

.PARAMETER isWireless
Whether the device is a wireless device.

.PARAMETER collectWireless
Whether wireless information is collected for the device.

.PARAMETER keepDetailsCurrent
Whether device details should be kept current.

.PARAMETER note
A note to set for the device.

.PARAMETER snmpOid
The SNMP OID to set for the device.

.PARAMETER actionPolicy
An array of action policies to set for the device.

.NOTES
WhatsUp Gold REST API is cool.

.EXAMPLE
Set-WUGDeviceProperties -DeviceID 33 -DisplayName "My device"
or
Set-WUGDeviceProperties -DeviceID 33, 34, 35 -isWireless $true
or
Set-WUGDeviceProperties -DeviceID 33, 34 -collectWireless $false -keepDetailsCurrent $true

#>
function Set-WUGDeviceProperties {
    param (
        [Parameter(Mandatory = $true)] [array] $DeviceID,
        [Parameter()] [string] $DisplayName,
        [Parameter()] [boolean] $isWireless,
        [Parameter()] [boolean] $collectWireless,
        [Parameter()] [boolean] $keepDetailsCurrent,
        [Parameter()] [string] $note,
        [Parameter()] [string] $snmpOid,
        [Parameter()] [array] $actionPolicy
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking
    #Input validation here
    #Array validations
    #actionPolicy
    #DeviceID
    if(!$DeviceID){$DeviceID = Write-Error "You must specify the DeviceID.";$DeviceID = Read-Host "Enter a DeviceID or IDs, separated by commas";$DeviceID = $DeviceID.Split(",");}
    #String Validation
    #DisplayName
    #note
    #snmpOid
    #Boolean validations
    #End input validation
    $finalresult = @()

    if ($DeviceID.Count -eq 1) {
        $uri = $global:WhatsUpServerBaseURI + "/api/v1/devices/$($DeviceID[0])/properties"
        $method = "PUT"
        $body = @{}
        if ($DisplayName) {$body.displayname = $DisplayName}
        if ($isWireless) {$body.iswireless = $isWireless}
        if ($collectWireless) {$body.collectwireless = $collectWireless}
        if ($keepDetailsCurrent) {$body.keepdetailscurrent = $keepDetailsCurrent}
        if ($note) {$body.note = $note}
        if ($snmpOid) {$body.snmpoid = $snmpOid}
        if ($actionPolicy) {$body.actionpolicy = $actionPolicy}
        $jsonBody = $body | ConvertTo-Json -Depth 5
        try {
            $result = Get-WUGAPIResponse -uri $uri -method $method -body $jsonBody
            return $result
        }
        catch {
            Write-Error "Error setting device properties: $_"
        }
    } else {
        $uri = $global:WhatsUpServerBaseURI + "/api/v1/devices/-/properties"
        $method = "PATCH"
        $batchSize = 201
        for ($i = 0; $i -lt $DeviceID.Count; $i += $batchSize) {
            $currentBatch = $DeviceID[$i..($i + $batchSize - 1)]
            $body = @{
                devices = $currentBatch
            }
            if ($isWireless) {$body.iswireless = $isWireless}
            if ($collectWireless) {$body.collectwireless = $collectWireless}
            if ($keepDetailsCurrent) {$body.keepdetailscurrent = $keepDetailsCurrent}
            if ($note) {$body.note = $note}
            if ($snmpOid) {$body.snmpoid = $snmpOid}
            if ($actionPolicy) {$body.actionpolicy = $actionPolicy}
            $jsonBody = $body | ConvertTo-Json -Depth 5
            Write-Information "Current batch of ${batchSize} is being processed."
            Write-Debug "Get-WUGAPIResponse -uri ${uri} -method ${method} -body ${jsonBody}"
            try {
                $result = Get-WUGAPIResponse -uri $uri -method $method -body $jsonBody
                $finalresult += $result
            }
            catch {
                Write-Error "Error setting device properties: $_"
                $errorMessage = "Error setting device properties: $($_.Exception.Message)`nStackTrace: $($_.ScriptStackTrace)"
                Write-Error $errorMessage
            }
        }
        return $finalresult
    }
}