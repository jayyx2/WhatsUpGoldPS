<#
.SYNOPSIS
Retrieves disk free space reports for specified devices from WhatsUp Gold.

.DESCRIPTION
The Get-WUGDeviceReportDiskSpaceFree function fetches disk free space reports for a list of device IDs from WhatsUp Gold. It supports filtering by time range, sorting, grouping, applying thresholds, and automatically handles pagination. The function provides progress feedback during execution.

.PARAMETER DeviceId
An array of device IDs for which disk free space reports are requested. This parameter is mandatory and accepts multiple values.

.PARAMETER Range
Specifies the time range for the report. Valid entries include various predefined ranges or 'custom' for a user-defined range. Default is 'today'.

.PARAMETER RangeStartUtc
The start date for the custom time range in UTC format. Required if Range is set to 'custom'.

.PARAMETER RangeEndUtc
The end date for the custom time range in UTC format. Required if Range is set to 'custom'.

.PARAMETER RangeN
Used with certain 'lastN' ranges as a multiplier to specify the number for the data filter.

.PARAMETER SortBy
Specifies the field to sort the report by. Options include 'defaultColumn', 'id', 'deviceName', 'disk', 'diskId', 'pollTimeUtc', 'timeFromLastPollSeconds', 'size', 'minFree', 'maxFree', 'avgFree'. Default is 'minFree'.

.PARAMETER SortByDir
The direction to sort the report, either 'asc' for ascending or 'desc' for descending. Default is 'desc'.

.PARAMETER GroupBy
Specifies the field to group the report by.

.PARAMETER GroupByDir
The direction to group the report.

.PARAMETER ApplyThreshold
Indicates whether the threshold filter is applied. Accepts 'true' or 'false'.

.PARAMETER OverThreshold
Indicates if the threshold value is applied when over or under. Accepts 'true' or 'false'.

.PARAMETER ThresholdValue
Specifies the threshold filter value.

.PARAMETER BusinessHoursId
The business hour filter ID to apply.

.PARAMETER RollupByDevice
Indicates if the report should be summarized at the device level. Accepts 'true' or 'false'.

.PARAMETER PageId
Used for pagination, specifies the page ID to start from.

.PARAMETER Limit
Limits the number of entries per page. Default is 25.

.EXAMPLE
PS> Get-WUGDeviceReportDiskSpaceFree -DeviceId @("1", "2", "3") -Range "lastMonth"

Fetches last month's disk free space reports for devices with IDs 1, 2, and 3.

.EXAMPLE
PS> Get-WUGDeviceReportDiskSpaceFree -DeviceId @("4") -Range "custom" -RangeStartUtc "2023-01-01T00:00:00Z" -RangeEndUtc "2023-01-07T23:59:59Z"

Fetches disk free space reports for device 4 for the first week of January 2023.

.NOTES
Author: Jason Alberino (jason@wug.ninja) 2024-03-24
-Converts to gigabytes automatically
-Adds percentFree to the data returned
Modified: 2024-03-29
Reference: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#operation/DeviceReport_DeviceDiskFreeSpaceReport
#>

# Helper Function: Convert-BytesToUnit
function Convert-BytesToUnit {
    param (
        [long]$Bytes
    )
    if ($Bytes -ge 1TB) {
        $value = [math]::Round($Bytes / 1TB, 2)
        $unit = 'TB'
    }
    elseif ($Bytes -ge 1GB) {
        $value = [math]::Round($Bytes / 1GB, 2)
        $unit = 'GB'
    }
    elseif ($Bytes -ge 1MB) {
        $value = [math]::Round($Bytes / 1MB, 2)
        $unit = 'MB'
    }
    else {
        $value = [math]::Round($Bytes / 1KB, 2)
        $unit = 'KB'
    }
    return @{Value = $value; Unit = $unit}
}

# Main Function: Get-WUGDeviceReportDiskSpaceFree
function Get-WUGDeviceReportDiskSpaceFree {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
        [ValidateSet("today", "lastPolled", "yesterday", "lastWeek", "lastMonth", "lastQuarter", "weekToDate", "monthToDate", "quarterToDate", "lastNSeconds", "lastNMinutes", "lastNHours", "lastNDays", "lastNWeeks", "lastNMonths", "custom")][string]$Range,
        [string]$RangeStartUtc,
        [string]$RangeEndUtc,
        [int]$RangeN = 1,
        [ValidateSet("defaultColumn", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")][string]$SortBy,
        [ValidateSet("asc", "desc")][string]$SortByDir,
        [ValidateSet("noGrouping", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")][string]$GroupBy,
        [ValidateSet("asc", "desc")][string]$GroupByDir,
        [ValidateSet("true", "false")][string]$ApplyThreshold,
        [ValidateSet("true", "false")][string]$OverThreshold,
        [double]$ThresholdValue = 0.0,
        [int]$BusinessHoursId = 0,
        [ValidateSet("true", "false")][string]$RollupByDevice,
        [string]$PageId,
        [ValidateRange(0, 250)][int]$Limit
    ) 

    begin {
        # Initialize collection for DeviceIds
        $collectedDeviceIds = @()

        # Debug message with all parameters
        Write-Debug "Function: Get-WUGDeviceReportDiskSpaceFree -- DeviceId=${DeviceId} Range=${Range} RangeStartUtc=${RangeStartUtc} RangeEndUtc=${RangeEndUtc} RangeN=${RangeN} SortBy=${SortBy} SortByDir=${SortByDir} GroupBy=${GroupBy} GroupByDir=${GroupByDir} ApplyThreshold=${ApplyThreshold} OverThreshold=${OverThreshold} ThresholdValue=${ThresholdValue} BusinessHoursId=${BusinessHoursId} RollupByDevice=${RollupByDevice} PageId=${PageId} Limit=${Limit}"

        # Set static variables
        $finaloutput = @()
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/devices"
        $endUri = "disk-free-space"
        $queryString = ""
        $totalDevices = $DeviceId.Count

        # Building the query string
        if ($Range) { $queryString += "range=$Range&" }
        if ($RangeStartUtc) { $queryString += "rangeStartUtc=$RangeStartUtc&" }
        if ($RangeEndUtc) { $queryString += "rangeEndUtc=$RangeEndUtc&" }
        if ($RangeN) { $queryString += "rangeN=$RangeN&" }
        if ($SortBy) { $queryString += "sortBy=$SortBy&" }
        if ($SortByDir) { $queryString += "sortByDir=$SortByDir&" }
        if ($GroupBy) { $queryString += "groupBy=$GroupBy&" }
        if ($GroupByDir) { $queryString += "groupByDir=$GroupByDir&" }
        if ($ApplyThreshold) { $queryString += "applyThreshold=$ApplyThreshold&" }
        if ($OverThreshold) { $queryString += "overThreshold=$OverThreshold&" }
        if ($ThresholdValue) { $queryString += "thresholdValue=$ThresholdValue&" }
        if ($BusinessHoursId) { $queryString += "businessHoursId=$BusinessHoursId&" }
        if ($RollupByDevice) { $queryString += "rollupByDevice=$RollupByDevice&" }
        if ($PageId) { $queryString += "pageId=$PageId&" }
        if ($Limit) { $queryString += "limit=$Limit&" }

        # Trimming the trailing "&" if it exists
        $queryString = $queryString.TrimEnd('&')

        Write-Debug "Constructed Query String: $queryString"
    }

    process {
        # Collect DeviceIds from pipeline
        foreach ($id in $DeviceId) {
            $collectedDeviceIds += $id
            Write-Debug "Collected DeviceID: $id"
        }
    }

    end {
        # Total number of devices to process
        $totalDevices = $collectedDeviceIds.Count
        Write-Debug "Total Devices to Process: $totalDevices"

        if ($totalDevices -eq 0) {
            Write-Warning "No valid DeviceIDs provided."
            return
        }

        # Determine batch size (max 499)
        $batchSize = 499
        if ($totalDevices -le $batchSize) { 
            $batchSize = $totalDevices 
        }
        Write-Debug "Batch Size: $batchSize"

        $devicesProcessed = 0
        $percentCompleteDevices = 0

        foreach ($id in $collectedDeviceIds) {
            $devicesProcessed++
            $percentCompleteDevices = [Math]::Round(($devicesProcessed / $totalDevices) * 100, 2)
            Write-Progress -Id 1 -Activity "Fetching device report ${endUri} for $totalDevices devices" -Status "Processing Device $devicesProcessed of $totalDevices (DeviceID: $id)" -PercentComplete $percentCompleteDevices
            Write-Debug "Processing DeviceID: $id"

            $currentPageId = $null
            $pageCount = 0

            do {
                if ($currentPageId) {
                    $uri = "${baseUri}/${id}/reports/${endUri}?pageId=$currentPageId&$queryString"
                    Write-Debug "Constructed URI with pageId: $uri"
                } else {
                    $uri = "${baseUri}/${id}/reports/${endUri}?$queryString"
                    Write-Debug "Constructed URI: $uri"
                }

                try {
                    $result = Get-WUGAPIResponse -uri $uri -Method "GET"
                    Write-Debug "API Call Successful for URI: $uri"

                    if ($null -eq $result.data -or $result.data.Count -eq 0) {
                        Write-Warning "No data returned for DeviceID: $id on URI: $uri"
                        break
                    }

                    foreach ($data in $result.data) {
                        # Check if 'size' property exists
                        if ($data.PSObject.Properties.Match('size').Count -eq 0) {
                            Write-Warning "DeviceID: $id returned a data object without 'size' property. Skipping this object."
                            continue
                        }

                        # Ensure 'size', 'minFree', 'maxFree', 'avgFree' are numeric
                        $isValid = $true
                        foreach ($prop in @('size', 'minFree', 'maxFree', 'avgFree')) {
                            if (-not ($data.$prop -is [double] -or $data.$prop -is [int] -or $data.$prop -is [long])) {
                                Write-Warning "DeviceID: $id has non-numeric '$prop': $($data.$prop). Skipping this object."
                                $isValid = $false
                                break
                            }
                        }
                        if (-not $isValid) { continue }

                        # Calculate percent free
                        $percentFree = if ($data.size -gt 0) { [math]::Round(($data.avgFree / $data.size) * 100, 2) } else { 0 }

                        # Convert 'size' to appropriate unit
                        $conversion = Convert-BytesToUnit -Bytes $data.size
                        $unit = $conversion.Unit
                        $sizeValue = $conversion.Value

                        # Convert 'minFree', 'maxFree', 'avgFree' using the same unit
                        switch ($unit) {
                            'TB' {
                                $minFreeDisplay = [math]::Round($data.minFree / 1TB, 2)
                                $maxFreeDisplay = [math]::Round($data.maxFree / 1TB, 2)
                                $avgFreeDisplay = [math]::Round($data.avgFree / 1TB, 2)
                            }
                            'GB' {
                                $minFreeDisplay = [math]::Round($data.minFree / 1GB, 2)
                                $maxFreeDisplay = [math]::Round($data.maxFree / 1GB, 2)
                                $avgFreeDisplay = [math]::Round($data.avgFree / 1GB, 2)
                            }
                            'MB' {
                                $minFreeDisplay = [math]::Round($data.minFree / 1MB, 2)
                                $maxFreeDisplay = [math]::Round($data.maxFree / 1MB, 2)
                                $avgFreeDisplay = [math]::Round($data.avgFree / 1MB, 2)
                            }
                            'KB' {
                                $minFreeDisplay = [math]::Round($data.minFree / 1KB, 2)
                                $maxFreeDisplay = [math]::Round($data.maxFree / 1KB, 2)
                                $avgFreeDisplay = [math]::Round($data.avgFree / 1KB, 2)
                            }
                            default {
                                # If unit is not recognized, skip conversion
                                $minFreeDisplay = $data.minFree
                                $maxFreeDisplay = $data.maxFree
                                $avgFreeDisplay = $data.avgFree
                            }
                        }

                        # Create a new PSCustomObject with existing and new properties
                        $newData = [PSCustomObject]@{
                            deviceName              = $data.deviceName
                            disk                    = $data.disk
                            diskId                  = $data.diskId
                            pollTimeUtc             = $data.pollTimeUtc
                            timeFromLastPollSeconds = $data.timeFromLastPollSeconds
                            size                    = $data.size
                            minFree                 = $data.minFree
                            maxFree                 = $data.maxFree
                            avgFree                 = $data.avgFree
                            id                      = $data.id
                            percentFree             = $percentFree
                            sizeDisplay             = "{0:N2} {1}" -f $sizeValue, $unit
                            minFreeDisplay          = "{0:N2} {1}" -f $minFreeDisplay, $unit
                            maxFreeDisplay          = "{0:N2} {1}" -f $maxFreeDisplay, $unit
                            avgFreeDisplay          = "{0:N2} {1}" -f $avgFreeDisplay, $unit
                        }

                        # Process series data if available
                        if ($data.series) {
                            $newSeries = @()
                            foreach ($series in $data.series) {
                                # Ensure 'series' properties are numeric
                                $isSeriesValid = $true
                                foreach ($prop in @('avgFree', 'minFree', 'maxFree')) {
                                    if (-not ($series.$prop -is [double] -or $series.$prop -is [int] -or $series.$prop -is [long])) {
                                        Write-Warning "DeviceID: $id series has non-numeric '$prop': $($series.$prop). Skipping this series object."
                                        $isSeriesValid = $false
                                        break
                                    }
                                }
                                if (-not $isSeriesValid) { continue }

                                # Convert series values based on determined unit
                                $seriesAvgFree = switch ($unit) {
                                    'TB' { [math]::Round($series.avgFree / 1TB, 2) }
                                    'GB' { [math]::Round($series.avgFree / 1GB, 2) }
                                    'MB' { [math]::Round($series.avgFree / 1MB, 2) }
                                    'KB' { [math]::Round($series.avgFree / 1KB, 2) }
                                }
                                $seriesMinFree = switch ($unit) {
                                    'TB' { [math]::Round($series.minFree / 1TB, 2) }
                                    'GB' { [math]::Round($series.minFree / 1GB, 2) }
                                    'MB' { [math]::Round($series.minFree / 1MB, 2) }
                                    'KB' { [math]::Round($series.minFree / 1KB, 2) }
                                }
                                $seriesMaxFree = switch ($unit) {
                                    'TB' { [math]::Round($series.maxFree / 1TB, 2) }
                                    'GB' { [math]::Round($series.maxFree / 1GB, 2) }
                                    'MB' { [math]::Round($series.maxFree / 1MB, 2) }
                                    'KB' { [math]::Round($series.maxFree / 1KB, 2) }
                                }

                                # Create a new PSCustomObject for the series
                                $newSeriesObj = [PSCustomObject]@{
                                    pollTimeUtc    = $series.pollTimeUtc
                                    avgFree        = $series.avgFree
                                    minFree        = $series.minFree
                                    maxFree        = $series.maxFree
                                    avgFreeDisplay = "{0:N2} {1}" -f $seriesAvgFree, $unit
                                    minFreeDisplay = "{0:N2} {1}" -f $seriesMinFree, $unit
                                    maxFreeDisplay = "{0:N2} {1}" -f $seriesMaxFree, $unit
                                }
                                $newSeries += $newSeriesObj
                            }
                            $newData | Add-Member -NotePropertyName 'series' -NotePropertyValue $newSeries -Force
                        }

                        # Add the new data object to the final output
                        $finaloutput += $newData
                        Write-Debug "Processed DeviceID: $id with disk: $($newData.disk)"
                    }

                    $currentPageId = $result.paging.nextPageId
                    $pageCount++

                    # Page progress for the current device with Id 2
                    if ($result.paging.totalPages) {
                        $percentCompletePages = [Math]::Round(($pageCount / $result.paging.totalPages) * 100, 2)
                        Write-Progress -Id 2 -Activity "Fetching device report ${endUri} for DeviceID: $id" -Status "Page $pageCount of $($result.paging.totalPages)" -PercentComplete $percentCompletePages
                        Write-Debug "Processing Page: $pageCount of $($result.paging.totalPages)"
                    } else {
                        # Indicate ongoing progress if total pages aren't known
                        Write-Progress -Id 2 -Activity "Fetching device report ${endUri} for DeviceID: $id" -Status "Processing page $pageCount" -PercentComplete 0
                        Write-Debug "Processing Page: $pageCount (Total Pages Unknown)"
                    }

                }
                catch {
                    Write-Error "Error fetching device report ${endUri} for DeviceID ${id}: $_"
                    # Exit the pagination loop on error
                    $currentPageId = $null
                }

            } while ($currentPageId)

            # Clear the page progress for the current device after all pages are processed
            Write-Progress -Id 2 -Activity "Fetching device report ${endUri} for DeviceID: $id" -Status "Completed" -Completed
            Write-Debug "Completed DeviceID: $id"
        }

        # Clear the main device progress after all devices are processed
        Write-Progress -Id 1 -Activity "Fetching device report ${endUri} for $totalDevices devices" -Status "All devices processed" -Completed
        Write-Debug "All devices have been processed."

        # Return the collected data
        Write-Debug "Total Data Collected: $($finaloutput.Count)"
        return $finaloutput
    }
}


# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQURt5tSG/UFv7TFsHZtd3kY/T2
# DmWgghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUY283T0e3jdf5iNF7p6uawOeE
# BXowDQYJKoZIhvcNAQEBBQAEggIAAGQ1Bo4LLUyh7XsPtIzRKopYSAji8pLgaEgs
# PTzfSTrKdNzDZLIx8T4CL0qQ0SPn1VCEI2mC8Aj/ekQuZoLZ9xuiMa1thxYF4lu5
# HRqwMpt6GG5jyMt4vmNDZE94xlhEst0j36q5URASOU5egoImaQ1jpgoH5MTPJQn/
# rt2TXVY1f0aixT9uv8c52vwhts1gnJA0R3NDNZDGIMkaSqAGcBzwa9FkXNMA7181
# h0q7YyhHS1A0psM90xJ9NqBHqI0ijzsIKVf0mSvLnLcP/jtjm96VSfoPYBP9130N
# KbGrdza+2alFErB2wAV+loYoSxvl4sSVN6uKlsu14RElSwLWAMm0CVo8Gqgj41Rv
# 3cnFdintPPMaIEe2zK02RunsNdbufqXnPQ2jHz2nwyhI1srr3S+IHz/Hmg1/02uV
# CudFX2gx42ODytti3gwBxw0AzeLwHD1d1UVC2Im4BZ2iOxwY6p6JPdmXqrVj66Bd
# 95KfPp5MeRl4pVw3iMtxI6o/NXYhdSJ4D1+YL8TnASJ5b60DvUgFM+2BsUtK36gW
# 0w4bduby3DD7Kk26lmpffnlMgVHJJqFT3gdC+E+E5MelKIrc5JKDHD9aGV+GFMJL
# 8dE7tMZtr+3KfdX133kIZPxWDcw5jX2Ed0xv8auZ8GF7dpGE5+qXi76rGkPRvURl
# a9XIl4A=
# SIG # End signature block
