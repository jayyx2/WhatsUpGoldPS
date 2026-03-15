<#
.SYNOPSIS
Updates the maintenance mode settings for one or more devices in WhatsUp Gold.

.DESCRIPTION
The Set-WUGDeviceMaintenance function allows you to update the maintenance mode settings for one or more devices in WhatsUp Gold. You can enable or disable maintenance mode for the specified devices, and set a reason and/or an end time for the maintenance period. You can also specify a time interval for the maintenance period using the -TimeInterval parameter.

.PARAMETER DeviceId
Specifies the ID or IDs of the device or devices for which to update maintenance mode. Multiple DeviceIDs can be specified by separating them with commas or by passing them through the pipeline.

.PARAMETER Enabled
Specifies whether to enable or disable maintenance mode for the specified devices.

.PARAMETER Reason
Specifies the reason for the maintenance period.

.PARAMETER EndUTC
Specifies the end time of the maintenance period in UTC format (e.g., "2024-09-21T13:57:40Z").

.PARAMETER TimeInterval
Specifies the duration of the maintenance period as a time interval. The time interval should be in the format "Xm|Xminutes|Xh|Xhours|Xd|Xdays" where X is an integer value representing the duration.

.EXAMPLE
# Enable maintenance mode for devices with IDs "2355" and "2367" for a period of 2 hours.
"2355","2367" | Set-WUGDeviceMaintenance -Enabled $true -TimeInterval "2h" -Reason "Scheduled Maintenance"

.EXAMPLE
# Disable maintenance mode for devices with IDs "2355" and "2367" with a reason.
$deviceIds = @("2355", "2367")
Set-WUGDeviceMaintenance -DeviceId $deviceIds -Enabled $false -Reason "Maintenance Completed"

.EXAMPLE
# Enable maintenance mode for devices via pipeline with time interval.
$devices = Get-WUGDevices -View 'overview'
$devices | Where-Object { $_.name -cmatch 'dish' } | Select-Object -ExpandProperty id | Set-WUGDeviceMaintenance -Enabled $true -TimeInterval "2h" -Reason "Scheduled Maintenance"

.NOTES
- The function requires a connection to a WhatsUp Gold server with a valid authorization token. You can establish the connection using the Connect-WUGServer function.
- The function processes device updates in batches to avoid exceeding the maximum limit.
- The function returns a hashtable containing the number of successful and failed updates.

Author: Jason Alberino (jason@wug.ninja) 2023-03-24
Last modified: 2024-09-21
#>

function Set-WUGDeviceMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter()][string]$Reason,
        [Parameter()][string]$EndUTC,
        [Parameter()][ValidatePattern("^(?<Value>\d+)\s*(?<Unit>m|minutes|h|hours|d|days)$")][string]$TimeInterval
    )

    begin {
        Write-Debug "Function: Set-WUGDeviceMaintenance -- DeviceId:${DeviceId} Enabled:${Enabled} Reason:${Reason} Limit:${EndUTC} TimeInterval:${TimeInterval}"
        # Initialize collection for DeviceIds
        $collectedDeviceIds = @()
        $successes = 0
        $errors = 0
    }

    process {
        # Collect DeviceIds from pipeline
        foreach ($id in $DeviceId) { $collectedDeviceIds += $id }
    }

    end {
        # Total number of devices to process
        $totalDevices = $collectedDeviceIds.Count
        if ($totalDevices -eq 0) {
            Write-Warning "No valid DeviceIDs provided."
            return
        }

        # Input validation and processing based on Enabled flag
        if ($Enabled) {
            if ($TimeInterval) {
                # Validate and parse TimeInterval
                $regex = "^(?<Value>\d+)\s*(?<Unit>m|minutes|h|hours|d|days)$"
                $match = [regex]::Match($TimeInterval, $regex)
                if (-not $match.Success) {
                    Write-Error "Invalid value for -TimeInterval. Use format 'Xm|Xminutes|Xh|Xhours|Xd|Xdays'."
                    throw "Invalid TimeInterval format."
                }
                $value = [int]$match.Groups["Value"].Value
                $unit = $match.Groups["Unit"].Value.ToLower()
                switch ($unit) {
                    "m" { $timeSpan = New-TimeSpan -Minutes $value }
                    "minutes" { $timeSpan = New-TimeSpan -Minutes $value }
                    "h" { $timeSpan = New-TimeSpan -Hours $value }
                    "hours" { $timeSpan = New-TimeSpan -Hours $value }
                    "d" { $timeSpan = New-TimeSpan -Days $value }
                    "days" { $timeSpan = New-TimeSpan -Days $value }
                    default { Write-Error "Unsupported time unit: $unit"; throw "Unsupported Time Unit." }
                }
                $endTime = (Get-Date).Add($timeSpan)
                $EndUTC = $endTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            elseif ($EndUTC) {
                # Validate EndUTC format
                if (-not ($EndUTC -match "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")) {
                    Write-Error "Invalid format for -EndUTC. Use 'yyyy-MM-ddTHH:mm:ssZ'."
                    throw "Invalid EndUTC format."
                }
            }
            else {
                # Neither TimeInterval nor EndUTC provided; endUtc is omitted
                $EndUTC = $null
            }
        }
        else {
            # When disabling, ignore TimeInterval and EndUTC
            $EndUTC = $null
        }

        # Determine batch size (max 499)
        $batchSize = 499
        if ($totalDevices -le $batchSize) { $batchSize = $totalDevices }

        $devicesProcessed = 0
        $percentComplete = 0

        # Single-device optimised path: PUT /devices/{id}/config/maintenance
        if ($totalDevices -eq 1) {
            $singleId = $collectedDeviceIds[0]
            $body = @{ enabled = $Enabled }
            if ($Reason) { $body.reason = $Reason }
            if ($EndUTC) { $body.endUtc = $EndUTC }
            $bodyJson = $body | ConvertTo-Json -Depth 5
            Write-Debug "Single-device API Request Body: $bodyJson"

            if (-not $PSCmdlet.ShouldProcess("Device $singleId", "Set maintenance mode to $Enabled")) {
                return @{ successfulOperations = 0; errors = 0; success = $true }
            }

            try {
                $result = Get-WUGAPIResponse -uri "$global:WhatsUpServerBaseURI/api/v1/devices/$singleId/config/maintenance" -Method "PUT" -Body $bodyJson
                $successes = 1
            }
            catch {
                Write-Error "Error updating maintenance mode for DeviceID ${singleId}: $($_.Exception.Message)"
                $errors = 1
            }

            $resultData = @{
                successfulOperations = $successes
                errors               = $errors
                success              = ($errors -eq 0)
            }
            return $resultData
        }

        # Batch path: PATCH /devices/-/config/maintenance
        while ($devicesProcessed -lt $totalDevices) {
            $remainingDevices = $totalDevices - $devicesProcessed
            $currentBatchSize = [Math]::Min($batchSize, $remainingDevices)
            $batch = $collectedDeviceIds[$devicesProcessed..($devicesProcessed + $currentBatchSize - 1)]

            # Update progress
            $percentComplete = [Math]::Round((($devicesProcessed + $currentBatchSize) / $totalDevices) * 100)
            if ($percentComplete -gt 100) { $percentComplete = 100 }

            Write-Progress -Activity "Updating device maintenance mode to $Enabled for $totalDevices devices." -Status "Progress: $percentComplete% ($($devicesProcessed + $currentBatchSize)/$totalDevices)"  -PercentComplete $percentComplete

            # Construct API request body
            $body = @{
                devices = $batch
                enabled = $Enabled
            }

            if ($Reason) { $body.reason = $Reason }
            if ($EndUTC) { $body.endUtc = $EndUTC }

            $bodyJson = $body | ConvertTo-Json -Depth 5
            Write-Debug "API Request Body: $bodyJson"

            if (-not $PSCmdlet.ShouldProcess("$($batch.Count) devices", "Set maintenance mode to $Enabled")) { continue }

            try {
                $result = Get-WUGAPIResponse -uri "$global:WhatsUpServerBaseURI/api/v1/devices/-/config/maintenance" -Method "PATCH" -Body $bodyJson

                if ($result.data.successfulOperations) { $successes += $result.data.successfulOperations }
                if ($result.data.resourcesWithErrors) { $errors += $result.data.resourcesWithErrors.Count }
                if ($result.data.errors) { $errors += $result.data.errors.Count }
            }
            catch {
                Write-Error "Error updating maintenance mode for DeviceIDs ${batch}: $($_.Exception.Message)"
                $errors += $currentBatchSize
            }

            $devicesProcessed += $currentBatchSize
        }

        # Final progress update
        Write-Progress -Activity "Updating device maintenance mode" -Status "All devices processed" -Completed
        Write-Debug "Set-WUGDeviceMaintenance function completed."

        # Construct result hashtable
        $resultData = @{
            successfulOperations = $successes
            resourcesNotAllowed  = $result.data.resourcesNotAllowed
            resourcesWithErrors  = $result.data.resourcesWithErrors
            errors               = $errors
            success              = ($errors -eq 0)
        }

        return $resultData
    }
}
# End of Set-WUGDeviceMaintenance function
# End of script
#------------------------------------------------------------------
# This script is part of the WhatsUpGoldPS PowerShell module.
# It is designed to interact with the WhatsUp Gold API for network monitoring.
# The script is provided as-is and is not officially supported by WhatsUp Gold.
# Use at your own risk.
#------------------------------------------------------------------

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC/pU46ritgaOGE
# 5OtbajZAAR7CAKFjdrVqFlYhKq7roaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
# jTanyYqJ1pQWMA0GCSqGSIb3DQEBDAUAMHsxCzAJBgNVBAYTAkdCMRswGQYDVQQI
# DBJHcmVhdGVyIE1hbmNoZXN0ZXIxEDAOBgNVBAcMB1NhbGZvcmQxGjAYBgNVBAoM
# EUNvbW9kbyBDQSBMaW1pdGVkMSEwHwYDVQQDDBhBQUEgQ2VydGlmaWNhdGUgU2Vy
# dmljZXMwHhcNMjEwNTI1MDAwMDAwWhcNMjgxMjMxMjM1OTU5WjBWMQswCQYDVQQG
# EwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0aWdv
# IFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCN55QSIgQkdC7/FiMCkoq2rjaFrEfUI5ErPtx94jGgUW+s
# hJHjUoq14pbe0IdjJImK/+8Skzt9u7aKvb0Ffyeba2XTpQxpsbxJOZrxbW6q5KCD
# J9qaDStQ6Utbs7hkNqR+Sj2pcaths3OzPAsM79szV+W+NDfjlxtd/R8SPYIDdub7
# P2bSlDFp+m2zNKzBenjcklDyZMeqLQSrw2rq4C+np9xu1+j/2iGrQL+57g2extme
# me/G3h+pDHazJyCh1rr9gOcB0u/rgimVcI3/uxXP/tEPNqIuTzKQdEZrRzUTdwUz
# T2MuuC3hv2WnBGsY2HH6zAjybYmZELGt2z4s5KoYsMYHAXVn3m3pY2MeNn9pib6q
# RT5uWl+PoVvLnTCGMOgDs0DGDQ84zWeoU4j6uDBl+m/H5x2xg3RpPqzEaDux5mcz
# mrYI4IAFSEDu9oJkRqj1c7AGlfJsZZ+/VVscnFcax3hGfHCqlBuCF6yH6bbJDoEc
# QNYWFyn8XJwYK+pF9e+91WdPKF4F7pBMeufG9ND8+s0+MkYTIDaKBOq3qgdGnA2T
# OglmmVhcKaO5DKYwODzQRjY1fJy67sPV+Qp2+n4FG0DKkjXp1XrRtX8ArqmQqsV/
# AZwQsRb8zG4Y3G9i/qZQp7h7uJ0VP/4gDHXIIloTlRmQAOka1cKG8eOO7F/05QID
# AQABo4IBEjCCAQ4wHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYD
# VR0OBBYEFDLrkpr/NZZILyhAQnAgNpFcF4XmMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMDMBsGA1UdIAQUMBIwBgYE
# VR0gADAIBgZngQwBBAEwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21v
# ZG9jYS5jb20vQUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEE
# KDAmMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZI
# hvcNAQEMBQADggEBABK/oe+LdJqYRLhpRrWrJAoMpIpnuDqBv0WKfVIHqI0fTiGF
# OaNrXi0ghr8QuK55O1PNtPvYRL4G2VxjZ9RAFodEhnIq1jIV9RKDwvnhXRFAZ/ZC
# J3LFI+ICOBpMIOLbAffNRk8monxmwFE2tokCVMf8WPtsAO7+mKYulaEMUykfb9gZ
# pk+e96wJ6l2CxouvgKe9gUhShDHaMuwV5KZMPWw5c9QLhTkg4IUaaOGnSDip0TYl
# d8GNGRbFiExmfS9jzpjoad+sPKhdnckcW67Y8y90z7h+9teDnRGWYpquRRPaf9xH
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgBYCwr7ConGjeLDtQpaMX8xhqlXjJ6mtu
# FXHA1VGh8JcwDQYJKoZIhvcNAQEBBQAEggIAgonyjWawVTbeoPbCd81gB8j5QGd7
# ZLhGDNsHrWY7Qe3onaWqCvpfMAJKeDoVMkKLmJ3oPQQXxzbQ5Jb6CP3bPAIeFrHH
# TXyTcoYNHuUTdmjfuClYvtjrBs4Or6lKYOigjywjcWthniTEbQZQCkEO0CpxYthm
# lWcxss6sjKyTCWPzVDgibGgnmHZnbB4w7YGiQ8xUP1WFRwnr9fRMqWkUq1VU/y+2
# yNOZzHXclpW3/ZXhQwU5YQp+LrUlfnCSZT+ym8ni/IH2BL71xKK6Obt3ZR6Qdpu/
# yUwkRMVneW+3lh126T6alNAmWSZDaeyrzO9trLmEfWtUvNz1ICwwErqkWT7a8HMF
# rpcg+o/jxVicAW2YFoVnXPPUWjXcjK7tqR1YY19o1/9nTQDMIUdZ9fziYjQ6G9bu
# sMn3pIvoIa6raC2ul9IcQAQVXPom7uOq9K99GzswZfOx/QgbK1+5vf0gnGvMOGa8
# jlJUHTHW6r77OL4xL2CIvLdtc7hyI3rNrmNG5dSrAmmlrRnne7J2COVJxkPHpkpk
# 52MwoeA1Aw9gdj6eQeH8OA15hBfV9n34EMDsz8X5qGZdjiMI/8sDO9EtUeOC6GXO
# LMQh6pjLLg3ubYEqBRSH0k0ZwVZMr3uyCXKuTJ8rfYjpEl70KNF3bDw8sVkLv/J7
# TfLSm+S9HpZUh9o=
# SIG # End signature block
