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
      PSCredential (domain\user + password) via WSMan, DCOM or WMI.
      Uses native WMI when the local Hyper-V module is unavailable.

    Prerequisites:
      1. Windows PowerShell with CIM/WMI support
      2. WinRM/WSMan or RPC/DCOM access to target hosts
      3. Credentials with Hyper-V Administrators or local admin access

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first; local Hyper-V module optional
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

function Get-HypervMonitorCredentialScript {
    @'
$user = $Context.GetProperty('CredWindows:DomainAndUserid')
$password = $Context.GetProperty('CredWindows:Password')
if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrEmpty($password)) { throw 'The device Windows credential is unavailable.' }
$credential = [PSCredential]::new($user, (ConvertTo-SecureString $password -AsPlainText -Force))
$password = $null
'@
}

function Get-HypervVmOwnerScript {
    param([string]$HostAddress, [guid]$VMId, [hashtable]$ClusterNodes)
    if (-not $ClusterNodes -or $ClusterNodes.Count -eq 0) {
        return "`$ownerAddress = '$($HostAddress.Replace("'", "''"))'"
    }
    if ($VMId -eq [guid]::Empty) { throw 'Cluster VM monitoring requires its Hyper-V GUID.' }
    $entries = foreach ($node in @($ClusterNodes.Keys | Sort-Object)) {
        "'$($node.Replace("'", "''"))' = '$($ClusterNodes[$node].Replace("'", "''"))'"
    }
    $template = @'
$nodeAddresses = @{ __NODES__ }
$ownerAddress = $null
$ownerJob = Get-WmiObject -ComputerName @($nodeAddresses.Values | Select-Object -Unique) -Credential $credential -Namespace 'root\MSCluster' -Class MSCluster_Resource -Filter "Type='Virtual Machine'" -AsJob -ErrorAction Stop
try {
    $pending = @($ownerJob.ChildJobs)
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $probeErrors = [System.Collections.Generic.List[string]]::new()
    while (-not $ownerAddress -and $pending.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        $finished = @($pending | Where-Object { $_.State -notin @('Running', 'NotStarted', 'Blocked') })
        foreach ($probe in $finished) {
            try {
                $resources = @(Receive-Job -Job $probe -ErrorAction Stop)
                $matching = @($resources | Where-Object { "$($_.PrivateProperties.VmId)" -eq '__ID__' })
                if ($matching.Count -ne 1) { throw 'The cluster VM resource was not uniquely resolved by GUID.' }
                $owner = "$($matching[0].OwnerNode)"
                if (-not $nodeAddresses.ContainsKey($owner)) { throw "The cluster reported an unknown owner: $owner." }
                $ownerAddress = $nodeAddresses[$owner]
                break
            } catch {
                $probeErrors.Add($_.Exception.Message)
                Write-Warning "Hyper-V cluster owner probe failed: $($_.Exception.Message)"
            }
        }
        $pending = @($pending | Where-Object { $finished -notcontains $_ })
        if (-not $ownerAddress -and $pending.Count -gt 0) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ownerAddress) { throw "Could not resolve the current VM owner within 20 seconds. $($probeErrors -join '; ')" }
} finally {
    Stop-Job -Job $ownerJob -ErrorAction Stop
    Remove-Job -Job $ownerJob -Force -ErrorAction Stop
}
'@
    $template.Replace('__NODES__', ($entries -join '; ')).Replace('__ID__', $VMId.ToString())
}

function Get-HypervVmCpuScript {
    param([string]$HostAddress, [string]$VMName, [guid]$VMId = [guid]::Empty, [hashtable]$ClusterNodes)
    $template = @'
$ErrorActionPreference = 'Stop'
__CREDENTIAL__
__OWNER__
$prefix = '__VM__:'
$samples = @(Get-WmiObject -ComputerName $ownerAddress -Credential $credential -Class Win32_PerfFormattedData_HvStats_HyperVHypervisorVirtualProcessor -ErrorAction Stop |
    Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
if ($samples.Count -eq 0) { throw 'No virtual-processor samples were returned for the VM.' }
foreach ($sample in $samples) {
    if ($null -eq $sample.PercentTotalRunTime) { throw 'VM processor usage was not reported.' }
}
$value = ($samples | Measure-Object -Property PercentTotalRunTime -Average).Average
if ($null -eq $value) { throw 'VM processor usage could not be calculated.' }
$Context.SetValue([double]$value)
'@
    $template.Replace('__CREDENTIAL__', (Get-HypervMonitorCredentialScript)).Replace('__OWNER__', (Get-HypervVmOwnerScript -HostAddress $HostAddress -VMId $VMId -ClusterNodes $ClusterNodes)).Replace('__VM__', $VMName.Replace("'", "''"))
}

function Get-HypervVmStatusScript {
    param([string]$HostAddress, [guid]$VMId, [hashtable]$ClusterNodes)
    $template = @'
$ErrorActionPreference = 'Stop'
try {
    __CREDENTIAL__
    __OWNER__
    $vm = Get-WmiObject -ComputerName $ownerAddress -Credential $credential -Namespace 'root\virtualization\v2' -Class Msvm_ComputerSystem -Filter "Name='__ID__'" -ErrorAction Stop
    if (-not $vm) { throw 'The VM was not found on its configured owner.' }
    if ([int]$vm.EnabledState -eq 2) { $Context.SetResult(0, "VM is running on $ownerAddress.") }
    else { $Context.SetResult(1, "VM is not running (EnabledState=$($vm.EnabledState)).") }
}
catch { $Context.SetResult(1, "VM status query failed: $($_.Exception.Message)") }
'@
    $template.Replace('__CREDENTIAL__', (Get-HypervMonitorCredentialScript)).Replace('__OWNER__', (Get-HypervVmOwnerScript -HostAddress $HostAddress -VMId $VMId -ClusterNodes $ClusterNodes)).Replace('__ID__', $VMId.ToString())
}

function Get-HypervVmMemoryScript {
    param([string]$HostAddress, [string]$VMName, [guid]$VMId, [hashtable]$ClusterNodes)
    $template = @'
$ErrorActionPreference = 'Stop'
__CREDENTIAL__
__OWNER__
$memory = @(Get-WmiObject -ComputerName $ownerAddress -Credential $credential -Class Win32_PerfFormattedData_BalancerStats_HyperVDynamicMemoryVM -ErrorAction Stop |
    Where-Object { $_.Name -eq '__VM__' })
if ($memory.Count -ne 1 -or $null -eq $memory[0].PhysicalMemory) { throw 'VM physical memory was not uniquely reported by its current owner.' }
$Context.SetValue([double]$memory[0].PhysicalMemory)
'@
    $template.Replace('__CREDENTIAL__', (Get-HypervMonitorCredentialScript)).Replace('__OWNER__', (Get-HypervVmOwnerScript -HostAddress $HostAddress -VMId $VMId -ClusterNodes $ClusterNodes)).Replace('__VM__', $VMName.Replace("'", "''"))
}

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
                $hostIPs = @($netConfigs |
                    ForEach-Object { $_.IPAddress } |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' })
                $hostIP = if ($hostIPs -contains $Target) { $Target } else { $hostIPs | Select-Object -First 1 }
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
            if (-not $UseDirect -and $Session -and (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
                return @(Get-VM -CimSession $Session -ErrorAction Stop)
            }
            try {
                $wmiVMs = if (-not $UseDirect -and $Session) {
                    Get-CimInstance -CimSession $Session -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem -ErrorAction Stop
                } else {
                    Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_ComputerSystem `
                        -ComputerName $Target -Credential $Cred -ErrorAction Stop
                }
                $wmiVMs = @($wmiVMs | Where-Object { $_.Caption -eq 'Virtual Machine' })
                return @(foreach ($wv in $wmiVMs) {
                    $processorCount = $null
                    try {
                        $settings = if (-not $UseDirect -and $Session) {
                            Get-CimAssociatedInstance -CimSession $Session -InputObject $wv -ResultClassName Msvm_VirtualSystemSettingData -ErrorAction Stop
                        } else {
                            $wv.GetRelated('Msvm_VirtualSystemSettingData')
                        }
                        $currentSettings = $settings | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } | Select-Object -First 1
                        if ($currentSettings) {
                            $processors = if (-not $UseDirect -and $Session) {
                                Get-CimAssociatedInstance -CimSession $Session -InputObject $currentSettings -ResultClassName Msvm_ProcessorSettingData -ErrorAction Stop
                            } else {
                                $currentSettings.GetRelated('Msvm_ProcessorSettingData')
                            }
                            $processorCount = ($processors | Select-Object -First 1).VirtualQuantity
                        }
                    } catch {
                        Write-Warning "Could not collect processor inventory for VM '$($wv.ElementName)' on ${Target}: $($_.Exception.Message)"
                    }
                    $memoryAssigned = $null
                    if ([int]$wv.EnabledState -eq 3) { $memoryAssigned = 0 }
                    else {
                        try {
                            $memoryCounters = if (-not $UseDirect -and $Session) {
                                Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_BalancerStats_HyperVDynamicMemoryVM -ErrorAction Stop
                            } else {
                                Get-WmiObject -ComputerName $Target -Credential $Cred -Class Win32_PerfFormattedData_BalancerStats_HyperVDynamicMemoryVM -ErrorAction Stop
                            }
                            $memory = $memoryCounters | Where-Object { $_.Name -eq $wv.ElementName } | Select-Object -First 1
                            if ($memory -and $null -ne $memory.PhysicalMemory) { $memoryAssigned = [long]$memory.PhysicalMemory * 1MB }
                        } catch {
                            Write-Warning "Could not collect memory inventory for VM '$($wv.ElementName)' on ${Target}: $($_.Exception.Message)"
                        }
                    }
                    [PSCustomObject]@{
                        Name           = $wv.ElementName
                        VMId           = $wv.Name
                        State          = switch ([int]$wv.EnabledState) { 2 { 'Running' } 3 { 'Off' } 6 { 'Saved' } 9 { 'Paused' } 32768 { 'Paused' } 32769 { 'Suspended' } default { "Unknown($($wv.EnabledState))" } }
                        ProcessorCount = $processorCount
                        CPUUsage       = $null
                        MemoryAssigned = $memoryAssigned
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
                            $vmResources = @(Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_Resource `
                                -Filter "Type='Virtual Machine'" -ComputerName $seedTarget -Credential $cred -ErrorAction Stop)
                            foreach ($resource in $vmResources) {
                                $resourceId = [guid]::Empty
                                if ([guid]::TryParse("$($resource.PrivateProperties.VmId)", [ref]$resourceId)) {
                                    $clusterVMOwners.Remove("$($resource.OwnerGroup)")
                                    $clusterVMOwners[$resourceId.ToString()] = "$($resource.OwnerNode)"
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
                                $nIP   = "$($nif.Address)"
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

                    $memAssigned = if ($null -ne $vm.MemoryAssigned) { [math]::Round($vm.MemoryAssigned / 1GB, 2) } else { $null }

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
                        CPUCount   = if ($null -ne $vm.ProcessorCount) { "$($vm.ProcessorCount)" } else { $null }
                        CPUUsage   = if ($null -ne $vm.CPUUsage) { "$($vm.CPUUsage)" } else { $null }
                        MemoryGB   = if ($null -ne $memAssigned) { "$memAssigned" } else { $null }
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
            foreach ($vmKey in $vmMap.Keys) {
                $discoveredVMIds[$vmMap[$vmKey].VMId] = $true
                $discoveredVMIds[$vmMap[$vmKey].Name] = $true
            }
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
                        CPUCount   = $null
                        CPUUsage   = $null
                        MemoryGB   = $null
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
                -MonitorType 'Service' `
                -MonitorParams @{
                    ServiceInternalName = 'vmms'
                    ServiceDisplayName = 'Hyper-V Virtual Machine Management'
                    ServiceRestartOnFailure = 0
                } `
                -UniqueKey "HyperV:host:${hostName}:active:status" `
                -Attributes $hostAttrs `
                -Tags @('hyperv', 'host', $hostName, $(if ($hostIP) { $hostIP } else { 'no-ip' }))

            if ($clusterInfo) {
                $items += New-DiscoveredItem -Name 'HyperV - Cluster Service' -ItemType ActiveMonitor -MonitorType Service `
                    -MonitorParams @{ ServiceInternalName = 'ClusSvc'; ServiceDisplayName = 'Cluster Service'; ServiceRestartOnFailure = 0 } `
                    -UniqueKey "HyperV:host:${hostName}:active:cluster" -Attributes $hostAttrs -Tags @('hyperv', 'host', $hostName)
            }
            $hostPerfMonitors = @(
                @{ Name = 'HyperV - Host CPU'; Key = 'cpu'; Class = 'Win32_PerfFormattedData_PerfOS_Processor'; Property = 'PercentProcessorTime'; Instance = '_Total'; Display = 'CPU usage (%)' }
                @{ Name = 'HyperV - Host Available Memory (MB)'; Key = 'memory'; Class = 'Win32_PerfFormattedData_PerfOS_Memory'; Property = 'AvailableMBytes'; Instance = ''; Display = 'Available memory (MB)' }
                @{ Name = 'HyperV - Host Disk Free (%)'; Key = 'disk'; Class = 'Win32_PerfFormattedData_PerfDisk_LogicalDisk'; Property = 'PercentFreeSpace'; Instance = '_Total'; Display = 'Disk free (%)' }
            )
            foreach ($pm in $hostPerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'WmiFormatted' `
                    -MonitorParams @{
                        WmiFormattedRelativePath = $pm.Class
                        WmiFormattedPropertyName = $pm.Property
                        WmiFormattedDisplayname = $pm.Display
                        WmiFormattedInstanceName = $pm.Instance
                        WmiFormattedTimeout = 15
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
            $vmHostIP = if ($hostMap.ContainsKey($vmHost)) { $hostMap[$vmHost].IP } else { $null }
            if (-not $vmHostIP) {
                Write-Warning "No reachable owner address for VM '$vmName'; skipping monitor creation."
                continue
            }
            $vmId = $vmInfo.VMId
            $parsedVmId = [guid]::Empty
            if (-not [guid]::TryParse($vmId, [ref]$parsedVmId)) {
                Write-Warning "VM '$vmName' has no resolved Hyper-V GUID; skipping monitors rather than querying a cluster role name."
                continue
            }
            $monitorNodes = $null
            $vmLabel = 'VM'
            if ($vmInfo.OwnerNode -and $clusterInfo) {
                $monitorNodes = @{}
                foreach ($node in $clusterInfo.NodeIPs.Keys) { $monitorNodes[$node] = $clusterInfo.NodeIPs[$node] }
                foreach ($node in $hostMap.Keys) { $monitorNodes[$node] = $hostMap[$node].IP }
                $vmLabel = 'Cluster VM'
            }

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
                if ($clusterInfo) {
                    $vmAttrs['HyperV.ClusterName'] = $clusterInfo.ClusterName
                    $vmAttrs['HyperV.MonitorHost'] = @($clusterInfo.Nodes | Sort-Object)[0]
                }
            }

            $items += New-DiscoveredItem `
                -Name "HyperV - $vmLabel Status - $vmName [$vmId]" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    PowerShellScriptText = (Get-HypervVmStatusScript -HostAddress $vmHostIP -VMId $vmId -ClusterNodes $monitorNodes)
                    PowerShellScriptImpersonateFlag = '1'
                    PowerShellScriptTimeout = 90
                } `
                -UniqueKey "HyperV:vm:${vmHost}:${vmName}:active:status" `
                -Attributes $vmAttrs `
                -Tags @('hyperv', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmHost)

            $items += New-DiscoveredItem -Name "HyperV - $vmLabel CPU (%) - $vmName [$vmId]" -ItemType PerformanceMonitor -MonitorType PowerShell `
                -MonitorParams @{ ScriptText = (Get-HypervVmCpuScript -HostAddress $vmHostIP -VMName $vmName -VMId $vmId -ClusterNodes $monitorNodes); ScriptImpersonateFlag = '1'; ScriptTimeout = 90 } `
                -UniqueKey "HyperV:vm:${vmHost}:${vmName}:perf:cpu" -Attributes $vmAttrs -Tags @('hyperv', 'vm', $vmName, $vmHost)
            $memoryParams = if ($monitorNodes) {
                @{ ScriptText = (Get-HypervVmMemoryScript -HostAddress $vmHostIP -VMName $vmName -VMId $vmId -ClusterNodes $monitorNodes); ScriptImpersonateFlag = '1'; ScriptTimeout = 90 }
            } else {
                @{
                    WmiFormattedRelativePath = 'Win32_PerfFormattedData_BalancerStats_HyperVDynamicMemoryVM'
                    WmiFormattedPropertyName = 'PhysicalMemory'
                    WmiFormattedDisplayname = 'VM physical memory (MB)'
                    WmiFormattedInstanceName = $vmName
                    WmiFormattedDeviceAddress = $vmHostIP
                    WmiFormattedTimeout = 15
                }
            }
            $memoryType = if ($monitorNodes) { 'PowerShell' } else { 'WmiFormatted' }
            $items += New-DiscoveredItem -Name "HyperV - $vmLabel Memory (MB) - $vmName [$vmId]" -ItemType PerformanceMonitor -MonitorType $memoryType `
                -MonitorParams $memoryParams `
                -UniqueKey "HyperV:vm:${vmHost}:${vmName}:perf:memory" -Attributes $vmAttrs -Tags @('hyperv', 'vm', $vmName, $vmHost)
        }

        $cred = $null; $secPwd = $null
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
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCOpNVYktvwDvEf
# 70H/Et0XRXUbqdKXAnBUgA6CPF8MKaCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBh
# iyOUw7pyKEq4rhoDQl2ZfX5Y8vAuWvAvnDSyWeIOVTANBgkqhkiG9w0BAQEFAASC
# AgDke/gDvzSlABA3CIqwjUWtjxGTgauM2xi9c8BMJIePhydlhkVxtdsCsxAKPze/
# QQMyQSmaEeLdkeVBYRLPJ+7UCGkSHgI9rf2NtZCSLBBerdWd+Hfp9ThpZAcHEJXy
# HM7o6L0Vjt/tlLz9ON8p0pUYAd6jU3s6fzD0XgLcGetZjcCu6wqPS2dhdJekgoWT
# R0EL3JXiHT6pGB/MNufLAAE4bXlf5uexl+n5tJ4nP97/wblOMQF258BJKbhWF9N1
# RcMFeArZL/hQPICkBnFEAxGSn4elddOb8ZZHTmG/0/EDep2sST7+zXEkWbAnyUY2
# CM/5ToYzDjYuA7tpLNib2pms8CkcB9eM+kLThi8vTamyqqFJicYfpz5MX0uBXseO
# D3NQf0a5iP4ACtQUdxbx1h4ir7QW86zBW6LBwnACHWBT/HePdGc9CfN9MCt+IeM9
# AL46gUGzIOIWwGXRnrN2vuBRrE9kTTXIgCR/AuzcLk/BNSvSyBtucXxUe0P4wsgd
# lToV+xVdzhkhwwtTIvqbIfqenA4CcQaKeBcOaZEgZoNBvUu1UZy6rpoJfyvslpIk
# eGGHSIC7XdC0BNS9KRbklRl2ggxDqh9mlq0dNrhvFWMQKP93X7ppmn56w+2fW/Df
# abQAdwbZaGPTd95tLGZCPj/xrZMRv5SVrE3gz5sCu2SCyqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTQwMjQwNTlaMC8GCSqGSIb3DQEJBDEiBCAcU3zx4L2j
# M3SbnLb66T2/PCCxl/mwK4fYH6FpOga2XzANBgkqhkiG9w0BAQEFAASCAgBsSL4Q
# uyV4VEJJuRD9JnZHLDHzQsEtXREsxyTLPuu+c6srRAk1RrYUMP3MFkcDb+5kw4ro
# TRsaS91wbfImD5A8BBYFp4l4s6+aLCbZb/5e0DodHWtIZR0+VRm6FcibVs2EXi7T
# WU7zei0NKiLDDkNoZ8zVW36P1kipl2Yo6nOAdqYjOY4sDQyZ1nfmEKA7AWP8FFcq
# TZ3H1sawM8UWt1zMeI7yBwRV5xH1ZRz9aH1jkx/QAlq4+rXBnsBWyu5C9ySiSaGn
# B28e3alPiPY9fhAd7ac4RG43zEDDm+RpatzG/q41jWyW+B/Yhau2XhEC50jXr/4x
# yQn//W5P/+LsAze5KiFJmJtm49iaZIata6yJUIe/arHA1EmX6Z+wcUbn0Sl27iRP
# TtwgUeCnitRRF12Qv5SZbZEUCy4IH4iHfUF1Kg1GcogAWu9Jnos7aKv38s6DVPjm
# gc1elZ9Ak+hBTtvX97gZFRzdG/KTiQY1Q9Afp7URY0E60LekyXm419V3yJ7Nf4zB
# A+kuBjXZJDLPV5f8EXWW1f/bIN7TS4ra3bkMZIf21xO5tG3hzxWsRSNlLrXHXlAD
# 4XZj2DCEQP2cBCuaN/nAacSOPPv9/I/DqyIQPqLi30D7GNs0SKs+qEhMVrWawDqL
# IvIYSP3R+0aasrmAxvMhXZB0Lg4UevYHDO9vgw==
# SIG # End signature block
