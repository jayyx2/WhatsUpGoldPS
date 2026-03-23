<#
.SYNOPSIS
    Hyper-V discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers a Hyper-V discovery provider that uses CIM sessions to
    discover Hyper-V hosts and virtual machines, then builds a monitor
    plan suitable for WhatsUp Gold or standalone use.

    Discovery discovers:
      - Hyper-V hosts (IP, OS, CPU, Memory, Uptime)
      - Virtual machines (IP, State, CPU, Memory, Disks, NICs)

    Authentication:
      PSCredential (domain\user + password) via CIM sessions (WSMan).
      No external modules required — uses built-in Hyper-V PowerShell.

    Prerequisites:
      1. Hyper-V PowerShell module (installed with Hyper-V role or RSAT)
      2. WinRM/WSMan enabled on target hosts
      3. Credentials with Hyper-V Administrators or local admin access

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first, Hyper-V PowerShell module
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

# Ensure HypervHelpers is available
$hypervHelpersPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..\hyperv\HypervHelpers.ps1'
if (Test-Path $hypervHelpersPath) {
    . $hypervHelpersPath
}

# ============================================================================
# Hyper-V Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'HyperV' `
    -MatchAttribute 'DiscoveryHelper.HyperV' `
    -AuthType 'BasicAuth' `
    -DefaultPort 5985 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $targets = if ($ctx.DeviceIP -is [System.Collections.IEnumerable] -and $ctx.DeviceIP -isnot [string]) {
            @($ctx.DeviceIP)
        } else {
            @($ctx.DeviceIP)
        }

        # --- Resolve credential ---
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

        if (-not $cred) {
            Write-Warning "No valid Hyper-V credential available."
            return $items
        }

        # ================================================================
        # Phase 1: Connect to each host and enumerate VMs
        # ================================================================
        $hostMap = @{}  # hostName -> @{ IP; OS; CPUModel; RAMTotal; ... }
        $vmMap   = @{}  # "host:vmname" -> @{ ... }
        $clusterInfo = $null  # populated if any target belongs to a cluster

        # --- Helper: Connect to a remote target (WSMan -> DCOM -> WMI) ---
        # Returns @{ Session; ConnMethod; UseDirect }
        function Connect-HypervTarget {
            param([string]$Target, [PSCredential]$Cred)
            $result = @{ Session = $null; ConnMethod = $null; UseDirect = $false }

            Write-Host "    Trying WSMan to $Target..." -ForegroundColor DarkGray -NoNewline
            try {
                $opt = New-CimSessionOption -Protocol Wsman
                $result.Session = New-CimSession -ComputerName $Target -Credential $Cred -SessionOption $opt -ErrorAction Stop
                $result.ConnMethod = 'WSMan'
                Write-Host " OK" -ForegroundColor Green
                return $result
            } catch {
                Write-Host " failed" -ForegroundColor DarkYellow
                Write-Verbose "WSMan failed for $Target : $_"
            }

            Write-Host "    Trying DCOM to $Target..." -ForegroundColor DarkGray -NoNewline
            try {
                $opt = New-CimSessionOption -Protocol Dcom
                $result.Session = New-CimSession -ComputerName $Target -Credential $Cred -SessionOption $opt -ErrorAction Stop
                $result.ConnMethod = 'DCOM'
                $result.UseDirect = $true
                Write-Host " OK" -ForegroundColor Green
                return $result
            } catch {
                Write-Host " failed" -ForegroundColor DarkYellow
                Write-Verbose "DCOM failed for $Target : $_"
            }

            Write-Host "    Trying WMI to $Target..." -ForegroundColor DarkGray -NoNewline
            try {
                $test = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $Target -Credential $Cred -ErrorAction Stop
                if ($test) {
                    $result.ConnMethod = 'WMI'
                    $result.UseDirect = $true
                    Write-Host " OK" -ForegroundColor Green
                    return $result
                }
            } catch {
                Write-Host " failed" -ForegroundColor DarkYellow
            }

            return $null
        }

        # --- Helper: Gather host details ---
        function Get-TargetHostInfo {
            param([string]$Target, [PSCredential]$Cred, $Session, [bool]$UseDirect)
            if ($UseDirect) {
                $os  = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $Target -Credential $Cred
                $cs  = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $Target -Credential $Cred
                $cpu = Get-WmiObject -Class Win32_Processor -ComputerName $Target -Credential $Cred | Select-Object -First 1
            } else {
                $os  = Get-CimInstance -CimSession $Session -ClassName Win32_OperatingSystem
                $cs  = Get-CimInstance -CimSession $Session -ClassName Win32_ComputerSystem
                $cpu = Get-CimInstance -CimSession $Session -ClassName Win32_Processor | Select-Object -First 1
            }
            $hostIP = $null
            $netConfigs = $null
            try {
                if ($UseDirect) {
                    $netConfigs = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ComputerName $Target -Credential $Cred -Filter "IPEnabled = True"
                } else {
                    $netConfigs = Get-CimInstance -CimSession $Session -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True"
                }
                $hostIP = $netConfigs |
                    ForEach-Object { $_.IPAddress } |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
                    Select-Object -First 1
            } catch { }
            if (-not $hostIP) { $hostIP = $Target }

            # Resolve real hostname from Win32_ComputerSystem
            $resolvedName = if ($cs -and $cs.Name) { $cs.Name } else { $Target }

            # CPU topology
            $cpuCount = if ($UseDirect) {
                @(Get-WmiObject -Class Win32_Processor -ComputerName $Target -Credential $Cred).Count
            } else {
                @(Get-CimInstance -CimSession $Session -ClassName Win32_Processor).Count
            }

            # Host disks
            $hostDisks = @()
            try {
                if ($UseDirect) {
                    $hostDisks = @(Get-WmiObject -Class Win32_LogicalDisk -Filter 'DriveType = 3' -ComputerName $Target -Credential $Cred)
                } else {
                    $hostDisks = @(Get-CimInstance -CimSession $Session -ClassName Win32_LogicalDisk -Filter 'DriveType = 3')
                }
            } catch {}
            $diskParts = @()
            $diskTotalGB = 0
            $diskFreeGB  = 0
            foreach ($d in $hostDisks) {
                $dTotal = [math]::Round([long]$d.Size / 1GB, 0)
                $dFree  = [math]::Round([long]$d.FreeSpace / 1GB, 0)
                $diskTotalGB += $dTotal
                $diskFreeGB  += $dFree
                $diskParts += "$($d.DeviceID) $dFree/$($dTotal) GB"
            }

            # NIC count
            $nicCount = if ($netConfigs) { @($netConfigs).Count } else { 0 }

            # Virtual switch names
            $switchNames = ''
            try {
                if ($UseDirect) {
                    $vSwitches = @(Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_VirtualEthernetSwitch -ComputerName $Target -Credential $Cred)
                } else {
                    $vSwitches = @(Get-CimInstance -CimSession $Session -Namespace 'root\virtualization\v2' -ClassName Msvm_VirtualEthernetSwitch)
                }
                $switchNames = ($vSwitches | ForEach-Object { $_.ElementName } | Select-Object -Unique) -join ', '
            } catch {}

            # Uptime
            $uptimeHours = 0
            try {
                if ($os.LastBootUpTime -is [datetime]) {
                    $uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
                } else {
                    $boot = [System.Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
                    $uptimeHours = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
                }
            } catch {}

            return @{
                HostName    = $resolvedName
                IP          = $hostIP
                OSName      = "$($os.Caption)"
                CPUModel    = "$($cpu.Name)"
                CPUSockets  = "$cpuCount"
                CPUCores    = "$($cpu.NumberOfCores)"
                CPULogical  = "$($cpu.NumberOfLogicalProcessors)"
                RAMTotal    = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2))"
                RAMFree     = "$([math]::Round($os.FreePhysicalMemory / 1MB, 2))"
                Status      = if ($os.Status -eq 'OK') { 'running' } else { "$($os.Status)" }
                Manufacturer = "$($cs.Manufacturer)"
                Model       = "$($cs.Model)"
                NicCount    = "$nicCount"
                DiskSummary = ($diskParts -join ', ')
                DiskTotalGB = "$diskTotalGB"
                DiskFreeGB  = "$diskFreeGB"
                SwitchNames = $switchNames
                Uptime      = "$uptimeHours hours"
            }
        }

        # --- Helper: Enumerate VMs on a target ---
        function Get-TargetVMs {
            param([string]$Target, [PSCredential]$Cred, $Session, [bool]$UseDirect)
            if (-not $UseDirect -and $Session) {
                return @(Get-VM -CimSession $Session -ErrorAction Stop)
            }
            # WMI / DCOM fallback
            try {
                $wmiVMs = Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_ComputerSystem `
                    -ComputerName $Target -Credential $Cred -ErrorAction Stop |
                    Where-Object { $_.Caption -eq 'Virtual Machine' }
                return @(foreach ($wv in $wmiVMs) {
                    [PSCustomObject]@{
                        Name           = $wv.ElementName
                        VMId           = $wv.Name
                        State          = switch ([int]$wv.EnabledState) { 2 { 'Running' } 3 { 'Off' } 6 { 'Saved' } 9 { 'Paused' } 32768 { 'Paused' } 32769 { 'Suspended' } default { "Unknown($($wv.EnabledState))" } }
                        ProcessorCount = 0
                        CPUUsage       = 0
                        MemoryAssigned = 0
                        _WmiMode       = $true
                    }
                })
            } catch {
                Write-Warning "VM enumeration failed for $Target : $_"
                return @()
            }
        }

        # ==============================================================
        # Phase 1a: Probe for Failover Cluster membership
        # ==============================================================
        # Connect to the first target and check MSCluster namespace.
        # If it's a cluster node, discover all sibling nodes and expand
        # the target list so we enumerate VMs across all nodes.
        # ==============================================================
        $processedTargets = @{}    # prevent duplicates when cluster adds nodes
        $clusterVMOwners  = @{}    # VMId -> OwnerNode from cluster role data
        $clusterNodeStates = @{}   # NodeName -> state string

        # Use a while loop so targets added mid-iteration (cluster nodes) are visited
        [System.Collections.ArrayList]$targets = @($targets)
        $targetIndex = 0
        while ($targetIndex -lt $targets.Count) {
            $seedTarget = $targets[$targetIndex]
            $targetIndex++
            if ($processedTargets.ContainsKey($seedTarget)) { continue }

            $conn = Connect-HypervTarget -Target $seedTarget -Cred $cred
            if (-not $conn) {
                Write-Warning "All connection methods failed for $seedTarget. Skipping."
                continue
            }

            Write-Host "  Connected: $seedTarget ($($conn.ConnMethod))" -ForegroundColor DarkGray

            # --- Cluster detection ---
            if (-not $clusterInfo) {
                try {
                    $clusterObj = Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_Cluster `
                        -ComputerName $seedTarget -Credential $cred -ErrorAction Stop
                    if ($clusterObj) {
                        $clusterName = $clusterObj.Name
                        Write-Host "  Failover Cluster detected: $clusterName" -ForegroundColor Cyan

                        # Discover all cluster nodes
                        $clusterNodes = @(Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_Node `
                            -ComputerName $seedTarget -Credential $cred -ErrorAction Stop)

                        $nodeNames = @()
                        foreach ($n in $clusterNodes) {
                            $nodeName = "$($n.Name)"
                            $nodeNames += $nodeName
                            $stateStr = switch ([int]$n.State) {
                                0 { 'Up' }
                                1 { 'Down' }
                                2 { 'Paused' }
                                3 { 'Joining' }
                                default { "Unknown($($n.State))" }
                            }
                            $clusterNodeStates[$nodeName] = $stateStr
                            Write-Host "    Node: $nodeName ($stateStr)" -ForegroundColor DarkGray
                        }

                        # Quorum info
                        $quorumType = ''
                        try {
                            $quorumRes = Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_Cluster `
                                -ComputerName $seedTarget -Credential $cred -ErrorAction Stop
                            $quorumType = switch ([int]$quorumRes.QuorumType) {
                                1 { 'NodeMajority' }
                                2 { 'NodeAndDiskMajority' }
                                3 { 'NodeAndFileShareMajority' }
                                4 { 'DiskOnly' }
                                5 { 'NodeAndCloudWitness' }
                                default { "Type$($quorumRes.QuorumType)" }
                            }
                        } catch { }

                        # Enumerate clustered VM resource groups for owner tracking
                        try {
                            $clusterGroups = Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_ResourceGroup `
                                -ComputerName $seedTarget -Credential $cred -ErrorAction Stop
                            foreach ($grp in $clusterGroups) {
                                # GroupType 111 = Virtual Machine; also check name pattern
                                if ([int]$grp.GroupType -eq 111 -or $grp.Name -match '^[0-9a-f]{8}-') {
                                    $clusterVMOwners[$grp.Name] = "$($grp.OwnerNode)"
                                }
                            }
                            Write-Host "    Clustered VM roles: $($clusterVMOwners.Count)" -ForegroundColor DarkGray
                        } catch {
                            Write-Verbose "Could not enumerate cluster VM groups: $_"
                        }

                        $clusterInfo = @{
                            ClusterName = $clusterName
                            Nodes       = $nodeNames
                            NodeStates  = $clusterNodeStates
                            QuorumType  = $quorumType
                            VMOwners    = $clusterVMOwners
                        }

                        # Resolve cluster node IPs via MSCluster_NetworkInterface
                        # so we can connect even when the client lacks DNS for the domain
                        $clusterNodeIPs = @{}
                        try {
                            $clNetIfs = Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_NetworkInterface `
                                -ComputerName $seedTarget -Credential $cred -ErrorAction Stop
                            foreach ($nif in $clNetIfs) {
                                $nNode = "$($nif.Node)"
                                $nIP   = "$($nif.IPAddress)"
                                if ($nIP -and $nIP -match '^\d{1,3}(\.\d{1,3}){3}$' -and $nIP -notlike '169.254.*') {
                                    if (-not $clusterNodeIPs.ContainsKey($nNode)) {
                                        $clusterNodeIPs[$nNode] = $nIP
                                    }
                                }
                            }
                        } catch {
                            Write-Verbose "Could not resolve cluster node IPs: $_"
                        }
                        $clusterInfo['NodeIPs'] = $clusterNodeIPs

                        # Add sibling nodes to targets so we enumerate VMs on each
                        # Try IP first (client may not have DNS for the cluster domain),
                        # fall back to hostname, skip if already in targets or is the seed
                        foreach ($nodeName in $nodeNames) {
                            $nodeIP = if ($clusterNodeIPs.ContainsKey($nodeName)) { $clusterNodeIPs[$nodeName] } else { $null }

                            # Skip if this node (by name or IP) is already covered
                            $alreadyCovered = ($targets -contains $nodeName) -or ($nodeName -eq $seedTarget) -or
                                              ($processedTargets.ContainsKey($nodeName))
                            if ($nodeIP) {
                                $alreadyCovered = $alreadyCovered -or ($targets -contains $nodeIP) -or
                                                  ($nodeIP -eq $seedTarget) -or ($processedTargets.ContainsKey($nodeIP))
                            }
                            if ($alreadyCovered) { continue }

                            # Prefer IP for connectivity, fall back to hostname
                            $nodeTarget = if ($nodeIP) { $nodeIP } else { $nodeName }
                            [void]$targets.Add($nodeTarget)
                            $ipDisplay = if ($nodeIP) { " ($nodeIP)" } else { ' (no IP resolved)' }
                            Write-Host "    Auto-added cluster node: $nodeName$ipDisplay" -ForegroundColor DarkGray
                        }
                    }
                } catch {
                    Write-Verbose "No failover cluster on $seedTarget (root\MSCluster not available)."
                }
            }

            # --- Gather host info ---
            $processedTargets[$seedTarget] = $true
            try {
                $hostInfo = Get-TargetHostInfo -Target $seedTarget -Cred $cred -Session $conn.Session -UseDirect $conn.UseDirect
                $hostInfo['ConnMethod'] = $conn.ConnMethod
                $resolvedHostName = $hostInfo.HostName
                # Mark resolved hostname as processed to avoid duplicate when cluster adds it by name
                $processedTargets[$resolvedHostName] = $true
                if ($clusterInfo) {
                    $hostInfo['ClusterName'] = $clusterInfo.ClusterName
                    $nodeStateKey = if ($clusterNodeStates.ContainsKey($seedTarget)) { $seedTarget }
                        elseif ($clusterNodeStates.ContainsKey($resolvedHostName)) { $resolvedHostName }
                        else { $null }
                    $hostInfo['NodeState'] = if ($nodeStateKey) { $clusterNodeStates[$nodeStateKey] } else { 'Unknown' }
                }
                $hostMap[$resolvedHostName] = $hostInfo
            } catch {
                Write-Warning "Error getting host info for $seedTarget : $_"
            }

            # --- Enumerate VMs ---
            try {
                $vms = Get-TargetVMs -Target $seedTarget -Cred $cred -Session $conn.Session -UseDirect $conn.UseDirect
                foreach ($vm in $vms) {
                    $vmIP = $null
                    if (-not $conn.UseDirect -and $conn.Session) {
                        try {
                            $nics = Get-VMNetworkAdapter -CimSession $conn.Session -VM $vm -ErrorAction SilentlyContinue
                            $vmIP = $nics |
                                ForEach-Object { $_.IPAddresses } |
                                Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
                                Select-Object -First 1
                        } catch { }
                    }

                    $memAssigned = if ($vm.MemoryAssigned) { [math]::Round($vm.MemoryAssigned / 1GB, 2) } else { 0 }

                    # Determine owner node — only for clustered VMs
                    $ownerNode = ''
                    if ($clusterInfo -and $clusterInfo.VMOwners.Count -gt 0) {
                        $vmIdStr = "$($vm.VMId)"
                        if ($clusterInfo.VMOwners.ContainsKey($vmIdStr)) {
                            $ownerNode = $clusterInfo.VMOwners[$vmIdStr]
                        }
                        # Also try by VM name (some clusters key by name)
                        $vmNameStr = "$($vm.Name)"
                        if ($clusterInfo.VMOwners.ContainsKey($vmNameStr)) {
                            $ownerNode = $clusterInfo.VMOwners[$vmNameStr]
                        }
                    }

                    $vmKey = "${resolvedHostName}:$($vm.Name)"
                    $vmMap[$vmKey] = @{
                        Name       = "$($vm.Name)"
                        VMId       = "$($vm.VMId)"
                        Host       = $resolvedHostName
                        OwnerNode  = $ownerNode
                        State      = "$($vm.State)"
                        IP         = $vmIP
                        CPUCount   = "$($vm.ProcessorCount)"
                        CPUUsage   = "$($vm.CPUUsage)"
                        MemoryGB   = "$memAssigned"
                    }
                }
            } catch {
                Write-Warning "Error enumerating VMs on $seedTarget : $_"
            }

            # Cleanup CIM session
            if ($conn.Session) {
                try { Remove-CimSession -CimSession $conn.Session -ErrorAction SilentlyContinue } catch { }
            }
        }

        # --- If cluster detected, also enumerate VMs from cluster resource
        #     groups that weren't found on any live node (failed/offline VMs) ---
        if ($clusterInfo -and $clusterInfo.VMOwners.Count -gt 0) {
            $discoveredVMIds = @{}
            foreach ($vmKey in $vmMap.Keys) { $discoveredVMIds[$vmMap[$vmKey].VMId] = $true }
            foreach ($vmRoleKey in $clusterInfo.VMOwners.Keys) {
                if (-not $discoveredVMIds.ContainsKey($vmRoleKey)) {
                    # This VM role wasn't found on any live node — cluster role exists but VM is offline/failed
                    $ownerNode = $clusterInfo.VMOwners[$vmRoleKey]
                    $syntheticKey = "cluster:$vmRoleKey"
                    $vmMap[$syntheticKey] = @{
                        Name       = $vmRoleKey
                        VMId       = $vmRoleKey
                        Host       = $ownerNode
                        OwnerNode  = $ownerNode
                        State      = 'ClusterOffline'
                        IP         = $null
                        CPUCount   = '0'
                        CPUUsage   = '0'
                        MemoryGB   = '0'
                    }
                    Write-Verbose "Added offline cluster VM: $vmRoleKey (owner: $ownerNode)"
                }
            }
        }

        if ($clusterInfo) {
            Write-Host "  Cluster: $($clusterInfo.ClusterName) ($($clusterInfo.Nodes.Count) nodes, $($clusterInfo.VMOwners.Count) VM roles)" -ForegroundColor Cyan
        }
        Write-Verbose "Topology: $($hostMap.Count) hosts, $($vmMap.Count) VMs"

        # ================================================================
        # Phase 2: Build discovery plan
        # ================================================================
        $baseAttrs = @{
            'DiscoveryHelper.HyperV' = 'true'
            'DiscoveryHelper.HyperV.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
        }
        if ($clusterInfo) {
            $baseAttrs['HyperV.ClusterNodes'] = ($clusterInfo.Nodes -join ',')
            $baseAttrs['HyperV.QuorumType'] = $clusterInfo.QuorumType
        }

        # --- Per-Host items ---
        foreach ($hostName in @($hostMap.Keys | Sort-Object)) {
            $hostInfo = $hostMap[$hostName]
            $hostIP   = $hostInfo.IP

            $hostAttrs = $baseAttrs.Clone()
            $hostAttrs['HyperV.DeviceType'] = 'Host'
            $hostAttrs['HyperV.HostName']   = $hostName
            if ($hostIP) { $hostAttrs['HyperV.HostIP'] = $hostIP }
            $hostAttrs['HyperV.OS']         = $hostInfo.OSName
            $hostAttrs['HyperV.CPUModel']   = $hostInfo.CPUModel
            $hostAttrs['HyperV.CPUSockets'] = $hostInfo.CPUSockets
            $hostAttrs['HyperV.CPUCores']   = $hostInfo.CPUCores
            $hostAttrs['HyperV.CPULogical']  = $hostInfo.CPULogical
            $hostAttrs['HyperV.RAMTotalGB'] = $hostInfo.RAMTotal
            $hostAttrs['HyperV.RAMFreeGB']  = $hostInfo.RAMFree
            $hostAttrs['HyperV.NicCount']   = $hostInfo.NicCount
            $hostAttrs['HyperV.DiskSummary']= $hostInfo.DiskSummary
            $hostAttrs['HyperV.DiskTotalGB']= $hostInfo.DiskTotalGB
            $hostAttrs['HyperV.DiskFreeGB'] = $hostInfo.DiskFreeGB
            $hostAttrs['HyperV.SwitchNames']= $hostInfo.SwitchNames
            $hostAttrs['HyperV.Manufacturer'] = $hostInfo.Manufacturer
            $hostAttrs['HyperV.Model']      = $hostInfo.Model
            $hostAttrs['HyperV.Uptime']     = $hostInfo.Uptime
            $hostAttrs['HyperV.Status']     = $hostInfo.Status
            if ($hostInfo.ClusterName) { $hostAttrs['HyperV.ClusterName'] = $hostInfo.ClusterName }
            if ($hostInfo.NodeState)   { $hostAttrs['HyperV.NodeState']   = $hostInfo.NodeState }

            $items += New-DiscoveredItem `
                -Name 'HyperV - Host Status' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Monitors Hyper-V host $hostName connectivity and status"
                } `
                -UniqueKey "HyperV:host:${hostName}:active:status" `
                -Attributes $hostAttrs `
                -Tags @('hyperv', 'host', $hostName, $(if ($hostIP) { $hostIP } else { 'no-ip' }))

            $hostPerfMonitors = @(
                @{ Name = 'HyperV - Host CPU';    Key = 'cpu' }
                @{ Name = 'HyperV - Host Memory'; Key = 'memory' }
                @{ Name = 'HyperV - Host Disk';   Key = 'disk' }
            )
            foreach ($pm in $hostPerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'PowerShell' `
                    -MonitorParams @{
                        Description = "$($pm.Name) for host $hostName"
                    } `
                    -UniqueKey "HyperV:host:${hostName}:perf:$($pm.Key)" `
                    -Attributes $hostAttrs `
                    -Tags @('hyperv', 'host', $hostName, $(if ($hostIP) { $hostIP } else { 'no-ip' }))
            }
        }

        # --- Per-VM items ---
        foreach ($vmKey in @($vmMap.Keys | Sort-Object)) {
            $vmInfo = $vmMap[$vmKey]
            $vmName = $vmInfo.Name
            $vmIP   = $vmInfo.IP
            $vmHost = $vmInfo.Host

            $vmAttrs = $baseAttrs.Clone()
            $vmAttrs['HyperV.DeviceType'] = 'VM'
            $vmAttrs['HyperV.VMName']     = $vmName
            $vmAttrs['HyperV.VMId']       = $vmInfo.VMId
            $vmAttrs['HyperV.Host']       = $vmHost
            $vmAttrs['HyperV.State']      = $vmInfo.State
            $vmAttrs['HyperV.CPUCount']   = $vmInfo.CPUCount
            $vmAttrs['HyperV.MemoryGB']   = $vmInfo.MemoryGB
            if ($vmIP) { $vmAttrs['HyperV.VMIP'] = $vmIP }
            if ($vmInfo.OwnerNode) {
                $vmAttrs['HyperV.OwnerNode'] = $vmInfo.OwnerNode
                if ($clusterInfo) { $vmAttrs['HyperV.ClusterName'] = $clusterInfo.ClusterName }
            }

            $items += New-DiscoveredItem `
                -Name 'HyperV - VM Status' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Monitors VM $vmName state on host $vmHost"
                } `
                -UniqueKey "HyperV:vm:${vmHost}:${vmName}:active:status" `
                -Attributes $vmAttrs `
                -Tags @('hyperv', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmHost)

            $vmPerfMonitors = @(
                @{ Name = 'HyperV - VM CPU';    Key = 'cpu' }
                @{ Name = 'HyperV - VM Memory'; Key = 'memory' }
            )
            foreach ($pm in $vmPerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'PowerShell' `
                    -MonitorParams @{
                        Description = "$($pm.Name) for VM $vmName on $vmHost"
                    } `
                    -UniqueKey "HyperV:vm:${vmHost}:${vmName}:perf:$($pm.Key)" `
                    -Attributes $vmAttrs `
                    -Tags @('hyperv', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmHost)
            }
        }

        return $items
    }

# ==============================================================================
# Export-HypervDiscoveryDashboardHtml
# ==============================================================================
function Export-HypervDiscoveryDashboardHtml {
    <#
    .SYNOPSIS
        Generates a Hyper-V dashboard HTML file from live host/VM data.
    .DESCRIPTION
        Reads the Hyper-V dashboard template, injects column definitions
        and row data as JSON, and writes the final HTML to OutputPath.
    .PARAMETER DashboardData
        Array of PSCustomObject rows from Get-HypervDashboard.
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title shown in header and browser tab.
    .PARAMETER TemplatePath
        Path to Hyperv-Dashboard-Template.html.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Hyper-V Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'hyperv\Hyperv-Dashboard-Template.html'
    }
    if (-not (Test-Path $TemplatePath)) {
        Write-Error "Template not found: $TemplatePath"
        return
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '(?<=[a-z])([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'State')     { $col.formatter = 'formatState' }
        if ($prop.Name -eq 'Status')    { $col.formatter = 'formatStatus' }
        if ($prop.Name -eq 'Heartbeat') { $col.formatter = 'formatHeartbeat' }
        if ($prop.Name -eq 'Type')      { $col.formatter = 'formatType' }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    # Force array wrapper even for a single item
    $dataJson    = ConvertTo-Json -InputObject @($DashboardData) -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $parentDir = Split-Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Dashboard written to: $OutputPath"
    return $OutputPath
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBZe2PH5DohMXuS
# hdaeZbUHHc6Ulz763u8J8Nve7OGrm6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg0lnekWoRFyFSt7QbvC8NRxT8e6rFc/tQ
# 8MP2RHruD3AwDQYJKoZIhvcNAQEBBQAEggIAnUPch3CkEns2qVUT3n0/qISr7OCK
# xIxWnbON+wUo5XjNVA94ihrX9Ll66WyMj8braizztaFaOFJEJAIGGYi1fqohRLGc
# 1f8trM1WrO7DkbZyXUu/e6/hpGOzeR1Pj4w1B3sdITFX+BTZxsO2GQV7DwDAx6K7
# Jsk4iY7DCfo9u4s0F5V0IMI2GYNakBbpT9VC3c7JNRO47iQWgfoJGi2IiJiVt2Q5
# 44QXhbCyWQoqO59ITo/ApJy/uP2CZI7wJoKcnMWhYEwMcw7XWFOBUOJzSCp642E6
# Cw1ElVvOer9mlYqjZh+gJuzCjozKw1BtqaszthW16g8K2tb2PLW4FRtqZbSjfnk8
# Rl5qMUMq399zDg3pZLFawjvT+eovjcYBsbBayJUtgRPcO7c2JZFq7q2aWK4E7Ur2
# VP9Td8FZGo4+gnpZtjnWFBHM//wqQqgHeTcRRPqiCXHzvXX/+Mfdg6cyC3pcEKcg
# vqrZknOlyhkA7h17mJxZNND6Ako8zQPagiZ+2zeNDJYF0BZe5mg1ZTCjE/EW1sJY
# UG5vUJlJ4/svBaoF7gU/PN6d1G7CaYuet1rF9vxfRhw75BD8P0UBjoRDm3wujqcI
# SxIb9tFTDS+Pp+09Zgx49/mQDdidMx6yiQB+WRwe9m4P+8Wivf1WWn72zz5yHJ9d
# FUyC7yQ7WzqR8SU=
# SIG # End signature block
