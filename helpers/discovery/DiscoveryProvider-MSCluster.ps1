<#
.SYNOPSIS
    Microsoft Windows Server Failover Cluster (WSFC/MSCS) discovery provider.

.DESCRIPTION
    Registers an 'MSCluster' discovery provider that probes the root\MSCluster WMI
    namespace on a cluster node and returns the whole cluster inventory plus a
    validated monitor plan.

    Discovers:
      - The cluster itself: name, FQDN, functional level, upgrade version, admin
        access point, dynamic quorum, shared volume root, S2D state, CSV balancer
      - Heartbeat tuning: same/cross subnet delay and threshold, route history
      - Quorum health: witness resource type and state, per-node vote weights, and
        the total vote count, with a warning when an even vote count has no witness
      - Every node: state, cluster network IP, OS build, drain status, status text,
        with a warning when node builds differ outside a rolling upgrade
      - Every resource group / clustered role, with its virtual network name (VNN),
        virtual IP address(es), failover policy (auto-failback, threshold, period,
        priority), anti-affinity classes and preferred owners
      - Every cluster resource: type, state, owner group, owner node, and its
        restart / IsAlive / LooksAlive policy, flagging anything not Online
      - SQL Server Failover Cluster Instances and Always On AG listeners
      - Installed cluster resource types and unassigned available disks
      - Cluster networks with role, mask and metric, warning on a single or absent
        cluster-communication network
      - Cluster shared volumes including redirected access, maintenance mode, fault
        and backup state, warning on redirected or in-maintenance volumes
      - Cluster disk capacity: path, label, file system, mount points, percent free
      - Cluster performance counter classes present on each node, validated to
        actually return data

    Monitor plan and the shared-vs-local split:
      - NODE devices receive the node-local resources: the Cluster Service active
        monitor and every validated cluster performance counter. Those counters
        measure a node's own participation in the cluster, so they belong on the
        node and stay meaningful regardless of which node owns a role.
      - ROLE devices (the virtual IP / VNN of each clustered role) receive the
        shared resource: role availability. A role floats between nodes, so the
        only honest place to answer "is this role up" is its virtual IP.

    A clustered role only becomes a WUG device if it owns an IPv4 virtual IP.
    Roles without one are still reported in the inventory.

    Prerequisites:
      1. DiscoveryHelpers.ps1 loaded first
      2. WMI/DCOM access to at least one cluster node
      3. Credentials with local administrator rights on the node

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first, PowerShell 5.1+
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

# Dynamic dashboard generator (used by Export-MSClusterDashboardHtml)
$msClusterDynDash = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $msClusterDynDash) { . $msClusterDynDash }

# ============================================================================
# MS Failover Cluster Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'MSCluster' `
    -MatchAttribute 'DiscoveryHelper.MSCluster' `
    -AuthType 'BasicAuth' `
    -DefaultPort 135 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items   = @()
        $targets = @($ctx.DeviceIP)

        # MSCluster_Node / MSCluster_Resource / MSCluster_ResourceGroup state values
        $nodeStateMap = @{
            -1 = 'Unknown'; 0 = 'Up'; 1 = 'Down'; 2 = 'Paused'; 3 = 'Joining'
        }
        $resourceStateMap = @{
            -1 = 'Unknown'; 0 = 'Inherited'; 1 = 'Initializing'; 2 = 'Online'; 3 = 'Offline'
            4 = 'Failed'; 128 = 'Pending'; 129 = 'OnlinePending'; 130 = 'OfflinePending'
        }
        $groupStateMap = @{
            -1 = 'Unknown'; 0 = 'Online'; 1 = 'Offline'; 2 = 'Failed'; 3 = 'PartialOnline'; 4 = 'Pending'
        }

        # Perf counter members that carry no monitoring value. WMI system properties
        # (__GENUS and friends) and the PowerShell adapter members are filtered too.
        $skipProperties = @(
            'Caption', 'Description', 'Name', 'PSComputerName',
            'Frequency_Object', 'Frequency_PerfTime', 'Frequency_Sys100NS',
            'Timestamp_Object', 'Timestamp_PerfTime', 'Timestamp_Sys100NS',
            'Scope', 'Path', 'Options', 'ClassPath', 'Properties', 'SystemProperties',
            'Qualifiers', 'Site', 'Container'
        )

        # --- Resolve credential (same shapes the other WMI providers accept) ---
        $cred = $null
        if ($ctx.Credential -and $ctx.Credential.PSCredential -and $ctx.Credential.PSCredential -is [PSCredential]) {
            $cred = $ctx.Credential.PSCredential
        }
        elseif ($ctx.Credential -and $ctx.Credential.Username -and $ctx.Credential.Password) {
            $secPwd = ConvertTo-SecureString $ctx.Credential.Password -AsPlainText -Force
            $cred = [PSCredential]::new($ctx.Credential.Username, $secPwd)
        }
        elseif ($ctx.Credential -and $ctx.Credential -is [PSCredential]) {
            $cred = $ctx.Credential
        }

        # --- Connect to root\MSCluster over CIM ---
        # Get-WmiObject returns the embedded PrivateProperties object as an empty
        # string, which silently loses every virtual IP, virtual name and SQL
        # instance name. CIM materialises it properly, so the cluster inventory
        # goes over a CIM session. DCOM is tried first because WSMan needs
        # Kerberos or an HTTPS/TrustedHosts setup that clusters often lack.
        function Connect-MSClusterCim {
            param([string]$Target, [PSCredential]$Cred)

            $isLocal = ($Target -eq 'localhost' -or $Target -eq '.' -or $Target -eq '127.0.0.1' -or
                        $Target -eq '::1' -or $Target -eq $env:COMPUTERNAME)
            if ($isLocal) { return @{ Session = $null; IsLocal = $true; Method = 'Local' } }

            foreach ($proto in @('Dcom', 'Wsman')) {
                try {
                    $opt = New-CimSessionOption -Protocol $proto
                    $s = New-CimSession -ComputerName $Target -Credential $Cred -SessionOption $opt -ErrorAction Stop
                    return @{ Session = $s; IsLocal = $false; Method = $proto }
                }
                catch {
                    Write-Verbose "CIM $proto to ${Target} failed: $($_.Exception.Message)"
                }
            }
            return $null
        }

        function Get-MSClusterInstance {
            param($Conn, [string]$Class, [int]$Retries = 3)
            $splat = @{ Namespace = 'root\MSCluster'; ClassName = $Class; ErrorAction = 'Stop' }
            if ($Conn -and $Conn.Session) { $splat.CimSession = $Conn.Session }

            # DCOM to a cluster intermittently returns "The remote procedure call
            # failed", so a single failure is not treated as an empty class.
            $lastError = $null
            for ($attempt = 1; $attempt -le $Retries; $attempt++) {
                try { return @(Get-CimInstance @splat) }
                catch {
                    $lastError = $_
                    Write-Verbose "$Class attempt $attempt/$Retries failed: $($_.Exception.Message)"
                    if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (400 * $attempt) }
                }
            }
            throw $lastError
        }

        function Get-MSClusterQueryResult {
            param($Conn, [string]$Query, [int]$Retries = 3)
            $splat = @{ Namespace = 'root\MSCluster'; Query = $Query; ErrorAction = 'Stop' }
            if ($Conn -and $Conn.Session) { $splat.CimSession = $Conn.Session }

            $lastError = $null
            for ($attempt = 1; $attempt -le $Retries; $attempt++) {
                try { return @(Get-CimInstance @splat) }
                catch {
                    $lastError = $_
                    if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (400 * $attempt) }
                }
            }
            throw $lastError
        }

        # --- Build a WMI splat for a target (omits ComputerName/Credential locally) ---
        function New-MSClusterWmiSplat {
            param([string]$Target, [PSCredential]$Cred, [string]$Namespace = 'root\MSCluster')

            $isLocal = ($Target -eq 'localhost' -or $Target -eq '.' -or $Target -eq '127.0.0.1' -or
                        $Target -eq '::1' -or $Target -eq $env:COMPUTERNAME)

            $splat = @{ Namespace = $Namespace; ErrorAction = 'Stop' }
            if (-not $isLocal) {
                $splat.ComputerName = $Target
                if ($Cred) { $splat.Credential = $Cred }
            }
            return $splat
        }

        # --- Read a property off an embedded WMI object without throwing ---
        function Get-MSClusterPrivateProp {
            param($Resource, [string]$PropertyName)
            $value = $null
            try { $value = $Resource.PrivateProperties.$PropertyName } catch { }
            if ($null -eq $value) { return $null }
            return [string]$value
        }

        function ConvertTo-MSClusterStateText {
            param([hashtable]$Map, $Value)
            if ($null -eq $Value) { return 'Unknown' }
            $key = [int]$Value
            if ($Map.ContainsKey($key)) { return $Map[$key] }
            return "State$key"
        }

        # --- Read a set of properties off a WMI object, skipping any that the
        #     build does not expose. Returns an ordered name -> string map. ---
        function Get-MSClusterProps {
            param($Object, [string[]]$Names)

            $out = [ordered]@{}
            if (-not $Object) { return $out }

            $available = @{}
            foreach ($p in $Object.PSObject.Properties) {
                if ($p.MemberType -eq 'Property') { $available[$p.Name] = $true }
            }

            foreach ($n in $Names) {
                if (-not $available.ContainsKey($n)) { continue }
                $v = $null
                try { $v = $Object.$n } catch { continue }
                if ($null -eq $v) { continue }
                if ($v -is [System.Array]) { $v = ($v -join ',') }
                $s = ([string]$v).Trim()
                if ($s -eq '') { continue }
                $out[$n] = $s
            }
            return $out
        }

        # --- Flatten a property map into "Key=Value; Key=Value" ---
        function ConvertTo-MSClusterSummary {
            param([System.Object]$Map, [string[]]$Order)
            if (-not $Map -or $Map.Count -eq 0) { return $null }
            $parts = @()
            $keys = if ($Order) { $Order } else { @($Map.Keys) }
            foreach ($k in $keys) {
                if (-not $Map.Contains($k)) { continue }
                $parts += "$k=$($Map[$k])"
            }
            if ($parts.Count -eq 0) { return $null }
            return ($parts -join '; ')
        }

        # --- Nodes associated with a cluster object (preferred / possible owners) ---
        function Get-MSClusterAssociatedNode {
            param($Conn, [string]$SourceClass, [string]$SourceName)
            $names = @()
            if (-not $SourceName) { return $names }
            try {
                $escaped = $SourceName.Replace('\', '\\').Replace("'", "\'")
                $q = "ASSOCIATORS OF {${SourceClass}.Name='${escaped}'} WHERE ResultClass=MSCluster_Node"
                $names = @(Get-MSClusterQueryResult -Conn $Conn -Query $q | ForEach-Object { [string]$_.Name })
            }
            catch {
                Write-Verbose "Associator query failed for ${SourceClass} '${SourceName}': $($_.Exception.Message)"
            }
            return $names
        }

        # ================================================================
        # Phase 1: Confirm the target is a cluster node, then enumerate
        # ================================================================
        # Invoke-Discovery calls this script once per target, so $targets holds a
        # single host. One node returns the whole cluster; the setup script is
        # responsible for not re-scanning a cluster it has already seen.
        $clusterName = $null
        $seedTarget  = $null
        $conn        = $null
        $clusterObj  = $null

        foreach ($t in $targets) {
            if (-not $t) { continue }
            Write-Host "    Connecting to $t ..." -ForegroundColor DarkGray -NoNewline
            $tryConn = Connect-MSClusterCim -Target $t -Cred $cred
            if (-not $tryConn) {
                Write-Host " no CIM connection" -ForegroundColor DarkYellow
                continue
            }
            Write-Host " $($tryConn.Method)" -ForegroundColor Green -NoNewline

            Write-Host " | reading root\MSCluster ..." -ForegroundColor DarkGray -NoNewline
            try {
                $clusterObj = Get-MSClusterInstance -Conn $tryConn -Class MSCluster_Cluster | Select-Object -First 1
                if ($clusterObj) {
                    $seedTarget  = $t
                    $conn        = $tryConn
                    $clusterName = [string]$clusterObj.Name
                    Write-Host " OK ($clusterName)" -ForegroundColor Green
                    break
                }
                Write-Host " no cluster" -ForegroundColor DarkYellow
            }
            catch {
                Write-Host " unreachable" -ForegroundColor DarkYellow
                Write-Verbose "root\MSCluster on $t : $($_.Exception.Message)"
            }
            if ($tryConn.Session) { Remove-CimSession $tryConn.Session -ErrorAction SilentlyContinue }
        }

        if (-not $clusterObj) {
            Write-Verbose "No failover cluster reachable on: $($targets -join ', ')."
            return $items
        }

        # --- Cluster-wide properties ---
        $quorumPath = $null
        $quorumType = $null
        try { $quorumPath = [string]$clusterObj.QuorumPath } catch { }
        try { $quorumType = [string]$clusterObj.QuorumType } catch { }
        $clusterFunctionalLevel = $null
        try { $clusterFunctionalLevel = [string]$clusterObj.ClusterFunctionalLevel } catch { }

        # Deeper cluster configuration. Property availability varies by OS build,
        # so anything missing is simply left out.
        $clusterCfg = Get-MSClusterProps -Object $clusterObj -Names @(
            'Fqdn', 'Description', 'ClusterFunctionalLevel', 'ClusterUpgradeVersion',
            'AdminAccessPoint', 'DynamicQuorumEnable', 'WitnessDynamicWeight',
            'PreventQuorum', 'EnableSharedVolumes', 'SharedVolumesRoot',
            'S2DEnabled', 'S2DCacheDesiredState', 'BlockCacheSize',
            'SameSubnetDelay', 'SameSubnetThreshold', 'CrossSubnetDelay', 'CrossSubnetThreshold',
            'RouteHistoryLength', 'RequestReplyTimeout',
            'QuorumArbitrationTimeMax', 'QuorumArbitrationTimeMin',
            'DefaultNetworkRole', 'CsvBalancer', 'DrainOnShutdown'
        )

        $heartbeatSummary = ConvertTo-MSClusterSummary -Map $clusterCfg -Order @(
            'SameSubnetDelay', 'SameSubnetThreshold', 'CrossSubnetDelay', 'CrossSubnetThreshold', 'RouteHistoryLength'
        )
        $clusterFqdn = if ($clusterCfg.Contains('Fqdn')) { $clusterCfg['Fqdn'] } else { $null }

        Write-Host "    Reading cluster configuration ..." -ForegroundColor DarkGray
        # --- Resource types installed on the cluster ---
        $resourceTypes = @()
        try {
            $resourceTypes = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_ResourceType |
                ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
        }
        catch {
            Write-Verbose "Could not enumerate MSCluster_ResourceType: $($_.Exception.Message)"
        }

        # --- Disks presented to the cluster but not yet in use ---
        $availableDisks = @()
        try {
            $availableDisks = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_AvailableDisk |
                ForEach-Object { [string]$_.Name } | Where-Object { $_ })
        }
        catch {
            Write-Verbose "MSCluster_AvailableDisk unavailable: $($_.Exception.Message)"
        }

        Write-Host "    Reading nodes ..." -ForegroundColor DarkGray
        # --- Nodes ---
        $nodes = @()
        try {
            $nodes = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_Node)
        }
        catch {
            Write-Warning "Could not enumerate cluster nodes: $($_.Exception.Message)"
        }
        $nodeNames = @($nodes | ForEach-Object { [string]$_.Name })

        # Without nodes there is nothing to build a plan from, and continuing would
        # quietly emit an empty result that looks like a healthy "nothing to do".
        if ($nodes.Count -eq 0) {
            Write-Error "Connected to cluster '$clusterName' but could not enumerate its nodes. This is usually a transient DCOM/RPC failure - re-run, or check RPC connectivity and permissions on $seedTarget."
            if ($conn -and $conn.Session) { Remove-CimSession $conn.Session -ErrorAction SilentlyContinue }
            return $items
        }

        # --- Per-node build and drain detail ---
        $nodeDetail = @{}
        foreach ($n in $nodes) {
            $nName = [string]$n.Name
            $np = Get-MSClusterProps -Object $n -Names @(
                'NodeName', 'Description', 'MajorVersion', 'MinorVersion', 'BuildNumber',
                'CSDVersion', 'NodeHighestVersion', 'NodeLowestVersion',
                'NodeDrainStatus', 'NodeDrainTarget', 'StatusInformation', 'NeedsPreventQuorum'
            )

            $build = $null
            if ($np.Contains('MajorVersion') -and $np.Contains('MinorVersion') -and $np.Contains('BuildNumber')) {
                $build = "$($np['MajorVersion']).$($np['MinorVersion']).$($np['BuildNumber'])"
            }
            elseif ($np.Contains('BuildNumber')) {
                $build = $np['BuildNumber']
            }

            $nodeDetail[$nName] = @{
                Build       = $build
                DrainStatus = if ($np.Contains('NodeDrainStatus')) { $np['NodeDrainStatus'] } else { $null }
                Status      = if ($np.Contains('StatusInformation')) { $np['StatusInformation'] } else { $null }
                Description = if ($np.Contains('Description')) { $np['Description'] } else { $null }
            }
        }

        # A mixed-build cluster is supported only during a rolling upgrade.
        $distinctBuilds = @($nodeDetail.Values | ForEach-Object { $_.Build } | Where-Object { $_ } | Sort-Object -Unique)
        if ($distinctBuilds.Count -gt 1) {
            Write-Warning "Cluster '$clusterName' nodes are running different builds ($($distinctBuilds -join ', ')). Expected only during a rolling upgrade."
        }

        # --- Node IPs from cluster network interfaces ---
        $nodeIPs = @{}
        try {
            foreach ($ni in @(Get-MSClusterInstance -Conn $conn -Class MSCluster_NetworkInterface)) {
                $niNode = [string]$ni.Node
                $niAddr = [string]$ni.Address
                if (-not $niNode -or -not $niAddr) { continue }
                if ($niAddr -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { continue }
                if (-not $nodeIPs.ContainsKey($niNode)) { $nodeIPs[$niNode] = $niAddr }
            }
        }
        catch {
            Write-Verbose "Could not enumerate MSCluster_NetworkInterface: $($_.Exception.Message)"
        }

        # Fall back to DNS for any node without a cluster-network IP
        foreach ($nn in $nodeNames) {
            if ($nodeIPs.ContainsKey($nn)) { continue }
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($nn) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                if ($resolved) { $nodeIPs[$nn] = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "DNS resolution failed for node ${nn}: $($_.Exception.Message)"
            }
        }

        # --- Cluster networks ---
        # Role: 0 = disabled, 1 = cluster (heartbeat) only, 2 = client only, 3 = both
        $networkRoleMap = @{ 0 = 'Disabled'; 1 = 'ClusterOnly'; 2 = 'ClientOnly'; 3 = 'ClusterAndClient' }
        Write-Host "    Reading networks ..." -ForegroundColor DarkGray
        $clusterNetworks = @()
        try {
            $clusterNetworks = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_Network | ForEach-Object {
                $np = Get-MSClusterProps -Object $_ -Names @('AddressMask', 'Metric', 'AutoMetric', 'Description')
                $roleVal = $null
                try { $roleVal = [int]$_.Role } catch { }
                [PSCustomObject]@{
                    Name        = [string]$_.Name
                    Address     = [string]$_.Address
                    AddressMask = if ($np.Contains('AddressMask')) { $np['AddressMask'] } else { $null }
                    Role        = $roleVal
                    RoleText    = if ($null -ne $roleVal -and $networkRoleMap.ContainsKey($roleVal)) { $networkRoleMap[$roleVal] } else { 'Unknown' }
                    Metric      = if ($np.Contains('Metric')) { $np['Metric'] } else { $null }
                    State       = [int]$_.State
                }
            })
        }
        catch {
            Write-Verbose "Could not enumerate MSCluster_Network: $($_.Exception.Message)"
        }

        $heartbeatNets = @($clusterNetworks | Where-Object { $_.Role -eq 1 -or $_.Role -eq 3 })
        if ($heartbeatNets.Count -eq 1 -and $clusterNetworks.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' has only one cluster-enabled network ($($heartbeatNets[0].Name)). Intra-cluster communication has no redundant path."
        }
        elseif ($heartbeatNets.Count -eq 0 -and $clusterNetworks.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' has no network enabled for cluster communication."
        }

        # --- Cluster shared volumes ---
        Write-Host "    Reading shared volumes ..." -ForegroundColor DarkGray
        $csvVolumes = @()
        try {
            $csvVolumes = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_ClusterSharedVolume | ForEach-Object {
                $cp = Get-MSClusterProps -Object $_ -Names @(
                    'VolumeFriendlyName', 'RedirectedAccess', 'MaintenanceMode', 'FaultState',
                    'BackupState', 'BlockRedirectedIOReason', 'FileSystemRedirectedIOReason'
                )
                [PSCustomObject]@{
                    Name             = [string]$_.Name
                    VolumeName       = [string]$_.VolumeName
                    FriendlyName     = if ($cp.Contains('VolumeFriendlyName')) { $cp['VolumeFriendlyName'] } else { $null }
                    State            = [int]$_.State
                    RedirectedAccess = if ($cp.Contains('RedirectedAccess')) { $cp['RedirectedAccess'] } else { $null }
                    MaintenanceMode  = if ($cp.Contains('MaintenanceMode')) { $cp['MaintenanceMode'] } else { $null }
                    FaultState       = if ($cp.Contains('FaultState')) { $cp['FaultState'] } else { $null }
                    BackupState      = if ($cp.Contains('BackupState')) { $cp['BackupState'] } else { $null }
                }
            })
        }
        catch {
            Write-Verbose "MSCluster_ClusterSharedVolume unavailable: $($_.Exception.Message)"
        }

        # Redirected I/O routes every write through the coordinator node and is a
        # well known throughput cliff, so it is worth saying out loud.
        $redirectedCsv = @($csvVolumes | Where-Object { $_.RedirectedAccess -eq 'True' -or $_.RedirectedAccess -eq '1' })
        if ($redirectedCsv.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' CSV(s) in redirected access mode: $(@($redirectedCsv | ForEach-Object { $_.Name }) -join ', ')"
        }
        $maintCsv = @($csvVolumes | Where-Object { $_.MaintenanceMode -eq 'True' -or $_.MaintenanceMode -eq '1' })
        if ($maintCsv.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' CSV(s) in maintenance mode: $(@($maintCsv | ForEach-Object { $_.Name }) -join ', ')"
        }

        # --- Cluster disks (capacity is a common cluster outage cause) ---
        Write-Host "    Reading cluster disks ..." -ForegroundColor DarkGray
        $clusterDisks = @()
        try {
            $clusterDisks = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_DiskPartition | ForEach-Object {
                $totalMB = 0
                $freeMB  = 0
                try { $totalMB = [double]$_.TotalSize } catch { }
                try { $freeMB = [double]$_.FreeSpace } catch { }
                $dp = Get-MSClusterProps -Object $_ -Names @('FileSystem', 'SerialNumber', 'PartitionNumber', 'MountPoints')
                [PSCustomObject]@{
                    Path        = [string]$_.Path
                    VolumeLabel = [string]$_.VolumeLabel
                    FileSystem  = if ($dp.Contains('FileSystem')) { $dp['FileSystem'] } else { $null }
                    MountPoints = if ($dp.Contains('MountPoints')) { $dp['MountPoints'] } else { $null }
                    TotalMB     = $totalMB
                    FreeMB      = $freeMB
                    PercentFree = if ($totalMB -gt 0) { [Math]::Round(($freeMB / $totalMB) * 100, 1) } else { $null }
                }
            })
        }
        catch {
            Write-Verbose "MSCluster_DiskPartition unavailable: $($_.Exception.Message)"
        }

        # --- Resources, grouped by owning resource group ---
        Write-Host "    Reading resources ..." -ForegroundColor DarkGray
        $resources = @()
        try {
            $resources = @(Get-MSClusterInstance -Conn $conn -Class MSCluster_Resource)
        }
        catch {
            Write-Warning "Could not enumerate cluster resources: $($_.Exception.Message)"
        }

        $groupData = [ordered]@{}
        foreach ($res in $resources) {
            $grp = [string]$res.OwnerGroup
            if (-not $grp) { continue }
            if (-not $groupData.Contains($grp)) {
                $groupData[$grp] = [ordered]@{
                    GroupName    = $grp
                    Kind         = 'Other'
                    NetworkNames = [System.Collections.Generic.List[string]]::new()
                    VirtualIPs   = [System.Collections.Generic.List[string]]::new()
                    OnlineIPs    = [System.Collections.Generic.List[string]]::new()
                    SqlInstances = [System.Collections.Generic.List[string]]::new()
                    AGNames      = [System.Collections.Generic.List[string]]::new()
                    Resources    = [System.Collections.Generic.List[object]]::new()
                    OwnerNode    = [string]$res.OwnerNode
                }
            }
            $g       = $groupData[$grp]
            $resType = [string]$res.Type
            $resName = [string]$res.Name

            $rp = Get-MSClusterProps -Object $res -Names @(
                'RestartAction', 'RestartThreshold', 'RestartPeriod', 'RestartDelay',
                'IsAlivePollInterval', 'LooksAlivePollInterval', 'PendingTimeout', 'DeadlockTimeout',
                'PersistentState', 'SeparateMonitor', 'CoreResource', 'Description',
                'StatusInformation', 'LastOperationStatusCode', 'ResourceSpecificStatus'
            )

            $g.Resources.Add([PSCustomObject]@{
                Name       = $resName
                Type       = $resType
                State      = ConvertTo-MSClusterStateText -Map $resourceStateMap -Value $res.State
                OwnerNode  = [string]$res.OwnerNode
                Policy     = ConvertTo-MSClusterSummary -Map $rp -Order @('RestartAction', 'RestartThreshold', 'RestartPeriod', 'IsAlivePollInterval', 'LooksAlivePollInterval')
                CoreRes    = if ($rp.Contains('CoreResource')) { $rp['CoreResource'] } else { $null }
                StatusInfo = if ($rp.Contains('StatusInformation')) { $rp['StatusInformation'] } else { $null }
            })

            if ($resType -like '*IP Address*') {
                $addr = Get-MSClusterPrivateProp -Resource $res -PropertyName 'Address'
                if ($addr -and -not $g.VirtualIPs.Contains($addr)) { $g.VirtualIPs.Add($addr) }
                # A multi-subnet role carries one IP per subnet but only the one for
                # the owning node's subnet is online, so that is the address to monitor.
                if ($addr -and ([int]$res.State) -eq 2 -and -not $g.OnlineIPs.Contains($addr)) {
                    $g.OnlineIPs.Add($addr)
                }
            }
            elseif ($resType -like '*Network Name*') {
                $nn = Get-MSClusterPrivateProp -Resource $res -PropertyName 'DnsName'
                if (-not $nn) { $nn = Get-MSClusterPrivateProp -Resource $res -PropertyName 'Name' }
                if (-not $nn) { $nn = $resName }
                if ($nn -and -not $g.NetworkNames.Contains($nn)) { $g.NetworkNames.Add($nn) }
                if ($resName -eq 'Cluster Name') { $g.Kind = 'ClusterCore' }
            }
            elseif ($resType -eq 'SQL Server') {
                $inst = Get-MSClusterPrivateProp -Resource $res -PropertyName 'InstanceName'
                $vs   = Get-MSClusterPrivateProp -Resource $res -PropertyName 'VirtualServerName'
                if (-not $inst) { $inst = 'MSSQLSERVER' }
                if (-not $g.SqlInstances.Contains($inst)) { $g.SqlInstances.Add($inst) }
                if ($vs -and -not $g.NetworkNames.Contains($vs)) { $g.NetworkNames.Add($vs) }
                $g.Kind = 'SqlFci'
            }
            elseif ($resType -like '*Availability Group*') {
                if ($resName -and -not $g.AGNames.Contains($resName)) { $g.AGNames.Add($resName) }
                if ($g.Kind -ne 'SqlFci') { $g.Kind = 'SqlAvailabilityGroup' }
            }
        }

        # --- Resource group states and failover policy ---
        Write-Host "    Reading resource groups and failover policy ..." -ForegroundColor DarkGray
        $groupStates = @{}
        try {
            foreach ($rg in @(Get-MSClusterInstance -Conn $conn -Class MSCluster_ResourceGroup)) {
                $rgName = [string]$rg.Name
                $gp = Get-MSClusterProps -Object $rg -Names @(
                    'AutoFailbackType', 'FailbackWindowStart', 'FailbackWindowEnd',
                    'FailoverPeriod', 'FailoverThreshold', 'Priority', 'PersistentState',
                    'AntiAffinityClassNames', 'ColdStartSetting', 'GroupType', 'IsCoreGroup',
                    'DefaultOwner', 'Description', 'StatusInformation'
                )

                $groupStates[$rgName] = @{
                    State          = ConvertTo-MSClusterStateText -Map $groupStateMap -Value $rg.State
                    OwnerNode      = [string]$rg.OwnerNode
                    FailoverPolicy = ConvertTo-MSClusterSummary -Map $gp -Order @('AutoFailbackType', 'FailoverThreshold', 'FailoverPeriod', 'Priority')
                    AntiAffinity   = if ($gp.Contains('AntiAffinityClassNames')) { $gp['AntiAffinityClassNames'] } else { $null }
                    GroupType      = if ($gp.Contains('GroupType')) { $gp['GroupType'] } else { $null }
                    Preferred      = @(Get-MSClusterAssociatedNode -Conn $conn -SourceClass 'MSCluster_ResourceGroup' -SourceName $rgName)
                }
            }
        }
        catch {
            Write-Verbose "Could not enumerate MSCluster_ResourceGroup: $($_.Exception.Message)"
        }

        $roles = @()
        foreach ($grpName in $groupData.Keys) {
            $g = $groupData[$grpName]
            $stateInfo = if ($groupStates.ContainsKey($grpName)) { $groupStates[$grpName] } else { $null }
            $ipv4 = @($g.VirtualIPs | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' })
            $ipv4Online = @($g.OnlineIPs | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' })
            $primary = if ($ipv4Online.Count -gt 0) { $ipv4Online[0] } elseif ($ipv4.Count -gt 0) { $ipv4[0] } else { $null }

            $roles += [PSCustomObject]@{
                GroupName    = $g.GroupName
                Kind         = $g.Kind
                VirtualName  = if ($g.NetworkNames.Count -gt 0) { $g.NetworkNames[0] } else { $null }
                NetworkNames = @($g.NetworkNames)
                VirtualIPs   = @($g.VirtualIPs)
                OnlineIPs    = @($g.OnlineIPs)
                PrimaryIP    = $primary
                SqlInstances = @($g.SqlInstances)
                AGNames      = @($g.AGNames)
                Resources    = @($g.Resources)
                State        = if ($stateInfo) { $stateInfo.State } else { 'Unknown' }
                OwnerNode    = if ($stateInfo -and $stateInfo.OwnerNode) { $stateInfo.OwnerNode } else { $g.OwnerNode }
                FailoverPolicy = if ($stateInfo) { $stateInfo.FailoverPolicy } else { $null }
                AntiAffinity   = if ($stateInfo) { $stateInfo.AntiAffinity } else { $null }
                GroupType      = if ($stateInfo) { $stateInfo.GroupType } else { $null }
                PreferredOwners = if ($stateInfo) { @($stateInfo.Preferred) } else { @() }
            }
        }

        Write-Host "    Cluster '$clusterName' (via $seedTarget): $($nodeNames.Count) node(s), $($roles.Count) role(s), $($resources.Count) resource(s), $($csvVolumes.Count) CSV(s), $($clusterNetworks.Count) network(s), $($clusterDisks.Count) disk(s), $($resourceTypes.Count) resource type(s)" -ForegroundColor Gray

        # ================================================================
        # Phase 1b: Quorum model and current health
        # ================================================================
        # A witness resource lives in the core cluster group. Its presence and the
        # sum of node vote weights decide whether the cluster survives a node loss.
        $witnessResources = @($resources | Where-Object { [string]$_.Type -like '*Witness*' })
        $witnessType  = if ($witnessResources.Count -gt 0) { [string]$witnessResources[0].Type } else { $null }
        $witnessState = if ($witnessResources.Count -gt 0) {
            ConvertTo-MSClusterStateText -Map $resourceStateMap -Value $witnessResources[0].State
        } else { $null }

        # NodeWeight is absent on older builds; a missing weight means the node votes.
        $totalVotes = 0
        $nodeWeights = @{}
        foreach ($n in $nodes) {
            $w = $null
            try { $w = $n.NodeWeight } catch { }
            $weight = if ($null -eq $w) { 1 } else { [int]$w }
            $nodeWeights[[string]$n.Name] = $weight
            $totalVotes += $weight
        }
        $witnessVotes = if ($witnessResources.Count -gt 0) { 1 } else { 0 }
        $quorumVotes  = $totalVotes + $witnessVotes

        if ($witnessResources.Count -eq 0 -and ($totalVotes % 2) -eq 0 -and $totalVotes -gt 0) {
            Write-Warning "Cluster '$clusterName' has $totalVotes voting node(s) and no witness resource. An even vote count without a witness cannot survive the loss of half the nodes."
        }
        elseif ($witnessState -and $witnessState -ne 'Online') {
            Write-Warning "Cluster '$clusterName' witness ($witnessType) is '$witnessState'. Quorum is degraded."
        }

        # --- Current health: anything not in its normal state is worth saying out loud ---
        $unhealthyNodes = @($nodes | Where-Object {
            (ConvertTo-MSClusterStateText -Map $nodeStateMap -Value $_.State) -ne 'Up'
        } | ForEach-Object {
            "$($_.Name) ($(ConvertTo-MSClusterStateText -Map $nodeStateMap -Value $_.State))"
        })
        if ($unhealthyNodes.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' node(s) not Up: $($unhealthyNodes -join ', ')"
        }

        $drainingNodes = @($nodeDetail.Keys | Where-Object {
            $ds = $nodeDetail[$_].DrainStatus
            $ds -and $ds -ne '0' -and $ds -ne 'NotInitiated'
        } | ForEach-Object { "$_ ($($nodeDetail[$_].DrainStatus))" })
        if ($drainingNodes.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' node(s) draining or drained: $($drainingNodes -join ', ')"
        }

        $unhealthyRoles = @($roles | Where-Object { $_.State -ne 'Online' } |
            ForEach-Object { "$($_.GroupName) ($($_.State))" })
        if ($unhealthyRoles.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' role(s) not Online: $($unhealthyRoles -join ', ')"
        }

        $lowDisks = @($clusterDisks | Where-Object { $null -ne $_.PercentFree -and $_.PercentFree -lt 10 } |
            ForEach-Object { "$($_.Path) $($_.PercentFree)% free" })
        if ($lowDisks.Count -gt 0) {
            Write-Warning "Cluster '$clusterName' disk(s) below 10% free: $($lowDisks -join ', ')"
        }

        # ================================================================
        # Phase 2 + 2.5: Discover cluster perf counter classes, then keep
        # only the properties that actually return numeric data.
        # ================================================================
        # Counters are enumerated per node because roles installed on one node
        # (S2D, CSV, SQL) add classes the other nodes may not have.
        $nodeCounters = @{}   # nodeName -> @( @{ Class; Property; Instances } )

        $nodeIndex = 0
        foreach ($nodeName in $nodeNames) {
            $nodeIndex++
            $nodeSw = [System.Diagnostics.Stopwatch]::StartNew()
            $probeTarget = if ($nodeIPs.ContainsKey($nodeName)) { $nodeIPs[$nodeName] } else { $nodeName }
            $cimvSplat = $null
            try { $cimvSplat = New-MSClusterWmiSplat -Target $probeTarget -Cred $cred -Namespace 'root\cimv2' }
            catch { continue }

            Write-Host "    [$nodeIndex/$($nodeNames.Count)] ${nodeName} ($probeTarget): listing cluster performance classes ..." -ForegroundColor DarkGray
            Write-Progress -Activity 'MS Cluster discovery' -Status "Listing performance classes on $nodeName" -PercentComplete 0

            $classNames = @()
            try {
                $classNames = @(Get-WmiObject -List @cimvSplat |
                    Where-Object { $_.Name -like 'Win32_PerfFormattedData_*' -and $_.Name -like '*Clus*' } |
                    ForEach-Object { $_.Name } | Sort-Object)
            }
            catch {
                Write-Warning "    Could not enumerate performance classes on ${nodeName}: $($_.Exception.Message)"
                continue
            }

            if ($classNames.Count -eq 0) {
                Write-Host "    ${nodeName}: no cluster performance counter classes found." -ForegroundColor DarkYellow
                continue
            }

            Write-Host "        $($classNames.Count) class(es) found, validating which return data ..." -ForegroundColor DarkGray
            $validated = [System.Collections.Generic.List[object]]::new()
            $classIndex = 0

            foreach ($className in $classNames) {
                $classIndex++
                $pct = [Math]::Round(($classIndex / $classNames.Count) * 100)
                Write-Progress -Activity 'MS Cluster discovery' `
                    -Status "${nodeName}: validating counters [$classIndex/$($classNames.Count)]" `
                    -CurrentOperation $className -PercentComplete $pct

                $rows = @()
                try {
                    $rows = @(Get-WmiObject -Query "Select * from $className" @cimvSplat)
                }
                catch {
                    Write-Verbose "    $className unavailable on ${nodeName}: $($_.Exception.Message)"
                    continue
                }
                if ($rows.Count -eq 0) { continue }

                # Instance names, when the class is instanced
                $instances = @()
                foreach ($row in $rows) {
                    $iname = $null
                    try { $iname = [string]$row.Name } catch { }
                    if ($iname -and $instances -notcontains $iname) { $instances += $iname }
                }

                # Keep only properties that exist and hold a numeric value somewhere.
                # ManagementObject.Properties does not enumerate through the PS adapter,
                # so read the member list off PSObject instead.
                $goodProps = @()
                $candidateNames = @($rows[0].PSObject.Properties |
                    Where-Object { $_.MemberType -eq 'Property' } |
                    ForEach-Object { $_.Name })

                foreach ($pName in $candidateNames) {
                    if ($pName -like '__*') { continue }
                    if ($skipProperties -contains $pName) { continue }

                    $hasNumeric = $false
                    foreach ($row in $rows) {
                        $val = $row.$pName
                        if ($null -eq $val) { continue }
                        $parsed = 0.0
                        if ([double]::TryParse([string]$val, [ref]$parsed)) { $hasNumeric = $true; break }
                    }
                    if ($hasNumeric) { $goodProps += $pName }
                }

                foreach ($gp in $goodProps) {
                    $validated.Add([PSCustomObject]@{
                        Class     = $className
                        Property  = $gp
                        Instances = $instances
                    })
                }
            }

            $nodeCounters[$nodeName] = @($validated)
            $nodeSw.Stop()
            Write-Host "        ${nodeName}: $($classNames.Count) class(es), $($validated.Count) validated counter(s) in $([Math]::Round($nodeSw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Gray
        }
        Write-Progress -Activity 'MS Cluster discovery' -Completed

        # ================================================================
        # Phase 3: Build the monitor plan
        # ================================================================
        $roleSummary = @($roles | Where-Object { $_.VirtualName } | ForEach-Object { $_.VirtualName }) -join ','
        $csvSummary  = @($csvVolumes | ForEach-Object {
            $flags = @()
            if ($_.RedirectedAccess -eq 'True' -or $_.RedirectedAccess -eq '1') { $flags += 'redirected' }
            if ($_.MaintenanceMode -eq 'True' -or $_.MaintenanceMode -eq '1') { $flags += 'maintenance' }
            if ($flags.Count -gt 0) { "$($_.Name) [$($flags -join '/')]" } else { $_.Name }
        }) -join ','
        $netSummary  = @($clusterNetworks | ForEach-Object {
            $bits = @($_.Name)
            if ($_.Address) { $bits += "$($_.Address)" }
            $bits += $_.RoleText
            "$($bits -join ' ')"
        }) -join ','
        $diskSummary = @($clusterDisks | ForEach-Object {
            if ($null -ne $_.PercentFree) { "$($_.Path) $($_.PercentFree)% free" } else { $_.Path }
        }) -join ','
        $resTypeSummary = @($resourceTypes) -join ','
        $availDiskSummary = @($availableDisks) -join ','

        # Every role, including the ones with no virtual IP (VM roles, storage
        # groups). Those never become their own device, so this is the only place
        # they show up.
        $allRolesSummary = @($roles | ForEach-Object {
            $vip = if ($_.PrimaryIP) { $_.PrimaryIP } else { 'no-VIP' }
            "$($_.GroupName)|$($_.Kind)|$($_.State)|$($_.OwnerNode)|$vip"
        }) -join ';'

        $vipRoleCount = @($roles | Where-Object { $_.PrimaryIP }).Count
        Write-Host "    Roles: $($roles.Count) total, $vipRoleCount with a virtual IP (own device), $($roles.Count - $vipRoleCount) without (live on their owner node)" -ForegroundColor Gray

        # --- NODE devices: node-local resources ---
        foreach ($node in $nodes) {
            $nodeName  = [string]$node.Name
            $nodeIP    = if ($nodeIPs.ContainsKey($nodeName)) { $nodeIPs[$nodeName] } else { $null }
            $nodeState = ConvertTo-MSClusterStateText -Map $nodeStateMap -Value $node.State

            $nodeAttrs = @{
                'MSCluster.DeviceType'   = 'Node'
                'MSCluster.ClusterName'  = "$clusterName"
                'MSCluster.NodeName'     = "$nodeName"
                'MSCluster.NodeState'    = "$nodeState"
                'MSCluster.Nodes'        = "$($nodeNames -join ',')"
                'MSCluster.Roles'        = "$roleSummary"
                'MSCluster.NodeVote'     = "$(if ($nodeWeights.ContainsKey($nodeName)) { $nodeWeights[$nodeName] } else { 1 })"
                'MSCluster.QuorumVotes'  = "$quorumVotes"
            }
            if ($nodeIP)                 { $nodeAttrs['MSCluster.NodeIP'] = "$nodeIP" }
            if ($quorumType)             { $nodeAttrs['MSCluster.QuorumType'] = "$quorumType" }
            if ($quorumPath)             { $nodeAttrs['MSCluster.QuorumPath'] = "$quorumPath" }
            if ($witnessType)            { $nodeAttrs['MSCluster.WitnessType'] = "$witnessType" }
            if ($witnessState)           { $nodeAttrs['MSCluster.WitnessState'] = "$witnessState" }
            if ($clusterFunctionalLevel) { $nodeAttrs['MSCluster.FunctionalLevel'] = "$clusterFunctionalLevel" }
            if ($clusterFqdn)            { $nodeAttrs['MSCluster.Fqdn'] = "$clusterFqdn" }
            if ($csvSummary)             { $nodeAttrs['MSCluster.SharedVolumes'] = "$csvSummary" }
            if ($netSummary)             { $nodeAttrs['MSCluster.Networks'] = "$netSummary" }
            if ($diskSummary)            { $nodeAttrs['MSCluster.ClusterDisks'] = "$diskSummary" }
            if ($resTypeSummary)         { $nodeAttrs['MSCluster.ResourceTypes'] = "$resTypeSummary" }
            if ($availDiskSummary)       { $nodeAttrs['MSCluster.AvailableDisks'] = "$availDiskSummary" }
            if ($heartbeatSummary)       { $nodeAttrs['MSCluster.HeartbeatTuning'] = "$heartbeatSummary" }
            if ($allRolesSummary)        { $nodeAttrs['MSCluster.AllRoles'] = "$allRolesSummary" }
            if ($clusterCfg.Contains('DynamicQuorumEnable')) { $nodeAttrs['MSCluster.DynamicQuorum'] = "$($clusterCfg['DynamicQuorumEnable'])" }
            if ($clusterCfg.Contains('S2DEnabled'))          { $nodeAttrs['MSCluster.S2DEnabled'] = "$($clusterCfg['S2DEnabled'])" }
            if ($clusterCfg.Contains('SharedVolumesRoot'))   { $nodeAttrs['MSCluster.SharedVolumesRoot'] = "$($clusterCfg['SharedVolumesRoot'])" }

            $nd = $null
            if ($nodeDetail.ContainsKey($nodeName)) { $nd = $nodeDetail[$nodeName] }
            if ($nd) {
                if ($nd.Build)       { $nodeAttrs['MSCluster.NodeBuild'] = "$($nd.Build)" }
                if ($nd.DrainStatus) { $nodeAttrs['MSCluster.NodeDrainStatus'] = "$($nd.DrainStatus)" }
                if ($nd.Status)      { $nodeAttrs['MSCluster.NodeStatusInfo'] = "$($nd.Status)" }
            }

            $nodeTags = @('mscluster', 'node', $nodeName, $clusterName)

            # Cluster Service is the node's own participation in the cluster.
            $items += New-DiscoveredItem `
                -Name 'MSCluster - Cluster Service' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'Service' `
                -MonitorParams @{
                    ServiceDisplayName  = 'Cluster Service'
                    ServiceInternalName = 'ClusSvc'
                    ServiceUseSNMP      = 'false'
                    Description         = "Cluster Service (ClusSvc) on node $nodeName"
                } `
                -UniqueKey "mscluster:${clusterName}:node:${nodeName}:svc:clussvc" `
                -Attributes $nodeAttrs `
                -Tags $nodeTags

            # Validated cluster performance counters for this node
            $counters = @()
            if ($nodeCounters.ContainsKey($nodeName)) { $counters = @($nodeCounters[$nodeName]) }

            foreach ($ctr in $counters) {
                # Trim the Win32_PerfFormattedData_<provider>_ prefix for readable names
                $objectLabel = $ctr.Class
                if ($objectLabel -match '^Win32_PerfFormattedData_[^_]+_(.+)$') { $objectLabel = $Matches[1] }

                $instanceList = @($ctr.Instances)
                if ($instanceList.Count -eq 0) { $instanceList = @('') }

                foreach ($inst in $instanceList) {
                    $instLabel = if ($inst) { " ($inst)" } else { '' }
                    $instKey   = if ($inst) { $inst } else { 'default' }

                    $items += New-DiscoveredItem `
                        -Name "MSCluster - $objectLabel - $($ctr.Property)$instLabel" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'WmiFormatted' `
                        -MonitorParams @{
                            WmiFormattedRelativePath = $ctr.Class
                            WmiFormattedPropertyName = $ctr.Property
                            WmiFormattedDisplayname  = "$objectLabel \ $($ctr.Property)$instLabel"
                            WmiFormattedInstanceName = "$inst"
                            WmiFormattedTimeout      = 10
                            Description              = "$objectLabel $($ctr.Property)$instLabel on node $nodeName"
                        } `
                        -UniqueKey "mscluster:${clusterName}:node:${nodeName}:perf:$($ctr.Class):$($ctr.Property):${instKey}" `
                        -Attributes $nodeAttrs `
                        -Tags $nodeTags
                }
            }
        }

        # --- ROLE devices: the shared resource is the role's availability ---
        foreach ($role in $roles) {
            if (-not $role.PrimaryIP) { continue }

            $roleName = if ($role.VirtualName) { $role.VirtualName } else { $role.GroupName }

            $roleAttrs = @{
                'MSCluster.DeviceType'    = 'Role'
                'MSCluster.ClusterName'   = "$clusterName"
                'MSCluster.RoleKind'      = "$($role.Kind)"
                'MSCluster.ResourceGroup' = "$($role.GroupName)"
                'MSCluster.VirtualName'   = "$roleName"
                'MSCluster.VirtualIP'     = "$($role.VirtualIPs -join ',')"
                'MSCluster.PrimaryIP'     = "$($role.PrimaryIP)"
                'MSCluster.RoleState'     = "$($role.State)"
                'MSCluster.OwnerNode'     = "$($role.OwnerNode)"
                'MSCluster.Nodes'         = "$($nodeNames -join ',')"
            }
            if ($role.OnlineIPs -and $role.OnlineIPs.Count -gt 0) {
                $roleAttrs['MSCluster.OnlineVirtualIP'] = "$($role.OnlineIPs -join ',')"
            }
            if ($role.SqlInstances.Count -gt 0) {
                $roleAttrs['MSCluster.SqlInstance'] = "$($role.SqlInstances -join ',')"
            }
            if ($role.AGNames.Count -gt 0) {
                $roleAttrs['MSCluster.AvailabilityGroup'] = "$($role.AGNames -join ',')"
            }
            if ($role.FailoverPolicy)  { $roleAttrs['MSCluster.FailoverPolicy'] = "$($role.FailoverPolicy)" }
            if ($role.AntiAffinity)    { $roleAttrs['MSCluster.AntiAffinity'] = "$($role.AntiAffinity)" }
            if ($role.GroupType)       { $roleAttrs['MSCluster.GroupType'] = "$($role.GroupType)" }
            if ($role.PreferredOwners -and $role.PreferredOwners.Count -gt 0) {
                $roleAttrs['MSCluster.PreferredOwners'] = "$($role.PreferredOwners -join ',')"
            }
            if ($role.Resources.Count -gt 0) {
                $roleAttrs['MSCluster.Resources'] = "$(@($role.Resources | ForEach-Object { $_.Name }) -join ',')"
                $roleAttrs['MSCluster.ResourceTypesInUse'] = "$(@($role.Resources | ForEach-Object { $_.Type } | Sort-Object -Unique) -join ',')"

                $policyDetail = @($role.Resources | Where-Object { $_.Policy } |
                    ForEach-Object { "$($_.Name): $($_.Policy)" })
                if ($policyDetail.Count -gt 0) {
                    $roleAttrs['MSCluster.ResourcePolicy'] = "$($policyDetail -join ' | ')"
                }

                $badResources = @($role.Resources | Where-Object { $_.State -ne 'Online' } |
                    ForEach-Object { "$($_.Name) ($($_.State))" })
                if ($badResources.Count -gt 0) {
                    $roleAttrs['MSCluster.UnhealthyResources'] = "$($badResources -join ',')"
                    Write-Warning "Role '$($role.GroupName)' has resource(s) not Online: $($badResources -join ', ')"
                }
            }

            $roleTags = @('mscluster', 'role', $role.Kind, $roleName, $clusterName)

            $items += New-DiscoveredItem `
                -Name 'MSCluster - Role Availability' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'Ping' `
                -MonitorParams @{
                    PingPayloadSize = 32
                    Timeout         = 5
                    Retries         = 2
                    Description     = 'Availability of a clustered role virtual IP'
                } `
                -UniqueKey "mscluster:${clusterName}:role:$($role.GroupName):ping" `
                -Attributes $roleAttrs `
                -Tags $roleTags
        }

        Write-Host "    Plan: $(@($items | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) active, $(@($items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) performance item(s)" -ForegroundColor Gray

        if ($conn -and $conn.Session) { Remove-CimSession $conn.Session -ErrorAction SilentlyContinue }

        return $items
    }

# ============================================================================
# Dashboard
# ============================================================================

function Export-MSClusterDashboardHtml {
    <#
    .SYNOPSIS
        Renders the MS Failover Cluster discovery inventory as an HTML dashboard.
    .DESCRIPTION
        Thin wrapper over Export-DynamicDashboardHtml so the cluster inventory picks
        up the standard Bootstrap Table dashboard with search, sorting and exports.
    .PARAMETER DashboardData
        Flattened inventory rows produced by Setup-MSCluster-Discovery.ps1.
    .PARAMETER OutputPath
        Destination .html path.
    .PARAMETER ReportTitle
        Dashboard heading.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$DashboardData,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$ReportTitle = 'Microsoft Failover Cluster Inventory'
    )

    if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) {
        throw "Export-DynamicDashboardHtml is not loaded. Dot-source helpers/reports/Export-DynamicDashboardHtml.ps1 first."
    }

    Export-DynamicDashboardHtml -Data $DashboardData `
        -OutputPath $OutputPath `
        -ReportTitle $ReportTitle `
        -CardField @('Cluster', 'Kind') `
        -ExportPrefix 'MSCluster'

    return $OutputPath
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDJTk42gnUIVB8Q
# x4pEhc3DYuvyNr7AK0kzKU+wjkUdJaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCiVLcmTlYbl3mXTPoeQnYvuNqaAGKXsLVLfnSdh5wQ/TANBgkqhkiG9w0BAQEF
# AASCAgCJyj0BeT0kcDvnvOuK1rbsiDaIyv0uO6KqbMl7bLH1QyHRywUVdqbq99YW
# IrZhNYW+1vnkCA2PkZ2eRhtWr5n0+yBHxt3KoEkjd5bK/uIU9O00OZeAGOh8C6R+
# HqfPcQy92oBtVOYscfWaAvm6ocsozTMKkMxrFxjqNv+fsQ49ALszzA5KgT4sG6NC
# hS6f87mFBvTYSKEHFBH2/06Akx3H6NgpAb+7FPlPPMtzLE4rUxQAYAcNlIzkKbGC
# CYeE8EXc5aAumvkWGks0yRofaaet6+mPbpc6FbTK030/aR+AfJLwMNFrpjmBnruc
# rDKNJlh8uzuQT9Ems4b2T77BXLRwMbxp4Tj/CJdXRVPtKwMaJ6J/NQGY6zqYZW9Z
# jhcBV6+tHjuAno+cAFfXe6hNSbjbCJ0uwkTqIoYUmerYhH6nwF4UHxFVYiHeG7o/
# +Mak9cItAkB0RR1MwUvmRHbVe8xdBYEzP5+w3I+ObIzjbS1MX05A4QtpHLbCgIC6
# cWNF+drDGBQAyJNb4RzJ4zDqXtHxvOsEygQ6K8SxW3+4CeOojxxr4c/LM+ALQ4Fa
# 3YJA1tCu/Zmy8Cvc+hDvjNUUKN124g0JfOr0sl7W42huN8qekJOn8iOdXb5s+kw4
# 2xeL4AGaeXQp1y1hK5aKgIZ+2DT3w44OBB27/7lex/31XBiI6KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA4MjgyMjI1NDJaMC8GCSqGSIb3DQEJBDEiBCDd8Gw7
# At737bKyYIfZ0Hq4tQPsboCxsddE0S6nlQe/ATANBgkqhkiG9w0BAQEFAASCAgB1
# gnAR/5wPYAOuEdWqOGf5aF+7f/QzYSCVDBBmNEhxQKTDSmpAKr9N3xQxKuG1JGAA
# VpTQXpSTxfIV3/nnKkUeRsUJlmwnO1Lx1t0Qd5BnM4h3B0VJZ++37CE8IOFez/tV
# KxsCEhJ90pUHGjO68IMn2+iioQiM8k9CWbs3WzkHUbkKez4UIgzvLmkmBg1gac5k
# ZZSyDHgrOJuFyJE+KaG3SjcVNdlQqxsMyBSByYUmHaTDW7HFbXL0P5dct2Q/uwz7
# uEsmb33gG5Cw14Dbfah/QVHbt7CagV/8wQr74ZTp6W6O2WCTEPAz5UREiCPzYo9l
# rcxIHhHS8lGeF1AwDnjWy4voCYVuHD0B+PgJxDlzzMY/ugoJt66psW7MBjp/0BUT
# JtxogUvYBHWBe4lppXKu2VfmomkCrhsBCJnvGRtwRxzhRIsYbMdN2kRogymYv8lG
# 4QjXYwJZjZn1/BlgVyhMThxwyWj6SMAAprpAeHZZ9lwVEo/LT/a7LzzKR4VLUpwh
# asCt+8V/cft+ZuCTEVwW6o7mpykzvC904GQMlpXOugRuBngIwjOCmBvl1e2QRvCc
# ObrX4pF2BvFzZhv0FzZ59c8VFaJATXw4CRPkmmG5qm0Lg5HgPXCb8hTadumrrjvm
# vRja92/B/GKxM5fQebag2+Ttrco6+H5pAMBSt/uUmQ==
# SIG # End signature block
