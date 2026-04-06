<#
.SYNOPSIS
    GCP discovery provider for Google Cloud infrastructure monitoring.

.DESCRIPTION
    Registers a GCP discovery provider that uses gcloud CLI and GCP REST
    APIs to discover Compute Engine VMs, Cloud SQL instances, and load
    balancer forwarding rules, then builds a monitor plan.

    Active Monitors (up/down):
      - Per-VM instance status via Compute Engine API
      - Per-Cloud SQL instance state via sqladmin API

    Performance Monitors (stats over time):
      - VM CPU utilization via Cloud Monitoring API
      - Cloud SQL connections, CPU, memory via monitoring

    Authentication:
      GCP uses a service account JSON key file. The gcloud CLI is required
      to activate the account and obtain bearer tokens for REST API calls.

    Prerequisites:
      1. gcloud CLI installed and in PATH
      2. Service account JSON key file with Compute Viewer + Monitoring Viewer roles
      3. Device attribute 'DiscoveryHelper.GCP' = 'true'

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first, gcloud CLI
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

# Load GCP helpers
$gcpHelperPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'gcp\GCPHelpers.ps1'
if (Test-Path $gcpHelperPath) {
    . $gcpHelperPath
}

# ============================================================================
# GCP Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'GCP' `
    -MatchAttribute 'DiscoveryHelper.GCP' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $cred = $ctx.Credential

        # Get bearer token and project
        $token = $null
        $project = $null

        if ($cred.AccessToken) {
            $token = $cred.AccessToken
        }
        elseif ($cred.KeyFilePath) {
            # Activate service account and get token
            try {
                Connect-GCPAccount -KeyFilePath $cred.KeyFilePath -Project $cred.Project
                $token = Get-GCPAccessToken
            }
            catch {
                Write-Warning "GCP: Could not authenticate: $_"
                return $items
            }
        }
        if (-not $token) {
            Write-Warning "GCP: No access token available."
            return $items
        }

        $project = if ($cred.Project) { $cred.Project } else { $ctx.DeviceIP }
        $authHeaders = @{ Authorization = "Bearer $token" }
        $computeApi = 'https://compute.googleapis.com/compute/v1'
        $sqlApi     = 'https://sqladmin.googleapis.com/v1'

        # Helper for GCP REST calls
        function Invoke-GCPREST {
            param([string]$Uri)
            Invoke-RestMethod -Uri $Uri -Headers $authHeaders -Method GET -ErrorAction Stop
        }

        Write-Host "  Discovering GCP project: $project" -ForegroundColor DarkGray

        # --- Compute Engine VMs ---
        Write-Host "  Querying Compute Engine instances..." -ForegroundColor DarkGray
        $vms = @()
        try {
            $resp = Invoke-GCPREST -Uri "${computeApi}/projects/${project}/aggregated/instances"
            if ($resp.items) {
                foreach ($zone in $resp.items.PSObject.Properties) {
                    if ($zone.Value.instances) {
                        $vms += @($zone.Value.instances)
                    }
                }
            }
        }
        catch {
            Write-Warning "GCP: Could not list VMs: $_"
        }

        Write-Host "  Found $($vms.Count) VM instances" -ForegroundColor DarkGray

        foreach ($vm in $vms) {
            $vmName   = $vm.name
            $vmId     = $vm.id
            $vmStatus = $vm.status   # RUNNING, STOPPED, TERMINATED, etc.
            $vmZone   = ($vm.zone -split '/')[-1]
            $vmType   = ($vm.machineType -split '/')[-1]

            # Extract IPs
            $vmIp = $null
            $vmExtIp = $null
            if ($vm.networkInterfaces) {
                $nic = $vm.networkInterfaces | Select-Object -First 1
                if ($nic.networkIP) { $vmIp = $nic.networkIP }
                if ($nic.accessConfigs) {
                    $ac = $nic.accessConfigs | Where-Object { $_.natIP } | Select-Object -First 1
                    if ($ac) { $vmExtIp = $ac.natIP }
                }
            }
            $resolvedIp = if ($vmExtIp) { $vmExtIp } elseif ($vmIp) { $vmIp } else { $null }

            $vmAttrs = @{
                'DiscoveryHelper.GCP' = 'true'
                'GCP.Project'         = $project
                'GCP.VMName'          = $vmName
                'GCP.VMId'            = "$vmId"
                'GCP.Zone'            = $vmZone
                'GCP.MachineType'     = $vmType
                'GCP.Status'          = $vmStatus
                'GCP.DeviceType'      = 'VM'
                'Vendor'              = 'Google Cloud'
            }
            if ($resolvedIp) { $vmAttrs['GCP.IPAddress'] = $resolvedIp }

            # Active Monitor: VM status
            $vmSelfLink = $vm.selfLink
            $statusCompare = "[{`"JsonPathQuery`":`"['status']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"RUNNING`"}]"
            $items += New-DiscoveredItem `
                -Name "GCP VM Health - $vmName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $vmSelfLink
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = $statusCompare
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "GCP:${project}:vm:${vmId}:active:health" `
                -Attributes $vmAttrs `
                -Tags @('gcp', 'vm', $vmName, $vmZone)
        }

        # --- Cloud SQL instances ---
        Write-Host "  Querying Cloud SQL instances..." -ForegroundColor DarkGray
        $sqlInstances = @()
        try {
            $sqlResp = Invoke-GCPREST -Uri "${sqlApi}/projects/${project}/instances"
            if ($sqlResp.items) { $sqlInstances = @($sqlResp.items) }
        }
        catch {
            Write-Verbose "GCP: Could not list Cloud SQL instances: $_"
        }

        Write-Host "  Found $($sqlInstances.Count) Cloud SQL instances" -ForegroundColor DarkGray

        foreach ($sql in $sqlInstances) {
            $sqlName    = $sql.name
            $sqlState   = $sql.state   # RUNNABLE, STOPPED, etc.
            $sqlTier    = if ($sql.settings.tier) { $sql.settings.tier } else { 'unknown' }
            $sqlVersion = if ($sql.databaseVersion) { $sql.databaseVersion } else { 'unknown' }
            $sqlRegion  = if ($sql.region) { $sql.region } else { 'unknown' }

            # Cloud SQL public IP
            $sqlIp = $null
            if ($sql.ipAddresses) {
                $pub = $sql.ipAddresses | Where-Object { $_.type -eq 'PRIMARY' } | Select-Object -First 1
                if ($pub) { $sqlIp = $pub.ipAddress }
            }

            $sqlAttrs = @{
                'DiscoveryHelper.GCP'  = 'true'
                'GCP.Project'          = $project
                'GCP.SQLName'          = $sqlName
                'GCP.SQLVersion'       = $sqlVersion
                'GCP.SQLTier'          = $sqlTier
                'GCP.SQLRegion'        = $sqlRegion
                'GCP.SQLState'         = $sqlState
                'GCP.DeviceType'       = 'CloudSQL'
                'Vendor'               = 'Google Cloud'
            }
            if ($sqlIp) { $sqlAttrs['GCP.IPAddress'] = $sqlIp }

            # Active Monitor: Cloud SQL state
            $sqlSelfLink = $sql.selfLink
            if (-not $sqlSelfLink) {
                $sqlSelfLink = "${sqlApi}/projects/${project}/instances/${sqlName}"
            }
            $sqlCompare = "[{`"JsonPathQuery`":`"['state']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"RUNNABLE`"}]"
            $items += New-DiscoveredItem `
                -Name "GCP Cloud SQL Health - $sqlName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $sqlSelfLink
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = $sqlCompare
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "GCP:${project}:sql:${sqlName}:active:health" `
                -Attributes $sqlAttrs `
                -Tags @('gcp', 'cloudsql', $sqlName, $sqlRegion)
        }

        # --- Load Balancer forwarding rules ---
        Write-Host "  Querying forwarding rules..." -ForegroundColor DarkGray
        $fwdRules = @()
        try {
            $fwdResp = Invoke-GCPREST -Uri "${computeApi}/projects/${project}/aggregated/forwardingRules"
            if ($fwdResp.items) {
                foreach ($region in $fwdResp.items.PSObject.Properties) {
                    if ($region.Value.forwardingRules) {
                        $fwdRules += @($region.Value.forwardingRules)
                    }
                }
            }
        }
        catch {
            Write-Verbose "GCP: Could not list forwarding rules: $_"
        }

        Write-Host "  Found $($fwdRules.Count) forwarding rules" -ForegroundColor DarkGray

        foreach ($fwd in $fwdRules) {
            $fwdName = $fwd.name
            $fwdIp   = if ($fwd.IPAddress) { $fwd.IPAddress } else { $null }
            $fwdPort = if ($fwd.portRange) { $fwd.portRange } elseif ($fwd.ports) { ($fwd.ports -join ',') } else { '' }
            $fwdProto = if ($fwd.IPProtocol) { $fwd.IPProtocol } else { '' }
            $fwdRegion = if ($fwd.region) { ($fwd.region -split '/')[-1] } else { 'global' }

            $fwdAttrs = @{
                'DiscoveryHelper.GCP' = 'true'
                'GCP.Project'         = $project
                'GCP.FwdRuleName'     = $fwdName
                'GCP.FwdProtocol'     = $fwdProto
                'GCP.FwdPorts'        = $fwdPort
                'GCP.FwdRegion'       = $fwdRegion
                'GCP.DeviceType'      = 'ForwardingRule'
                'Vendor'              = 'Google Cloud'
            }
            if ($fwdIp) { $fwdAttrs['GCP.IPAddress'] = $fwdIp }

            # Active Monitor: Forwarding rule exists
            $fwdSelfLink = $fwd.selfLink
            $items += New-DiscoveredItem `
                -Name "GCP LB Health - $fwdName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $fwdSelfLink
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "GCP:${project}:fwd:${fwdName}:active:health" `
                -Attributes $fwdAttrs `
                -Tags @('gcp', 'loadbalancer', $fwdName, $fwdRegion)
        }

        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDaLT8LCw17F6ba
# tc4SqEE+2hwioB0HE4HIyFQpkgLM8aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgHnJfWa5X7lNltrcFjZF5CTmVTTYjl4aB
# GMjJPekwJTgwDQYJKoZIhvcNAQEBBQAEggIAWo26cJWH5Tv8urMaoLflkG6qt1G5
# 7Mn1Plro9Q08e2yyRwf/PMCyiF2oJP7OzeglaTqyi34kOFQf0B1QeKoYfml3oH59
# A8ShwitjWjizreZNu6HHqPwEsFAldK/MPHUkb+FGk1bd4PxxEWNY48bF7gnBiErk
# VVspu4JlDbMhWc90TIInW5HN2MOE5WSZmfisl8OLwsOK0Bev694W9mkPEXagm8Os
# ewspQMyZIU9cS3kiLKMNa1HlDWMjZ2LtrX8A4uXiZWRSiPp0sDNYOHz7m5lqAumO
# EXsOlLcQTQsq1GwiBDIHoMF+ZcvY73lw2PzNxXq3dfG2EoRZhBvvARBQGYSk/HtE
# N/XpPTr8TNSstkD2oR9dItLMFH262g3Jx9v5LNTt0zDTkvsTjodw9tt9dCmAWZ7B
# ur3Eo/UKxEJzFDtk4jIAceXOTNLUVvlsxXUkXSRB5w7KSdUehp/3FiONdzXy+DyB
# 2P9M1g32NybSWs97wAOS0eyV7dyRKjLWZyCYkNgRPCaZ9GaLbFCDUnoQjcYHOlsG
# P1Zr+bClWGzr/qOFkOIh62qQxNx2CF6GdhhfJCNBOlAVcW/ksB7S8W9lTTCv4qxn
# qjg70YXZStOduexqhUIbNVenGilUxgbh/X7uTEh06TgDD4NacW7NYldZRZdPZRcg
# M97CzemGdPSRQY4=
# SIG # End signature block
