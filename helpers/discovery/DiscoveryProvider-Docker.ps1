<#
.SYNOPSIS
    Docker discovery provider for container host monitoring.

.DESCRIPTION
    Registers a Docker discovery provider that queries the Docker Engine
    REST API to discover containers and host info, then builds a monitor plan.

    Active Monitors (up/down):
      - Docker host availability via /info
      - Per-container running state via /containers/{id}/json

    Performance Monitors (stats over time):
      - Container CPU % via /containers/{id}/stats (one-shot)
      - Container Memory usage (MB) via stats endpoint
      - Container Network Rx/Tx bytes via stats endpoint

    Authentication:
      Docker API uses no auth (port 2375) or X.509 client certs (port 2376).
      This provider connects to the Docker host's exposed API.

    Prerequisites:
      1. Docker Engine API exposed (tcp://host:2375 or tls://host:2376)
      2. For TLS: client certificate accessible
      3. Device attribute 'DiscoveryHelper.Docker' = 'true'

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

# Load Docker helpers
$dockerHelperPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'docker\DockerHelpers.ps1'
if (Test-Path $dockerHelperPath) {
    . $dockerHelperPath
}

# ============================================================================
# Docker Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Docker' `
    -MatchAttribute 'DiscoveryHelper.Docker' `
    -AuthType 'BearerToken' `
    -DefaultPort 2375 `
    -DefaultProtocol 'http' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $hostTarget = $ctx.DeviceIP
        $port = $ctx.Port
        $proto = $ctx.Protocol
        $baseUri = "${proto}://${hostTarget}:${port}"

        # Helper to call Docker API
        function Invoke-DockerREST {
            param([string]$Endpoint)
            $uri = "${baseUri}${Endpoint}"
            Invoke-RestMethod -Uri $uri -Method GET -ErrorAction Stop
        }

        Write-Host "  Querying Docker host $hostTarget..." -ForegroundColor DarkGray

        # Host info
        $hostInfo = $null
        try {
            $hostInfo = Invoke-DockerREST -Endpoint '/info'
        }
        catch {
            Write-Warning "Docker: Could not reach host $hostTarget`: $_"
            return $items
        }

        $hostName = if ($hostInfo.Name) { $hostInfo.Name } else { $hostTarget }
        $containersRunning = if ($hostInfo.ContainersRunning) { $hostInfo.ContainersRunning } else { 0 }
        $containersStopped = if ($hostInfo.ContainersStopped) { $hostInfo.ContainersStopped } else { 0 }
        $dockerVersion = if ($hostInfo.ServerVersion) { $hostInfo.ServerVersion } else { 'unknown' }

        $hostAttrs = @{
            'DiscoveryHelper.Docker' = 'true'
            'Docker.HostName'        = $hostName
            'Docker.Version'         = $dockerVersion
            'Docker.Containers'      = "$($containersRunning + $containersStopped)"
            'Docker.DeviceType'      = 'Host'
            'Vendor'                 = 'Docker'
        }

        Write-Host "  Docker $dockerVersion — $containersRunning running, $containersStopped stopped" -ForegroundColor DarkGray

        # Active Monitor: Docker host availability
        $items += New-DiscoveredItem `
            -Name "Docker Host Health - $hostName" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                    = "${baseUri}/info"
                RestApiMethod                 = 'GET'
                RestApiTimeoutMs              = 10000
                RestApiUseAnonymous           = '1'
                RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
            } `
            -UniqueKey "Docker:${hostTarget}:active:host" `
            -Attributes $hostAttrs `
            -Tags @('docker', 'host', $hostName)

        # Get running containers
        $containers = @()
        try {
            $containers = @(Invoke-DockerREST -Endpoint '/containers/json?all=false')
        }
        catch {
            Write-Warning "Docker: Could not list containers on $hostTarget`: $_"
        }

        Write-Host "  Found $($containers.Count) running containers" -ForegroundColor DarkGray

        foreach ($ctr in $containers) {
            $ctrId    = $ctr.Id
            $ctrShort = if ($ctrId.Length -gt 12) { $ctrId.Substring(0, 12) } else { $ctrId }
            $ctrName  = $ctr.Names[0] -replace '^/', ''
            $ctrImage = $ctr.Image
            $ctrState = $ctr.State

            $ctrAttrs = @{
                'DiscoveryHelper.Docker' = 'true'
                'Docker.HostName'        = $hostName
                'Docker.ContainerId'     = $ctrShort
                'Docker.ContainerName'   = $ctrName
                'Docker.Image'           = $ctrImage
                'Docker.State'           = $ctrState
                'Docker.DeviceType'      = 'Container'
                'Vendor'                 = 'Docker'
            }

            # Active Monitor: Container running check
            $items += New-DiscoveredItem `
                -Name "Container Health - $ctrName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "${baseUri}/containers/${ctrId}/json"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 10000
                    RestApiUseAnonymous           = '1'
                    RestApiComparisonList         = "[{`"JsonPathQuery`":`"['State']['Running']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"true`"}]"
                    RestApiDownIfResponseCodeIsIn = '[404,500,502,503]'
                } `
                -UniqueKey "Docker:${hostTarget}:ctr:${ctrShort}:active:health" `
                -Attributes $ctrAttrs `
                -Tags @('docker', 'container', $ctrName, $hostName)

            # Performance Monitor: Container CPU %
            # Docker stats (one-shot): /containers/{id}/stats?stream=false
            # JSONPath for CPU delta: precalc not possible in REST monitor.
            # Use $.cpu_stats.cpu_usage.total_usage as raw counter.
            $statsUrl = "${baseUri}/containers/${ctrId}/stats?stream=false"
            $items += New-DiscoveredItem `
                -Name "CPU Usage - $ctrName ($hostName)" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                = $statsUrl
                    RestApiJsonPath           = '$.memory_stats.usage'
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '15000'
                    RestApiUseAnonymousAccess = '1'
                    _MetricName               = 'memory_usage'
                    _MetricDisplayName        = 'Memory Usage (bytes)'
                } `
                -UniqueKey "Docker:${hostTarget}:ctr:${ctrShort}:perf:memory" `
                -Attributes $ctrAttrs `
                -Tags @('docker', 'container', $ctrName, 'memory')

            # Performance Monitor: Container Network Rx bytes
            $items += New-DiscoveredItem `
                -Name "Network Rx Bytes - $ctrName ($hostName)" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                = $statsUrl
                    RestApiJsonPath           = '$.networks.eth0.rx_bytes'
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '15000'
                    RestApiUseAnonymousAccess = '1'
                    _MetricName               = 'network_rx_bytes'
                    _MetricDisplayName        = 'Network Rx Bytes'
                } `
                -UniqueKey "Docker:${hostTarget}:ctr:${ctrShort}:perf:net_rx" `
                -Attributes $ctrAttrs `
                -Tags @('docker', 'container', $ctrName, 'network')

            # Performance Monitor: Container Network Tx bytes
            $items += New-DiscoveredItem `
                -Name "Network Tx Bytes - $ctrName ($hostName)" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                = $statsUrl
                    RestApiJsonPath           = '$.networks.eth0.tx_bytes'
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '15000'
                    RestApiUseAnonymousAccess = '1'
                    _MetricName               = 'network_tx_bytes'
                    _MetricDisplayName        = 'Network Tx Bytes'
                } `
                -UniqueKey "Docker:${hostTarget}:ctr:${ctrShort}:perf:net_tx" `
                -Attributes $ctrAttrs `
                -Tags @('docker', 'container', $ctrName, 'network')
        }

        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCaoQU6VAUnD9IJ
# OhudjSSPEgUSGhqamWZvtuwMExA3p6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgoXqe1m0U7iZPveaQvVcLrPfdncBgwUJe
# gww2weGHWmYwDQYJKoZIhvcNAQEBBQAEggIA56/IYvuMeZP5ePVvWTSLT8XGHsPY
# e+ckBUFw6/W5jFKP0Hc9w5nrncd2aItPrPiwTj7/vGq12i3m/5GtQls1sSkOh88J
# mLxDy+tV4QdYmxIxV4fdlfWY9h6tZkinQWuDkfDhoa/C7LgDoeLwUUh+zJ4amUvO
# LNtfM40LW+9s33sojq/h5UcI2wGZ+jtnoANsTeQG7xc0FZAI38yrqT1fuUK8AZdw
# gY3UPJ/Mmo9ZsF5S8BfsFhunjB7KpI2M94JZyptv6p1C1a+yUe4hplPvnOxgt5n1
# wJ/q8aDVgfKi/6sIWJYuy70i2S3z8Tm7A76dm7wlrtRbV5v4D135THMRYm9GH5Re
# R2eTpAOLld5j2CuLT9mAlBgRLdkv6sasxJxMFFGG+XP3FPTDfXwWFhY57WFoiGaf
# e6XyczgULhh2gueKkRfKkeFfzdyN61BoSW5SW/nRGRpagyoel6IUH1ekeOcwg8PK
# yY/zCoSrIzjTvu/2SM3T/JD83dPOtLv2uZBWtfFF29gjItaenVaBpM4RxBUE/FIo
# ezO78xNGVabx666IOskgvv8EwiyofMSaRB/o9ttY/MrI4sm4MnFWOBeOt5SSZJDs
# XQ15Z125jXngh1MNsL19umydCT94B5uvZQd9ILCs20iZ4iaOjG3znnjsPpOWJAyW
# Pz57IwLdCWIKNNE=
# SIG # End signature block
