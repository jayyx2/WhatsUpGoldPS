    <#
    .SYNOPSIS
    Retrieves device information from the WhatsUp Gold API.

    .DESCRIPTION
    Fetches devices by specified Device IDs or searches for devices using search parameters.
    If -DeviceID is specified, it retrieves devices with those IDs.
    If -DeviceID is not specified, it searches for devices based on provided criteria.

    .PARAMETER DeviceId
    The ID(s) of the device(s) to retrieve.

    .PARAMETER SearchValue
    A search string to find devices when DeviceId is not specified.

    .PARAMETER DeviceGroupID
    The ID of the device group to search within. Default is "-1" (All Devices).

    .PARAMETER View
    The level of detail to retrieve. Valid options are "id", "basic", "card", "overview". Default is "card".

    .PARAMETER Limit
    The maximum number of devices to retrieve. Default is 250.

    .EXAMPLE
    Get-WUGDevice -DeviceId 2367, 2368

    Retrieves devices with IDs 2367 and 2368.

    .EXAMPLE
    Get-WUGDevice -SearchValue "Server"

    Searches for devices with "Server" in their properties.

    .EXAMPLE
    Get-WUGDevice

    Retrieves all devices (up to the limit).

    #>
    function Get-WUGDevice {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
        [Parameter()][string] $SearchValue,
        [Parameter()][string] $DeviceGroupID = "-1",  # Default to All Devices
        [Parameter()][ValidateSet("id", "basic", "card", "overview")][string] $View = "card",
        [ValidateRange(1, 250)][int]$Limit = 250
    )

    begin {
        Write-Debug "Initializing Get-WUGDevice function."
        Write-Debug "DeviceId: $DeviceId"
        Write-Debug "SearchValue: $SearchValue"
        Write-Debug "DeviceGroupID: $DeviceGroupID"
        Write-Debug "View: $View"
        Write-Debug "Limit: $Limit"

        # Global variables error checking
        if ($null -eq $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            Connect-WUGServer
        }
        if ($null -eq $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Running Connect-WUGServer."
            Connect-WUGServer
        }

        # Initialize variables
        $finalOutput = @()
        $uri = "$($global:WhatsUpServerBaseURI)/api/v1"
    }

    process {
        if ($DeviceId) {
            Write-Debug "DeviceId specified. Fetching devices by ID."

            $totalDevices = $DeviceId.Count
            $currentDeviceIndex = 0

            foreach ($id in $DeviceId) {
                $currentDeviceIndex++
                $percentComplete = [Math]::Round(($currentDeviceIndex / $totalDevices) * 100)

                Write-Progress -Activity "Fetching device information" -Status "Processing Device ID $id ($currentDeviceIndex of $totalDevices)" -PercentComplete $percentComplete

                $deviceUri = "${uri}/devices/${id}?view=${View}"
                Write-Debug "Fetching device info from URI: $deviceUri"

                try {
                    $result = Get-WUGAPIResponse -Uri $deviceUri -Method "GET"
                    Write-Debug "Result from Get-WUGAPIResponse for Device ID ${id}: $result"
                    if ($null -ne $result.data) {
                        $finalOutput += $result.data
                    } else {
                        Write-Warning "No data returned for Device ID $id."
                    }
                }
                catch {
                    Write-Error "Error fetching device with ID ${id}: $_"
                }
            }
        }
        else {
            Write-Debug "No DeviceId specified. Using search functionality."

            # Build base URI for device search
            $baseUri = "${uri}/device-groups/${DeviceGroupID}/devices/-?"

            # Build query string
            $queryString = ""
            if ($SearchValue) { $queryString += "search=$([System.Web.HttpUtility]::UrlEncode($SearchValue))&" }
            if ($View) { $queryString += "view=$([System.Web.HttpUtility]::UrlEncode($View))&" }
            if ($Limit) { $queryString += "limit=$Limit&" }
            $queryString = $queryString.TrimEnd('&')

            $searchUri = "$baseUri$queryString"
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

                Write-Debug "Fetching devices from URI: $currentUri"

                try {
                    $result = Get-WUGAPIResponse -Uri $currentUri -Method "GET"
                    Write-Debug "Result from Get-WUGAPIResponse: $result"

                    if ($null -ne $result.data.devices) {
                        $finalOutput += $result.data.devices
                    }

                    $currentPageId = $result.paging.nextPageId
                    $pageNumber++

                    # Update progress
                    if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                        $percentComplete = ($pageNumber / $result.paging.totalPages) * 100
                        Write-Progress -Activity "Retrieving devices" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete $percentComplete
                    } else {
                        Write-Progress -Activity "Retrieving devices" -Status "Processing page $pageNumber" -PercentComplete (($pageNumber % 100))
                    }
                }
                catch {
                    Write-Error "Error fetching devices: $_"
                    break # Ensure exit from loop on error
                }
            } while ($null -ne $currentPageId)
        }
    }

    end {
        Write-Progress -Activity "Fetching device information" -Completed
        Write-Debug "Completed Get-WUGDevice function"
        return $finalOutput
    }
}
# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUDnhhqJtQBG2gVRYA81/O4jlX
# lhygghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUTaFvuRXfpuwKH31goit5rX2I
# wFQwDQYJKoZIhvcNAQEBBQAEggIAGEsrrtvKIIsOibpnU/Jysc14Qhn7kwfjCtnB
# EdUBhZg+tGQA3WRK1zQAuP0OlF3Zlj7RISB5vfeMtH5OenLSj3n1LKW6DpkdQHgo
# xOkcAZHF/Wt/Dlg2DK22/rYHk9pX188+ian0Xrywi6dxnuux8oxLsgTPNJ1r9vj1
# V5jsBoucqX5oTIC89W2jg9ewUW3qfepaMCQneNCQGGGvZCDdLGDbXlEEQpxDZKC9
# bJ4jAUqSkjmHPQB8mq3SHLI+Gm2Bou9y0LVq64AcmFvf8eIKpObQTZYShYFGII3o
# OQz0cE+qUVf0uPTRvWeLoz2Uvp8NoOP541f/CbXohlK4iR1PJgP+lEgse5oQ1CDA
# wu6IkQ96PvGZ1DEzNz0QFFqQXjIpNQkw/mvBKGjXpkRXdKuJThdoPhELiKqsS51a
# Q/oNRnnA9odhFN8ETsxNcOzLj3pGy9eO3K5sFsWC9JOL1O+rhS4EqVR1Xuk2HsGQ
# HAIU1x/+QxLEtcsolthpt7ymzwpaU9zNVgc5FNp1+6iy/Ef24O9sGfon//M8dd/p
# WQvSQWG6Qls8WWy4ivJHzC9W3WmrtpuTVKFoApR7YZ+RgzK8gkN9TIUJB7DmCj4u
# v5/XimSHROc1ryOl0cWf9PReKRVAhAAmhIUI44BfAAGPCNnkC+0e9EGXAQaNw/KV
# QSX1qIs=
# SIG # End signature block
