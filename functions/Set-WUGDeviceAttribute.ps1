<#
.SYNOPSIS
Adds or updates an attribute for one or more devices in WhatsUp.

.DESCRIPTION
The Set-WUGDeviceAttribute function allows users to add a new attribute or update an existing attribute for specified devices in WhatsUp. If an attribute with the given name exists (case-insensitive), it will be updated with the new value. If it does not exist, a new attribute will be created.

.PARAMETER DeviceId
The ID(s) of the device(s) to which the attribute will be added or updated.

.PARAMETER Name
The name of the attribute to add or update.

.PARAMETER Value
The value to set for the specified attribute.

.EXAMPLE
# Add/update attribute named 'Location' with value 'Data Center 1' to device with ID 12345
Set-WUGDeviceAttribute -DeviceId 12345 -Name "Location" -Value "Data Center 1"

.EXAMPLE
# Update the attribute 'Owner' with value 'John Doe' for multiple devices
Set-WUGDeviceAttribute -DeviceId 12345, 67890, 54321 -Name "Owner" -Value "John Doe"

.NOTES
# Author: Jason Alberino (jason@wug.ninja) 2024-09-26
# Still need to test weird attirbute names that are similar

.LINK
# Link to related documentation or resources
https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_FindAttributes
https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_AddAttribute
https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/Device_UpdateAttribute
#>

function Set-WUGDeviceAttribute {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    
    begin {
        # Initialize collection for DeviceIds
        $collectedDeviceIds = @()
    
        # Debug message with all parameters
        Write-Debug "Function: Set-WUGDeviceAttribute -- DeviceId=${DeviceId} Name=${Name} Value=${Value}"
        
        # Set static variables
        $finaloutput = @()
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/devices"
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
    
        $devicesProcessed = 0
        $percentCompleteDevices = 0
    
        foreach ($id in $collectedDeviceIds) {
            $devicesProcessed++
            $percentCompleteDevices = [Math]::Round(($devicesProcessed / $totalDevices) * 100, 2)
            Write-Progress -Id 1 -Activity "Setting device attributes" -Status "Processing Device $devicesProcessed of $totalDevices (DeviceID: $id)" -PercentComplete $percentCompleteDevices
            Write-Debug "Processing DeviceID: $id"
    
            try {
                # Step 1: Get all existing attributes for the device
                $getUri = "${baseUri}/$id/attributes/-"
                Write-Debug "Fetching existing attributes with URI: $getUri"
                    
                try {
                    $existingAttributesResponse = Get-WUGAPIResponse -uri $getUri -Method "GET"
                }
                catch {
                    Write-Error "Failed to fetch existing attributes for DeviceID: $id. Error: $_"
                    continue
                }
    
                # Initialize matchingAttribute to $null
                $matchingAttribute = $null
    
                # Check if the API returned data
                if ($null -ne $existingAttributesResponse.data -and $existingAttributesResponse.data.Count -gt 0) {
                    # Look for an exact match on the attribute name (case-insensitive)
                    $matchingAttribute = $existingAttributesResponse.data | Where-Object { $_.name -ieq $Name } | Select-Object -First 1
                    if ($matchingAttribute) {
                        Write-Debug "Attribute '$Name' exists with AttributeID: $($matchingAttribute.attributeId). Preparing to update."
                    }
                    else {
                        Write-Debug "Attribute '$Name' does not exist for DeviceID: $id. Proceeding to create."
                    }
                }
                else {
                    Write-Debug "No existing attributes found for DeviceID: $id. Proceeding to create attribute '$Name'."
                }
    
                if ($matchingAttribute) {
                    # Attribute exists, perform PUT to update
                    $attributeId = $matchingAttribute.attributeId
                    Write-Debug "Attribute ID: $attributeId"
    
                    # No need to encode attributeId
                    $encodedName = [uri]::EscapeDataString($Name)
                    $encodedValue = [uri]::EscapeDataString($Value)
                    $updateUri = "${baseUri}/${id}/attributes/${attributeId}?name=${encodedName}&value=${encodedValue}"
    
                    Write-Debug "Updating attribute with URI: $updateUri"
                        
                    try {
                        $updateResponse = Get-WUGAPIResponse -uri $updateUri -Method "PUT"
                    }
                    catch {
                        Write-Error "Failed to update attribute '$Name' for DeviceID: $id. Error: $_"
                        continue
                    }
    
                    # Check if update was successful
                    if ($updateResponse.data -and $updateResponse.data.success -eq $true) {
                        Write-Debug "Successfully updated attribute '$Name' for DeviceID: $id"
                        # Optionally, add the updated attribute to final output
                        $finaloutput += $matchingAttribute
                    }
                    else {
                        Write-Warning "Failed to update attribute '$Name' for DeviceID: $id"
                    }
                }
                else {
                    # Attribute does not exist, perform POST to create
                    $encodedName = [uri]::EscapeDataString($Name)
                    $encodedValue = [uri]::EscapeDataString($Value)
                    $postUri = "${baseUri}/$id/attributes/-?name=$encodedName&value=$encodedValue"
    
                    Write-Debug "Creating attribute with URI: $postUri"
                        
                    try {
                        $createResponse = Get-WUGAPIResponse -uri $postUri -Method "POST"
                    }
                    catch {
                        Write-Error "Failed to create attribute '$Name' for DeviceID: $id. Error: $_"
                        continue
                    }
    
                    # Check if creation was successful
                    if ($createResponse.data -and $createResponse.data.attributeId) {
                        Write-Debug "Successfully created attribute '$Name' for DeviceID: $id"
                        # Add the created attribute data to $finaloutput
                        $finaloutput += $createResponse.data
                    }
                    else {
                        Write-Warning "Failed to create attribute '$Name' for DeviceID: $id"
                    }
                }
            }
            catch {
                Write-Error "Error setting attribute '$Name' for DeviceID ${id}: $_"
            }
    
            # Clear the progress for this device
            Write-Progress -Id 1 -Activity "Setting device attributes" -Status "Completed DeviceID: $id" -PercentComplete $percentCompleteDevices
            Write-Debug "Completed DeviceID: $id"
        }
    
        # Clear the main device progress after all devices are processed
        Write-Progress -Id 1 -Activity "Setting device attributes" -Status "All devices processed" -Completed
        Write-Debug "All devices have been processed."
    
        # Return the collected data
        Write-Debug "Total Data Collected: $($finaloutput.Count)"
        return $finaloutput
    }
}


# SIG # Begin signature block
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCHMuFiph52SyP4
# VG4hYE0AYWWULo5WWEd79qhndiaGE6CCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BgkqhkiG9w0BCQQxIgQgYlHaUwaIridjdpbVQD4cRmYIlJno+hJ/+UvttQXfOLQw
# DQYJKoZIhvcNAQEBBQAEggIAKnvcaiPzDbZsh/1Xunrji9UGHsRlc4nP9R1v0++/
# acG0ASa7phYvA1i09plACp1W/ybs+VN/Oi7u6o58MeclNvYUjpn7QlGd73D6ZUlu
# RDF1Wvv4e+q4fWb6sw/caAOks/bVQA9VoeHOh+CeOdihphuFqc8nkysDJxA08DgL
# IPa3PlEsS5oC5okXlbOYqH5pfKiWdIQGt6h7C4TlbM1N3/HWtCPR83HV/QPDciQZ
# i0Rx9tmzd48PgmbGtNtpUOl+66qxRFj1jgy/Z0cfJpe7JBEducygHSHQF+wlkRbJ
# DUMsEBchEkc9UF0zRKKuRNf5hQ8mV1zzn2/vCm+WDif9A2ClpAmLwQzOOOlCCTUm
# mXtvifSOmwCEmBA+DlcSqgpR0PRnuaFVt7idaLIMLfOQ5/aXXR5J90L2KrB/M+uP
# vwUMMuAWcAegPwT1IFcBwvkO48VzNRSQj10kY0th36JKZ9CsF7ByfEQm2IJ5JLlA
# CXlXLC5Sb4E9dyVuWPkfjDtQ6T0rrwJ8wohLhfso11Lb8hk6lxOyqxD7dTBn7NDH
# 6oaQBMjO3AOyo8fAPj8iTzYUu5Viu51d2CShfCpk5Qtl7u1ZbSIU7ELUYRqTu/Mc
# mxVeEiNiL3/j3fac6POF/x/lCZqTu/4CvxceokRbmVD098WwvOzJslD1f70GtX/A
# OmI=
# SIG # End signature block
