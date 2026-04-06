<#
.SYNOPSIS
    Nutanix discovery provider for hypervisor/cluster monitoring.

.DESCRIPTION
    Registers a Nutanix discovery provider that queries the Prism REST API
    v2.0 to discover clusters, hosts, and VMs, then builds a monitor plan.

    Active Monitors (up/down):
      - Cluster health via /api/nutanix/v2.0/cluster
      - Per-host power state via /api/nutanix/v2.0/hosts/{uuid}
      - Per-VM power state via /api/nutanix/v2.0/vms/{uuid}

    Performance Monitors (stats over time):
      - Host CPU %, memory % via host stats
      - VM CPU %, memory usage via VM stats

    Authentication:
      Nutanix Prism uses HTTP Basic Auth.
      Port 9440 (Prism Element or Prism Central).

    Prerequisites:
      1. Nutanix Prism Element or Central accessible
      2. Username + password with viewer/admin role
      3. Device attribute 'DiscoveryHelper.Nutanix' = 'true'

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

# Load Nutanix helpers
$nutanixHelperPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'nutanix\NutanixHelpers.ps1'
if (Test-Path $nutanixHelperPath) {
    . $nutanixHelperPath
}

# ============================================================================
# Nutanix Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Nutanix' `
    -MatchAttribute 'DiscoveryHelper.Nutanix' `
    -AuthType 'BasicAuth' `
    -DefaultPort 9440 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $hostTarget = $ctx.DeviceIP
        $port = $ctx.Port
        $baseUri = "https://${hostTarget}:${port}"
        $apiBase = "${baseUri}/api/nutanix/v2.0"

        # Ensure TLS 1.2
        if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }

        # SSL bypass for PS 5.1
        if ($ctx.IgnoreCertErrors -and $PSVersionTable.PSEdition -ne 'Core') {
            if (-not ([System.Management.Automation.PSTypeName]'SSLValidator').Type) {
                Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SSLValidator {
    private static bool OnValidateCertificate(
        object sender, X509Certificate certificate,
        X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
    public static void OverrideValidation() {
        ServicePointManager.ServerCertificateValidationCallback =
            new RemoteCertificateValidationCallback(OnValidateCertificate);
        ServicePointManager.Expect100Continue = false;
    }
}
"@
            }
            [SSLValidator]::OverrideValidation()
        }

        # Build auth header
        $cred = $ctx.Credential
        if (-not $cred) {
            Write-Warning "Nutanix: No credentials provided."
            return $items
        }

        $username = $null
        $password = $null
        if ($cred.PSCredential) {
            $username = $cred.PSCredential.UserName
            $password = $cred.PSCredential.GetNetworkCredential().Password
        }
        elseif ($cred.Username) {
            $username = $cred.Username
            $password = $cred.Password
        }
        if (-not $username) {
            Write-Warning "Nutanix: Could not extract credentials."
            return $items
        }

        $pair = "${username}:${password}"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
        $b64 = [System.Convert]::ToBase64String($bytes)
        $authHeaders = @{
            Authorization  = "Basic $b64"
            'Content-Type' = 'application/json'
        }

        # Helper to query Nutanix
        function Invoke-NutanixREST {
            param([string]$Endpoint)
            $uri = "${apiBase}${Endpoint}"
            Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET -ErrorAction Stop
        }

        Write-Host "  Querying Nutanix cluster at $hostTarget..." -ForegroundColor DarkGray

        # --- Cluster info ---
        $cluster = $null
        try {
            $cluster = Invoke-NutanixREST -Endpoint '/cluster'
        }
        catch {
            Write-Warning "Nutanix: Could not reach cluster at $hostTarget`: $_"
            return $items
        }

        $clusterName = if ($cluster.name) { $cluster.name } else { $hostTarget }
        $clusterUuid = if ($cluster.uuid) { $cluster.uuid } else { '' }

        $clusterAttrs = @{
            'DiscoveryHelper.Nutanix' = 'true'
            'Nutanix.ClusterName'     = $clusterName
            'Nutanix.ClusterUuid'     = $clusterUuid
            'Nutanix.DeviceType'      = 'Cluster'
            'Vendor'                  = 'Nutanix'
        }

        # Active Monitor: Cluster health
        $items += New-DiscoveredItem `
            -Name "Nutanix Cluster Health - $clusterName" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                    = "${apiBase}/cluster"
                RestApiMethod                 = 'GET'
                RestApiTimeoutMs              = 15000
                RestApiUseAnonymous           = '0'
                RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
            } `
            -UniqueKey "Nutanix:${clusterUuid}:active:cluster" `
            -Attributes $clusterAttrs `
            -Tags @('nutanix', 'cluster', $clusterName)

        # --- Hosts ---
        Write-Host "  Querying hosts..." -ForegroundColor DarkGray
        $hosts = @()
        try {
            $hostsResp = Invoke-NutanixREST -Endpoint '/hosts'
            if ($hostsResp.entities) { $hosts = @($hostsResp.entities) }
        }
        catch {
            Write-Warning "Nutanix: Could not list hosts: $_"
        }

        Write-Host "  Found $($hosts.Count) hosts" -ForegroundColor DarkGray

        foreach ($h in $hosts) {
            $hUuid = $h.uuid
            $hName = if ($h.name) { $h.name } else { "Host-$hUuid" }
            $hIp   = $null
            if ($h.hypervisor_address) { $hIp = $h.hypervisor_address }
            elseif ($h.service_vmexternal_ip) { $hIp = $h.service_vmexternal_ip }

            $hostAttrs = @{
                'DiscoveryHelper.Nutanix' = 'true'
                'Nutanix.ClusterName'     = $clusterName
                'Nutanix.HostUuid'        = $hUuid
                'Nutanix.HostName'        = $hName
                'Nutanix.DeviceType'      = 'Host'
                'Vendor'                  = 'Nutanix'
            }
            if ($hIp) { $hostAttrs['Nutanix.IPAddress'] = $hIp }

            # Active Monitor: Host availability
            $items += New-DiscoveredItem `
                -Name "Nutanix Host Health - $hName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "${apiBase}/hosts/${hUuid}"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "Nutanix:${clusterUuid}:host:${hUuid}:active:health" `
                -Attributes $hostAttrs `
                -Tags @('nutanix', 'host', $hName)

            # Perf Monitor: Host CPU usage
            $items += New-DiscoveredItem `
                -Name "CPU Usage % - $hName (nutanix)" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                = "${apiBase}/hosts/${hUuid}"
                    RestApiJsonPath           = '$.stats.hypervisor_cpu_usage_ppm'
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '15000'
                    RestApiUseAnonymousAccess = '0'
                    _MetricName               = 'cpu_usage_ppm'
                    _MetricDisplayName        = 'CPU Usage (ppm)'
                } `
                -UniqueKey "Nutanix:${clusterUuid}:host:${hUuid}:perf:cpu" `
                -Attributes $hostAttrs `
                -Tags @('nutanix', 'host', $hName, 'cpu')

            # Perf Monitor: Host Memory usage
            $items += New-DiscoveredItem `
                -Name "Memory Usage % - $hName (nutanix)" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                = "${apiBase}/hosts/${hUuid}"
                    RestApiJsonPath           = '$.stats.hypervisor_memory_usage_ppm'
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '15000'
                    RestApiUseAnonymousAccess = '0'
                    _MetricName               = 'memory_usage_ppm'
                    _MetricDisplayName        = 'Memory Usage (ppm)'
                } `
                -UniqueKey "Nutanix:${clusterUuid}:host:${hUuid}:perf:memory" `
                -Attributes $hostAttrs `
                -Tags @('nutanix', 'host', $hName, 'memory')
        }

        # --- VMs ---
        Write-Host "  Querying VMs..." -ForegroundColor DarkGray
        $vms = @()
        try {
            $vmsResp = Invoke-NutanixREST -Endpoint '/vms?include_vm_nic_config=true'
            if ($vmsResp.entities) { $vms = @($vmsResp.entities) }
        }
        catch {
            Write-Warning "Nutanix: Could not list VMs: $_"
        }

        Write-Host "  Found $($vms.Count) VMs" -ForegroundColor DarkGray

        foreach ($vm in $vms) {
            $vmUuid  = $vm.uuid
            $vmName  = if ($vm.name) { $vm.name } else { "VM-$vmUuid" }
            $vmState = if ($vm.power_state) { $vm.power_state } else { 'unknown' }
            $vmIp    = $null

            # Try to extract guest IP from NICs
            if ($vm.vm_nics) {
                foreach ($nic in @($vm.vm_nics)) {
                    if ($nic.ip_address) {
                        $vmIp = $nic.ip_address
                        break
                    }
                }
            }

            $vmAttrs = @{
                'DiscoveryHelper.Nutanix' = 'true'
                'Nutanix.ClusterName'     = $clusterName
                'Nutanix.VMUuid'          = $vmUuid
                'Nutanix.VMName'          = $vmName
                'Nutanix.VMState'         = $vmState
                'Nutanix.DeviceType'      = 'VM'
                'Vendor'                  = 'Nutanix'
            }
            if ($vmIp) { $vmAttrs['Nutanix.IPAddress'] = $vmIp }

            # Active Monitor: VM power state
            $stateCompare = "[{`"JsonPathQuery`":`"['power_state']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"on`"}]"
            $items += New-DiscoveredItem `
                -Name "Nutanix VM Health - $vmName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "${apiBase}/vms/${vmUuid}"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = $stateCompare
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "Nutanix:${clusterUuid}:vm:${vmUuid}:active:health" `
                -Attributes $vmAttrs `
                -Tags @('nutanix', 'vm', $vmName)

            # Only add perf monitors for powered-on VMs
            if ($vmState -eq 'on') {
                # Perf Monitor: VM CPU usage
                $items += New-DiscoveredItem `
                    -Name "CPU Usage % - $vmName (nutanix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = "${apiBase}/vms/${vmUuid}"
                        RestApiJsonPath           = '$.stats.hypervisor_cpu_usage_ppm'
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        _MetricName               = 'cpu_usage_ppm'
                        _MetricDisplayName        = 'CPU Usage (ppm)'
                    } `
                    -UniqueKey "Nutanix:${clusterUuid}:vm:${vmUuid}:perf:cpu" `
                    -Attributes $vmAttrs `
                    -Tags @('nutanix', 'vm', $vmName, 'cpu')

                # Perf Monitor: VM Memory usage
                $items += New-DiscoveredItem `
                    -Name "Memory Usage % - $vmName (nutanix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = "${apiBase}/vms/${vmUuid}"
                        RestApiJsonPath           = '$.stats.hypervisor_memory_usage_ppm'
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        _MetricName               = 'memory_usage_ppm'
                        _MetricDisplayName        = 'Memory Usage (ppm)'
                    } `
                    -UniqueKey "Nutanix:${clusterUuid}:vm:${vmUuid}:perf:memory" `
                    -Attributes $vmAttrs `
                    -Tags @('nutanix', 'vm', $vmName, 'memory')
            }
        }

        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD5uq+CEmnwgNi2
# 5xqyqBnisrPLHzInI1pSw6lgVcD5v6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgU2zYi5zUv4jeIjm2pJdCd7HO9aNFFZ+3
# SYTrlvb9HKMwDQYJKoZIhvcNAQEBBQAEggIAQJmcaJWd1iI2PbkmlZah0pXYvdC2
# M4CrFUxWvtbhIJKmq5eAUIw+gTBYc3F1wQOQr1tB5YVV9NU3aPvPFXSQ0H+V32jp
# 2Ir8fG5V88Kh4KoXYGfHQpFEQSiRL/gCk1UjzwNjnIEBf/nWjN6RdPICihlNO05V
# SKXS2YDwJtvj4PPhSuUJyT3ZwMZc5VPgLX9XfGPMAeHpk0cx+qcjRXd7fPbcy7Oc
# KAC7b0EGIwm7X5tI6O2mNHclGOLrb62uZ5gPn5gmZbDJSDg5/XByNoH+5vAvlmEl
# BLCR1y8+OKm/0Es7hVVdfpdGcMGUXhSxs/2oqYhnWz5QArNhAPmIrhW454XsTKo4
# w+clrlf2uRXG/bCdVPGR3t9on+u6kEO0m4sKIeCN6jOWOpNCoZ8QLyYw/1d9BgGX
# +N+MKFpVqdyYoUwWyoQOFtmL/0jVaJ4O9/TbJIVtFmZRVFJ1OpbCJSp5G8PqisDK
# yNrAFfUyYZkSNTEgjTSVt5UmDx9/FjCFf6HKrmUsA4aZamy4k2iNTpSXqp6G6hfr
# MbbF9RWuFomebC72XOJRx9qfM09YcBCqsPznsHL3To5pBemFMSXkfs04qVHwfo3I
# shUUfbp2VgjAdPYc/63MkrbHoOARdNuIXijyc4SRaeGWXDYtYpJzpp0gPZWquZek
# 1tkVDxz6mJUnn90=
# SIG # End signature block
