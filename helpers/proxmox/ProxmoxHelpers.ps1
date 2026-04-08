function Initialize-SSLBypass {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
        $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
    }
    else {
        # Compiled callback -- avoids scriptblock delegate marshaling failures
        # under rapid sequential requests in PS 5.1
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
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
    }
}
"@
        }
        [SSLValidator]::OverrideValidation()
    }
    Write-Warning "Ignoring SSL certificate validation errors. Use this option with caution."
}

function Invoke-ProxmoxAPI {
    param(
        [string]$Uri,
        [string]$Cookie,
        [string]$ApiToken,
        [string]$Method = 'Get',
        [hashtable]$Body
    )
    $params = @{ Uri = $Uri; Method = $Method }
    if ($Body) { $params.Body = $Body }

    if ($ApiToken) {
        $authValue = "PVEAPIToken=$ApiToken"
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $params.Headers = @{ Authorization = $authValue }
            $params.SkipHeaderValidation = $true
        } else {
            # PS 5.1: WebHeaderCollection rejects the token format via -Headers;
            # use a WebSession and inject the header directly
            $parsed = [System.Uri]$Uri
            $hostKey = $parsed.Host
            $tokenKey = "token:$hostKey"
            if (-not $script:_PmxSessions) { $script:_PmxSessions = @{} }
            if (-not $script:_PmxSessions[$tokenKey]) {
                $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                $script:_PmxSessions[$tokenKey] = $session
            }
            $script:_PmxSessions[$tokenKey].Headers['Authorization'] = $authValue
            $params.WebSession = $script:_PmxSessions[$tokenKey]
        }
    } elseif ($PSVersionTable.PSEdition -eq 'Core') {
        $params.Headers = @{ Cookie = $Cookie }
    } else {
        # PS 5.1: Cookie is a restricted header; use a cached WebSession
        $parsed = [System.Uri]$Uri
        $hostKey = $parsed.Host
        if (-not $script:_PmxSessions) { $script:_PmxSessions = @{} }
        if (-not $script:_PmxSessions[$hostKey] -or $script:_PmxSessionCookie[$hostKey] -ne $Cookie) {
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $parts = $Cookie -split '=', 2
            $session.Cookies.Add((New-Object System.Net.Cookie($parts[0], $parts[1], '/', $hostKey)))
            if (-not $script:_PmxSessionCookie) { $script:_PmxSessionCookie = @{} }
            $script:_PmxSessions[$hostKey] = $session
            $script:_PmxSessionCookie[$hostKey] = $Cookie
        }
        $params.WebSession = $script:_PmxSessions[$hostKey]
    }
    $maxRetries = if ($PSVersionTable.PSEdition -eq 'Core') { 0 } else { 2 }
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        try {
            return (Invoke-RestMethod @params)
        } catch {
            $isClosed = $_.Exception.Message -match 'underlying connection was closed|unexpected error occurred on a send'
            if ($isClosed -and $attempt -lt $maxRetries) {
                # Reset the connection pool for this endpoint and retry
                try {
                    $sp = [System.Net.ServicePointManager]::FindServicePoint([System.Uri]$Uri)
                    $sp.CloseConnectionGroup('')
                } catch {}
                Start-Sleep -Milliseconds (300 * ($attempt + 1))
            } else {
                throw
            }
        }
    }
}

function Connect-ProxmoxServer {
    <#
    .SYNOPSIS
        Authenticates to a Proxmox VE server and returns an auth cookie or validates an API token.
    .DESCRIPTION
        Supports two authentication methods:
        1. Username + Password: Posts credentials to the Proxmox API ticket endpoint and returns
           a PVEAuthCookie string for use in subsequent API calls.
        2. API Token: Validates the token by calling /api2/json/version and returns the token
           string for use in subsequent API calls via the Authorization header.
    .PARAMETER Server
        The base URI of the Proxmox VE server (e.g. https://192.168.1.100:8006).
    .PARAMETER Username
        The Proxmox username (e.g. root@pam). Used with Password auth.
    .PARAMETER Password
        The password for authentication. Used with Username.
    .PARAMETER ApiToken
        A Proxmox API token in the format user@realm!tokenid=uuid-secret.
    .EXAMPLE
        $cookie = Connect-ProxmoxServer -Server "https://192.168.1.100:8006" -Username "root@pam" -Password "MyPassword"
        Authenticates with username/password and returns the PVEAuthCookie.
    .EXAMPLE
        $token = Connect-ProxmoxServer -Server "https://192.168.1.100:8006" -ApiToken "root@pam!mytoken=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        Validates the API token and returns the token string for subsequent calls.
    #>
    param(
        [string]$Server,
        [string]$Username,
        [string]$Password,
        [string]$ApiToken
    )

    if ($ApiToken) {
        # Validate the API token by calling the version endpoint
        $versionUri = "$Server/api2/json/version"
        $authValue = "PVEAPIToken=$ApiToken"
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $version = Invoke-RestMethod -Method Get -Uri $versionUri -Headers @{ Authorization = $authValue } -SkipHeaderValidation -ErrorAction Stop
        } else {
            # PS 5.1: WebHeaderCollection rejects the token format; use HttpWebRequest directly
            $req = [System.Net.HttpWebRequest]::Create($versionUri)
            $req.Method = 'GET'
            $req.Headers.Add('Authorization', $authValue)
            try {
                $resp = $req.GetResponse()
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $json = $reader.ReadToEnd()
                $reader.Close(); $resp.Close()
                $version = $json | ConvertFrom-Json
            } catch {
                throw "API token authentication failed: $($_.Exception.Message)"
            }
        }
        if (-not $version.data.version) {
            throw "API token authentication failed: no version data returned."
        }
        return $ApiToken
    }

    $login = Invoke-RestMethod -Method Post -Uri "$Server/api2/json/access/ticket" -Body @{
        username = $Username
        password = $Password
    }

    if (-not $login.data.ticket) {
        throw "Authentication failed: no ticket returned."
    }

    return "PVEAuthCookie=$($login.data.ticket)"
}

function Get-ProxmoxNodes {
    <#
    .SYNOPSIS
        Returns all nodes in the Proxmox cluster.
    .PARAMETER Server
        The base URI of the Proxmox VE server.
    .PARAMETER Cookie
        The PVEAuthCookie from Connect-ProxmoxServer.
    .PARAMETER ApiToken
        A Proxmox API token string (user@realm!tokenid=secret). Used instead of Cookie.
    .EXAMPLE
        $nodes = Get-ProxmoxNodes -Server "https://192.168.1.100:8006" -Cookie $cookie
        Returns all nodes in the Proxmox cluster.
    .EXAMPLE
        $nodes = Get-ProxmoxNodes -Server "https://pve:8006" -ApiToken $token
        Returns all nodes using API token authentication.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$ApiToken
    )

    (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes" -Cookie $Cookie -ApiToken $ApiToken).data
}

function Get-ProxmoxVMs {
    <#
    .SYNOPSIS
        Returns all QEMU VMs on a specific Proxmox node.
    .PARAMETER Server
        The base URI of the Proxmox VE server.
    .PARAMETER Cookie
        The PVEAuthCookie from Connect-ProxmoxServer.
    .PARAMETER ApiToken
        A Proxmox API token string (user@realm!tokenid=secret). Used instead of Cookie.
    .PARAMETER Node
        The name of the Proxmox node.
    .EXAMPLE
        $vms = Get-ProxmoxVMs -Server "https://192.168.1.100:8006" -Cookie $cookie -Node "pve1"
        Returns all VMs on the pve1 node.
    .EXAMPLE
        $vms = Get-ProxmoxVMs -Server "https://pve:8006" -ApiToken $token -Node "pve1"
        Returns all VMs using API token authentication.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$Node,
        [string]$ApiToken
    )

    (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu" -Cookie $Cookie -ApiToken $ApiToken).data
}

function Get-ProxmoxNodeDetail {
    <#
    .SYNOPSIS
        Returns detailed status information for a Proxmox node.
    .DESCRIPTION
        Retrieves node status, network configuration, and version information
        including CPU, memory, swap, disk, and load averages.
    .PARAMETER Server
        The base URI of the Proxmox VE server.
    .PARAMETER Cookie
        The PVEAuthCookie from Connect-ProxmoxServer.
    .PARAMETER ApiToken
        A Proxmox API token string (user@realm!tokenid=secret). Used instead of Cookie.
    .PARAMETER Node
        The name of the Proxmox node.
    .EXAMPLE
        Get-ProxmoxNodeDetail -Server "https://192.168.1.100:8006" -Cookie $cookie -Node "pve1"
        Returns CPU, memory, disk, and version details for the pve1 node.
    .EXAMPLE
        Get-ProxmoxNodeDetail -Server "https://pve:8006" -ApiToken $token -Node "pve1"
        Returns node details using API token authentication.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$Node,
        [string]$ApiToken
    )

    $status = (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/status" -Cookie $Cookie -ApiToken $ApiToken).data

    # Get the node's IP from its network interfaces
    try {
        $network = (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/network" -Cookie $Cookie -ApiToken $ApiToken).data
        $ip = ($network | Where-Object {
            $_.address -and $_.type -eq 'bridge' -or $_.type -eq 'eth'
        } | Select-Object -First 1).address

        if (-not $ip) {
            $ip = ($network | Where-Object { $_.address } | Select-Object -First 1).address
        }
        if (-not $ip) { $ip = "N/A" }
    }
    catch {
        $ip = "N/A"
    }

    # Get Proxmox version info
    try {
        $version = (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/version" -Cookie $Cookie -ApiToken $ApiToken).data
    }
    catch {
        $version = $null
    }

    [PSCustomObject]@{
        Type          = "Host"
        NodeName      = $Node
        NodeID        = if ($status.'boot-info'.uuid) { "$($status.'boot-info'.uuid)" } else { "N/A" }
        IPAddress     = $ip
        Status        = if ($status.uptime -gt 0) { "running" } else { "offline" }
        Uptime        = "$($status.uptime)"
        PVEVersion    = if ($version) { "$($version.version)-$($version.release)" } else { "N/A" }
        KernelVersion = if ($status.kversion) { "$($status.kversion)" } else { "N/A" }
        CPUModel      = if ($status.cpuinfo.model) { "$($status.cpuinfo.model)" } else { "N/A" }
        CPUSockets    = "$($status.cpuinfo.sockets)"
        CPUCores      = "$($status.cpuinfo.cores)"
        CPUThreads    = "$($status.cpuinfo.cpus)"
        CPUPercent    = "{0:N1}%" -f ($status.cpu * 100)
        RAM_Used      = "$([math]::Round($status.memory.used / 1MB)) MB"
        RAM_Total     = "$([math]::Round($status.memory.total / 1MB)) MB"
        RAM_Free      = "$([math]::Round($status.memory.free / 1MB)) MB"
        Swap_Used     = "$([math]::Round($status.swap.used / 1MB)) MB"
        Swap_Total    = "$([math]::Round($status.swap.total / 1MB)) MB"
        RootFS_Used   = "$([math]::Round($status.rootfs.used / 1GB)) GB"
        RootFS_Total  = "$([math]::Round($status.rootfs.total / 1GB)) GB"
        RootFS_Free   = "$([math]::Round($status.rootfs.free / 1GB)) GB"
        LoadAvg1      = "$($status.loadavg[0])"
        LoadAvg5      = "$($status.loadavg[1])"
        LoadAvg15     = "$($status.loadavg[2])"
    }
}

function Get-ProxmoxVMDetail {
    <#
    .SYNOPSIS
        Returns detailed status and configuration for a specific Proxmox VM.
    .DESCRIPTION
        Retrieves VM configuration and live status including CPU, memory, disk,
        network I/O, and attempts to get the IP address via the QEMU guest agent.
    .PARAMETER Server
        The base URI of the Proxmox VE server.
    .PARAMETER Cookie
        The PVEAuthCookie from Connect-ProxmoxServer.
    .PARAMETER ApiToken
        A Proxmox API token string (user@realm!tokenid=secret). Used instead of Cookie.
    .PARAMETER Node
        The name of the Proxmox node hosting the VM.
    .PARAMETER VMID
        The numeric VM ID.
    .EXAMPLE
        Get-ProxmoxVMDetail -Server "https://192.168.1.100:8006" -Cookie $cookie -Node "pve1" -VMID 100
        Returns detailed status for VM 100 on node pve1.
    .EXAMPLE
        Get-ProxmoxVMDetail -Server "https://pve:8006" -ApiToken $token -Node "pve1" -VMID 100
        Returns VM details using API token authentication.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$Node,
        [int]$VMID,
        [string]$ApiToken
    )

    $config = Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu/$VMID/config" -Cookie $Cookie -ApiToken $ApiToken
    $status = Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu/$VMID/status/current" -Cookie $Cookie -ApiToken $ApiToken

    # Try to get IP via guest agent
    try {
        $netInfo = Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu/$VMID/agent/network-get-interfaces" `
            -Cookie $Cookie -ApiToken $ApiToken

        $ip = $netInfo.data.result |
            ForEach-Object {
                $_.'ip-addresses' |
                Where-Object {
                    $_.'ip-address' -and
                    $_.'ip-address' -notlike '127.*' -and
                    $_.'ip-address-type' -eq 'ipv4'
                }
            } |
            Select-Object -ExpandProperty 'ip-address' -First 1

        if (-not $ip) { $ip = "N/A" }
    }
    catch {
        $ip = "N/A"
    }

    [PSCustomObject]@{
        VMID       = "$VMID"
        Name       = if ($config.data.name) { "$($config.data.name)" } else { "N/A" }
        Node       = $Node
        Status     = if ($status.data.status) { "$($status.data.status)" } else { "N/A" }
        QMPStatus  = if ($status.data.qmpstatus) { "$($status.data.qmpstatus)" } else { "N/A" }
        IPAddress  = $ip
        Uptime     = "$($status.data.uptime)"
        CPUPercent = "{0:N1}%" -f ($status.data.cpu * 100)
        CPUs       = "$($status.data.cpus)"
        CPUSockets = if ($config.data.sockets) { "$($config.data.sockets)" } else { "1" }
        CPUCores   = if ($config.data.cores) { "$($config.data.cores)" } else { "$($status.data.cpus)" }
        RAM_Used   = "$([math]::Round($status.data.mem / 1MB)) MB"
        RAM_Total  = "$([math]::Round($status.data.maxmem / 1MB)) MB"
        Disk_Used  = "$([math]::Round($status.data.disk / 1MB)) MB"
        Disk_Total = "$([math]::Round($status.data.maxdisk / 1MB)) MB"
        Disk_Read  = "$([math]::Round($status.data.diskread / 1MB)) MB"
        Disk_Write = "$([math]::Round($status.data.diskwrite / 1MB)) MB"
        NetIn_KB   = "$([math]::Round($status.data.netin / 1KB)) KB"
        NetOut_KB  = "$([math]::Round($status.data.netout / 1KB)) KB"
        Tags       = if ($status.data.tags) { "$($status.data.tags)" } else { "N/A" }
        HAGroup    = if ($status.data.ha.group) { "$($status.data.ha.group)" } else { "N/A" }
        HAState    = if ($status.data.ha.state) { "$($status.data.ha.state)" } else { "N/A" }
        HAManaged  = if ($status.data.ha.managed) { "$($status.data.ha.managed)" } else { "N/A" }
    }
}

function Get-ProxmoxDashboard {
    <#
    .SYNOPSIS
        Builds a flat dashboard view combining Proxmox nodes and their VMs.
    .DESCRIPTION
        Queries the Proxmox VE API for node list, node details, and VM details,
        then returns a unified collection of objects suitable for an interactive
        Bootstrap Table dashboard. Each row represents a VM enriched with its
        parent node context including CPU, RAM, PVE version, and HA state.
    .PARAMETER Server
        The base URI of the Proxmox VE server (e.g. https://pve:8006).
    .PARAMETER Cookie
        The PVEAuthCookie string obtained from Connect-ProxmoxServer.
    .PARAMETER ApiToken
        A Proxmox API token string (user@realm!tokenid=secret). Used instead of Cookie.
    .EXAMPLE
        $cookie = Connect-ProxmoxServer -Server "https://pve:8006" -Username "root@pam" -Password "pass"
        Get-ProxmoxDashboard -Server "https://pve:8006" -Cookie $cookie

        Returns a flat dashboard view of all VMs across the specified Proxmox node.
    .EXAMPLE
        $data = Get-ProxmoxDashboard -Server $server -Cookie $cookie
        $data | Where-Object { $_.Status -eq "running" }

        Retrieves the dashboard and filters for running VMs.
    .EXAMPLE
        $cookie = Connect-ProxmoxServer -Server "https://pve:8006" -Username "root@pam" -Password $pass
        $data = Get-ProxmoxDashboard -Server "https://pve:8006" -Cookie $cookie
        Export-ProxmoxDashboardHtml -DashboardData $data -OutputPath "C:\Reports\proxmox.html"
        Start-Process "C:\Reports\proxmox.html"

        End-to-end: authenticate, gather data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains: Type (Host or VM), Name, Status, IPAddress, Node,
        CPU (combined percent + core/vCPU count), RAM (used / total),
        Disk (used / total for hosts, total size for VMs),
        NetworkIn, NetworkOut, Uptime, Tags, HAState.
        Nodes appear as Type="Host" rows; VMs appear as Type="VM (VMID)" rows.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, network access to Proxmox VE API (port 8006).
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$Cookie,
        [string]$ApiToken
    )

    $nodes = Get-ProxmoxNodes -Server $Server -Cookie $Cookie -ApiToken $ApiToken
    $results = @()

    foreach ($node in $nodes) {
        $nodeName = $node.node
        $nodeDetail = Get-ProxmoxNodeDetail -Server $Server -Cookie $Cookie -ApiToken $ApiToken -Node $nodeName

        # Add the node itself as a row
        $nodeRamUsed  = [double]($nodeDetail.RAM_Used -replace '[^\d.]')
        $nodeRamTotal = [double]($nodeDetail.RAM_Total -replace '[^\d.]')
        $nodeRamPct   = if ($nodeRamTotal -gt 0) { '{0:N1}%' -f ($nodeRamUsed / $nodeRamTotal * 100) } else { '0.0%' }
        $results += [PSCustomObject]@{
            Type       = "Host"
            Name       = $nodeName
            Status     = $nodeDetail.Status
            IPAddress  = $nodeDetail.IPAddress
            Node       = $nodeName
            CPU        = "$($nodeDetail.CPUPercent) ($($nodeDetail.CPUSockets)s/$($nodeDetail.CPUCores)c/$($nodeDetail.CPUThreads)t)"
            RAM        = "$nodeRamPct ($($nodeDetail.RAM_Used) / $($nodeDetail.RAM_Total))"
            Disk       = "$($nodeDetail.RootFS_Used) / $($nodeDetail.RootFS_Total)"
            NetworkIn  = "N/A"
            NetworkOut = "N/A"
            Uptime     = $nodeDetail.Uptime
            Tags       = "N/A"
            HAState    = "N/A"
        }

        $vms = Get-ProxmoxVMs -Server $Server -Cookie $Cookie -ApiToken $ApiToken -Node $nodeName

        foreach ($vm in $vms) {
            $vmDetail = Get-ProxmoxVMDetail -Server $Server -Cookie $Cookie -ApiToken $ApiToken -Node $nodeName -VMID $vm.vmid

            $vmRamUsed  = [double]($vmDetail.RAM_Used -replace '[^\d.]')
            $vmRamTotal = [double]($vmDetail.RAM_Total -replace '[^\d.]')
            $vmRamPct   = if ($vmRamTotal -gt 0) { '{0:N1}%' -f ($vmRamUsed / $vmRamTotal * 100) } else { '0.0%' }
            $results += [PSCustomObject]@{
                Type       = "VM ($($vmDetail.VMID))"
                Name       = $vmDetail.Name
                Status     = $vmDetail.Status
                IPAddress  = $vmDetail.IPAddress
                Node       = $nodeName
                CPU        = "$($vmDetail.CPUPercent) ($($vmDetail.CPUSockets)s/$($vmDetail.CPUCores)c)"
                RAM        = "$vmRamPct ($($vmDetail.RAM_Used) / $($vmDetail.RAM_Total))"
                Disk       = $vmDetail.Disk_Total
                NetworkIn  = "$($vmDetail.NetIn_KB)"
                NetworkOut = "$($vmDetail.NetOut_KB)"
                Uptime     = $vmDetail.Uptime
                Tags       = $vmDetail.Tags
                HAState    = $vmDetail.HAState
            }
        }
    }

    return $results
}

function Export-ProxmoxDashboardHtml {
    <#
    .SYNOPSIS
        Renders Proxmox dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-ProxmoxDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-ProxmoxDashboard containing VM and node details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Proxmox Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        Proxmox-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-ProxmoxDashboard -Server $server -Cookie $cookie
        Export-ProxmoxDashboardHtml -DashboardData $data -OutputPath "C:\Reports\proxmox.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-ProxmoxDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\proxmox.html" -ReportTitle "Lab Proxmox"

        Exports with a custom report title.
    .EXAMPLE
        $cookie = Connect-ProxmoxServer -Server $server -Username "root@pam" -Password $pass
        $data = Get-ProxmoxDashboard -Server $server -Cookie $cookie
        Export-ProxmoxDashboardHtml -DashboardData $data -OutputPath "C:\Reports\proxmox.html"
        Start-Process "C:\Reports\proxmox.html"

        Full pipeline: authenticate, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Proxmox-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Proxmox Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Proxmox-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $titleMap = @{
        'Type'       = 'Type'
        'Name'       = 'Name'
        'Status'     = 'Status'
        'IPAddress'  = 'IP Address'
        'Node'       = 'Node'
        'CPU'        = 'CPU'
        'RAM'        = 'RAM'
        'Disk'       = 'Disk'
        'NetworkIn'  = 'Network In'
        'NetworkOut' = 'Network Out'
        'Uptime'     = 'Uptime'
        'Tags'       = 'Tags'
        'HAState'    = 'HA State'
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $title = if ($titleMap.ContainsKey($prop.Name)) { $titleMap[$prop.Name] } else { ($prop.Name -creplace '(?<=[a-z])([A-Z])', ' $1').Trim() }
        $col = @{
            field      = $prop.Name
            title      = $title
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'Status') {
            $col.formatter = 'formatStatus'
        }
        if ($prop.Name -eq 'Type') {
            $col.formatter = 'formatType'
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = $DashboardData | ConvertTo-Json -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Proxmox Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDagSZ/CArUAWrc
# 4zZ2EW9rY0RBEH76UnElE0Uj0izWIqCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCW+0e3
# 8USEFCHCO4ey86raytjTtJxSEG6BPEIbLPj7pDANBgkqhkiG9w0BAQEFAASCAgAR
# B5Ugj5E6ZnhLSlcoyP63O6L2CjLeIie8NEodOz3KHUp7On6TBSZRGzyjP7x9QRpQ
# 6DQ2tHoeESocT/RnUSZqLDPULC9VzBIMYqGY+3tyWyMwtSyscRDbdkAHhMFu9kn2
# IokCcbExQBsQs/2cHtGqK87mCeHOOOv+tr1Kyvkgoxqa1XWcIrezcTJYSDCVMv15
# f03tdTDKkXujHPyKjhytVlhfsVpD9KKKD1kloJI6QHrMcta0aeS5VmyqSvZqti4l
# 1Rtb2K/1fsebyoHRPDntuM5sPEWn0i4q1pq6oswxyFXhobd6Unb3mTDNLSQ9uE6h
# YxXaj/rIv1su4DiVUOxkcPwH/pAaPFlJPmZE5BKid6Z/wi4MfokidSeh0cZBvNPM
# 6M3pNqMQfHVGLVE3Es2ZAmi3byxOE93eE/xqZUd2MJ1tbZqT7Qcg1bJ7H4UEoLQc
# GP+jX0HA2XKiDc7rmHqYPsMdEz/JW3acHs1rH2IPJqVLYwMB1BN4K7o3jizsi+BR
# qDaCbsvr04tVy2x7lxeP7DmmA+oMfrJWIDrZWpqmVtx4Jo+2H6a/iOWoQVNiqWDR
# wM2hEXfQvCs8erXdZmNz7FiTvfMh9LcDBL2/Wlgzuqafmoij623aTP5zB9WBrP1H
# vp+Zfr0ya7K9tb3U47ywqAR6GHcaPIkfzjgHegnzK6GCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwODAxMzYy
# OFowPwYJKoZIhvcNAQkEMTIEML1k4+AKhHPM1ZUY0dXDM66R7m/MuBWWxwqZ5psj
# 4IUsoPeUNPlbquBNtmbPvGnZtTANBgkqhkiG9w0BAQEFAASCAgBHXfsoCM8OLjMb
# cT9HuJ3vlUCr/mvBsOS8m5W2BgZaSNBpqwvZd/oc1VGUdEqodXfbigXvB94SGtns
# kKSEyYH9oJgaUuLc9y1EnX4lFo8GNsbVQ14BykRMQO/CqN1CvRyrE9dc82CkaAGM
# tM426k3nSY8QtKlLrukYqAW3+7wpFLgbI1FMooyDnly9Xpnm/xI/Twn5MVhVXJj3
# E3uz8rvhQhDZuyW9qJwMC0HNXSHyO4pAKice7Cbh3J4tkNUIiCVHHLBFhbqwKbDm
# baPl1InyldRkZKKVINNwaRifKx1ZPxqDApZdJSCKK5Px2yzfJJB22HJKJitvipDV
# w3Bvxm/sYuqb7d5n9TlUulPVLhsp7NVV2FdkmOr2Pu/USB3/HEoBVbgnkQ9i7ppe
# /FMrwdgDRdITSvXA8VJuYcvKz9f1/aZt0LDEoYVwF8Gx7SgiNxqlopmaQPwvOyOg
# hD5iASJpkMz7wTbYTSSKRazYf6A0Oe+z++Y4fKSp1/YX86oYXqnLR05qLlttOlDN
# 8MwkurcfmV0A4D/6qdMd8Nwh8fnMiqy/Zxi/KJ7la+nfBYYhUAB1bOQxUKrBlgtG
# LzEWIEsOSqy4AZSeMtJ8JxOcnpZGRu0BY+S9bycrNM4ILTWUGDvN8XA4sny8oQwp
# D98MY7aTR45lr0YL+lu7PVNuY/jxHA==
# SIG # End signature block
