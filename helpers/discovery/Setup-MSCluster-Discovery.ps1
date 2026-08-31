#requires -Version 5.1
<#
.SYNOPSIS
    Discovers a Microsoft Windows Server Failover Cluster (WSFC/MSCS) and pushes a
    cluster-aware monitor plan to WhatsUp Gold.

.DESCRIPTION
    Point this at any single node of a failover cluster. It probes root\MSCluster over
    WMI and returns the whole cluster: nodes with their OS build and drain status,
    clustered roles with virtual network names, virtual IPs, failover policy, preferred
    owners and anti-affinity, cluster resources with their restart and health-check
    policy, cluster networks with roles and metrics, cluster shared volumes including
    redirected and maintenance state, cluster disk capacity, installed resource types,
    unassigned available disks, heartbeat tuning, and quorum and witness configuration
    with per-node vote weights. SQL Failover Cluster Instances and Always On AG
    listeners are identified along the way.

    Anything unhealthy is called out as it is found: nodes not Up or being drained,
    mismatched node builds, roles not Online, resources not Online, CSVs in redirected
    or maintenance mode, a single or absent cluster-communication network, cluster disks
    below 10% free, and an even vote count with no witness configured.

    It then builds a monitor plan that respects how a cluster actually behaves:

      NODE devices (addressed by the node IP) get the node-local resources:
        - Cluster Service (ClusSvc) active monitor
        - Every cluster performance counter validated to return data on that node
          (cluster database, cluster API, network reconnections, resource control
          manager, CSV file system, Storage Spaces Direct, and so on)

      ROLE devices (addressed by the role's virtual IP) get the shared resource:
        - Role availability. A clustered role floats between nodes, so its virtual IP
          is the only honest place to answer "is this role up".

    That split is the point of the script. Putting shared-resource monitors on the
    physical nodes is what produces false alarms on whichever node does not currently
    own the role.

    Counter discovery is validated, not assumed: each candidate class is queried and
    only properties that return a numeric value are turned into monitors. Classes
    differ per node depending on installed roles (S2D, CSV, SQL), so every node is
    probed independently.

    Prerequisites:
      1. WMI/DCOM access to at least one cluster node
      2. Credentials with local administrator rights on the nodes
      3. WhatsUpGoldPS module (only for -Action PushToWUG / DashboardAndPush)

.PARAMETER Target
    One or more cluster node names or IP addresses. Any single reachable node returns
    the entire cluster topology; extra targets only add resilience.

.PARAMETER Credential
    PSCredential for WMI access. When omitted, resolved from the DPAPI discovery vault.

.PARAMETER CounterClass
    Wildcard filter applied to the discovered cluster performance counter classes.
    Example: '*ClusterCSV*','*ClusterDatabase*'. Default: all discovered classes.

.PARAMETER MaxPerfMonitorsPerNode
    Cap on performance monitors assigned to each node device. A cluster running S2D can
    expose hundreds of counters; this keeps the push sane. Default: 60. Use 0 for no cap.

.PARAMETER SkipRoleDevices
    Do not create or monitor the clustered role virtual IP devices. Node monitoring only.

.PARAMETER SkipNodePerfMonitors
    Discover and report cluster counters but do not push them. Leaves the Cluster
    Service monitor on the nodes and role availability on the virtual IPs.

.PARAMETER DeviceGroupName
    WUG device group that newly created cluster devices are placed into.

.PARAMETER PollingIntervalMinutes
    Polling interval for performance monitor assignments. Default: 5.

.PARAMETER PollingIntervalSeconds
    Polling interval for active monitor assignments. Default: 300.

.PARAMETER Action
    Skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Only needed for PushToWUG.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold. When omitted, Connect-WUGServer -AutoConnect is used.

.PARAMETER OutputPath
    Directory for exports and dashboards.
    Default: %LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Output.

.PARAMETER NonInteractive
    Suppress prompts. Uses cached vault credentials.

.EXAMPLE
    .\Setup-MSCluster-Discovery.ps1 -Target 'SQLNODE1' -Action ShowTable

    Discover the cluster that SQLNODE1 belongs to and print the full plan.

.EXAMPLE
    .\Setup-MSCluster-Discovery.ps1 -Target 'SQLNODE1' -Action Dashboard

    Generate the cluster inventory dashboard without touching WhatsUp Gold.

.EXAMPLE
    .\Setup-MSCluster-Discovery.ps1 -Target 'SQLNODE1' -Action PushToWUG -DeviceGroupName 'Clusters'

    Create node devices and role virtual IP devices in the 'Clusters' group, then attach
    node-local counters to the nodes and role availability to the virtual IPs.

.EXAMPLE
    .\Setup-MSCluster-Discovery.ps1 -Target 'HVNODE1' -CounterClass '*ClusterCSV*','*ClusterDatabase*' -Action PushToWUG

    Push only the CSV and cluster database counters.

.EXAMPLE
    .\Setup-MSCluster-Discovery.ps1 -Target 'SQLNODE1' -SkipNodePerfMonitors -Action PushToWUG

    Availability only: Cluster Service on the nodes, role health on the virtual IPs.

.EXAMPLE
    .\Setup-MSCluster-Discovery.ps1 -Target 'SQLNODE1' -Action DashboardAndPush -NonInteractive

    Unattended run suitable for a scheduled task.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: WhatsUpGoldPS module (for PushToWUG), PowerShell 5.1+
    Encoding: UTF-8 with BOM
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [PSCredential]$Credential,

    [string[]]$CounterClass,

    [ValidateRange(0, 5000)]
    [int]$MaxPerfMonitorsPerNode = 60,

    [switch]$SkipRoleDevices,

    [switch]$SkipNodePerfMonitors,

    [string]$DeviceGroupName,

    [ValidateRange(1, 1440)]
    [int]$PollingIntervalMinutes = 5,

    [ValidateRange(60, 86400)]
    [int]$PollingIntervalSeconds = 300,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer,

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

# ==============================================================================
# Load the discovery framework and this provider
# ==============================================================================
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent

$discoveryHelpersPath = Join-Path $scriptDir 'DiscoveryHelpers.ps1'
if (-not (Test-Path $discoveryHelpersPath)) {
    Write-Error "DiscoveryHelpers.ps1 not found at '$discoveryHelpersPath'. Cannot continue."
    return
}
. $discoveryHelpersPath

$providerPath = Join-Path $scriptDir 'DiscoveryProvider-MSCluster.ps1'
if (-not (Test-Path $providerPath)) {
    Write-Error "DiscoveryProvider-MSCluster.ps1 not found at '$providerPath'. Cannot continue."
    return
}
. $providerPath

$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

Write-Host ""
Write-Host "=== Microsoft Failover Cluster Discovery ===" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 1: Targets
# ==============================================================================
if ($Target) {
    $clusterTargets = @($Target)
}
elseif ($NonInteractive) {
    Write-Error 'No -Target supplied and running non-interactively. Exiting.'
    return
}
else {
    Write-Host "Enter any cluster node - IP address, hostname, or FQDN." -ForegroundColor Cyan
    Write-Host "One node is enough; the whole cluster is discovered from it." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt "Cluster node(s)"
    $clusterTargets = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($clusterTargets.Count -eq 0) {
    Write-Error 'No valid cluster node provided. Exiting.'
    return
}
Write-Host "Targets: $($clusterTargets -join ', ')" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 2: Credentials (DPAPI vault)
# ==============================================================================
if ($Credential) {
    $wmiCred = $Credential
}
else {
    $vaultName = 'Windows.WMI.Credential.1'
    $credSplat = @{ Name = $vaultName; CredType = 'PSCredential'; ProviderLabel = 'Failover Cluster (WMI)' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    elseif ($Action)     { $credSplat.AutoUse = $true }
    $wmiCred = Resolve-DiscoveryCredential @credSplat
}

if (-not $wmiCred) {
    Write-Error 'No credentials available. Provide -Credential or configure the vault. Exiting.'
    return
}

# ==============================================================================
# STEP 3: Discover
# ==============================================================================
Write-Host "Discovering cluster from: $($clusterTargets -join ', ')..." -ForegroundColor Cyan

$credHash = @{
    Username     = $wmiCred.UserName
    Password     = $wmiCred.GetNetworkCredential().Password
    PSCredential = $wmiCred
}

# One node returns the whole cluster, so a target is only scanned when it belongs
# to a cluster not already discovered. Extra targets therefore act as fallbacks
# for an unreachable node, while nodes of a genuinely different cluster still get
# discovered in the same run.
$plan = @()
$seenClusters = @{}
$pending = [System.Collections.Generic.List[string]]::new()
foreach ($t in $clusterTargets) { $pending.Add($t) }

while ($pending.Count -gt 0) {
    $currentTarget = $pending[0]
    $pending.RemoveAt(0)

    $result = @(Invoke-Discovery -ProviderName 'MSCluster' -Target @($currentTarget) -Credential $credHash)
    if ($result.Count -eq 0) { continue }

    $foundCluster = $result[0].Attributes['MSCluster.ClusterName']
    if ($foundCluster -and $seenClusters.ContainsKey($foundCluster)) {
        Write-Host "  $currentTarget belongs to '$foundCluster', already discovered. Skipping." -ForegroundColor DarkGray
        continue
    }
    if ($foundCluster) { $seenClusters[$foundCluster] = $true }
    $plan += $result

    # Remaining targets that are members of this cluster no longer need scanning
    $members = @{}
    foreach ($it in $result) {
        $mn = $it.Attributes['MSCluster.NodeName']
        $mi = $it.Attributes['MSCluster.NodeIP']
        if ($mn) { $members[$mn] = $true }
        if ($mi) { $members[$mi] = $true }
    }
    foreach ($nn in @($result[0].Attributes['MSCluster.Nodes'] -split ',')) {
        if ($nn) { $members[$nn.Trim()] = $true }
    }

    for ($p = $pending.Count - 1; $p -ge 0; $p--) {
        $cand = $pending[$p]
        $short = if ($cand -match '^([^.]+)\.') { $Matches[1] } else { $cand }
        if ($members.ContainsKey($cand) -or $members.ContainsKey($short)) {
            Write-Host "  $cand is a node of '$foundCluster'. Already covered." -ForegroundColor DarkGray
            $pending.RemoveAt($p)
        }
    }
}

if ($plan.Count -eq 0) {
    Write-Warning "Nothing discovered. Check connectivity, credentials, and that the target is a cluster node."
    return
}

if ($seenClusters.Count -gt 1) {
    Write-Host "  Discovered $($seenClusters.Count) clusters: $(@($seenClusters.Keys) -join ', ')" -ForegroundColor Cyan
}

# Safety net in case two seeds resolved to the same cluster under different names
$uniquePlan = [ordered]@{}
foreach ($it in $plan) {
    if (-not $uniquePlan.Contains($it.UniqueKey)) { $uniquePlan[$it.UniqueKey] = $it }
}
$plan = @($uniquePlan.Values)

# ==============================================================================
# STEP 4: Apply counter filters, then group the plan into devices
# ==============================================================================
if ($SkipNodePerfMonitors) {
    $plan = @($plan | Where-Object { $_.ItemType -ne 'PerformanceMonitor' })
}
elseif ($CounterClass) {
    $plan = @($plan | Where-Object {
        if ($_.ItemType -ne 'PerformanceMonitor') { return $true }
        $cls = $_.MonitorParams['WmiFormattedRelativePath']
        foreach ($pat in $CounterClass) {
            if ($cls -like $pat) { return $true }
        }
        return $false
    })
}

if ($SkipRoleDevices) {
    $plan = @($plan | Where-Object { $_.Attributes['MSCluster.DeviceType'] -ne 'Role' })
}

$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $devType = $item.Attributes['MSCluster.DeviceType']
    $itemCluster = $item.Attributes['MSCluster.ClusterName']

    switch ($devType) {
        'Node' {
            $name = $item.Attributes['MSCluster.NodeName']
            $key  = "$itemCluster|node:$name"
            $ip   = $item.Attributes['MSCluster.NodeIP']
            $kind = 'Node'
        }
        'Role' {
            $name = $item.Attributes['MSCluster.VirtualName']
            # Group names such as 'Cluster Group' repeat in every cluster, so the
            # key has to be cluster-qualified.
            $key  = "$itemCluster|role:$($item.Attributes['MSCluster.ResourceGroup'])"
            $ip   = $item.Attributes['MSCluster.PrimaryIP']
            $kind = $item.Attributes['MSCluster.RoleKind']
        }
        default { continue }
    }

    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name    = $name
            IP      = $ip
            Type    = $devType
            Kind    = $kind
            Cluster = $itemCluster
            Attrs   = $item.Attributes
            Items   = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$clusterName = @($seenClusters.Keys) -join ', '

# Cap per-node performance monitors so a big S2D cluster does not flood WUG
$cappedCount = 0
if ($MaxPerfMonitorsPerNode -gt 0) {
    foreach ($key in @($devicePlan.Keys)) {
        $dev = $devicePlan[$key]
        if ($dev.Type -ne 'Node') { continue }

        $perfItems = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })
        if ($perfItems.Count -le $MaxPerfMonitorsPerNode) { continue }

        $keepPerf   = @($perfItems | Select-Object -First $MaxPerfMonitorsPerNode)
        $activeItems = @($dev.Items | Where-Object { $_.ItemType -ne 'PerformanceMonitor' })
        $cappedCount += ($perfItems.Count - $keepPerf.Count)

        $newItems = [System.Collections.ArrayList]@()
        foreach ($i in $activeItems) { [void]$newItems.Add($i) }
        foreach ($i in $keepPerf)    { [void]$newItems.Add($i) }
        $dev.Items = $newItems
    }

    if ($cappedCount -gt 0) {
        # Rebuild the plan so exports and the push agree with the capped device plan
        $rebuilt = [System.Collections.ArrayList]@()
        foreach ($key in $devicePlan.Keys) {
            foreach ($i in $devicePlan[$key].Items) { [void]$rebuilt.Add($i) }
        }
        $plan = @($rebuilt)
    }
}

$nodeDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'Node' })
$roleDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'Role' })
$nodesNoIP   = @($nodeDevices | Where-Object { -not $_.IP })

# ==============================================================================
# STEP 5: Show what was found
# ==============================================================================
Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Cluster:                 $clusterName" -ForegroundColor White
Write-Host "  Nodes:                   $($nodeDevices.Count)" -ForegroundColor White
Write-Host "  Roles with a virtual IP: $($roleDevices.Count)" -ForegroundColor White
Write-Host "  Total plan items:        $($plan.Count)" -ForegroundColor White
Write-Host "    Active monitors:       $(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count)" -ForegroundColor White
Write-Host "    Performance monitors:  $(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count)" -ForegroundColor White
if ($cappedCount -gt 0) {
    Write-Host "  Counters trimmed by -MaxPerfMonitorsPerNode: $cappedCount" -ForegroundColor Yellow
}
Write-Host ""

if ($nodesNoIP.Count -gt 0) {
    Write-Host "Nodes without a resolvable IPv4 address (cannot be created in WUG):" -ForegroundColor Yellow
    foreach ($n in $nodesNoIP) { Write-Host "    $($n.Name)" -ForegroundColor DarkYellow }
    Write-Host ""
}

$sampleNodeAttrs = $null
if ($nodeDevices.Count -gt 0) { $sampleNodeAttrs = $nodeDevices[0].Attrs }
if ($sampleNodeAttrs) {
    foreach ($cn in @($seenClusters.Keys)) {
        $cNode = @($nodeDevices | Where-Object { $_.Cluster -eq $cn }) | Select-Object -First 1
        if (-not $cNode) { continue }
        $ca = $cNode.Attrs
        Write-Host "Quorum - $cn" -ForegroundColor Cyan
        Write-Host "    Type:          $($ca['MSCluster.QuorumType'])" -ForegroundColor Gray
        Write-Host "    Witness:       $(if ($ca['MSCluster.WitnessType']) { "$($ca['MSCluster.WitnessType']) ($($ca['MSCluster.WitnessState']))" } else { 'none configured' })" -ForegroundColor Gray
        Write-Host "    Total votes:   $($ca['MSCluster.QuorumVotes'])" -ForegroundColor Gray
        if ($ca['MSCluster.ClusterDisks']) {
            Write-Host "    Cluster disks: $($ca['MSCluster.ClusterDisks'])" -ForegroundColor Gray
        }
        Write-Host ""
    }
}

$badRoles = @($roleDevices | Where-Object { $_.Attrs['MSCluster.UnhealthyResources'] -or ($_.Attrs['MSCluster.RoleState'] -and $_.Attrs['MSCluster.RoleState'] -ne 'Online') })
$badNodes = @($nodeDevices | Where-Object { $_.Attrs['MSCluster.NodeState'] -ne 'Up' })
if ($badNodes.Count -gt 0 -or $badRoles.Count -gt 0) {
    Write-Host "Needs attention:" -ForegroundColor Yellow
    foreach ($n in $badNodes) {
        Write-Host "    Node $($n.Name): $($n.Attrs['MSCluster.NodeState'])" -ForegroundColor DarkYellow
    }
    foreach ($r in $badRoles) {
        $detail = $r.Attrs['MSCluster.UnhealthyResources']
        if (-not $detail) { $detail = $r.Attrs['MSCluster.RoleState'] }
        Write-Host "    Role $($r.Name): $detail" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# Every clustered role, including those with no virtual IP. A role only becomes its
# own WUG device when it owns one; the rest live on whichever node currently owns them.
$roleRows = @()
foreach ($cn in @($seenClusters.Keys)) {
    $srcNode = @($nodeDevices | Where-Object { $_.Cluster -eq $cn }) | Select-Object -First 1
    if (-not $srcNode) { continue }
    $raw = $srcNode.Attrs['MSCluster.AllRoles']
    if (-not $raw) { continue }
    foreach ($entry in @($raw -split ';')) {
        if (-not $entry) { continue }
        $f = $entry -split '\|'
        if ($f.Count -lt 5) { continue }
        $roleRows += [PSCustomObject]@{
            Cluster   = $cn
            Role      = $f[0]
            Kind      = $f[1]
            State     = $f[2]
            OwnerNode = $f[3]
            VirtualIP = $f[4]
            Monitored = if ($f[4] -eq 'no-VIP') { 'on owner node' } else { 'own device' }
        }
    }
}

if ($roleRows.Count -gt 0) {
    Write-Host "Clustered roles:" -ForegroundColor Cyan
    $roleRows | Format-Table Cluster, Role, Kind, State, OwnerNode, VirtualIP, Monitored -AutoSize
    $noVip = @($roleRows | Where-Object { $_.VirtualIP -eq 'no-VIP' })
    if ($noVip.Count -gt 0) {
        Write-Host "  $($noVip.Count) role(s) have no virtual IP (VM and storage roles typically do not) so they get no device of their own." -ForegroundColor Gray
        Write-Host ""
    }
}

Write-Host "Cluster device layout:" -ForegroundColor Cyan
$devicePlan.Values | Sort-Object @{E = { $_.Type }}, @{E = { $_.Name }} |
    ForEach-Object {
        [PSCustomObject]@{
            Cluster  = $_.Cluster
            Device   = $_.Name
            Type     = $_.Type
            Kind     = $_.Kind
            IP       = if ($_.IP) { $_.IP } else { '(none)' }
            Scope    = if ($_.Type -eq 'Role') { 'Shared' } else { 'Node-local' }
            Monitors = $_.Items.Count
        }
    } | Format-Table -AutoSize

# Flattened rows for dashboards and exports
$inventory = @()
foreach ($key in $devicePlan.Keys) {
    $dev = $devicePlan[$key]
    $a   = $dev.Attrs
    $inventory += [PSCustomObject]@{
        Cluster       = $dev.Cluster
        Device        = $dev.Name
        Type          = $dev.Type
        Kind          = $dev.Kind
        IP            = $dev.IP
        Scope         = if ($dev.Type -eq 'Role') { 'Shared' } else { 'Node-local' }
        State         = if ($dev.Type -eq 'Node') { $a['MSCluster.NodeState'] } else { $a['MSCluster.RoleState'] }
        OwnerNode     = $a['MSCluster.OwnerNode']
        ResourceGroup = $a['MSCluster.ResourceGroup']
        SqlInstance   = $a['MSCluster.SqlInstance']
        AvailGroup    = $a['MSCluster.AvailabilityGroup']
        Resources     = $a['MSCluster.Resources']
        ResourceTypes = $a['MSCluster.ResourceTypesInUse']
        ResourcePolicy = $a['MSCluster.ResourcePolicy']
        Unhealthy     = $a['MSCluster.UnhealthyResources']
        FailoverPolicy = $a['MSCluster.FailoverPolicy']
        PreferredOwner = $a['MSCluster.PreferredOwners']
        AntiAffinity  = $a['MSCluster.AntiAffinity']
        NodeBuild     = $a['MSCluster.NodeBuild']
        DrainStatus   = $a['MSCluster.NodeDrainStatus']
        NodeVote      = $a['MSCluster.NodeVote']
        QuorumVotes   = $a['MSCluster.QuorumVotes']
        QuorumType    = $a['MSCluster.QuorumType']
        DynamicQuorum = $a['MSCluster.DynamicQuorum']
        Witness       = $a['MSCluster.WitnessType']
        WitnessState  = $a['MSCluster.WitnessState']
        S2DEnabled    = $a['MSCluster.S2DEnabled']
        SharedVolumes = $a['MSCluster.SharedVolumes']
        ClusterDisks  = $a['MSCluster.ClusterDisks']
        AvailableDisks = $a['MSCluster.AvailableDisks']
        Networks      = $a['MSCluster.Networks']
        Heartbeat     = $a['MSCluster.HeartbeatTuning']
        ActiveCount   = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
        PerfCount     = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count
    }
}

# ==============================================================================
# STEP 6: Action
# ==============================================================================
if ($OutputPath) { $OutputDir = $OutputPath }
else { $OutputDir = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output' }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG'        { $choice = '1' }
        'ExportJSON'       { $choice = '2' }
        'ExportCSV'        { $choice = '3' }
        'ShowTable'        { $choice = '4' }
        'Dashboard'        { $choice = '5' }
        'None'             { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice -and $NonInteractive) { $choice = '5' }

if (-not $choice) {
    Write-Host ""
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push to WhatsUp Gold (creates node + role devices, attaches monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export inventory to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate cluster HTML dashboard"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host "  [7] Dashboard + Push to WUG"
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-7]"
}

if ($choice -eq '7') { $actionsToRun = @('5', '1') }
else { $actionsToRun = @($choice) }

foreach ($currentChoice in $actionsToRun) {
switch ($currentChoice) {
    '1' {
        # ---------------------------------------------------------------- Push
        Write-Host ""
        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
            if (Test-Path $repoPsd1) { Import-Module $repoPsd1 -Force -ErrorAction Stop }
            else { Import-Module WhatsUpGoldPS -ErrorAction Stop }
        }
        catch {
            Write-Error "Could not load WhatsUpGoldPS module. Is it installed? $_"
            return
        }

        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) {
            try {
                if ($WUGCredential -and $WUGServer) {
                    Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
                }
                elseif ($WUGServer) {
                    Connect-WUGServer -serverUri $WUGServer -IgnoreSSLErrors
                }
                else {
                    Connect-WUGServer -AutoConnect -IgnoreSSLErrors
                }
            }
            catch {
                Write-Error "Failed to connect to WhatsUp Gold: $_"
                return
            }
        }

        Write-Host ""
        Write-Host "Reconciling cluster devices in WUG..." -ForegroundColor Cyan

        $wugDeviceMap   = @{}
        $devicesCreated = 0
        $devicesFound   = 0
        $devicesSkipped = 0

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if (-not $dev.IP -or $dev.IP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                Write-Warning "  '$($dev.Name)' has no IPv4 address. Skipping device creation."
                $devicesSkipped++
                continue
            }

            # Pre-check before creating; the API rejects duplicates rather than merging.
            $existingDevice = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.IP)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.networkAddress -eq $dev.IP -or $_.hostName -eq $dev.Name -or $_.displayName -eq $dev.Name
                    } | Select-Object -First 1
                }
                if (-not $existingDevice) {
                    $byName = @(Get-WUGDevice -SearchValue $dev.Name)
                    $existingDevice = $byName | Where-Object {
                        $_.displayName -eq $dev.Name -or $_.hostName -eq $dev.Name -or $_.networkAddress -eq $dev.IP
                    } | Select-Object -First 1
                }
            }
            catch {
                Write-Verbose "Device search for '$($dev.Name)' failed: $_"
            }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $devicesFound++
                Write-Host "  [EXISTS] $($existingDevice.displayName) (ID: $($existingDevice.id)) [$($dev.Type)]" -ForegroundColor Gray

                # A role can keep the same name while its VIP moves to a new
                # subnet. Reconcile the default WUG interface so reruns follow
                # the current VIP instead of leaving the device on an old IP.
                $currentAddress = [string]$existingDevice.networkAddress
                $defaultInterface = $null
                try {
                    $defaultInterface = @(Get-WUGDeviceInterface -DeviceId $existingDevice.id -Default) | Select-Object -First 1
                }
                catch {
                    Write-Verbose "Could not retrieve the default interface for '$($dev.Name)': $_"
                }
                if (-not $defaultInterface -and $existingDevice.PSObject.Properties['interfaces']) {
                    $defaultInterface = @($existingDevice.interfaces | Where-Object { $_.isDefault -eq $true }) | Select-Object -First 1
                    if (-not $defaultInterface) {
                        $defaultInterface = @($existingDevice.interfaces) | Select-Object -First 1
                    }
                }
                if ($defaultInterface -and $defaultInterface.networkAddress) {
                    $currentAddress = [string]$defaultInterface.networkAddress
                }

                if ($currentAddress -and $currentAddress -ne $dev.IP) {
                    if ($defaultInterface -and $defaultInterface.interfaceId) {
                        try {
                            Set-WUGDeviceInterface `
                                -DeviceId $existingDevice.id `
                                -InterfaceId $defaultInterface.interfaceId `
                                -NetworkAddress $dev.IP `
                                -IsDefault $true
                            Write-Host "           Updated address: $currentAddress -> $($dev.IP)" -ForegroundColor Yellow
                        }
                        catch {
                            Write-Warning "  Failed to update address for '$($dev.Name)' ($currentAddress -> $($dev.IP)): $_"
                        }
                    }
                    else {
                        Write-Warning "  Existing device '$($dev.Name)' has no resolvable default interface; address remains $currentAddress (discovered $($dev.IP))."
                    }
                }
                continue
            }

            if ($dev.Type -eq 'Role') {
                $note = "Clustered role '$($dev.Attrs['MSCluster.ResourceGroup'])' in cluster '$($dev.Cluster)'. " +
                        "This device owns SHARED cluster resources and follows the role across failover. " +
                        "Node-local resources belong on the node devices."
            }
            else {
                $note = "Failover cluster node in cluster '$($dev.Cluster)'. " +
                        "This device owns NODE-LOCAL resources. Shared role resources belong on the role virtual IP devices."
            }

            $splat = @{
                displayName   = $dev.Name
                DeviceAddress = $dev.IP
                Hostname      = $dev.Name
                Brand         = 'Microsoft'
                OS            = 'Windows'
                Note          = $note
            }
            if ($DeviceGroupName) { $splat['GroupName'] = $DeviceGroupName }

            Write-Host "  [CREATE] $($dev.Name) ($($dev.IP)) [$($dev.Type)]" -ForegroundColor White
            try {
                Add-WUGDeviceTemplate @splat | Out-Null

                $newDevice = @(Get-WUGDevice -SearchValue $dev.IP) | Where-Object {
                    $_.networkAddress -eq $dev.IP -or $_.displayName -eq $dev.Name
                } | Select-Object -First 1

                if ($newDevice) {
                    $wugDeviceMap[$key] = $newDevice.id
                    $devicesCreated++
                    Write-Host "           Created (ID: $($newDevice.id))" -ForegroundColor Green
                }
                else {
                    Write-Warning "  Created '$($dev.Name)' but could not resolve its device ID."
                    $devicesSkipped++
                }
            }
            catch {
                Write-Warning "  Failed to create device '$($dev.Name)' ($($dev.IP)): $_"
                $devicesSkipped++
            }
        }

        # Bind every plan item to its resolved device
        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing, $devicesSkipped skipped" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Syncing monitors..." -ForegroundColor Cyan

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds $PollingIntervalSeconds `
            -PerfPollingIntervalMinutes $PollingIntervalMinutes

        Write-Host ""
        Write-Host "=== Push Complete ===" -ForegroundColor Cyan
        Write-Host "  Devices in WUG:               $($wugDeviceMap.Count)" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created: $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:          $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):      $($result.Skipped)" -ForegroundColor White
        Write-Host "  Attributes set:               $($result.AttrsUpdated)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            Write-Host "  Failed:                       $($result.Failed)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  Shared role resources are on the virtual IP devices; node-local resources are on the nodes." -ForegroundColor Gray
        Write-Host ""
    }
    '2' {
        $jsonPath = Join-Path $OutputDir "MSCluster-Discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir "MSCluster-Inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $inventory | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported to: $csvPath" -ForegroundColor Green

        $planCsvPath = Join-Path $OutputDir "MSCluster-Plan-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $plan | Export-DiscoveryPlan -Format CSV -Path $planCsvPath
        Write-Host "Plan exported to: $planCsvPath" -ForegroundColor Green
    }
    '4' {
        Write-Host ""
        Write-Host "--- Cluster inventory ---" -ForegroundColor Cyan
        $inventory | Format-Table -AutoSize
        Write-Host "--- Monitor plan ---" -ForegroundColor Cyan
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        $dashPath = Join-Path $OutputDir 'MSCluster-Dashboard.html'

        if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) {
            Write-Warning "Dashboard generator not available. Exporting JSON instead."
            $jsonPath = Join-Path $OutputDir "MSCluster-Inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
            $inventory | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
            Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
            break
        }

        Export-MSClusterDashboardHtml -DashboardData $inventory `
            -OutputPath $dashPath `
            -ReportTitle "Failover Cluster: $clusterName" | Out-Null

        Write-Host "Dashboard generated: $dashPath" -ForegroundColor Green
        Write-Host "  Nodes: $($nodeDevices.Count) | Roles: $($roleDevices.Count) | Monitors: $($plan.Count)" -ForegroundColor Gray

        $nmConsolePaths = @(
            "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
            "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
        )
        $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($nmConsolePath) {
            $wugDashDir = Join-Path $nmConsolePath 'dashboards'
            if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
            try {
                Copy-Item -Path $dashPath -Destination (Join-Path $wugDashDir 'MSCluster-Dashboard.html') -Force
                Write-Host "Copied to WUG: /NmConsole/dashboards/MSCluster-Dashboard.html" -ForegroundColor Green
            }
            catch {
                Write-Warning "Could not copy to NmConsole (run as admin?): $_"
            }
            if (Get-Command -Name 'Deploy-DashboardWebConfig' -ErrorAction SilentlyContinue) {
                Deploy-DashboardWebConfig -Path $wugDashDir
            }
        }
    }
    '6' {
        Write-Host "No action taken." -ForegroundColor Gray
    }
    default {
        Write-Warning "Invalid choice '$currentChoice'."
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "=== Failover Cluster Discovery Complete ===" -ForegroundColor Cyan
Write-Host ""

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBrX3eljDhltVdI
# WVIXd8S4Z9839Go1KAE8zw7af8mTUKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCC9UsEkrA7wPlAE5wlCgj3Iy2DD9CtC++7v0iYPFgeqIzANBgkqhkiG9w0BAQEF
# AASCAgCZi1tqYF3GGIBTD0OtAYBA7/z0HUJr1Yyuudh4S7WDwX9OsRDiIFX+jYrq
# 1akjYYLx7wh4CGUkDM+z0XcTv8Y/VDGBRPbit+qZvAIM3RKVQNKjoHq6I0nVDVxU
# dxfoMYfZO7OHuunkJ4m0vuZRzowZ/FQ3L9x9wQxwXtV40FSPQRb6Y+HbIt2Y+Cbd
# S/ReeSCwLckimIoCCq1rMr6yu6TFlxkQtvnJv1XzymIIMp0VAZc+3q5nz70YdDXp
# XHhM/ldAU3sl8JkW+0FwBA8YdgYAi8dFRQvZ/0+JBNnyikIfV3MtHfy+lbq/9/am
# FzpFb58gjal9oJqUPM/yF0QvmsK7kb/cK6cdFbEn+8PrcLEZJIFPgS23G7TezL/+
# pdEFaaDEE+v947v+Anyu/ImHPEverkYCv8RosceVEb0dCdiUWDnz31rSQjYqdxq1
# U1MPLV2RDdMvlwJuLM/U0qSPRJJLTjI2vRjkB0obp7MM4Myv7h7vjeyH9hVTVxhc
# pw5i1DcwAIRRoEOCIE7AOGzY7i5o9HDMilN39AnpkM5MyIPBA3uvqvvxP92t48Df
# 66hjAAGV/P9pxOOMItYhOsMomxj9X9rSm9XDC0T9NfJG9V1EDXx0V5KBSIu52m12
# MLIDNjh+KaetShUxRJxKcEKwjglh2vC1JYFqs13zkcORdmm+06GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA4MzAyMzI0NThaMC8GCSqGSIb3DQEJBDEiBCDgTN4e
# PCtkHRou25qINaDEG4wGqtA/qs72XjtqGT2ZFjANBgkqhkiG9w0BAQEFAASCAgCM
# L2J8hUdBcFrP1GFqYTF/BYJNk8/Oxy8nThKxr5l9LjDGo7FKl+F02uKt4ht6U60g
# GaAozRLbfnVdaFHg6whAeXOI/yCVVpvCpXnRmu+uum7y9l5BfsIx/c0ZIoryItlM
# Xoi9EK7u+Fg6yYtbDaZstE0xrGtqBSMDc/R7LDyuGSAxY1kaK7alMnB75ddXF80d
# fZBfJYFWuHrfgMR4zdHQuFQpDk/cphAmegbB6mV7g97LPWD9XtK6yYUW7OpoC/2S
# 6Xm79og7Dq1idcyQgaBxSdUsvGEpvpQrf/xoBVMgpWpL4qTlYKEEeGKYrbC2AJzq
# Da6WOGqO9c0Ha8+PYsWcaKY3Fp7r3TZzpECFADGd6I9EA1b4FJb4A+9rVJF9L/t+
# ZEPEOwibNAh7KYn5CM9WONak8k2svwDHk1SRTzhU5SLMZ8tYeHnh1bGIRsRAa69U
# kYKzZgo4Q4p1mIFZRUTALsXMjVj9MwdddLMYV6qH/+KDUl6kpi4yIEZi3tGJbdQ6
# K92vdjEzOeVyZ/ZNfvNGVjYtyI/OMYJIvFijN9rSuvhoulIk4SdgNjLd7BDpZ+do
# /HR8N4msiiA5Snu8m2aot6KYh4m9YZlXZJ2KpYYQM3VMZ8g45wT0kej6WTIVJv5i
# ioBdEkHvCQ5sCJL9hBJIhXOWm7dbrXou+sUybEBNSA==
# SIG # End signature block
