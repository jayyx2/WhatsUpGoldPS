<#
.SYNOPSIS
    Retrieves performance and availability reports for one or more WhatsUp Gold device groups.

.DESCRIPTION
    Get-WUGDeviceGroupReport queries the WhatsUp Gold REST API for group-level reports across multiple
    report types such as CPU, memory, disk, interface, ping, state change, and maintenance mode.
    Results are automatically paginated. Supports hierarchy inclusion, sorting, grouping, thresholds,
    time ranges, and business hours filtering.

.PARAMETER GroupId
    One or more device group IDs to retrieve reports for. Accepts pipeline input and the alias 'id'. Required.

.PARAMETER ReportType
    The type of report to retrieve. Required. Valid values: Cpu, Disk, DiskSpaceFree, Interface,
    InterfaceDiscards, InterfaceErrors, InterfaceTraffic, Memory, PingAvailability, PingResponseTime, StateChange, Maintenance.

.PARAMETER ReturnHierarchy
    Include devices from descendant groups. Valid values: true, false. Default from API: false (only devices in the specified group).

.PARAMETER Range
    The time range preset for the report. Valid values: today, lastPolled, yesterday, lastWeek, lastMonth,
    lastQuarter, weekToDate, monthToDate, quarterToDate, lastNSeconds, lastNMinutes, lastNHours, lastNDays,
    lastNWeeks, lastNMonths, custom.

.PARAMETER RangeStartUtc
    The start date/time in UTC for a custom time range. Used when Range is set to 'custom'.

.PARAMETER RangeEndUtc
    The end date/time in UTC for a custom time range. Used when Range is set to 'custom'.

.PARAMETER RangeN
    The number of time units for lastN* range types (e.g., lastNHours with RangeN=4 means last 4 hours). Default: 1.

.PARAMETER SortBy
    The column to sort results by. Valid values depend on the ReportType selected.

.PARAMETER SortByDir
    The sort direction. Valid values: asc, desc. Default: desc.

.PARAMETER GroupBy
    The column to group results by. Valid values depend on the ReportType selected.

.PARAMETER GroupByDir
    The group sort direction. Valid values: asc, desc.

.PARAMETER ApplyThreshold
    Whether to apply a threshold filter to the results. Valid values: true, false.

.PARAMETER OverThreshold
    When ApplyThreshold is true, determines whether to return values over or under the threshold. Valid values: true, false.

.PARAMETER ThresholdValue
    The numeric threshold value to filter against. Default: 0.0.

.PARAMETER BusinessHoursId
    The ID of a business hours profile to restrict the report to. Default: 0 (all hours).

.PARAMETER RollupByDevice
    Whether to roll up (aggregate) results per device instead of individual resources. Valid values: true, false.

.PARAMETER PageId
    The page identifier for retrieving a specific page of paginated results.

.PARAMETER Limit
    The maximum number of results per page. Valid range: 0-250.

.EXAMPLE
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Cpu -Range lastWeek

    Returns the CPU utilization report for the root device group over the last week.

.EXAMPLE
    Get-WUGDeviceGroupReport -GroupId 5 -ReportType Memory -Range lastNHours -RangeN 8 -ReturnHierarchy true

    Returns the memory utilization report for group 5 and all its descendant groups over the last 8 hours.

.EXAMPLE
    Get-WUGDeviceGroupReport -GroupId 10 -ReportType PingAvailability -Range custom -RangeStartUtc '2026-03-01T00:00:00Z' -RangeEndUtc '2026-03-06T00:00:00Z'

    Returns the ping availability report for group 10 within a custom UTC date range.

.EXAMPLE
    Get-WUGDeviceGroupReport -GroupId 3,7 -ReportType Disk -Range lastMonth -ApplyThreshold true -OverThreshold true -ThresholdValue 90

    Returns disk utilization data for groups 3 and 7 over the last month where values exceed 90%.

.EXAMPLE
    1..5 | Get-WUGDeviceGroupReport -ReportType StateChange -Range today -SortBy deviceName -SortByDir asc

    Pipes group IDs 1 through 5 and retrieves today's state change report sorted by device name ascending.

.EXAMPLE
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Maintenance -ReturnHierarchy true

    Returns the maintenance mode report for all devices across the entire group hierarchy.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#tag/DeviceGroupReport
#>
function Get-WUGDeviceGroupReport {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int[]]$GroupId = @(-2),

        [Parameter(Mandatory = $true)]
        [ValidateSet("Cpu", "Disk", "DiskSpaceFree", "Interface", "InterfaceDiscards", "InterfaceErrors", "InterfaceTraffic", "Memory", "PingAvailability", "PingResponseTime", "StateChange", "Maintenance")]
        [string]$ReportType,

        [ValidateSet("true", "false")]
        [string]$ReturnHierarchy,

        [ValidateSet("today", "lastPolled", "yesterday", "lastWeek", "lastMonth", "lastQuarter", "weekToDate", "monthToDate", "quarterToDate", "lastNSeconds", "lastNMinutes", "lastNHours", "lastNDays", "lastNWeeks", "lastNMonths", "custom")]
        [string]$Range,

        [string]$RangeStartUtc,
        [string]$RangeEndUtc,

        [int]$RangeN = 1,

        [string]$SortBy,

        [ValidateSet("asc", "desc")]
        [string]$SortByDir = "desc",

        [string]$GroupBy,

        [ValidateSet("asc", "desc")]
        [string]$GroupByDir,

        [ValidateSet("true", "false")]
        [string]$ApplyThreshold,

        [ValidateSet("true", "false")]
        [string]$OverThreshold,

        [double]$ThresholdValue,

        [int]$BusinessHoursId,

        [ValidateSet("true", "false")]
        [string]$RollupByDevice,

        [string]$PageId,

        [ValidateRange(0, 250)]
        [int]$Limit
    )

    begin {
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error "WhatsUpServerBaseURI is not set. Please run Connect-WUGServer to establish a connection."
            return
        }

        Write-Verbose "Starting Get-WUGDeviceGroupReport -ReportType $ReportType"

        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/device-groups"

        # Map ReportType to API endpoint and valid SortBy/GroupBy values
        $reportConfig = @{
            "Cpu" = @{
                Endpoint = "cpu-utilization"
                SortBy   = @("defaultColumn", "id", "deviceName", "cpu", "cpuId", "pollTimeUtc", "timeFromLastPollSeconds", "minPercent", "maxPercent", "avgPercent")
                GroupBy  = @("noGrouping", "id", "deviceName", "cpu", "cpuId", "pollTimeUtc", "timeFromLastPollSeconds", "minPercent", "maxPercent", "avgPercent")
            }
            "Disk" = @{
                Endpoint = "disk-utilization"
                SortBy   = @("defaultColumn", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minUsed", "maxUsed", "avgUsed", "avgFree", "minPercent", "maxPercent", "avgPercent")
                GroupBy  = @("noGrouping", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "mi", "ma", "av")
            }
            "DiskSpaceFree" = @{
                Endpoint = "disk-free-space"
                SortBy   = @("defaultColumn", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")
                GroupBy  = @("noGrouping", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")
            }
            "Interface" = @{
                Endpoint = "interface-utilization"
                SortBy   = @("defaultColumn", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
                GroupBy  = @("noGrouping", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
            }
            "InterfaceDiscards" = @{
                Endpoint = "interface-discards"
                SortBy   = @("defaultColumn", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
                GroupBy  = @("noGrouping", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
            }
            "InterfaceErrors" = @{
                Endpoint = "interface-errors"
                SortBy   = @("defaultColumn", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
                GroupBy  = @("noGrouping", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
            }
            "InterfaceTraffic" = @{
                Endpoint = "interface-traffic"
                SortBy   = @("defaultColumn", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
                GroupBy  = @("noGrouping", "id", "deviceName", "interfaceName", "interfaceId", "pollTimeUtc", "timeFromLastPollSeconds", "rxMin", "rxMax", "rxAvg", "rxTotal", "txMin", "txMax", "txAvg", "txTotal", "totalAvg")
            }
            "Memory" = @{
                Endpoint = "memory-utilization"
                SortBy   = @("defaultColumn", "id", "deviceName", "memory", "memoryId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minUsed", "maxUsed", "avgUsed", "minPercent", "maxPercent", "avgPercent")
                GroupBy  = @("noGrouping", "id", "deviceName", "memory", "memoryId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minUsed", "maxUsed", "avgUsed", "minPercent", "maxPercent", "avgPercent")
            }
            "PingAvailability" = @{
                Endpoint = "ping-availability"
                SortBy   = @("defaultColumn", "id", "deviceName", "interfaceId", "interfaceName", "packetsLost", "packetsSent", "percentAvailable", "percentPacketLoss", "totalTimeMinutes", "timeUnavailableMinutes", "pollTimeUtc", "timeFromLastPollSeconds")
                GroupBy  = @("noGrouping", "id", "deviceName", "interfaceId", "interfaceName", "packetsLost", "packetsSent", "percentAvailable", "percentPacketLoss", "totalTimeMinutes", "timeUnavailableMinutes", "pollTimeUtc", "timeFromLastPollSeconds")
            }
            "PingResponseTime" = @{
                Endpoint = "ping-response-time"
                SortBy   = @("defaultColumn", "id", "deviceName", "interfaceId", "interfaceName", "minMilliSec", "maxMilliSec", "avgMilliSec", "pollTimeUtc", "timeFromLastPollSeconds")
                GroupBy  = @("noGrouping", "id", "deviceName", "interfaceId", "interfaceName", "minMilliSec", "maxMilliSec", "avgMilliSec", "pollTimeUtc", "timeFromLastPollSeconds")
            }
            "StateChange" = @{
                Endpoint = "state-change"
                SortBy   = @("defaultColumn", "deviceName", "monitorTypeName", "stateName", "startTimeUtc", "endTimeUtc", "totalSeconds", "result")
                GroupBy  = @("noGrouping", "deviceName", "monitorTypeName", "stateName", "startTimeUtc", "endTimeUtc", "totalSeconds", "result")
            }
            "Maintenance" = @{
                Endpoint = "device-maintenance-mode"
                SortBy   = @("defaultColumn", "id", "name", "startTimeUtc", "durationSeconds", "maintenanceMode", "userName", "reason")
                GroupBy  = @("defaultColumn", "id", "name", "startTimeUtc", "durationSeconds", "maintenanceMode", "userName", "reason")
            }
        }

        $config = $reportConfig[$ReportType]
        $reportEndpoint = $config.Endpoint

        # Validate SortBy against the allowed values for this report type
        if ($SortBy -and $SortBy -notin $config.SortBy) {
            Write-Error "Invalid SortBy value '$SortBy' for report type '$ReportType'. Valid values: $($config.SortBy -join ', ')"
            return
        }

        # Validate GroupBy against the allowed values for this report type
        if ($GroupBy -and $GroupBy -notin $config.GroupBy) {
            Write-Error "Invalid GroupBy value '$GroupBy' for report type '$ReportType'. Valid values: $($config.GroupBy -join ', ')"
            return
        }

        # Build query string from bound parameters
        $queryParams = @{}
        if ($ReturnHierarchy)   { $queryParams["returnHierarchy"] = $ReturnHierarchy }
        if ($Range)             { $queryParams["range"] = $Range }
        if ($RangeStartUtc)     { $queryParams["rangeStartUtc"] = $RangeStartUtc }
        if ($RangeEndUtc)       { $queryParams["rangeEndUtc"] = $RangeEndUtc }
        if ($PSBoundParameters.ContainsKey('RangeN')) { $queryParams["rangeN"] = $RangeN }
        if ($SortBy)            { $queryParams["sortBy"] = $SortBy }
        if ($SortByDir)         { $queryParams["sortByDir"] = $SortByDir }
        if ($GroupBy)           { $queryParams["groupBy"] = $GroupBy }
        if ($GroupByDir)        { $queryParams["groupByDir"] = $GroupByDir }
        if ($PSBoundParameters.ContainsKey('ApplyThreshold')) { $queryParams["applyThreshold"] = $ApplyThreshold }
        if ($PSBoundParameters.ContainsKey('OverThreshold'))  { $queryParams["overThreshold"] = $OverThreshold }
        if ($PSBoundParameters.ContainsKey('ThresholdValue')) { $queryParams["thresholdValue"] = $ThresholdValue }
        if ($BusinessHoursId)   { $queryParams["businessHoursId"] = $BusinessHoursId }
        if ($PSBoundParameters.ContainsKey('RollupByDevice')) { $queryParams["rollupByDevice"] = $RollupByDevice }
        if ($PageId)            { $queryParams["pageId"] = $PageId }
        if ($PSBoundParameters.ContainsKey('Limit')) { $queryParams["limit"] = $Limit }

        $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $collectedGroupIds = @()
        $finalOutput = @()
    }

    process {
        foreach ($id in $GroupId) {
            $collectedGroupIds += $id
        }
    }

    end {
        $totalGroups = $collectedGroupIds.Count
        $currentGroupIndex = 0

        foreach ($id in $collectedGroupIds) {
            $currentGroupIndex++
            $percentCompleteGroups = [Math]::Round(($currentGroupIndex / $totalGroups) * 100, 2)
            Write-Progress -Id 1 -Activity "Fetching $ReportType report for groups" -Status "Processing Group $currentGroupIndex of $totalGroups (GroupID: $id)" -PercentComplete $percentCompleteGroups

            $currentPageId = $null
            $pageCount = 0

            do {
                if ($currentPageId) {
                    $uri = "$baseUri/$id/devices/reports/$reportEndpoint/?pageId=$currentPageId"
                    if ($queryString) { $uri += "&$queryString" }
                } else {
                    $uri = "$baseUri/$id/devices/reports/$reportEndpoint/"
                    if ($queryString) { $uri += "?$queryString" }
                }

                Write-Verbose "API Call: $uri"

                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method "GET"
                    $finalOutput += $result.data
                    $currentPageId = $result.paging.nextPageId
                    $pageCount++

                    if ($result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                        $percentCompletePage = [Math]::Round(($pageCount / $result.paging.totalPages) * 100, 2)
                        Write-Progress -Id 2 -Activity "Fetching $ReportType report for GroupID: $id" -Status "Page $pageCount of $($result.paging.totalPages)" -PercentComplete $percentCompletePage
                    } else {
                        Write-Progress -Id 2 -Activity "Fetching $ReportType report for GroupID: $id" -Status "Processing page $pageCount" -PercentComplete 0
                    }
                }
                catch {
                    Write-Error "Error fetching $ReportType report for GroupID ${id}: $_"
                    $currentPageId = $null
                }
            } while ($currentPageId)

            Write-Progress -Id 2 -Activity "Fetching $ReportType report for GroupID: $id" -Status "Completed" -Completed
        }

        Write-Progress -Id 1 -Activity "Fetching $ReportType report for groups" -Status "All groups processed" -Completed
        return $finalOutput
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBQd5h8Jzwaxc4X
# yjdkVPWSUzKcOzwVz96nA6CTKYDuEqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgiObQFIsUF2aK14MDB0ePqWhzUgOKkKBo
# QtPUW9+EybswDQYJKoZIhvcNAQEBBQAEggIAbC2E1sh4P+ZozZeL7hfD1HQlMmRS
# tE/Y9Axf/iLhcr3dUyDhzfTM0IIvwLIwm2g/KxWo/s+wlULuyO+EKiAkdCLgw+dw
# JrY11LOBRdN5oH/A5G8LIAbjMe2vXDtzM2G6sTmAuXCmi4DXNyK/rHPAuoLyBhk2
# I2kcGqGB2cSD9b7s6rVOA75wvROlE+2og9Tkqe/ZTNyhY5z4sjVXRVpBxyrhIvlF
# HrFLvsERotLXSPtW2jYkCtZwXgUIeYxbM+qJzNxet2NOJGP+K3QoenKRMXf+hRqW
# +RcT/TSVujxoS6Lv8yzVKk0MHu8HKRy0Ior8oL5AaAET2i6Kl8RJC1RrArVanRyJ
# b2vQN4DXpbopj7ziY1hthGhusHdXYAEJU2H+FtUIBpGBcfW5isgcA0UPHjF7Yvp9
# buA2cZBHluJBOo0smor947nnmOxGRULJ/dg2sIovh/2Gh7rt4VIkTvhUh3Bf7Gud
# kWZPMKJistEE8L6f2rCaHpMozInD0uHRPf+OVxPbFtz8Abs3teB+8jSX00ptvlB1
# mPTjH3TYteh5AFKRtal/pWOskFqe0wy/25q+wMseKbmoJXyUJCNf3QYLCH2wY0V0
# cOlZq3mZNNxK82/RcoSHplq6YpjZK8p/1L8F5k5C3/w9GLEUUCPagEF/275Tl/w/
# l8q2kuuP/LlTIro=
# SIG # End signature block
