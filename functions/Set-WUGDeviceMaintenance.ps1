<#
.SYNOPSIS
Updates the maintenance mode settings for one or more devices in WhatsUp Gold.

.DESCRIPTION
The Set-WUGDeviceMaintenance function allows you to update the maintenance mode settings for one or more devices in WhatsUp Gold. You can enable or disable maintenance mode for the specified devices, and set a reason and/or an end time for the maintenance period. You can also specify a time interval for the maintenance period using the -TimeInterval parameter.

.PARAMETER DeviceID
Specifies the ID or IDs of the device or devices for which to update maintenance mode. Multiple DeviceIDs can be specified by separating them with commas.

.PARAMETER Enabled
Specifies whether to enable or disable maintenance mode for the specified devices.

.PARAMETER Reason
Specifies the reason for the maintenance period.

.PARAMETER EndUTC
Specifies the end time of the maintenance period in UTC format (e.g. "2022-02-28T18:30:00Z").

.PARAMETER TimeInterval
Specifies the duration of the maintenance period as a time interval. The time interval should be in the format "Xm|Xminutes|Xh|Xhours|Xd|Xdays" where X is an integer value representing the duration.

.NOTES
- The function requires a connection to a WhatsUp Gold server with valid authorization token. You can establish the connection using the Connect-WUGServer function.
- The function processes the device updates in batches of 499 to avoid exceeding the maximum limit.
- The function returns a hashtable containing the number of successful and failed updates.

.EXAMPLE
Set-WUGDeviceMaintenance -DeviceID "12345" -Enabled $true -TimeInterval "2h"
Enables maintenance mode for the device with ID "12345" for a period of 2 hours.

.EXAMPLE
Set-WUGDeviceMaintenance -DeviceID "12345,54321" -Enabled $false -Reason "Upgrading firmware"
Disables maintenance mode for the devices with IDs "12345" and "54321" and sets the reason for the maintenance period to "Upgrading firmware".
#>
function Set-WUGDeviceMaintenance {
    param(
        [Parameter(Mandatory)][array]$DeviceID,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter()][string]$Reason,
        [Parameter()][string]$EndUTC,
        [Parameter()][ValidatePattern("^(?<Value>\d+)\s*(?<Unit>m|minutes|h|hours|d|days|s|seconds)$")][string]$TimeInterval
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;} else {Get-WUGAuthToken}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    #Input validation
    if (!$DeviceID) {
        $DeviceID = Read-Host "Enter a DeviceID or IDs, separated by commas"
        if ([string]::IsNullOrWhiteSpace($DeviceID)) {
            Write-Error "You must specify the DeviceID."
            return
        }
        $DeviceID = $DeviceID.Split(",")
    }

    if ($Enabled) {
        if ($TimeInterval) {
            $regex = "^(?<Value>\d+)\s*(?<Unit>m|minutes|h|hours|d|days)$|^(?<Value>\d+)(?<Unit>m|minutes|h|hours|d|days)$"
            $match = [regex]::Match($TimeInterval, $regex)
            if (-not $match.Success) {
                Write-Error "Invalid value for -TimeInterval. Use format 'Xm|Xminutes|Xh|Xhours|Xd|Xdays'."
                return
            }
            $value = [int]$match.Groups["Value"].Value
            $unit = $match.Groups["Unit"].Value
            switch ($unit) {
                "m" {$timeSpan = New-TimeSpan -Minutes $value}
                "minutes" {$timeSpan = New-TimeSpan -Minutes $value}
                "h" {$timeSpan = New-TimeSpan -Hours $value}
                "hours" {$timeSpan = New-TimeSpan -Hours $value}
                "d" {$timeSpan = New-TimeSpan -Days $value}
                "days" {$timeSpan = New-TimeSpan -Days $value}
            }         
            $endTime = (Get-Date).Add($timeSpan)
            $endUTC = $endTime.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'")
        } else {
            Write-Error "You must specify the -TimeInterval parameter."
            return
        }
    }
    #End input validation
        
    $totalDevices = $DeviceID.Count
    $batchSize = 499
    if ($totalDevices -le $batchSize) {
        $batchSize = $totalDevices
    }
    
    $devicesProcessed = 0
    $successes = 0
    $errors = 0
    $percentComplete = 0
    
    while ($percentComplete -ne 100) {
        $batch = $DeviceID[$devicesProcessed..($devicesProcessed + $batchSize - 1)]
    
        $Progress = Write-Progress -Activity "Updating device maintenance mode to ${Enabled} for ${totalDevices} devices." -Status "Progress: $percentComplete% ($devicesProcessed/$totalDevices)" -PercentComplete $percentComplete
    
        $body = @{
            devices = $batch
            enabled = $Enabled
            endUtc  = $EndUTC
            reason  = $Reason
        } | ConvertTo-Json
        Write-Debug -Message "${body}"
    
        try {
            $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/maintenance" -method "PATCH" -body $body
            $successes += $result.data.successfulOperations
            $errors += $result.data.resourcesWithErros.Count + $result.data.errors.Count
        }
        catch {
            $errors += $batch.Count
        }
    
        $devicesProcessed += $batchSize
        $percentComplete = [Math]::Round($devicesProcessed / $totalDevices * 100)
        If ($percentComplete -gt 100) { $percentComplete = 100 }
    }
        
    $resultData = @{
        successfulOperations = $successes
        resourcesNotAllowed  = @()
        resourcesWithErrors  = @()
        errors               = @()
        success              = $true
    }
    
    if ($errors -gt 0) {
        $resultData.success = $false
    }
    
    return $resultData
    
}