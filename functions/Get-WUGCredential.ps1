<#
.SYNOPSIS
Retrieves credentials from the WhatsUp Gold credential library.

.DESCRIPTION
The Get-WUGCredential function retrieves credentials from WhatsUp Gold using the REST API. It supports:
- Retrieving a specific credential by ID using /api/v1/credentials/{credentialId}
- Listing/searching all credentials using /api/v1/credentials/-
- Retrieving credential assignments using /api/v1/credentials/{credentialId}/assignments/-
- Retrieving a credential template using /api/v1/credentials/{credentialId}/config/template
- Retrieving all credential templates using /api/v1/credentials/-/config/template
- Retrieving credential helpers using /api/v1/credentials/-/helpers
- Retrieving all global credential assignments using /api/v1/credentials/-/assignments/-

.PARAMETER CredentialId
The ID of a specific credential to retrieve. Used with the ByCredentialId, CredentialAssignments, and CredentialTemplate parameter sets.

.PARAMETER Assignments
Switch to retrieve assignments for the specified CredentialId.

.PARAMETER CredentialTemplate
Switch to retrieve the template for a specific credential by CredentialId.

.PARAMETER AllCredentialTemplates
Switch to retrieve all credential templates.

.PARAMETER Helpers
Switch to retrieve credential helpers.

.PARAMETER AllAssignments
Switch to retrieve all global credential assignments.

.PARAMETER SearchValue
Optional search text to filter credentials by display name, description, or type. Case-insensitive.

.PARAMETER View
Level of credential information to return. Valid values: id, basic, summary, details. Default: basic.

.PARAMETER Type
Filter credentials by type. Valid values: all, snmpV1, snmpV2, snmpV3, windows, ado, telnet, ssh, vmware, jmx, smis, aws, azure, meraki, restapi, ubiquiti, redfish. Default: all.

.PARAMETER Limit
Maximum number of credentials per page. Valid range: 1-250. Default: 250.

.EXAMPLE
# Get all credentials
Get-WUGCredential

.EXAMPLE
# Get a specific credential by ID
Get-WUGCredential -CredentialId "abc-123"

.EXAMPLE
# Search for SSH credentials
Get-WUGCredential -SearchValue "Linux" -Type ssh

.EXAMPLE
# Get credential assignments
Get-WUGCredential -CredentialId "abc-123" -Assignments

.EXAMPLE
# Get a credential template
Get-WUGCredential -CredentialId "abc-123" -CredentialTemplate

.EXAMPLE
# Get all credential templates
Get-WUGCredential -AllCredentialTemplates

.EXAMPLE
# Get credential helpers
Get-WUGCredential -Helpers

.EXAMPLE
# Get all global credential assignments
Get-WUGCredential -AllAssignments

.NOTES
Author: Jason Alberino (jason@wug.ninja)
Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#tag/Credential
#>
function Get-WUGCredential {
    [CmdletBinding(DefaultParameterSetName = 'ListCredentials')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByCredentialId', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialAssignments')]
        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialTemplate')]
        [Alias('id')]
        [string[]]$CredentialId,

        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialAssignments')]
        [switch]$Assignments,

        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialTemplate')]
        [switch]$CredentialTemplate,

        [Parameter(Mandatory = $true, ParameterSetName = 'AllCredentialTemplates')]
        [switch]$AllCredentialTemplates,

        [Parameter(Mandatory = $true, ParameterSetName = 'Helpers')]
        [switch]$Helpers,

        [Parameter(Mandatory = $true, ParameterSetName = 'AllAssignments')]
        [switch]$AllAssignments,

        [Parameter(ParameterSetName = 'ListCredentials')]
        [Parameter(ParameterSetName = 'AllCredentialTemplates')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [string]$SearchValue,

        [Parameter(ParameterSetName = 'ByCredentialId')]
        [Parameter(ParameterSetName = 'ListCredentials')]
        [Parameter(ParameterSetName = 'CredentialAssignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [ValidateSet('id', 'basic', 'summary', 'details')]
        [string]$View = 'basic',

        [Parameter(ParameterSetName = 'ListCredentials')]
        [Parameter(ParameterSetName = 'AllCredentialTemplates')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [Parameter(ParameterSetName = 'Helpers')]
        [ValidateSet('all', 'snmpV1', 'snmpV2', 'snmpV3', 'windows', 'ado', 'telnet', 'ssh', 'vmware', 'jmx', 'smis', 'aws', 'azure', 'meraki', 'restapi', 'ubiquiti', 'redfish')]
        [string]$Type = 'all',

        [Parameter(ParameterSetName = 'ListCredentials')]
        [Parameter(ParameterSetName = 'CredentialAssignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [ValidateRange(1, 250)]
        [int]$Limit = 250,

        [Parameter(ParameterSetName = 'CredentialAssignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [ValidateSet('id', 'basic', 'summary', 'details')]
        [string]$DeviceView,

        [Parameter(ParameterSetName = 'CredentialTemplate')]
        [Parameter(ParameterSetName = 'AllCredentialTemplates')]
        [string]$Key,

        [Parameter(ParameterSetName = 'Helpers')]
        [string]$Input
    )

    begin {
        Write-Debug "Starting Get-WUGCredential function. ParameterSet: $($PSCmdlet.ParameterSetName)"
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/credentials"
        $finalOutput = @()
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {

            'ByCredentialId' {
                foreach ($cid in $CredentialId) {
                    $queryParams = @()
                    if ($View) { $queryParams += "view=$View" }
                    $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                    $uri = "${baseUri}/${cid}${query}"

                    Write-Debug "Fetching credential from URI: $uri"
                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $finalOutput += $result.data }
                    }
                    catch {
                        Write-Error "Error fetching credential ${cid}: $_"
                    }
                }
            }

            'CredentialAssignments' {
                foreach ($cid in $CredentialId) {
                    $queryParams = @()
                    if ($View) { $queryParams += "view=$View" }
                    if ($DeviceView) { $queryParams += "deviceView=$DeviceView" }
                    $queryParams += "limit=$Limit"
                    $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                    $assignBaseUri = "${baseUri}/${cid}/assignments/-${query}"

                    Write-Debug "Fetching credential assignments from URI: $assignBaseUri"

                    $currentPageId = $null
                    $pageNumber = 0

                    do {
                        $currentUri = if ($null -ne $currentPageId) {
                            $sep = if ($assignBaseUri -match '\?') { '&' } else { '?' }
                            "${assignBaseUri}${sep}pageId=$currentPageId"
                        } else { $assignBaseUri }

                        try {
                            $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'
                            if ($result.data) { $finalOutput += $result.data }
                            $currentPageId = $result.paging.nextPageId
                            $pageNumber++
                        }
                        catch {
                            Write-Error "Error fetching assignments for credential ${cid}: $_"
                            break
                        }
                    } while ($null -ne $currentPageId)
                }
            }

            'ListCredentials' {
                $allData = @()
                $currentPageId = $null
                $pageCount = 0

                do {
                    $queryParams = @()
                    if ($View) { $queryParams += "view=$View" }
                    if ($Type -and $Type -ne 'all') { $queryParams += "type=$Type" }
                    if ($SearchValue) { $queryParams += "search=$([uri]::EscapeDataString($SearchValue))" }
                    $queryParams += "limit=$Limit"
                    if ($currentPageId) { $queryParams += "pageId=$([uri]::EscapeDataString($currentPageId))" }

                    $query = "?" + ($queryParams -join "&")
                    $uri = "${baseUri}/-${query}"

                    Write-Debug "Listing credentials from URI: $uri"
                    $pageCount++
                    Write-Progress -Activity "Retrieving credentials" -Status "Page $pageCount" -PercentComplete -1

                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $allData += $result.data }
                        $currentPageId = $result.paging.nextPageId
                    }
                    catch {
                        Write-Error "Error listing credentials: $_"
                        break
                    }
                } while ($currentPageId)

                Write-Progress -Activity "Retrieving credentials" -Completed
                $finalOutput = $allData
            }

            'CredentialTemplate' {
                foreach ($cid in $CredentialId) {
                    $queryParams = @()
                    if ($Key) { $queryParams += "key=$([uri]::EscapeDataString($Key))" }
                    $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                    $uri = "${baseUri}/${cid}/config/template${query}"

                    Write-Debug "Fetching credential template from URI: $uri"
                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $finalOutput += $result.data }
                    }
                    catch {
                        Write-Error "Error fetching template for credential ${cid}: $_"
                    }
                }
            }

            'AllCredentialTemplates' {
                $queryParams = @()
                if ($Key) { $queryParams += "key=$([uri]::EscapeDataString($Key))" }
                if ($Type -and $Type -ne 'all') { $queryParams += "type=$Type" }
                if ($SearchValue) { $queryParams += "search=$([uri]::EscapeDataString($SearchValue))" }
                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${baseUri}/-/config/template${query}"

                Write-Debug "Fetching all credential templates from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) { $finalOutput += $result.data }
                }
                catch {
                    Write-Error "Error fetching credential templates: $_"
                }
            }

            'Helpers' {
                $queryParams = @()
                if ($Input) { $queryParams += "input=$([uri]::EscapeDataString($Input))" }
                if ($Type -and $Type -ne 'all') { $queryParams += "type=$Type" }
                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${baseUri}/-/helpers${query}"

                Write-Debug "Fetching credential helpers from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) { $finalOutput += $result.data }
                }
                catch {
                    Write-Error "Error fetching credential helpers: $_"
                }
            }

            'AllAssignments' {
                $allData = @()
                $currentPageId = $null
                $pageCount = 0

                do {
                    $queryParams = @()
                    if ($View) { $queryParams += "view=$View" }
                    if ($Type -and $Type -ne 'all') { $queryParams += "type=$Type" }
                    if ($SearchValue) { $queryParams += "search=$([uri]::EscapeDataString($SearchValue))" }
                    if ($DeviceView) { $queryParams += "deviceView=$DeviceView" }
                    $queryParams += "limit=$Limit"
                    if ($currentPageId) { $queryParams += "pageId=$([uri]::EscapeDataString($currentPageId))" }

                    $query = "?" + ($queryParams -join "&")
                    $uri = "${baseUri}/-/assignments/-${query}"

                    Write-Debug "Fetching all credential assignments from URI: $uri"
                    $pageCount++
                    Write-Progress -Activity "Retrieving all credential assignments" -Status "Page $pageCount" -PercentComplete -1

                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $allData += $result.data }
                        $currentPageId = $result.paging.nextPageId
                    }
                    catch {
                        Write-Error "Error fetching all credential assignments: $_"
                        break
                    }
                } while ($currentPageId)

                Write-Progress -Activity "Retrieving all credential assignments" -Completed
                $finalOutput = $allData
            }
        }
    }

    end {
        Write-Debug "Completed Get-WUGCredential function. Total results: $($finalOutput.Count)"
        return $finalOutput
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCALTzLjo9wHCnsC
# bZ1TwDc54VoCGP7U4QzZtNfZ02R4j6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgPhO9U2f+/AYpNgoRB/y+mGaAYs3hOy3x
# 0P+IgGILDhQwDQYJKoZIhvcNAQEBBQAEggIAl7q8trRGT51o3QYPYU5gMnprfZpr
# vyadvmQCzWqwIWYj/h46t4zaDEoMuotVXESugsJMYXF+KmtcOYTJzR1G3u/LpF4s
# 3AeeY1HnD1vYBmIZKq9ZOMWfOxvqn+2drLqxxiLFaX7pkmRkvab3EE1Ujkm42cGk
# 5BhInpQ1cAyO4E/LhCl8/IZta1LtBpwzopBsDwg5ZZ+/S8sdbblA/ERQYDO4Ster
# P2VhxQcRDPXKi43JiL+s1GOhHpH4KC3cCBmNsTFjtIhaf1ALYw6SjD62mhvmpFSe
# 4PJTWx1ofNjDXMeC1kbQVoqNFFmA56Uk3d4xWC6bAei1YgBJNhJmoCoDAvqAO/0j
# bYhi/F0BRIUpcTBnS7vKTexVgHWHm3XYKfsPUgJLn24klaag0H5BB5KG0Mki2QN5
# vjPQnLU35060OM+CPgxN53mqCYZGV3oOqIxJdDaFd6qTr/M73Vy8nEyYpMvo0yec
# qlGL1zkHnSbsuxYXpix95T7deuIVYHfQs8sVMJRXOgu/+64jxTUJxwntQ5TglaU3
# 6zqBrcywEjRl03RVXjEUOIuyB2ry2L4s54VYMdi5RYTitu8Qy3231u9IjJWvntnF
# 9FE29toBW9Yda9U2iwk7kJHFOFlMR/BS5l6jPdhPYtcMf4lo+JFyreUhpE4Dq60R
# hB12XDQZ8RoSkd8=
# SIG # End signature block
