<#
.SYNOPSIS
    Fortinet FortiGate discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers a Fortinet discovery provider that queries FortiOS REST API
    to discover system status, resources, interfaces, VPN tunnels, and
    SD-WAN health, then builds a monitor plan.
    Works standalone or with WUG integration.

    Active Monitors (up/down):
      - System status via /api/v2/monitor/system/status
      - HA peer health via /api/v2/monitor/system/ha-peer
      - License validity via /api/v2/monitor/license/status
      - VPN tunnel status via /api/v2/monitor/vpn/ipsec

    Performance Monitors (stats over time):
      - CPU utilization via /api/v2/monitor/system/resource/usage
      - Memory utilization via resource/usage
      - Active session count via resource/usage
      - Session setup rate via resource/usage
      - Disk utilization via resource/usage

    Authentication:
      FortiGate uses API tokens (bearer tokens). The token is stored
      securely in the DPAPI vault for live discovery and in the WUG
      credential store for ongoing monitoring. Monitor definitions use
      the WUG context variable %Credential.Password% so the plaintext
      token is never embedded in monitor configurations.

    Prerequisites:
      1. FortiGate device exists in WUG (or will be created)
      2. FortiGate admin with REST API token generated
      3. Device attribute 'DiscoveryHelper.Fortinet' = 'true'
      4. REST API credential assigned to device (token as password)

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM

    FortiGate API Token Security:
    - The API token is stored in the DPAPI vault (encrypted) for discovery.
    - In WUG, the token is stored in the WUG credential store (not in
      device attributes or monitor params). Monitor definitions reference
      it via %Credential.Password% — the plaintext token is never exposed.
    - The token should be scoped to read-only API access on the FortiGate.
#>

# Ensure DiscoveryHelpers is available
if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $discoveryPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'DiscoveryHelpers.ps1'
    if (Test-Path $discoveryPath) {
        . $discoveryPath
    }
    else {
        throw "DiscoveryHelpers.ps1 not found. Load it before this provider."
    }
}

# ============================================================================
# Fortinet Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Fortinet' `
    -MatchAttribute 'DiscoveryHelper.Fortinet' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $baseUri = $ctx.BaseUri
        $deviceId = $ctx.DeviceId
        $deviceName = $ctx.DeviceName
        $ignoreCert = if ($ctx.IgnoreCertErrors) { '1' } else { '0' }
        $attrValue = $ctx.AttributeValue

        # ================================================================
        # Auth: resolve token for live API calls (in-memory only)
        # ================================================================
        # Token is from $ctx.Credential.ApiToken (preferred) or legacy
        # $ctx.AttributeValue (backward compat). Never stored in monitors.
        $tokenValue = $null
        if ($ctx.Credential -and $ctx.Credential.ApiToken) {
            $tokenValue = $ctx.Credential.ApiToken
        }
        elseif ($attrValue -and $attrValue -ne 'true' -and $attrValue.Length -gt 10) {
            $tokenValue = $attrValue
        }

        # ================================================================
        # WUG Monitor Auth: use credential variable reference
        # ================================================================
        # Monitor definitions use %Credential.Password% so WUG resolves
        # the token from the credential store at poll time. The plaintext
        # token is NEVER embedded in monitor params.
        $credPwdVar    = '%Credential.Password%'
        $tplAuthHeader = "Authorization:Bearer ${credPwdVar}"
        $useAnonymous  = '1'  # Auth via custom header, not basic auth

        # ================================================================
        # 1. ACTIVE MONITOR — System Status (overall health check)
        # ================================================================
        $statusUrl = "${baseUri}/api/v2/monitor/system/status"

        $items += New-DiscoveredItem `
            -Name "FortiGate System Status [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $statusUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = $useAnonymous
                RestApiCustomHeader         = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "Fortinet:${deviceId}:active:sysstatus" `
            -DeviceId $deviceId `
            -Attributes @{
                'Fortinet.MonitorType' = 'System Status'
                'DiscoveryHelper.Fortinet.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
            } `
            -Tags @('fortinet', 'active', 'system')

        # ================================================================
        # 2. ACTIVE MONITOR — License Status
        # ================================================================
        $licenseUrl = "${baseUri}/api/v2/monitor/license/status"

        $items += New-DiscoveredItem `
            -Name "FortiGate License Status [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $licenseUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = $useAnonymous
                RestApiCustomHeader         = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "Fortinet:${deviceId}:active:license" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'active', 'license')

        # ================================================================
        # 3. ACTIVE MONITOR — HA Peer Health
        # ================================================================
        $haUrl = "${baseUri}/api/v2/monitor/system/ha-peer"

        $items += New-DiscoveredItem `
            -Name "FortiGate HA Health [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $haUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = $useAnonymous
                RestApiCustomHeader         = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "Fortinet:${deviceId}:active:ha" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'active', 'ha')

        # ================================================================
        # 4. ACTIVE MONITOR — VPN Tunnel Status
        # ================================================================
        $vpnUrl = "${baseUri}/api/v2/monitor/vpn/ipsec"

        $items += New-DiscoveredItem `
            -Name "FortiGate VPN Tunnels [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $vpnUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = $useAnonymous
                RestApiCustomHeader         = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "Fortinet:${deviceId}:active:vpn" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'active', 'vpn')

        # ================================================================
        # 5. PERFORMANCE MONITOR — CPU Utilization
        # ================================================================
        $resourceUrl = "${baseUri}/api/v2/monitor/system/resource/usage?interval=1-min"

        $items += New-DiscoveredItem `
            -Name "FortiGate CPU [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $resourceUrl
                RestApiJsonPath           = '$.results.cpu[0].current'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = $useAnonymous
                RestApiCustomHeader       = $tplAuthHeader
            } `
            -UniqueKey "Fortinet:${deviceId}:perf:cpu" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'performance', 'cpu')

        # ================================================================
        # 6. PERFORMANCE MONITOR — Memory Utilization
        # ================================================================
        $items += New-DiscoveredItem `
            -Name "FortiGate Memory [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $resourceUrl
                RestApiJsonPath           = '$.results.mem[0].current'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = $useAnonymous
                RestApiCustomHeader       = $tplAuthHeader
            } `
            -UniqueKey "Fortinet:${deviceId}:perf:memory" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'performance', 'memory')

        # ================================================================
        # 7. PERFORMANCE MONITOR — Active Sessions
        # ================================================================
        $items += New-DiscoveredItem `
            -Name "FortiGate Sessions [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $resourceUrl
                RestApiJsonPath           = '$.results.session[0].current'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = $useAnonymous
                RestApiCustomHeader       = $tplAuthHeader
            } `
            -UniqueKey "Fortinet:${deviceId}:perf:sessions" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'performance', 'sessions')

        # ================================================================
        # 8. PERFORMANCE MONITOR — Session Setup Rate
        # ================================================================
        $items += New-DiscoveredItem `
            -Name "FortiGate Setup Rate [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $resourceUrl
                RestApiJsonPath           = '$.results.setuprate[0].current'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = $useAnonymous
                RestApiCustomHeader       = $tplAuthHeader
            } `
            -UniqueKey "Fortinet:${deviceId}:perf:setuprate" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'performance', 'setuprate')

        # ================================================================
        # 9. PERFORMANCE MONITOR — Disk Utilization
        # ================================================================
        $items += New-DiscoveredItem `
            -Name "FortiGate Disk [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $resourceUrl
                RestApiJsonPath           = '$.results.disk[0].current'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = $useAnonymous
                RestApiCustomHeader       = $tplAuthHeader
            } `
            -UniqueKey "Fortinet:${deviceId}:perf:disk" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'performance', 'disk')

        # ================================================================
        # 10. ACTIVE MONITOR — SD-WAN Health Checks
        # ================================================================
        $sdwanUrl = "${baseUri}/api/v2/monitor/virtual-wan/health-check"

        $items += New-DiscoveredItem `
            -Name "FortiGate SD-WAN Health [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $sdwanUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = $useAnonymous
                RestApiCustomHeader         = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "Fortinet:${deviceId}:active:sdwan" `
            -DeviceId $deviceId `
            -Tags @('fortinet', 'active', 'sdwan')

        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+UeSRlGkcvq8e
# ktekqwWwMLa93BxdB/ocXoVtKFPcoaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgeWP+cDl4gxBuWt2+5aVCQJ9UlBnEZdpp
# P6Yy4D/a8QMwDQYJKoZIhvcNAQEBBQAEggIAWzbGFaMN9sM+8G9PHGgZV8XLZoD5
# BfkCkrZV1AT/e+JX3pqnDMiq6aQ3nM0i9kcXN075EjINJn53OLlrBOZHB8ftcMrB
# 7iGM7YlMsOMh/IwLrYMw4/pPnyKYMfKQWKpTVJBDftcIqrqhdD0cYWTply916adV
# hFa68CpZQ8s5BFZcuI770kGof8tgiMw67/y/duciJu2NvCI7I1xb8uszTBOxc4bX
# egfsmbxaLixqcXT1ozZE8Tr0sFH9blBg4hW8tqy07P7Qcq2avZro9z0yJV2bGIGS
# fWnc3dNIqpU22ufyGMIRXEf+Dur959Lj31pOVT5q2cAcBuH/wMLkfIFK/8HStR2v
# ny/VR6K2pkQOBo38Npo0/acvscg/r1+gLiMVvz+oxWUGDFq8yTXqZtgSB38Hd9w7
# 4Eux+dDkexkGe7QnVnl2WHgNr4V3WF82B+C8YuS01XLmBDL3nEMXuThya31HVioP
# rMQp8TJRLiMw3EdJxoHlSjzGOh5VufdavoIaR4ALF1XG0m2xJcqCkjsgwqFC1JTk
# 80UJcwWX+K5uForiXAwI0nOFSum+91tcdLKq+tIzi5vP/yaAf1UuKX6ho2YPV6+q
# IYl+QGbsI7WS8mtLKem4wYuvKbe0aoDi+y37puH9PpODyJOM1VS9hywN7zPnijA7
# Wwg/za+IQER2FBU=
# SIG # End signature block
