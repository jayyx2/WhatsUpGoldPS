function Get-WUGDeviceReport {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int[]]$DeviceId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Cpu')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Memory')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Disk')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Interface')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Ping')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Latency')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Default')]
        [ValidateSet("Cpu", "Disk", "DiskSpaceFree", "Interface", "InterfaceDiscards", "InterfaceErrors", "InterfaceTraffic", "Memory", "PingAvailability", "PingResponseTime", "StateChange")]
        [string]$ReportType,

        [Parameter(ParameterSetName = 'Cpu')]
        [Parameter(ParameterSetName = 'Memory')]
        [Parameter(ParameterSetName = 'Disk')]
        [Parameter(ParameterSetName = 'Interface')]
        [Parameter(ParameterSetName = 'Ping')]
        [Parameter(ParameterSetName = 'Latency')]
        [ValidateSet("today", "lastPolled", "yesterday", "lastWeek", "lastMonth", "lastQuarter", "weekToDate", "monthToDate", "quarterToDate", "lastNSeconds", "lastNMinutes", "lastNHours", "lastNDays", "lastNWeeks", "lastNMonths", "custom")]
        [string]$Range,

        [string]$RangeStartUtc,
        [string]$RangeEndUtc,

        [int]$RangeN = 1,

        [Parameter(ParameterSetName = 'Disk')]
        [ValidateSet("defaultColumn", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")]
        [string]$SortBy,

        [ValidateSet("asc", "desc")]
        [string]$SortByDir = "desc",

        [Parameter(ParameterSetName = 'Disk')]
        [ValidateSet("noGrouping", "id", "deviceName", "disk", "diskId", "pollTimeUtc", "timeFromLastPollSeconds", "size", "minFree", "maxFree", "avgFree")]
        [string]$GroupBy,

        [ValidateSet("asc", "desc")]
        [string]$GroupByDir,

        [ValidateSet("true", "false")]
        [string]$ApplyThreshold,

        [ValidateSet("true", "false")]
        [string]$OverThreshold,

        [double]$ThresholdValue = 0.0,

        [int]$BusinessHoursId = 0,

        [ValidateSet("true", "false")]
        [string]$RollupByDevice,

        [string]$PageId,

        [ValidateRange(0, 250)]
        [int]$Limit = 50
    )

    begin {
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error "WhatsUpServerBaseURI is not set. Please run Connect-WUGServer to establish a connection."
            return
        }

        Write-Verbose "Starting Get-WUGDeviceReport"

        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1"

        switch ($ReportType) {
            "Cpu"                { $reportEndpoint = "Cpu" }
            "Disk"               { $reportEndpoint = "Disk" }
            "DiskSpaceFree"      { $reportEndpoint = "DiskSpaceFree" }
            "Interface"          { $reportEndpoint = "Interface" }
            "InterfaceDiscards"  { $reportEndpoint = "InterfaceDiscards" }
            "InterfaceErrors"    { $reportEndpoint = "InterfaceErrors" }
            "InterfaceTraffic"   { $reportEndpoint = "InterfaceTraffic" }
            "Memory"             { $reportEndpoint = "Memory" }
            "PingAvailability"   { $reportEndpoint = "PingAvailability" }
            "PingResponseTime"   { $reportEndpoint = "PingResponseTime" }
            "StateChange"        { $reportEndpoint = "StateChange" }
            default { 
                Write-Error "Invalid ReportType specified."
                return 
            }
        }

        $queryParams = @{}
        if ($Range)             { $queryParams["range"] = $Range }
        if ($RangeStartUtc)     { $queryParams["rangeStartUtc"] = $RangeStartUtc }
        if ($RangeEndUtc)       { $queryParams["rangeEndUtc"] = $RangeEndUtc }
        if ($PSBoundParameters.ContainsKey('RangeN')) { $queryParams["rangeN"] = $RangeN }
        if ($SortBy)            { $queryParams["sortBy"] = $SortBy }
        if ($SortByDir)         { $queryParams["sortByDir"] = $SortByDir }
        if ($GroupBy)           { $queryParams["groupBy"] = $GroupBy }
        if ($GroupByDir)        { $queryParams["groupByDir"] = $GroupByDir }
        if ($PSBoundParameters.ContainsKey('ApplyThreshold')) { $queryParams["applyThreshold"] = $ApplyThreshold }
        if ($PSBoundParameters.ContainsKey('OverThreshold'))  { $queryParams["overThreshold"] = $OverThreshold }
        if ($ThresholdValue -ne $null)    { $queryParams["thresholdValue"] = $ThresholdValue }
        if ($BusinessHoursId)   { $queryParams["businessHoursId"] = $BusinessHoursId }
        if ($PSBoundParameters.ContainsKey('RollupByDevice')) { $queryParams["rollupByDevice"] = $RollupByDevice }
        if ($PageId)            { $queryParams["pageId"] = $PageId }
        if ($Limit)             { $queryParams["limit"] = $Limit }

        $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $collectedDeviceIds = @()
        $finalOutput = @()
    }

    process {
        foreach ($id in $DeviceId) {
            $collectedDeviceIds += $id
        }
    }

    end {
        foreach ($id in $collectedDeviceIds) {
            $currentPageId = $null

            do {
                $uri = if ($currentPageId) {
                    "$baseUri/devices/$id/reports/$reportEndpoint?pageId=$currentPageId&$queryString"
                } else {
                    "$baseUri/devices/$id/reports/$reportEndpoint?$queryString"
                }

                Write-Verbose "API Call: $uri"

                try {
                    $result = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
                    $finalOutput += $result.data
                    $currentPageId = $result.paging.nextPageId
                }
                catch {
                    Write-Error "Failed to fetch data for device $id. Error: $_"
                    $currentPageId = $null
                }
            } while ($currentPageId)
        }

        return $finalOutput
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAFHNQKxMMTiZIs
# o/tGpEZ6SPlJ/jT0r35PqEWozNvFoKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg7shu1OOMhzu+38B4RSdF/jYK64feHEnS
# gtSSa9n4VucwDQYJKoZIhvcNAQEBBQAEggIAm5noTOyG18ZOixWibbbBLwCat8XC
# WNNjFcrgdPJARh0MsImtlMcYRHhgxtps2GEb93diue8DagtbKL6D23bm+EGYWJ+S
# CQyQyv2IxdE8D2BSA6wokU8cLThH6z8K00XrL9OtMM+oQIN9CXmjfAu3ymvU2PbZ
# K9Va8Fq5QsqKNFvq64pmT9AUzICrpOQWnYg/ayJ33hLhIuf1CAzdBwBMlQk323sm
# 85uAf1EM+etPyR75jrJzMCOex73Dm4UmZrBWvU0fJvq8LLDFszAct66WHLzhTSxI
# Y74TRJcpgeeTHIx1sp3n6+1LcoJHt2m/EVZsC0t+d4EMbPZzjwhBy+V7/PGM4iLf
# 2teWNJ19NXjF6yCa92xYRe7MaYq6nmD/KxxccxApHxn+SdeLZj/VxZ2l4IjFAKv+
# BBj921j5FzZcCgRB15WD7jxjFODcBkFjcTdGxLlSGCgV8ZFnPfne8bGQVlg06Azr
# WYrKzIBSg8p/G13F2LVqK1XoG+ZAG2gCDZHlWcsVaxf7CpjkHBZEu2tdLtL6rVtH
# 50ne+SfgMzzSKrAHq2taFQjT+Ksh5ZAOsU8IsklXaY8r4m8ocXPdpJC6J+ibAxR5
# O6KgORZAoXNiXT0kpTEg4OQE/XtZI+esUnSYDFQYm6TZISN5VH0k94OxsetLqU6d
# 7tlM+s2Jf45zdGk=
# SIG # End signature block
