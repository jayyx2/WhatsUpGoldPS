# =============================================================================
# Docker Engine API Helpers for WhatsUpGoldPS
# Communicates with Docker Engine REST API (v1.45+).
# Enable remote API: https://docs.docker.com/engine/daemon/remote-access/
# Default ports: 2375 (unencrypted) / 2376 (TLS)
# =============================================================================

function Initialize-SSLBypass {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
        $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
    }
    else {
        if (-not ([System.Management.Automation.PSTypeName]'SSLValidator').Type) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SSLValidator {
    private static bool OnValidateCertificate(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) {
        return true;
    }
    public static void OverrideValidation() {
        ServicePointManager.ServerCertificateValidationCallback =
            new RemoteCertificateValidationCallback(OnValidateCertificate);
        ServicePointManager.Expect100Continue = false;
        ServicePointManager.DefaultConnectionLimit = 64;
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
    }
}
"@
        }
        [SSLValidator]::OverrideValidation()
    }
    Write-Warning "Ignoring SSL certificate validation errors. Use this option with caution."
}

function Invoke-DockerAPI {
    <#
    .SYNOPSIS
        Sends a request to the Docker Engine API.
    .DESCRIPTION
        Wrapper around Invoke-RestMethod for Docker Engine API calls.
        Handles connection reuse, retries on PS 5.1 connection-pool
        exhaustion, and optional TLS client certificate auth.
    .PARAMETER BaseUri
        The base URI of the Docker host (e.g. http://192.168.1.100:2375).
    .PARAMETER Endpoint
        The API path (e.g. /containers/json).
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER Body
        Optional hashtable body for POST requests.
    .PARAMETER Certificate
        Optional X509Certificate2 for TLS client-cert auth (port 2376).
    .EXAMPLE
        Invoke-DockerAPI -BaseUri "http://docker01:2375" -Endpoint "/info"
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [string]$Endpoint = '/',
        [string]$Method = 'Get',
        [hashtable]$Body,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )
    $uri = "$BaseUri$Endpoint"
    $params = @{ Uri = $uri; Method = $Method; ContentType = 'application/json' }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    if ($Certificate) { $params.Certificate = $Certificate }

    $maxRetries = if ($PSVersionTable.PSEdition -eq 'Core') { 0 } else { 2 }
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        try {
            return (Invoke-RestMethod @params)
        } catch {
            $isClosed = $_.Exception.Message -match 'underlying connection was closed|unexpected error occurred on a send'
            if ($isClosed -and $attempt -lt $maxRetries) {
                try {
                    $sp = [System.Net.ServicePointManager]::FindServicePoint([System.Uri]$uri)
                    $sp.CloseConnectionGroup('')
                } catch {}
                Start-Sleep -Milliseconds (300 * ($attempt + 1))
            } else {
                throw
            }
        }
    }
}

function Connect-DockerServer {
    <#
    .SYNOPSIS
        Tests connectivity to a Docker Engine API endpoint.
    .DESCRIPTION
        Validates that the Docker Engine API is reachable by calling /version.
        Returns a connection object containing the base URI, API version, and
        Docker version information for use in subsequent API calls.
    .PARAMETER DockerHost
        The hostname or IP address of the Docker host.
    .PARAMETER Port
        TCP port for the Docker API. Defaults to 2375 (unencrypted).
        Use 2376 for TLS.
    .PARAMETER UseTLS
        Use HTTPS instead of HTTP.
    .PARAMETER IgnoreSSLErrors
        Skip SSL certificate validation (for self-signed certs).
    .PARAMETER Certificate
        Optional X509Certificate2 for TLS client-cert authentication.
    .EXAMPLE
        $conn = Connect-DockerServer -DockerHost "docker01" -Port 2375
        Connects to Docker Engine via unencrypted HTTP.
    .EXAMPLE
        $conn = Connect-DockerServer -DockerHost "docker01" -Port 2376 -UseTLS -IgnoreSSLErrors
        Connects via HTTPS with self-signed cert bypass.
    #>
    param(
        [Parameter(Mandatory)][string]$DockerHost,
        [int]$Port = 2375,
        [switch]$UseTLS,
        [switch]$IgnoreSSLErrors,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    if ($IgnoreSSLErrors) { Initialize-SSLBypass }

    $scheme = if ($UseTLS -or $Port -eq 2376) { 'https' } else { 'http' }
    $baseUri = "${scheme}://${DockerHost}:${Port}"

    try {
        $version = Invoke-DockerAPI -BaseUri $baseUri -Endpoint '/version' -Certificate $Certificate
    }
    catch {
        throw "Failed to connect to Docker Engine at ${baseUri}: $($_.Exception.Message)"
    }

    $conn = [PSCustomObject]@{
        BaseUri      = $baseUri
        ApiVersion   = $version.ApiVersion
        DockerVersion = $version.Version
        OS           = $version.Os
        Arch         = $version.Arch
        KernelVersion = $version.KernelVersion
        GoVersion    = $version.GoVersion
        Certificate  = $Certificate
    }

    Write-Verbose "Connected to Docker $($conn.DockerVersion) at $baseUri (API $($conn.ApiVersion))"
    return $conn
}

function Get-DockerSystemInfo {
    <#
    .SYNOPSIS
        Returns Docker Engine system-wide information.
    .DESCRIPTION
        Calls GET /info and returns server details including OS, kernel,
        storage driver, container/image counts, and resource limits.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .EXAMPLE
        $info = Get-DockerSystemInfo -Connection $conn
    #>
    param(
        [Parameter(Mandatory)]$Connection
    )
    $info = Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint '/info' -Certificate $Connection.Certificate

    [PSCustomObject]@{
        Hostname        = "$($info.Name)"
        OS              = "$($info.OperatingSystem)"
        OSType          = "$($info.OSType)"
        Architecture    = "$($info.Architecture)"
        KernelVersion   = "$($info.KernelVersion)"
        DockerVersion   = "$($info.ServerVersion)"
        StorageDriver   = "$($info.Driver)"
        LoggingDriver   = "$($info.LoggingDriver)"
        CgroupDriver    = "$($info.CgroupDriver)"
        Containers      = "$($info.Containers)"
        ContainersRunning = "$($info.ContainersRunning)"
        ContainersPaused = "$($info.ContainersPaused)"
        ContainersStopped = "$($info.ContainersStopped)"
        Images          = "$($info.Images)"
        CPUs            = "$($info.NCPU)"
        MemoryTotalGB   = "$([math]::Round($info.MemTotal / 1GB, 2))"
        DockerRootDir   = "$($info.DockerRootDir)"
        Swarm           = if ($info.Swarm.LocalNodeState -and $info.Swarm.LocalNodeState -ne 'inactive') { "$($info.Swarm.LocalNodeState)" } else { "inactive" }
    }
}

function Get-DockerContainers {
    <#
    .SYNOPSIS
        Returns all containers (running and stopped).
    .DESCRIPTION
        Calls GET /containers/json?all=true and returns container list.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .PARAMETER RunningOnly
        If set, returns only running containers.
    .EXAMPLE
        $containers = Get-DockerContainers -Connection $conn
    .EXAMPLE
        $running = Get-DockerContainers -Connection $conn -RunningOnly
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [switch]$RunningOnly
    )
    $all = if ($RunningOnly) { 'false' } else { 'true' }
    Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint "/containers/json?all=$all" -Certificate $Connection.Certificate
}

function Get-DockerContainerDetail {
    <#
    .SYNOPSIS
        Returns detailed inspection data for a container.
    .DESCRIPTION
        Calls GET /containers/{id}/json to return full container configuration,
        state, network settings, mount points, and resource limits.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .PARAMETER ContainerId
        The container ID or name.
    .EXAMPLE
        Get-DockerContainerDetail -Connection $conn -ContainerId "abc123"
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$ContainerId
    )
    Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint "/containers/$ContainerId/json" -Certificate $Connection.Certificate
}

function Get-DockerContainerStats {
    <#
    .SYNOPSIS
        Returns real-time CPU, memory, network, and disk I/O stats for a container.
    .DESCRIPTION
        Calls GET /containers/{id}/stats?stream=false to get a single snapshot
        of container resource usage. Calculates CPU percentage, memory usage,
        and network I/O from the raw counters.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .PARAMETER ContainerId
        The container ID or name.
    .EXAMPLE
        $stats = Get-DockerContainerStats -Connection $conn -ContainerId "abc123"
    .EXAMPLE
        Get-DockerContainers -Connection $conn -RunningOnly | ForEach-Object {
            Get-DockerContainerStats -Connection $conn -ContainerId $_.Id
        }
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$ContainerId
    )
    $raw = Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint "/containers/$ContainerId/stats?stream=false" -Certificate $Connection.Certificate

    # CPU % calculation: delta usage / delta system * num_cpus * 100
    $cpuDelta = $raw.cpu_stats.cpu_usage.total_usage - $raw.precpu_stats.cpu_usage.total_usage
    $sysDelta = $raw.cpu_stats.system_cpu_usage - $raw.precpu_stats.system_cpu_usage
    $numCPUs  = $raw.cpu_stats.online_cpus
    if (-not $numCPUs -or $numCPUs -eq 0) { $numCPUs = @($raw.cpu_stats.cpu_usage.percpu_usage).Count }
    $cpuPct = if ($sysDelta -gt 0 -and $numCPUs -gt 0) {
        [math]::Round(($cpuDelta / $sysDelta) * $numCPUs * 100, 2)
    } else { 0 }

    # Memory
    $memUsage = $raw.memory_stats.usage - ($raw.memory_stats.stats.cache -as [long])
    if ($memUsage -lt 0) { $memUsage = $raw.memory_stats.usage }
    $memLimit = $raw.memory_stats.limit
    $memPct = if ($memLimit -gt 0) { [math]::Round($memUsage / $memLimit * 100, 2) } else { 0 }

    # Network I/O (aggregate all interfaces)
    $netRx = 0; $netTx = 0
    if ($raw.networks) {
        foreach ($iface in $raw.networks.PSObject.Properties) {
            $netRx += $iface.Value.rx_bytes
            $netTx += $iface.Value.tx_bytes
        }
    }

    # Block I/O
    $blkRead = 0; $blkWrite = 0
    if ($raw.blkio_stats.io_service_bytes_recursive) {
        foreach ($entry in $raw.blkio_stats.io_service_bytes_recursive) {
            if ($entry.op -eq 'read' -or $entry.op -eq 'Read') { $blkRead += $entry.value }
            if ($entry.op -eq 'write' -or $entry.op -eq 'Write') { $blkWrite += $entry.value }
        }
    }

    [PSCustomObject]@{
        ContainerId  = $ContainerId
        CpuPercent   = $cpuPct
        MemoryUsageMB = [math]::Round($memUsage / 1MB, 2)
        MemoryLimitMB = [math]::Round($memLimit / 1MB, 2)
        MemoryPercent = $memPct
        NetRxMB       = [math]::Round($netRx / 1MB, 2)
        NetTxMB       = [math]::Round($netTx / 1MB, 2)
        BlockReadMB   = [math]::Round($blkRead / 1MB, 2)
        BlockWriteMB  = [math]::Round($blkWrite / 1MB, 2)
        PIDs          = $raw.pids_stats.current
    }
}

function Get-DockerNetworks {
    <#
    .SYNOPSIS
        Returns all Docker networks.
    .DESCRIPTION
        Calls GET /networks and returns network configuration details.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .EXAMPLE
        $networks = Get-DockerNetworks -Connection $conn
    #>
    param(
        [Parameter(Mandatory)]$Connection
    )
    $nets = Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint '/networks' -Certificate $Connection.Certificate
    foreach ($n in $nets) {
        [PSCustomObject]@{
            Name       = "$($n.Name)"
            Id         = "$($n.Id.Substring(0,12))"
            Driver     = "$($n.Driver)"
            Scope      = "$($n.Scope)"
            Internal   = "$($n.Internal)"
            IPv6       = "$($n.EnableIPv6)"
            Subnet     = "$(($n.IPAM.Config | ForEach-Object { $_.Subnet }) -join ', ')"
            Gateway    = "$(($n.IPAM.Config | ForEach-Object { $_.Gateway }) -join ', ')"
            Containers = "$(@($n.Containers.PSObject.Properties).Count)"
        }
    }
}

function Get-DockerVolumes {
    <#
    .SYNOPSIS
        Returns all Docker volumes.
    .DESCRIPTION
        Calls GET /volumes and returns volume details.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .EXAMPLE
        $volumes = Get-DockerVolumes -Connection $conn
    #>
    param(
        [Parameter(Mandatory)]$Connection
    )
    $resp = Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint '/volumes' -Certificate $Connection.Certificate
    foreach ($v in $resp.Volumes) {
        [PSCustomObject]@{
            Name       = "$($v.Name)"
            Driver     = "$($v.Driver)"
            Scope      = "$($v.Scope)"
            Mountpoint = "$($v.Mountpoint)"
            CreatedAt  = "$($v.CreatedAt)"
        }
    }
}

function Get-DockerImages {
    <#
    .SYNOPSIS
        Returns all Docker images.
    .DESCRIPTION
        Calls GET /images/json and returns image details including size and tags.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .EXAMPLE
        $images = Get-DockerImages -Connection $conn
    #>
    param(
        [Parameter(Mandatory)]$Connection
    )
    $imgs = Invoke-DockerAPI -BaseUri $Connection.BaseUri -Endpoint '/images/json' -Certificate $Connection.Certificate
    foreach ($img in $imgs) {
        [PSCustomObject]@{
            Id         = "$($img.Id.Split(':')[1].Substring(0,12))"
            Tags       = "$(($img.RepoTags | Where-Object { $_ -ne '<none>:<none>' }) -join ', ')"
            SizeMB     = "$([math]::Round($img.Size / 1MB, 2))"
            Created    = "$([DateTimeOffset]::FromUnixTimeSeconds($img.Created).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss'))"
            Containers = "$($img.Containers)"
        }
    }
}

function Get-DockerDashboard {
    <#
    .SYNOPSIS
        Builds a flat dashboard view of Docker host and container status.
    .DESCRIPTION
        Gathers system info, container list, and live stats from a Docker host,
        then returns a unified collection with Docker host as Type="Host" and
        each container as Type="Container". Follows the Proxmox/VMware dashboard
        pattern for WhatsUpGoldPS helper dashboards.
    .PARAMETER Connection
        A connection object from Connect-DockerServer.
    .EXAMPLE
        $conn = Connect-DockerServer -DockerHost "docker01"
        $data = Get-DockerDashboard -Connection $conn
    .EXAMPLE
        $data = Get-DockerDashboard -Connection $conn
        Export-DockerDashboardHtml -DashboardData $data -OutputPath "C:\Reports\docker.html"
    #>
    param(
        [Parameter(Mandatory)]$Connection
    )

    $results = @()
    $sysInfo = Get-DockerSystemInfo -Connection $Connection

    # -- Host row --
    $results += [PSCustomObject]@{
        Type           = "Host"
        Name           = $sysInfo.Hostname
        Status         = "running"
        IPAddress      = ($Connection.BaseUri -replace '^https?://' -replace ':\d+$')
        Image          = "N/A"
        CPU            = "$($sysInfo.CPUs) CPUs"
        Memory         = "$($sysInfo.MemoryTotalGB) GB Total"
        CpuPercent     = "N/A"
        MemPercent     = "N/A"
        NetRxMB        = "N/A"
        NetTxMB        = "N/A"
        BlockReadMB    = "N/A"
        BlockWriteMB   = "N/A"
        PIDs           = "N/A"
        OS             = $sysInfo.OS
        DockerVersion  = $sysInfo.DockerVersion
        StorageDriver  = $sysInfo.StorageDriver
        Containers     = "$($sysInfo.ContainersRunning) running / $($sysInfo.Containers) total"
        ImageCount     = $sysInfo.Images
        Ports          = "N/A"
        Uptime         = "N/A"
    }

    # -- Container rows --
    $containers = Get-DockerContainers -Connection $Connection
    foreach ($c in $containers) {
        $name = ($c.Names | Select-Object -First 1) -replace '^/'
        $state = "$($c.State)"
        $image = "$($c.Image)"

        # Parse ports
        $portList = @()
        if ($c.Ports) {
            foreach ($p in $c.Ports) {
                if ($p.PublicPort) {
                    $portList += "$($p.PublicPort)->$($p.PrivatePort)/$($p.Type)"
                } else {
                    $portList += "$($p.PrivatePort)/$($p.Type)"
                }
            }
        }
        $portsStr = if ($portList.Count -gt 0) { $portList -join ', ' } else { 'N/A' }

        # Uptime from Created timestamp
        $created = [DateTimeOffset]::FromUnixTimeSeconds($c.Created).LocalDateTime
        $uptime = if ($state -eq 'running') { '{0:d\.hh\:mm\:ss}' -f ((Get-Date) - $created) } else { 'N/A' }

        # Get live stats for running containers
        $cpuPct = 'N/A'; $memPct = 'N/A'; $memStr = 'N/A'; $cpuStr = 'N/A'
        $netRx = 'N/A'; $netTx = 'N/A'; $blkR = 'N/A'; $blkW = 'N/A'; $pids = 'N/A'
        if ($state -eq 'running') {
            try {
                $stats = Get-DockerContainerStats -Connection $Connection -ContainerId $c.Id
                $cpuPct = "$($stats.CpuPercent)"
                $memPct = "$($stats.MemoryPercent)"
                $cpuStr = "$($stats.CpuPercent)%"
                $memStr = "$($stats.MemoryPercent)% ($($stats.MemoryUsageMB) / $($stats.MemoryLimitMB) MB)"
                $netRx = "$($stats.NetRxMB)"
                $netTx = "$($stats.NetTxMB)"
                $blkR = "$($stats.BlockReadMB)"
                $blkW = "$($stats.BlockWriteMB)"
                $pids = "$($stats.PIDs)"
            } catch {
                Write-Verbose "Stats unavailable for ${name}: $($_.Exception.Message)"
            }
        }

        # Get IP from first network
        $ipAddr = 'N/A'
        if ($c.NetworkSettings -and $c.NetworkSettings.Networks) {
            $firstNet = $c.NetworkSettings.Networks.PSObject.Properties | Select-Object -First 1
            if ($firstNet -and $firstNet.Value.IPAddress) {
                $ipAddr = "$($firstNet.Value.IPAddress)"
            }
        }

        $results += [PSCustomObject]@{
            Type           = "Container"
            Name           = $name
            Status         = $state
            IPAddress      = $ipAddr
            Image          = $image
            CPU            = $cpuStr
            Memory         = $memStr
            CpuPercent     = $cpuPct
            MemPercent     = $memPct
            NetRxMB        = $netRx
            NetTxMB        = $netTx
            BlockReadMB    = $blkR
            BlockWriteMB   = $blkW
            PIDs           = $pids
            OS             = 'N/A'
            DockerVersion  = 'N/A'
            StorageDriver  = 'N/A'
            Containers     = 'N/A'
            ImageCount     = 'N/A'
            Ports          = $portsStr
            Uptime         = $uptime
        }
    }

    return $results
}

function Export-DockerDashboardHtml {
    <#
    .SYNOPSIS
        Renders Docker dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-DockerDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-DockerDashboard.
    .PARAMETER OutputPath
        File path for the output HTML file.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Docker Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        Docker-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-DockerDashboard -Connection $conn
        Export-DockerDashboardHtml -DashboardData $data -OutputPath "C:\Reports\docker.html"
    .EXAMPLE
        Export-DockerDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\docker.html" -ReportTitle "Production Docker"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Docker Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Docker-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $titleMap = @{
        'Type'          = 'Type'
        'Name'          = 'Name'
        'Status'        = 'Status'
        'IPAddress'     = 'IP Address'
        'Image'         = 'Image'
        'CPU'           = 'CPU'
        'Memory'        = 'Memory'
        'CpuPercent'    = 'CPU %'
        'MemPercent'    = 'Mem %'
        'NetRxMB'       = 'Net Rx MB'
        'NetTxMB'       = 'Net Tx MB'
        'BlockReadMB'   = 'Blk Read MB'
        'BlockWriteMB'  = 'Blk Write MB'
        'PIDs'          = 'PIDs'
        'OS'            = 'OS'
        'DockerVersion' = 'Docker Version'
        'StorageDriver' = 'Storage Driver'
        'Containers'    = 'Containers'
        'ImageCount'    = 'Images'
        'Ports'         = 'Ports'
        'Uptime'        = 'Uptime'
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $title = if ($titleMap.ContainsKey($prop.Name)) { $titleMap[$prop.Name] } else { ($prop.Name -creplace '([A-Z])', ' $1').Trim() }
        $col = @{
            field      = $prop.Name
            title      = $title
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'Status') { $col.formatter = 'formatStatus' }
        if ($prop.Name -eq 'Type')   { $col.formatter = 'formatType' }
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
    Write-Verbose "Docker Dashboard HTML written to $OutputPath"
}
