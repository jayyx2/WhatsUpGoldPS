<#
.SYNOPSIS
Configures maintenance schedules for specified devices in WhatsUp Gold.

.DESCRIPTION
The Set-WUGDeviceMaintenanceSchedule function allows administrators to create, update, or delete maintenance schedules for devices managed by WhatsUp Gold. 
It supports various scheduling types, including Daily, Weekly, Monthly, Monthly Advanced, Yearly, and Yearly Advanced schedules. 
Users can define schedules by specifying individual parameters or by providing a configuration object. 
Additionally, the function enables the deletion of all existing maintenance schedules for one or more devices.

.PARAMETER DeviceId
Specifies the ID(s) of the device(s) for which the maintenance schedule will be set.
This parameter is mandatory across all parameter sets.

.PARAMETER ScheduleType
Defines the type of maintenance schedule to apply.
Valid options are: 'Daily', 'Weekly', 'Monthly', 'MonthlyAdvanced', 'Yearly', 'YearlyAdvanced'.
This parameter is mandatory when using the 'ByParameters' parameter set.

.PARAMETER StartTimeHour
Specifies the hour when the maintenance window starts.
This parameter is mandatory when using the 'ByParameters' parameter set.

.PARAMETER StartTimeMinute
Specifies the minute when the maintenance window starts.
Defaults to 0 if not provided.

.PARAMETER EndTimeHour
Specifies the hour when the maintenance window ends.
This parameter is mandatory when using the 'ByParameters' parameter set.

.PARAMETER EndTimeMinute
Specifies the minute when the maintenance window ends.
Defaults to 0 if not provided.

.PARAMETER RecurEvery
Determines the recurrence interval for the schedule.
For example, a value of 1 means the schedule repeats every day/week/month/year based on the ScheduleType.
Defaults to 1.

.PARAMETER DaysOfWeek
Specifies the days of the week when the maintenance schedule should occur.
Applicable for 'Weekly' ScheduleType.

.PARAMETER DayOfMonth
Defines the day of the month for the maintenance schedule.
Applicable for 'Monthly' and 'Yearly' ScheduleTypes.

.PARAMETER Occurence
Indicates the occurrence pattern within the month or year, such as 'First', 'Second', 'Third', 'Fourth', or 'Last'.
Applicable for 'MonthlyAdvanced' and 'YearlyAdvanced' ScheduleTypes.

.PARAMETER DayOfWeek
Specifies the day of the week associated with the occurrence pattern.
Applicable for 'MonthlyAdvanced' and 'YearlyAdvanced' ScheduleTypes.

.PARAMETER Month
Defines the month for the maintenance schedule.
Applicable for 'Yearly' and 'YearlyAdvanced' ScheduleTypes.

.PARAMETER EffectiveStartDate
Sets the start date for the maintenance schedule.
If not specified, defaults to the current date.
Specified as an array, example  @{ day = 29; month = 'september'; year = 2025 }

.PARAMETER EffectiveExpirationDate
Sets the expiration date for the maintenance schedule.
If not specified, the schedule does not expire.
Specified as an array, example  @{ day = 29; month = 'september'; year = 2025 }

.PARAMETER Config
Provides a configuration object containing one or more maintenance schedules.
Applicable when using the 'ByConfig' parameter set.

.PARAMETER DeleteAllSchedules
Deletes all existing maintenance schedules for the specified device(s).
Applicable when using the 'ByDeletion' parameter set.

.EXAMPLE
# Create a Yearly Advanced maintenance schedule for device 2367 using individual parameters
Set-WUGDeviceMaintenanceSchedule `
    -DeviceId 2367 `
    -ScheduleType 'YearlyAdvanced' `
    -StartTimeHour 1 `
    -EndTimeHour 1 `
    -Occurence 'First' `
    -DayOfWeek 'Monday' `
    -Month 'December'

.EXAMPLE
# Create a Monthly Advanced maintenance schedule for device 2367 using a configuration object
    $sched = @{
        ScheduleType = 'MonthlyAdvanced'
        StartTimeHour = 1
        EndTimeHour = 1
        Occurence = 'Last'
        DayOfWeek = 'Saturday'
        EffectiveStartDate = @{ day = 29; month = 'september'; year = 2024 }
    }
    Set-WUGDeviceMaintenanceSchedule -DeviceId 2367 -Config $sched

.EXAMPLE
# Retrieve an existing maintenance schedule and update it using the -Config parameter
$sched = Get-WUGDeviceMaintenanceSchedule -DeviceID 2367
$sched.ScheduleType = 'YearlyAdvanced'
$sched.Occurence = 'First'
$sched.DayOfWeek = 'Monday'
$sched.Month = 'December'
Set-WUGDeviceMaintenanceSchedule -DeviceId 2367 -Config $sched

.EXAMPLE
# Delete all maintenance schedules for device 2367
Set-WUGDeviceMaintenanceSchedule -DeviceId 2367 -DeleteAllSchedules

.PARAMETER ByParameters
(Parameter Set Name) Use individual parameters to define the maintenance schedule.

.PARAMETER ByConfig
(Parameter Set Name) Use a configuration object to define one or more maintenance schedules.

.PARAMETER ByDeletion
(Parameter Set Name) Delete all existing maintenance schedules for the specified device(s).

.NOTES
- Ensure that the global variables `$WUGBearerHeaders` and `$WhatsUpServerBaseURI` are set before invoking this function.
These are typically initialized by running the `Connect-WUGServer` function.
- The `-Config` parameter expects an object with properties matching the schedule configuration. 
Use the output from `Get-WUGDeviceMaintenanceSchedule` as a template for the configuration object.

Author: Jason Alberino (jason@wug.ninja) 2024-09-29
Updated: Jason Albberino (jason@wug.ninja) 2024-10-02

.LINK
https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_UpdateMaintenanceBatchSchedule
https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_UpdateMaintenanceSchedule

#>
function Set-WUGDeviceMaintenanceSchedule {
    [CmdletBinding(DefaultParameterSetName = 'ByParameters')]
    param(
        # Common Parameters for All Parameter Sets
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByParameters')]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByConfig')]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByDeletion')]
        [Alias('id')]
        [int[]]$DeviceId,

        # Parameters for 'ByParameters' Parameter Set
        [Parameter(Mandatory = $true, ParameterSetName = 'ByParameters')]
        [int]$StartTimeHour,
        [Parameter(ParameterSetName = 'ByParameters')]
        [int]$StartTimeMinute = 0,
        [Parameter(Mandatory = $true, ParameterSetName = 'ByParameters')]
        [int]$EndTimeHour,
        [Parameter(ParameterSetName = 'ByParameters')]
        [int]$EndTimeMinute = 0,
        [Parameter(Mandatory = $true, ParameterSetName = 'ByParameters')]
        [ValidateSet('Daily', 'Weekly', 'Monthly', 'MonthlyAdvanced', 'Yearly', 'YearlyAdvanced')]
        [string]$ScheduleType,
        [Parameter(ParameterSetName = 'ByParameters')]
        [int]$RecurEvery = 1,
        [Parameter(ParameterSetName = 'ByParameters')]
        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
        [string[]]$DaysOfWeek,
        [Parameter(ParameterSetName = 'ByParameters')]
        [ValidateRange(1, 31)]
        [int]$DayOfMonth,
        [Parameter(ParameterSetName = 'ByParameters')]
        [ValidateSet('First', 'Second', 'Third', 'Fourth', 'Last')]
        [string]$Occurence,
        [Parameter(ParameterSetName = 'ByParameters')]
        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
        [string]$DayOfWeek,
        [Parameter(ParameterSetName = 'ByParameters')]
        [ValidateSet('january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december')]
        [string]$Month,
        [Parameter(ParameterSetName = 'ByParameters')]
        [object]$EffectiveStartDate,
        [Parameter(ParameterSetName = 'ByParameters')]
        [object]$EffectiveExpirationDate,

        # Parameters for 'ByConfig' Parameter Set
        [Parameter(Mandatory = $true, ParameterSetName = 'ByConfig')]
        [array]$Config,

        # Switch Parameter for 'ByDeletion' Parameter Set
        [Parameter(Mandatory = $true, ParameterSetName = 'ByDeletion')]
        [switch]$DeleteAllSchedules
    )

    begin {
        Write-Debug "Starting Set-WUGDeviceMaintenanceSchedule function"
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {
            'ByParameters' {
                # Validate parameters based on ScheduleType
                switch ($ScheduleType) {
                    'Daily' {
                        if ($null -eq $StartTimeHour -or $null -eq $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Daily' ScheduleType."
                        }
                    }
                    'Weekly' {
                        if (-not $DaysOfWeek -or $DaysOfWeek.Count -eq 0) {
                            throw "When ScheduleType is 'Weekly', the DaysOfWeek parameter is required."
                        }
                        if ($null -eq $StartTimeHour -or $null -eq $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Weekly' ScheduleType."
                        }
                    }
                    'Monthly' {
                        if ($null -eq $DayOfMonth) {
                            throw "When ScheduleType is 'Monthly', the DayOfMonth parameter is required."
                        }
                        if ($null -eq $StartTimeHour -or $null -eq $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Monthly' ScheduleType."
                        }
                    }
                    'MonthlyAdvanced' {
                        if (-not $Occurence -or -not $DayOfWeek) {
                            throw "When ScheduleType is 'MonthlyAdvanced', both Occurence and DayOfWeek parameters are required."
                        }
                        if ($null -eq $StartTimeHour -or $null -eq $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'MonthlyAdvanced' ScheduleType."
                        }
                    }
                    'Yearly' {
                        if ($null -eq $DayOfMonth -or -not $Month) {
                            throw "When ScheduleType is 'Yearly', both DayOfMonth and Month parameters are required."
                        }
                        if ($null -eq $StartTimeHour -or $null -eq $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Yearly' ScheduleType."
                        }
                    }
                    'YearlyAdvanced' {
                        if (-not $Occurence -or -not $DayOfWeek -or -not $Month) {
                            throw "When ScheduleType is 'YearlyAdvanced', Occurence, DayOfWeek, and Month parameters are required."
                        }
                        if ($null -eq $StartTimeHour -or $null -eq $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'YearlyAdvanced' ScheduleType."
                        }
                    }
                    default {
                        throw "Invalid ScheduleType: $ScheduleType"
                    }
                }

                # If EffectiveStartDate is not specified, default to today's date
                if (-not $EffectiveStartDate) {
                    $today = Get-Date
                    $EffectiveStartDate = @{
                        "day"   = $today.Day
                        "month" = $today.ToString('MMMM').ToLower()
                        "year"  = $today.Year
                    }
                }

                # Build the schedule object based on ScheduleType
                $schedule = @{
                    "effectiveStartDate" = $EffectiveStartDate
                    "duration"           = @{
                        "startTime" = @{
                            "hour"   = $StartTimeHour
                            "minute" = $StartTimeMinute
                        }
                        "endTime"   = @{
                            "hour"   = $EndTimeHour
                            "minute" = $EndTimeMinute
                        }
                    }
                }

                switch ($ScheduleType) {
                    'Daily' {
                        $schedule["daily"] = @{
                            "repeat" = $RecurEvery
                        }
                    }
                    'Weekly' {
                        # Build daysOfTheWeek as a hashtable
                        $daysOfTheWeek = @{}
                        if ($DaysOfWeek -and ($DaysOfWeek -is [array]) -and ($DaysOfWeek.Count -gt 0)) {
                            foreach ($day in $DaysOfWeek) {
                                $daysOfTheWeek[$day.ToLower()] = $true
                            }
                        }
                        $schedule["weekly"] = @{
                            "repeat"        = $RecurEvery
                            "daysOfTheWeek" = $daysOfTheWeek
                        }
                    }
                    'Monthly' {
                        $schedule["monthly"] = @{
                            "repeat" = $RecurEvery
                            "day"    = $DayOfMonth
                        }
                    }
                    'MonthlyAdvanced' {
                        $schedule["monthlyAdvance"] = @{
                            "repeat"    = $RecurEvery
                            "occurence" = $Occurence.ToLower()
                            "dayOfWeek" = $DayOfWeek.ToLower()
                        }
                    }
                    'Yearly' {
                        $schedule["yearly"] = @{
                            "day"   = $DayOfMonth
                            "month" = $Month.ToLower()
                        }
                    }
                    'YearlyAdvanced' {
                        $schedule["yearlyAdvance"] = @{
                            "week"      = $Occurence.ToLower()
                            "dayOfWeek" = $DayOfWeek.ToLower()
                            "month"     = $Month.ToLower()
                        }
                    }
                    default {
                        throw "Invalid ScheduleType: $ScheduleType"
                    }
                }

                # Remove 'effectiveExpirationDate' if it's $null
                if ($null -eq $EffectiveExpirationDate) {
                    $schedule.PSObject.Properties.Remove('effectiveExpirationDate') | Out-Null
                }
                else {
                    $schedule["effectiveExpirationDate"] = $EffectiveExpirationDate
                }

                $schedules = @($schedule)
                $body = @{
                    "schedules" = $schedules
                    "devices"   = $DeviceId
                }

                $jsonBody = ConvertTo-Json -InputObject $body -Depth 10
                Write-Debug "Request Body: $jsonBody"

                # Send the PATCH request to the API
                $url = "$($global:WhatsUpServerBaseURI)/api/v1/devices/-/config/maintenance/schedule"
                Write-Debug "Sending PATCH request to URL: $url"

                try {
                    $result = Get-WUGAPIResponse -Uri $url -Method "PATCH" -Body $jsonBody
                    # Directly output the 'data' property for better readability
                    Write-Output $result.data
                }
                catch {
                    # Capture detailed error information
                    if ($_.Exception.Response) {
                        $responseStream = $_.Exception.Response.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($responseStream)
                        $responseBody = $reader.ReadToEnd()
                        Write-Error "API call failed. Status Code: $($_.Exception.Response.StatusCode) ($($_.Exception.Response.StatusDescription)). Response Body: $responseBody"
                    }
                    else {
                        Write-Error "API call failed. Exception: $($_.Exception.Message)"
                    }
                    return
                }
            }
            'ByConfig' {
                # Handle setting the schedule via Config object (Supports Single and Multiple Devices)

                if ($DeviceId.Count -eq 0) {
                    Write-Error "At least one DeviceId must be specified with the -Config parameter."
                    return
                }

                $isSingleDevice = $DeviceId.Count -eq 1

                if ($isSingleDevice) {
                    # Single Device: Use PUT
                    $deviceId = $DeviceId[0]

                    # Transform each schedule in Config to the API expected format
                    $scheduleList = @()

                    foreach ($sched in $Config) {
                        # Ensure EffectiveStartDate is set
                        if (-not $sched.effectiveStartDate) {
                            $today = Get-Date
                            $sched.effectiveStartDate = @{
                                "day"   = $today.Day
                                "month" = $today.ToString('MMMM').ToLower()
                                "year"  = $today.Year
                            }
                        }

                        # Remove 'effectiveExpirationDate' if it's $null
                        if ($null -eq $sched.effectiveExpirationDate) {
                            $sched.PSObject.Properties.Remove('effectiveExpirationDate') | Out-Null
                        }

                        # Normalize ScheduleType by removing spaces and converting to lowercase
                        $normalizedScheduleType = $sched.ScheduleType.ToLower().Replace(' ', '')

                        # Build the schedule object
                        $schedule = @{
                            "effectiveStartDate" = $sched.effectiveStartDate
                            "duration"           = @{
                                "startTime" = @{
                                    "hour"   = $sched.StartTimeHour
                                    "minute" = $sched.StartTimeMinute
                                }
                                "endTime"   = @{
                                    "hour"   = $sched.EndTimeHour
                                    "minute" = $sched.EndTimeMinute
                                }
                            }
                        }

                        # Depending on normalized ScheduleType, add the appropriate schedule type field
                        switch ($normalizedScheduleType) {
                            'daily' {
                                $schedule["daily"] = @{
                                    "repeat" = $sched.RecurEvery
                                }
                            }
                            'weekly' {
                                # Build daysOfTheWeek as a hashtable
                                $daysOfTheWeek = @{}
                                if ($sched.DaysOfWeek -and ($sched.DaysOfWeek -is [array]) -and ($sched.DaysOfWeek.Count -gt 0)) {
                                    foreach ($day in $sched.DaysOfWeek) {
                                        $daysOfTheWeek[$day.ToLower()] = $true
                                    }
                                }
                                $schedule["weekly"] = @{
                                    "repeat"        = $sched.RecurEvery
                                    "daysOfTheWeek" = $daysOfTheWeek
                                }
                            }
                            'monthly' {
                                $schedule["monthly"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "day"    = $sched.DayOfMonth
                                }
                            }
                            'monthlyadvanced' {
                                $schedule["monthlyAdvance"] = @{
                                    "repeat"    = $sched.RecurEvery
                                    "occurence" = $sched.Occurence.ToLower()
                                    "dayOfWeek" = $sched.DayOfWeek.ToLower()
                                }
                            }
                            'yearly' {
                                $schedule["yearly"] = @{
                                    "day"   = $sched.DayOfMonth
                                    "month" = $sched.Month.ToLower()
                                }
                            }
                            'yearlyadvanced' {
                                $schedule["yearlyAdvance"] = @{
                                    "week"      = $sched.Occurence.ToLower()
                                    "dayOfWeek" = $sched.DayOfWeek.ToLower()
                                    "month"     = $sched.Month.ToLower()
                                }
                            }
                            default {
                                throw "Invalid ScheduleType in Config: $($sched.ScheduleType)"
                            }
                        }

                        # Include EffectiveExpirationDate if it's not $null
                        if ($null -ne $sched.effectiveExpirationDate) {
                            $schedule["effectiveExpirationDate"] = $sched.effectiveExpirationDate
                        }

                        $scheduleList += $schedule
                    }

                    $body = @{
                        "schedules" = $scheduleList
                    }

                    $jsonBody = ConvertTo-Json -InputObject $body -Depth 10
                    Write-Debug "Request Body: $jsonBody"

                    # Send the PUT request to the API
                    $url = "$($global:WhatsUpServerBaseURI)/api/v1/devices/$deviceId/config/maintenance/schedule"
                    Write-Debug "Sending PUT request to URL: $url"

                    try {
                        $result = Get-WUGAPIResponse -Uri $url -Method "PUT" -Body $jsonBody
                        # Directly output the 'data' property for better readability
                        Write-Output $result.data
                    }
                    catch {
                        # Capture detailed error information
                        if ($_.Exception.Response) {
                            $responseStream = $_.Exception.Response.GetResponseStream()
                            $reader = New-Object System.IO.StreamReader($responseStream)
                            $responseBody = $reader.ReadToEnd()
                            Write-Error "API call failed. Status Code: $($_.Exception.Response.StatusCode) ($($_.Exception.Response.StatusDescription)). Response Body: $responseBody"
                        }
                        else {
                            Write-Error "API call failed. Exception: $($_.Exception.Message)"
                        }
                        return
                    }
                }
                else {
                    # Multiple Devices: Use PATCH
                    # Similar adjustments as above
                    # [Repeat the same changes for the multiple devices scenario]
                }
            }
            'ByDeletion' {
                # Handle deletion of all schedules (Multiple Devices using PATCH)
                # [No changes needed here]
            }
            default {
                Write-Error "Invalid parameter set."
                return
            }
        }
    }

    end {
        Write-Debug "Set-WUGDeviceMaintenanceSchedule function completed."
    }
}

# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUVPdatoInsP/ZvlflP7kXcQ39
# aoGgghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUTF0hF9w+IoB7JN0fmycweA3C
# UbQwDQYJKoZIhvcNAQEBBQAEggIAfmIBrD6snINVYg+sCNw7oHC41JBxSGQc8Mte
# slYJiQa8Y1cjoxMf5dBsv+qTxPotNm9+cpUlILS53Z/bYWBEX1zYkJGXQaXHG7dG
# ii5owSBtbw7nhO34jbxdOmP0io25bweU8NjuzeBp2vfmu8rHz8X7mtN4JrL1uhAe
# gE0+mTyc7s/0ERxoa9mG6xnm6zEzcCqLtwmVP0egqrayLa4kGlQvvagvTDNULLmS
# 7Qe0LsNuvtuknxtLh3w3B3nfeunte2Gp7klstsHtdapwvMKx128+oqEThnLmKvMH
# hQUP2dWwxFKoCyBPTpy+1dw39tLNBoudYXlk88n5B4ydOkikkwmSwLxV6N2iQeif
# cv4UQZ1x52uhCBRwTz/BT5trQVStVuKGa8MVqyYtjvj3uI/Sba4HZfhQoffFy6Z/
# xS4YzWmSYw8e3kolxe3lLHTvA2VDWdsxEm8EaYlOzT1CA6JOSqEs/psM2Wh+gfJn
# GPquu/4Y791/zaWxp7/lXscAQHr/7qKWiXu1jCs5YXJazw6td6NzuKk8xi6ibuVf
# JPM6QdbzmefSqC3c1RU0WkR5BSB1XVDA7fn7P7ThHTuVg/n6L5SWUmqm/JObncdK
# +Sy1f5xWF4zgoR8WieGSJD/NzMJ0L4DZ8wc1LIHXUZVRqbJ4s6GU1jWNreQSQIkQ
# iTFm4oQ=
# SIG # End signature block
