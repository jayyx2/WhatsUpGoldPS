# =============================================================================
# VMware vSphere Helpers for WhatsUpGoldPS
#
# Two collection methods supported:
#   [1] VMware.PowerCLI module (Connect-VIServer, Get-VM, etc.)
#   [2] vCenter REST API direct (zero external dependencies -- uses Invoke-RestMethod)
#
# Functions suffixed with "REST" use the vCenter REST API directly.
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

# =============================================================================
# REST API Collection Method (zero external dependencies)
# Uses vCenter REST API via Invoke-RestMethod (PS 5.1 built-in)
# vSphere 6.5+ required for REST API support
# =============================================================================

# Script-scoped session cache
if (-not (Get-Variable -Name '_VMwareRESTSession' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:_VMwareRESTSession = $null
    $script:_VMwareRESTServer = $null
    $script:_VMwareRESTPort = 443
}

function Invoke-VMwareREST {
    <#
    .SYNOPSIS
        Internal helper -- calls a vCenter REST API endpoint with the cached session token.
    .PARAMETER Path
        API path (e.g., /api/vcenter/vm).
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER Body
        Request body for POST/PUT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'GET',
        [string]$Body
    )

    if (-not $script:_VMwareRESTSession) {
        throw "vCenter REST session not established. Call Connect-VMwareREST first."
    }

    $uri = "https://$($script:_VMwareRESTServer):$($script:_VMwareRESTPort)$Path"
    $headers = @{ 'vmware-api-session-id' = $script:_VMwareRESTSession }

    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $params.Body = $Body
        $params.ContentType = 'application/json'
    }

    return Invoke-RestMethod @params
}

function Connect-VMwareREST {
    <#
    .SYNOPSIS
        Authenticates to vCenter REST API and caches the session token.
    .PARAMETER Server
        vCenter server hostname or IP.
    .PARAMETER Credential
        PSCredential with vCenter username and password.
    .PARAMETER Port
        vCenter HTTPS port. Defaults to 443.
    .PARAMETER IgnoreSSLErrors
        Skip SSL certificate validation.
    .EXAMPLE
        $cred = Get-Credential
        Connect-VMwareREST -Server 'vcenter.lab.local' -Credential $cred -IgnoreSSLErrors
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [int]$Port = 443,
        [switch]$IgnoreSSLErrors
    )

    if ($IgnoreSSLErrors) {
        # PowerShell 5.1 SSL bypass
        try {
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }
        catch {
            # Type may already be added
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $script:_VMwareRESTServer = $Server
    $script:_VMwareRESTPort = $Port

    $uri = "https://${Server}:${Port}/api/session"
    $authBytes = [System.Text.Encoding]::UTF8.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    $authHeader = [System.Convert]::ToBase64String($authBytes)
    $headers = @{ Authorization = "Basic $authHeader" }

    try {
        $session = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -ErrorAction Stop
        # vCenter 7+ returns a plain string token; 6.x returns JSON with value
        if ($session -is [string]) {
            $script:_VMwareRESTSession = $session.Trim('"')
        }
        elseif ($session.value) {
            $script:_VMwareRESTSession = $session.value
        }
        else {
            $script:_VMwareRESTSession = "$session"
        }
        Write-Verbose "Connected to vCenter REST API at ${Server}:${Port}"
        return @{ Server = $Server; Port = $Port }
    }
    catch {
        throw "Failed to authenticate to vCenter REST API: $($_.Exception.Message)"
    }
}

function Get-VMwareClustersREST {
    <#
    .SYNOPSIS
        Returns all clusters from vCenter via REST API.
    .EXAMPLE
        Get-VMwareClustersREST
    #>

    $clusters = Invoke-VMwareREST -Path '/api/vcenter/cluster'
    foreach ($c in $clusters) {
        $detail = $null
        try { $detail = Invoke-VMwareREST -Path "/api/vcenter/cluster/$($c.cluster)" } catch { }
        [PSCustomObject]@{
            Name               = "$($c.name)"
            HAEnabled          = if ($detail -and $detail.ha_enabled -ne $null) { $detail.ha_enabled } else { 'N/A' }
            DrsEnabled         = if ($detail -and $detail.drs_enabled -ne $null) { $detail.drs_enabled } else { 'N/A' }
            ClusterId          = "$($c.cluster)"
        }
    }
}

function Get-VMwareHostsREST {
    <#
    .SYNOPSIS
        Returns all ESXi hosts from vCenter via REST API.
    .EXAMPLE
        Get-VMwareHostsREST
    #>

    $hosts = Invoke-VMwareREST -Path '/api/vcenter/host'
    foreach ($h in $hosts) {
        [PSCustomObject]@{
            Name            = "$($h.name)"
            HostId          = "$($h.host)"
            ConnectionState = "$($h.connection_state)"
            PowerState      = "$($h.power_state)"
        }
    }
}

function Get-VMwareHostDetailREST {
    <#
    .SYNOPSIS
        Returns detailed ESXi host information via REST API.
    .PARAMETER HostId
        The vCenter host MoRef ID (e.g., host-10).
    .PARAMETER HostName
        The ESXi host name (for output).
    .EXAMPLE
        Get-VMwareHostDetailREST -HostId 'host-10' -HostName 'esxi01.lab.local'
    #>
    param(
        [Parameter(Mandatory)][string]$HostId,
        [string]$HostName
    )

    $ip = $null
    # Get management IP from network interfaces
    try {
        $nics = Invoke-VMwareREST -Path "/api/vcenter/host/$HostId"
        # Host detail endpoint may not have IP; try to resolve hostname
        if ($HostName) {
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch { }
        }
    }
    catch { }

    [PSCustomObject]@{
        Type            = 'ESXi Host'
        Name            = if ($HostName) { $HostName } else { $HostId }
        IPAddress       = if ($ip) { $ip } else { '' }
        HostId          = $HostId
    }
}

function Get-VMwareVMsREST {
    <#
    .SYNOPSIS
        Returns all VMs from vCenter via REST API.
    .EXAMPLE
        Get-VMwareVMsREST
    #>

    $vms = Invoke-VMwareREST -Path '/api/vcenter/vm'
    foreach ($vm in $vms) {
        [PSCustomObject]@{
            Name       = "$($vm.name)"
            VMId       = "$($vm.vm)"
            PowerState = "$($vm.power_state)"
            CpuCount   = if ($vm.cpu_count) { $vm.cpu_count } else { 0 }
            MemorySizeMB = if ($vm.memory_size_MiB) { $vm.memory_size_MiB } else { 0 }
        }
    }
}

function Get-VMwareVMDetailREST {
    <#
    .SYNOPSIS
        Returns detailed VM information via REST API.
    .PARAMETER VMId
        The vCenter VM MoRef ID (e.g., vm-10).
    .PARAMETER VMName
        The VM name (for output).
    .EXAMPLE
        Get-VMwareVMDetailREST -VMId 'vm-10' -VMName 'MyServer'
    #>
    param(
        [Parameter(Mandatory)][string]$VMId,
        [string]$VMName
    )

    $detail = $null
    try { $detail = Invoke-VMwareREST -Path "/api/vcenter/vm/$VMId" } catch { }

    $ip = $null
    $guestOS = 'N/A'
    $guestFamily = 'N/A'
    $toolsStatus = 'N/A'

    if ($detail) {
        if ($detail.guest_OS) { $guestOS = "$($detail.guest_OS)" }

        # Try to get guest identity for IP
        try {
            $identity = Invoke-VMwareREST -Path "/api/vcenter/vm/$VMId/guest/identity"
            if ($identity.ip_address) { $ip = "$($identity.ip_address)" }
            if ($identity.family) { $guestFamily = "$($identity.family)" }
            if ($identity.name) { $guestOS = "$($identity.name)" }
        }
        catch { }

        # Try tools info
        try {
            $tools = Invoke-VMwareREST -Path "/api/vcenter/vm/$VMId/tools"
            if ($tools.run_state) { $toolsStatus = "$($tools.run_state)" }
        }
        catch { }
    }

    $numCpu = 0; $memGB = 0; $diskCount = 0; $nicCount = 0
    if ($detail) {
        if ($detail.cpu -and $detail.cpu.count) { $numCpu = $detail.cpu.count }
        if ($detail.memory -and $detail.memory.size_MiB) { $memGB = [math]::Round($detail.memory.size_MiB / 1024, 2) }
        if ($detail.disks) { $diskCount = @($detail.disks.PSObject.Properties).Count }
        if ($detail.nics) { $nicCount = @($detail.nics.PSObject.Properties).Count }
    }

    $hostName = 'N/A'
    # VM detail doesn't always include host; we pass it from the caller if needed

    [PSCustomObject]@{
        Name          = if ($VMName) { $VMName } else { $VMId }
        IPAddress     = if ($ip) { $ip } else { '' }
        PowerState    = if ($detail -and $detail.power_state) { "$($detail.power_state)" } else { 'N/A' }
        GuestOS       = $guestOS
        GuestFamily   = $guestFamily
        ToolsStatus   = $toolsStatus
        NumCPU        = $numCpu
        MemoryGB      = $memGB
        DiskCount     = $diskCount
        NicCount      = $nicCount
        VMId          = $VMId
    }
}

function Disconnect-VMwareREST {
    <#
    .SYNOPSIS
        Disconnects from vCenter REST API session.
    .EXAMPLE
        Disconnect-VMwareREST
    #>

    if ($script:_VMwareRESTSession) {
        try {
            Invoke-VMwareREST -Path '/api/session' -Method DELETE
            Write-Verbose "Disconnected from vCenter REST API"
        }
        catch {
            Write-Verbose "vCenter REST disconnect: $($_.Exception.Message)"
        }
        $script:_VMwareRESTSession = $null
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBsFjwk/PfKMGkx
# O6lE+BrTuFErUqncII7a54KnkKv4GqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgm7kUzz64wTdB9/jnccbMxk9DLQMF6WGu
# K35XhtV2zggwDQYJKoZIhvcNAQEBBQAEggIAFM6pBD9vvoGDOlnfFaBVyxLVec74
# UbG8J5vth95zDgomj4SaygPGRxxGjRJCsphBEC/Tppek7WEMDetbCogFTz9fVp6q
# jEGOUuu43CeHnu22pLTzm3DhYjvGreGxURYcrURiYMSLhNKxxy1foVr95EK8kTeC
# kbrNxDxK0sudtXv9ja8TZSPGUT+15zXWQf8EIzltqLOySXyBjErOUmgvj6+D1QkM
# knjtS3C+YV+FGnKwcB2HSKikbLesZu8UgIA6/DRtf+EZigN3C+pPRglcsj0k51oT
# R1HeMQFL+RDXYe7K2CTaLBjzlOg24/H/9kIqJKjb+qEGHpwEjYFtDXWsLed7JlZh
# JNAEOm21+e7VdD8/LqCcXBVy/tnVJxHPvOXPsqpKbtA+dUsVYArWPHh+rqFtsVs4
# G1uoks8WSes22EHgVgQiAVioD4XE7wdyhH/HSyOwRBbRkO8YOnftl3A2L9fS4Nv/
# Q4wzMBrY/rEFAqLI36HWZqM52eecG3Q+zWaairQKY4VaXVeLSqoGK8sCZbXMfmSl
# 39vALZB3NsN5dczWLMAL6ivQ5kW/wvkwO2AfdnbFqaQqdGzcHutu+UF8eskA9MgF
# iRqo/4mWZ5bji8XflVQWmB6RMrVASJ+tDrXEpUGe27v2FH2Jj9gOpW6S/IYFPbAS
# 2C6HgbGN01SkWNo=
# SIG # End signature block
