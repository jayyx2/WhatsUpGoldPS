<#
.SYNOPSIS
Sets properties of one or more devices in WhatsUp Gold.

.SYNTAX
Set-WUGDeviceProperties [-DeviceID] <array> [[-DisplayName] <string>] [[-isWireless] <boolean>] [[-collectWireless] <boolean>] [[-keepDetailsCurrent] <boolean>] [[-note] <string>] [[-snmpOid] <string>] [[-actionPolicy] <array>]

.DESCRIPTION
The Set-WUGDeviceProperties function allows you to set properties for one or more devices in WhatsUp Gold. You can specify the device ID(s) using the -DeviceID parameter. If you do not specify this parameter, you will be prompted to enter the device ID(s). Other parameters allow you to specify various properties to set for the devices.

PARAMETERS
.PARAMETER DeviceID <array>
    Specifies the device ID(s) of the device(s) for which you want to set properties. This parameter is mandatory.

.PARAMETER DisplayName <string>
    Specifies the display name of the device. Default is null.

.PARAMETER  isWireless <boolean>
    Specifies whether the device is a wireless device. Default is null.

.PARAMETER collectWireless <boolean>
    Specifies whether wireless information should be collected for the device. Default is null.

.PARAMETER keepDetailsCurrent <boolean>
    Specifies whether details should be kept current for the device. Default is null.

.PARAMETER note <string>
    Specifies notes for the device. Default is null.

.PARAMETER snmpOid <string>
    Specifies the SNMP OID for the device. Default is null.

.PARAMETER actionPolicy <array>
    Specifies the action policy for the device. Default is null.

.NOTES
    Author: Jason Alberino (jason@wug.ninja) 2023-03-24
    Last modified: Let's see your name here YYYY-MM-DD
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
        [Parameter()] [string] $actionPolicyName,
        [Parameter()] [string] $actionPolicyId
        #[Parameter()][string]$JsonData
    )
    # Your existing code to make the API call using $JsonData
    # TBD using call from Get-WUGDeviceTemplate or Get-WUGDeviceProperties
    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; } else { Request-WUGAuthToken }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking
    #Input validation here
    #Array validations
    #actionPolicy
    #DeviceID
    if (!$DeviceID) { $DeviceID = Write-Error "You must specify the DeviceID."; $DeviceID = Read-Host "Enter a DeviceID or IDs, separated by commas"; $DeviceID = $DeviceID.Split(","); }
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
        if ($DisplayName) { $body.displayname = $DisplayName }
        if ($isWireless) { $body.iswireless = $isWireless }
        if ($collectWireless) { $body.collectwireless = $collectWireless }
        if ($keepDetailsCurrent) { $body.keepdetailscurrent = $keepDetailsCurrent }
        if ($note) { $body.note = $note }
        if ($snmpOid) { $body.snmpoid = $snmpOid }
        if ($actionPolicyId -or $actionPolicyName) {
            $actionPolicy = @{}
            if ($body.actionpolicy) {
                $actionPolicy = $body.actionpolicy
            }
            if ($actionPolicyId) {
                $actionPolicy += @{
                    id = "${actionPolicyId}"
                }
            }
            if ($actionPolicyName) {
                $actionPolicy += @{
                    name = "${actionPolicyName}"
                }
            }
            $body.actionpolicy = $actionPolicy
        } else {
            $actionPolicy = @{}
            $body.actionpolicy = $actionPolicy
        }
        $jsonBody = $body | ConvertTo-Json -Depth 5
        try {
            $result = Get-WUGAPIResponse -uri $uri -method $method -body $jsonBody
            Write-Information $jsonBody
            return $result.data
        }
        catch {
            Write-Error "Error setting device properties: $($_)"
        }
    }
    else {
        $uri = $global:WhatsUpServerBaseURI + "/api/v1/devices/-/properties"
        $method = "PATCH"
        $batchSize = 201
        for ($i = 0; $i -lt $DeviceID.Count; $i += $batchSize) {
            $currentBatch = $DeviceID[$i..($i + $batchSize - 1)]
            $body = @{
                devices = $currentBatch
            }
            if ($isWireless) { $body.iswireless = $isWireless }
            if ($collectWireless) { $body.collectwireless = $collectWireless }
            if ($keepDetailsCurrent) { $body.keepdetailscurrent = $keepDetailsCurrent }
            if ($note) { $body.note = $note }
            if ($snmpOid) { $body.snmpoid = $snmpOid }
            if ($actionPolicyId -or $actionPolicyName) {
                $actionPolicy = @{}
                if ($body.actionpolicy) {
                    $actionPolicy = $body.actionpolicy
                }
                if ($actionPolicyId) {
                    $actionPolicy += @{
                        id = "${actionPolicyId}"
                    }
                }
                if ($actionPolicyName) {
                    $actionPolicy += @{
                        name = "${actionPolicyName}"
                    }
                }
                $body.actionpolicy = $actionPolicy
            } else {
                $actionPolicy = @{}
                $body.actionpolicy = $actionPolicy
            }
            $jsonBody = $body | ConvertTo-Json -Depth 5
            Write-Information "Current batch of ${batchSize} is being processed."
            Write-Debug "Get-WUGAPIResponse -uri ${uri} -method ${method} -body ${jsonBody}"
            try {
                $result = Get-WUGAPIResponse -uri $uri -method $method -body $jsonBody
                $finalresult += $result.data
            }
            catch {
                Write-Error $jsonBody
                Write-Error "Error setting device properties: $_"
                $errorMessage = "Error setting device properties: $($_.Exception.Message)`nStackTrace: $($_.ScriptStackTrace)"
                Write-Error $errorMessage
            }
        }
        return $finalresult
    }
}