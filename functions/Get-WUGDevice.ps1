<#
.SYNOPSIS
    Get a WhatsUp Gold device data using the WhatsUp Gold REST API
    Usually used to get the device id which can be used for various
    other rest API calls.

.DESCRIPTION
    Get data from the WhatsUp Gold /device/{$DeviceID} endpoint or
    search all devices using /device-groups/-1/devices/-?view=overview
    &search=$SearchValue" to find the device id you need

.PARAMETER DeviceID
    If you already know the device id, get the other information

.PARAMETER View
    If you want to change between the views, acceptable values are:
    "id", "basic", "card", "overview". Defaults to card.

.NOTES
    WhatsUp Gold REST API is cool.

.EXAMPLE
    Get-WUGDevice -DeviceID 33
    Get-WUGDevice -DeviceID $ArrayOfDeviceIDs
    Get-WUGDevice -DeviceID 2,3,4,20
#>
function Get-WUGDevice {
    param (
        [Parameter(Mandatory = $true)] [array] $DeviceID,
        [Parameter()] [ValidateSet("id", "basic", "card", "overview")] [string] $View = "card"
     )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    $uri = $global:WhatsUpServerBaseURI
    $finaloutput = @()

    if ($DeviceID) {
        foreach ($id in $DeviceID) {
            $deviceUri = "${uri}/api/v1/devices/${id}?view=overview"
            try {
                $result = Get-WUGAPIResponse -uri $deviceUri -method "GET"
                Write-Debug "Result from Get-WUGAPIResponse -uri ${deviceUri} -method `"GET`"`r`n:${result}"
                $finaloutput += $result.data
            }
            catch {
                Write-Error "No results returned for -DeviceID ${id}. Try using -Search instead."
            }
        }
    }

    return $finaloutput
}