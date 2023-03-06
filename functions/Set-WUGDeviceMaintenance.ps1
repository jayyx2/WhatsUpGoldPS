function Set-WUGDeviceMaintenance {
    param(
        [Parameter(Mandatory)][array]$DeviceID,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter()][string]$Reason,
        [Parameter()][string]$EndUTC,
        [Parameter()][ValidatePattern("^(?<Value>\d+)\s*(?<Unit>m|minutes|h|hours|d|days|s|seconds)$")][string]$TimeInterval
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
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