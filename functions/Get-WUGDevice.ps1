<#
.SYNOPSIS
    Get a WhatsUp Gold device data using the WhatsUp Gold REST API
    Usually used to get the device id which can be used for various
    other rest API calls.

.DESCRIPTION
    Get data from the WhatsUp Gold /device/{$DeviceID} endpont or
    search all devices using /device-groups/-1/devices/-?view=overview
    &search=$SearchValue" to find the device id you need

.PARAMETER DeviceID
    If you already know the device id, get the other information

.PARAMETER SearchValue
    Search by IP address, hostname, or display name of the WhatsUp
    Gold device.
        If multiple results returned, you must select an index

.NOTES
    WhatsUp Gold REST API is cool.

.EXAMPLE
    Get-WUGDevice -DeviceID 33
    or
    Get-WUGDevice -Search 192.168.1.238
        totalActiveMonitors     : 1
        totalActiveMonitorsDown : 0
        notes                   : This device was scanned by discovery
        on 2/18/2023 3:13:17 PM.
        hostName                : UnifiAP1.local
        networkAddress          : 192.168.1.238
        role                    : Managed Device
        brand                   : Ubiquiti Networks
        os                      : Linux
        bestState               : Up
        worstState              : Up
        name                    : UnifiAP1
        description             : Profile for devices with SNMP that did not match any other role
        id                      : 33
    Get-WUGDevice -Search 192.186.1.24
        Index 0 | DeviceName:CB-PF2JWEGA.localdomain | Hostname:CB-PF2JWEGA.localdomain | IP:192.168.1.242
        Index 1 | DeviceName:ESP_35DD0E.localdomain | Hostname:ESP_35DD0E.localdomain | IP:192.168.1.244
        Index 2 | DeviceName:pi.hole | Hostname:pi.hole | IP:192.168.1.248
    Input the desired index ID: 2
        totalActiveMonitors     : 1
        totalActiveMonitorsDown : 0
        notes                   : This device was scanned by discovery on 2/18/2023 3:13:17 PM.
        hostName                : pi.hole
        networkAddress          : 192.168.1.248
        role                    : Device
        brand                   : VMware, Inc.
        os                      : Not set
        bestState               : Up
        worstState              : Up
        name                    : pi.hole
        description             : By default, this role is assigned to devices that do not match any other device role
        id                      : 11
#>
function Get-WUGDevice {
    param (
        [Parameter()] [string] $DeviceID,
        [Parameter()] [string] $SearchValue
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

    if ($DeviceID) {
        $uri += "/api/v1/devices/${DeviceID}?view=overview"
        try{
            $result = Get-WUGAPIResponse -uri $uri -method "GET"
            return $result.data
        } catch {
            Write-Error "No results returned for -DeviceID ${DeviceID}. Try using -Search instead."
        }
    } else {
        if (-not $SearchValue) {
            $SearchValue = Read-Host "Enter the IP address, hostname, or display name of the device you want to search for"
        }
        $uri += "/api/v1/device-groups/-1/devices/-?view=overview&search=$SearchValue"
        $result = Get-WUGAPIResponse -uri $uri -method "GET"
        if($result.data.devices.Count -eq 0){
            throw  "No matching devices returned from the search. Try using the exact IP address, hostname, or display name to narrow your results."
        }
        if($result.data.devices.Count -eq 1){
            return $result.data.devices
        }
        if($result.data.devices.Count -gt 1){
            $devices = $result.data.devices
            foreach($device in $devices){
                if($count){
                    $count += 1
                } else {
                    $count = 1
                }
                $deviceName = $device.name
                $devicehostName = $device.hostName
                $deviceNetworkAddress = $device.NetworkAddress
                $finalcount = $count - 1
                Write-Output "Index ${finalcount} | DeviceName:${deviceName} | Hostname:${devicehostName} | IP:${deviceNetworkAddress}"
            }
            $Selected = Read-Host "Input the desired index ID"
            return $devices[$selected]
        }
    }
}