<#
.SYNOPSIS
Manage monitors in WhatsUp Gold at both the library and device levels, including assigning monitors to devices, updating device assignments (including batch), and updating library monitor definitions.

.DESCRIPTION
- Update library (template) monitor definitions.
- Assign new monitors to one or more devices.
- Update or disable/enable one or more monitor assignments by AssignmentId(s) for any device, supporting batch operations.
- All operations use the WhatsUp Gold REST API.
- Handles paging for bulk device assignment updates if required.

.PARAMETER Mode
"Library" (update template), "Device" (assign new or update assignment).

.PARAMETER MonitorId
Monitor's unique ID (required for library-level operations).

.PARAMETER DeviceId
Device ID(s) (required for device operations).

.PARAMETER AssignmentId
Assignment ID(s) to update for the device(s) (array/batch supported).

.PARAMETER MonitorTypeId
Monitor type ID (for assignment/creation).

.PARAMETER MonitorTypeName
Monitor type name (for assignment/creation).

.PARAMETER Enabled
Enable ("true") or disable ("false") the monitor assignment/template.

.PARAMETER Name
Template name (library only).

.PARAMETER Description
Template/assignment description.

.PARAMETER PropertyBags
Array of custom property bags (template only).

.PARAMETER UseInDiscovery
Boolean, for library monitors.

.PARAMETER PollingIntervalSeconds
Polling interval for device-level monitors in seconds.

.PARAMETER CriticalOrder
Critical order for device-level monitors.

.PARAMETER ActionPolicyId
Action policy ID for device-level monitors.

.PARAMETER ActionPolicyName
Action policy name for device-level monitors.

.EXAMPLE
# Disable a set of monitor assignments on a device:
Set-WUGActiveMonitor -Mode Device -DeviceId 123 -AssignmentId 456,457,458 -Enabled "false"

.EXAMPLE
# Enable and update polling interval for multiple assignments on multiple devices:
Set-WUGActiveMonitor -Mode Device -DeviceId 123,124 -AssignmentId 456,789 -Enabled "true" -PollingIntervalSeconds 300

.EXAMPLE
# Assign a new monitor to a device
Set-WUGActiveMonitor -Mode Device -DeviceId 101 -MonitorTypeName "CPU Usage" -PollingIntervalSeconds 120 -Enabled "true"

.EXAMPLE
# Update a monitor's library configuration
Set-WUGActiveMonitor -Mode Library -MonitorId "12345" -Name "Updated Monitor" -Description "Updated Description" -UseInDiscovery $true

.NOTES
Author: jayyx2 + Copilot
Reference: WhatsUp Gold REST API documentation
#>

function Set-WUGActiveMonitor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][ValidateSet("Library", "Device")][string]$Mode,
        [Parameter()][string]$MonitorId,
        [Parameter()][Alias("id")][int[]]$DeviceId,
        [Parameter()][int[]]$AssignmentId,
        [Parameter()][string]$MonitorTypeId,
        [Parameter()][string]$MonitorTypeName,
        [Parameter()][ValidateSet("true", "false")][string]$Enabled,
        [Parameter()][string]$Name,
        [Parameter()][string]$Description,
        [Parameter()][array]$PropertyBags,
        [Parameter()][bool]$UseInDiscovery,
        [Parameter()][ValidateRange(10, 86400)][int]$PollingIntervalSeconds,
        [Parameter()][ValidateRange(1, 32)][int]$CriticalOrder,
        [Parameter()][string]$ActionPolicyId,
        [Parameter()][string]$ActionPolicyName
    )

    begin {
        if (-not $global:WUGBearerHeaders) {
            Write-Error "Authorization header not set. Please run Connect-WUGServer first."
            return
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error "Base URI not found. Please run Connect-WUGServer first."
            return
        }
    }

    process {
        if ($Mode -eq "Library") {
            if (-not $MonitorId) {
                Write-Error "-MonitorId is required for library-level operations."
                return
            }
            $body = @{}
            if ($Name)          { $body.name = $Name }
            if ($Description)   { $body.description = $Description }
            if ($PropertyBags)  { $body.propertyBags = $PropertyBags }
            if ($PSBoundParameters.ContainsKey('UseInDiscovery')) { $body.useInDiscovery = $UseInDiscovery }
            if ($PSBoundParameters.ContainsKey('Enabled'))        { $body.enabled = [System.Convert]::ToBoolean($Enabled) }

            $uri = "${global:WhatsUpServerBaseURI}/api/v1/monitor/${MonitorId}"
            $jsonBody = $body | ConvertTo-Json -Depth 10

            try {
                $response = Get-WUGAPIResponse -Uri $uri -Method PUT -Body $jsonBody
                Write-Verbose "Library-level configuration updated successfully for monitor ID: ${MonitorId}."
                return $response
            }
            catch {
                Write-Error "Failed to update library configuration for monitor ID: ${MonitorId}: $_"
            }
        }
        elseif ($Mode -eq "Device") {
            if ($AssignmentId -and $DeviceId) {
                # Batch update/disable/enable existing assignments on one or more devices
                foreach ($deviceId in $DeviceId) {
                    foreach ($assignmentId in $AssignmentId) {
                        $body = @{}
                        if ($PSBoundParameters.ContainsKey('Enabled'))  { $body.enabled = [System.Convert]::ToBoolean($Enabled) }
                        if ($Description)        { $body.description = $Description }

                        $active = @{}
                        if ($PollingIntervalSeconds) { $active.pollingIntervalSeconds = $PollingIntervalSeconds }
                        if ($CriticalOrder)         { $active.criticalOrder = $CriticalOrder }
                        if ($ActionPolicyId)        { $active.actionPolicyId = $ActionPolicyId }
                        if ($ActionPolicyName)      { $active.actionPolicyName = $ActionPolicyName }
                        if ($active.Count -gt 0)    { $body.active = $active }

                        $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${deviceId}/monitors/${assignmentId}"
                        $jsonBody = $body | ConvertTo-Json -Depth 10

                        try {
                            $response = Get-WUGAPIResponse -Uri $uri -Method PUT -Body $jsonBody
                            Write-Verbose "Assignment updated for device ID: ${deviceId}, assignment ID: ${assignmentId}."
                        }
                        catch {
                            Write-Error "Failed to update assignment for device ID: ${deviceId}, assignment ID: ${assignmentId}: $_"
                        }
                    }
                }
            }
            elseif ($DeviceId) {
                # Assign new monitor to device(s) (no AssignmentId means this is a create, not update)
                foreach ($deviceId in $DeviceId) {
                    $body = @{}
                    $body.type = "active"
                    if ($MonitorTypeId)   { $body.monitorTypeId = $MonitorTypeId }
                    if ($MonitorTypeName) { $body.monitorTypeName = $MonitorTypeName }
                    if ($PSBoundParameters.ContainsKey('Enabled')) { $body.enabled = [System.Convert]::ToBoolean($Enabled) }
                    if ($Description)    { $body.description = $Description }

                    $active = @{}
                    if ($PollingIntervalSeconds) { $active.pollingIntervalSeconds = $PollingIntervalSeconds }
                    if ($CriticalOrder)         { $active.criticalOrder = $CriticalOrder }
                    if ($ActionPolicyId)        { $active.actionPolicyId = $ActionPolicyId }
                    if ($ActionPolicyName)      { $active.actionPolicyName = $ActionPolicyName }
                    if ($active.Count -gt 0)    { $body.active = $active }

                    $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${deviceId}/monitors"
                    $jsonBody = $body | ConvertTo-Json -Depth 10

                    try {
                        $response = Get-WUGAPIResponse -Uri $uri -Method POST -Body $jsonBody
                        Write-Verbose "Monitor assigned/updated successfully for device ID: ${deviceId}."
                    }
                    catch {
                        Write-Error "Failed to assign/update monitor for device ID: ${deviceId}: $_"
                    }
                }
            }
            else {
                Write-Error "For device-level operations, you must provide -DeviceId. To update/disable a specific assignment, provide both -DeviceId and -AssignmentId."
            }
        }
        else {
            Write-Error "Invalid -Mode. Use 'Library' or 'Device'."
        }
    }
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDh27oUK6+H19wl
# NvsnrQk2sM/fMRfhWljcoStS9GVijKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg7vB/4Dc11BQFi2orbPwWuwhvt+y2xFrD
# ypjGXgtRND4wDQYJKoZIhvcNAQEBBQAEggIAjNOnbAokmgiUvuOoGw6rHqJfmJLh
# r22aWpxdo3vsOtVQ8kiiAaS1X9Rww0iKpp2+nwK+wpzJcMflWKp4ynYK4/1FdfcW
# hhA07zH492hlnzBBK1nBvwn9LtXVAZ63TeQCEkBjZfwo5fQ0k1NUCrUROTNjyS1y
# shluM2tdWh6WWwk36Y2ekqKuw1NGGwNA1JyghcyRqOWj2AFozRXqrQw22TEqYni/
# tubHbFLfXFXz3QR7DfrSrbFbTXvhKoQq5+PJedFMjLT+7djIa6eZ5boE3VewzT5h
# bwh+bGu2ft524koHWER4XgwVYvIGbrpSPp4dwwvEDwpGC3rUg1/JI71LaluVumQP
# 78C6jRrcge/tTEoZhyVLUx1rolZUm7VKkMYdqZeIOYUbVhUUbQ2E8i2g71bKGoJE
# JF2NYqF+oUgBYzuHva+EQUkdtBdSoBQj8RVYg3DSGMztRcUuraAcHMZKlIW9IUr7
# Lp6egLUtFItdKGPTgKhG7ec4cbZ0DE87JKo3LbsfgaapyZeAGx41WnX0VRHqF7zg
# AXwJqy9ZckDh2khTDkvCHPbn9OPCfckoRE3kRHZcFpXV07lzgqLpKSX54c3JK+dh
# RHU9qMGyww/qFrOyWc7dCjC8GocwqAiz9fIX1scSD2LGS7YBZ+FTAWbeX9Qf0cLu
# Nl8g1TszCU219IE=
# SIG # End signature block
