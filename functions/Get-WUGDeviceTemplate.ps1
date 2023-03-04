<#
.SYNOPSIS
    GET the device template for a given deviceid.
    Endpoint: /api/v1/devices/${id}/config/template?options=${options}

.DESCRIPTION
    This will give you the template for a device. You can use this template
    to create new devices in WhatsUp Gold. Store it as a variable if you'd
    like to change it.
    $template = Get-WUGDeviceTemplate -Device 20

.PARAMETER DeviceID
    An array of device IDs to get the templates

.PARAMETER Options
    all: all basic options are included. (default)
    l2: include layer 2 data such as inventory, links and other information used by the system
    tempip: use ip address as the template id instead of the database identifier.
    simple: return all data in it simplest form, dropping items like parents, classid, etc.

.EXAMPLE
    Get-WUGDeviceTemplate -DeviceID 20 -options tempip
    Get-WUGDeviceTemplate -DeviceID $arrayOfIds
#>
function Get-WUGDeviceTemplate {
    param(
        [Parameter()] [array] $DeviceID,
        [Parameter()] [ValidateSet('all', 'l2', 'tempip', 'simple')] [string] $Options = 'all'
    )
    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking
    #Input validation here
    $DeviceID = Read-Host "Enter an array of numbers, separated by commas"
    $DeviceID = $DeviceID.Split(",")
    if(!$DeviceID){Write-Error "No DeviceID entered, so now I'm not doing it."; throw;}
    #End input validation
    $finaloutput = @()
    if ($DeviceID) {
        foreach ($id in $DeviceID) {
            $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${id}/config/template?options=${options}"
            try {
                $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                Write-Debug "Result from Get-WUGAPIResponse -uri ${deviceUri} -method `"GET`"`r`n:${result}"
                $finaloutput += $result.data.templates
            }
            catch {
                Write-Error "No results returned for -DeviceID ${id}."
                Write-Error "$(${result}.data.errors)"
            }
        }
        return $finaloutput
    }
}