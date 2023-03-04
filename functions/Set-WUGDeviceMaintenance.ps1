function Set-WUGDeviceMaintenance {
    param(
        [Parameter(Mandatory)][array]$DeviceID,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter()][string]$Reason,
        [Parameter()][string]$EndUTC
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    #Input validation
    if(!$DeviceID){$DeviceID = Read-Host "Enter a DeviceID or IDs, separated by commas";if ([string]::IsNullOrWhiteSpace($DeviceID)) {Write-Error "You must specify the DeviceID.";return;}$DeviceID = $DeviceID.Split(",");}
    #End input validation

    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/maintenance"

    $devicesProcessed = 0
    $totalDevices = $DeviceID.Count
    $successes = 0
    $errors = 0
    $percentComplete = 0
    while ($percentComplete -ne 100) {
        $batch = $DeviceID[0..498]
        $DeviceID = $DeviceID[499..($DeviceID.Count-1)]
        Write-Progress -Activity "Updating device maintenance mode to ${Enabled} for ${totalDevices} devices." -Status "Progress: $percentComplete% ($devicesProcessed/$totalDevices)" -PercentComplete $percentComplete

        $body = @{
            devices = $batch
            enabled = $Enabled
            endUtc = $EndUTC
            reason = $Reason
        } | ConvertTo-Json

        try {
            $result = Get-WUGAPIResponse -uri $uri -method "PATCH" -body $body
            $successes += $result.data.successfulOperations
            $errors += $result.data.resourcesWithErros.Count + $result.data.errors.Count
        }
        catch {
            $errors += $batch.Count
        }

        $devicesProcessed += $batch.Count
        $percentComplete = [Math]::Round($devicesProcessed / $totalDevices * 100)
        If ($percentComplete -gt 100){$percentComplete = 100} Else {$percentComplete}
    }
    
    $resultData = @{
        successfulOperations = $successes
        resourcesNotAllowed = @()
        resourcesWithErros = @()
        errors = @()
        limitReached = $false
        maximumReached = $false
        success = $true
    }

    if ($errors -gt 0) {
        $resultData.success = $false
    }

    return $resultData
}