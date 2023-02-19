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
            return $result
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