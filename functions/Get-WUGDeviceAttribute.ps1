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
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD8rTaq0NNrGVOY
# wgh79cc7I5fRzeRZnp11t6DAR/PBMaCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BgkqhkiG9w0BCQQxIgQg6bIwXdd12ACgI2EWJjCi48qjnBMgqxLa8Xnlz1nEuPEw
# DQYJKoZIhvcNAQEBBQAEggIAEuioaDyA017xdQVCyJvCgN8u9884viTqbPBsH8EB
# vr5oNeLeqYVHJDH/Ev6RtXB7YWICXfKRs91oDOvJzC/4cFG3/eaHqN9lD8IWxQi6
# tQxJaWRtmTR6qS6T0LYRnyXg+OyLqKf5DwyZwFrwujlEQOhIn4+0opSPz/JgLwud
# Us0a4pFyBJxu+UeNGfAm0UNhiDCMLZXzav8hKr1FVRs3vs6CxSHtipmdkF8IzhAN
# tv4jK8Dmfqdq/96UOV7kIDYmaBx8Ms+wh3RO/8ARXmHXd/yFdO7YXpNXJg4Vymw/
# vz4zZAwkaQLuijtShzsYXty3d/kan42+bwybw6LXCbuCuFlir72kBo3qJxUgz7KB
# TwU3cx2jBzIma5bH8ch5wdZXAuSROY2tIhD/AYLVHli47HKU1SdSxOOdwG9nygY4
# rm6F2ZwxYDRW/ulInwe040HatAOmIw4kyM08cyraiIR7NrkTra4mZeYjOhGXRAsP
# qy6TkO1VKOHbOwoq6AxDKqwyM2S30IMmaB4VzBjo1TbV14vDRUb4wIf9T0fwYnRD
# Xp6KxzUFjJP8AMOUwY5H8eJS2C+rgGCLP3WlYkpy4CxDguYD7c0rz3O6xJHpbMtQ
# waDRtrfLqv7R4f/hXo5BmlWZknDHE9ZqktjaeEwMOmAOEjyJehsCW/LtH+NwBNoN
# Ge8=
# SIG # End signature block
