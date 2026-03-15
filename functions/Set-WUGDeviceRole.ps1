<#
.SYNOPSIS
Assigns, removes, or batch-updates device role assignments on devices and groups.

.DESCRIPTION
The Set-WUGDeviceRole function handles role assignment operations on specific devices and groups.
For managing the role library itself (enable/disable/delete/restore roles, apply templates),
use Set-WUGRole instead. For importing/exporting role packages, use
Import-WUGRoleTemplate and Export-WUGRoleTemplate.

.PARAMETER SetDeviceRoleKind
Switch to assign a role of the specified kind to a device.
Endpoint: PUT /api/v1/devices/{deviceId}/roles/{kind}

.PARAMETER AssignDeviceRole
Switch to assign a role to a device via the generic roles endpoint.
Endpoint: PUT /api/v1/devices/{deviceId}/roles/-

.PARAMETER RemoveDeviceRoles
Switch to remove role assignments from a device, filtered by kind.
Endpoint: DELETE /api/v1/devices/{deviceId}/roles/-

.PARAMETER BatchDeviceRole
Switch to batch-assign roles of the specified kind across all devices.
Endpoint: PATCH /api/v1/devices/-/roles/{kind}

.PARAMETER GroupRole
Switch to assign a role of the specified kind to a device group.
Endpoint: PUT /api/v1/device-groups/{groupId}/roles/{kind}

.PARAMETER DeviceId
The device ID. Required for SetDeviceRoleKind, AssignDeviceRole, and RemoveDeviceRoles.

.PARAMETER GroupId
The device group ID. Required for GroupRole.

.PARAMETER RoleKind
The kind of role. Valid values: brand, os, primary, sub-role.
Required for SetDeviceRoleKind, BatchDeviceRole, and GroupRole.

.PARAMETER DeleteKind
The kind of role to remove when using RemoveDeviceRoles. Valid values: all, role, brand, os, subRole.
Default: all.

.PARAMETER Body
The JSON body for the request.

.EXAMPLE
# Assign a brand role to a device
$body = @{ roleId = "brand-role-id" } | ConvertTo-Json
Set-WUGDeviceRole -SetDeviceRoleKind -DeviceId "123" -RoleKind brand -Body $body

.EXAMPLE
# Remove all role assignments from a device
Set-WUGDeviceRole -RemoveDeviceRoles -DeviceId "123" -DeleteKind all

.EXAMPLE
# Batch-assign OS roles across all devices
$body = @{ items = @(@{ deviceId = "1"; roleId = "os-role-id" }) } | ConvertTo-Json -Depth 5
Set-WUGDeviceRole -BatchDeviceRole -RoleKind os -Body $body

.EXAMPLE
# Assign a brand role to a device group
$body = @{ roleId = "brand-role-id" } | ConvertTo-Json
Set-WUGDeviceRole -GroupRole -GroupId "5" -RoleKind brand -Body $body

.NOTES
Author: Jason Alberino (jason@wug.ninja)
Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#tag/DeviceRole
#>
function Set-WUGDeviceRole {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'SetDeviceRoleKind')]
        [switch]$SetDeviceRoleKind,

        [Parameter(Mandatory = $true, ParameterSetName = 'AssignDeviceRole')]
        [switch]$AssignDeviceRole,

        [Parameter(Mandatory = $true, ParameterSetName = 'RemoveDeviceRoles')]
        [switch]$RemoveDeviceRoles,

        [Parameter(Mandatory = $true, ParameterSetName = 'BatchDeviceRole')]
        [switch]$BatchDeviceRole,

        [Parameter(Mandatory = $true, ParameterSetName = 'GroupRole')]
        [switch]$GroupRole,

        [Parameter(Mandatory = $true, ParameterSetName = 'SetDeviceRoleKind')]
        [Parameter(Mandatory = $true, ParameterSetName = 'AssignDeviceRole')]
        [Parameter(Mandatory = $true, ParameterSetName = 'RemoveDeviceRoles')]
        [string]$DeviceId,

        [Parameter(Mandatory = $true, ParameterSetName = 'GroupRole')]
        [string]$GroupId,

        [Parameter(Mandatory = $true, ParameterSetName = 'SetDeviceRoleKind')]
        [Parameter(Mandatory = $true, ParameterSetName = 'BatchDeviceRole')]
        [Parameter(Mandatory = $true, ParameterSetName = 'GroupRole')]
        [ValidateSet('brand', 'os', 'primary', 'sub-role')]
        [string]$RoleKind,

        [Parameter(ParameterSetName = 'RemoveDeviceRoles')]
        [ValidateSet('all', 'role', 'brand', 'os', 'subRole')]
        [string]$DeleteKind = 'all',

        [Parameter(Mandatory = $true, ParameterSetName = 'SetDeviceRoleKind')]
        [Parameter(Mandatory = $true, ParameterSetName = 'AssignDeviceRole')]
        [Parameter(Mandatory = $true, ParameterSetName = 'BatchDeviceRole')]
        [Parameter(Mandatory = $true, ParameterSetName = 'GroupRole')]
        [string]$Body
    )

    begin {
        Write-Debug "Starting Set-WUGDeviceRole function. ParameterSet: $($PSCmdlet.ParameterSetName)"
    }

    process {
        switch ($PSCmdlet.ParameterSetName) {

            'SetDeviceRoleKind' {
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/roles/${RoleKind}"
                $method = 'PUT'
                Write-Debug "Setting ${RoleKind} role on device ${DeviceId}. URI: $uri"
                if (-not $PSCmdlet.ShouldProcess("Device $DeviceId role ${RoleKind}", "Set")) { return }
            }

            'AssignDeviceRole' {
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/roles/-"
                $method = 'PUT'
                Write-Debug "Assigning role to device ${DeviceId}. URI: $uri"
                if (-not $PSCmdlet.ShouldProcess("Device $DeviceId", "Assign role")) { return }
            }

            'RemoveDeviceRoles' {
                $queryParams = @()
                if ($DeleteKind) { $queryParams += "kind=$DeleteKind" }
                $query = if ($queryParams.Count -gt 0) { "?" + ($queryParams -join "&") } else { "" }
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/roles/-${query}"
                $method = 'DELETE'
                Write-Debug "Removing roles from device ${DeviceId} (kind=$DeleteKind). URI: $uri"

                if (-not $PSCmdlet.ShouldProcess("Device $DeviceId roles (kind=$DeleteKind)", "Remove")) { return }

                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method $method
                    if ($result.data) { return $result.data }
                    return $result
                }
                catch {
                    Write-Error "Error removing roles from device ${DeviceId}: $_"
                    return
                }
            }

            'BatchDeviceRole' {
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/-/roles/${RoleKind}"
                $method = 'PATCH'
                Write-Debug "Batch assigning ${RoleKind} role. URI: $uri"
                if (-not $PSCmdlet.ShouldProcess("All devices role ${RoleKind}", "Batch assign")) { return }
            }

            'GroupRole' {
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/device-groups/${GroupId}/roles/${RoleKind}"
                $method = 'PUT'
                Write-Debug "Setting ${RoleKind} role on group ${GroupId}. URI: $uri"
                if (-not $PSCmdlet.ShouldProcess("Group $GroupId role ${RoleKind}", "Set")) { return }
            }
        }

        # Handle Body-based operations
        if ($Body) {
            try {
                $result = Get-WUGAPIResponse -Uri $uri -Method $method -Body $Body
                if ($result.data) { return $result.data }
                return $result
            }
            catch {
                Write-Error "Error in Set-WUGDeviceRole ($($PSCmdlet.ParameterSetName)): $_"
            }
        }
    }

    end {
        Write-Debug "Completed Set-WUGDeviceRole function."
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCOogDV1JboUYr8
# 1DGlNohJ1VtO4ULKQBMFguElcjCZ2KCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgNGCcZnLDl7GzOvvnmToUTtPzj0+INAiG
# ZFy/6v0sHlUwDQYJKoZIhvcNAQEBBQAEggIAQK815MwLZWrXkme6NHc4wLiPbUTd
# QIuRjPxxoZjBLWbOkfN3VcvQmrGuYyHzl+phk0K6T1EoVDcq8wCEDP6Mkmnyo4W2
# TTnD5IH7yVfXHvf7jtfe5pmpKL8iNRlF0FJzn69K/WP2EgM+Q+GaCAg2W+0qJ59c
# P08PJvYWp5qYoctSmAVVVTPwukr2HAA2HdmSYxGlAHWuW7MLcHt4G1ORzqHvyqqz
# cVmYRtFMR7SlHLbvSJrq/dtKqj9YxhaH+dg4dboPI/WH/ui1tXQTO6+YQR2+2kwS
# YEZL54ZuuwdtYrGRKX+K1i5ljV+EkQzcpyQke81PbeyefnphoB6tFX81jiCxXNsb
# /rGU8MVVcxnnaDFVG9UjZBW5Ow1ttSdmgXANU9f2ihnSx8ZPkATiEaUBwT25LtjC
# pndxqpCqTMgk8grnocqiOZ82gMDgnsqLTln89W05R+6wkWc2JU/no8+Og1SELOI8
# fGRgtp5th3+LXmcdNSrvpQs8nupERVd/tBKo73xbQvkOBqDM9pQpWAUTlRWorO9Z
# xKua8IjbwhqYRSKwU6koBMBHp270rC8Xrit+3zprHxpFrONCCNVeuJTqGNDbiGgm
# KLa/qo6n06Jtk5rCs3HhTJLxgwkXYUqjWk0qmLGSxwQb7wY/4gWxi8v70Jor4SP9
# LsqulqX89GxagdE=
# SIG # End signature block
