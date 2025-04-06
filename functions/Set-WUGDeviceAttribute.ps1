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
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUcDprz5mCdoYGHUHAYpnpnMkx
# ERugghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUIyp+1QzJbrdtVzCIMjsfn4M4
# KDIwDQYJKoZIhvcNAQEBBQAEggIAJmmjDogtBF7/DKBWjblkDnSRT1zhIp8jz0ka
# fGkl2cBxfuN3ezcMH+7H7Fll/EU4u1h56NFpK/HG02HLutICie+mjnbZl+feR6O0
# qJI2z7dKEXmHEbdPcRyHBJSeyud2aHpYyormN/y/s/+jyq+Ay78I+bqDcvdmEY74
# icDNqyCZ6ppfjZN/iXz+PiwE3wXg/xPEW1sj5smMTak3fFL72GUP+irkSkyapA7Y
# TZC8Eru1lY/i9KD3EwhI+9J6DEB0BvF6B19AXx6PsbddLWr8StFRnTkM3RTjRTji
# dBA+sijZz+M8idkfE4Lnj8xUe5fBsJnGDJJZcSiI2bZ5q01YqOYPuKCRzqkk01Ag
# GtxC8FRNd/fsTFWJn4CmxFHTg/WoURAV87RsWUOSWANhl1Z9Cg1+ieBuYGCu61Fl
# 3NaJqu7ABOqMdCp2TkVQqHkVgRSKJk9bTQ0QtzCNjkpNSaLidNQYjMTYgbjsM7z+
# u5skqTWL+R/QZDQ4CLv5ExG7X7i3xD7LHpneZIXVl7QcphU1d5/q/kuPM03JEgTd
# 629A2yoPAJTg56WXY9YUOx55JiijbNfHZg3bIROq6rffNwDoAoY/CXOCrEv4mV7E
# +WX87eTKVDpgKy4hgbpd96UXW53mX+J7kg8XrUwlNfkmiLc7kqJQOIFIndxU9VBD
# aqFMPrM=
# SIG # End signature block
