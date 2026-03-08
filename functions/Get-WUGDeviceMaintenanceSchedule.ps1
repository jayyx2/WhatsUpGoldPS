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
function Get-WUGDeviceMaintenanceSchedule {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
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

        $collectedDeviceIds = @()
    }

    process {
        foreach ($id in $DeviceId) {
            $collectedDeviceIds += $id
        }
    }

    end {
        # If no DeviceId was specified, fetch all device IDs
        if ($collectedDeviceIds.Count -eq 0) {
            Write-Verbose "No DeviceId specified. Fetching all device IDs via Get-WUGDevice."
            $allDevices = Get-WUGDevice -View id
            if ($allDevices) {
                $collectedDeviceIds = @($allDevices.id)
            }
            if ($collectedDeviceIds.Count -eq 0) {
                Write-Warning "No devices found."
                return
            }
            Write-Verbose "Found $($collectedDeviceIds.Count) devices."
        }

        $allMaintenanceConfigs = @()
        $totalDevices = $collectedDeviceIds.Count
        $currentDeviceIndex = 0

        foreach ($id in $collectedDeviceIds) {
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

        Write-Debug "Get-WUGDeviceMaintenanceSchedule function completed."
        return $allMaintenanceConfigs
    }
}

# End of Get-WUGDeviceMaintenanceSchedule function
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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBBBydYErlb9BI2
# hImAolPJwHlnmrV28bnieNlXMJ3Bh6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgkU63P6D7aI8ukQcEhDtIdazH2yENfHlc
# eIGuC80vApkwDQYJKoZIhvcNAQEBBQAEggIAsv6u/lGuXKvB3xRwlTMKzRodqjL1
# oQFrQFys4ZejwgpRb6c7nmlI0xnOErxNb9a6y7vZTf5eUwb3wcoAy8eTgyW9qDng
# 75d4olTHIEYCRbe3UA+K339+bxck93hVoINGA/ak/vamsprl9n4OeJPIKVVP/3OB
# 48tYLI0f0ZGEqfYsZcoLzzVQUNSlcFF5xiR+6KHRFToKB8IrvSPdOYwCbKUoxhQn
# 7qdRl773kec8U/rPyPQ0GGLFi8WZyctXfzKUMecaQd7X/3NxfXRMAttukKYq+TC/
# RWgTRY0Tk993dSfPkro1VwmSnYavY4Np69FcRAh+a6NAOT1KUDWH3LAdWVPGX/gv
# xw0VegGCE012S4TiLFqeZ2IQTpVoCNgQRtVlZ/HAEL68QN1SIAgdhjRMUZsenYvk
# eS4ZmYD1yLbZQTt5z04HI7ei1PCbYo9vhiY5s4BjCNW0xweFo9yGZFbPvGO0bGgD
# 6ht0embO63pocoRuDBrUYbUW2Qbpkvi3YrJIxtnaPR6aC9ZeH2Gt1UyxDWkd084V
# p5ToZUeobrm/szDur9ofmFe5h5hup09QVGUD2xEyz86bNu/Wmj/0ZqMYmRDX7Uw0
# dNOfRHl0zsK8G0RFhF6/4qNKuViFy9lakY7j+TAfjf6dS3yIuwIamMcZYO6F1Xmo
# Mf/jOfduZGuFTvU=
# SIG # End signature block
