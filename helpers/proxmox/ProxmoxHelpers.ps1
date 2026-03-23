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

function Invoke-ProxmoxAPI {
    param(
        [string]$Uri,
        [string]$Cookie,
        [string]$Method = 'Get',
        [hashtable]$Body
    )
    $params = @{ Uri = $Uri; Method = $Method }
    if ($Body) { $params.Body = $Body }
    if ($PSVersionTable.PSEdition -eq 'Core') {
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
        Authenticates to a Proxmox VE server and returns an auth cookie.
    .DESCRIPTION
        Posts credentials to the Proxmox API ticket endpoint and returns
        a PVEAuthCookie string for use in subsequent API calls.
    .PARAMETER Server
        The base URI of the Proxmox VE server (e.g. https://192.168.1.100:8006).
    .PARAMETER Username
        The Proxmox username (e.g. root@pam).
    .PARAMETER Password
        The password for authentication.
    .EXAMPLE
        $cookie = Connect-ProxmoxServer -Server "https://192.168.1.100:8006" -Username "root@pam" -Password "MyPassword"
        Authenticates and returns the PVEAuthCookie for subsequent API calls.
    .EXAMPLE
        $cookie = Connect-ProxmoxServer -Server "https://pve.lab.local:8006" -Username "admin@pve" -Password $pass
        Connects to Proxmox using a stored password variable.
    #>
    param(
        [string]$Server,
        [string]$Username,
        [string]$Password
    )

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
    .EXAMPLE
        $nodes = Get-ProxmoxNodes -Server "https://192.168.1.100:8006" -Cookie $cookie
        Returns all nodes in the Proxmox cluster.
    .EXAMPLE
        Get-ProxmoxNodes -Server $server -Cookie $cookie | ForEach-Object { $_.node }
        Lists all node names in the cluster.
    #>
    param(
        [string]$Server,
        [string]$Cookie
    )

    (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes" -Cookie $Cookie).data
}

function Get-ProxmoxVMs {
    <#
    .SYNOPSIS
        Returns all QEMU VMs on a specific Proxmox node.
    .PARAMETER Server
        The base URI of the Proxmox VE server.
    .PARAMETER Cookie
        The PVEAuthCookie from Connect-ProxmoxServer.
    .PARAMETER Node
        The name of the Proxmox node.
    .EXAMPLE
        $vms = Get-ProxmoxVMs -Server "https://192.168.1.100:8006" -Cookie $cookie -Node "pve1"
        Returns all VMs on the pve1 node.
    .EXAMPLE
        Get-ProxmoxVMs -Server $server -Cookie $cookie -Node "pve1" | Where-Object { $_.status -eq "running" }
        Returns only running VMs on the node.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$Node
    )

    (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu" -Cookie $Cookie).data
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
    .PARAMETER Node
        The name of the Proxmox node.
    .EXAMPLE
        Get-ProxmoxNodeDetail -Server "https://192.168.1.100:8006" -Cookie $cookie -Node "pve1"
        Returns CPU, memory, disk, and version details for the pve1 node.
    .EXAMPLE
        Get-ProxmoxNodes -Server $server -Cookie $cookie | ForEach-Object { Get-ProxmoxNodeDetail -Server $server -Cookie $cookie -Node $_.node }
        Returns detailed information for every node in the cluster.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$Node
    )

    $status = (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/status" -Cookie $Cookie).data

    # Get the node's IP from its network interfaces
    try {
        $network = (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/network" -Cookie $Cookie).data
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
        $version = (Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/version" -Cookie $Cookie).data
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
    .PARAMETER Node
        The name of the Proxmox node hosting the VM.
    .PARAMETER VMID
        The numeric VM ID.
    .EXAMPLE
        Get-ProxmoxVMDetail -Server "https://192.168.1.100:8006" -Cookie $cookie -Node "pve1" -VMID 100
        Returns detailed status for VM 100 on node pve1.
    .EXAMPLE
        $vms = Get-ProxmoxVMs -Server $server -Cookie $cookie -Node "pve1"
        $vms | ForEach-Object { Get-ProxmoxVMDetail -Server $server -Cookie $cookie -Node "pve1" -VMID $_.vmid }
        Returns detailed information for every VM on the node.
    #>
    param(
        [string]$Server,
        [string]$Cookie,
        [string]$Node,
        [int]$VMID
    )

    $config = Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu/$VMID/config" -Cookie $Cookie
    $status = Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu/$VMID/status/current" -Cookie $Cookie

    # Try to get IP via guest agent
    try {
        $netInfo = Invoke-ProxmoxAPI -Uri "$Server/api2/json/nodes/$Node/qemu/$VMID/agent/network-get-interfaces" `
            -Cookie $Cookie

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
        [Parameter(Mandatory)][string]$Cookie
    )

    $nodes = Get-ProxmoxNodes -Server $Server -Cookie $Cookie
    $results = @()

    foreach ($node in $nodes) {
        $nodeName = $node.node
        $nodeDetail = Get-ProxmoxNodeDetail -Server $Server -Cookie $Cookie -Node $nodeName

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

        $vms = Get-ProxmoxVMs -Server $Server -Cookie $Cookie -Node $nodeName

        foreach ($vm in $vms) {
            $vmDetail = Get-ProxmoxVMDetail -Server $Server -Cookie $Cookie -Node $nodeName -VMID $vm.vmid

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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCE31QFkk1sT3Ai
# IHnGFQUc7hr3BziBv/V0dkSWoUzgB6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgkpuNGG4BD1qIRPLalgrHOPRwhQWeSn5Y
# TcRcJt7kQzYwDQYJKoZIhvcNAQEBBQAEggIAJbbZCArB0KIPKFfKHT+5/gnkCrPw
# 5W1rTP0yZmOwryp3s780RAlSWVrenWDH2Flg50x2Y+xlkv00Daa639BuZ0q4pD6o
# GIa+2zotrTk5RkTBW1ZDsdsF+dJuXq1/Vd2sTbnHOSucd89+haHUdWUeDTFqrEpe
# FiFnKdAF5YcsSuUshHhApsSTEIEo+nNW9lOhqz+BOdSsjr9WHhD9mRkrqTithwn9
# 8lmEFipEEGAnTVcVeHlm5tBvzWeR9FJX6qSshbPqa1x+dUscXi6y1RSHzBwHJwe/
# AtaiLDqG5R89M9USsTw8UsP8KmrEZE0JWdt0wNKy+/r2gURRzbBWK6Dl7KOBrxeA
# J/3aJYuu69/If24+DWL7obvE8qQmbmia+suUukuASd1iHvKuozr0U+udRj7/7xzF
# suK9tk4OnFlhqaWw0vb6UW1uAcvYshFnNLQk2TjZVNKwB6Qmi4nlAMVE3ZpIY8GU
# 1ar3PIgUUfR9BcXzQYaUroWHq9dy6gQ5IvTirLbIhaxq3ZU9ypwJ8nLXpBXIQF2s
# cJmu9XfRpCW7r9Z/B5Z1N3i2gOlR34vcyB80PwD6p0Uj7hwPSjsFlCUWHDWoRLbK
# 08QDRJNEZhC4hZSrew81Xef20pKcC5m5jnIQfjqQyPZwRUBU06zz1/iM4glX7Ace
# rjnSVyJdV0F7yj8=
# SIG # End signature block
