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
            Write-Output $finalOutput
        }
    }
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDM5Ha1iUvT/0kC
# jobu+lr9I+qqQzrZ2YLD/ZNyobUcfKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgF4Q3H9YOqdmL7K8BECfxQtgTKvmxr2g4
# cQWscyVNCNowDQYJKoZIhvcNAQEBBQAEggIAJNBkq3y6LS7W61nTrAW+Rt9MiWJC
# CAmwWZzxmAbU6KZ2xz3LV1uG3iVE3BvnGCauMVRWg/ubD8NsBHWKU8xqyF89jAaH
# kSVko4qc6sQ4GLdVWT1HP2W09c3emtineqvEF15VgSCeTkHf2Ym8nJ6d9Vea/sG3
# JPOAQEhE07QPTpN0O5ZdW7AXxw5bf9vFDh4rpneXYEUd5fUDEIYrMBV212Jh85H+
# s3KLkms3iQAaKtE4v7ucQu4cB56/D1SIY2a5A18FjnoKae5pY8eQdHQmGZ7U/Qem
# 4PL0RWfGIaCzIWoilyIlG2iNv7vVc4qGxuyREL18I4O5dC92KWAcZ1P1CyVjKTee
# R9SRKXb21TNYJLXvgj6um2NPwghH4SDT4PnTvVpRk2CQw1nWZ6yLndtn9MVaanIV
# 3vXbsXuhTX1hs0Iyb6cItvNo0qDVZ2BXdn3S5goA/3Gernkr/h2sc/a4g9FXkmT8
# tEUuwljSav40NAwIkVmg0OKnpk1mQ6muyUlfoJ+BRm7sh9ePU65RKXFECVPqO10B
# VwZ6hn6pAomLv/cisD6HKunQDIp3HeP/1gCU2MN4e1vOFvGD+kv4fqPYMkI11HXw
# pXNoj00zF3WKZkt70bh7gwnMgC3FuiafMayGTXeaALqIRAdLC6Izh6zS0N4BSpWW
# XC3cuVhHrqUYU1k=
# SIG # End signature block
