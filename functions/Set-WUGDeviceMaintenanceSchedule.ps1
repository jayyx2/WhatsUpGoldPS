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

    .PARAMETER EffectiveExpirationDate
        Sets the expiration date for the maintenance schedule.
        If not specified, the schedule does not expire.

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

    .LINK
        https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_UpdateMaintenanceBatchSchedule
        https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_UpdateMaintenanceSchedule

    #>
function Set-WUGDeviceMaintenanceSchedule {
    [CmdletBinding(DefaultParameterSetName = 'ByParameters')]
    param(
        # Common Parameters for All Parameter Sets
        [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByParameters')]
        [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByConfig')]
        [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByDeletion')]
        [Alias('id')]
        [int[]]$DeviceId,

        # Parameters for 'ByParameters' Parameter Set
        [Parameter(Mandatory=$true, ParameterSetName='ByParameters')]
        [int]$StartTimeHour,

        [Parameter(ParameterSetName='ByParameters')]
        [int]$StartTimeMinute = 0,

        [Parameter(Mandatory=$true, ParameterSetName='ByParameters')]
        [int]$EndTimeHour,

        [Parameter(ParameterSetName='ByParameters')]
        [int]$EndTimeMinute = 0,

        [Parameter(Mandatory=$true, ParameterSetName='ByParameters')]
        [ValidateSet('Daily', 'Weekly', 'Monthly', 'MonthlyAdvanced', 'Yearly', 'YearlyAdvanced')]
        [string]$ScheduleType,

        [Parameter(ParameterSetName='ByParameters')]
        [int]$RecurEvery = 1,

        [Parameter(ParameterSetName='ByParameters')]
        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
        [string[]]$DaysOfWeek,

        [Parameter(ParameterSetName='ByParameters')]
        [ValidateRange(1,31)]
        [int]$DayOfMonth,

        [Parameter(ParameterSetName='ByParameters')]
        [ValidateSet('First', 'Second', 'Third', 'Fourth', 'Last')]
        [string]$Occurence,

        [Parameter(ParameterSetName='ByParameters')]
        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
        [string]$DayOfWeek,

        [Parameter(ParameterSetName='ByParameters')]
        [ValidateSet('january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december')]
        [string]$Month,

        [Parameter(ParameterSetName='ByParameters')]
        [object]$EffectiveStartDate,

        [Parameter(ParameterSetName='ByParameters')]
        [object]$EffectiveExpirationDate,

        # Parameters for 'ByConfig' Parameter Set
        [Parameter(Mandatory=$true, ParameterSetName='ByConfig')]
        [array]$Config,

        # Switch Parameter for 'ByDeletion' Parameter Set
        [Parameter(Mandatory=$true, ParameterSetName='ByDeletion')]
        [switch]$DeleteAllSchedules
    )

    begin {
        Write-Debug "Starting Set-WUGDeviceMaintenanceSchedule function"

        # Check for required global variables
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            return
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Please run Connect-WUGServer."
            return
        }
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {
            'ByParameters' {
                # Validate parameters based on ScheduleType
                switch ($ScheduleType) {
                    'Daily' {
                        # No additional parameters required
                        if (-not $StartTimeHour -or -not $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Daily' ScheduleType."
                        }
                    }
                    'Weekly' {
                        if (-not $DaysOfWeek -or $DaysOfWeek.Count -eq 0) {
                            throw "When ScheduleType is 'Weekly', the DaysOfWeek parameter is required."
                        }
                        if (-not $StartTimeHour -or -not $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Weekly' ScheduleType."
                        }
                    }
                    'Monthly' {
                        if (-not $DayOfMonth) {
                            throw "When ScheduleType is 'Monthly', the DayOfMonth parameter is required."
                        }
                        if (-not $StartTimeHour -or -not $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Monthly' ScheduleType."
                        }
                    }
                    'MonthlyAdvanced' {
                        if (-not $Occurence -or -not $DayOfWeek) {
                            throw "When ScheduleType is 'MonthlyAdvanced', both Occurence and DayOfWeek parameters are required."
                        }
                        if (-not $StartTimeHour -or -not $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'MonthlyAdvanced' ScheduleType."
                        }
                    }
                    'Yearly' {
                        if (-not $DayOfMonth -or -not $Month) {
                            throw "When ScheduleType is 'Yearly', both DayOfMonth and Month parameters are required."
                        }
                        if (-not $StartTimeHour -or -not $EndTimeHour) {
                            throw "StartTimeHour and EndTimeHour are required for 'Yearly' ScheduleType."
                        }
                    }
                    'YearlyAdvanced' {
                        if (-not $Occurence -or -not $DayOfWeek -or -not $Month) {
                            throw "When ScheduleType is 'YearlyAdvanced', Occurence, DayOfWeek, and Month parameters are required."
                        }
                        if (-not $StartTimeHour -or -not $EndTimeHour) {
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
                    "duration" = @{
                        "startTime" = @{
                            "hour" = $StartTimeHour
                            "minute" = $StartTimeMinute
                        }
                        "endTime" = @{
                            "hour" = $EndTimeHour
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
                        foreach ($day in $DaysOfWeek) {
                            $daysOfTheWeek[$day.ToLower()] = $true
                        }
                        $schedule["weekly"] = @{
                            "repeat" = $RecurEvery
                            "daysOfTheWeek" = $daysOfTheWeek
                        }
                    }
                    'Monthly' {
                        $schedule["monthly"] = @{
                            "repeat" = $RecurEvery
                            "day" = $DayOfMonth
                        }
                    }
                    'MonthlyAdvanced' {
                        $schedule["monthlyAdvance"] = @{
                            "repeat" = $RecurEvery
                            "occurence" = $Occurence.ToLower()
                            "dayOfWeek" = $DayOfWeek.ToLower()
                        }
                    }
                    'Yearly' {
                        $schedule["yearly"] = @{
                            "day" = $DayOfMonth
                            "month" = $Month.ToLower()
                        }
                    }
                    'YearlyAdvanced' {
                        $schedule["yearlyAdvance"] = @{
                            "week" = $Occurence.ToLower()
                            "dayOfWeek" = $DayOfWeek.ToLower()
                            "month" = $Month.ToLower()
                        }
                    }
                    default {
                        throw "Invalid ScheduleType: $ScheduleType"
                    }
                }

                # Remove 'effectiveExpirationDate' if it's null
                if ($null -eq $EffectiveExpirationDate) {
                    $schedule.PSObject.Properties.Remove('effectiveExpirationDate') | Out-Null
                } else {
                    $schedule["effectiveExpirationDate"] = $EffectiveExpirationDate
                }

                $schedules = @($schedule)
                $body = @{
                    "schedules" = $schedules
                    "devices" = $DeviceId
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
                                "day" = $today.Day
                                "month" = $today.ToString('MMMM').ToLower()
                                "year" = $today.Year
                            }
                        }

                        # Remove 'effectiveExpirationDate' if it's null or not set
                        if (-not $sched.effectiveExpirationDate) {
                            $sched.PSObject.Properties.Remove('effectiveExpirationDate') | Out-Null
                        }

                        # Normalize ScheduleType by removing spaces and converting to lowercase
                        $normalizedScheduleType = $sched.ScheduleType.ToLower().Replace(' ', '')

                        # Build the schedule object
                        $schedule = @{
                            "effectiveStartDate" = $sched.effectiveStartDate
                            "duration" = @{
                                "startTime" = @{
                                    "hour" = $sched.StartTimeHour
                                    "minute" = $sched.StartTimeMinute
                                }
                                "endTime" = @{
                                    "hour" = $sched.EndTimeHour
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
                                if ($sched.DaysOfWeek) {
                                    foreach ($day in $sched.DaysOfWeek) {
                                        $daysOfTheWeek[$day.ToLower()] = $true
                                    }
                                }
                                $schedule["weekly"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "daysOfTheWeek" = $daysOfTheWeek
                                }
                            }
                            'monthly' {
                                $schedule["monthly"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "day" = $sched.DayOfMonth
                                }
                            }
                            'monthlyadvanced' {
                                $schedule["monthlyAdvance"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "occurence" = $sched.Occurence.ToLower()
                                    "dayOfWeek" = $sched.DayOfWeek.ToLower()
                                }
                            }
                            'yearly' {
                                $schedule["yearly"] = @{
                                    "day" = $sched.DayOfMonth
                                    "month" = $sched.Month.ToLower()
                                }
                            }
                            'yearlyadvanced' {
                                $schedule["yearlyAdvance"] = @{
                                    "week" = $sched.Occurence.ToLower()
                                    "dayOfWeek" = $sched.DayOfWeek.ToLower()
                                    "month" = $sched.Month.ToLower()
                                }
                            }
                            default {
                                throw "Invalid ScheduleType in Config: $($sched.ScheduleType)"
                            }
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
                    # Transform each schedule in Config to the API expected format
                    $scheduleList = @()

                    foreach ($sched in $Config) {
                        # Ensure EffectiveStartDate is set
                        if (-not $sched.effectiveStartDate) {
                            $today = Get-Date
                            $sched.effectiveStartDate = @{
                                "day" = $today.Day
                                "month" = $today.ToString('MMMM').ToLower()
                                "year" = $today.Year
                            }
                        }

                        # Remove 'effectiveExpirationDate' if it's null or not set
                        if (-not $sched.effectiveExpirationDate) {
                            $sched.PSObject.Properties.Remove('effectiveExpirationDate') | Out-Null
                        }

                        # Normalize ScheduleType by removing spaces and converting to lowercase
                        $normalizedScheduleType = $sched.ScheduleType.ToLower().Replace(' ', '')

                        # Build the schedule object
                        $schedule = @{
                            "effectiveStartDate" = $sched.effectiveStartDate
                            "duration" = @{
                                "startTime" = @{
                                    "hour" = $sched.StartTimeHour
                                    "minute" = $sched.StartTimeMinute
                                }
                                "endTime" = @{
                                    "hour" = $sched.EndTimeHour
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
                                if ($sched.DaysOfWeek) {
                                    foreach ($day in $sched.DaysOfWeek) {
                                        $daysOfTheWeek[$day.ToLower()] = $true
                                    }
                                }
                                $schedule["weekly"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "daysOfTheWeek" = $daysOfTheWeek
                                }
                            }
                            'monthly' {
                                $schedule["monthly"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "day" = $sched.DayOfMonth
                                }
                            }
                            'monthlyadvanced' {
                                $schedule["monthlyAdvance"] = @{
                                    "repeat" = $sched.RecurEvery
                                    "occurence" = $sched.Occurence.ToLower()
                                    "dayOfWeek" = $sched.DayOfWeek.ToLower()
                                }
                            }
                            'yearly' {
                                $schedule["yearly"] = @{
                                    "day" = $sched.DayOfMonth
                                    "month" = $sched.Month.ToLower()
                                }
                            }
                            'yearlyadvanced' {
                                $schedule["yearlyAdvance"] = @{
                                    "week" = $sched.Occurence.ToLower()
                                    "dayOfWeek" = $sched.DayOfWeek.ToLower()
                                    "month" = $sched.Month.ToLower()
                                }
                            }
                            default {
                                throw "Invalid ScheduleType in Config: $($sched.ScheduleType)"
                            }
                        }

                        $scheduleList += $schedule
                    }

                    $body = @{
                        "devices" = $DeviceId
                        "schedules" = $scheduleList
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
            }
            'ByDeletion' {
                # Handle deletion of all schedules (Multiple Devices using PATCH)

                $url = "$($global:WhatsUpServerBaseURI)/api/v1/devices/-/config/maintenance/schedule"
                Write-Debug "Sending PATCH DELETE request to URL: $url"

                $body = @{
                    "devices" = $DeviceId
                }

                $jsonBody = ConvertTo-Json -InputObject $body
                Write-Debug "Request Body: $jsonBody"

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
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBuSyTp52Xdh9og
# pLgC8Uj/aCeARKMxcfGensivAP/4PKCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BgkqhkiG9w0BCQQxIgQgrcnnx6RHL/kIByUMzsDH+JBGD/vSSMNNUJ1J7C07zkQw
# DQYJKoZIhvcNAQEBBQAEggIAOhvZ8OULTcPSy9iWTELKh6P2JOQnmEs3yra+pKwM
# Cv0C7FJBbYT/X78EFKSMvuw/XOvGI4UWojw+Lt2KaUB0oIPJVdGg72PMZyodop+t
# As0ur2ImZEy5I6CggevDs0jHMvJRVhr7uwQHM9bp1cd+s41ISqen29oVAAO4tmYf
# +njewXtQ/mWRMf5WuNQr1+EmpNyrZwfeRxFA/soO5EltA3uRP2Sz+81Fystbo5rO
# AgePbb561bTXDHnflVjdEUgyT+IHCdi7aWvYQdkHWKfTS9B41+MlQVqX7Ppa6oSP
# e9qWwHLuTCEBl9WHWRB7MtAoAuCg1nwwpZ3OSSmx4tsu94312P0hJ9p3qXYUaGli
# M76tq7Vt9VMcG9bbisXNx7tXfFEeaF4+GMGRCiOFdePGl56V3Qzujf1FL5OJgqr7
# t6RkLfoILbSQcWqBfOvcrMGM7FXEwRZeo3vBhigETARmSCDZ4EH9Fn8aKE7H4e9r
# stUeXZu9yS/LBUlWCRUl1wcGi/U7/GcQ/GuZXDT8wzT8VVZQzAj5hABrTPtIK8Z8
# xGLBFbj+nbrdTRuAWJKg+uaZGHtYQVFDRSF2QtVaCzAkqrFNSKG7gfkSVpdACv8J
# 9KLPFvZPWhWEJWKE0NgtdbI7SCRKeKcpNbAULGY3seHc0uBCszncVAqnDlSH/3Zl
# c/A=
# SIG # End signature block
