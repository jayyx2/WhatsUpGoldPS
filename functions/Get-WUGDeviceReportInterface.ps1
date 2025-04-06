<#
.SYNOPSIS
Retrieves Interface utilization reports for specified devices from WhatsUp Gold.

.DESCRIPTION
The Get-WUGDeviceReportInterface function fetches Interface utilization reports for a list of device IDs from WhatsUp Gold. It supports filtering by time range, sorting, grouping, applying thresholds, and automatically handles pagination. The function provides progress feedback during execution.

.PARAMETER DeviceId
An array of device IDs for which Interface utilization reports are requested. This parameter is mandatory and accepts multiple values.

.PARAMETER Range
Specifies the time range for the report. Valid entries include:
- "today": Returns data generated today.
- "lastPolled": Returns data from the last poll.
- "yesterday": Returns data generated yesterday.
- "lastWeek", "lastMonth", "lastQuarter": Data from the last week, month, or quarter.
- "weekToDate", "monthToDate", "quarterToDate": Data since the beginning of the current week, month, or quarter.
- "lastNSeconds", "lastNMinutes", "lastNHours", "lastNDays", "lastNWeeks", "lastNMonths": Data from the last N units of time.
- "custom": Data between 'rangeStartUtc' and 'rangeEndUtc'.
Default is 'today'.

.PARAMETER RangeStartUtc
The start date for the report in UTC format (YYYY-MM-DDTHH:MM:SSZ). Required if Range is set to 'custom'.

.PARAMETER RangeEndUtc
The end date for the report in UTC format (YYYY-MM-DDTHH:MM:SSZ). Required if Range is set to 'custom'.

.PARAMETER RangeN
Used with 'lastN' ranges as a multiplier to specify the number for the data filter. For example, 'lastNHours=2' would fetch data from the last 2 hours.

.PARAMETER SortBy
Specifies the field to sort the report by. Valid options include "defaultColumn","id","deviceName","interfaceName","interfaceId","pollTimeUtc","timeFromLastPollSeconds","rxMin","rxMax","rxAvg","rxTotal","txMin","txMax","txAvg","txTotal","totalAvg"

.PARAMETER SortByDir
The direction to sort the report. Options are 'asc' for ascending or 'desc' for descending. Default is 'desc'.

.PARAMETER GroupBy
Specifies the field to group the report by. Similar options as SortBy.

.PARAMETER GroupByDir
The direction to group the report. Options are 'asc' or 'desc'.

.PARAMETER ApplyThreshold
Indicates whether the threshold filter is applied. Accepts 'true' or 'false'.

.PARAMETER OverThreshold
Indicates if the threshold value is applied when over or under. Accepts 'true' or 'false'.

.PARAMETER ThresholdValue
The threshold filter value as a string. Default is '0.0'.

.PARAMETER BusinessHoursId
The business hour filter ID to apply. Default is '0' (no filter applied).

.PARAMETER RollupByDevice
Indicates if the report should be summarized at the device level. Accepts 'true' or 'false'. Default is 'true'.

.PARAMETER PageId
Used for pagination, specifies the page ID to start from.

.PARAMETER Limit
Limits the number of entries per page. Default is 25.

.EXAMPLE
PS> Get-WUGDeviceReportInterface -DeviceId @("1", "2", "3") -Range "lastWeek"

Fetches last week's Interface utilization reports for devices with IDs 1, 2, and 3.

.EXAMPLE
PS> Get-WUGDeviceReportInterface -DeviceId @("4") -Range "custom" -RangeStartUtc "2023-01-01T00:00:00Z" -RangeEndUtc "2023-01-07T23:59:59Z"

Fetches Interface utilization reports for device 4 for the first week of January 2023.

.NOTES
Author: Jason Alberino (jason@wug.ninja) 2024-03-24
Modified: 2024-03-29

Reference: https://docs.ipswitch.com/NM/WhatsUpGold2022_1/02_Guides/rest_api/#operation/DeviceReport_DeviceInterfaceUtilizationReport
Provides an interface to WhatsUp Gold's REST API for fetching detailed Interface utilization reports across devices, with support for extensive filtering and pagination.
#>
function Get-WUGDeviceReportInterface {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
        [ValidateSet("today", "lastPolled", "yesterday", "lastWeek", "lastMonth", "lastQuarter", "weekToDate", "monthToDate", "quarterToDate", "lastNSeconds", "lastNMinutes", "lastNHours", "lastNDays", "lastNWeeks", "lastNMonths", "custom")][string]$Range,
        [string]$RangeStartUtc,
        [string]$RangeEndUtc,
        [int]$RangeN = 1,
        [ValidateSet("defaultColumn","id","deviceName","interfaceName","interfaceId","pollTimeUtc","timeFromLastPollSeconds","rxMin","rxMax","rxAvg","rxTotal","txMin","txMax","txAvg","txTotal","totalAvg")][string]$SortBy,
        [ValidateSet("asc", "desc")][string]$SortByDir,
        [ValidateSet("noGrouping","id","deviceName","interfaceName","interfaceId","pollTimeUtc","timeFromLastPollSeconds","rxMin","rxMax","rxAvg","rxTotal","txMin","txMax","txAvg","txTotal","totalAvg")][string]$GroupBy,
        [ValidateSet("asc", "desc")][string]$GroupByDir,
        [ValidateSet("true", "false")][string]$ApplyThreshold,
        [ValidateSet("true", "false")][string]$OverThreshold,
        [string]$ThresholdValue,
        [int]$BusinessHoursId,
        [ValidateSet("true", "false")][string]$RollupByDevice,
        [string]$PageId,
        [ValidateRange(0, 250)][int]$Limit
    )

    begin {
        # Initialize collection for DeviceIds
        $collectedDeviceIds = @()

        # Debug message with all parameters
        Write-Debug "Function: Get-WUGDeviceReportInterface -- DeviceId:${DeviceId} Range:${Range} RangeStartUtc:${RangeStartUtc} RangeEndUtc:${RangeEndUtc} RangeN:${RangeN} SortBy:${SortBy} SortByDir:${SortByDir} GroupBy:${GroupBy} GroupByDir:${GroupByDir} ApplyThreshold:${ApplyThreshold} OverThreshold:${OverThreshold} ThresholdValue:${ThresholdValue} BusinessHoursId:${BusinessHoursId} RollupByDevice:${RollupByDevice} PageId:${PageId} Limit:${Limit}"

        # Set static variables
        $finaloutput = @()
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/devices"
        $endUri = "interface-utilization"
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

                    # Conditional data additions/conversions
                    #foreach ($data in $result.data) {
                    #    #Do Nothing
                    #}

                    Write-Debug "Data Received Count: $($result.data.Count)"
                    $finaloutput += $result.data
                    Write-Debug "Accumulated Data Count: $($finaloutput.Count)"
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

                } catch {
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
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUPFSfmkrJxmwj5liny/6fdjMq
# oQOgghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQU+iY+SrNBN6fjG8u3jZJZx5n2
# kxgwDQYJKoZIhvcNAQEBBQAEggIAgDXqMx+mUFhyWSCvIwUUyu2wYOHEP1LAOq1H
# j70fbTAn+E4FHwMhEKnzLB7mq5aA6vGaaXu5IJwHpEgKORD9L8DFeV6jqXZB/Ncf
# T+3Uuai+NUlZ18gJWQ+yqQEvEC1/fSS5Tr5rp21PDtLhDldb79ZJdLynee2fVhAM
# qk5TFSt2tTxtRwVU7elWURfpEBgNQ3NCKfwvnsGHqn6r9Vb72X/YMdvAxY7BKtb5
# qo2fmnPOOqtDngLpsJGSSBVcA20nmeE38BGl5sTmAOwnyZSuHpOrYdk7JvGbkQHy
# K7iEA3JacHH3AVhjDmpamTh7dTV2566nu54lbhSz2e0ne0c69+gE10L5KHUXKI+H
# Zd4grweX+0NE/URycNr9bVaa8KLXSPlbuwFToWcDgrKIldnLMhAwBZuZnU8G4F0n
# AqYU3MHiPTZVTp+eHMCgSCigRex1q84YXz6bZZt4jxR0rndyGESDcaQgnFqrzILy
# 8m+CpBCC1Mu8lR0o2G3F5i96sPxgCTcGDNlRyfL6dFgmTdmSGOAdUZrBkBen+EdH
# Cc+n2CHsF8D4O/GJf944NBLlS2lRjbv2TGObvfscrmlgH1aqYrHQdGN4Ti1ynIqw
# kaYym9IRF3fhDjul9ZQgNigMc70lcWd8JmXcJKHRu0XpG2V4jeZHs4jHOtgCzueo
# WOkdqkc=
# SIG # End signature block
