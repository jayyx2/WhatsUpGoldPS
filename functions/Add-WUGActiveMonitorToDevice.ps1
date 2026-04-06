<#
.SYNOPSIS
    Assigns an active monitor to one or more devices in WhatsUp Gold.

.DESCRIPTION
    Add-WUGActiveMonitorToDevice assigns a specified active monitor template to one or
    more devices via the WhatsUp Gold REST API (POST /api/v1/devices/{deviceId}/monitors/-).
    When multiple DeviceIds or MonitorIds are supplied, the function loops through each
    combination, issuing one POST per pair. Optional parameters control polling interval,
    comment, argument, interface binding, critical order, and action policy.

.PARAMETER DeviceId
    One or more device IDs to assign the monitor to. Required. Accepts pipeline input.

.PARAMETER MonitorId
    One or more monitor template IDs (monitorTypeId) to assign. Required.

.PARAMETER Enabled
    Whether the monitor should be enabled. Valid values: true, false. Default: true.

.PARAMETER Comment
    An optional comment for the monitor assignment.

.PARAMETER Argument
    An optional argument string passed to the monitor.

.PARAMETER InterfaceId
    The interface ID to bind the monitor to, if applicable.

.PARAMETER PollingIntervalSeconds
    The polling interval in seconds (10-86400).

.PARAMETER CriticalOrder
    The critical order ranking (1-100).

.PARAMETER ActionPolicyId
    The ID of the action policy to associate with this monitor.

.PARAMETER ActionPolicyName
    The name of the action policy to associate with this monitor.

.EXAMPLE
    Add-WUGActiveMonitorToDevice -DeviceId 42 -MonitorId 5

    Assigns active monitor template 5 to device 42 with default settings.

.EXAMPLE
    Add-WUGActiveMonitorToDevice -DeviceId 42 -MonitorId 5 -PollingIntervalSeconds 60 -Comment "HTTP check"

    Assigns active monitor 5 to device 42 with a 60-second polling interval and a comment.

.EXAMPLE
    Add-WUGActiveMonitorToDevice -DeviceId @(100,101,102) -MonitorId 12 -Enabled false -ActionPolicyName "Email Admins"

    Assigns monitor 12 to devices 100, 101, and 102 in a disabled state.

.EXAMPLE
    @(100,101,102) | Add-WUGActiveMonitorToDevice -MonitorId 5

    Pipes three device IDs and assigns monitor 5 to each.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Reference: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/#tag/Device-Monitors

    The WUG REST API has no bulk endpoint for assigning a monitor to multiple devices.
    This function iterates each DeviceId x MonitorId combination, one POST per pair.
#>
function Add-WUGActiveMonitorToDevice {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int[]]$DeviceId,
        [Parameter(Position = 1, Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [int[]]$MonitorId,
        [ValidateSet("true", "false")][string]$Enabled = "true",
        [string]$Comment,
        [string]$Argument,
        [string]$InterfaceId,
        [ValidateRange(10, 86400)][int]$PollingIntervalSeconds,
        [ValidateRange(1, 100)][int]$CriticalOrder,
        [string]$ActionPolicyId,
        [string]$ActionPolicyName
    )

    begin {
        Write-Debug "Initializing Add-WUGActiveMonitorToDevice function."
        Write-Debug "DeviceId: $DeviceId"
        Write-Debug "MonitorId: $MonitorId"
        Write-Debug "Enabled: $Enabled"
        Write-Debug "Comment: $Comment"
        Write-Debug "Argument: $Argument"
        Write-Debug "InterfaceId: $InterfaceId"
        Write-Debug "PollingIntervalSeconds: $PollingIntervalSeconds"
        Write-Debug "CriticalOrder: $CriticalOrder"
        Write-Debug "ActionPolicyId: $ActionPolicyId"
        Write-Debug "ActionPolicyName: $ActionPolicyName"

        # Build the active params sub-object once - identical for every device/monitor pair
        $activeParams = @{}
        if ($Comment) {$activeParams.comment = $Comment}
        if ($Argument) {$activeParams.argument = $Argument}
        if ($InterfaceId) {$activeParams.interfaceId = $InterfaceId}
        if ($PSBoundParameters.ContainsKey('PollingIntervalSeconds')) {$activeParams.pollingIntervalSeconds = $PollingIntervalSeconds}
        if ($PSBoundParameters.ContainsKey('CriticalOrder')) {$activeParams.criticalOrder = $CriticalOrder}
        if ($ActionPolicyId) {$activeParams.actionPolicyId = $ActionPolicyId}
        if ($ActionPolicyName) {$activeParams.actionPolicyName = $ActionPolicyName}
    }

    process {
        $totalDevices = $DeviceId.Count
        $currentDeviceIndex = 0

        foreach ($dId in $DeviceId) {
            $currentDeviceIndex++

            foreach ($mId in $MonitorId) {
                $percentComplete = [Math]::Round(($currentDeviceIndex / $totalDevices) * 100)
                Write-Progress -Activity "Assigning active monitor(s) to device(s)" -Status "Processing Device ID $dId ($currentDeviceIndex of $totalDevices)" -PercentComplete $percentComplete

                $uri  = "$($global:WhatsUpServerBaseURI)/api/v1/devices/${dId}/monitors/-"
                $body = @{
                    type          = "active"
                    monitorTypeId = $mId
                    enabled       = $Enabled
                    isGlobal      = "true"
                    active        = $activeParams
                } | ConvertTo-Json -Depth 5

                Write-Debug "Assigning monitor $mId to device $dId"
                Write-Debug "URI: $uri"
                Write-Debug "Body: $body"

                if (-not $PSCmdlet.ShouldProcess("Device $dId", "Assign active monitor $mId")) { continue }

                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method "POST" -Body $body

                    if ($result.data.successful -eq 1) {
                        Write-Output "Successfully assigned active monitor $mId to device $dId."
                        Write-Debug "Result from Get-WUGAPIResponse for Device ID ${dId}: $result"
                    }
                    else {
                        Write-Warning "Failed to assign active monitor $mId to device $dId."
                        Write-Debug "Result from Get-WUGAPIResponse for Device ID ${dId}: $result"
                    }
                }
                catch {
                    Write-Error "Error assigning monitor $mId to device ${dId}: $_"
                }
            }
        }
    }

    end {
        Write-Progress -Activity "Assigning active monitor(s) to device(s)" -Completed
        Write-Debug "Completed Add-WUGActiveMonitorToDevice function."
    }
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA6Y8BXkVwDLtjn
# 3mtE6VQmehjyidi/Rrpu88XOxSOXY6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQga5M0bUPb8CZ+2HboThUcV4Dpj8rYNxB6
# U96ue0ilFdwwDQYJKoZIhvcNAQEBBQAEggIA4IKv3xpGR8R9IZ7Uacw2rj7chs/M
# l/lhMUUiklaXnbibuFKKfgz3lhI4YkXjLyavgHFYkAHWIGv0GVEnGtpWpxu6KHLj
# umzsEkAR3/ui2AideUMLIUccvQwyV/Ip7/aBo+NFXsifZssT4L8SB7IGWAzwJtxw
# asAz5acnnk+JqX5Ohf0OLJhTrNuMaTZR/54+Lgzat9VJe7TD6HTGyqiH3gbOLgFc
# F+JO8TwBoKvZ3hx6dA7TqZ7e2Z6I9OhkHcS7Uzm+B/qm9yONega+7JAeY5Ulr0SF
# 6L0Q3j0mXcIAUWa2uMLjsYyND4sbCpejKEtZ3IDRqJ82VO8Kb8ctbykLDNSUQ2Zc
# z8vC5xATOxeyeHOhOD+Trot6JaVKvgqZ3GalzlO5kNFZvXyfVsPjPhJhoZOpd6W0
# 9TqtYeNU3HVyLREiDtdhVm6qrSfypVkimNIr8267PsfqMi9NO9ReQIQHS6VIFRWR
# a0m6fshvE3hYEL3KAGqexGOGeBuOSXyD2XRnE7P5Lc1QPr7ey389eUMdBIhggOVC
# epwa35DJlqlZ72MwrgK4/n7zoCluS6gN3gl3CrCs6GP0WzGfYIVvP/SmIoOAupFK
# L5XRE2oGFgM8NgtIgzggEKTvt1GSC8ZZlBYofCHsvONh2wFBicByP+seHvYjQflo
# jjYM26rMmJVV2TE=
# SIG # End signature block
