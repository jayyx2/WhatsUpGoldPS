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
function Get-WUGDeviceReportDiskSpaceFree {
    [CmdletBinding()]param (
        [Parameter(Mandatory = $true)][array]$DeviceId,
        [ValidateSet("today", "lastPolled", "yesterday", "lastWeek", "lastMonth", "lastQuarter", "weekToDate", "monthToDate", "quarterToDate", "lastNSeconds", "lastNMinutes", "lastNHours", "lastNDays", "lastNWeeks", "lastNMonths", "custom")][string]$Range,
        [string]$RangeStartUtc,
        [string]$RangeEndUtc,
        [int]$RangeN,
        [ValidateSet("defaultColumn", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")][string]$SortBy,
        [ValidateSet("asc", "desc")][string]$SortByDir,
        [ValidateSet("noGrouping", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")][string]$GroupBy,
        [ValidateSet("asc", "desc")][string]$GroupByDir,
        [ValidateSet("true", "false")][string]$ApplyThreshold,
        [ValidateSet("true", "false")][string]$OverThreshold,
        [double]$ThresholdValue,
        [int]$BusinessHoursId,
        [ValidateSet("true", "false")][string]$RollupByDevice,
        [string]$PageId,
        [ValidateRange(0, 250)][int]$Limit
    ) 

    begin {
        #Input validation
        if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
        if ((Get-Date) -ge $global:expiry) { Write-Error "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
        if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
        #Set static variables
        $finaloutput = @()
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/devices"
        $endUri = "disk-free-space"
        $queryString = ""
        $totalDevices = $DeviceId.Count
        $currentDeviceIndex = 0
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
    }

    process {
        foreach ($id in $DeviceId) {
            $currentDeviceIndex++
            $percentCompleteDevices = [Math]::Round(($currentDeviceIndex / $totalDevices) * 100, 2)
            # Main progress for device processing with Id 1
            Write-Progress -Id 1 -Activity "Fetching device report ${endUri} for $totalDevices devices" -Status "Processing Device $currentDeviceIndex of $totalDevices (DeviceID: $id)" -PercentComplete $percentCompleteDevices
             
            $currentPageId = $null
            $pageCount = 0
            
            do {
                if ($currentPageId) {
                    $uri = "${baseUri}/${id}/reports/${endUri}?pageId=$currentPageId"
                    if(!$null -eq $queryString){$uri += "&${queryString}"}
                } else {
                    $uri = "${baseUri}/${id}/reports/${endUri}?${queryString}"
                }
                try {
                    $result = Get-WUGAPIResponse -uri $uri -method "GET"
                    #Conditional data addtions/conversions
                    foreach ($data in $result.data) {
                        $data.minFree = [math]::Round($data.minFree / 1073741824, 2)
                        $data.maxFree = [math]::Round($data.maxFree / 1073741824, 2)
                        $data.avgFree = [math]::Round($data.avgFree / 1073741824, 2)
                        $data.size = [math]::Round($data.size / 1073741824, 2)
                        # Calculate percent free and add it as a new property
                        $percentFree = if ($data.size -gt 0) { [math]::Round(($data.avgFree / $data.size) * 100, 2) } else { 0 }
                        $data | Add-Member -NotePropertyName 'percentFree' -NotePropertyValue $percentFree
                        foreach ($series in $data.series) {
                            $series.avgFree = [math]::Round($series.avgFree / 1073741824, 2)
                            $series.minFree = [math]::Round($series.minFree / 1073741824, 2)
                            $series.maxFree = [math]::Round($series.maxFree / 1073741824, 2)
                        }
                    }
                    $finaloutput += $result.data
                    $currentPageId = $result.paging.nextPageId
                    $pageCount++
    
                    # Page progress for the current device with Id 2
                    if ($result.paging.totalPages) {
                        $percentCompletePages = ($pageCount / $result.paging.totalPages) * 100
                        Write-Progress -Id 2 -Activity "Fetching device report ${endUri} for deviceID: $id" -Status "Page $pageCount of $($result.paging.totalPages)" -PercentComplete $percentCompletePages
                    }
                    else {
                        # Indicate ongoing progress if total pages aren't known
                        Write-Progress -Id 2 -Activity "Fetching device report ${endUri} for deviceID: $id" -Status "Processing page $pageCount" -PercentComplete 0
                    }
    
                }
                catch {
                    Write-Error "Error fetching device report ${endUri} for DeviceID ${id}: $_"
                    $currentPageId = $null
                }
    
            } while ($currentPageId)
    
            # Clear the page progress for the current device after all pages are processed
            Write-Progress -Id 2 -Activity "Fetching device report ${endUri} for DeviceID: $id" -Status "Completed" -Completed
        }
    
        # Clear the main device progress after all devices are processed
        Write-Progress -Id 1 -Activity "Fetching device report ${endUri} for $totalDevices devices" -Status "All devices processed" -Completed
    }
    

    end {
        return $finaloutput
    }
}
# SIG # Begin signature block
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBh14/1TxPim2Qu
# UAHjgTZjPkzC3WThOVnoWXwqm9PX3aCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BgkqhkiG9w0BCQQxIgQgO5W4HYqS1nTvu+I7M1H8ul/H0sNaLrtXhV35RtyiRWYw
# DQYJKoZIhvcNAQEBBQAEggIAaZB8su0+nk8Cv6YLGMkSR+A0CuQZdwkwwUVQ8X7s
# dPt5pEX6ErnUb6Uo8xUE1KVJ+JOqEO/8sg8t9ovUT8WfrjQkOry2hk/NrMiRBpZb
# H127yCFkmY2NaRGewa+1O/lRz/3B/Z0E0ZMW/LMlxpqbKebBownhMdHr0pG8iPqt
# tJqYKsz+el1nQzu7YHBUK7srxt3pg4U1TEAE/hW02zkwkcVPgA+8hIfl2PXtdtGs
# KXaztrFVi1FKMMUf3HL2bTVLLMDLUIe9khFWqn7AsPkNbWxg/mo4YAjYi75M67X2
# LMu9Zsy3Ff0NP8+5CTHyi8EiFTDwfJAJqaqUCM2uXVx3gN+EmxtHqEHmod0gpkuP
# HLClh4/7nM5O5Qv8ximJX9Ay1H9CkIIxIUKHODUToY6Xnekt1gfIzmNgQJ4Gu/1D
# 3MZbNU1qwcquG0pYKXTjRIyxOfhgfFEDE8Jn2l+Su3VaSoWVb5QNXihlb8BmYC8k
# FZCHPw08kDQA/0OtultiDcXEo7VH9KAvrBl+1FbKrDJzkA14KeIwQFGkzcxHeZqw
# GG+Edjg17sUmuB6l6NyMTAdrq6x8CLcZn0u5hU2+EMZGfIgJt4l5D2QS1fkmjZwZ
# D+iJGKCxUqDFA8bYcKXNrLSixda2jvfXt2zVyZdK66ZSBuzw3q8y/lxohBaT20I2
# fB8=
# SIG # End signature block
