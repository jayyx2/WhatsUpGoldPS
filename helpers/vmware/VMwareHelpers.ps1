# =============================================================================
# VMware vSphere Helpers for WhatsUpGoldPS
# Requires VMware PowerCLI modules. Install them first:
#   Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
# =============================================================================

function Connect-VMware {
    <#
    .SYNOPSIS
        Connects to a VMware vCenter Server or ESXi host.
    .DESCRIPTION
        Wraps Connect-VIServer to establish a session with a vCenter Server
        or standalone ESXi host. The session is stored in PowerCLI's default
        connection state and used by all subsequent helper functions.
    .PARAMETER Server
        The hostname or IP address of the vCenter Server or ESXi host.
    .PARAMETER Credential
        PSCredential for authentication.
    .PARAMETER Port
        The port number. Defaults to 443.
    .PARAMETER IgnoreSSLErrors
        Skip SSL certificate validation.
    .EXAMPLE
        $cred = Get-Credential -UserName "administrator@vsphere.local"
        Connect-VMware -Server "vcenter01.lab.local" -Credential $cred
        Connects to vCenter Server using the specified credentials.
    .EXAMPLE
        Connect-VMware -Server "192.168.1.100" -Credential $cred -IgnoreSSLErrors
        Connects to a vCenter Server with self-signed certificates.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [int]$Port = 443,
        [switch]$IgnoreSSLErrors
    )

    if ($IgnoreSSLErrors) {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session -ErrorAction SilentlyContinue | Out-Null
    }

    try {
        $connection = Connect-VIServer -Server $Server -Credential $Credential -Port $Port -ErrorAction Stop
        Write-Verbose "Connected to VMware: $Server ($($connection.ProductLine) $($connection.Version))"
        return $connection
    }
    catch {
        throw "Failed to connect to VMware server $Server : $($_.Exception.Message)"
    }
}

function Get-VMwareClusters {
    <#
    .SYNOPSIS
        Returns all vSphere clusters.
    .DESCRIPTION
        Wraps Get-Cluster and returns a collection of cluster objects with
        HA, DRS, and EVC configuration details.
    .EXAMPLE
        Get-VMwareClusters
        Returns all clusters in the connected vCenter.
    .EXAMPLE
        Get-VMwareClusters | Where-Object { $_.HAEnabled -eq $true }
        Returns only HA-enabled clusters.
    #>

    foreach ($cluster in (Get-Cluster -ErrorAction Stop)) {
        [PSCustomObject]@{
            Name               = "$($cluster.Name)"
            HAEnabled          = "$($cluster.HAEnabled)"
            HAFailoverLevel    = "$($cluster.HAFailoverLevel)"
            DrsEnabled         = "$($cluster.DrsEnabled)"
            DrsAutomationLevel = "$($cluster.DrsAutomationLevel)"
            EVCMode            = "$($cluster.EVCMode)"
        }
    }
}

function Get-VMwareDatastores {
    <#
    .SYNOPSIS
        Returns all datastores in the connected vSphere environment.
    .DESCRIPTION
        Wraps Get-Datastore and returns capacity, free space, and usage information.
    .EXAMPLE
        Get-VMwareDatastores
        Returns all datastores with capacity and usage details.
    .EXAMPLE
        Get-VMwareDatastores | Where-Object { [double]$_.PercentFree -lt 20 }
        Returns datastores with less than 20% free space.
    #>

    foreach ($ds in (Get-Datastore -ErrorAction Stop)) {
        [PSCustomObject]@{
            Name        = "$($ds.Name)"
            CapacityGB  = "$([math]::Round($ds.CapacityGB, 2))"
            FreeSpaceGB = "$([math]::Round($ds.FreeSpaceGB, 2))"
            PercentFree = "$([math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1))"
            Type        = "$($ds.Type)"
            State       = "$($ds.State)"
        }
    }
}

function Get-VMwareHosts {
    <#
    .SYNOPSIS
        Returns all ESXi hosts in the connected vSphere environment.
    .DESCRIPTION
        Wraps Get-VMHost and returns a simplified collection of ESXi host objects.
    .EXAMPLE
        Get-VMwareHosts
        Returns all ESXi hosts in the connected vCenter.
    .EXAMPLE
        Get-VMwareHosts | Where-Object { $_.ConnectionState -eq 'Connected' }
        Returns only connected ESXi hosts.
    #>

    Get-VMHost -ErrorAction Stop
}

function Get-VMwareHostDetail {
    <#
    .SYNOPSIS
        Gathers detailed information about a single ESXi host.
    .DESCRIPTION
        Takes an ESXi host object and returns comprehensive details including
        hardware, CPU, memory, networking, and real-time performance metrics.
    .PARAMETER VMHost
        An ESXi host object returned by Get-VMwareHosts or Get-VMHost.
    .EXAMPLE
        $hosts = Get-VMwareHosts
        Get-VMwareHostDetail -VMHost $hosts[0]
        Returns detailed information for the first ESXi host.
    .EXAMPLE
        Get-VMwareHosts | ForEach-Object { Get-VMwareHostDetail -VMHost $_ }
        Returns detailed information for every ESXi host.
    #>
    param(
        [Parameter(Mandatory)]$VMHost
    )

    $mgmtIP = (Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -ErrorAction SilentlyContinue |
        Where-Object { $_.ManagementTrafficEnabled } | Select-Object -First 1).IP
    if (-not $mgmtIP) { $mgmtIP = "N/A" }

    $clusterName = if ($VMHost.Parent -and $VMHost.Parent.GetType().Name -eq 'ClusterImpl') {
        "$($VMHost.Parent.Name)"
    } else { "N/A" }

    $cpuAvg = (Get-Stat -Entity $VMHost -Stat "cpu.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average
    $memAvg = (Get-Stat -Entity $VMHost -Stat "mem.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average
    $netAvg = (Get-Stat -Entity $VMHost -Stat "net.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average
    $diskAvg = (Get-Stat -Entity $VMHost -Stat "disk.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
        Measure-Object -Property Value -Average).Average

    $hostDatastores = ($VMHost | Get-Datastore -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ", "

    [PSCustomObject]@{
        Type            = "ESXi Host"
        Name            = "$($VMHost.Name)"
        IPAddress       = $mgmtIP
        Cluster         = $clusterName
        ConnectionState = "$($VMHost.ConnectionState)"
        PowerState      = "$($VMHost.PowerState)"
        Version         = "$($VMHost.Version)"
        Build           = "$($VMHost.Build)"
        Manufacturer    = "$($VMHost.Manufacturer)"
        Model           = "$($VMHost.Model)"
        CpuSockets      = "$($VMHost.ExtensionData.Hardware.CpuInfo.NumCpuPackages)"
        CpuCores        = "$($VMHost.ExtensionData.Hardware.CpuInfo.NumCpuCores)"
        CpuThreads      = "$($VMHost.ExtensionData.Hardware.CpuInfo.NumCpuThreads)"
        CpuTotalMHz     = "$($VMHost.CpuTotalMhz)"
        CpuUsageMHz     = "$($VMHost.CpuUsageMhz)"
        MemoryTotalGB   = "$([math]::Round($VMHost.MemoryTotalGB, 2))"
        MemoryUsageGB   = "$([math]::Round($VMHost.MemoryUsageGB, 2))"
        CpuUsagePct     = "$(if ($null -ne $cpuAvg) { [math]::Round($cpuAvg, 2) } else { 'N/A' })"
        MemUsagePct     = "$(if ($null -ne $memAvg) { [math]::Round($memAvg, 2) } else { 'N/A' })"
        NetUsageKBps    = "$(if ($null -ne $netAvg) { [math]::Round($netAvg, 2) } else { 'N/A' })"
        DiskUsageKBps   = "$(if ($null -ne $diskAvg) { [math]::Round($diskAvg, 2) } else { 'N/A' })"
        Datastores      = $hostDatastores
    }
}

function Get-VMwareVMs {
    <#
    .SYNOPSIS
        Returns all virtual machines in the connected vSphere environment.
    .DESCRIPTION
        Wraps Get-VM and returns a simplified collection of VM objects.
    .EXAMPLE
        Get-VMwareVMs
        Returns all VMs in the connected vCenter.
    .EXAMPLE
        Get-VMwareVMs | Where-Object { $_.PowerState -eq 'PoweredOn' }
        Returns only powered-on VMs.
    #>

    Get-VM -ErrorAction Stop
}

function Get-VMwareVMDetail {
    <#
    .SYNOPSIS
        Gathers detailed information about a single virtual machine.
    .DESCRIPTION
        Takes a VM object and returns comprehensive details including guest OS,
        CPU, memory, disk, network, and real-time performance metrics.
    .PARAMETER VM
        A VM object returned by Get-VMwareVMs or Get-VM.
    .EXAMPLE
        $vms = Get-VMwareVMs
        Get-VMwareVMDetail -VM $vms[0]
        Returns detailed information for the first VM.
    .EXAMPLE
        Get-VMwareVMs | ForEach-Object { Get-VMwareVMDetail -VM $_ }
        Returns detailed information for every VM.
    #>
    param(
        [Parameter(Mandatory)]$VM
    )

    $guest = $VM | Get-VMGuest -ErrorAction SilentlyContinue
    $ipAddr = $guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
    if (-not $ipAddr) { $ipAddr = "N/A" }

    $nics = $VM | Get-NetworkAdapter -ErrorAction SilentlyContinue
    $disks = $VM | Get-HardDisk -ErrorAction SilentlyContinue

    # Parse datastore names from hard disk file paths ([DatastoreName] path/to.vmdk)
    $vmDatastores = @()
    if ($disks) {
        $vmDatastores = @($disks | ForEach-Object {
            if ($_.Filename -match '^\[([^\]]+)\]') { $Matches[1] }
        } | Select-Object -Unique)
    }
    $datastoreStr = if ($vmDatastores.Count -gt 0) { $vmDatastores -join ', ' } else { 'N/A' }

    $cpuAvg = $null; $memAvg = $null; $netAvg = $null; $diskAvg = $null; $diskLat = $null
    if ($VM.PowerState -eq 'PoweredOn') {
        $cpuAvg = (Get-Stat -Entity $VM -Stat "cpu.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $memAvg = (Get-Stat -Entity $VM -Stat "mem.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $netAvg = (Get-Stat -Entity $VM -Stat "net.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $diskAvg = (Get-Stat -Entity $VM -Stat "disk.usage.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average
        $diskLat = (Get-Stat -Entity $VM -Stat "disk.totalLatency.average" -Realtime -MaxSamples 5 -ErrorAction SilentlyContinue |
            Measure-Object -Property Value -Average).Average

        # Fallback to 5-minute interval stats if realtime returned nothing
        if ($null -eq $diskAvg) {
            $diskAvg = (Get-Stat -Entity $VM -Stat "disk.usage.average" -IntervalSecs 300 -MaxSamples 1 -ErrorAction SilentlyContinue |
                Measure-Object -Property Value -Average).Average
        }
        if ($null -eq $diskLat) {
            $diskLat = (Get-Stat -Entity $VM -Stat "disk.totalLatency.average" -IntervalSecs 300 -MaxSamples 1 -ErrorAction SilentlyContinue |
                Measure-Object -Property Value -Average).Average
        }
    }

    $hostName = "$($VM.VMHost.Name)"
    $clusterName = if ($VM.VMHost.Parent -and $VM.VMHost.Parent.GetType().Name -eq 'ClusterImpl') {
        "$($VM.VMHost.Parent.Name)"
    } else { "N/A" }

    [PSCustomObject]@{
        Name              = "$($VM.Name)"
        IPAddress         = $ipAddr
        PowerState        = "$($VM.PowerState)"
        ESXiHost          = $hostName
        Cluster           = $clusterName
        GuestOS           = "$($VM.ExtensionData.Config.GuestFullName)"
        GuestFamily       = "$($guest.GuestFamily)"
        ToolsStatus       = "$($VM.ExtensionData.Guest.ToolsStatus)"
        NumCPU            = "$($VM.NumCpu)"
        MemoryGB          = "$($VM.MemoryGB)"
        ProvisionedSpaceGB = "$([math]::Round($VM.ProvisionedSpaceGB, 2))"
        UsedSpaceGB       = "$([math]::Round($VM.UsedSpaceGB, 2))"
        NicCount          = "$(@($nics).Count)"
        NicTypes          = "$(($nics.Type | Select-Object -Unique) -join ', ')"
        NetworkNames      = "$(($nics.NetworkName | Select-Object -Unique) -join ', ')"
        DiskCount         = "$(@($disks).Count)"
        DiskTotalGB       = "$([math]::Round(($disks | Measure-Object -Property CapacityGB -Sum).Sum, 2))"
        Datastores        = $datastoreStr
        CpuUsagePct       = "$(if ($null -ne $cpuAvg) { [math]::Round($cpuAvg, 2) } else { 'N/A' })"
        MemUsagePct       = "$(if ($null -ne $memAvg) { [math]::Round($memAvg, 2) } else { 'N/A' })"
        NetUsageKBps      = "$(if ($null -ne $netAvg) { [math]::Round($netAvg, 2) } else { 'N/A' })"
        DiskUsageKBps     = "$(if ($null -ne $diskAvg) { [math]::Round($diskAvg, 2) } else { 'N/A' })"
        DiskLatencyMs     = "$(if ($null -ne $diskLat) { [math]::Round($diskLat, 2) } else { 'N/A' })"
    }
}

function Get-VMwareDashboard {
    <#
    .SYNOPSIS
        Builds a flat dashboard view combining ESXi hosts and their VMs.
    .DESCRIPTION
        Gathers host and VM details from the connected vCenter, then returns
        a unified collection of objects suitable for rendering in an interactive
        Bootstrap Table dashboard. Each row is either an ESXi host or a VM,
        distinguished by a Type column. Columns that apply to only one type
        show "N/A" for the other, following the Proxmox dashboard pattern.
    .EXAMPLE
        Connect-VMware -Server "vcenter01" -Credential $cred
        Get-VMwareDashboard
        Returns a flat dashboard view of all hosts and VMs.
    .EXAMPLE
        $data = Get-VMwareDashboard
        Export-VMwareDashboardHtml -DashboardData $data -OutputPath "C:\Reports\vmware.html"
        Start-Process "C:\Reports\vmware.html"
        End-to-end: connect, gather, export, and open in browser.
    #>

    $results = @()
    $esxiHosts = Get-VMwareHosts

    foreach ($esxi in $esxiHosts) {
        $hostDetail = Get-VMwareHostDetail -VMHost $esxi

        # -- Host row --
        $results += [PSCustomObject]@{
            Type              = "Host"
            Name              = $hostDetail.Name
            PowerState        = $hostDetail.PowerState
            IPAddress         = $hostDetail.IPAddress
            Cluster           = $hostDetail.Cluster
            ESXiHost          = $hostDetail.Name
            GuestOS           = "VMware ESXi $($hostDetail.Version)"
            ToolsStatus       = "N/A"
            CPU               = "$($hostDetail.CpuUsagePct)% ($($hostDetail.CpuSockets)s/$($hostDetail.CpuCores)c/$($hostDetail.CpuThreads)t)"
            Memory            = "$($hostDetail.MemUsagePct)% ($($hostDetail.MemoryUsageGB) / $($hostDetail.MemoryTotalGB) GB)"
            CpuUsagePct       = $hostDetail.CpuUsagePct
            MemUsagePct       = $hostDetail.MemUsagePct
            NetUsageKBps      = $hostDetail.NetUsageKBps
            DiskUsageKBps     = $hostDetail.DiskUsageKBps
            Hardware          = "$($hostDetail.Manufacturer) $($hostDetail.Model)".Trim()
            VersionBuild      = "ESXi $($hostDetail.Version) Build $($hostDetail.Build)"
            Datastores        = $hostDetail.Datastores
            ProvisionedSpaceGB = "N/A"
            UsedSpaceGB       = "N/A"
            NicCount          = "N/A"
            DiskCount         = "N/A"
            DiskLatencyMs     = "N/A"
        }

        # -- VM rows --
        $vms = Get-VM -Location $esxi -ErrorAction SilentlyContinue
        foreach ($vm in $vms) {
            $vmDetail = Get-VMwareVMDetail -VM $vm

            $results += [PSCustomObject]@{
                Type              = "VM"
                Name              = $vmDetail.Name
                PowerState        = $vmDetail.PowerState
                IPAddress         = $vmDetail.IPAddress
                Cluster           = $vmDetail.Cluster
                ESXiHost          = $vmDetail.ESXiHost
                GuestOS           = $vmDetail.GuestOS
                ToolsStatus       = $vmDetail.ToolsStatus
                CPU               = "$($vmDetail.CpuUsagePct)% ($($vmDetail.NumCPU) vCPU)"
                Memory            = "$($vmDetail.MemUsagePct)% ($($vmDetail.MemoryGB) GB)"
                CpuUsagePct       = $vmDetail.CpuUsagePct
                MemUsagePct       = $vmDetail.MemUsagePct
                NetUsageKBps      = $vmDetail.NetUsageKBps
                DiskUsageKBps     = $vmDetail.DiskUsageKBps
                Hardware          = "N/A"
                VersionBuild      = "N/A"
                Datastores        = $vmDetail.Datastores
                ProvisionedSpaceGB = $vmDetail.ProvisionedSpaceGB
                UsedSpaceGB       = $vmDetail.UsedSpaceGB
                NicCount          = $vmDetail.NicCount
                DiskCount         = $vmDetail.DiskCount
                DiskLatencyMs     = $vmDetail.DiskLatencyMs
            }
        }
    }

    return $results
}

function Export-VMwareDashboardHtml {
    <#
    .SYNOPSIS
        Renders VMware dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-VMwareDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-VMwareDashboard.
    .PARAMETER OutputPath
        File path for the output HTML file.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "VMware vSphere Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        VMware-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-VMwareDashboard
        Export-VMwareDashboardHtml -DashboardData $data -OutputPath "C:\Reports\vmware.html"
        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-VMwareDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\vmware.html" -ReportTitle "Production vSphere"
        Exports with a custom report title.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "VMware vSphere Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "VMware-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $titleMap = @{
        'Type'              = 'Type'
        'Name'              = 'Name'
        'PowerState'        = 'Power State'
        'IPAddress'         = 'IP Address'
        'Cluster'           = 'Cluster'
        'ESXiHost'          = 'ESXi Host'
        'GuestOS'           = 'Guest OS'
        'ToolsStatus'       = 'Tools Status'
        'CPU'               = 'CPU'
        'Memory'            = 'Memory'
        'CpuUsagePct'       = 'CPU %'
        'MemUsagePct'       = 'Mem %'
        'NetUsageKBps'      = 'Net KBps'
        'DiskUsageKBps'     = 'Disk KBps'
        'Hardware'          = 'Hardware'
        'VersionBuild'      = 'Version / Build'
        'Datastores'        = 'Datastores'
        'ProvisionedSpaceGB' = 'Provisioned GB'
        'UsedSpaceGB'       = 'Used GB'
        'NicCount'          = 'NICs'
        'DiskCount'         = 'Disks'
        'DiskLatencyMs'     = 'Disk Latency ms'
    }
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $title = if ($titleMap.ContainsKey($prop.Name)) { $titleMap[$prop.Name] } else { ($prop.Name -creplace '([A-Z])', ' $1').Trim() }
        $col = @{
            field      = $prop.Name
            title      = $title
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'PowerState')  { $col.formatter = 'formatPowerState' }
        if ($prop.Name -eq 'ToolsStatus') { $col.formatter = 'formatToolsStatus' }
        if ($prop.Name -eq 'Type')        { $col.formatter = 'formatType' }
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
    Write-Verbose "VMware Dashboard HTML written to $OutputPath"
}

function Disconnect-VMware {
    <#
    .SYNOPSIS
        Disconnects from the VMware vCenter Server or ESXi host.
    .DESCRIPTION
        Wraps Disconnect-VIServer to cleanly close the vSphere session.
    .PARAMETER Server
        Optional server name to disconnect from. If omitted, disconnects all.
    .EXAMPLE
        Disconnect-VMware
        Disconnects from all connected vSphere servers.
    .EXAMPLE
        Disconnect-VMware -Server "vcenter01"
        Disconnects from a specific vCenter server.
    #>
    param(
        [string]$Server
    )

    try {
        if ($Server) {
            Disconnect-VIServer -Server $Server -Confirm:$false -ErrorAction Stop
        } else {
            Disconnect-VIServer -Confirm:$false -Force -ErrorAction Stop
        }
        Write-Verbose "Disconnected from VMware"
    }
    catch {
        Write-Warning "VMware disconnect: $($_.Exception.Message)"
    }
}
