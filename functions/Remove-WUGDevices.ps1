function Remove-WUGDevices {
    param(
        [Parameter(Mandatory)][array]$DeviceID,
        [Parameter()][bool]$DeleteDiscoveredDevices
    )

    # Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    # End global variables error checking

    $totalDevices = $DeviceID.Count
    $batchSize = 499
    if ($totalDevices -le $batchSize) {
        $batchSize = $totalDevices
    }

    $devicesProcessed = 0
    $successes = 0

    do {
        $devices = $DeviceID[$devicesProcessed..($devicesProcessed + $batchSize - 1)]
        $devicesProcessed += $batchSize

        $body = @{
            operation = "delete"
            devices = $devices
        }

        if ($DeleteDiscoveredDevices) {
            $body["removeDiscoveredResources"] = $true
        }

        $jsonBody = $body | ConvertTo-Json -Depth 5

        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-" -method "PATCH" -body $jsonBody

        if ($result.data.success -eq $true) {
            $successes += $devices.Count
        }

        $percentComplete = ($devicesProcessed / $totalDevices) * 100
        if ($percentComplete -gt 100) {$percentComplete = 100;}
                
        Write-Progress -Activity "Removing devices" -PercentComplete $percentComplete -Status "$devicesProcessed of $totalDevices devices processed"
    } while ($devicesProcessed -lt $totalDevices)

    $result = @{
        successfulOperations = $successes
        resourcesNotAllowed = $null
        resourcesWithErros = $null
        errors = $null
        limitReached = $false
        maximumReached = $false
        success = $true
    }

    return $result
}
