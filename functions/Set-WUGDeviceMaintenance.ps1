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
    [CmdletBinding()]
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

            try {
                $result = Get-WUGAPIResponse -uri "$global:WhatsUpServerBaseURI/api/v1/devices/-/config/maintenance" ` -Method "PATCH" -Body $bodyJson 

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

        Write-Output $resultData
    }
}

# SIG # Begin signature block
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCRkUll2rIU2NF7
# wbew6VfYpcrvd04px06dqqTsvbYNyKCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# L9Uo2bC5a4CH2RwwggZkMIIEzKADAgECAhEA6IUbK/8zRw2NKvPg4jKHsTANBgkq
# hkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1p
# dGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgQ0EgUjM2
# MB4XDTIzMDQxOTAwMDAwMFoXDTI2MDcxODIzNTk1OVowVTELMAkGA1UEBhMCVVMx
# FDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNvbiBBbGJlcmlubzEX
# MBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQC2JA01BehqpO3INejKVsKScaS9sd0Hjoz1tceFig6Yyu2glTKimH9n
# r9l5438Cjpc1x+n42gMfnS5Cza4tZUWr1usOq3d0TljKFOOSW8Uve1J+PC0f/Hxp
# DbI8hE38ICDmgv8EozBOgo4lPm/rDHVTHgiRZvy1H8gPTuE13ck2sevVslku2E2F
# 8wst5Kb12OqngF96RXptEeM0iTipPhfNinWCa8e58+mbt1dHCbX46593DRd3yQv+
# rvPkIh9QkMGmumfjV5lv1S3iqf/Vg6XP9R3lTPMWNO2IEzIjk12t817rU3xYyf2Q
# 4dlA/i1bRpFfjEVcxQiZJdQKnQlqd3hOk0tr8bxTI3RZxgOLRgC8mA9hgcnJmreM
# WP4CwXZUKKX13pMqzrX/qiSUsB+Mvcn7LHGEo9pJIBgMItZW4zn4uPzGbf53EQUW
# nPfUOSBdgkRAdkb/c7Lkhhc1HNPWlUqzS/tdopI7+TzNsYr7qEckXpumBlUSONoJ
# n2V1zukFbgsBq0mRWSZf+ut3OVGo7zSYopsMXSIPFEaBcxNuvcZQXv6YdXEsDpvG
# mysbgVa/7uP3KwH9h79WeFU/TiGEISH5B59qTg26+GMRqhyZoYHj7wI36omwSNja
# tUo5cYz4AEYTO58gceMcztNO45BynLwPbZwZ0bxPN2wL1ruIYd+ewQIDAQABo4IB
# rjCCAaowHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhekzQwwHQYDVR0OBBYE
# FJHuVIzRubayI0tfw82Q7Q/47iu9MA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8E
# AjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEwNQYMKwYBBAGyMQEC
# AQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeB
# DAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNlY3RpZ28uY29tL1Nl
# Y3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5BggrBgEFBQcBAQRtMGsw
# RAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1Ymxp
# Y0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5z
# ZWN0aWdvLmNvbTAjBgNVHREEHDAagRhqYXNvbi5hbGJlcmlub0BnbWFpbC5jb20w
# DQYJKoZIhvcNAQEMBQADggGBAET0EFH0r+hqoQWr4Ha9UDuEv28rTgV2aao1nFRg
# GZ/5owM7x9lxappLUbgQFfeIzzAsp3gwTKMYf47njUjvOBZD9zV/3I/vaLmY2enm
# MXZ48Om9GW4pNmnvsef2Ub1/+dRzgs8UFX5wBJcfy4OWP3t0OaKJkn+ZltgFF1cu
# L/RPiWSRcZuhh7dIWgoPQrVx8BtC8pkh4F5ECxogQnlaDNBzGYf1UYNfEQOFec31
# UK8oENwWx5/EaKFrSi9Y4tu6rkpH0idmYds/1fvqApGxujhvCO4Se8Atfc98icX4
# DWkc1QILREHiVinmoO3smmjB5wumgP45p9OVJXhI0D0gUFQfOSappa5eO2lbnNVG
# 90rCsADmVpDDmNt2qPG01luBbX6VtWMP2thjP5/CWvUy6+xfrhlqvwZyZt3SKtuf
# FWkqnNWMnmgtBNSmBF5+q8w5SJW+24qrncKJWSIim/nRtC11XnoI9SXlaucS3Nlb
# crQVicXOtbhksEqMTn52i8NOfzGCAxswggMXAgEBMGkwVDELMAkGA1UEBhMCR0Ix
# GDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJs
# aWMgQ29kZSBTaWduaW5nIENBIFIzNgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJYIZI
# AWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAv
# BgkqhkiG9w0BCQQxIgQg1sVeX9xsd5tRekgZhAvMcJq4LS2Jc5QtsVALQBywqf4w
# DQYJKoZIhvcNAQEBBQAEggIATn/UgDgOxAS/esbPnpZS4mrvpXQig4yG9TWhtoxP
# 49GcVwYhnl4zkfGoKqOOGJtgowdrn3gsLet95d+9rS24t6Ci9SEHwtPu94os8PB1
# Crs4dlCdlp+eAP7oakNL/jeFKHiJANEAbY8Ii6yTAmL1+AZ1u7hPgMmktGBtoujg
# WYAotPDfVGnkOptaqpu9I6yMrZhVTObLorTowykitDsIil/nM/CUCRCl2/uRozHv
# wCJS5UNLgmfAXy5egVmFI1f1BFSjLCM5Spuqk+5dwCx65z4Mnm17W4qCt59eaXn2
# LsnJimSvodOIE5zmz7Ep9sC79ynz9jIkogainauAZvtIk11ZMfYCqvdMzKAmkOrM
# f8xA1xxzUh7FKZGPuAsVf7wu48BC4BlFrc+STMlzUIEQOpUiA/4a8Zw3jpRCKo4N
# Kds82svDR0yc6L3B28flh+jrwJtv7VvgLt+ypctECzipZ+LddPGGfjo7roFQcvJs
# AmmvTzYgyVWOBCcoAlMSIG/TynjoEHNFY+Gfc4/0lIjJxwBZEaoTxbtAYWvymG1A
# MvdxIYbT28E/cSR17h+dHYOvEonK9t2D9nl+TysE2OneBk7qFvAow4833avoKbMs
# 3tD2AJoFyieztCOMwvObKiWrxT7xOIdJja1RwkjD8TJ/PAHgIPgu6ic2ZbX0ztRg
# woo=
# SIG # End signature block
