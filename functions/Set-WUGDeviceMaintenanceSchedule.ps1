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
# End of Set-WUGDeviceMaintenanceSchedule function
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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA0krE4dMl535lV
# WY2C2ZC0SlPc5Q0TZQTlRzxhEN7oc6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgRXCXJk7kLybTFhfJxQe0rhLNSZvALqF4
# AyKAMrkw0vIwDQYJKoZIhvcNAQEBBQAEggIA1Rd0BgGKnAJnO0abN744cP5QfRAi
# UO6LYvV7t23xHWH48nH/Gq+x4cLDZm63yogmrKSkhEw3Ku2gmcnwEVfG5pjB7Hds
# Q2Fr9Mhwx/pOfwakm53azQZXWCUmIhKrT9la6ISkQe3v56APDqP69jt5GJ2f203e
# UJ8dNHkSL8cbCuricpd2sGltkIMYI+xuZzvU56NczNbrnLie/uYrjya4H69W9k+G
# jbo+0VdxMwDH60Te4pgW/UHTHV3TqXuodGENDmImV3iqAsoYTxW1jYMGIKyVxQvl
# xwlKCbxiqXCAIhjbl4Comp7I62hopuaMsjK44lTDH3jIdz108mlpTnvjv6WhAfJ6
# VwEAuwVJMMurBgLhgslAeOj9ARLuEKgf6CAprsyxks/rX55dlAR6xTK5lTcrYPLi
# gtP0XRGkIrUzil+0yCxb/4qbSMbatSv6E5mXKqr4hkKzrFR58QQCv1XFCLXylMcU
# czEBzkcA9GSXPSY5OrYfh9A/loXZo9vk+DLWYRR7Rq2TCOzh+Zq8ysCR/uPGWBzX
# 4YiNpMWRMhPkjElfvNR7IfI1f9ZAqcheDgv5oR03zM7rKI2xLVVyu7xd1QUWUwvT
# osXFA8IK/BR8XmQpVDNe7Jv8FYgwJmYAJuGBAno9AfjMmSkisRspAQ6z/F9OPGu3
# LFcALI9hiL8898c=
# SIG # End signature block
