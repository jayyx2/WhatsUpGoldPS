<#
.SYNOPSIS
Retrieves device roles from the WhatsUp Gold role library.

.DESCRIPTION
The Get-WUGRole function retrieves device role data from the WhatsUp Gold role library via the REST API.
It supports multiple operations via parameter sets:
- Retrieve a specific role by ID
- List all device roles with filtering
- Get role assignments for a specific role or all roles
- Get role templates
- Get percent variables

.PARAMETER RoleId
The ID of the device role. Used with ByRoleId, Assignments, and Template parameter sets.

.PARAMETER View
Amount of role data to retrieve. Valid values: id, simple, basic, summary. Default: simple.

.PARAMETER Kind
Return roles of the specified kind.

.PARAMETER AssignmentKind
Kind filter for the AllAssignments parameter set. Valid values: all, role, brand, os, subRole.

.PARAMETER TemplateKind
Kind filter for the AllTemplates parameter set. Valid values: any, role, brand, os, subRole, monitor, interfaceFilter, deviceFilter, monitorCriteria.

.PARAMETER Source
Filter roles by source (e.g., system, systemModified, userDefined).

.PARAMETER Filter
Optional case-insensitive filter on role name and alternate names.

.PARAMETER Search
Optional case-insensitive search text.

.PARAMETER Assignments
Switch to retrieve role assignments for the specified RoleId.

.PARAMETER AllAssignments
Switch to retrieve all role assignments across all roles.

.PARAMETER Template
Switch to retrieve a role template for the specified RoleId.

.PARAMETER AllTemplates
Switch to retrieve all role templates.

.PARAMETER PercentVariables
Switch to retrieve percent variables for a given choice.

.PARAMETER DeviceView
Type of device information to be returned for assignments.

.PARAMETER DeviceFilter
Optional case-insensitive filter on device address, display and hostnames.

.PARAMETER IncludeUnassignedRoles
When true, all roles matching the filter are returned even if they have no assignments.

.PARAMETER Options
Type of template to be created. Valid values: all, clone, transfer, update.

.PARAMETER Choice
Type of percent variables requested. Valid values: discoveryDevice, discoverySession, monitoredDevice, discoveredNetwork, device.

.PARAMETER PageId
Page to return for paged results.

.PARAMETER Limit
Number of items per page.

.EXAMPLE
Get-WUGRole -RoleId "abc-123"

.EXAMPLE
Get-WUGRole -Kind role -View summary

.EXAMPLE
Get-WUGRole -Assignments -RoleId "abc-123" -DeviceView basic

.EXAMPLE
Get-WUGRole -AllAssignments -AssignmentKind role -DeviceView card

.EXAMPLE
Get-WUGRole -Template -RoleId "abc-123" -Options transfer

.EXAMPLE
Get-WUGRole -AllTemplates -TemplateKind role -Options all

.EXAMPLE
Get-WUGRole -PercentVariables -Choice monitoredDevice

.NOTES
Author: Jason Alberino (jason@wug.ninja)
Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#tag/DeviceRole
#>
function Get-WUGRole {
    [CmdletBinding(DefaultParameterSetName = 'ListRoles')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByRoleId', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Parameter(Mandatory = $true, ParameterSetName = 'Assignments')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
        [Alias('id')]
        [string[]]$RoleId,

        [Parameter(ParameterSetName = 'ByRoleId')]
        [Parameter(ParameterSetName = 'ListRoles')]
        [ValidateSet('id', 'simple', 'basic', 'summary')]
        [string]$View = 'simple',

        [Parameter(ParameterSetName = 'ListRoles')]
        [ValidateSet('any', 'role', 'brand', 'os', 'subRole', 'monitor', 'interfaceFilter', 'deviceFilter', 'monitorCriteria')]
        [string]$Kind,

        [Parameter(ParameterSetName = 'AllAssignments')]
        [ValidateSet('all', 'role', 'brand', 'os', 'subRole')]
        [string]$AssignmentKind,

        [Parameter(ParameterSetName = 'AllTemplates')]
        [ValidateSet('any', 'role', 'brand', 'os', 'subRole', 'monitor', 'interfaceFilter', 'deviceFilter', 'monitorCriteria')]
        [string]$TemplateKind,

        [Parameter(ParameterSetName = 'ListRoles')]
        [Parameter(ParameterSetName = 'AllTemplates')]
        [string]$Source,

        [Parameter(ParameterSetName = 'ListRoles')]
        [Parameter(ParameterSetName = 'Assignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [Parameter(ParameterSetName = 'AllTemplates')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'ListRoles')]
        [Parameter(ParameterSetName = 'AllTemplates')]
        [string]$Search,

        [Parameter(Mandatory = $true, ParameterSetName = 'Assignments')]
        [switch]$Assignments,

        [Parameter(Mandatory = $true, ParameterSetName = 'AllAssignments')]
        [switch]$AllAssignments,

        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
        [switch]$Template,

        [Parameter(Mandatory = $true, ParameterSetName = 'AllTemplates')]
        [switch]$AllTemplates,

        [Parameter(Mandatory = $true, ParameterSetName = 'PercentVariables')]
        [switch]$PercentVariables,

        [Parameter(ParameterSetName = 'Assignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [ValidateSet('id', 'basic', 'card', 'overview')]
        [string]$DeviceView,

        [Parameter(ParameterSetName = 'Assignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [string]$DeviceFilter,

        [Parameter(ParameterSetName = 'AllAssignments')]
        [bool]$IncludeUnassignedRoles,

        [Parameter(ParameterSetName = 'Template')]
        [Parameter(ParameterSetName = 'AllTemplates')]
        [ValidateSet('all', 'clone', 'transfer', 'update')]
        [string]$Options,

        [Parameter(ParameterSetName = 'PercentVariables')]
        [ValidateSet('discoveryDevice', 'discoverySession', 'monitoredDevice', 'discoveredNetwork', 'device')]
        [string]$Choice,

        [Parameter(ParameterSetName = 'ListRoles')]
        [Parameter(ParameterSetName = 'Assignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [Parameter(ParameterSetName = 'AllTemplates')]
        [string]$PageId,

        [Parameter(ParameterSetName = 'ListRoles')]
        [Parameter(ParameterSetName = 'Assignments')]
        [Parameter(ParameterSetName = 'AllAssignments')]
        [Parameter(ParameterSetName = 'AllTemplates')]
        [int]$Limit
    )

    begin {
        Write-Debug "Starting Get-WUGRole function. ParameterSet: $($PSCmdlet.ParameterSetName)"
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/device-role"
        $finalOutput = @()
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {

            'ByRoleId' {
                foreach ($rid in $RoleId) {
                    $queryParams = @()
                    if ($View) { $queryParams += "view=$View" }
                    $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                    $uri = "${baseUri}/${rid}${query}"

                    Write-Debug "Fetching role from URI: $uri"
                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $finalOutput += $result.data }
                    }
                    catch {
                        Write-Error "Error fetching role ${rid}: $_"
                    }
                }
            }

            'ListRoles' {
                $queryParams = @()
                if ($View) { $queryParams += "view=$View" }
                if ($Kind) { $queryParams += "kind=$Kind" }
                if ($Source) { $queryParams += "source=$([uri]::EscapeDataString($Source))" }
                if ($Filter) { $queryParams += "filter=$([uri]::EscapeDataString($Filter))" }
                if ($Search) { $queryParams += "search=$([uri]::EscapeDataString($Search))" }
                if ($PSBoundParameters.ContainsKey('Limit')) { $queryParams += "limit=$Limit" }
                if ($PageId) { $queryParams += "pageId=$([uri]::EscapeDataString($PageId))" }

                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${baseUri}/-${query}"

                Write-Debug "Listing roles from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) { $finalOutput += $result.data }
                }
                catch {
                    Write-Error "Error listing device roles: $_"
                }
            }

            'Assignments' {
                foreach ($rid in $RoleId) {
                    $queryParams = @()
                    if ($Filter) { $queryParams += "filter=$([uri]::EscapeDataString($Filter))" }
                    if ($DeviceView) { $queryParams += "deviceView=$DeviceView" }
                    if ($DeviceFilter) { $queryParams += "deviceFilter=$([uri]::EscapeDataString($DeviceFilter))" }
                    if ($PSBoundParameters.ContainsKey('Limit')) { $queryParams += "limit=$Limit" }
                    if ($PageId) { $queryParams += "pageId=$([uri]::EscapeDataString($PageId))" }

                    $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                    $uri = "${baseUri}/${rid}/assignments/-${query}"

                    Write-Debug "Fetching assignments from URI: $uri"
                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $finalOutput += $result.data }
                    }
                    catch {
                        Write-Error "Error fetching assignments for role ${rid}: $_"
                    }
                }
            }

            'AllAssignments' {
                $queryParams = @()
                if ($AssignmentKind) { $queryParams += "kind=$AssignmentKind" }
                if ($Filter) { $queryParams += "filter=$([uri]::EscapeDataString($Filter))" }
                if ($PSBoundParameters.ContainsKey('IncludeUnassignedRoles')) { $queryParams += "includeUnassignedRoles=$($IncludeUnassignedRoles.ToString().ToLower())" }
                if ($DeviceView) { $queryParams += "deviceView=$DeviceView" }
                if ($DeviceFilter) { $queryParams += "deviceFilter=$([uri]::EscapeDataString($DeviceFilter))" }
                if ($PSBoundParameters.ContainsKey('Limit')) { $queryParams += "limit=$Limit" }
                if ($PageId) { $queryParams += "pageId=$([uri]::EscapeDataString($PageId))" }

                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${baseUri}/-/assignments/-${query}"

                Write-Debug "Fetching all assignments from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) { $finalOutput += $result.data }
                }
                catch {
                    Write-Error "Error fetching all role assignments: $_"
                }
            }

            'Template' {
                foreach ($rid in $RoleId) {
                    $queryParams = @()
                    if ($Options) { $queryParams += "options=$Options" }

                    $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                    $uri = "${baseUri}/${rid}/config/template${query}"

                    Write-Debug "Fetching template from URI: $uri"
                    try {
                        $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                        if ($result.data) { $finalOutput += $result.data }
                    }
                    catch {
                        Write-Error "Error fetching template for role ${rid}: $_"
                    }
                }
            }

            'AllTemplates' {
                $queryParams = @()
                if ($Options) { $queryParams += "options=$Options" }
                if ($TemplateKind) { $queryParams += "kind=$TemplateKind" }
                if ($Source) { $queryParams += "source=$([uri]::EscapeDataString($Source))" }
                if ($Filter) { $queryParams += "filter=$([uri]::EscapeDataString($Filter))" }
                if ($Search) { $queryParams += "search=$([uri]::EscapeDataString($Search))" }
                if ($PSBoundParameters.ContainsKey('Limit')) { $queryParams += "limit=$Limit" }
                if ($PageId) { $queryParams += "pageId=$([uri]::EscapeDataString($PageId))" }

                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${baseUri}/-/config/template${query}"

                Write-Debug "Fetching all templates from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) { $finalOutput += $result.data }
                }
                catch {
                    Write-Error "Error fetching device role templates: $_"
                }
            }

            'PercentVariables' {
                $queryParams = @()
                if ($Choice) { $queryParams += "choice=$Choice" }

                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${baseUri}/-/percentVariables${query}"

                Write-Debug "Fetching percent variables from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) { $finalOutput += $result.data }
                }
                catch {
                    Write-Error "Error fetching percent variables: $_"
                }
            }
        }
    }

    end {
        Write-Debug "Completed Get-WUGRole function. Items returned: $($finalOutput.Count)"
        return $finalOutput
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAsbDrm7+1vhbcl
# fIeFfUqV4QEtLt+qKVOzviH8OttbfKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgxoOZD3wthCFA+ekaKWKixmX/2YDH0D0X
# gVuifTFphq8wDQYJKoZIhvcNAQEBBQAEggIAd4mzVdzSSlB2p9QcMjzjDLzGSy2Q
# 8PCuLp7PmVcUcinTNf5S6ZVnzyZlMhmDpv5OF64lJNSl6nU9PS+kNLNebNz0Aa3A
# CJ7JPsEmv3Og0EVlhRBzi6UiYRyp7n9j6pnR2kOmPAuEl54VoGtLZ/PnA5x/4ZB9
# Sf22a60o2bVNNt9CtCM0O9L+OsC14b+ZyJNHGby8E3wPL/6PxIEGsXFr3UZRgJyb
# G5uNPKPSDmvSQswwgsGBFT5DGbzel49lLGtTSis0WpMz4TesxUJYI2Yd4588jalr
# 1B0fMM/4UyofmglORzTsajRNjyFyl722oPYlsqVooEgiN3uZDt70Ie+pwTvQLsnf
# erCQQy5sW57MSP6GF9hWTQDd3RpoGiCDXYWMmNpjZgyPKKebY4kIkrWIYWZ4tnlI
# cRThJxbWbaBRiOB+TqqLGfqS5buyjZMDk/vWPUnhL5m2qj1nIQjDWYrr/FRyPxGA
# Bi1oPyEPF5cNuYJLlFoIT8J1Hdub/AYVBIhLy1lu9CBQj34AveyfN1E97P2qyxPn
# zGbwffBuiIgrDbr27uta1LxVRDB7DqsN/3RyqmhL6BDx/c8hz/BGTL5TFYxm9fev
# 0Ri/6sUOcrR66JNJHJrRTGg+sG1fLfXMh0hOPmq52/GagTPwATdkO24h+YqAXTP+
# EAs9rcZaJbPBxNM=
# SIG # End signature block
