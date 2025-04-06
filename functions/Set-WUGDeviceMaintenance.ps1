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
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUhQOWAxaTeRIOeT9g5T3MurvJ
# tAOgghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIGGjCCBAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG
# 9w0BAQwFADBWMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk
# MS0wKwYDVQQDEyRTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYw
# HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1Ymxp
# YyBDb2RlIFNpZ25pbmcgQ0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIB
# igKCAYEAmyudU/o1P45gBkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxD
# eEDIArCS2VCoVk4Y/8j6stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk
# 9vT0k2oWJMJjL9G//N523hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7Xw
# iunD7mBxNtecM6ytIdUlh08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ
# 0arWZVeffvMr/iiIROSCzKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZX
# nYvZQgWx/SXiJDRSAolRzZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+t
# AfiWu01TPhCr9VrkxsHC5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvr
# n35XGf2RPaNTO2uSZ6n9otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn
# 3UayWW9bAgMBAAGjggFkMIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaR
# XBeF5jAdBgNVHQ4EFgQUDyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYD
# VR0gBBQwEjAGBgRVHSAAMAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRw
# Oi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RS
# NDYuY3JsMHsGCCsGAQUFBwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAj
# BggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEM
# BQADggIBAAb/guF3YzZue6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXK
# ZDk8+Y1LoNqHrp22AKMGxQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWk
# vfPkKaAQsiqaT9DnMWBHVNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3d
# MapandPfYgoZ8iDL2OR3sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwF
# kvjFV3jS49ZSc4lShKK6BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZa
# PATHvNIzt+z1PHo35D/f7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8b
# kinLrYrKpii+Tk7pwL7TjRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7Ew
# oIJB0kak6pSzEu4I64U6gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TW
# SenLbjBQUGR96cFr6lEUfAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg
# 51Tbnio1lB93079WPFnYaOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoU
# KD85gnJ+t0smrWrb8dee2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGZDCCBMyg
# AwIBAgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJKoZIhvcNAQEMBQAwVDELMAkGA1UE
# BhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGln
# byBQdWJsaWMgQ29kZSBTaWduaW5nIENBIFIzNjAeFw0yMzA0MTkwMDAwMDBaFw0y
# NjA3MTgyMzU5NTlaMFUxCzAJBgNVBAYTAlVTMRQwEgYDVQQIDAtDb25uZWN0aWN1
# dDEXMBUGA1UECgwOSmFzb24gQWxiZXJpbm8xFzAVBgNVBAMMDkphc29uIEFsYmVy
# aW5vMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtiQNNQXoaqTtyDXo
# ylbCknGkvbHdB46M9bXHhYoOmMrtoJUyoph/Z6/ZeeN/Ao6XNcfp+NoDH50uQs2u
# LWVFq9brDqt3dE5YyhTjklvFL3tSfjwtH/x8aQ2yPIRN/CAg5oL/BKMwToKOJT5v
# 6wx1Ux4IkWb8tR/ID07hNd3JNrHr1bJZLthNhfMLLeSm9djqp4BfekV6bRHjNIk4
# qT4XzYp1gmvHufPpm7dXRwm1+Oufdw0Xd8kL/q7z5CIfUJDBprpn41eZb9Ut4qn/
# 1YOlz/Ud5UzzFjTtiBMyI5NdrfNe61N8WMn9kOHZQP4tW0aRX4xFXMUImSXUCp0J
# and4TpNLa/G8UyN0WcYDi0YAvJgPYYHJyZq3jFj+AsF2VCil9d6TKs61/6oklLAf
# jL3J+yxxhKPaSSAYDCLWVuM5+Lj8xm3+dxEFFpz31DkgXYJEQHZG/3Oy5IYXNRzT
# 1pVKs0v7XaKSO/k8zbGK+6hHJF6bpgZVEjjaCZ9ldc7pBW4LAatJkVkmX/rrdzlR
# qO80mKKbDF0iDxRGgXMTbr3GUF7+mHVxLA6bxpsrG4FWv+7j9ysB/Ye/VnhVP04h
# hCEh+Qefak4NuvhjEaocmaGB4+8CN+qJsEjY2rVKOXGM+ABGEzufIHHjHM7TTuOQ
# cpy8D22cGdG8TzdsC9a7iGHfnsECAwEAAaOCAa4wggGqMB8GA1UdIwQYMBaAFA8q
# yyCHKLjsb0iuK1SmKaoXpM0MMB0GA1UdDgQWBBSR7lSM0bm2siNLX8PNkO0P+O4r
# vTAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEF
# BQcDAzBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDAjAlMCMGCCsGAQUFBwIBFhdo
# dHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAEwSQYDVR0fBEIwQDA+oDyg
# OoY4aHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25p
# bmdDQVIzNi5jcmwweQYIKwYBBQUHAQEEbTBrMEQGCCsGAQUFBzAChjhodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNy
# dDAjBggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wIwYDVR0RBBww
# GoEYamFzb24uYWxiZXJpbm9AZ21haWwuY29tMA0GCSqGSIb3DQEBDAUAA4IBgQBE
# 9BBR9K/oaqEFq+B2vVA7hL9vK04FdmmqNZxUYBmf+aMDO8fZcWqaS1G4EBX3iM8w
# LKd4MEyjGH+O541I7zgWQ/c1f9yP72i5mNnp5jF2ePDpvRluKTZp77Hn9lG9f/nU
# c4LPFBV+cASXH8uDlj97dDmiiZJ/mZbYBRdXLi/0T4lkkXGboYe3SFoKD0K1cfAb
# QvKZIeBeRAsaIEJ5WgzQcxmH9VGDXxEDhXnN9VCvKBDcFsefxGiha0ovWOLbuq5K
# R9InZmHbP9X76gKRsbo4bwjuEnvALX3PfInF+A1pHNUCC0RB4lYp5qDt7JpowecL
# poD+OafTlSV4SNA9IFBUHzkmqaWuXjtpW5zVRvdKwrAA5laQw5jbdqjxtNZbgW1+
# lbVjD9rYYz+fwlr1MuvsX64Zar8Gcmbd0irbnxVpKpzVjJ5oLQTUpgRefqvMOUiV
# vtuKq53CiVkiIpv50bQtdV56CPUl5WrnEtzZW3K0FYnFzrW4ZLBKjE5+dovDTn8x
# ggMCMIIC/gIBATBpMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBS
# MzYCEQDohRsr/zNHDY0q8+DiMoexMAkGBSsOAwIaBQCgcDAQBgorBgEEAYI3AgEM
# MQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQU8VmIBDv8fn6ocU33QKiKd5ca
# 0KEwDQYJKoZIhvcNAQEBBQAEggIAF9Gjix+NjDFuVXZgmwk0boTgJM9cYaJPUFPW
# NzrSwHKP2qpTURZ8XK4HAlfMPMy2N+X/9MYygqp1plRwm4LLlajHI2vOCTq7vxXy
# zO4xJbYaj/bhA4E2DYfkcOlNtqwKAnzJUEETvEY+/67++tDPfbsVbQqtr/kZa6Rb
# 1JDldgjScKQOV37XQnD8hzWuUAsLa5/BXF3vrx//9tf1f4REfIAL4tThhYH39+UW
# M29xAsg9P1vjrAtMDgn0NXmaE2h5Qwo+PXqQuj9pBRZ+Ro6tj5gPpdO8GMJ9iCmN
# 739qv+ZPguYiMUONltrUidUbQdQ8or8p9lpQ8XuKOeBSZO4UzLAxsZlB9m9fhfSx
# YCBFKv0QK6j/HCl8B9HMeYKOf2xRI/wgXxG3HIxmyDiGUUFgoKkweOLjNuGH0jk2
# TSd4dqmyVZpQkxaUvCH5fUZag0ImKIFnjtcZhiKvXvJLYUAmjI1Lv3DjD5ygIyUc
# iePIoGAIj1afEf/itRLuvfvIXdPLx+UIDeQpygF9yFPxcqRx52RTJ27beti/mJyM
# 6DQALXQiCG4X62rFpIdLVqohAlW3ximXXftgyfpuyMZwAtnBdNM/T0FM1w5YihFE
# siRJum3aX6jxzBSbpjbSv9jdblo0B00GtXWgYVJE9UbLWyI2x7g3fSMH8XTo5Qzu
# ckBeUmw=
# SIG # End signature block
