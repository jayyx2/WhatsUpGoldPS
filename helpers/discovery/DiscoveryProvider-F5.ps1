<#
.SYNOPSIS
    F5 BIG-IP discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers an F5 discovery provider that queries iControl REST API
    to discover virtual servers, pools, and pool members, then builds
    a monitor plan. Works standalone or with WUG integration.

    Active Monitors (up/down):
      - Per-VS availability via /mgmt/tm/ltm/virtual/~<partition>~<vs>/stats
      - Pool member reachability via TcpIp monitors (native WUG type)

    Performance Monitors (stats over time):
      - VS current connections via REST API (JSONPath to extract numeric)
      - VS throughput (bits in/out) via REST API
      - System CPU/memory if discovered

    Prerequisites:
      1. F5 device exists in WUG
      2. REST API credential created + assigned: basic auth with F5 admin user
      3. Device attribute 'DiscoveryHelper.F5' = 'true'

    The F5 iControl REST API uses:
      - Basic auth (Authorization: Basic base64) or token auth
      - Base URL: https://<host>/mgmt/
      - VS stats: /mgmt/tm/ltm/virtual/stats
      - VS config: /mgmt/tm/ltm/virtual
      - Pool members: /mgmt/tm/ltm/pool/~<partition>~<pool>/members
      - System: /mgmt/tm/sys/global-settings, /mgmt/tm/sys/performance/all-stats

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM
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
# F5 Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'F5' `
    -MatchAttribute 'DiscoveryHelper.F5' `
    -AuthType 'BasicAuth' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)
        <#
            $ctx keys:
              DeviceId, DeviceName, DeviceIP, BaseUri, Port, Protocol,
              ProviderName, AttributeValue, ExistingMonitors, IgnoreCertErrors
        #>
        $items = @()
        $baseUri = $ctx.BaseUri
        $deviceId = $ctx.DeviceId
        $deviceName = $ctx.DeviceName
        $ignoreCert = if ($ctx.IgnoreCertErrors) { '1' } else { '0' }

        # --- Attributes to set on the device ---
        $deviceAttrs = @{}

        # ================================================================
        # 1. ACTIVE MONITORS — VS availability (REST API up/down)
        # ================================================================
        # Instead of polling the full /stats endpoint and parsing,
        # use HttpContent monitors to check the VS stats endpoint
        # and match on the availability state string.
        #
        # For each VS: GET /mgmt/tm/ltm/virtual/~<partition>~<vsName>/stats
        # Response contains: "status.availabilityState":{"description":"available"}
        # UP if response contains "available", DOWN otherwise.
        #
        # Alternative: REST API active monitor with ComparisonList for
        # HTTP status code checks (200 = VS exists and responds).

        # First, discover all virtual servers via the config endpoint
        $vsListUrl = "${baseUri}/mgmt/tm/ltm/virtual"

        $items += New-DiscoveredItem `
            -Name "F5 VS List [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $vsListUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = '0'
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "F5:${deviceId}:active:vslist" `
            -DeviceId $deviceId `
            -Attributes @{ 'F5.MonitorType' = 'VS List Health' } `
            -Tags @('f5', 'active', 'vslist')

        # ================================================================
        # 2. ACTIVE MONITORS — Per-VS availability via HttpContent
        # ================================================================
        # For individual VS monitoring, we create HttpContent monitors
        # that check the VS-specific stats endpoint for "available"
        #
        # URL: /mgmt/tm/ltm/virtual/~<partition>~<vsName>/stats
        # Content match: "available" in the response body
        # This gives per-VS up/down visibility natively in WUG.

        # Note: We build these from the AttributeValue which can contain
        # a comma-separated partition list, or we discover from the VS
        # list endpoint response.  For now, we use a known-partition
        # approach or rely on the full VS list endpoint.
        #
        # Since WUG REST API monitors can only check HTTP status codes
        # or response body, we use the VS list endpoint as the health
        # check and per-VS stats endpoints as individual monitors.

        # ================================================================
        # 3. PERFORMANCE MONITORS — VS connection stats
        # ================================================================
        # Track current connections per VS over time via REST API perf monitor
        # GET /mgmt/tm/ltm/virtual/stats returns JSON with connection metrics
        # JSONPath: $.entries.*.nestedStats.entries.clientside.curConns.value

        # Global VS stats endpoint — tracks overall load balancer health
        $vsStatsUrl = "${baseUri}/mgmt/tm/ltm/virtual/stats"

        # System-level perf monitor: total current connections across all VS
        $items += New-DiscoveredItem `
            -Name "F5 Total VS Connections [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $vsStatsUrl
                RestApiJsonPath           = '$.entries..nestedStats.entries.["clientside.curConns"].value'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = '0'
            } `
            -UniqueKey "F5:${deviceId}:perf:totalconns" `
            -DeviceId $deviceId `
            -Tags @('f5', 'performance', 'connections')

        # ================================================================
        # 4. PERFORMANCE MONITORS — System resources
        # ================================================================
        # CPU and memory utilization via /mgmt/tm/sys/performance/all-stats

        $sysPerfUrl = "${baseUri}/mgmt/tm/sys/performance/all-stats"

        $items += New-DiscoveredItem `
            -Name "F5 System CPU [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $sysPerfUrl
                RestApiJsonPath           = '$.entries.["https://localhost/mgmt/tm/sys/performance/all-stats/System CPU Usage"].nestedStats.entries.Current.description'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = '0'
            } `
            -UniqueKey "F5:${deviceId}:perf:syscpu" `
            -DeviceId $deviceId `
            -Attributes @{ 'F5.MonitorType' = 'System CPU' } `
            -Tags @('f5', 'performance', 'cpu')

        $items += New-DiscoveredItem `
            -Name "F5 System Memory [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $sysPerfUrl
                RestApiJsonPath           = '$.entries.["https://localhost/mgmt/tm/sys/performance/all-stats/Memory Used"].nestedStats.entries.Current.description'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = '0'
            } `
            -UniqueKey "F5:${deviceId}:perf:sysmem" `
            -DeviceId $deviceId `
            -Attributes @{ 'F5.MonitorType' = 'System Memory' } `
            -Tags @('f5', 'performance', 'memory')

        # ================================================================
        # 5. ACTIVE MONITORS — Pool member TcpIp reachability
        # ================================================================
        # For each pool member with an IP:Port, create a native TcpIp
        # active monitor. This is complementary to the F5 status —
        # it tells WUG if the real server is reachable regardless of
        # what the F5 thinks.

        # Note: For pool member discovery at the individual IP:Port level,
        # extend this provider to enumerate
        # /mgmt/tm/ltm/pool?expandSubcollections=true and emit TcpIp items
        # for each pool member's IP:Port. This provider creates top-level
        # active/perf monitors on the F5 device itself.

        # ================================================================
        # 6. DEVICE ATTRIBUTES — F5 metadata
        # ================================================================
        # Set useful attributes on the WUG device for dashboards/reports

        $deviceAttrs['DiscoveryHelper.F5.LastRun'] = (Get-Date).ToUniversalTime().ToString('o')

        # Add a system info health check
        $sysInfoUrl = "${baseUri}/mgmt/tm/sys/global-settings"

        $items += New-DiscoveredItem `
            -Name "F5 System Info [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $sysInfoUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = '0'
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "F5:${deviceId}:active:sysinfo" `
            -DeviceId $deviceId `
            -Attributes $deviceAttrs `
            -Tags @('f5', 'active', 'system')

        # ================================================================
        # 7. ACTIVE MONITORS — Pool health endpoint
        # ================================================================
        $poolStatsUrl = "${baseUri}/mgmt/tm/ltm/pool/stats"

        $items += New-DiscoveredItem `
            -Name "F5 Pool Health [$deviceName]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                  = $poolStatsUrl
                RestApiMethod               = 'GET'
                RestApiTimeoutMs            = 10000
                RestApiIgnoreCertErrors     = $ignoreCert
                RestApiUseAnonymous         = '0'
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList       = '[]'
            } `
            -UniqueKey "F5:${deviceId}:active:poolhealth" `
            -DeviceId $deviceId `
            -Tags @('f5', 'active', 'pool')

        # ================================================================
        # 8. PERFORMANCE MONITORS — Pool active member counts
        # ================================================================
        $items += New-DiscoveredItem `
            -Name "F5 Pool Active Members [$deviceName]" `
            -ItemType 'PerformanceMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                = $poolStatsUrl
                RestApiJsonPath           = '$.entries..nestedStats.entries.activeMemberCnt.value'
                RestApiHttpMethod         = 'GET'
                RestApiHttpTimeoutMs      = 10000
                RestApiIgnoreCertErrors   = $ignoreCert
                RestApiUseAnonymousAccess = '0'
            } `
            -UniqueKey "F5:${deviceId}:perf:poolmembers" `
            -DeviceId $deviceId `
            -Tags @('f5', 'performance', 'pool')

        return $items
    }

# ============================================================================
# F5 Discovery Dashboard Export
# ============================================================================
function Export-F5DiscoveryDashboardHtml {
    <#
    .SYNOPSIS
        Generates an F5 discovery dashboard HTML from plan data.
    .PARAMETER DashboardData
        Array of PSCustomObject rows (Device, IP, Monitor, Type, Status).
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title. Default: 'F5 BIG-IP Discovery Dashboard'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'F5 BIG-IP Discovery Dashboard'
    )

    # Prefer the dynamic dashboard generator (auto cards, search, export)
    $dynDashPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
    if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) {
        if (Test-Path $dynDashPath) { . $dynDashPath }
    }

    if (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
        Export-DynamicDashboardHtml -Data $DashboardData `
            -OutputPath $OutputPath `
            -ReportTitle $ReportTitle `
            -CardField 'Device','Type' `
            -StatusField 'Status'
    }
    elseif (Get-Command -Name 'Export-F5DashboardHtml' -ErrorAction SilentlyContinue) {
        # Fallback to the F5Helpers template-based dashboard
        Export-F5DashboardHtml -DashboardData $DashboardData `
            -OutputPath $OutputPath `
            -ReportTitle $ReportTitle
    }
    else {
        Write-Error "No dashboard generator available."
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA3VbrWXJ7k89QC
# HecJ1nl6jlHtdaRTVnNbCvKEfQHmFqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgE2ITZ+q8kRL/xgJviOvhkz9VOqeswQxD
# n5Ju1YEAp2kwDQYJKoZIhvcNAQEBBQAEggIAkT0lMII6rEMjTqGpO27S++E2wYoO
# HIDHJG1+JtPhDw8na45CzysgGIjqejSRUlTkRnM6ocfYVW4zWsN7NRkEfsmgHg4P
# 6+VmYMnUBijG0BK2AsYoEGGrkkRM6bQooToJFI81wypV+6Ep1NmhCH4kWcgBjVhZ
# ktg68vU5HIPTbGOwZSAz0r10v0reyJCwgGfkS/ZEqFYK+i7OeCynlNxIMutalYrT
# zepyAUQmijOx4QxbxCHijeTvQso/AKaTDtThtYjGOkjFq/yemwA3VYzjHQCBC9xO
# e2qJPTDuW+W++FNgDhNmmpJwB3UM6awJ9q6NWrw7UkB7dzOpRcHFCXGG5Wj8Mszz
# 9rmjZbI7pXnY36gQwU5l/AbckLY1fTEc6mUD4sDReNTCsSO7N8lnsOAcoJB5zi29
# 3DLfkVZKwf+C69HgKwb86u0TImb6NvshmhOrER1K4RNj4euF38dX70iK9ulrQEsV
# hsSTWlmUPcmnVJ3HE2KTLPA8QvzMcgFyr8AJDCOQ5YFcZljyuW9I98RLhFC7xPgW
# 2OlH/O1qPd6BbJsfi2xVbKHaFmO39iBBWvk6GjjxkrMZINk30i4XI4k8M46n42uj
# TSQO7xiu8N17roowFJ+jyE0G8C6k81f4V57Tum8uRYhQhML7WRutjFL/uWZcxFZN
# BVWEAZ1gG8YsezM=
# SIG # End signature block
