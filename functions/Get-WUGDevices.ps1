<#
.SYNOPSIS
Get WhatsUp Gold devices data using the WhatsUp Gold REST API.

.DESCRIPTION
Retrieve an array of devices from WhatsUp Gold

.PARAMETER SearchValue
Search using IP Address, Display Name, or Hostname.

.PARAMETER DeviceGroupID
Default is -1 (all devices). You will vastly increase your search 
efficiency by specifying a device group id

.PARAMETER View
Default is card.
    id: id
    basic: id, name, os, brand, role, networkAddress, hostname, notes
    overview: id, description, name, worstState, bestState, os, brand, role, networkAddress,
    hostName, notes, totalActiveMonitorsDown, totalActiveMonitors
    card: id, description, name, worstState, bestState, os, brand, role, networkAddress,
    hostName, notes, totalActiveMonitorsDown, totalActiveMonitors, downActiveMonitors
.PARAMETER Limit
Default and maximum is 500. Specify number of records to return in a single page

.EXAMPLE
Get-WUGDevices -SearchValue "sub.domain.com" -DeviceGroupId 3 -View basic -Limit 200
Get-WUGDevices -SearchValue 192.168.1. -View overview

.NOTES
Author: Jason Alberino (jason@wug.ninja) 2023-03-24
Last modified: Let's see your name here YYYY-MM-DD

#>

function Get-WUGDevices {
    param (
        [Parameter()] [string] $SearchValue,
        [Parameter()] [string] $DeviceGroupID = "-1",
        [Parameter()] [ValidateSet("id", "basic", "card", "overview")] [string] $View = "id",
        [Parameter()] [string] $Limit = "25"
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; } else { Request-WUGAuthToken }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking

    $uri = ${global:WhatsUpServerBaseURI}
    $uri += "/api/v1/device-groups/${DeviceGroupID}/devices/-?view=${View}&limit=${Limit}"

    if ($SearchValue) {
        $uri += "&search=${SearchValue}"
    }
    else {
        $SearchValue = Read-Host "Enter the search value either IP, hostname, or display name."
    }
    $currentPage = 1
    $allDevices = @()
    do {
        $result = Get-WUGAPIResponse -uri $uri -method "GET"
        $devices = ${result}.data.devices
        $allDevices += $devices
        $pageInfo = ${result}.paging
        if (${pageInfo}.nextPageId) {
            $currentPage++
            $uri = $global:WhatsUpServerBaseURI + "/api/v1/device-groups/${DeviceGroupID}/devices/-?view=${View}&limit=${Limit}&pageId=$(${pageInfo}.nextPageId)&search=${SearchValue}"
            $percentComplete = ($currentPage / ${pageInfo}.nextPageId) * 100
            Write-Progress -Activity "Retrieved $($allDevices.Count) devices already, wait for more." -PercentComplete $percentComplete -Status "Page $currentPage of ?? (${Limit} per page)"
        } else {
            #Do Nothing
        }
    } while (${pageInfo}.nextPageId)
    return $allDevices
}