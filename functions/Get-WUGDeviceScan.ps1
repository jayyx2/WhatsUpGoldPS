<#
.SYNOPSIS
    Retrieves device scan information from WhatsUp Gold, including scan statuses, scan details, and discovered devices.

.DESCRIPTION
    Get-WUGDeviceScan queries the WhatsUp Gold REST API for device scan data. When called without a ScanId,
    it returns a paginated list of all scan statuses. When called with a ScanId, it returns the scan status
    and discovered devices for that specific scan. Optionally cancels a running scan.

.PARAMETER ScanId
    The unique identifier (GUID) of a specific device scan. When provided, the command returns the status
    and discovered devices for that scan. Accepts pipeline input and the alias 'id'.

.PARAMETER CancelScan
    When specified along with a ScanId, sends a cancel request to stop the running scan.

.PARAMETER Model
    Filters scan statuses by scan model type. Valid values: all, standard, newDevice, refresh, staging, rescan.

.PARAMETER ActiveOnly
    Filters scan statuses to active scans only. Valid values: true, false.

.PARAMETER DeviceView
    Controls the level of detail returned for discovered devices. Valid values: id, basic, card, overview.

.PARAMETER Search
    A search string to filter results by name or other searchable fields.

.PARAMETER PageId
    The page identifier for retrieving a specific page of paginated results.

.PARAMETER Limit
    The maximum number of results to return per page.

.EXAMPLE
    Get-WUGDeviceScan

    Returns all scan statuses with default paging.

.EXAMPLE
    Get-WUGDeviceScan -Model newDevice -ActiveOnly true

    Returns only active scans with the 'newDevice' model.

.EXAMPLE
    Get-WUGDeviceScan -ScanId 'b2cf2d31-a0ec-c956-d113-08de7beeb7bd'

    Returns the status and discovered devices for the specified scan.

    ScanId  : b2cf2d31-a0ec-c956-d113-08de7beeb7bd
    Cancel  :
    Status  : @{isExport=False; scanUtc=3/7/2026 2:10:34 AM; devicesFound=1; devicesComplete=1; ...}
    Devices : {@{devices=System.Object[]; name=discovery-...; id=b2cf2d31-a0ec-c956-d113-08de7beeb7bd}}

.EXAMPLE
    Get-WUGDeviceScan -ScanId 'b2cf2d31-a0ec-c956-d113-08de7beeb7bd' -CancelScan

    Cancels the specified scan and returns its current status and devices.

.EXAMPLE
    'b2cf2d31-a0ec-c956-d113-08de7beeb7bd' | Get-WUGDeviceScan -DeviceView overview

    Pipes a ScanId and retrieves the scan details with the 'overview' device view.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/#tag/Device-Scan
#>
function Get-WUGDeviceScan {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [string]$ScanId,

        [switch]$CancelScan,

        [ValidateSet("all", "standard", "newDevice", "refresh", "staging", "rescan")]
        [string]$Model,

        [ValidateSet("true", "false")]
        [string]$ActiveOnly,

        [ValidateSet("id", "basic", "card", "overview")]
        [string]$DeviceView,

        [string]$Search,

        [string]$PageId,

        [int]$Limit
    )

    begin {
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error "WhatsUpServerBaseURI is not set. Please run Connect-WUGServer to establish a connection."
            return
        }

        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/device-scan"
    }

    process {
        if (-not $ScanId) {
            # No ScanId: list all scan statuses
            $queryString = ""
            if ($Model)      { $queryString += "model=$Model&" }
            if ($ActiveOnly) { $queryString += "activeOnly=$ActiveOnly&" }
            if ($Search)     { $queryString += "search=$Search&" }
            if ($PageId)     { $queryString += "pageId=$PageId&" }
            if ($PSBoundParameters.ContainsKey('Limit')) { $queryString += "limit=$Limit&" }
            $queryString = $queryString.TrimEnd('&')
            $uri = "$baseUri/-/status"
            if ($queryString) { $uri += "?$queryString" }

            Write-Verbose "Fetching all scan statuses: $uri"

            $finalOutput = @()
            $currentPageId = $null
            $pageCount = 0

            do {
                if ($currentPageId) {
                    $pagedUri = "$baseUri/-/status?pageId=$currentPageId"
                    if ($queryString) { $pagedUri += "&$queryString" }
                } else {
                    $pagedUri = $uri
                }

                try {
                    $result = Get-WUGAPIResponse -Uri $pagedUri -Method "GET"
                    $finalOutput += $result.data
                    $currentPageId = $result.paging.nextPageId
                    $pageCount++

                    if ($result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                        $percentComplete = [Math]::Round(($pageCount / $result.paging.totalPages) * 100, 2)
                        Write-Progress -Id 1 -Activity "Fetching scan statuses" -Status "Page $pageCount of $($result.paging.totalPages)" -PercentComplete $percentComplete
                    } else {
                        Write-Progress -Id 1 -Activity "Fetching scan statuses" -Status "Processing page $pageCount" -PercentComplete 0
                    }
                }
                catch {
                    Write-Error "Error fetching scan statuses: $_"
                    $currentPageId = $null
                }
            } while ($currentPageId)

            Write-Progress -Id 1 -Activity "Fetching scan statuses" -Status "Completed" -Completed
            return $finalOutput
        }

        # ScanId provided
        $output = [PSCustomObject]@{
            ScanId  = $ScanId
            Cancel  = $null
            Status  = $null
            Devices = $null
        }

        # Cancel if requested
        if ($CancelScan) {
            Write-Verbose "Cancelling scan $ScanId"
            try {
                $cancelResult = Get-WUGAPIResponse -Uri "$baseUri/$ScanId/cancel" -Method "PUT"
                $output.Cancel = $cancelResult
                Write-Verbose "Cancel request sent for scan $ScanId"
            }
            catch {
                Write-Error "Error cancelling scan ${ScanId}: $_"
            }
        }

        # Get scan status
        Write-Verbose "Fetching status for scan $ScanId"
        try {
            $statusResult = Get-WUGAPIResponse -Uri "$baseUri/$ScanId/status" -Method "GET"
            $output.Status = $statusResult.data
        }
        catch {
            Write-Error "Error fetching status for scan ${ScanId}: $_"
        }

        # Get scan devices (paginated)
        $deviceQueryString = ""
        if ($DeviceView) { $deviceQueryString += "view=$DeviceView&" }
        if ($Search)     { $deviceQueryString += "search=$Search&" }
        if ($PageId)     { $deviceQueryString += "pageId=$PageId&" }
        if ($PSBoundParameters.ContainsKey('Limit')) { $deviceQueryString += "limit=$Limit&" }
        $deviceQueryString = $deviceQueryString.TrimEnd('&')

        $allDevices = @()
        $currentPageId = $null
        $pageCount = 0

        do {
            if ($currentPageId) {
                $devUri = "$baseUri/$ScanId/devices?pageId=$currentPageId"
                if ($deviceQueryString) { $devUri += "&$deviceQueryString" }
            } else {
                $devUri = "$baseUri/$ScanId/devices"
                if ($deviceQueryString) { $devUri += "?$deviceQueryString" }
            }

            Write-Verbose "Fetching devices for scan ${ScanId}: $devUri"

            try {
                $result = Get-WUGAPIResponse -Uri $devUri -Method "GET"
                $allDevices += $result.data
                $currentPageId = $result.paging.nextPageId
                $pageCount++

                if ($result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                    $percentComplete = [Math]::Round(($pageCount / $result.paging.totalPages) * 100, 2)
                    Write-Progress -Id 1 -Activity "Fetching devices for scan $ScanId" -Status "Page $pageCount of $($result.paging.totalPages)" -PercentComplete $percentComplete
                } else {
                    Write-Progress -Id 1 -Activity "Fetching devices for scan $ScanId" -Status "Processing page $pageCount" -PercentComplete 0
                }
            }
            catch {
                Write-Error "Error fetching devices for scan ${ScanId}: $_"
                $currentPageId = $null
            }
        } while ($currentPageId)

        Write-Progress -Id 1 -Activity "Fetching devices for scan $ScanId" -Status "Completed" -Completed
        $output.Devices = $allDevices

        return $output
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDTwBuKP9Zgiu9V
# GC5f4Q2iuQSmwCFQLY/qwopnaYO8sqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgY+3bR+JLmql3ZUX2IjZeLzwuYCkLUSYc
# K5Y62MHZfKQwDQYJKoZIhvcNAQEBBQAEggIAPA+ldO74TZkJGRTtdR2xLd1rI/Rc
# fdpAUA1w5cdRCOKN3LDE1XH+1aRSIQXvRre0Ft3YJWAHJg7quV3ZILSMsLZu2Tzk
# BAxiTD0w5k3F7lJW30fGbfUokm5MsY+DS1RhPBR1PrmZCn/TMWEdBx+sERyxmDW5
# n//PiNFllYbsW+YOj9MT4sxPcKMoy5pruckpfctG2m26lW9g3rarg1lTghf7D8bk
# xM8RWVLhhe+yXgJWsqBumoi9keEfmxgBv4BxDIChxGrnuyETJuwXBjFrT9cjmzsz
# XyOiL1o1qlOBpscUk9AtZzBXUTtcDf2aKmJQwm/HmAwFDl7NIiedUBesq14J/Xco
# 4o+zF2/miSelxOVa4Bi39uRij4EsbjaqisNA1GCywSIRf73H0s+9b1g+iuAPm3ZC
# Ti/ZVSb1o8OVutwuir4kJIX5Yq6DD8an+0Qz2rSm7vdJYTDPzEWOqZ6muvdpjTJM
# 5WJEJNDzvON3lkv3I2+bnCVfn7zhxxIK2BwptQlxZ4YiUV2LttTL+VRftY7ALFOn
# eBsO8nYFyAVhjqpJ2ILN4v9m7Hx+BNP5Idox5D/DsKYp//h64PfZb5ksNxgSLCcD
# x0IlQ3wPvfvAiKHSzs/SgaLU/Wqf9rrTXnDfORZhtO9xJTGushbEmT0SBZNtPF/v
# TkxgMbIhgjMuVzE=
# SIG # End signature block
