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

    .PARAMETER ReturnHierarchy
    Whether to return all descendant groups of the parent group. Valid values: "true", "false".

    .PARAMETER State
    Filter devices by state (e.g., "up", "down").

    .EXAMPLE
    Get-WUGDevice -DeviceId 2367, 2368

    Retrieves devices with IDs 2367 and 2368.

    .EXAMPLE
    Get-WUGDevice -SearchValue "Server"

    Searches for devices with "Server" in their properties.

    .EXAMPLE
    Get-WUGDevice

    Retrieves all devices (up to the limit).

    .NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/#tag/Devices
    #>
    function Get-WUGDevice {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)][Alias('id')][int[]]$DeviceId,
        [Parameter()][string] $SearchValue,
        [Parameter()][string] $DeviceGroupID = "-1",  # Default to All Devices
        [Parameter()][ValidateSet("id", "basic", "card", "overview")][string] $View = "card",
        [ValidateRange(1, 250)][int]$Limit = 250,
        [ValidateSet("true", "false")][string]$ReturnHierarchy,
        [string]$State
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
            if ($ReturnHierarchy) { $queryString += "returnHierarchy=$ReturnHierarchy&" }
            if ($State) { $queryString += "state=$([System.Web.HttpUtility]::UrlEncode($State))&" }
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
        Write-Output $finalOutput
    }
}

# End of Get-WUGDevice function
# End of script
#------------------------------------------------------------------
# This script is part of the WhatsUpGoldPS PowerShell module.
# It is designed to interact with the WhatsUp Gold API for network monitoring.
# The script is provided as-is and is not officially supported by WhatsUp Gold.
# Use at your own risk.
#------------------------------------------------------------------

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAJ9SbQPvLnYNbM
# KP4nkO8dreXqN/VlQrio/CQWmhEiOqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgI1flIalMJSpQcttrc797ADR/k5FjJ/R/
# I1QtXIEVbsEwDQYJKoZIhvcNAQEBBQAEggIAHxdVKraVU9PDrLJXFcKh6NPk0VEl
# 1Y/o5DW45m7K2lQSUi3aYDSx5f3IHY11r8saeODBTgU2FWjnGlzyNCPHSMeFZ/RK
# yjb8ylaf6LDhhNiBC3ucZD5mzXfq8C1e3DA3E/iwu443WoSMjLmo77TViY8NqtrR
# x76SzfunaKPxxntCpj9H0vkN53UXPznRoFT/q7zqQWSoTp2AcVB1kWyf7CkmZ1US
# uz5XLHesNoNwLEUGLWhcHyAmI6kR2zm2l6EsgYJdmVECcnp7MmQLBs97i5yEOkT/
# UiU2Vb62blCVzUEWuiVtWNeLHfCsIdTQnUIM+v01bFXnk4d/R61iOeK7jzfyAwxN
# F98uK+or3eFbe4iypYddR8tb5FQDVfqX4wfGwsxhuMXus9437WQ100IjYGjAxWuG
# NEZ3vhrXce91g450EdE3qrxcgM/BkbH3Uu1Eugom5ucWqMfvnUK45Gj86KJqo6Xl
# pirzd3vXeM2GYKU4ZcWAfEoul1CkZfAeP4TiuV+uw7cIGKfaSMep99+NH5fIwnJt
# NIzC17h3K4fn7/JL9QSuNQv7edtm3q1HulSgIFR4gIoANrE43tVyt6GQKouKuhA2
# jaPTFVG3uBcbvbPHhV4MjgDCbwjHWaVM7TK9/UccDrM8Hn+nvgFrljJlaCgXftMI
# 8AIscCQTm7D4eQs=
# SIG # End signature block
