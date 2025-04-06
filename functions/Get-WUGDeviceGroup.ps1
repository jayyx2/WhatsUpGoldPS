<#
.SYNOPSIS
Retrieves device groups from WhatsUp Gold by GroupId or based on specified search criteria.

.DESCRIPTION
The `Get-WUGDeviceGroup` function retrieves device groups from WhatsUp Gold using the REST API. It allows you to:

- Retrieve specific device groups by their `GroupId` using the `/api/v1/device-groups/{groupId}` endpoint.
- Search for device groups based on criteria such as name (`SearchValue`), group type (`GroupType`), and view level (`View`) using the `/api/v1/device-groups/-` endpoint.

The function supports pagination and handles large result sets efficiently.

.PARAMETER GroupId
Specifies one or more GroupId(s) of the device groups to retrieve. When this parameter is used, the function retrieves the specified device groups using the `/api/v1/device-groups/{groupId}` endpoint. This parameter belongs to the 'ByGroupId' parameter set.

.PARAMETER SearchValue
Specifies a search value to filter device groups by name. The function uses the `/api/v1/device-groups/-` endpoint to search for device groups whose names contain the specified value. This parameter belongs to the 'BySearch' parameter set.

.PARAMETER View
Specifies the level of detail for the device group information returned. Valid options are:

- `summary`: Returns basic information about the device groups.
- `detail`: Returns detailed information, including group type, monitor state, and device counts.

Default value is `detail`. This parameter is available in both parameter sets.

.PARAMETER GroupType
Specifies the type of device groups to retrieve. Valid options are:

- `all`: Retrieves all types of device groups.
- `static_group`: Retrieves static device groups.
- `dynamic_group`: Retrieves dynamic device groups.
- `layer2`: Retrieves Layer 2 device groups.

Default value is `all`. This parameter belongs to the 'BySearch' parameter set.

.PARAMETER Limit
Specifies the maximum number of device groups to return per page. Valid range is 1 to 250. Default is 250. This parameter belongs to the 'BySearch' parameter set.

.EXAMPLE
# Example 1: Retrieve specific device groups by GroupId
$groupIds = @(101, 102, 103)
$groups = Get-WUGDeviceGroup -GroupId $groupIds -View 'detail'

# Output the groups
$groups | Format-Table

.EXAMPLE
# Example 2: Search for device groups with "Server" in the name
$groups = Get-WUGDeviceGroup -SearchValue "Server" -GroupType "static_group" -Limit 100

# Output the groups
$groups | Format-Table

.NOTES
Author: Jason Alberino (jason@wug.ninja)
Created: 2023-04-15
Last Modified: 2024-09-28
Reference: 
- [WhatsUp Gold REST API - Get Device Group by ID](https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/DeviceGroup_GetDeviceGroup)
- [WhatsUp Gold REST API - List Device Groups](https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/DeviceGroup_ListGroups)

This function uses parameter sets to distinguish between retrieving device groups by `GroupId` and searching with other parameters:

- **ByGroupId Parameter Set**: Uses the `/api/v1/device-groups/{groupId}` endpoint to retrieve specific device groups.
- **BySearch Parameter Set**: Uses the `/api/v1/device-groups/-` endpoint to search for device groups based on criteria.

#>
function Get-WUGDeviceGroup {
    [CmdletBinding(DefaultParameterSetName = 'BySearch')]
    param (
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByGroupId')][int[]]$GroupId,
        [Parameter(ParameterSetName = 'BySearch')][string]$SearchValue,
        [Parameter(ParameterSetName = 'ByGroupId')][Parameter(ParameterSetName = 'BySearch')][ValidateSet("summary", "detail")][string]$View = 'detail',
        [Parameter(ParameterSetName = 'BySearch')][ValidateSet("all", "static_group", "dynamic_group", "layer2")][string]$GroupType = 'all',
        [Parameter(ParameterSetName = 'BySearch')][ValidateRange(1, 250)][int]$Limit = 250
    )

    begin {
        Write-Debug "Initializing Get-WUGDeviceGroup function."
        Write-Debug "ParameterSetName: $($PSCmdlet.ParameterSetName)"
        Write-Debug "GroupId: $GroupId"
        Write-Debug "SearchValue: $SearchValue"
        Write-Debug "View: $View"
        Write-Debug "GroupType: $GroupType"
        Write-Debug "Limit: $Limit"
        # Initialize the output collection
        $allGroups = @()
        # Base URI
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/device-groups"
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ByGroupId') {
            Write-Debug "ParameterSet: ByGroupId"

            $totalGroups = $GroupId.Count
            $currentGroupIndex = 0

            foreach ($id in $GroupId) {
                $currentGroupIndex++
                $percentComplete = [Math]::Round(($currentGroupIndex / $totalGroups) * 100)

                Write-Progress -Activity "Fetching group information" -Status "Processing Group ID $id ($currentGroupIndex of $totalGroups)" -PercentComplete $percentComplete

                # Construct the URI for each group ID
                $uri = "${baseUri}/${id}?view=${View}"
                Write-Debug "Fetching group info from URI: $uri"

                # Make the API request
                try {
                    $response = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    $deviceGroup = $response.data

                    # Format the output object based on the 'View' parameter
                    if ($View -eq 'detail') {
                        $groupObject = [PSCustomObject]@{
                            Id                    = $deviceGroup.id
                            ParentGroupId         = $deviceGroup.parentGroupId
                            Name                  = $deviceGroup.name
                            Description           = $deviceGroup.description
                            GroupType             = $deviceGroup.details.groupType
                            MonitorState          = $deviceGroup.details.monitorState
                            ChildrenCount         = $deviceGroup.details.childrenCount
                            DeviceChildrenCount   = $deviceGroup.details.deviceChildrenCount
                            DeviceDescendantCount = $deviceGroup.details.deviceDescendantCount
                        }
                    }
                    else {
                        $groupObject = [PSCustomObject]@{
                            Id            = $deviceGroup.id
                            ParentGroupId = $deviceGroup.parentGroupId
                            Name          = $deviceGroup.name
                        }
                    }

                    # Add the group object to the output collection
                    $allGroups += $groupObject
                }
                catch {
                    Write-Error "Error getting device group with ID ${id}: $_"
                }
            }

            # Clear progress
            Write-Progress -Activity "Fetching group information" -Completed
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'BySearch') {
            Write-Debug "ParameterSet: BySearch"

            # Build query parameters
            $queryParams = @{}
            if ($View) { $queryParams['view'] = $View }
            if ($SearchValue) { $queryParams['search'] = $SearchValue }
            if ($GroupType) { $queryParams['groupType'] = $GroupType }
            if ($Limit) { $queryParams['limit'] = $Limit }

            # Build the query string
            $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
            $searchUri = "${baseUri}/-?$queryString"
            Write-Debug "Search URI: $searchUri"

            $currentPageId = $null
            $pageNumber = 0

            do {
                # Check if there is a current page ID and modify the URI accordingly
                if ($null -ne $currentPageId) {
                    $currentUri = "$searchUri&pageId=$currentPageId"
                }
                else {
                    $currentUri = $searchUri
                }

                Write-Debug "Fetching groups from URI: $currentUri"

                try {
                    $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'
                    Write-Debug "Result from Get-WUGAPIResponse: $result"

                    if ($null -ne $result.data.groups) {
                        foreach ($group in $result.data.groups) {
                            if ($View -eq 'detail') {
                                $groupObject = [PSCustomObject]@{
                                    Id                    = $group.id
                                    ParentGroupId         = $group.parentGroupId
                                    Name                  = $group.name
                                    Description           = $group.description
                                    GroupType             = $group.details.groupType
                                    MonitorState          = $group.details.monitorState
                                    ChildrenCount         = $group.details.childrenCount
                                    DeviceChildrenCount   = $group.details.deviceChildrenCount
                                    DeviceDescendantCount = $group.details.deviceDescendantCount
                                }
                            }
                            else {
                                $groupObject = [PSCustomObject]@{
                                    Id            = $group.id
                                    ParentGroupId = $group.parentGroupId
                                    Name          = $group.name
                                }
                            }
                            $allGroups += $groupObject
                        }
                    }

                    $currentPageId = $result.paging.nextPageId
                    $pageNumber++

                    # Update progress
                    if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                        $percentComplete = ($pageNumber / $result.paging.totalPages) * 100
                        Write-Progress -Activity "Retrieving device groups" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete $percentComplete
                    } else {
                        Write-Progress -Activity "Retrieving device groups" -Status "Processing page $pageNumber" -PercentComplete (($pageNumber % 100))
                    }
                }
                catch {
                    Write-Error "Error fetching device groups: $_"
                    break # Ensure exit from loop on error
                }
            } while ($null -ne $currentPageId)

            # Clear progress
            Write-Progress -Activity "Retrieving device groups" -Completed
        }
        else {
            Write-Error "Invalid parameter set."
        }
    }

    end {
        Write-Debug "Completed Get-WUGDeviceGroup function"
        return $allGroups
    }
}
# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUhMwFA3/JRoDnoA8KXnDTksWw
# 7k2gghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQU/QULMIpOUdO9fPTZOnt0ZYqT
# mMwwDQYJKoZIhvcNAQEBBQAEggIAsQzyW89LbE+xxfd9GxIT/5emsEfNA0k1rKed
# h50MJnB7HOAP5rjtTaun3SUfjhZy/Qp8BxpSjO4hTYt22vOlMb+vbjtP9DypUxma
# lY/dx7W9UNANLqUxwrQtSKtmf1VYQzBxTlU5HKd9C53Uo+Nxp0G5Oau64ZSmRo3d
# xe/ltj9W+butGg6jI7tCQvslfNlV91sgur4IV/CtxTlgDlCh9gHY/34iT1dbN7C6
# Aq6B6bnCSFIASOFxbtA/te6KPpxoMau2lXEnwnI8lhdq9KGGQsDbkrG/RgxSNBUp
# 0mN4zB1VjXkXP+wNeYPRRapORvSaxxLTfpZuQpPRKQxy2nZBuqxDhXps6KU0rdL4
# Gh7iI9gzlgjxEVUPQsYwGNY4tSnTsxvDn+eOlJNJGH0HRaWXCNV+NGIISjtFe1Ii
# UIEGQDFSKwBTDlbvMmUZKmNy8ciUEtp4n9h86YmQKLEneQoVhwr8gz03N9a9fyfz
# YPCFoSaa8ETHMod+kZ11kTuPzf0gUV0HIPawAcGsOXcylMgvLrARJQe6q/M/pBI5
# SuafFyNZ095Y6dHcPmKan2RddCj/Eokq1dSlxGG5EtRfbJjTa5I5xXu7go+Na2Es
# 1QgvMOvlgFMh2X8WSapQAS6MjOguvpLHjW8mMGOgSbjTlqWJuU0VSqZHVXKsZPDA
# 4VAblEM=
# SIG # End signature block
