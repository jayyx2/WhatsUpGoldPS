    <#
    .SYNOPSIS
    Retrieves device attributes from the WhatsUp Gold API.

    .DESCRIPTION
    Fetches attributes for specified devices, with options to filter by names, name contains, value contains, or attribute IDs.
    Supports fetching specific attributes using AttributeId.
    Handles paging and error handling efficiently.

    .PARAMETER DeviceId
    The ID(s) of the device(s) to retrieve attributes from.

    .PARAMETER Names
    An array of attribute names to filter the results.

    .PARAMETER NameContains
    A string to match attribute names that contain this value.

    .PARAMETER ValueContains
    A string to match attribute values that contain this value.

    .PARAMETER AttributeId
    The ID(s) of specific attributes to retrieve.

    .PARAMETER Limit
    The maximum number of attributes to retrieve per device (default is 250).

    .EXAMPLE
    Get-WUGDeviceAttribute -DeviceId 2367 -Names "TestAttribute"

    Retrieves the attribute named "TestAttribute" for device 2367.

    .EXAMPLE
    Get-WUGDeviceAttribute -DeviceId 2367 -AttributeId 28852, 28853

    Retrieves the attributes with IDs 28852 and 28853 for device 2367.

    .NOTES
    When specifying -AttributeId, you can only specify one DeviceId.
    #>
    function Get-WUGDeviceAttribute {
        [CmdletBinding(DefaultParameterSetName = 'Default')]
        param(
            [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Default', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
            [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByNames', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
            [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByNameContains', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
            [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByValueContains', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
            [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByAttributeId', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
            [Alias('id')]
            [int[]]$DeviceId,
    
            [Parameter(Mandatory = $true, ParameterSetName = 'ByNames')]
            [string[]]$Names,
    
            [Parameter(Mandatory = $true, ParameterSetName = 'ByNameContains')]
            [string]$NameContains,
    
            [Parameter(Mandatory = $true, ParameterSetName = 'ByValueContains')]
            [string]$ValueContains,
    
            [Parameter(Mandatory = $true, ParameterSetName = 'ByAttributeId')]
            [int[]]$AttributeId,
    
            [Parameter(ParameterSetName = 'ByNames')]
            [Parameter(ParameterSetName = 'ByNameContains')]
            [Parameter(ParameterSetName = 'ByValueContains')]
            [Parameter(ParameterSetName = 'Default')]
            [ValidateRange(1, 250)]
            [int]$Limit = 250
        )
    
        begin {
            Write-Debug "Initializing Get-WUGDeviceAttribute function."
            Write-Debug "ParameterSetName: $($PSCmdlet.ParameterSetName)"
            Write-Debug "DeviceId: $DeviceId"
            Write-Debug "Names: $Names"
            Write-Debug "NameContains: $NameContains"
            Write-Debug "ValueContains: $ValueContains"
            Write-Debug "AttributeId: $AttributeId"
            Write-Debug "Limit: $Limit"
    
            # Enforce that when -AttributeId is specified, only one DeviceId can be specified
            if ($PSCmdlet.ParameterSetName -eq 'ByAttributeId' -and $DeviceId.Count -gt 1) {
                throw "When specifying -AttributeId, you can only specify one DeviceId."
            }
    
            # Initialize the pipeline flag
            $bpipeline = $false
    
            # Initialize collections
            $finalOutput = @()
            $collectedDeviceInfo = @()
        }
    
        process {
            # Process input objects
            if ($null -ne $_ -and $_.PSObject.Properties.Match('id').Count -gt 0) {
                # Input is a device object
                $inputObject = $_
                $deviceId = $inputObject.id
                $deviceName = $inputObject.name
                $networkAddress = $inputObject.networkAddress
                $hostName = $inputObject.hostName
    
                $collectedDeviceInfo += @{
                    DeviceId       = $deviceId
                    DeviceName     = $deviceName
                    NetworkAddress = $networkAddress
                    HostName       = $hostName
                }
                $bpipeline = $true
                Write-Debug "Pipeline input detected. DeviceId: $deviceId"
            }
            else {
                # Input is an array of Device IDs
                foreach ($id in $DeviceId) {
                    $collectedDeviceInfo += @{
                        DeviceId = $id
                    }
                    Write-Debug "Added DeviceId: $id to collectedDeviceInfo"
                }
            }
        }
    
        end {
            Write-Debug "Processing collected device information."
    
            $totalDevices = $collectedDeviceInfo.Count
            $currentDeviceIndex = 0
    
            foreach ($device in $collectedDeviceInfo) {
                $deviceId = $device.DeviceId
                $deviceName = $device.DeviceName
                $networkAddress = $device.NetworkAddress
                $hostName = $device.HostName
    
                $currentDeviceIndex++
                $devicePercentComplete = [Math]::Round(($currentDeviceIndex / $totalDevices) * 100, 2)
                Write-Progress -Id 1 -Activity "Fetching Attributes" -Status "Processing Device $currentDeviceIndex of $totalDevices (DeviceID: $deviceId)" -PercentComplete $devicePercentComplete
    
                if ($PSCmdlet.ParameterSetName -eq 'ByAttributeId') {
                    # Fetch specific attributes for a single device
                    foreach ($attrId in $AttributeId) {
                        $attributesUri = "$($global:WhatsUpServerBaseURI)/api/v1/devices/$deviceId/attributes/$attrId"
    
                        Write-Verbose "Requesting URI: $attributesUri"
    
                        try {
                            # Make the API call and retrieve the response
                            $result = Get-WUGAPIResponse -Uri $attributesUri -Method GET
    
                            if ($result.data) {
                                $attribute = $result.data
    
                                # Add additional device properties if available
                                if ($bpipeline) {
                                    if ($deviceName) {
                                        $attribute | Add-Member -NotePropertyName "DeviceName" -NotePropertyValue $deviceName -Force
                                    }
                                    if ($networkAddress) {
                                        $attribute | Add-Member -NotePropertyName "NetworkAddress" -NotePropertyValue $networkAddress -Force
                                    }
                                    if ($hostName) {
                                        $attribute | Add-Member -NotePropertyName "HostName" -NotePropertyValue $hostName -Force
                                    }
                                }
    
                                $finalOutput += $attribute
                            }
    
                        }
                        catch {
                            Write-Error "Error fetching attribute ID $attrId for DeviceID ${deviceId}: $($_.Exception.Message)"
                        }
                    }
                }
                else {
                    # Build the query string if filters are specified
                    $queryString = ""
                    if ($PSBoundParameters.ContainsKey('Names') -and $Names -and $Names.Count -gt 0) {
                        foreach ($name in $Names) {
                            if (![string]::IsNullOrWhiteSpace($name)) {
                                $queryString += "names=$([System.Web.HttpUtility]::UrlEncode($name))&"
                            }
                        }
                    }
                    if ($PSBoundParameters.ContainsKey('NameContains') -and ![string]::IsNullOrWhiteSpace($NameContains)) {
                        $queryString += "nameContains=$([System.Web.HttpUtility]::UrlEncode($NameContains))&"
                    }
                    if ($PSBoundParameters.ContainsKey('ValueContains') -and ![string]::IsNullOrWhiteSpace($ValueContains)) {
                        $queryString += "valueContains=$([System.Web.HttpUtility]::UrlEncode($ValueContains))&"
                    }
                    if ($PSBoundParameters.ContainsKey('Limit') -and $Limit -gt 0) {
                        $queryString += "limit=$Limit&"
                    }
                    # Trim the trailing "&" if it exists
                    $queryString = $queryString.TrimEnd('&')
    
                    # Construct the URI for fetching attributes
                    $attributesUri = "$($global:WhatsUpServerBaseURI)/api/v1/devices/$deviceId/attributes/-"
                    if (-not [string]::IsNullOrWhiteSpace($queryString)) {
                        $attributesUri += "?$queryString"
                        Write-Debug "Query String: $queryString"
                    }
    
                    $currentPageId = $null
                    $pageCount = 0
    
                    do {
                        if ($currentPageId) {
                            $uri = "$attributesUri&pageId=$currentPageId"
                        }
                        else {
                            $uri = $attributesUri
                        }
    
                        Write-Verbose "Requesting URI: $uri"
    
                        try {
                            # Make the API call and retrieve the response
                            $result = Get-WUGAPIResponse -Uri $uri -Method GET
    
                            if ($result.data) {
                                foreach ($attribute in $result.data) {
                                    # Add additional device properties if available
                                    if ($bpipeline) {
                                        if ($deviceName) {
                                            $attribute | Add-Member -NotePropertyName "DeviceName" -NotePropertyValue $deviceName -Force
                                        }
                                        if ($networkAddress) {
                                            $attribute | Add-Member -NotePropertyName "NetworkAddress" -NotePropertyValue $networkAddress -Force
                                        }
                                        if ($hostName) {
                                            $attribute | Add-Member -NotePropertyName "HostName" -NotePropertyValue $hostName -Force
                                        }
                                    }
    
                                    $finalOutput += $attribute
                                }
                            }
    
                            $currentPageId = $result.paging.nextPageId
                            $pageCount++
    
                            # Update paging progress
                            if ($result.paging.totalPages) {
                                $percentCompletePages = ($pageCount / $result.paging.totalPages) * 100
                                Write-Progress -Id 2 -Activity "Fetching Attributes for DeviceID: $deviceId" -Status "Page $pageCount of $($result.paging.totalPages)" -PercentComplete $percentCompletePages
                            } else {
                                Write-Progress -Id 2 -Activity "Fetching Attributes for DeviceID: ${deviceId}" -Status "Processing page $pageCount" -PercentComplete 0
                            }
    
                        }
                        catch {
                            Write-Error "Error fetching attributes for DeviceID ${deviceId}: $($_.Exception.Message)"
                            $currentPageId = $null
                        }
    
                    } while ($null -ne $currentPageId)
    
                    # Clear the paging progress for the current device after all pages are processed
                    Write-Progress -Id 2 -Activity "Fetching Attributes for DeviceID: $deviceId" -Status "Completed" -Completed
                }
            }
    
            # Clear the main device progress after all devices are processed
            Write-Progress -Id 1 -Activity "Fetching Attributes" -Status "All devices processed" -Completed
            Write-Debug "Get-WUGDeviceAttribute function completed."
    
            # Output the final data
            return $finalOutput
        }
    }
# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUDfjNOikS0iRtPXx7e6U3DaUl
# UzqgghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUMtw6S9xY9RNzFnKYjt7Ixyn9
# 3TAwDQYJKoZIhvcNAQEBBQAEggIAcUcS/VQujvwMqzOn5Uz5bupAO8KSvJZU5t+1
# NJErpjgrkVHBAyXERdCWWJYLJThb2hVYZiS3fzOMxx8f4Xm90LdW39y/Er7Lfm1J
# 7AhPxJJGQmnjRvUSdjyesbbPDzVjBV4JjpChI6pi+vrMrWm5bbG0n4z9Ag7NQvXR
# MMtPjI4lr/mClayWDmIP5TDoGj17g0pH7gyzX9pa3pksyxecA6hsqdvm6eFY+38K
# LJfq8D3LrWYTSQ9hCPZzCc3WoXR7IuZFVE8Na1JnNNVHnDkI86uZW2aiMpBRzbm/
# ggmsYJGtp+g1Fzr1Y66djwh9wWwOP6pJ49CFvbeq/9jKnCFv1T4DNCWHBQKz8TiG
# uGeRMRfpEd8EwCv+poZlKgmwe+0sErJJ4wutw8wvXVXlsMHX13wUQ10jSFI9ubf9
# fbdxL0HwblE4XbxFvuU8a1QphXUrydk+XjKSWgsTtmDA3tLtAQ0U7H99onDi0Srh
# UndXPRmq0mKujVM2ur84jxNa9X1yN5diKo5Dp6AczOIDwJfpHotREAMuh+c5WO16
# gdIcFXQ2WX7e+VX4bivsQeX72dOYqRA2GVuMP916GZiY0wkBiIVJa7m8zJLaDS4S
# swVScCvXEFU3yEUzqAaR4dqLQVZcF+pea13ahKG+CradlOjDT83j5+0B5cZJkzwD
# BU4aHOs=
# SIG # End signature block
