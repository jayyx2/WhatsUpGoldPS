<#
.SYNOPSIS
    Deletes monitor templates from WhatsUp Gold by search term, by monitor ID,
    or removes all assignments for a specific monitor.

.DESCRIPTION
    Remove-WUGActiveMonitor deletes monitor templates from the WhatsUp Gold library:
    - BySearch: DELETE /api/v1/monitors/- (bulk delete by search string)
    - ById:     DELETE /api/v1/monitors/{monitorId} (delete a single monitor)
    - RemoveAssignments: DELETE /api/v1/monitors/{monitorId}/assignments/- (remove all device assignments)

.PARAMETER Search
    A search string to identify the monitors to delete (BySearch parameter set).

.PARAMETER MonitorId
    The ID of a specific monitor to delete or manage (ById / RemoveAssignments parameter sets).

.PARAMETER RemoveAssignments
    Switch to remove all device assignments for the specified MonitorId instead of deleting the monitor itself.

.PARAMETER Type
    The type of monitor to delete. Valid values: all, active, performance, passive. Default: active.

.PARAMETER IncludeDeviceMonitors
    Include device-assigned monitors in the deletion scope. Default: false.

.PARAMETER IncludeSystemMonitors
    Include system-level monitors in the deletion scope. Default: false.

.PARAMETER IncludeCoreMonitors
    Include core monitors in the deletion scope. Default: false.

.PARAMETER FailIfInUse
    Whether the operation should fail if a matching monitor is currently in use. Default: true.

.EXAMPLE
    Remove-WUGActiveMonitor -Search "ROC-Mon"

    Deletes active monitor templates matching "ROC-Mon".

.EXAMPLE
    Remove-WUGActiveMonitor -MonitorId "abc-123"

    Deletes the specific monitor template with ID abc-123.

.EXAMPLE
    Remove-WUGActiveMonitor -MonitorId "abc-123" -RemoveAssignments

    Removes all device assignments for monitor abc-123 without deleting the template.

.EXAMPLE
    Remove-WUGActiveMonitor -Search "HTTP" -Type performance -IncludeDeviceMonitors $true -FailIfInUse $false

    Deletes performance monitors matching "HTTP", including device-assigned monitors,
    even if they are currently in use.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/#tag/Monitor-Templates
#>
function Remove-WUGActiveMonitor {
    [CmdletBinding(DefaultParameterSetName = 'BySearch', SupportsShouldProcess = $true)]
    param(
        # Search string to identify monitors to delete
        [Parameter(Mandatory = $true, ParameterSetName = 'BySearch')]
        [string]$Search,

        # ID of a specific monitor to delete or manage assignments for
        [Parameter(Mandatory = $true, ParameterSetName = 'ById')]
        [Parameter(Mandatory = $true, ParameterSetName = 'RemoveAssignments')]
        [string]$MonitorId,

        # Remove all device assignments for the specified monitor
        [Parameter(Mandatory = $true, ParameterSetName = 'RemoveAssignments')]
        [switch]$RemoveAssignments,

        # Type of monitor to delete
        [Parameter(ParameterSetName = 'BySearch')]
        [Parameter(ParameterSetName = 'ById')]
        [ValidateSet('all', 'active', 'performance', 'passive')]
        [string]$Type = 'active',

        # Include device-assigned monitors in the deletion scope
        [Parameter(ParameterSetName = 'BySearch')]
        [bool]$IncludeDeviceMonitors = $false,

        # Include system-level monitors in the deletion scope
        [Parameter(ParameterSetName = 'BySearch')]
        [bool]$IncludeSystemMonitors = $false,

        # Include core monitors in the deletion scope
        [Parameter(ParameterSetName = 'BySearch')]
        [bool]$IncludeCoreMonitors = $false,

        # Whether the operation should fail if a matching monitor is in use
        [Parameter(ParameterSetName = 'BySearch')]
        [Parameter(ParameterSetName = 'ById')]
        [bool]$FailIfInUse = $true
    )

    begin {
        Write-Debug "Initializing Remove-WUGActiveMonitor function. ParameterSet: $($PSCmdlet.ParameterSetName)"
        $monitorsBaseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors"
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {

            'BySearch' {
                # Build the query string using the provided parameters
                $queryParams = @()
                $queryParams += "type=$Type"
                $queryParams += "search=$([uri]::EscapeDataString($Search))"

                if ($IncludeDeviceMonitors) { $queryParams += "includeDeviceMonitors=true" }
                if ($IncludeSystemMonitors) { $queryParams += "includeSystemMonitors=true" }
                if ($IncludeCoreMonitors) { $queryParams += "includeCoreMonitors=true" }
                if (-not $FailIfInUse) { $queryParams += "failIfInUse=false" }

                $uri = "${monitorsBaseUri}/-?" + ($queryParams -join "&")
                Write-Verbose "Constructed URI: $uri"

                if (-not $PSCmdlet.ShouldProcess("Monitors matching '${Search}'", "Delete")) { return }

                Write-Debug "Deleting monitors matching the search query: ${Search}"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method DELETE
                    if ($result.data.successful -gt 0) {
                        Write-Verbose "Successfully deleted $($result.data.successful) monitor(s)."
                    }
                    elseif ($result.data.errors) {
                        Write-Warning "Errors occurred while deleting monitors:"
                        foreach ($errItem in $result.data.errors) {
                            Write-Warning "TemplateId: $($errItem.templateId) - Messages: $($errItem.messages -join ', ')"
                        }
                    }
                    else {
                        Write-Warning "No monitors were deleted."
                    }
                    return $result
                }
                catch {
                    Write-Error "Error deleting monitors: $($_.Exception.Message)"
                }
            }

            'ById' {
                $queryParams = @()
                if ($Type) { $queryParams += "type=$Type" }
                if (-not $FailIfInUse) { $queryParams += "failIfInUse=false" }
                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${monitorsBaseUri}/${MonitorId}${query}"
                if (-not $PSCmdlet.ShouldProcess("Monitor ${MonitorId}", "Delete")) { return }

                Write-Debug "DELETE URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method DELETE
                    if ($result.data) {
                        Write-Verbose "Successfully deleted monitor ${MonitorId}."
                        return $result.data
                    }
                    return $result
                }
                catch {
                    Write-Error "Error deleting monitor ${MonitorId}: $($_.Exception.Message)"
                }
            }

            'RemoveAssignments' {
                $uri = "${monitorsBaseUri}/${MonitorId}/assignments/-"
                if (-not $PSCmdlet.ShouldProcess("All assignments for monitor ${MonitorId}", "Delete")) { return }

                Write-Debug "DELETE URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method DELETE
                    if ($result.data) {
                        Write-Verbose "Successfully removed all assignments for monitor ${MonitorId}."
                        return $result.data
                    }
                    return $result
                }
                catch {
                    Write-Error "Error removing assignments for monitor ${MonitorId}: $($_.Exception.Message)"
                }
            }
        }
    }

    end {
        Write-Debug "Remove-WUGActiveMonitor function completed."
    }
}



# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBym/0liPJUNO7X
# 1JkHvHwESWyjYd86VmzE45r98C9juqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgOR4tz1L/6taaQbRukYdKXsNQEmZGVEiK
# GZl+Iy0HfgwwDQYJKoZIhvcNAQEBBQAEggIAd3hcNhWWTEKPc36E7ZLIbQC3aJO5
# lrSNRe9L3lTj2pf89K84FWXMCxE+CeSSMLAQT7Dnyy14naQjAslotWrZ57lS821T
# Z1Ono/usSafT2uP9C4BgkxnzL8tBr3PBDihikP11fExwEXnr9/G0hQVgg7KA/PHG
# y0oyx4f5/oJAfcbbJuLnHrZu7wYSGlt8jCFtursskRhpoyxbSeP6vyLneF0oT6gZ
# Jm2p7M4tKWz5CW4TQxcfmc+oBs3ZGwEyILFI8otQ0LtpWasdd/XKMSz9ogDRkWQZ
# mdqJIUs2eQy02FJh881qiAoaMzjiBws6j+8LIA5/P6h9MKXFR9fYHMut5qmHnSrR
# ryUaxr5FDwHn1PLyDanaDaRaEQ1Si1lpB3zf/Iy9/R84PwWxRbHoyhjseL6BBjDy
# KJb+mx31/hxzTdLHXBmzozeJCH+5uZUeN2RBIGA13/eZvx1CHI/+pGql4WtZvifP
# Z23fShGiV0U67RCB8160kAB+g0YSAAagyUzMrqdCIXzSgs8mD8GRvoIBeN70GVNg
# r9LW3MNPammC8Zt4O/LdOF062ic4dFIluolnJlUcZekws7JBZfi2vZBdlr0ZatTK
# qbPTK3waqgfJninhwPb/3SVSHE6mciHz5JHUGiZkPXs/2NU6yzQY0Qxp445dynTS
# TmH6gpDfz7NzkWc=
# SIG # End signature block
