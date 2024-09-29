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
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCeACVH8CxqKEaN
# LjP+lyh/ig0Lp79gafeQD8J3GClyOaCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BgkqhkiG9w0BCQQxIgQgCbT0bYkgOa872SxS+9iocAl68Az7f9kz9VrmVR9z5TMw
# DQYJKoZIhvcNAQEBBQAEggIAl6QLDIDlZFP+yKf+ArwvYdvkJHEHzq+PTlAzwvEZ
# ijgoDmAhg35Bx2hyipHJfLfPOyFy+aRvmsa6JGYEe103KsDvrAPz0hgAiDRuU/JX
# hzn0iyNgW5fNUlEktGea/cmqbmwTwMHEQgSyBi+6fgPIPJlbLriNPVaTYXtRg3YQ
# zrgUwU/QtYfdNDhey7uznpPuOuZ4yOeZUxMsNuBIVSLmSAauNL0qqC7Y0uMhgJZp
# zaPQI0e9SVplAYcLGPhGOdxEGJyeW6jQ9/g9EU8PC2Fhfgu0O/szkHmKCxUW6Sy2
# wECwSO1KMJOKKFX5i1tHYHasI+tUy85od7QKOZllruRKWIVNjvrdVXIXKer9O/Xz
# V9DM0g0uR6xpbFryXaJBxV5JqipMAPm0Z44H60gVUaltnKKjJ0M+kf3CyBlprwEp
# A4yN4YeuSnsnxP3QlM4/kx02CDtd7Jf3IjVeYhRAHipyW6Gtg5FVPKSLztEqYiat
# oz050duvzODVftm9SuLw8k7H99ygUqjoKsl4/vFbridBQDdlXmhOROvZGxRrtf1y
# MbG7h6nTx2bzNjFXnDDnEOOVwMBgOwRDyPwyKJC3Wmlw9aLmIw4T63cGsv6pgYvE
# TNDuoD3ZpMvdlUykwxlO683oGfORlGCeky2vcCcA6IZiE1SNBpbjxAx1YpooPLiQ
# 2Mk=
# SIG # End signature block
