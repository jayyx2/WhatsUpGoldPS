<#
    .SYNOPSIS
        Retrieves maintenance schedules for specified devices in WhatsUp Gold.

    .DESCRIPTION
        The Get-WUGDeviceMaintenanceSchedule function fetches the current maintenance schedules configured for one or more devices managed by WhatsUp Gold.
        It supports retrieving schedules for individual devices or multiple devices simultaneously. The function processes the API response
        to provide a structured output containing detailed schedule information, including schedule type, recurrence, effective dates, and
        duration.

    .PARAMETER DeviceId
        Specifies the ID(s) of the device(s) for which the maintenance schedules will be retrieved.
        This parameter is mandatory and accepts one or more integer values.
        It supports pipeline input, allowing you to pass device IDs directly through the pipeline.

    .INPUTS
        System.Int32[]
        The function accepts integer values representing Device IDs from the pipeline.

    .OUTPUTS
        PSCustomObject[]
        Returns an array of custom objects, each representing a maintenance schedule for a device. The output includes properties such as:
            - DeviceID
            - StartTimeHour
            - StartTimeMinute
            - EndTimeHour
            - EndTimeMinute
            - ScheduleType
            - RecurEvery
            - DaysOfWeek
            - DayOfMonth
            - Occurence
            - DayOfWeek
            - Month
            - EffectiveStartDate
            - EffectiveExpirationDate

    .EXAMPLE
        # Retrieve maintenance schedules for device 2367
        Get-WUGDeviceMaintenanceSchedule -DeviceId 2367

    .EXAMPLE
        # Retrieve maintenance schedules for multiple devices and display the results
        Get-WUGDeviceMaintenanceSchedule -DeviceId 2367, 2368, 2369 | Format-Table -AutoSize

    .EXAMPLE
        # Retrieve maintenance schedules for device 2367 and update it using the -Config parameter
        $sched = Get-WUGDeviceMaintenanceSchedule -DeviceId 2367
        # Modify the schedule as needed, for example, changing the ScheduleType
        $sched.ScheduleType = 'YearlyAdvanced'
        $sched.Occurence = 'First'
        $sched.DayOfWeek = 'Monday'
        $sched.Month = 'December'
        Set-WUGDeviceMaintenanceSchedule -DeviceId 2367 -Config $sched

    .NOTES
        - Ensure that the global variables `$WUGBearerHeaders` and `$WhatsUpServerBaseURI` are set before invoking this function.
          These are typically initialized by running the `Connect-WUGServer` function.
        - The function utilizes the WhatsUp Gold REST API to fetch maintenance schedules. Refer to the official WhatsUp Gold REST API documentation for more details:
          https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_GetPollingConfig
        - The `Occurence` property is intentionally misspelled to match the API response. Ensure consistency when using this property.

        Author: Jason Alberino (jason@wug.ninja) 2024-09-29
#>
    #>
function Get-WUGDeviceMaintenanceSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int[]]$DeviceId
    )

    begin {
        Write-Debug "Function: Get-WUGDeviceMaintenanceSchedule -- DeviceIDs: $($DeviceID -join ', ')"

        # Check for required global variables
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            Connect-WUGServer
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Please run Connect-WUGServer."
            Connect-WUGServer
        }
    }

    process {
        $allMaintenanceConfigs = @()  # Array to store all configurations
        $totalDevices = $DeviceID.Count
        $currentDeviceIndex = 0

        foreach ($id in $DeviceID) {
            $currentDeviceIndex++
            $percentComplete = [Math]::Round(($currentDeviceIndex / $totalDevices) * 100)

            Write-Progress -Activity "Fetching maintenance schedules" -Status "Processing Device ID $id ($currentDeviceIndex of $totalDevices)" -PercentComplete $percentComplete

            try {
                # Get the current maintenance configuration for each device
                $url = "$($global:WhatsUpServerBaseURI)/api/v1/devices/$id/config/polling"
                Write-Debug "Fetching maintenance schedule from: $url"
                $response = Get-WUGAPIResponse -Uri $url -Method Get

                # Check if the response contains expected data
                if (-not $response -or -not $response.data) {
                    Write-Error "No data returned from API for DeviceID $id. Check if the API endpoint is correct and accessible."
                    continue
                }

                # Extract the maintenance configuration
                $maintenance = $response.data.maintenance

                if ($maintenance -and $maintenance.schedules) {
                    Write-Debug "Found $($maintenance.schedules.Count) maintenance schedules for DeviceID $id."

                    # Iterate over each schedule
                    foreach ($schedule in $maintenance.schedules) {
                        # Initialize variables
                        $scheduleType = 'Unknown'
                        $recurEvery = $null
                        $daysOfWeek = $null
                        $dayOfMonth = $null
                        $occurence = $null  # Intentionally misspelled to match API
                        $dayOfWeek = $null
                        $month = $null

                        # Extract start and end times as separate hour and minute properties
                        $startHour = $schedule.duration.startTime.hour
                        $startMinute = $schedule.duration.startTime.minute
                        $endHour = $schedule.duration.endTime.hour
                        $endMinute = $schedule.duration.endTime.minute

                        # Extract effective dates
                        $effectiveStartDate = $schedule.effectiveStartDate
                        $effectiveExpirationDate = $schedule.effectiveExpirationDate

                        # Determine Schedule Type
                        if ($schedule.daily) {
                            $scheduleType = 'Daily'
                            $recurEvery = $schedule.daily.repeat
                        } elseif ($schedule.weekly) {
                            $scheduleType = 'Weekly'
                            $recurEvery = $schedule.weekly.repeat
                            $daysOfWeek = $schedule.weekly.daysOfTheWeek
                        } elseif ($schedule.monthly) {
                            $scheduleType = 'Monthly'
                            $recurEvery = $schedule.monthly.repeat
                            $dayOfMonth = $schedule.monthly.day
                        } elseif ($schedule.monthlyAdvance) {
                            $scheduleType = 'Monthly Advanced'
                            $recurEvery = $schedule.monthlyAdvance.repeat
                            $occurence = $schedule.monthlyAdvance.occurence  # Intentionally misspelled
                            $dayOfWeek = $schedule.monthlyAdvance.dayOfWeek
                        } elseif ($schedule.yearly) {
                            $scheduleType = 'Yearly'
                            $dayOfMonth = $schedule.yearly.day
                            $month = $schedule.yearly.month
                        } elseif ($schedule.yearlyAdvance) {
                            $scheduleType = 'Yearly Advanced'
                            $occurence = $schedule.yearlyAdvance.week  # Assuming 'week' is correctly spelled
                            $dayOfWeek = $schedule.yearlyAdvance.dayOfWeek
                            $month = $schedule.yearlyAdvance.month
                        }

                        # Build the schedule object with separate hour and minute properties
                        $scheduleDetails = [PSCustomObject]@{
                            DeviceID                = $id
                            StartTimeHour           = $startHour
                            StartTimeMinute         = $startMinute
                            EndTimeHour             = $endHour
                            EndTimeMinute           = $endMinute
                            ScheduleType            = $scheduleType
                            RecurEvery              = $recurEvery
                            DaysOfWeek              = $daysOfWeek
                            DayOfMonth              = $dayOfMonth
                            Occurence               = $occurence  # Intentionally misspelled
                            DayOfWeek               = $dayOfWeek
                            Month                   = $month
                            EffectiveStartDate      = $effectiveStartDate
                            EffectiveExpirationDate = $effectiveExpirationDate
                        }

                        $allMaintenanceConfigs += $scheduleDetails
                    }
                } else {
                    Write-Debug "No maintenance schedules found for DeviceID $id."
                }
            }
            catch {
                Write-Error "Failed to get maintenance schedule for DeviceID ${id}: $($_.Exception.Message)"
            }
        }

        # Clear the progress bar after completion
        Write-Progress -Activity "Fetching maintenance schedules" -Completed
    }

    end {
        Write-Debug "Get-WUGDeviceMaintenanceSchedule function completed."
        return $allMaintenanceConfigs
    }
}



# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUxwGsS46srMmHXcXd4jxfWZXT
# FZKgghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUpRYvz/7ngqFuaQi+dat3fJpw
# 9NswDQYJKoZIhvcNAQEBBQAEggIAtMdlewFSui3QtFKxVHoadsLxWi6UNPCu60y9
# BNCyN/tnpmcqngoO9+o3AAnEL/CBw0vGvkQFt6Uy8+udrhOLsl/2qutLqm2Kmg2x
# r8S379cgK1+bSijPhQ70eu+acn7iKKk8wOD8Xs3uAZSUE9Prd5bFtq3dByl8ybOP
# 8XV7VspIwdIVycTNUZ0PLUvbEU6lGrlXbAu1hsHv4jRv3gPSMY7A1ZFYluJia+kG
# V03cjpeE/c5JZy892GaQqYS2EQz69Gyo8Awh2Ji0HZqgwxYqbIOYtlHZMBpUArAR
# UvX03jypfwoUij6vx9sHhy6hVg4OAev+C4oZMJCTSZNL32+OF/lbJSIAe6xwbVWr
# ktJLmDjnE6f3rQbhs7HqYLd/NZmK9r9u/djc7lzbCSDWl1QP4GUMwiorvAxqtubS
# 2MGQIeqCxBUjTw44pPA96N9SJynSY5ComnKfEjGIVQaiinb9A7wj8smev/N7I7Q0
# HQF+G09sUmsWGkIA/idlZ2h9+s6C5CNR5J2vyl+LDhl3Uelb8Y06iY8G/KMhmmPi
# YGcDvnCJQqV4unvDiic1Z0vESWyXCCmr95Xt+JV7Fv9AbYeJTEl3Jp4+HaYmCGbI
# HO6/iegC3qsWO3cP6prJHj0pduy194nKqK85Sz5/aCe4NzuskDoBAvoyTAGYlUDb
# vFNUsAk=
# SIG # End signature block
