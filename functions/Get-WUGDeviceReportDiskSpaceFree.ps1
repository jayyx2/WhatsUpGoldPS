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
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
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
        # If no DeviceId was specified, fetch all device IDs
        if ($collectedDeviceIds.Count -eq 0) {
            Write-Verbose "No DeviceId specified. Fetching all device IDs via Get-WUGDevice."
            $allDevices = Get-WUGDevice -View id
            if ($allDevices) { $collectedDeviceIds = @($allDevices.id) }
            if ($collectedDeviceIds.Count -eq 0) { Write-Warning "No devices found."; return }
            Write-Verbose "Found $($collectedDeviceIds.Count) devices."
        }

        # Total number of devices to process
        $totalDevices = $collectedDeviceIds.Count
        Write-Debug "Total Devices to Process: $totalDevices"

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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDAxAue7eWLqHbI
# P/EC47LOMNllE0qc1tXaEgePu9iiIaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgooagKKDFSqflqrMujlR1KLTdrq8rLv6T
# Xh79el6LlXowDQYJKoZIhvcNAQEBBQAEggIALRq6RjTYK9E9w6p/M5c1Ekf7Sk1s
# hBkaWlBdXBXhIMMbuTcMN3CwQGgvY8QIH9VAhmEm0paxxmIDWdBy5Nrr6h9/AMA6
# ut0K+uB0bHwKsKV5fzqMbWihlQXREuml2omkLL0knvEMleCNGoiQjYqvndZQxx9N
# n7ZxEIe/mOILbY7JF/9XtyaZh3dPW72eftm6MN/yOSDWZ1iosI6uIEEFRhIzngEN
# gH87Y6DrveiLgoCdHVR5e/tety6CcVV5KRTRnJJ1dnaqQWedtlnoLIbFbMcuoEy/
# AzX+ahhCeQxlDfvxhWjlQwSBH822MSnfi1ttnMAkZFQv+PZwpnodlE1HCXRfjqsz
# FtKHMNTUGHWTNT6e62ZZkCGFtPlRlVNIdt0DzV0o/OByPN8pB6GCLKLrmjF/sSRV
# /hCXfHbEM+/mY8ki/7wTI8X5IIq1B6I+ZIMG6s66keXr1Wcr9Y/dX56gOShuajWV
# xVLN4uCoPA3PW9fV7bWj1ueT+zMRYhQxnAAzqzorG8GS1pFSsopyv3qeREKKQ9Ko
# F6CDkULirv8y+zO8EEsV4r8dwxeDWYb1DS01exrDhRSWnunHsT5DWzw/xZxrPQTA
# sWBvUYs8Kr7Z3rQkCBvBda6NiiPjU5tUKPE7amTTIqcnvZmVqMlcBBB9IJ56Cj8k
# XrfyE+j3MfeXM98=
# SIG # End signature block
