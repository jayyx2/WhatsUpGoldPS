<#
.SYNOPSIS
Get performance monitors from the WhatsUp Gold library or device-specific assignments.

.DESCRIPTION
Without -DeviceId, queries the monitor library via GET /api/v1/monitors/-?type=performance.
With -DeviceId, queries device assignments via GET /api/v1/devices/{deviceId}/monitors/-.

Use -Search to filter by display name, description, or classId in either mode.

.PARAMETER DeviceId
The device ID(s) to retrieve performance monitor assignments for.
Accepts pipeline input by property name. When omitted, searches the monitor library.

.PARAMETER Search
Return only monitors containing this string in display name, description,
classId, argument, or comment. Case-insensitive.

.PARAMETER MonitorTypeId
Filter results by monitor type ID.

.PARAMETER EnabledOnly
[Device mode] Return only enabled monitors. Default is $false (return all).

.PARAMETER View
Level of detail returned.
Device mode accepts: 'id', 'minimum', 'basic', 'status' (default 'status').
Library mode accepts: 'id', 'basic', 'info', 'summary', 'details' (default 'info').

.PARAMETER PageId
Page to return (for paging).

.PARAMETER Limit
Maximum number of results per page (0-250).

.PARAMETER IncludeDeviceMonitors
[Library mode] Return device-specific monitors. Default = 'false'.

.PARAMETER IncludeSystemMonitors
[Library mode] Return system monitors that cannot be modified. Default = 'false'.

.PARAMETER IncludeCoreMonitors
[Library mode] Return core monitors. Default = 'false'.

.EXAMPLE
Get-WUGPerformanceMonitor -Search 'Azure'

Searches the performance monitor library for monitors matching 'Azure'.

.EXAMPLE
Get-WUGPerformanceMonitor -DeviceId 3409

Returns all performance monitors assigned to device 3409.

.EXAMPLE
Get-WUGPerformanceMonitor -DeviceId 3409 -Search 'Memory'

Returns performance monitors matching 'Memory' on device 3409.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: GET /api/v1/monitors/- (library) or GET /api/v1/devices/{deviceId}/monitors/- (device)
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS
#>
function Get-WUGPerformanceMonitor {
    [CmdletBinding(DefaultParameterSetName = 'Library')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Device', ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int[]]$DeviceId,

        [string]$Search,

        [string]$MonitorTypeId,

        [Parameter(ParameterSetName = 'Device')]
        [bool]$EnabledOnly = $false,

        [ValidateSet("id", "minimum", "basic", "info", "summary", "details", "status")]
        [string]$View,

        [string]$PageId,

        [ValidateRange(0, 250)]
        [int]$Limit,

        [Parameter(ParameterSetName = 'Library')]
        [ValidateSet('true', 'false')]
        [string]$IncludeDeviceMonitors = 'false',

        [Parameter(ParameterSetName = 'Library')]
        [ValidateSet('true', 'false')]
        [string]$IncludeSystemMonitors = 'false',

        [Parameter(ParameterSetName = 'Library')]
        [ValidateSet('true', 'false')]
        [string]$IncludeCoreMonitors = 'false'
    )

    begin {
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            return
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Please run Connect-WUGServer first."
            return
        }
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Library') {
            # Validate View values for Library mode
            if ($View -and $View -notin @('id', 'basic', 'info', 'summary', 'details')) {
                Write-Error "View value '$View' is not valid for Library mode. Valid values: id, basic, info, summary, details."
                return
            }
            # Library search: GET /api/v1/monitors/-?type=performance
            $qs = "type=performance"
            if ($View)                  { $qs += "&view=$View" }
            if ($IncludeDeviceMonitors) { $qs += "&includeDeviceMonitors=$IncludeDeviceMonitors" }
            if ($IncludeSystemMonitors) { $qs += "&includeSystemMonitors=$IncludeSystemMonitors" }
            if ($IncludeCoreMonitors)   { $qs += "&includeCoreMonitors=$IncludeCoreMonitors" }
            if ($Search)                { $qs += "&search=$([uri]::EscapeDataString($Search))" }
            if ($Limit)                 { $qs += "&limit=$Limit" }

            $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/monitors/-?${qs}"

            # Auto-paginate unless caller specified a specific page
            $currentPageId = $PageId
            $userRequestedPage = [bool]$PageId
            do {
                if ($currentPageId) {
                    $uri = "${baseUri}&pageId=$currentPageId"
                } else {
                    $uri = $baseUri
                }
                Write-Debug "GET $uri"

                try {
                    $response = Get-WUGAPIResponse -Uri $uri -Method GET
                    if ($response.data -and $response.data.performanceMonitors) {
                        foreach ($mon in $response.data.performanceMonitors) {
                            [PSCustomObject]@{
                                Id              = $mon.id
                                MonitorId       = $mon.monitorId
                                Name            = $mon.name
                                Description     = $mon.description
                                ClassId         = if ($mon.monitorTypeInfo) { $mon.monitorTypeInfo.classId } else { $null }
                                BaseType        = if ($mon.monitorTypeInfo) { $mon.monitorTypeInfo.baseType } else { $null }
                                MonitorTypeName = if ($mon.monitorTypeInfo) { $mon.monitorTypeInfo.name } else { $null }
                                TemplateId      = $mon.templateId
                                PropertyBags    = $mon.propertyBags
                                HasSensitiveData = $mon.hasSensitiveData
                                OwnedByDevice   = $mon.ownedByDevice
                            }
                        }
                    }
                    $currentPageId = if ($response.paging) { $response.paging.nextPageId } else { $null }
                }
                catch {
                    Write-Error "Failed to retrieve performance monitor library: $_"
                    break
                }
            } while ($currentPageId -and -not $userRequestedPage)
        }
        else {
            # Device assignments: GET /api/v1/devices/{deviceId}/monitors/-?type=performance
            if (-not $View) { $View = 'status' }
            # Validate View values for Device mode
            if ($View -notin @('id', 'minimum', 'basic', 'status')) {
                Write-Error "View value '$View' is not valid for Device mode. Valid values: id, minimum, basic, status."
                return
            }
            foreach ($devId in $DeviceId) {
                $qs = "type=performance"
                if ($View)          { $qs += "&view=$View" }
                if ($Search)        { $qs += "&search=$([uri]::EscapeDataString($Search))" }
                if ($MonitorTypeId) { $qs += "&monitorTypeId=$MonitorTypeId" }
                $qs += "&enabledOnly=$($EnabledOnly.ToString().ToLower())"
                if ($Limit)         { $qs += "&limit=$Limit" }

                $baseDevUri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${devId}/monitors/-?${qs}"

                # Auto-paginate unless caller specified a specific page
                $currentPageId = $PageId
                $userRequestedPage = [bool]$PageId
                do {
                    if ($currentPageId) {
                        $uri = "${baseDevUri}&pageId=$currentPageId"
                    } else {
                        $uri = $baseDevUri
                    }
                    Write-Debug "GET $uri"

                    try {
                        $response = Get-WUGAPIResponse -Uri $uri -Method GET
                        if ($response.data) {
                            foreach ($mon in $response.data) {
                                [PSCustomObject]@{
                                    DeviceId            = $devId
                                    AssignmentId        = $mon.id
                                    Name                = $mon.description
                                    Description         = $mon.description
                                    Type                = $mon.type
                                    MonitorTypeId       = $mon.monitorTypeId
                                    MonitorTypeClassId  = $mon.monitorTypeClassId
                                    MonitorTypeName     = $mon.monitorTypeName
                                    Enabled             = $mon.enabled
                                    IsGlobal            = $mon.isGlobal
                                    Status              = $mon.status
                                    PollingIntervalMin  = if ($mon.performance) { $mon.performance.pollingIntervalMinutes } else { $null }
                                    ThresholdInfo       = $mon.thresholdInfo
                                }
                            }
                        }
                        $currentPageId = if ($response.paging) { $response.paging.nextPageId } else { $null }
                    }
                    catch {
                        Write-Error "Failed to retrieve performance monitors for device ${devId}: $_"
                        break
                    }
                } while ($currentPageId -and -not $userRequestedPage)
            }
        }
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBjfs14FTK7+iVh
# V48RuJyfAlq2koT0df6VA5U14Xh2AqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgb4UH3b2VLAn3uORZrUhWnzuKtBAu+q5w
# F1YCpPEgxP4wDQYJKoZIhvcNAQEBBQAEggIAQkoP5cSXqorMcjiziF4p3ot+/xua
# 3QO6acpj/WhwOGNd1rXb+znPuWLmtmQLNoFiyFC1pfU0ncWwwH6elXPRy206Rec7
# zYD7SwP8Mjhj0gY4qJNOvWwk/ks1Bm/hxCvSvW9orIxKE7+wExfFKD1tBtU1Xoev
# k17G8T3JWPxOxanFOduBzJwnIKANleS9lFtKkTegHIAPmN/VZ0qZskUTl9BVHJxz
# FDP5ZxUHmMi+0Si773xMbfFvqjMbojDijO2Daom4IfSbrtmpQJd/gUtBGWaYGGBu
# JOPpdmweAadw9VmxGHtNx8ionkbDlnx9Z/SWGg1ulI39FZ6beX3WWM0s9J01xVqC
# tJY05GDlyIqh49rPvOCujLahw/7OEZ064Fcpoozz/t3ZillG1KW+4JZOI8Oc0kqN
# OGKfhPXRLo0OQigNuSW1TIvoZ9uV8dsAVswivF9qhdvJflk9amHBH5EQW79xE6GK
# V6eTNb1h9VFu+JYYbWTR/3cudD8Tkfo70vhP0HE9E5JIKSAVmwIsk1DTN2UYOBL+
# tWWEjBgkqi8bRW2YvNn10a45zhcJrFsTS7/kZ9OGMhfFdy8W+8QiiL/BJVrBj/a5
# lVn8MpnOZXIAxrUXlyEcvJwpECGJ5aDsAODkhPbOY9DWM+prhdzuY+TJilDsF69Q
# CYoowwHNV+BJwNY=
# SIG # End signature block
