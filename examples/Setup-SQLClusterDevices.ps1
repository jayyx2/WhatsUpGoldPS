#requires -Version 5.1
<#
.SYNOPSIS
    Sets up WhatsUp Gold devices for a Windows Server Failover Cluster (WSFC) that hosts
    SQL Server, so that shared cluster resources are monitored on their virtual IP and
    node-local resources are monitored on the physical node.

.DESCRIPTION
    Monitoring a failover cluster correctly requires the WUG device layout to mirror the
    cluster layout. This script audits and remediates that layout.

    THE MODEL
      - Each PHYSICAL NODE is its own device, addressed by the node IP. It owns node-local
        resources: CPU, memory, local disks, NIC, OS services, cluster service health, and
        any non-clustered SQL instance installed on that node.
      - Each SHARED (clustered) ROLE is its own STANDALONE device, addressed by the role's
        VIRTUAL IP and named after its virtual network name (VNN). It owns the shared
        resources: the SQL Failover Cluster Instance, its databases, and the role's
        availability. Because the role floats, the virtual device keeps reporting through a
        failover while the node devices do not.
      - Availability Group listeners get the same treatment as a role.
      - The cluster name object (CNO / "Cluster Group") can optionally get its own device so
        that core cluster health is visible independently of any node.

    WHAT THIS SCRIPT DOES
      1. Probes one or more cluster nodes over WMI (root\MSCluster) and builds the full
         cluster topology: nodes, resource groups, network names, virtual IPs, SQL FCIs and
         Availability Groups.
      2. Audits WhatsUp Gold: which nodes exist as devices, which virtual roles already have
         a standalone device, and which are missing.
      3. Creates the missing standalone virtual devices (VNN + VIP), tagged with cluster
         attributes so they can be found later or used in dynamic groups.
      4. CLEANUP -- flags a virtual IP that has been attached as a secondary interface on a
         node device. That is the most common mis-setup: the VIP answers ping through the
         node device, so failovers look healthy when they are not. Optionally removes the
         stray interface.
      5. CLEANUP -- finds shared-resource monitors that are assigned to the PHYSICAL NODE
         devices and reports, disables, or removes them. Those monitors go unknown/down on
         whichever node does not currently own the role, which is the usual source of false
         alarms on a cluster.

    Run it once in report mode, review, then re-run with -NodeCleanupAction Disable.

    After this script has established the device layout, run the SQL discovery helper
    (helpers/discovery/Setup-MSSQL-Discovery.ps1) against the VIRTUAL device to attach the
    database and instance performance monitors to the right place.

.PARAMETER ClusterNode
    One or more cluster node names or IP addresses to probe over WMI. Any single reachable
    node returns the whole cluster topology; supplying several just adds resilience.

.PARAMETER Credential
    PSCredential with WMI/administrative access to the cluster node(s). Omit when the
    current user already has access, or when probing the local machine.

.PARAMETER DeviceGroupName
    Optional WUG device group to place newly created virtual devices into.

.PARAMETER Brand
    Brand/vendor string stamped on created virtual devices. Default: 'Microsoft'.

.PARAMETER WindowsCredentialName
    Optional name of an existing WUG Windows credential to associate with created virtual
    devices, so WMI-based monitors can poll them.

.PARAMETER IncludeClusterCore
    Also create a standalone device for the cluster name object (CNO / core cluster group).

.PARAMETER IncludeOtherRoles
    Also create standalone devices for non-SQL clustered roles that own a network name and a
    virtual IP (file server, generic service, DTC, and so on).

.PARAMETER SkipAvailabilityGroups
    Do not create devices for Always On Availability Group listeners.

.PARAMETER SkipDeviceCreation
    Audit and clean up only. Never create devices.

.PARAMETER NodeCleanupAction
    What to do with shared-resource monitors found on the PHYSICAL NODE devices.
      Report  - (default) list them and make no changes.
      Disable - set the assignment to disabled. Reversible, keeps history.
      Remove  - delete the monitor assignment from the node.

.PARAMETER SharedMonitorPattern
    Extra wildcard patterns identifying shared-resource monitors on node devices. The script
    always looks for monitors naming a discovered virtual server, AG listener, or clustered
    SQL instance; use this to catch monitors that follow a local naming convention.
    Example: 'MSSQL*','SQLServer:*'

.PARAMETER RemoveVipInterfaceFromNodes
    Remove a virtual IP that is attached as a secondary interface on a node device. Without
    this switch the condition is only reported.

.PARAMETER WUGServer
    WhatsUp Gold server hostname or IP. If omitted, the script assumes Connect-WUGServer has
    already been run.

.PARAMETER WUGPort
    WhatsUp Gold API port. Default: 9644.

.PARAMETER WUGCredential
    PSCredential used to connect to WhatsUp Gold when -WUGServer is supplied.

.PARAMETER IgnoreSSLErrors
    Ignore certificate errors when connecting to WhatsUp Gold.

.EXAMPLE
    .\Setup-SQLClusterDevices.ps1 -ClusterNode 'SQLNODE1' -WhatIf

    Preview: show the cluster topology, what devices would be created, and what cleanup is
    outstanding, without changing anything.

.EXAMPLE
    .\Setup-SQLClusterDevices.ps1 -ClusterNode 'SQLNODE1' -Credential (Get-Credential)

    Report mode. Creates the missing virtual devices and lists the node-level cleanup that
    still needs to be done.

.EXAMPLE
    .\Setup-SQLClusterDevices.ps1 -ClusterNode 'SQLNODE1' -NodeCleanupAction Disable `
        -DeviceGroupName 'SQL Clusters'

    Creates the virtual devices in the 'SQL Clusters' group and disables shared-resource
    monitors that are currently assigned to the physical nodes.

.EXAMPLE
    .\Setup-SQLClusterDevices.ps1 -ClusterNode 'SQLNODE1' -NodeCleanupAction Disable `
        -SharedMonitorPattern 'MSSQL*','SQL Agent*' -RemoveVipInterfaceFromNodes

    Full remediation, including detaching virtual IPs that were added as extra interfaces on
    the node devices.

.EXAMPLE
    .\Setup-SQLClusterDevices.ps1 -ClusterNode 'SQLNODE1' -IncludeClusterCore -IncludeOtherRoles

    Also give the cluster name object and every other clustered role with a VIP its own device.

.NOTES
    Requires: WhatsUpGoldPS module, WMI access to the cluster node(s)
    Compatible with PowerShell 5.1+
    Author:   jayyx2 + Copilot

.LINK
    https://docs.ipswitch.com/NM/WhatsUpGold2026/02_Guides/rest_api/index.html
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'WindowsCredentialName',
    Justification = 'This is the name of a credential already sto red in WhatsUp Gold, not a secret.')]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$ClusterNode,

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$DeviceGroupName,

    [Parameter()]
    [string]$Brand = 'Microsoft',

    [Parameter()]
    [string]$WindowsCredentialName,

    [Parameter()]
    [switch]$IncludeClusterCore,

    [Parameter()]
    [switch]$IncludeOtherRoles,

    [Parameter()]
    [switch]$SkipAvailabilityGroups,

    [Parameter()]
    [switch]$SkipDeviceCreation,

    [Parameter()]
    [ValidateSet('Report', 'Disable', 'Remove')]
    [string]$NodeCleanupAction = 'Report',

    [Parameter()]
    [string[]]$SharedMonitorPattern,

    [Parameter()]
    [switch]$RemoveVipInterfaceFromNodes,

    [Parameter()]
    [string]$WUGServer,

    [Parameter()]
    [int]$WUGPort = 9644,

    [Parameter()]
    [PSCredential]$WUGCredential,

    [Parameter()]
    [switch]$IgnoreSSLErrors
)

#region Module import and connection
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    Import-Module WhatsUpGoldPS -ErrorAction Stop
}

if ($WUGServer) {
    $connSplat = @{ ServerUri = $WUGServer; Port = $WUGPort }
    if ($WUGCredential)   { $connSplat.Credential = $WUGCredential }
    if ($IgnoreSSLErrors) { $connSplat.IgnoreSSLErrors = $true }
    Connect-WUGServer @connSplat
}

if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) {
    Write-Error "Not connected to WhatsUp Gold. Run Connect-WUGServer first, or supply -WUGServer."
    return
}
#endregion

#region Helper functions

function Get-WSFCTopology {
    <#
    .SYNOPSIS
        Returns the failover cluster topology visible from a node, via root\MSCluster WMI.
    .DESCRIPTION
        Produces the cluster name, node list, and one entry per resource group that owns a
        network name and/or a virtual IP. Each role is classified as SqlFci,
        SqlAvailabilityGroup, ClusterCore, or Other.

        Returns $null when the host is not a cluster node (root\MSCluster absent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter()][PSCredential]$NodeCredential
    )

    $isLocal = ($ComputerName -eq 'localhost' -or $ComputerName -eq '.' -or
                $ComputerName -eq '127.0.0.1' -or $ComputerName -eq $env:COMPUTERNAME)

    $wmiSplat = @{ Namespace = 'root\MSCluster'; ErrorAction = 'Stop' }
    if (-not $isLocal) {
        $wmiSplat.ComputerName = $ComputerName
        if ($NodeCredential) { $wmiSplat.Credential = $NodeCredential }
    }

    try {
        $cluster = Get-WmiObject -Class MSCluster_Cluster @wmiSplat | Select-Object -First 1
    }
    catch {
        Write-Verbose "root\MSCluster not available on ${ComputerName}: $($_.Exception.Message)"
        return $null
    }
    if (-not $cluster) { return $null }

    $topology = [ordered]@{
        ClusterName = [string]$cluster.Name
        ProbedFrom  = $ComputerName
        Nodes       = @()
        Roles       = @()
    }

    try {
        $topology.Nodes = @(Get-WmiObject -Class MSCluster_Node @wmiSplat |
            ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Name; State = [int]$_.State } })
    }
    catch {
        Write-Verbose "Could not enumerate MSCluster_Node: $($_.Exception.Message)"
    }

    try {
        $resources = @(Get-WmiObject -Class MSCluster_Resource @wmiSplat)
    }
    catch {
        Write-Verbose "Could not enumerate MSCluster_Resource: $($_.Exception.Message)"
        return $topology
    }

    # A role's virtual identity lives on sibling resources in the same OwnerGroup.
    $groups = @{}
    foreach ($res in $resources) {
        $grp = [string]$res.OwnerGroup
        if (-not $grp) { continue }
        if (-not $groups.ContainsKey($grp)) {
            $groups[$grp] = [ordered]@{
                GroupName    = $grp
                Kind         = 'Other'
                NetworkNames = [System.Collections.Generic.List[string]]::new()
                VirtualIPs   = [System.Collections.Generic.List[string]]::new()
                SqlInstances = [System.Collections.Generic.List[string]]::new()
                AGNames      = [System.Collections.Generic.List[string]]::new()
                OwnerNode    = [string]$res.OwnerNode
            }
        }
        $g = $groups[$grp]
        $resType = [string]$res.Type

        if ($resType -like '*IP Address*') {
            $addr = $null
            try { $addr = [string]$res.PrivateProperties.Address } catch { }
            if ($addr -and -not $g.VirtualIPs.Contains($addr)) { $g.VirtualIPs.Add($addr) }
        }
        elseif ($resType -like '*Network Name*') {
            $nn = $null
            try { $nn = [string]$res.PrivateProperties.DnsName } catch { }
            if (-not $nn) { try { $nn = [string]$res.PrivateProperties.Name } catch { } }
            if (-not $nn) { $nn = [string]$res.Name }
            if ($nn -and -not $g.NetworkNames.Contains($nn)) { $g.NetworkNames.Add($nn) }
            if ([string]$res.Name -eq 'Cluster Name') { $g.Kind = 'ClusterCore' }
        }
        elseif ($resType -eq 'SQL Server') {
            $inst = $null
            $vs   = $null
            try { $inst = [string]$res.PrivateProperties.InstanceName } catch { }
            try { $vs = [string]$res.PrivateProperties.VirtualServerName } catch { }
            if (-not $inst) { $inst = 'MSSQLSERVER' }
            if (-not $g.SqlInstances.Contains($inst)) { $g.SqlInstances.Add($inst) }
            if ($vs -and -not $g.NetworkNames.Contains($vs)) { $g.NetworkNames.Add($vs) }
            $g.Kind = 'SqlFci'
        }
        elseif ($resType -like '*Availability Group*') {
            $agName = [string]$res.Name
            if ($agName -and -not $g.AGNames.Contains($agName)) { $g.AGNames.Add($agName) }
            if ($g.Kind -ne 'SqlFci') { $g.Kind = 'SqlAvailabilityGroup' }
        }
    }

    $roleList = [System.Collections.Generic.List[object]]::new()
    foreach ($grpName in ($groups.Keys | Sort-Object)) {
        $g = $groups[$grpName]
        if ($g.NetworkNames.Count -eq 0 -and $g.VirtualIPs.Count -eq 0) { continue }
        $roleList.Add([PSCustomObject]@{
            GroupName    = $g.GroupName
            Kind         = $g.Kind
            VirtualName  = if ($g.NetworkNames.Count -gt 0) { $g.NetworkNames[0] } else { $null }
            NetworkNames = @($g.NetworkNames)
            VirtualIPs   = @($g.VirtualIPs)
            SqlInstances = @($g.SqlInstances)
            AGNames      = @($g.AGNames)
            OwnerNode    = $g.OwnerNode
        })
    }
    $topology.Roles = @($roleList)

    return $topology
}

function Find-WUGDeviceMatch {
    <#
    .SYNOPSIS
        Finds an existing WUG device whose address or name exactly matches a candidate.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Address,
        [string[]]$Name
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($Address)) {
        if ($a -and -not $candidates.Contains([string]$a)) { $candidates.Add([string]$a) }
    }
    foreach ($n in @($Name)) {
        if (-not $n) { continue }
        if (-not $candidates.Contains([string]$n)) { $candidates.Add([string]$n) }
        if ($n -match '^([^.]+)\.') {
            $short = $Matches[1]
            if (-not $candidates.Contains($short)) { $candidates.Add($short) }
        }
    }

    foreach ($c in $candidates) {
        $found = $null
        try { $found = @(Get-WUGDevice -SearchValue $c) }
        catch {
            Write-Verbose "Device search for '$c' failed: $($_.Exception.Message)"
            continue
        }
        if (-not $found -or $found.Count -eq 0) { continue }

        $exact = $found | Where-Object {
            $_.networkAddress -eq $c -or $_.hostName -eq $c -or $_.displayName -eq $c
        } | Select-Object -First 1
        if ($exact) { return $exact }
    }
    return $null
}

function Get-DeviceMonitorAssignment {
    <#
    .SYNOPSIS
        Returns active and performance monitor assignments for a device in one shape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$DeviceId
    )

    $list = [System.Collections.Generic.List[object]]::new()

    try {
        foreach ($m in @(Get-WUGActiveMonitor -DeviceId $DeviceId)) {
            $aid = if ($m.DeviceMonitorAssignmentId) { $m.DeviceMonitorAssignmentId } else { $m.AssignmentId }
            if (-not $aid) { continue }
            $list.Add([PSCustomObject]@{
                AssignmentId = $aid
                Name         = if ($m.Name) { $m.Name } else { $m.MonitorTypeName }
                Kind         = 'Active'
                Enabled      = $m.Enabled
            })
        }
    }
    catch {
        Write-Verbose "Could not list active monitors for device ${DeviceId}: $($_.Exception.Message)"
    }

    try {
        foreach ($m in @(Get-WUGPerformanceMonitor -DeviceId $DeviceId -View 'basic')) {
            $aid = if ($m.AssignmentId) { $m.AssignmentId } else { $m.DeviceMonitorAssignmentId }
            if (-not $aid) { continue }
            $list.Add([PSCustomObject]@{
                AssignmentId = $aid
                Name         = if ($m.Name) { $m.Name } else { $m.MonitorTypeName }
                Kind         = 'Performance'
                Enabled      = $m.Enabled
            })
        }
    }
    catch {
        Write-Verbose "Could not list performance monitors for device ${DeviceId}: $($_.Exception.Message)"
    }

    return @($list)
}

function Set-DeviceMonitorEnabled {
    <#
    .SYNOPSIS
        Enables or disables a single monitor assignment on a device.
    .DESCRIPTION
        PUT /api/v1/devices/{deviceId}/monitors/{assignmentId} is generic across monitor
        types, so this covers both active and performance assignments.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][int]$DeviceId,
        [Parameter(Mandatory = $true)][string]$AssignmentId,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $uri  = "${global:WhatsUpServerBaseURI}/api/v1/devices/${DeviceId}/monitors/${AssignmentId}"
    $body = @{ enabled = $Enabled } | ConvertTo-Json -Depth 3

    if (-not $PSCmdlet.ShouldProcess("assignment ${AssignmentId} on device ${DeviceId}", "Set enabled=${Enabled}")) { return }

    return Get-WUGAPIResponse -Uri $uri -Method PUT -Body $body
}

#endregion

#region STEP 1 -- Probe cluster topology

Write-Host ""
Write-Host "=== WSFC / SQL Cluster Device Setup ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "STEP 1: Probing cluster topology..." -ForegroundColor Cyan

$topology = $null
foreach ($node in $ClusterNode) {
    Write-Host "  Querying $node ..." -ForegroundColor Gray
    $topology = Get-WSFCTopology -ComputerName $node -NodeCredential $Credential
    if ($topology) {
        Write-Host "  Cluster '$($topology.ClusterName)' reported by $node." -ForegroundColor Green
        break
    }
    Write-Host "  $node did not return cluster information." -ForegroundColor Yellow
}

if (-not $topology) {
    Write-Error "None of the supplied hosts returned failover cluster information. Verify WMI access and that root\MSCluster exists (the host must be a cluster node)."
    return
}

Write-Host ""
Write-Host "  Cluster:  $($topology.ClusterName)" -ForegroundColor White
Write-Host "  Nodes:    $(@($topology.Nodes | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor White
Write-Host "  Roles:    $(@($topology.Roles).Count)" -ForegroundColor White
Write-Host ""
foreach ($role in $topology.Roles) {
    $ipText = if ($role.VirtualIPs.Count -gt 0) { $role.VirtualIPs -join ', ' } else { '<no VIP>' }
    Write-Host "    [$($role.Kind)] $($role.GroupName)" -ForegroundColor White
    Write-Host "        Virtual name : $($role.VirtualName)" -ForegroundColor Gray
    Write-Host "        Virtual IP   : $ipText" -ForegroundColor Gray
    if ($role.SqlInstances.Count -gt 0) {
        Write-Host "        SQL instance : $($role.SqlInstances -join ', ')" -ForegroundColor Gray
    }
    if ($role.AGNames.Count -gt 0) {
        Write-Host "        AG           : $($role.AGNames -join ', ')" -ForegroundColor Gray
    }
    Write-Host "        Current owner: $($role.OwnerNode)" -ForegroundColor Gray
}
Write-Host ""

#endregion

#region STEP 2 -- Select the roles that should own a standalone device

$rolesToSetup = [System.Collections.Generic.List[object]]::new()
foreach ($role in $topology.Roles) {
    $include = $false
    switch ($role.Kind) {
        'SqlFci'               { $include = $true }
        'SqlAvailabilityGroup' { $include = -not $SkipAvailabilityGroups }
        'ClusterCore'          { $include = [bool]$IncludeClusterCore }
        default                { $include = [bool]$IncludeOtherRoles }
    }
    if (-not $include) { continue }

    if (-not $role.VirtualName) {
        Write-Warning "Role '$($role.GroupName)' has no network name resource. Skipping."
        continue
    }

    # Add-WUGDeviceTemplate accepts IPv4 addresses only.
    $ipv4 = @($role.VirtualIPs | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' })
    if ($ipv4.Count -eq 0) {
        Write-Warning "Role '$($role.GroupName)' ($($role.VirtualName)) has no IPv4 virtual IP. Add its device manually."
        continue
    }

    $rolesToSetup.Add([PSCustomObject]@{
        Role      = $role
        PrimaryIP = $ipv4[0]
        AllIPv4   = $ipv4
    })
}

if ($rolesToSetup.Count -eq 0) {
    Write-Warning "No clustered roles selected for device setup. Use -IncludeClusterCore / -IncludeOtherRoles to widen the selection."
}

#endregion

#region STEP 3 -- Audit and create the virtual devices

Write-Host "STEP 2: Auditing WhatsUp Gold devices..." -ForegroundColor Cyan

# Node devices -- required, because node-local resources belong to them.
$nodeDevices = @{}   # node name -> device object
foreach ($n in $topology.Nodes) {
    $nodeDev = Find-WUGDeviceMatch -Name @($n.Name)
    if ($nodeDev) {
        $nodeDevices[$n.Name] = $nodeDev
        Write-Host "  Node '$($n.Name)' -> device #$($nodeDev.id) '$($nodeDev.displayName)'" -ForegroundColor Green
    }
    else {
        Write-Host "  Node '$($n.Name)' -> NO DEVICE IN WUG" -ForegroundColor Yellow
        Write-Warning "Node '$($n.Name)' has no WUG device. Node-local resources (CPU, memory, disk, cluster service) cannot be monitored until you add it."
    }
}
Write-Host ""

Write-Host "STEP 3: Reconciling virtual (shared) devices..." -ForegroundColor Cyan

$createdDevices  = [System.Collections.Generic.List[object]]::new()
$existingDevices = [System.Collections.Generic.List[object]]::new()
$virtualDevices  = @{}   # virtual name -> device id

foreach ($entry in $rolesToSetup) {
    $role      = $entry.Role
    $vName     = $role.VirtualName
    $vIP       = $entry.PrimaryIP
    $shortName = if ($vName -match '^([^.]+)\.') { $Matches[1] } else { $vName }

    $existing = Find-WUGDeviceMatch -Address $entry.AllIPv4 -Name @($vName, $shortName)

    if ($existing) {
        $virtualDevices[$vName] = [int]$existing.id
        $existingDevices.Add([PSCustomObject]@{ Name = $vName; IP = $vIP; DeviceId = [int]$existing.id })
        Write-Host "  [EXISTS]  $vName ($vIP) -> device #$($existing.id) '$($existing.displayName)'" -ForegroundColor Gray

        if ($existing.networkAddress -and $existing.networkAddress -ne $vIP) {
            Write-Warning "  Device #$($existing.id) matched '$vName' but its address is '$($existing.networkAddress)', not the virtual IP '$vIP'. Verify it is the standalone virtual device and not a node."
        }
        continue
    }

    if ($SkipDeviceCreation) {
        Write-Host "  [MISSING] $vName ($vIP) -- creation skipped (-SkipDeviceCreation)" -ForegroundColor Yellow
        continue
    }

    $attrs = @(
        @{ name = 'Cluster.Name';      value = "$($topology.ClusterName)" }
        @{ name = 'Cluster.Role';      value = "$($role.Kind)" }
        @{ name = 'Cluster.Group';     value = "$($role.GroupName)" }
        @{ name = 'Cluster.Nodes';     value = "$(@($topology.Nodes | ForEach-Object { $_.Name }) -join ',')" }
        @{ name = 'Cluster.VirtualIP'; value = "$($entry.AllIPv4 -join ',')" }
    )
    if ($role.SqlInstances.Count -gt 0) {
        $attrs += @{ name = 'Cluster.SqlInstance'; value = "$($role.SqlInstances -join ',')" }
    }
    if ($role.AGNames.Count -gt 0) {
        $attrs += @{ name = 'Cluster.AvailabilityGroup'; value = "$($role.AGNames -join ',')" }
    }

    $note = "Standalone device for clustered role '$($role.GroupName)' in WSFC '$($topology.ClusterName)'. " +
            "This device owns SHARED cluster resources and follows the role across failover. " +
            "Do not monitor node-local resources here; use the node devices for that. " +
            "Created by Setup-SQLClusterDevices.ps1 on $(Get-Date -Format 'yyyy-MM-dd')."

    $splat = @{
        displayName   = $vName
        DeviceAddress = $vIP
        Hostname      = $vName
        Brand         = $Brand
        OS            = 'Windows'
        Note          = $note
        Attributes    = $attrs
    }
    if ($DeviceGroupName)       { $splat['GroupName'] = $DeviceGroupName }
    if ($WindowsCredentialName) { $splat['CredentialWindows'] = $WindowsCredentialName }

    if (-not $PSCmdlet.ShouldProcess("$vName ($vIP)", 'Create standalone WUG device for clustered role')) {
        Write-Host "  [WHATIF]  Would create $vName ($vIP)" -ForegroundColor Yellow
        continue
    }

    Write-Host "  [CREATE]  $vName ($vIP)" -ForegroundColor White
    try {
        $null = Add-WUGDeviceTemplate @splat

        $newDev = Find-WUGDeviceMatch -Address @($vIP) -Name @($vName, $shortName)
        if ($newDev) {
            $virtualDevices[$vName] = [int]$newDev.id
            $createdDevices.Add([PSCustomObject]@{ Name = $vName; IP = $vIP; DeviceId = [int]$newDev.id })
            Write-Host "            Created device #$($newDev.id)" -ForegroundColor Green
        }
        else {
            Write-Warning "  Created '$vName' but could not resolve its device ID afterwards."
        }
    }
    catch {
        Write-Error "  Failed to create device for '$vName' ($vIP): $_"
    }
}
Write-Host ""

#endregion

#region STEP 4 -- Cleanup: virtual IPs attached as interfaces on node devices

Write-Host "STEP 4: Checking for virtual IPs attached to node devices..." -ForegroundColor Cyan

$vipSet = @{}
foreach ($entry in $rolesToSetup) {
    foreach ($ip in $entry.AllIPv4) { $vipSet[$ip] = $entry.Role.VirtualName }
}

$strayInterfaceCount   = 0
$removedInterfaceCount = 0

foreach ($nodeName in ($nodeDevices.Keys | Sort-Object)) {
    $nodeDev = $nodeDevices[$nodeName]
    $nodeId  = [int]$nodeDev.id

    $interfaces = @()
    try { $interfaces = @(Get-WUGDeviceInterface -DeviceId $nodeId) }
    catch {
        Write-Verbose "Could not list interfaces for node device ${nodeId}: $($_.Exception.Message)"
        continue
    }

    foreach ($iface in $interfaces) {
        $ifAddr = if ($iface.address) { [string]$iface.address } else { [string]$iface.networkAddress }
        $ifId   = if ($iface.interfaceId) { [string]$iface.interfaceId } else { [string]$iface.id }
        if (-not $ifAddr -or -not $vipSet.ContainsKey($ifAddr)) { continue }

        $strayInterfaceCount++
        Write-Host "  [STRAY]   Node '$nodeName' (#$nodeId) carries virtual IP $ifAddr (role '$($vipSet[$ifAddr])') as an interface." -ForegroundColor Yellow
        Write-Host "            While the node owns the role this looks healthy even when the role has failed." -ForegroundColor DarkGray

        if (-not $RemoveVipInterfaceFromNodes) { continue }
        if (-not $ifId) {
            Write-Warning "            Could not determine the interface ID; remove it manually."
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("interface $ifAddr on node device #$nodeId ($nodeName)", 'Remove virtual IP interface')) { continue }

        try {
            Remove-WUGDeviceInterface -DeviceId $nodeId -InterfaceId $ifId -Confirm:$false | Out-Null
            $removedInterfaceCount++
            Write-Host "            Removed." -ForegroundColor Green
        }
        catch {
            Write-Warning "            Failed to remove interface $ifAddr from node device #${nodeId}: $_"
        }
    }
}

if ($strayInterfaceCount -eq 0) {
    Write-Host "  None found." -ForegroundColor Green
}
elseif (-not $RemoveVipInterfaceFromNodes) {
    Write-Host "  Re-run with -RemoveVipInterfaceFromNodes to detach them." -ForegroundColor Cyan
}
Write-Host ""

#endregion

#region STEP 5 -- Cleanup: shared-resource monitors sitting on the physical nodes

Write-Host "STEP 5: Checking node devices for shared-resource monitors ($NodeCleanupAction mode)..." -ForegroundColor Cyan

# Build the match patterns from what we actually discovered, plus anything the caller added.
$patterns = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $rolesToSetup) {
    $role = $entry.Role
    foreach ($nn in $role.NetworkNames) {
        if ($nn) { $patterns.Add("*$nn*") }
    }
    foreach ($inst in $role.SqlInstances) {
        if ($inst -and $inst -ne 'MSSQLSERVER') { $patterns.Add("*$inst*") }
    }
    foreach ($ag in $role.AGNames) {
        if ($ag) { $patterns.Add("*$ag*") }
    }
    foreach ($ip in $entry.AllIPv4) { $patterns.Add("*$ip*") }
}
foreach ($p in @($SharedMonitorPattern)) {
    if ($p) { $patterns.Add($p) }
}

$uniquePatterns = @($patterns | Sort-Object -Unique)
if ($uniquePatterns.Count -gt 0) {
    Write-Host "  Matching monitor names against: $($uniquePatterns -join ', ')" -ForegroundColor Gray
}

$flaggedCount  = 0
$changedCount  = 0
$failedCount   = 0
$cleanupReport = [System.Collections.Generic.List[object]]::new()

if ($uniquePatterns.Count -eq 0) {
    Write-Host "  No patterns to match. Supply -SharedMonitorPattern to search node devices." -ForegroundColor Yellow
}
else {
    foreach ($nodeName in ($nodeDevices.Keys | Sort-Object)) {
        $nodeDev = $nodeDevices[$nodeName]
        $nodeId  = [int]$nodeDev.id

        foreach ($mon in (Get-DeviceMonitorAssignment -DeviceId $nodeId)) {
            $monName = [string]$mon.Name
            if (-not $monName) { continue }

            $matched = $false
            foreach ($pat in $uniquePatterns) {
                if ($monName -like $pat) { $matched = $true; break }
            }
            if (-not $matched) { continue }

            $flaggedCount++
            $cleanupReport.Add([PSCustomObject]@{
                Node         = $nodeName
                DeviceId     = $nodeId
                Kind         = $mon.Kind
                Monitor      = $monName
                AssignmentId = $mon.AssignmentId
                Enabled      = $mon.Enabled
            })

            $stateText = if ($mon.Enabled -eq $false) { 'already disabled' } else { 'enabled' }
            Write-Host "  [SHARED]  $nodeName (#$nodeId) $($mon.Kind): '$monName' ($stateText)" -ForegroundColor Yellow

            if ($NodeCleanupAction -eq 'Report') { continue }

            if ($NodeCleanupAction -eq 'Disable') {
                if ($mon.Enabled -eq $false) { continue }
                if (-not $PSCmdlet.ShouldProcess("'$monName' on node device #$nodeId ($nodeName)", 'Disable shared-resource monitor')) { continue }
                try {
                    $null = Set-DeviceMonitorEnabled -DeviceId $nodeId -AssignmentId $mon.AssignmentId -Enabled $false -Confirm:$false
                    $changedCount++
                    Write-Host "            Disabled." -ForegroundColor Green
                }
                catch {
                    $failedCount++
                    Write-Warning "            Failed to disable '$monName' on node device #${nodeId}: $_"
                }
            }
            else {
                if (-not $PSCmdlet.ShouldProcess("'$monName' on node device #$nodeId ($nodeName)", 'Remove shared-resource monitor assignment')) { continue }
                try {
                    Remove-WUGDeviceMonitor -DeviceId $nodeId -AssignmentId $mon.AssignmentId -Confirm:$false | Out-Null
                    $changedCount++
                    Write-Host "            Removed." -ForegroundColor Green
                }
                catch {
                    $failedCount++
                    Write-Warning "            Failed to remove '$monName' from node device #${nodeId}: $_"
                }
            }
        }
    }

    if ($flaggedCount -eq 0) {
        Write-Host "  No shared-resource monitors found on the node devices." -ForegroundColor Green
    }
}
Write-Host ""

#endregion

#region STEP 6 -- Summary

Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Cluster:                       $($topology.ClusterName)" -ForegroundColor White
Write-Host "  Nodes with a WUG device:       $($nodeDevices.Count) of $(@($topology.Nodes).Count)" -ForegroundColor White
Write-Host "  Virtual devices already set:   $($existingDevices.Count)" -ForegroundColor White
Write-Host "  Virtual devices created:       $($createdDevices.Count)" -ForegroundColor $(if ($createdDevices.Count -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  Stray VIP interfaces on nodes: $strayInterfaceCount (removed: $removedInterfaceCount)" -ForegroundColor $(if ($strayInterfaceCount -gt 0) { 'Yellow' } else { 'Gray' })
Write-Host "  Shared monitors on nodes:      $flaggedCount (changed: $changedCount, failed: $failedCount)" -ForegroundColor $(if ($flaggedCount -gt 0) { 'Yellow' } else { 'Gray' })
Write-Host ""

if ($cleanupReport.Count -gt 0 -and $NodeCleanupAction -eq 'Report') {
    Write-Host "  Outstanding cleanup:" -ForegroundColor Yellow
    $cleanupReport | Format-Table Node, DeviceId, Kind, Monitor, AssignmentId, Enabled -AutoSize
    Write-Host "  Re-run with -NodeCleanupAction Disable to disable these on the nodes." -ForegroundColor Cyan
    Write-Host ""
}

if ($virtualDevices.Count -gt 0) {
    Write-Host "  Next step -- attach SQL monitoring to the virtual device(s):" -ForegroundColor Cyan
    foreach ($vn in ($virtualDevices.Keys | Sort-Object)) {
        Write-Host "    ..\helpers\discovery\Setup-MSSQL-Discovery.ps1 -DeviceId $($virtualDevices[$vn]) -Action PushToWUG   # $vn" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Keep node-local monitoring (CPU, memory, disk, Cluster Service) on the node devices." -ForegroundColor Gray
    Write-Host ""
}

#endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBn+pasxayE1F2e
# ueAqrDrJU/kUCxeEhmYt7TDLalY1m6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBo+yvbwleU83w1WFIsn82M1mMmexc6HlS4wxdQTKNojDANBgkqhkiG9w0BAQEF
# AASCAgCqfCbmwktgXFCGZAL2vXxXEm+BdYXWdRNcEoQr7WTV5AeSCLvSfMq7B04E
# rk/A808RUKDcnIV0EMAEjoN01LBvylefmYiEqS5cLkkhquMF5QgvvuGCysOBq2N8
# AypngXH0Hta6egTKc+wuQj4oF8p77yQB8pGV7GuRMFwRrmCBbSClrznaIV6cxQt0
# EjKUChx31P0Jdxfbg7rdTpRWFkieRFPcqEnNQLcQdd7OmIJVm/icTu5xdc/29L3f
# UXIQgFTOhj+r8JhsBU4d85UXxJBnKhWkE+JekPUrhahVETpGYoVjoODOIzZAggz6
# d8SbRI872s7SiUcv4/OUuwDLXrS2nx6d4eU+TqQq2shYkxwHy9VB9cKSSU3r5Pzl
# Lh25CYSz/kRC91E0mC7HnWa6KKedeDSM1UfIuq2SdQqR4mcNND2sbf6lj7MIHzL5
# mHvHguVmOOiVlHY3FkBibBcIxvxK+P+4fM9Dt6rJt+4LH8Ek5of+bKReMVhRXECf
# mCyhXM91RjApNcZzrcMLnXV3RLyALfNIi2sUWFUaCbGZdfpNfKfM0Bgh7xtoLv1N
# ReMFuZLCsVuMs19a5FCuEZvmcBCW9cdjN5tgI1GE+pNAOKRuKQPhfitoaBI4lNo7
# ljlvyGyinfNMr2272dYHG/oKzP981CHKCHvJnni329rSNw7ZmqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA4MjgxNjUzNDdaMC8GCSqGSIb3DQEJBDEiBCDUuVKA
# VN0dYCoCc6Wb5yr61HZCZNFsX1eQFLw9rB+i8jANBgkqhkiG9w0BAQEFAASCAgDP
# shuOP3iAWs/L/58AMnKRyvvpfw/9RFjJTW8P19Y4R84aCmCFTAC6Ev/aaf4cyfZe
# jXswIs/Gq1QpVd2ctvfjxZ/FfVvckFce06/hPnQNtQrY4HCZx5kZHiYh99GMj8yW
# 17aFzppruc/VgvM+CIajoxT5xDBoPbkZ5xC0aHm3IdSpYWfyJqkmcTuBJTysJRes
# FBlSh8ZiIQgj8+fksjcPH9kVpxkUz0R+eieL2LF+E6JnLDZBqcVXrpaQf9lUVjfu
# DwoPJWgRQ26l2RJZJ/plXwN2Qnl92MVhP1MGqcHjE3bb+sssoqJOb3qb/YQWBeZr
# zfYQMSrEM8vnTA20w2aNPqGxP6iw5BR7dElQhPif5xou6VtIUueehsbCF10wZjzG
# BNuNL3fOeyT/XAw9cbBHIqR6Q6Z9q5e/S2NcCycONEZ69t9ZlATey2DnjrnGEF+k
# MaomJcqMDhU7DeRRAtrItFCmUSBa1qSv0OnGkuldstm3kNgoqd+SUSLD4BqtvcFL
# So4Edvz6JI0h0VDDXoPNiv4OJ1dXEv9ca5YDJnKQx4C+nQZSL80yg/md16jVZEW/
# VxTQ3iY88nNX8Z/RzwAzOalI4f1fNpjef8IJnlE5FVokDSLwSCmIummbd7wsts9n
# N+yLOAncqk5rQoaYL9G7XMl/T1ZdbBGAMixKfgF40A==
# SIG # End signature block
