<#
.SYNOPSIS
    OCI discovery provider for Oracle Cloud Infrastructure monitoring.

.DESCRIPTION
    Registers an OCI discovery provider that uses the OCI.PSModules
    to discover compute instances, DB systems, autonomous databases,
    and load balancers, then builds a monitor plan.

    Active Monitors (up/down):
      - Per-instance lifecycle state (Compute: RUNNING, DB: AVAILABLE, LB: ACTIVE)

    Authentication:
      OCI uses API key authentication via ~/.oci/config file. The config
      file path and profile name are passed through the credential object.

    Prerequisites:
      1. OCI.PSModules installed (Install-Module OCI.PSModules)
      2. OCI config file (~/.oci/config) with valid API key
      3. Device attribute 'DiscoveryHelper.OCI' = 'true'

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first, OCI.PSModules
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

# Load OCI helpers
$ociHelperPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'oci\OCIHelpers.ps1'
if (Test-Path $ociHelperPath) {
    . $ociHelperPath
}

# ============================================================================
# OCI Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'OCI' `
    -MatchAttribute 'DiscoveryHelper.OCI' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $cred = $ctx.Credential

        # OCI config file and profile
        $configFile = if ($cred.ConfigFile) { $cred.ConfigFile } else { $null }
        $profile    = if ($cred.Profile)    { $cred.Profile }    else { $null }
        $tenancyId  = if ($cred.TenancyId)  { $cred.TenancyId }  else { $ctx.DeviceIP }
        $region     = if ($cred.Region)     { $cred.Region }     else { $null }

        # Validate connection
        try {
            $connectSplat = @{}
            if ($configFile) { $connectSplat['ConfigFile'] = $configFile }
            if ($profile)    { $connectSplat['Profile']    = $profile }
            Connect-OCIProfile @connectSplat
        }
        catch {
            Write-Warning "OCI: Authentication failed: $_"
            return $items
        }

        # Common splat for OCI calls
        $baseSplat = @{}
        if ($configFile) { $baseSplat['ConfigFile'] = $configFile }
        if ($profile)    { $baseSplat['Profile']    = $profile }
        if ($region)     { $baseSplat['Region']     = $region }

        # Discover compartments
        Write-Host "  Discovering OCI tenancy: $tenancyId" -ForegroundColor DarkGray
        $compartments = @()
        try {
            $compSplat = @{ TenancyId = $tenancyId }
            if ($configFile) { $compSplat['ConfigFile'] = $configFile }
            if ($profile)    { $compSplat['Profile']    = $profile }
            $compartments = @(Get-OCICompartments @compSplat)
        }
        catch {
            Write-Warning "OCI: Could not list compartments: $_"
        }

        # Include root compartment
        $compIds = @($tenancyId)
        foreach ($c in $compartments) { $compIds += $c.CompartmentId }

        Write-Host "  Found $($compIds.Count) compartments (including root)" -ForegroundColor DarkGray

        # --- Compute Instances ---
        Write-Host "  Querying compute instances..." -ForegroundColor DarkGray
        $allInstances = @()
        foreach ($compId in $compIds) {
            try {
                $instSplat = @{ CompartmentId = $compId } + $baseSplat
                $instances = @(Get-OCIComputeInstances @instSplat)
                $allInstances += $instances
            }
            catch {
                Write-Verbose "OCI: Could not list instances in compartment ${compId}: $_"
            }
        }

        Write-Host "  Found $($allInstances.Count) compute instances" -ForegroundColor DarkGray

        foreach ($inst in $allInstances) {
            $instName  = $inst.Name
            $instId    = $inst.InstanceId
            $instState = $inst.LifecycleState   # RUNNING, STOPPED, TERMINATED, etc.
            $instShape = $inst.Shape
            $instAD    = $inst.AvailabilityDomain

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'Compute' -Resource $inst

            $instAttrs = @{
                'DiscoveryHelper.OCI' = 'true'
                'OCI.TenancyId'       = $tenancyId
                'OCI.CompartmentId'   = $inst.CompartmentId
                'OCI.InstanceId'      = $instId
                'OCI.Shape'           = $instShape
                'OCI.AD'              = $instAD
                'OCI.LifecycleState'  = $instState
                'OCI.DeviceType'      = 'Compute'
                'Vendor'              = 'Oracle Cloud'
            }
            if ($resolvedIp) { $instAttrs['OCI.IPAddress'] = $resolvedIp }

            # Active Monitor: instance state
            # OCI doesn't have a simple GET-by-ID REST URL usable without signing;
            # we use a REST API call against the compute API with unsigned requests not practical.
            # Instead, we build monitors that the OCI helpers will verify via PowerShell script monitors
            # or via REST with proper signing. For now, track as discovered items for plan export.
            $items += New-DiscoveredItem `
                -Name "OCI Compute Health - $instName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "https://iaas.$($inst.Region).oraclecloud.com/20160918/instances/${instId}"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = "[{`"JsonPathQuery`":`"['lifecycleState']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"RUNNING`"}]"
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "OCI:${tenancyId}:compute:${instId}:active:health" `
                -Attributes $instAttrs `
                -Tags @('oci', 'compute', $instName, $instAD)
        }

        # --- DB Systems ---
        Write-Host "  Querying DB Systems..." -ForegroundColor DarkGray
        $allDBSystems = @()
        foreach ($compId in $compIds) {
            try {
                $dbSplat = @{ CompartmentId = $compId } + $baseSplat
                $dbs = @(Get-OCIDBSystems @dbSplat)
                $allDBSystems += $dbs
            }
            catch {
                Write-Verbose "OCI: Could not list DB systems in compartment ${compId}: $_"
            }
        }

        Write-Host "  Found $($allDBSystems.Count) DB Systems" -ForegroundColor DarkGray

        foreach ($db in $allDBSystems) {
            $dbName  = $db.Name
            $dbId    = $db.DBSystemId
            $dbState = $db.LifecycleState   # AVAILABLE, STOPPED, TERMINATING, etc.
            $dbShape = $db.Shape
            $dbAD    = $db.AvailabilityDomain

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'DBSystem' -Resource $db

            $dbAttrs = @{
                'DiscoveryHelper.OCI' = 'true'
                'OCI.TenancyId'       = $tenancyId
                'OCI.CompartmentId'   = $db.CompartmentId
                'OCI.DBSystemId'      = $dbId
                'OCI.Shape'           = $dbShape
                'OCI.AD'              = $dbAD
                'OCI.LifecycleState'  = $dbState
                'OCI.Edition'         = $db.DatabaseEdition
                'OCI.DeviceType'      = 'DBSystem'
                'Vendor'              = 'Oracle Cloud'
            }
            if ($resolvedIp) { $dbAttrs['OCI.IPAddress'] = $resolvedIp }

            $items += New-DiscoveredItem `
                -Name "OCI DB Health - $dbName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "https://database.$($db.Region).oraclecloud.com/20160918/dbSystems/${dbId}"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = "[{`"JsonPathQuery`":`"['lifecycleState']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"AVAILABLE`"}]"
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "OCI:${tenancyId}:dbsystem:${dbId}:active:health" `
                -Attributes $dbAttrs `
                -Tags @('oci', 'dbsystem', $dbName, $dbAD)
        }

        # --- Autonomous Databases ---
        Write-Host "  Querying Autonomous Databases..." -ForegroundColor DarkGray
        $allADBs = @()
        foreach ($compId in $compIds) {
            try {
                $adbSplat = @{ CompartmentId = $compId } + $baseSplat
                $adbs = @(Get-OCIAutonomousDatabases @adbSplat)
                $allADBs += $adbs
            }
            catch {
                Write-Verbose "OCI: Could not list autonomous DBs in compartment ${compId}: $_"
            }
        }

        Write-Host "  Found $($allADBs.Count) Autonomous Databases" -ForegroundColor DarkGray

        foreach ($adb in $allADBs) {
            $adbName    = $adb.Name
            $adbId      = $adb.AutonomousDbId
            $adbState   = $adb.LifecycleState   # AVAILABLE, STOPPED, TERMINATED, etc.
            $adbWorkload = $adb.DbWorkload

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'AutonomousDB' -Resource $adb

            $adbAttrs = @{
                'DiscoveryHelper.OCI' = 'true'
                'OCI.TenancyId'       = $tenancyId
                'OCI.CompartmentId'   = $adb.CompartmentId
                'OCI.AutonomousDbId'  = $adbId
                'OCI.DbWorkload'      = $adbWorkload
                'OCI.LifecycleState'  = $adbState
                'OCI.DeviceType'      = 'AutonomousDB'
                'Vendor'              = 'Oracle Cloud'
            }
            if ($resolvedIp) { $adbAttrs['OCI.IPAddress'] = $resolvedIp }

            $items += New-DiscoveredItem `
                -Name "OCI ADB Health - $adbName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "https://database.$($adb.Region).oraclecloud.com/20160918/autonomousDatabases/${adbId}"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = "[{`"JsonPathQuery`":`"['lifecycleState']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"AVAILABLE`"}]"
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "OCI:${tenancyId}:adb:${adbId}:active:health" `
                -Attributes $adbAttrs `
                -Tags @('oci', 'autonomousdb', $adbName, $adbWorkload)
        }

        # --- Load Balancers ---
        Write-Host "  Querying Load Balancers..." -ForegroundColor DarkGray
        $allLBs = @()
        foreach ($compId in $compIds) {
            try {
                $lbSplat = @{ CompartmentId = $compId } + $baseSplat
                $lbs = @(Get-OCILoadBalancers @lbSplat)
                $allLBs += $lbs
            }
            catch {
                Write-Verbose "OCI: Could not list load balancers in compartment ${compId}: $_"
            }
        }

        Write-Host "  Found $($allLBs.Count) Load Balancers" -ForegroundColor DarkGray

        foreach ($lb in $allLBs) {
            $lbName  = $lb.Name
            $lbId    = $lb.LoadBalancerId
            $lbState = $lb.LifecycleState   # ACTIVE, FAILED, CREATING, etc.
            $lbShape = $lb.ShapeName

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'LoadBalancer' -Resource $lb

            $lbAttrs = @{
                'DiscoveryHelper.OCI' = 'true'
                'OCI.TenancyId'       = $tenancyId
                'OCI.CompartmentId'   = $lb.CompartmentId
                'OCI.LoadBalancerId'  = $lbId
                'OCI.Shape'           = $lbShape
                'OCI.LifecycleState'  = $lbState
                'OCI.DeviceType'      = 'LoadBalancer'
                'Vendor'              = 'Oracle Cloud'
            }
            if ($resolvedIp) { $lbAttrs['OCI.IPAddress'] = $resolvedIp }

            $items += New-DiscoveredItem `
                -Name "OCI LB Health - $lbName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = "https://iaas.$($lb.Region).oraclecloud.com/20170115/loadBalancers/${lbId}"
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = "[{`"JsonPathQuery`":`"['lifecycleState']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"ACTIVE`"}]"
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "OCI:${tenancyId}:lb:${lbId}:active:health" `
                -Attributes $lbAttrs `
                -Tags @('oci', 'loadbalancer', $lbName, $lbShape)
        }

        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQjpKYfUGn5aL+
# UYK8DSa+mJjZnt6FQ/YNSF7lohL99qCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg66Lus7rvJN9Qveqn0bYTG8DLtAQrReNd
# Vdpdk5ZpCPYwDQYJKoZIhvcNAQEBBQAEggIAL0cQNNQsxlXTyCmfy1eBms5bcniI
# 35o/b4uKrk9t6Z3zJ8QGBFXNltwy2NLff9zWcnCmY1RlkRcYlhYVTpK5UbowE1FA
# Aki4z1mvMI0DR646TlDFtjveAn3ATJYfUG0H3GC01pXTQf6VNcBCnQnxd9jU1iwx
# 3WlYstyJfVHPvr/gAjJzCamB2KDjf1Q82f1KYnWhiLO366HtBGvkfexf/PhwbjXc
# q60bHhADT/pN7g+Uy0WzumO6nHXRsj8BEqm1+3TdlW+s4vcbWLEiql8vPvkQa4ST
# c2/ED0rWmYo53uHNySHEXkdDr1Rvswu5AAUiutwSYPnRYYmTGMAagw/diHyaAksj
# W9IlJZZxMSV8oMK7sUUxW/e6sox1q9nnd0JOQiBXhj5QCba+tzL3Oa2tyuiRjzV+
# iVJq5SnQ8TmPOL5rotVTRoR2jAuTqdz43rBjDUZAmyQgsIB2qANMykFw3l0bolfy
# AW4AvArynJZEdyaTI8dXEHD+c16esVw+/3cw/xOkxtfC6vXqeF1XGH0oL6S80hFG
# YXig+GX4pSnWNRJRmcgr4iYR5XYWQEmkwp+Y2OafyWK8jaYQ9Vgr0AD0M+4ifawa
# QOuQfa3obzqbdJzC1TNGLhQ9lD1vRBiD6UzSsfuTwOS6DEn1DSq3f7C7nb/s7frw
# eqWgtUQSG/gxBio=
# SIG # End signature block
