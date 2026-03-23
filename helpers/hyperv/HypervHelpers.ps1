function Connect-HypervHost {
    <#
    .SYNOPSIS
        Creates a CIM session to a remote Hyper-V host.
    .DESCRIPTION
        Establishes a CIM session using WSMan (default) or DCOM for older hosts.
        Returns a CIMSession object used by all other helper functions.
    .PARAMETER ComputerName
        The hostname or IP of the Hyper-V host.
    .PARAMETER Credential
        PSCredential for authentication.
    .PARAMETER UseDCOM
        Use DCOM instead of WSMan (for older hosts without WinRM).
    .EXAMPLE
        $cred = Get-Credential
        $session = Connect-HypervHost -ComputerName "hyperv01.lab.local" -Credential $cred
        Creates a CIM session to the specified Hyper-V host using WSMan.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred -UseDCOM
        Creates a CIM session using DCOM for compatibility with older hosts.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [switch]$UseDCOM
    )

    $sessionOption = if ($UseDCOM) {
        New-CimSessionOption -Protocol Dcom
    } else {
        New-CimSessionOption -Protocol Wsman
    }

    try {
        $session = New-CimSession -ComputerName $ComputerName -Credential $Credential -SessionOption $sessionOption -ErrorAction Stop
        Write-Verbose "Connected to Hyper-V host: $ComputerName"
        return $session
    }
    catch {
        throw "Failed to connect to $ComputerName : $($_.Exception.Message)"
    }
}

function Get-HypervClusterInfo {
    <#
    .SYNOPSIS
        Detects whether a Hyper-V host is a Failover Cluster node and returns cluster metadata.
    .PARAMETER ComputerName
        Hostname or IP of the Hyper-V host.
    .PARAMETER Credential
        PSCredential for authentication.
    .EXAMPLE
        $cluster = Get-HypervClusterInfo -ComputerName "hyperv01" -Credential $cred
        if ($cluster) { "Cluster: $($cluster.ClusterName), Nodes: $($cluster.Nodes -join ', ')" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    try {
        $clusterObj = Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_Cluster `
            -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
    }
    catch {
        Write-Verbose "No Failover Cluster on $ComputerName (root\MSCluster unavailable)."
        return $null
    }
    if (-not $clusterObj) { return $null }

    $nodes = @(Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_Node `
        -ComputerName $ComputerName -Credential $Credential -ErrorAction SilentlyContinue)

    $nodeDetails = @{}
    foreach ($n in $nodes) {
        $nodeDetails["$($n.Name)"] = switch ([int]$n.State) {
            0 { 'Up' }; 1 { 'Down' }; 2 { 'Paused' }; 3 { 'Joining' }
            default { "Unknown($($n.State))" }
        }
    }

    $vmOwners = @{}
    try {
        $groups = Get-WmiObject -Namespace 'root\MSCluster' -Class MSCluster_ResourceGroup `
            -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
        foreach ($grp in $groups) {
            if ([int]$grp.GroupType -eq 111 -or $grp.Name -match '^[0-9a-f]{8}-') {
                $vmOwners[$grp.Name] = "$($grp.OwnerNode)"
            }
        }
    }
    catch { }

    $quorumType = ''
    try {
        $quorumType = switch ([int]$clusterObj.QuorumType) {
            1 { 'NodeMajority' }; 2 { 'NodeAndDiskMajority' }; 3 { 'NodeAndFileShareMajority' }
            4 { 'DiskOnly' }; 5 { 'NodeAndCloudWitness' }
            default { "Type$($clusterObj.QuorumType)" }
        }
    }
    catch { }

    [PSCustomObject]@{
        ClusterName = "$($clusterObj.Name)"
        Nodes       = @($nodes | ForEach-Object { "$($_.Name)" })
        NodeStates  = $nodeDetails
        VMOwners    = $vmOwners
        QuorumType  = $quorumType
    }
}

function Get-HypervHostDetail {
    <#
    .SYNOPSIS
        Gathers detailed information about a Hyper-V host.
    .PARAMETER CimSession
        An active CIM session to the Hyper-V host.
    .PARAMETER ComputerName
        Hostname or IP of the Hyper-V host (WMI fallback mode).
    .PARAMETER Credential
        PSCredential for WMI authentication when using ComputerName.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        Get-HypervHostDetail -CimSession $session
        Returns OS, CPU, RAM, and uptime details for the Hyper-V host.
    .EXAMPLE
        Get-HypervHostDetail -ComputerName "hyperv01" -Credential $cred
        Returns the same details using WMI instead of a CIM session.
    #>
    [CmdletBinding(DefaultParameterSetName = 'CimSession')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'CimSession')]
        [Microsoft.Management.Infrastructure.CimSession]$CimSession,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$ComputerName,

        [Parameter(ParameterSetName = 'Direct')]
        [PSCredential]$Credential
    )

    if ($PSCmdlet.ParameterSetName -eq 'CimSession') {
        $targetName = $CimSession.ComputerName

        $os  = Get-CimInstance -CimSession $CimSession -ClassName Win32_OperatingSystem
        $cs  = Get-CimInstance -CimSession $CimSession -ClassName Win32_ComputerSystem
        $cpu = Get-CimInstance -CimSession $CimSession -ClassName Win32_Processor | Select-Object -First 1

        try {
            $netConfigs = Get-CimInstance -CimSession $CimSession -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True"
        }
        catch { $netConfigs = $null }

        $cpuCount = @(Get-CimInstance -CimSession $CimSession -ClassName Win32_Processor).Count

        # Host disks
        try {
            $hostDisks = @(Get-CimInstance -CimSession $CimSession -ClassName Win32_LogicalDisk -Filter "DriveType = 3")
        } catch { $hostDisks = @() }

        # Virtual switches
        try {
            $vSwitches = @(Get-CimInstance -CimSession $CimSession -Namespace 'root\virtualization\v2' -ClassName Msvm_VirtualEthernetSwitch)
        } catch { $vSwitches = @() }
    }
    else {
        $targetName = $ComputerName
        $wmiSplat = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        if ($Credential) { $wmiSplat['Credential'] = $Credential }

        $os  = Get-WmiObject -Class Win32_OperatingSystem @wmiSplat
        $cs  = Get-WmiObject -Class Win32_ComputerSystem @wmiSplat
        $cpu = Get-WmiObject -Class Win32_Processor @wmiSplat | Select-Object -First 1

        try {
            $netConfigs = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" @wmiSplat
        }
        catch { $netConfigs = $null }

        $cpuCount = @(Get-WmiObject -Class Win32_Processor @wmiSplat).Count

        # Host disks
        try {
            $hostDisks = @(Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType = 3" @wmiSplat)
        } catch { $hostDisks = @() }

        # Virtual switches
        try {
            $vSwitches = @(Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_VirtualEthernetSwitch @wmiSplat)
        } catch { $vSwitches = @() }
    }

    # Resolve real hostname from Win32_ComputerSystem
    if ($cs -and $cs.Name) { $targetName = $cs.Name }

    # Resolve IP from active adapters
    $ip = "N/A"
    if ($netConfigs) {
        $foundIP = $netConfigs |
            ForEach-Object { $_.IPAddress } |
            Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
            Select-Object -First 1
        if ($foundIP) { $ip = $foundIP }
    }

    # LastBootUpTime handling (WMI returns string, CIM returns DateTime)
    $uptimeHours = 0
    try {
        if ($os.LastBootUpTime -is [datetime]) {
            $uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        }
        else {
            $boot = [System.Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
            $uptimeHours = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
        }
    }
    catch { }

    # NIC count
    $nicCount = if ($netConfigs) { @($netConfigs).Count } else { 0 }

    # Disk summary — per-drive details
    $diskSummary = ''
    $diskTotalGB = 0
    $diskFreeGB  = 0
    if ($hostDisks.Count -gt 0) {
        $driveParts = @()
        foreach ($d in $hostDisks) {
            $dTotal = [math]::Round([long]$d.Size / 1GB, 0)
            $dFree  = [math]::Round([long]$d.FreeSpace / 1GB, 0)
            $diskTotalGB += $dTotal
            $diskFreeGB  += $dFree
            $driveParts += "$($d.DeviceID) $dFree/$($dTotal) GB"
        }
        $diskSummary = $driveParts -join ', '
    }

    # Virtual switch names
    $switchNames = ($vSwitches | ForEach-Object { $_.ElementName } | Select-Object -Unique) -join ', '

    [PSCustomObject]@{
        Type             = "Hyper-V Host"
        HostName         = $targetName
        IPAddress        = $ip
        OSName           = "$($os.Caption)"
        OSVersion        = "$($os.Version)"
        OSBuild          = "$($os.BuildNumber)"
        Manufacturer     = "$($cs.Manufacturer)"
        Model            = "$($cs.Model)"
        Domain           = "$($cs.Domain)"
        CPUModel         = "$($cpu.Name)"
        CPUSockets       = "$cpuCount"
        CPUCores         = "$($cpu.NumberOfCores)"
        CPULogical       = "$($cpu.NumberOfLogicalProcessors)"
        RAM_TotalGB      = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2))"
        RAM_FreeGB       = "$([math]::Round($os.FreePhysicalMemory / 1MB, 2))"
        Uptime           = "$uptimeHours hours"
        Status           = if ($os.Status -eq "OK") { "running" } else { "$($os.Status)" }
        NicCount         = "$nicCount"
        DiskSummary      = $diskSummary
        DiskTotalGB      = "$diskTotalGB"
        DiskFreeGB       = "$diskFreeGB"
        SwitchNames      = $switchNames
    }
}

function Get-HypervVMs {
    <#
    .SYNOPSIS
        Returns a list of VMs on the Hyper-V host.
    .PARAMETER CimSession
        An active CIM session to the Hyper-V host.
    .PARAMETER ComputerName
        Hostname or IP of the Hyper-V host (WMI fallback mode).
    .PARAMETER Credential
        PSCredential for WMI authentication when using ComputerName.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        $vms = Get-HypervVMs -CimSession $session
        Returns all VMs on the Hyper-V host.
    .EXAMPLE
        $vms = Get-HypervVMs -ComputerName "hyperv01" -Credential $cred
        Returns all VMs using WMI instead of a CIM session.
    #>
    [CmdletBinding(DefaultParameterSetName = 'CimSession')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'CimSession')]
        [Microsoft.Management.Infrastructure.CimSession]$CimSession,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$ComputerName,

        [Parameter(ParameterSetName = 'Direct')]
        [PSCredential]$Credential
    )

    if ($PSCmdlet.ParameterSetName -eq 'CimSession') {
        Get-VM -CimSession $CimSession
    }
    else {
        $wmiSplat = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        if ($Credential) { $wmiSplat['Credential'] = $Credential }

        $wmiVMs = Get-WmiObject -Namespace 'root\virtualization\v2' -Class Msvm_ComputerSystem @wmiSplat |
            Where-Object { $_.Caption -eq 'Virtual Machine' }

        foreach ($wv in $wmiVMs) {
            [PSCustomObject]@{
                Name               = $wv.ElementName
                VMId               = $wv.Name
                State              = switch ([int]$wv.EnabledState) {
                    2     { 'Running' }
                    3     { 'Off' }
                    6     { 'Saved' }
                    9     { 'Paused' }
                    32768 { 'Paused' }
                    32769 { 'Suspended' }
                    default { "Unknown($($wv.EnabledState))" }
                }
                ProcessorCount     = 0
                CPUUsage           = 0
                MemoryAssigned     = 0
                MemoryStartup      = 0
                DynamicMemoryEnabled = $false
                Generation         = 0
                Version            = ''
                Uptime             = [timespan]::Zero
                Status             = 'OK'
                ReplicationState   = 'None'
                Notes              = ''
                _WmiMode           = $true
                _WmiObject         = $wv
            }
        }
    }
}

function Get-HypervVMDetail {
    <#
    .SYNOPSIS
        Gathers detailed information about a single Hyper-V VM.
    .PARAMETER CimSession
        An active CIM session to the Hyper-V host.
    .PARAMETER VM
        A VM object returned by Get-VM or Get-HypervVMs.
    .PARAMETER ComputerName
        Hostname or IP of the Hyper-V host (WMI fallback mode).
    .PARAMETER Credential
        PSCredential for WMI authentication when using ComputerName.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        $vms = Get-HypervVMs -CimSession $session
        Get-HypervVMDetail -CimSession $session -VM $vms[0]
    .EXAMPLE
        $vms = Get-HypervVMs -ComputerName "hyperv01" -Credential $cred
        Get-HypervVMDetail -ComputerName "hyperv01" -Credential $cred -VM $vms[0]
    #>
    [CmdletBinding(DefaultParameterSetName = 'CimSession')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'CimSession')]
        [Microsoft.Management.Infrastructure.CimSession]$CimSession,

        [Parameter(Mandatory)]$VM,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$ComputerName,

        [Parameter(ParameterSetName = 'Direct')]
        [PSCredential]$Credential
    )

    # ---- WMI / Direct mode ------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Direct') {
        $hostName = $ComputerName
        $wmiSplat = @{ ComputerName = $ComputerName; ErrorAction = 'SilentlyContinue' }
        if ($Credential) { $wmiSplat['Credential'] = $Credential }

        $ns = 'root\virtualization\v2'
        $vmGuid = $VM.VMId

        # --- VM Settings (generation, notes) ---
        $generation = '0'
        $notes = ''
        $guestOSName = ''
        try {
            $vssd = Get-WmiObject -Namespace $ns -Class Msvm_VirtualSystemSettingData @wmiSplat |
                Where-Object { $_.VirtualSystemIdentifier -eq $vmGuid -and $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
            if ($vssd) {
                $generation = if ($vssd.VirtualSystemSubType -eq 'Microsoft:Hyper-V:SubType:2') { '2' } else { '1' }
                $noteText = if ($vssd.Notes) {
                    if ($vssd.Notes -is [array]) { "$($vssd.Notes[0])" } else { "$($vssd.Notes)" }
                } else { '' }
                if ($noteText.Length -gt 200) { $noteText = $noteText.Substring(0, 200) }
                $notes = $noteText
            }
        } catch {}

        # --- CPU count ---
        $cpuCount = 0
        try {
            $cpuSD = Get-WmiObject -Namespace $ns -Class Msvm_ProcessorSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            if ($cpuSD) { $cpuCount = [int]$cpuSD.VirtualQuantity }
        } catch {}

        # --- Memory (startup, dynamic) ---
        $memStartupMB = 0
        $memDynamic = $false
        try {
            $memSD = Get-WmiObject -Namespace $ns -Class Msvm_MemorySettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            if ($memSD) {
                $memStartupMB = [long]$memSD.VirtualQuantity
                $memDynamic = [bool]$memSD.DynamicMemoryEnabled
            }
        } catch {}
        $memStartupGB = [math]::Round($memStartupMB / 1024, 2)
        $memAssignedGB = $memStartupGB

        # --- IP addresses ---
        $vmIP = 'N/A'
        # Method 1: Msvm_GuestNetworkAdapterConfiguration (modern, preferred)
        try {
            $guestNicConfigs = Get-WmiObject -Namespace $ns -Class Msvm_GuestNetworkAdapterConfiguration @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            foreach ($gnic in @($guestNicConfigs)) {
                if ($gnic.IPAddresses) {
                    $foundIP = @($gnic.IPAddresses) |
                        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
                        Select-Object -First 1
                    if ($foundIP) { $vmIP = $foundIP; break }
                }
            }
        } catch {}

        # Method 2: KVP exchange (fallback, with IP format validation)
        if ($vmIP -eq 'N/A') {
            try {
                $kvpItems = Get-WmiObject -Namespace $ns -Class Msvm_KvpExchangeComponent @wmiSplat |
                    Where-Object { $_.SystemName -eq $vmGuid }
                if ($kvpItems -and $kvpItems.GuestIntrinsicExchangeItems) {
                    foreach ($item in $kvpItems.GuestIntrinsicExchangeItems) {
                        try {
                            $xml = [xml]$item
                            $kvpName = ($xml.SelectNodes("//PROPERTY[@NAME='Name']/VALUE")).InnerText
                            $kvpVal  = ($xml.SelectNodes("//PROPERTY[@NAME='Data']/VALUE")).InnerText
                            if ($kvpName -eq 'NetworkAddressIPv4' -and $kvpVal -match '^\d{1,3}(\.\d{1,3}){3}$' -and $kvpVal -notlike '169.254.*') {
                                $vmIP = $kvpVal; break
                            }
                        } catch {}
                    }
                }
            } catch {}
        }

        # --- Guest OS name from KVP (for fallback Notes) ---
        try {
            $kvpItems2 = Get-WmiObject -Namespace $ns -Class Msvm_KvpExchangeComponent @wmiSplat |
                Where-Object { $_.SystemName -eq $vmGuid }
            if ($kvpItems2 -and $kvpItems2.GuestIntrinsicExchangeItems) {
                foreach ($item in $kvpItems2.GuestIntrinsicExchangeItems) {
                    try {
                        $xml = [xml]$item
                        $kvpName = ($xml.SelectNodes("//PROPERTY[@NAME='Name']/VALUE")).InnerText
                        $kvpVal  = ($xml.SelectNodes("//PROPERTY[@NAME='Data']/VALUE")).InnerText
                        if ($kvpName -eq 'OSName' -and $kvpVal) {
                            $guestOSName = "$kvpVal"; break
                        }
                    } catch {}
                }
            }
        } catch {}

        # If no user-set notes, use guest OS name as fallback
        if (-not $notes -and $guestOSName) { $notes = $guestOSName }

        # --- NICs (synthetic + legacy) ---
        $nicCount = 0
        try {
            $vmNics = Get-WmiObject -Namespace $ns -Class Msvm_SyntheticEthernetPortSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            $nicCount = @($vmNics).Count
        } catch {}
        try {
            $legacyNics = Get-WmiObject -Namespace $ns -Class Msvm_EmulatedEthernetPortSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            $nicCount += @($legacyNics).Count
        } catch {}

        # --- Virtual switch names ---
        $switchNames = ''
        try {
            $allSwitches = @{}
            Get-WmiObject -Namespace $ns -Class Msvm_VirtualEthernetSwitch @wmiSplat | ForEach-Object {
                $allSwitches[$_.Name] = $_.ElementName
            }
            $portAllocs = Get-WmiObject -Namespace $ns -Class Msvm_EthernetPortAllocationSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            $swNames = @()
            foreach ($pa in @($portAllocs)) {
                if ($pa.HostResource) {
                    foreach ($hr in $pa.HostResource) {
                        if ($hr -match 'Name="([^"]+)"') {
                            $swGuid = $Matches[1]
                            if ($allSwitches.ContainsKey($swGuid)) {
                                $swNames += $allSwitches[$swGuid]
                            }
                        }
                    }
                }
            }
            $switchNames = ($swNames | Select-Object -Unique) -join ', '
        } catch {}

        # --- VLAN IDs ---
        $vlanIds = ''
        try {
            $vlanSettings = Get-WmiObject -Namespace $ns -Class Msvm_EthernetSwitchPortVlanSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            $vids = @($vlanSettings | ForEach-Object { $_.AccessVlanId } | Where-Object { $_ -and $_ -ne 0 } | Select-Object -Unique)
            $vlanIds = $vids -join ', '
        } catch {}

        # --- Storage / disks ---
        $diskCount = 0
        $diskTotalGB = 0
        try {
            $storSD = Get-WmiObject -Namespace $ns -Class Msvm_StorageAllocationSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" -and $_.HostResource.Count -gt 0 }
            $diskCount = @($storSD).Count
            foreach ($sd in @($storSD)) {
                try {
                    # Limit = max VHD size in bytes (most reliable)
                    if ($sd.Limit -and [long]$sd.Limit -gt 0) {
                        $diskTotalGB += [math]::Round([long]$sd.Limit / 1GB, 2)
                    }
                    elseif ($sd.VirtualQuantity -and $sd.VirtualResourceBlockSize -and
                            [long]$sd.VirtualQuantity -gt 0 -and [long]$sd.VirtualResourceBlockSize -gt 0) {
                        $diskTotalGB += [math]::Round(([long]$sd.VirtualQuantity * [long]$sd.VirtualResourceBlockSize) / 1GB, 2)
                    }
                    elseif ($sd.HostResource) {
                        # Fall back to VHD file size on disk
                        foreach ($hr in $sd.HostResource) {
                            try {
                                $vhdPath = ($hr -replace '\\\\', '\').Trim()
                                $escapedPath = $vhdPath -replace '\\', '\\' -replace "'", "''"
                                $fileObj = Get-WmiObject -Class CIM_DataFile -Filter "Name='$escapedPath'" @wmiSplat
                                if ($fileObj -and $fileObj.FileSize) {
                                    $diskTotalGB += [math]::Round([long]$fileObj.FileSize / 1GB, 2)
                                }
                            } catch {}
                        }
                    }
                } catch {}
            }
        } catch {}

        # --- Snapshots ---
        $snapshotCount = 0
        try {
            $snapshots = @(Get-WmiObject -Namespace $ns -Class Msvm_VirtualSystemSettingData @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" -and $_.VirtualSystemType -like '*Snapshot*' })
            $snapshotCount = $snapshots.Count
        } catch {}

        # --- Heartbeat ---
        $heartbeatText = 'N/A'
        try {
            $hbComp = Get-WmiObject -Namespace $ns -Class Msvm_HeartbeatComponent @wmiSplat |
                Where-Object { $_.SystemName -eq $vmGuid }
            if ($hbComp -and $hbComp.OperationalStatus) {
                $heartbeatText = switch ([int]$hbComp.OperationalStatus[0]) {
                    2  { 'OK' }
                    12 { 'No Contact' }
                    13 { 'Lost Communication' }
                    default { "Unknown($($hbComp.OperationalStatus[0]))" }
                }
            }
        } catch {}

        # --- Uptime ---
        $uptimeStr = '00:00:00'
        try {
            $vmWmi = if ($VM._WmiObject) { $VM._WmiObject } else {
                Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem @wmiSplat |
                    Where-Object { $_.Name -eq $vmGuid }
            }
            if ($vmWmi -and $vmWmi.OnTimeInMilliseconds -and [long]$vmWmi.OnTimeInMilliseconds -gt 0) {
                $ts = [timespan]::FromMilliseconds([long]$vmWmi.OnTimeInMilliseconds)
                $uptimeStr = $ts.ToString('d\.hh\:mm\:ss')
            }
        } catch {}

        # --- Replication ---
        $replState = 'None'
        try {
            $repl = Get-WmiObject -Namespace $ns -Class Msvm_ReplicationRelationship @wmiSplat |
                Where-Object { $_.InstanceID -like "*$vmGuid*" }
            if ($repl) {
                $replState = switch ([int]$repl.ReplicationState) {
                    0 { 'Disabled' }; 1 { 'ReadyForInitialReplication' }
                    2 { 'WaitingToCompleteInitialReplication' }; 3 { 'Replicating' }
                    4 { 'SyncedReplicationComplete' }; 5 { 'Recovered' }
                    6 { 'Committed' }; 7 { 'Suspended' }; 8 { 'Critical' }
                    9 { 'WaitingForStartResynchronize' }; 10 { 'Resynchronizing' }
                    default { "Unknown($($repl.ReplicationState))" }
                }
            }
        } catch {}

        return [PSCustomObject]@{
            Name              = "$($VM.Name)"
            VMId              = "$($VM.VMId)"
            Host              = $hostName
            State             = "$($VM.State)"
            Status            = "$($VM.Status)"
            IPAddress         = $vmIP
            Generation        = $generation
            Version           = "$($VM.Version)"
            Uptime            = $uptimeStr
            CPUCount          = "$cpuCount"
            CPUUsagePct       = "$($VM.CPUUsage)%"
            MemoryAssignedGB  = "$memAssignedGB"
            MemoryStartupGB   = "$memStartupGB"
            DynamicMemory     = "$memDynamic"
            DiskCount         = "$diskCount"
            DiskTotalGB       = "$([math]::Round($diskTotalGB, 2))"
            NicCount          = "$nicCount"
            SwitchNames       = $switchNames
            VLanIds           = $vlanIds
            SnapshotCount     = "$snapshotCount"
            Heartbeat         = $heartbeatText
            ReplicationState  = $replState
            Notes             = $notes
        }
    }

    # ---- CIM session mode (original) -------------------------------------
    $hostName = $CimSession.ComputerName

    # Network adapters and IP
    $nics = Get-VMNetworkAdapter -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue
    $ip = $nics |
        ForEach-Object { $_.IPAddresses } |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $ip) { $ip = "N/A" }

    # VHDs
    $vhds = Get-VMHardDiskDrive -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue
    $vhdCount = @($vhds).Count
    $totalDiskGB = 0
    foreach ($vhd in $vhds) {
        try {
            $vhdInfo = Get-VHD -CimSession $CimSession -Path $vhd.Path -ErrorAction SilentlyContinue
            if ($vhdInfo) { $totalDiskGB += $vhdInfo.Size / 1GB }
        }
        catch { }
    }

    # Memory
    $memAssigned = if ($VM.MemoryAssigned) { [math]::Round($VM.MemoryAssigned / 1GB, 2) } else { 0 }
    $memStartup  = if ($VM.MemoryStartup)  { [math]::Round($VM.MemoryStartup / 1GB, 2) }  else { 0 }
    $memDynamic  = $VM.DynamicMemoryEnabled

    # Snapshots / checkpoints
    $snapshots = @(Get-VMSnapshot -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue)

    # Integration services
    $intSvc = Get-VMIntegrationService -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue
    $heartbeat = ($intSvc | Where-Object { $_.Name -eq "Heartbeat" }).PrimaryStatusDescription

    [PSCustomObject]@{
        Name              = "$($VM.Name)"
        VMId              = "$($VM.VMId)"
        Host              = $hostName
        State             = "$($VM.State)"
        Status            = "$($VM.Status)"
        IPAddress         = $ip
        Generation        = "$($VM.Generation)"
        Version           = "$($VM.Version)"
        Uptime            = "$($VM.Uptime)"
        CPUCount          = "$($VM.ProcessorCount)"
        CPUUsagePct       = "$($VM.CPUUsage)%"
        MemoryAssignedGB  = "$memAssigned"
        MemoryStartupGB   = "$memStartup"
        DynamicMemory     = "$memDynamic"
        DiskCount         = "$vhdCount"
        DiskTotalGB       = "$([math]::Round($totalDiskGB, 2))"
        NicCount          = "$(@($nics).Count)"
        SwitchNames       = ($nics | ForEach-Object { $_.SwitchName } | Select-Object -Unique) -join ", "
        VLanIds           = ($nics | ForEach-Object { $_.VlanSetting.AccessVlanId } | Where-Object { $_ } | Select-Object -Unique) -join ", "
        SnapshotCount     = "$($snapshots.Count)"
        Heartbeat         = if ($heartbeat) { "$heartbeat" } else { "N/A" }
        ReplicationState  = "$($VM.ReplicationState)"
        Notes             = if ($VM.Notes) { "$($VM.Notes.Substring(0, [math]::Min(200, $VM.Notes.Length)))" } else { "$($VM.GuestOperatingSystem)" }
    }
}

function Get-HypervDashboard {
    <#
    .SYNOPSIS
        Builds a flat dashboard view combining Hyper-V hosts and their VMs.
    .DESCRIPTION
        Connects to one or more Hyper-V hosts, gathers host details and VM
        details, then returns a unified collection of objects suitable for
        rendering in an interactive Bootstrap Table dashboard. Each row
        represents a VM enriched with its parent host context including
        host CPU model, RAM, OS, and IP address.
    .PARAMETER CimSessions
        One or more active CIM sessions to Hyper-V hosts. Create sessions
        using Connect-HypervHost.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        Get-HypervDashboard -CimSessions $session

        Returns a flat dashboard view of all VMs across the specified host.
    .EXAMPLE
        $sessions = @("hyperv01","hyperv02") | ForEach-Object { Connect-HypervHost -ComputerName $_ -Credential $cred }
        $dashboard = Get-HypervDashboard -CimSessions $sessions

        Returns a unified view across multiple Hyper-V hosts.
    .EXAMPLE
        $cred = Get-Credential
        $sessions = @("hyperv01","hyperv02") | ForEach-Object { Connect-HypervHost -ComputerName $_ -Credential $cred }
        $data = Get-HypervDashboard -CimSessions $sessions
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "C:\Reports\hyperv.html"
        Start-Process "C:\Reports\hyperv.html"

        End-to-end: connect to hosts, gather dashboard data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains VM details enriched with host context: VMName, State, Status,
        IPAddress, Host, HostIP, HostOS, HostCPUModel, HostRAM_TotalGB, HostRAM_FreeGB,
        Generation, CPUCount, CPUUsagePct, MemoryAssignedGB, MemoryStartupGB, DynamicMemory,
        DiskCount, DiskTotalGB, NicCount, SwitchNames, VLanIds, SnapshotCount, Heartbeat,
        ReplicationState, Uptime, Notes.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Hyper-V PowerShell module, CIM sessions to target hosts.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [Parameter(Mandatory)]$CimSessions
    )

    if ($CimSessions -isnot [System.Collections.IEnumerable] -or $CimSessions -is [string]) {
        $CimSessions = @($CimSessions)
    }

    $results = @()

    foreach ($session in $CimSessions) {
        $hostDetail = Get-HypervHostDetail -CimSession $session
        $vms = Get-HypervVMs -CimSession $session

        foreach ($vm in $vms) {
            $vmDetail = Get-HypervVMDetail -CimSession $session -VM $vm

            $results += [PSCustomObject]@{
                VMName            = $vmDetail.Name
                State             = $vmDetail.State
                Status            = $vmDetail.Status
                IPAddress         = $vmDetail.IPAddress
                Host              = $hostDetail.HostName
                HostIP            = $hostDetail.IPAddress
                HostOS            = $hostDetail.OSName
                HostCPUModel      = $hostDetail.CPUModel
                HostRAM_TotalGB   = $hostDetail.RAM_TotalGB
                HostRAM_FreeGB    = $hostDetail.RAM_FreeGB
                Generation        = $vmDetail.Generation
                CPUCount          = $vmDetail.CPUCount
                CPUUsagePct       = $vmDetail.CPUUsagePct
                MemoryAssignedGB  = $vmDetail.MemoryAssignedGB
                MemoryStartupGB   = $vmDetail.MemoryStartupGB
                DynamicMemory     = $vmDetail.DynamicMemory
                DiskCount         = $vmDetail.DiskCount
                DiskTotalGB       = $vmDetail.DiskTotalGB
                NicCount          = $vmDetail.NicCount
                SwitchNames       = $vmDetail.SwitchNames
                VLanIds           = $vmDetail.VLanIds
                SnapshotCount     = $vmDetail.SnapshotCount
                Heartbeat         = $vmDetail.Heartbeat
                ReplicationState  = $vmDetail.ReplicationState
                Uptime            = "$($vmDetail.Uptime)"
                Notes             = $vmDetail.Notes
            }
        }
    }

    return $results
}

function Export-HypervDashboardHtml {
    <#
    .SYNOPSIS
        Renders Hyper-V dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-HypervDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-HypervDashboard containing VM and host details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Hyper-V Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        Hyperv-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-HypervDashboard -CimSessions $sessions
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "C:\Reports\hyperv.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\hyperv.html" -ReportTitle "Production Hyper-V"

        Exports with a custom report title.
    .EXAMPLE
        $cred = Get-Credential
        $sessions = @("hv01","hv02") | ForEach-Object { Connect-HypervHost -ComputerName $_ -Credential $cred }
        $data = Get-HypervDashboard -CimSessions $sessions
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "C:\Reports\hyperv.html"
        Start-Process "C:\Reports\hyperv.html"

        Full pipeline: connect, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Hyperv-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Hyper-V Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Hyperv-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'State') {
            $col.formatter = 'formatState'
        }
        if ($prop.Name -eq 'Heartbeat') {
            $col.formatter = 'formatHeartbeat'
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = ConvertTo-Json -InputObject @($DashboardData) -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Hyper-V Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCe3QY3m9SmpdJ/
# CM6R1gev+j99Tj3pm3CHupFxpN/OMqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgQcw1xsgi8BqxYiL9OubAqxud6Y9MxlDc
# s1Ze18YtdWkwDQYJKoZIhvcNAQEBBQAEggIAqhMs/hVk+oHk9C4rD4dY8FM1hVFH
# cE6bgc50yw2AQ39LQnPEPxPNvpOt3kJa3W7WnwiIQGgopiliBCpSQwXTA2ojL3os
# PcfvB6fpfc5EnVAg4f5Tt7ftTTXCRx/7jX75h1ODFaipuldvSp3LLI8h58RnR50U
# 9lMjMZJ4zJzs49k6Fe/+OzJlZXpPBo0afWz0SH8/JHCmMoBItqkNLcL13LNkYWvk
# 7kojENVCCrVT349XiUJGCvBhu8j4aP9hFhUoRk3FR/Dqw77f2hrJIqXs0GLOhROZ
# YFdqRl2+ZjucJCiH5ziqYvsoWSaz0HR4MXzF8URua3tTCA/DBO/brCjJCHce8Xhu
# JsKShb/1FUUZR7F9boj86zYt+6BvjJw6fpyi2Ao0dudIvueArZ+KaYHv/cD+peEy
# HKRriSp6wzTdrliQUKNsOmVjbLxodD3MMgqnXpSOo3GeHrAFuPKUKLHP0RTR6Nmj
# VnJ9+7RptdlzqGCtrMRfvROjv2XHeLraaKcV+lzFlFVYSVyD8W5f11nZBkJSiPm1
# lYvMr4UyD8uRARsKQWMZ+fuxe7PG15rCC+pVVUcz0H2NSHxW8snMT3OciutEkxR2
# V2a8Qf3jOPV7/VQYgMtYmZ8+GHG2SKkUt15LbM06ss2iuQzfs3CpDdLUqk6mc26j
# q48BnDND9mJIbhs=
# SIG # End signature block
