<#
.SYNOPSIS
    OCI discovery provider for Oracle Cloud Infrastructure monitoring.

.DESCRIPTION
    Registers an OCI discovery provider that uses the OCI.PSModules
    to discover compute instances, DB systems, autonomous databases,
    and load balancers, then builds a monitor plan.

    Monitor Strategy (Option B -- built-in WUG monitors):
      - Ping Active Monitors for resources with reachable public IPs
      - TCP Active Monitors for resources with known service ports
        (SSH/22 for compute, HTTP/80 and HTTPS/443 for load balancers,
         SQL*Net/1521 for DB systems)
      - Resources without public IPs are included as inventory-only
        items in the discovery plan (for dashboard display)

    OCI REST APIs require HTTP Signature authentication (similar to
    AWS SigV4) which WUG cannot perform natively. Ping/TCP monitors
    require no cloud authentication and work with WUG out of the box.

    OCI Monitoring metrics (CPU, memory, disk, network) are queried
    via OCI.PSModules during discovery and stored as point-in-time
    snapshots in device attributes for dashboard display.

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

        # Collect metrics if OCI CLI is available (optional enrichment)
        $collectMetrics = [bool](Get-Command oci -ErrorAction SilentlyContinue)
        if ($collectMetrics) {
            Write-Host "  OCI CLI detected -- will collect metrics snapshots" -ForegroundColor DarkGray
        }

        # --- Helper: add Ping monitor for a resource with a public IP ---
        # Returns the item, or $null if no public IP available.
        $addPingMonitor = {
            param($Name, $UniqueKey, $Attributes, $Tags)
            $ip = $Attributes['OCI.IPAddress']
            if (-not $ip -or $ip -eq 'N/A') { return $null }
            New-DiscoveredItem `
                -Name $Name `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'Ping' `
                -MonitorParams @{
                    Timeout      = '3000'
                    RetryCount   = '2'
                    PayloadSize  = '32'
                } `
                -UniqueKey $UniqueKey `
                -Attributes $Attributes `
                -Tags $Tags
        }

        # --- Helper: add TCP port monitor ---
        $addTcpMonitor = {
            param($Name, $Port, $UniqueKey, $Attributes, $Tags)
            $ip = $Attributes['OCI.IPAddress']
            if (-not $ip -or $ip -eq 'N/A') { return $null }
            New-DiscoveredItem `
                -Name $Name `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'TcpIp' `
                -MonitorParams @{
                    Port         = "$Port"
                    Timeout      = '5000'
                    RetryCount   = '1'
                } `
                -UniqueKey $UniqueKey `
                -Attributes $Attributes `
                -Tags $Tags
        }

        # --- Helper: collect metrics and store as attributes ---
        $enrichWithMetrics = {
            param($Attrs, $CompartmentId, $Namespace, $ResourceId, $Region)
            if (-not $collectMetrics) { return }
            try {
                $metricSplat = @{
                    CompartmentId = $CompartmentId
                    Namespace     = $Namespace
                    ResourceId    = $ResourceId
                }
                if ($Region) { $metricSplat['Region'] = $Region }
                $metrics = @(Get-OCIMonitoringMetrics @metricSplat)
                foreach ($m in $metrics) {
                    if ($m.LastValue -and $m.LastValue -ne 'N/A') {
                        $Attrs["OCI.Metric.$($m.MetricName)"] = "$($m.LastValue) $($m.Unit)"
                    }
                }
                if ($metrics.Count -gt 0) {
                    $Attrs['OCI.MetricCount'] = "$($metrics.Count)"
                }
            }
            catch {
                Write-Verbose "OCI: Metrics collection failed for ${ResourceId}: $_"
            }
        }

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
            $instState = $inst.LifecycleState
            $instShape = $inst.Shape
            $instAD    = $inst.AvailabilityDomain

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'Compute' -Resource $inst

            $instAttrs = @{
                'DiscoveryHelper.OCI'          = 'true'
                'DiscoveryHelper.OCI.LastRun'   = (Get-Date).ToUniversalTime().ToString('o')
                'OCI.TenancyId'                = $tenancyId
                'OCI.CompartmentId'            = $inst.CompartmentId
                'OCI.InstanceId'               = $instId
                'OCI.Shape'                    = $instShape
                'OCI.AD'                       = $instAD
                'OCI.FaultDomain'              = $inst.FaultDomain
                'OCI.LifecycleState'           = $instState
                'OCI.PublicIP'                 = $inst.PublicIP
                'OCI.PrivateIP'                = $inst.PrivateIP
                'OCI.Region'                   = $inst.Region
                'OCI.TimeCreated'              = $inst.TimeCreated
                'OCI.DeviceType'               = 'Compute'
                'Cloud Type'                   = 'Compute'
                'ComputedDisplayName'          = $instName
                'HostName'                     = $instName
                'Vendor'                       = 'Oracle Cloud'
            }
            if ($resolvedIp) { $instAttrs['OCI.IPAddress'] = $resolvedIp }

            # Collect metrics snapshot
            & $enrichWithMetrics $instAttrs $inst.CompartmentId 'oci_computeagent' $instId $inst.Region

            # Ping monitor (requires public IP)
            $pingItem = & $addPingMonitor `
                "OCI Ping - $instName" `
                "OCI:${tenancyId}:compute:${instId}:active:ping" `
                $instAttrs `
                @('oci', 'compute', $instName, $instAD)
            if ($pingItem) { $items += $pingItem }

            # TCP monitor for SSH (port 22) if public IP available
            $sshItem = & $addTcpMonitor `
                "OCI SSH - $instName" 22 `
                "OCI:${tenancyId}:compute:${instId}:active:ssh" `
                $instAttrs `
                @('oci', 'compute', 'ssh', $instName)
            if ($sshItem) { $items += $sshItem }

            # If no public IP, add an inventory-only item for dashboard
            if (-not $pingItem) {
                $items += New-DiscoveredItem `
                    -Name "OCI Compute (inventory) - $instName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'Ping' `
                    -MonitorParams @{
                        _InventoryOnly = 'true'
                        _Reason        = 'No public IP'
                    } `
                    -UniqueKey "OCI:${tenancyId}:compute:${instId}:inventory" `
                    -Attributes $instAttrs `
                    -Tags @('oci', 'compute', 'inventory', $instName)
            }
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
            $dbState = $db.LifecycleState
            $dbShape = $db.Shape
            $dbAD    = $db.AvailabilityDomain

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'DBSystem' -Resource $db

            $dbAttrs = @{
                'DiscoveryHelper.OCI'          = 'true'
                'DiscoveryHelper.OCI.LastRun'   = (Get-Date).ToUniversalTime().ToString('o')
                'OCI.TenancyId'                = $tenancyId
                'OCI.CompartmentId'            = $db.CompartmentId
                'OCI.DBSystemId'               = $dbId
                'OCI.Shape'                    = $dbShape
                'OCI.AD'                       = $dbAD
                'OCI.LifecycleState'           = $dbState
                'OCI.Edition'                  = $db.DatabaseEdition
                'OCI.CpuCoreCount'             = $db.CpuCoreCount
                'OCI.DataStorageSizeInGBs'     = $db.DataStorageSizeInGBs
                'OCI.NodeCount'                = $db.NodeCount
                'OCI.DiskRedundancy'           = $db.DiskRedundancy
                'OCI.LicenseModel'             = $db.LicenseModel
                'OCI.Version'                  = $db.Version
                'OCI.Hostname'                 = $db.Hostname
                'OCI.Domain'                   = $db.Domain
                'OCI.Region'                   = $db.Region
                'OCI.TimeCreated'              = $db.TimeCreated
                'OCI.DeviceType'               = 'DBSystem'
                'Cloud Type'                   = 'DBSystem'
                'ComputedDisplayName'          = $dbName
                'HostName'                     = $dbName
                'Vendor'                       = 'Oracle Cloud'
            }
            if ($resolvedIp) { $dbAttrs['OCI.IPAddress'] = $resolvedIp }

            # Collect metrics snapshot
            & $enrichWithMetrics $dbAttrs $db.CompartmentId 'oci_database' $dbId $db.Region

            # Ping monitor
            $pingItem = & $addPingMonitor `
                "OCI Ping - $dbName" `
                "OCI:${tenancyId}:dbsystem:${dbId}:active:ping" `
                $dbAttrs `
                @('oci', 'dbsystem', $dbName, $dbAD)
            if ($pingItem) { $items += $pingItem }

            # TCP monitor for SQL*Net (port 1521)
            $sqlItem = & $addTcpMonitor `
                "OCI SQL*Net - $dbName" 1521 `
                "OCI:${tenancyId}:dbsystem:${dbId}:active:sqlnet" `
                $dbAttrs `
                @('oci', 'dbsystem', 'sqlnet', $dbName)
            if ($sqlItem) { $items += $sqlItem }

            if (-not $pingItem) {
                $items += New-DiscoveredItem `
                    -Name "OCI DB (inventory) - $dbName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'Ping' `
                    -MonitorParams @{
                        _InventoryOnly = 'true'
                        _Reason        = 'No reachable IP'
                    } `
                    -UniqueKey "OCI:${tenancyId}:dbsystem:${dbId}:inventory" `
                    -Attributes $dbAttrs `
                    -Tags @('oci', 'dbsystem', 'inventory', $dbName)
            }
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
            $adbName     = $adb.Name
            $adbId       = $adb.AutonomousDbId
            $adbState    = $adb.LifecycleState
            $adbWorkload = $adb.DbWorkload

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'AutonomousDB' -Resource $adb

            $adbAttrs = @{
                'DiscoveryHelper.OCI'          = 'true'
                'DiscoveryHelper.OCI.LastRun'   = (Get-Date).ToUniversalTime().ToString('o')
                'OCI.TenancyId'                = $tenancyId
                'OCI.CompartmentId'            = $adb.CompartmentId
                'OCI.AutonomousDbId'           = $adbId
                'OCI.DbWorkload'               = $adbWorkload
                'OCI.LifecycleState'           = $adbState
                'OCI.CpuCoreCount'             = $adb.CpuCoreCount
                'OCI.DataStorageSizeInTBs'     = $adb.DataStorageSizeInTBs
                'OCI.IsFreeTier'               = $adb.IsFreeTier
                'OCI.LicenseModel'             = $adb.LicenseModel
                'OCI.DbVersion'                = $adb.DbVersion
                'OCI.IsAutoScalingEnabled'     = $adb.IsAutoScalingEnabled
                'OCI.IsDedicated'              = $adb.IsDedicated
                'OCI.PrivateEndpointIp'        = $adb.PrivateEndpointIp
                'OCI.Region'                   = $adb.Region
                'OCI.TimeCreated'              = $adb.TimeCreated
                'OCI.DeviceType'               = 'AutonomousDB'
                'Cloud Type'                   = 'AutonomousDB'
                'ComputedDisplayName'          = $adbName
                'HostName'                     = $adbName
                'Vendor'                       = 'Oracle Cloud'
            }
            if ($resolvedIp) { $adbAttrs['OCI.IPAddress'] = $resolvedIp }

            # Collect metrics snapshot
            & $enrichWithMetrics $adbAttrs $adb.CompartmentId 'oci_autonomous_database' $adbId $adb.Region

            # Autonomous DBs typically have private endpoints only -- TCP 1522 if reachable
            $tcpItem = & $addTcpMonitor `
                "OCI ADB Port - $adbName" 1522 `
                "OCI:${tenancyId}:adb:${adbId}:active:tcp" `
                $adbAttrs `
                @('oci', 'autonomousdb', 'tcp', $adbName)
            if ($tcpItem) { $items += $tcpItem }

            # Inventory item (most ADBs have private endpoints only)
            if (-not $tcpItem) {
                $items += New-DiscoveredItem `
                    -Name "OCI ADB (inventory) - $adbName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'Ping' `
                    -MonitorParams @{
                        _InventoryOnly = 'true'
                        _Reason        = 'Private endpoint only'
                    } `
                    -UniqueKey "OCI:${tenancyId}:adb:${adbId}:inventory" `
                    -Attributes $adbAttrs `
                    -Tags @('oci', 'autonomousdb', 'inventory', $adbName)
            }
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
            $lbState = $lb.LifecycleState
            $lbShape = $lb.ShapeName

            $resolvedIp = Resolve-OCIResourceIP -ResourceType 'LoadBalancer' -Resource $lb

            $lbAttrs = @{
                'DiscoveryHelper.OCI'          = 'true'
                'DiscoveryHelper.OCI.LastRun'   = (Get-Date).ToUniversalTime().ToString('o')
                'OCI.TenancyId'                = $tenancyId
                'OCI.CompartmentId'            = $lb.CompartmentId
                'OCI.LoadBalancerId'           = $lbId
                'OCI.Shape'                    = $lbShape
                'OCI.LifecycleState'           = $lbState
                'OCI.IsPrivate'                = $lb.IsPrivate
                'OCI.PrimaryIP'                = $lb.PrimaryIP
                'OCI.AllIPs'                   = $lb.AllIPs
                'OCI.BackendSetCount'          = $lb.BackendSetCount
                'OCI.ListenerCount'            = $lb.ListenerCount
                'OCI.Region'                   = $lb.Region
                'OCI.TimeCreated'              = $lb.TimeCreated
                'OCI.DeviceType'               = 'LoadBalancer'
                'Cloud Type'                   = 'LoadBalancer'
                'ComputedDisplayName'          = $lbName
                'HostName'                     = $lbName
                'Vendor'                       = 'Oracle Cloud'
            }
            if ($resolvedIp) { $lbAttrs['OCI.IPAddress'] = $resolvedIp }

            # Collect metrics snapshot
            & $enrichWithMetrics $lbAttrs $lb.CompartmentId 'oci_lbaas' $lbId $lb.Region

            # Ping monitor for public LBs
            $pingItem = & $addPingMonitor `
                "OCI Ping - $lbName" `
                "OCI:${tenancyId}:lb:${lbId}:active:ping" `
                $lbAttrs `
                @('oci', 'loadbalancer', $lbName, $lbShape)
            if ($pingItem) { $items += $pingItem }

            # TCP monitors for HTTP/HTTPS
            $httpItem = & $addTcpMonitor `
                "OCI HTTP - $lbName" 80 `
                "OCI:${tenancyId}:lb:${lbId}:active:http" `
                $lbAttrs `
                @('oci', 'loadbalancer', 'http', $lbName)
            if ($httpItem) { $items += $httpItem }

            $httpsItem = & $addTcpMonitor `
                "OCI HTTPS - $lbName" 443 `
                "OCI:${tenancyId}:lb:${lbId}:active:https" `
                $lbAttrs `
                @('oci', 'loadbalancer', 'https', $lbName)
            if ($httpsItem) { $items += $httpsItem }

            if (-not $pingItem) {
                $items += New-DiscoveredItem `
                    -Name "OCI LB (inventory) - $lbName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'Ping' `
                    -MonitorParams @{
                        _InventoryOnly = 'true'
                        _Reason        = 'Private load balancer'
                    } `
                    -UniqueKey "OCI:${tenancyId}:lb:${lbId}:inventory" `
                    -Attributes $lbAttrs `
                    -Tags @('oci', 'loadbalancer', 'inventory', $lbName)
            }
        }

        # --- Summary ---
        $monitorItems = @($items | Where-Object { -not $_.MonitorParams._InventoryOnly })
        $inventoryItems = @($items | Where-Object { $_.MonitorParams._InventoryOnly })
        Write-Host "  Plan: $($monitorItems.Count) monitors, $($inventoryItems.Count) inventory-only" -ForegroundColor DarkGray

        return $items
    }

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAugvRMZB4DojVh
# dsyz2JWryWDzYQAmVaLQu804YYfyrKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCWn4OR34ln5gPeSkZVAsZgSVOjL7x7PeGt5cDsB+ncdDANBgkqhkiG9w0BAQEF
# AASCAgCK9PcdAWN8IJcn3tOr2/HS1r9jejluxFUOmigWhiZfdPikscwPeF5AZY2X
# MMyFrVXB4psxCPQwPc93/3MmfpxgrkttRAozM/J7vcYlj1T5C7stZIQchDy/yip9
# dyAVOzgeAwyBpnHdKfA8uMArIQg1FktXepePXWZiPUWk/MOC6w+4+DNQVBR8038X
# Djb0IKhC/DPg8dcJcyklYLFn9Go6M2vwOK8XpP5PPD0EFNwCXnECMgMMC4YIWaMh
# KZUF8D5sseWyRObtfufo+jpSUY3ZLBRPzhTgqTEXKaWPDqArccnQq3h42OaOCD7P
# hGquh2FW9IpTWtCpebfnuSS6FCf0TMPPH3ugF1TrbqeSarpp9/fkC8tn10sd1BCW
# +0luFftbZ5Xkwp6XWdxNN/tjBuQEBeGpkd/CQZA62KprVLbzAMEaaRE9DzSPUkDA
# LMcsa4DdzH6ihzRN9lS2HBLiPjYzwDwMD8VSvPb6Ya+R7K/nGGI4mFoSs9XUhkET
# wotoONz1VW201wv7fs0ZXMGQk3OnU0gwjCt3ePaY9udAQ4JJBCUsuODI31ey1oys
# omUwi9K0kbL/4bOYBYix8Eik/T2HgOOh1f3WJ+cJhY+HHl+Qwq/5HF3AgM1TcsEF
# VVboqnBsdWWJ1tDQfwfa74XeHAgfytKeCroNsqIh18h1GDnFqqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjUyMDA3MjRaMC8GCSqGSIb3DQEJBDEiBCA6bCwp
# rOS02Zbaty+1InSXelN6BiMJFW4Rs7OB+vv+SzANBgkqhkiG9w0BAQEFAASCAgAS
# Mf1wT3agnonimY+bbm5LiWBkrzctgYHGLTV5uuPtMN5k21OhHXS4FRZMu2XteQ7e
# paQihOzqQjYkw9ZTQGDwzC1iBh20ByUHvfQlETSE+hawQ+TxMMIf5dvAEYPRrYCy
# AihF8Xxpk6GJrdwqJkrjpjRDhkAZIGsQi9/q4lQYYu2vsyhiW4hdXsHCLZhgVz7x
# ds5aJYPXdIRJhE/ljB/ppLFdu+3VNQl09JwsdVGy0nPtY9PdjxLBAPGsi189F4a+
# 7/KEFzD9jf7RRGmdl0CtSZuULMsAUcsaC9NXIS/2zdjndVK6iFdMePqA3gVDCQsF
# NTt+NNkbXyeznpR+yNuGrgltW8qM9+qNKpkonKyVdX9KivKPQ8CWHG0pKv5VrokI
# 9KxZAtg34H/+J5guSEi5CVqArhnS3XjWS91t/DRcr2v59eLtsjNILY2DxH45XH34
# IK82dh+4awz/OZdddYoFulJeY2hgWS9hLjXP6i+boCl/vnWuJakZIcwdDNRjpEWL
# h9s/hynyTwS9PxdYpi6BnF3L6m1DjWpcYevJ6Rd2Yj0GNUgV8acxMNNAzs7ABrlF
# clkkXsEcYroN4UY/+JWdnU4Va6LXz1bV9f/TUauXUhXod2j0xJss671fEKDlJY5i
# UCiHtL+p9sqTEZRgXumWzDWeEHdhfs1EvSS/Ekp/dg==
# SIG # End signature block
