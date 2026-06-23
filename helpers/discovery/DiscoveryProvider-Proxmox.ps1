<#
.SYNOPSIS
    Proxmox VE discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers a Proxmox discovery provider that queries the Proxmox VE
    REST API to discover cluster nodes and QEMU virtual machines, then
    builds a monitor plan. Works standalone or with WUG integration.

    Active Monitors (up/down):
      - Cluster health via /api2/json/cluster/status
      - Per-node status via /api2/json/nodes/{node}/status
      - Per-VM status via /api2/json/nodes/{node}/qemu/{vmid}/status/current

    Performance Monitors (stats over time):
      - Node CPU utilization via /api2/json/nodes/{node}/status  ($.data.cpu)
      - Node memory utilization via node status ($.data.memory.used)
      - Node root disk usage via node status ($.data.rootfs.used)
      - Node load average via node status ($.data.loadavg[0])
      - VM CPU utilization via /api2/json/nodes/{node}/qemu/{vmid}/status/current
      - VM memory usage via VM status ($.data.mem)

    Authentication:
      Proxmox supports two auth methods:
      1. API Tokens (PVE 6.1+) - header based: Authorization: PVEAPIToken=user@realm!tokenid=uuid
      2. Username + Password - POST /api2/json/access/ticket to get a session ticket

      For WUG REST API monitors, API tokens are required (passed via the
      RestApiCustomHeader field using %Credential.Password%). Session
      tickets are short-lived and cannot be used for ongoing monitoring.

      For standalone discovery, both methods work. Username+password auth
      obtains a ticket for the live API calls during discovery only.

    Prerequisites:
      1. Proxmox VE 6.1+ (for API token support)
      2. API token created: Datacenter -> Permissions -> API Tokens
         OR username + password with API access
      3. Token/user must have Audit/read or Administrator role on /
      4. Device attribute 'DiscoveryHelper.Proxmox' = 'true'
      5. For WUG mode: REST API credential assigned (token as password)

    How to create a Proxmox API Token:
      1. Proxmox GUI -> Datacenter -> Permissions -> API Tokens -> Add
      2. Select user (e.g. root@pam or a dedicated monitoring user)
      3. Set Token ID (e.g. 'monitoring')
      4. UNCHECK 'Privilege Separation' for full user permissions
         OR create a dedicated PVEAuditor role token for read-only
      5. Copy the token value (shown only once): xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      6. The full token string for auth is: user@realm!tokenid=secret-uuid

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM

    Proxmox API Token Security:
    - Tokens inherit the user's permissions unless Privilege Separation is on.
    - Use a dedicated monitoring user with PVEAuditor role for least privilege.
    - Tokens do not expire unless deleted. Rotate periodically.
    - The token is stored in the DPAPI vault (encrypted) for discovery.
    - In WUG, the token is stored in the credential store (not in device
      attributes or monitor params). Monitors reference %Credential.Password%.
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

# ============================================================================
# Proxmox Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Proxmox' `
    -MatchAttribute 'DiscoveryHelper.Proxmox' `
    -AuthType 'BearerToken' `
    -DefaultPort 8006 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        # Ensure TLS 1.2 for Proxmox API (PS 5.1 defaults to TLS 1.0)
        if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }

        # Compiled SSL bypass for PS 5.1 — scriptblock delegates get GC'd,
        # causing intermittent "connection was closed unexpectedly" errors.
        if ($PSVersionTable.PSEdition -ne 'Core') {
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
        }

        $items = @()
        $baseUri    = $ctx.BaseUri
        $deviceIP   = $ctx.DeviceIP
        $ignoreCert = if ($ctx.IgnoreCertErrors) { '1' } else { '0' }
        $attrValue  = $ctx.AttributeValue

        # --- Resolve live API credential ---
        # Supports two modes:
        #   1. API Token: passed via $ctx.Credential.ApiToken (preferred)
        #   2. Username + Password: passed via $ctx.Credential (Username/Password keys)
        #      Obtains a session ticket via POST /access/ticket for live calls
        # Legacy: AttributeValue is still checked for backward compatibility
        #   but tokens should be passed via -Credential, not -AttributeValue.
        $tokenValue = $null
        $ticketCookie = $null
        $csrfToken = $null

        if ($ctx.Credential -and $ctx.Credential.ApiToken) {
            $tokenValue = $ctx.Credential.ApiToken
        }
        elseif ($attrValue -and $attrValue -ne 'true' -and $attrValue.Length -gt 10) {
            # Legacy: token passed via AttributeValue (backward compat)
            $tokenValue = $attrValue
        }
        elseif ($ctx.Credential -and $ctx.Credential.Username -and $ctx.Credential.Password) {
            # Username + Password mode: get a session ticket for live calls
            Write-Verbose "Authenticating to Proxmox with username+password..."
            try {
                $ticketUri = "${baseUri}/api2/json/access/ticket"
                $ticketBody = "username=$([uri]::EscapeDataString($ctx.Credential.Username))&password=$([uri]::EscapeDataString($ctx.Credential.Password))"
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $ticketParams = @{
                        Uri         = $ticketUri
                        Method      = 'POST'
                        Body        = $ticketBody
                        ContentType = 'application/x-www-form-urlencoded'
                    }
                    if ($ignoreCert -eq '1') { $ticketParams.SkipCertificateCheck = $true }
                    $ticketResp = Invoke-RestMethod @ticketParams -ErrorAction Stop
                }
                else {
                    if ($ignoreCert -eq '1') {
                        [SSLValidator]::OverrideValidation()
                    }
                    $ticketResp = Invoke-RestMethod -Uri $ticketUri -Method POST -Body $ticketBody `
                        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
                }
                if ($ticketResp.data.ticket) {
                    $ticketCookie = $ticketResp.data.ticket
                    $csrfToken = $ticketResp.data.CSRFPreventionToken
                    Write-Verbose "Proxmox ticket obtained (username+password auth)"
                }
                else {
                    Write-Warning "Proxmox ticket response did not contain a ticket."
                }
            }
            catch {
                Write-Warning "Failed to authenticate to Proxmox with username+password: $_"
            }
        }

        $apiHost = $deviceIP
        $apiPort = [string]$ctx.Port

        # Base URL prefix used by the live API helper below (discovery time)
        $apiBase = "https://${apiHost}:${apiPort}/api2/json"

        # ================================================================
        # Live API helper (for discovery calls, NOT stored in monitors)
        # Handles Cookie as a restricted header on PS 5.1 via Cookies collection
        # ================================================================
        $invokeApi = {
            param([string]$Url, [string]$HdrName, [string]$HdrVal, [string]$SkipSsl)
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $p = @{
                    Uri                 = $Url
                    Method              = 'GET'
                    Headers             = @{ $HdrName = $HdrVal }
                    SkipHeaderValidation = $true
                }
                if ($SkipSsl -eq '1') { $p.SkipCertificateCheck = $true }
                Invoke-RestMethod @p -ErrorAction Stop
            }
            else {
                if ($SkipSsl -eq '1') {
                    [SSLValidator]::OverrideValidation()
                }
                if ($HdrName -eq 'Cookie') {
                    $ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                    $parsed = [System.Uri]$Url
                    $parts = $HdrVal -split '=', 2
                    $ws.Cookies.Add((New-Object System.Net.Cookie($parts[0], $parts[1], '/', $parsed.Host)))
                    Invoke-RestMethod -Uri $Url -Method GET -WebSession $ws -ErrorAction Stop
                }
                else {
                    Invoke-RestMethod -Uri $Url -Method GET -Headers @{ $HdrName = $HdrVal } -ErrorAction Stop
                }
            }
        }

        # Parse auth for live calls
        $hdrName = $null; $hdrVal = $null
        if ($tokenValue) {
            $hdrName = 'Authorization'
            $hdrVal  = "PVEAPIToken=$tokenValue"
        }
        elseif ($ticketCookie) {
            # Ticket auth: pass cookie via Cookie header for live calls
            $hdrName = 'Cookie'
            $hdrVal  = "PVEAuthCookie=$ticketCookie"
        }

        # ================================================================
        # Phase 1: Live API enumeration
        # ================================================================
        $nodeMap = @{}   # nodeName -> IP
        $vmMap   = @{}   # vmid -> @{ Name; IP; Node; Status; Cpus; MaxMem; MaxDisk; Type }
        $ctMap   = @{}   # vmid -> @{ Name; IP; Node; Status; Cpus; MaxMem; MaxDisk; Type }
        $nodeStorageMap = @{} # nodeName -> @(@{ Name; Type })
        $poolMap = @()       # @('poolid1','poolid2',...)
        $sdnObjectMap = @()  # @(@{ Collection; Key; Id })

        if ($hdrName) {
            # Node IPs from /cluster/status
            try {
                $resp = & $invokeApi "${baseUri}/api2/json/cluster/status" $hdrName $hdrVal $ignoreCert
                if ($resp.data) {
                    foreach ($e in $resp.data) {
                        if ($e.type -eq 'node' -and $e.ip) { $nodeMap[$e.name] = $e.ip }
                    }
                }
            }
            catch { Write-Warning "Could not query cluster status for node IPs: $_" }

            # Ensure all nodes are in nodeMap
            try {
                $resp = & $invokeApi "${baseUri}/api2/json/nodes" $hdrName $hdrVal $ignoreCert
                if ($resp.data) {
                    foreach ($n in $resp.data) {
                        if ($n.node -and -not $nodeMap.ContainsKey($n.node)) {
                            $nodeMap[$n.node] = $null
                        }
                    }
                }
            }
            catch { Write-Warning "Could not query node list: $_" }

            # VMs per node + guest agent IPs
            foreach ($node in @($nodeMap.Keys)) {
                $nodeStorageMap[$node] = @()

                # Storage objects per node
                try {
                    $resp = & $invokeApi "${baseUri}/api2/json/nodes/${node}/storage" $hdrName $hdrVal $ignoreCert
                    if ($resp.data) {
                        $storageList = New-Object System.Collections.ArrayList
                        foreach ($st in $resp.data) {
                            if (-not $st.storage) { continue }
                            [void]$storageList.Add(@{
                                Name = [string]$st.storage
                                Type = if ($st.type) { [string]$st.type } else { 'unknown' }
                            })
                        }
                        $nodeStorageMap[$node] = @($storageList)
                    }
                }
                catch {
                    Write-Verbose "Could not query storage list on node ${node}: $_"
                }

                try {
                    $resp = & $invokeApi "${baseUri}/api2/json/nodes/${node}/qemu" $hdrName $hdrVal $ignoreCert
                    if ($resp.data) {
                        foreach ($vm in $resp.data) {
                            if (-not $vm.vmid) { continue }
                            $vmIP = $null
                            if ($vm.status -eq 'running') {
                                try {
                                    $agentUrl = "${baseUri}/api2/json/nodes/${node}/qemu/$($vm.vmid)/agent/network-get-interfaces"
                                    $agentResp = & $invokeApi $agentUrl $hdrName $hdrVal $ignoreCert
                                    if ($agentResp.data.result) {
                                        foreach ($iface in $agentResp.data.result) {
                                            if ($iface.name -eq 'lo') { continue }
                                            if ($iface.'ip-addresses') {
                                                $v4 = $iface.'ip-addresses' | Where-Object {
                                                    $_.'ip-address-type' -eq 'ipv4'
                                                } | Select-Object -First 1
                                                if ($v4 -and $v4.'ip-address' -ne '127.0.0.1') {
                                                    $vmIP = $v4.'ip-address'
                                                    break
                                                }
                                            }
                                        }
                                    }
                                }
                                catch { <# Guest agent not available #> }
                            }
                            $vmMap[[string]$vm.vmid] = @{
                                Name    = $vm.name
                                IP      = $vmIP
                                Node    = $node
                                Status  = $vm.status
                                Cpus    = $vm.cpus
                                MaxMem  = $vm.maxmem
                                MaxDisk = $vm.maxdisk
                                Type    = 'qemu'
                            }
                        }
                    }
                }
                catch { Write-Warning "Could not query VMs on node ${node}: $_" }

                # LXC containers per node
                try {
                    $resp = & $invokeApi "${baseUri}/api2/json/nodes/${node}/lxc" $hdrName $hdrVal $ignoreCert
                    if ($resp.data) {
                        foreach ($ct in $resp.data) {
                            if (-not $ct.vmid) { continue }
                            $ctIP = $null
                            # LXC containers often expose IP in status/current or via config
                            if ($ct.status -eq 'running') {
                                try {
                                    $ctStatusUrl = "${baseUri}/api2/json/nodes/${node}/lxc/$($ct.vmid)/status/current"
                                    $ctStatusResp = & $invokeApi $ctStatusUrl $hdrName $hdrVal $ignoreCert
                                    if ($ctStatusResp.data) {
                                        # Try common network config pattern: net0 "ip=x.x.x.x/24,..."
                                        $cfgUrl = "${baseUri}/api2/json/nodes/${node}/lxc/$($ct.vmid)/config"
                                        try {
                                            $cfgResp = & $invokeApi $cfgUrl $hdrName $hdrVal $ignoreCert
                                            if ($cfgResp.data) {
                                                foreach ($prop in $cfgResp.data.PSObject.Properties) {
                                                    if ($prop.Name -match '^net\d+$' -and $prop.Value -match 'ip=([^/,]+)') {
                                                        $candidateIP = $Matches[1]
                                                        if ($candidateIP -ne '127.0.0.1' -and $candidateIP -ne '0.0.0.0') {
                                                            $ctIP = $candidateIP
                                                            break
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        catch { <# Config query not available #> }
                                    }
                                }
                                catch { <# Status query failed #> }
                            }
                            $ctMap[[string]$ct.vmid] = @{
                                Name    = $ct.name
                                IP      = $ctIP
                                Node    = $node
                                Status  = $ct.status
                                Cpus    = $ct.cpus
                                MaxMem  = $ct.maxmem
                                MaxDisk = $ct.maxdisk
                                Type    = 'lxc'
                            }
                        }
                    }
                }
                catch { Write-Warning "Could not query LXC containers on node ${node}: $_" }
            }
        }

        $storageCount = 0
        foreach ($k in $nodeStorageMap.Keys) { $storageCount += @($nodeStorageMap[$k]).Count }
        Write-Host "  Topology: $($nodeMap.Count) nodes, $($vmMap.Count) VMs, $($ctMap.Count) containers, $storageCount storage objects" -ForegroundColor DarkGray

        # ================================================================
        # Phase 2: Validate metrics return numeric data
        # ================================================================
        # Probe each node/VM/CT status endpoint and verify that the JSON
        # paths used by performance monitors extract numeric values.
        # Dropped metrics are not added to the plan. Active monitors are
        # always kept (they only check HTTP status, not numeric values).

        # Define the metric sets once (reused in Phase 3 plan building)
        $clusterPerfDefs = @(
            @{ Name = 'Proxmox - Cluster Quorate';   JsonPath = '$.data[0].quorate'; Key = 'quorate';  Field = 'data[0].quorate' }
            @{ Name = 'Proxmox - Cluster Node Count'; JsonPath = '$.data[0].nodes';   Key = 'nodecount'; Field = 'data[0].nodes' }
        )
        $nodePerfDefs = @(
            @{ Name = 'Proxmox - Node CPU';            JsonPath = '$.data.cpu';            Key = 'cpu';         Field = 'cpu' }
            @{ Name = 'Proxmox - Node CPU IO Wait';    JsonPath = '$.data.wait';           Key = 'iowait';     Field = 'wait' }
            @{ Name = 'Proxmox - Node CPU Max';        JsonPath = '$.data.cpuinfo.cpus';   Key = 'cpumax';     Field = 'cpuinfo.cpus' }
            @{ Name = 'Proxmox - Node Memory Used';    JsonPath = '$.data.memory.used';    Key = 'memused';    Field = 'memory.used' }
            @{ Name = 'Proxmox - Node Memory Free';    JsonPath = '$.data.memory.free';    Key = 'memfree';    Field = 'memory.free' }
            @{ Name = 'Proxmox - Node Memory Total';   JsonPath = '$.data.memory.total';   Key = 'memtotal';   Field = 'memory.total' }
            @{ Name = 'Proxmox - Node Swap Used';      JsonPath = '$.data.swap.used';      Key = 'swapused';   Field = 'swap.used' }
            @{ Name = 'Proxmox - Node Swap Free';      JsonPath = '$.data.swap.free';      Key = 'swapfree';   Field = 'swap.free' }
            @{ Name = 'Proxmox - Node Swap Total';     JsonPath = '$.data.swap.total';     Key = 'swaptotal';  Field = 'swap.total' }
            @{ Name = 'Proxmox - Node Disk Used';      JsonPath = '$.data.rootfs.used';    Key = 'diskused';   Field = 'rootfs.used' }
            @{ Name = 'Proxmox - Node Disk Free';      JsonPath = '$.data.rootfs.free';    Key = 'diskfree';   Field = 'rootfs.free' }
            @{ Name = 'Proxmox - Node Disk Total';     JsonPath = '$.data.rootfs.total';   Key = 'disktotal';  Field = 'rootfs.total' }
            @{ Name = 'Proxmox - Node Load Avg 1m';    JsonPath = '$.data.loadavg[0]';     Key = 'loadavg1';   Field = 'loadavg[0]' }
            @{ Name = 'Proxmox - Node Load Avg 5m';    JsonPath = '$.data.loadavg[1]';     Key = 'loadavg5';   Field = 'loadavg[1]' }
            @{ Name = 'Proxmox - Node Load Avg 15m';   JsonPath = '$.data.loadavg[2]';     Key = 'loadavg15';  Field = 'loadavg[2]' }
            @{ Name = 'Proxmox - Node Uptime';         JsonPath = '$.data.uptime';         Key = 'uptime';     Field = 'uptime' }
        )
        $guestPerfDefs = @(
            @{ Name = 'CPU';        JsonPath = '$.data.cpu';       Key = 'cpu';       Field = 'cpu' }
            @{ Name = 'CPU Max';    JsonPath = '$.data.cpus';      Key = 'cpumax';    Field = 'cpus' }
            @{ Name = 'Memory';     JsonPath = '$.data.mem';       Key = 'mem';       Field = 'mem' }
            @{ Name = 'Memory Max'; JsonPath = '$.data.maxmem';    Key = 'maxmem';    Field = 'maxmem' }
            @{ Name = 'Net In';     JsonPath = '$.data.netin';     Key = 'netin';     Field = 'netin' }
            @{ Name = 'Net Out';    JsonPath = '$.data.netout';    Key = 'netout';    Field = 'netout' }
            @{ Name = 'Disk';       JsonPath = '$.data.disk';      Key = 'disk';      Field = 'disk' }
            @{ Name = 'Disk Max';   JsonPath = '$.data.maxdisk';   Key = 'maxdisk';   Field = 'maxdisk' }
            @{ Name = 'Disk Read';  JsonPath = '$.data.diskread';  Key = 'diskread';  Field = 'diskread' }
            @{ Name = 'Disk Write'; JsonPath = '$.data.diskwrite'; Key = 'diskwrite'; Field = 'diskwrite' }
            @{ Name = 'Uptime';     JsonPath = '$.data.uptime';    Key = 'uptime';    Field = 'uptime' }
        )
        $storagePerfDefs = @(
            @{ Name = 'Active';    JsonPath = '$.data.active';  Key = 'active';   Field = 'active' }
            @{ Name = 'Enabled';   JsonPath = '$.data.enabled'; Key = 'enabled';  Field = 'enabled' }
            @{ Name = 'Available'; JsonPath = '$.data.avail';   Key = 'avail';    Field = 'avail' }
            @{ Name = 'Used';      JsonPath = '$.data.used';    Key = 'used';     Field = 'used' }
            @{ Name = 'Total';     JsonPath = '$.data.total';   Key = 'total';    Field = 'total' }
        )

        # Dynamic property navigator — resolves 'memory.free' or 'loadavg[0]' on an object
        $resolveField = {
            param($obj, [string]$fieldPath)
            $cur = $obj
            foreach ($seg in $fieldPath -split '\.') {
                if ($null -eq $cur) { return $null }
                if ($seg -match '^(.+)\[(\d+)\]$') {
                    $cur = $cur.($Matches[1])
                    if ($cur -and $cur.Count -gt [int]$Matches[2]) {
                        $cur = $cur[[int]$Matches[2]]
                    } else { return $null }
                } else {
                    $cur = $cur.$seg
                }
            }
            return $cur
        }

        # Validated metric keys per entity: nodeValidated[nodeName] = @('cpu','memused',...)
        $clusterValidated = @{}
        $nodeValidated = @{}
        $guestValidated = @{}  # validated[vmid] = @('cpu','mem',...)
        $storageValidated = @{} # validated['node/storage'] = @('active','avail',...)
        $nodeCapacity = @{}    # nodeCapacity[nodeName] = @{ MemTotal; SwapTotal; DiskTotal }
        $nodeSdnEndpointHealthy = @{} # nodeName -> bool

        $poolListEndpointHealthy = $false
        $storageListEndpointHealthy = $false
        $sdnListEndpointHealthy = $false

        if ($hdrName) {
            Write-Host "  Validating cluster metrics..." -ForegroundColor DarkGray
            try {
                $clusterResp = & $invokeApi "${baseUri}/api2/json/cluster/status" $hdrName $hdrVal $ignoreCert
                $clusterData = @($clusterResp.data)
                $clusterObj = $clusterData | Where-Object { $_.type -eq 'cluster' } | Select-Object -First 1
                if (-not $clusterObj) { $clusterObj = $clusterData | Select-Object -First 1 }

                $clusterView = @{ data = @($clusterObj) }
                $validKeys = [System.Collections.Generic.List[string]]::new()
                foreach ($pm in $clusterPerfDefs) {
                    $val = & $resolveField $clusterView $pm.Field
                    if ($null -ne $val -and ($val -is [double] -or $val -is [int] -or $val -is [long] -or $val -is [decimal] -or $val -is [float] -or $val -is [single] -or "$val" -match '^\d')) {
                        $validKeys.Add($pm.Key)
                    }
                }
                $clusterValidated['cluster'] = @($validKeys)
                Write-Host "    Cluster: $($validKeys.Count)/$($clusterPerfDefs.Count) metrics validated" -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "    Could not probe cluster status — keeping all cluster metrics: $_"
                $clusterValidated['cluster'] = @($clusterPerfDefs | ForEach-Object { $_.Key })
            }

            Write-Host "  Validating node metrics..." -ForegroundColor DarkGray
            foreach ($nodeName in @($nodeMap.Keys | Sort-Object)) {
                $nodeSdnEndpointHealthy[$nodeName] = $false
                try {
                    $resp = & $invokeApi "${baseUri}/api2/json/nodes/${nodeName}/status" $hdrName $hdrVal $ignoreCert
                    $d = $resp.data
                    $validKeys = [System.Collections.Generic.List[string]]::new()
                    foreach ($pm in $nodePerfDefs) {
                        $val = & $resolveField $d $pm.Field
                        if ($null -ne $val -and ($val -is [double] -or $val -is [int] -or $val -is [long] -or $val -is [decimal] -or $val -is [float] -or $val -is [single] -or "$val" -match '^\d')) {
                            $validKeys.Add($pm.Key)
                        }
                    }
                    $nodeValidated[$nodeName] = @($validKeys)
                    # Capture static totals for device attributes (not worth polling)
                    $nodeCapacity[$nodeName] = @{
                        MemTotal  = & $resolveField $d 'memory.total'
                        SwapTotal = & $resolveField $d 'swap.total'
                        DiskTotal = & $resolveField $d 'rootfs.total'
                    }
                    $dropped = $nodePerfDefs.Count - $validKeys.Count
                    if ($dropped -gt 0) {
                        Write-Host "    $nodeName`: $($validKeys.Count)/$($nodePerfDefs.Count) metrics validated ($dropped dropped)" -ForegroundColor DarkYellow
                    } else {
                        Write-Host "    $nodeName`: $($validKeys.Count)/$($nodePerfDefs.Count) metrics validated" -ForegroundColor DarkGray
                    }
                }
                catch {
                    Write-Warning "    Could not probe node $nodeName — keeping all metrics (benefit of the doubt): $_"
                    $nodeValidated[$nodeName] = @($nodePerfDefs | ForEach-Object { $_.Key })
                }
            }

            # Probe node-scoped SDN endpoints for per-node SDN active monitors
            foreach ($nodeName in @($nodeMap.Keys | Sort-Object)) {
                try {
                    $null = & $invokeApi "${baseUri}/api2/json/nodes/${nodeName}/sdn" $hdrName $hdrVal $ignoreCert
                    $nodeSdnEndpointHealthy[$nodeName] = $true
                }
                catch {
                    Write-Verbose "Proxmox node SDN endpoint unavailable on ${nodeName}: $_"
                }
            }

            # Probe optional list endpoints (Datadog parity-style up checks)
            try {
                $poolResp = & $invokeApi "${baseUri}/api2/json/pools" $hdrName $hdrVal $ignoreCert
                $poolListEndpointHealthy = $true
                if ($poolResp.data) {
                    foreach ($p in @($poolResp.data)) {
                        if ($p.poolid) { $poolMap += [string]$p.poolid }
                    }
                    $poolMap = @($poolMap | Select-Object -Unique)
                }
            }
            catch {
                Write-Verbose "Proxmox pools endpoint unavailable: $_"
            }

            try {
                $null = & $invokeApi "${baseUri}/api2/json/storage" $hdrName $hdrVal $ignoreCert
                $storageListEndpointHealthy = $true
            }
            catch {
                Write-Verbose "Proxmox storage endpoint unavailable: $_"
            }

            try {
                $null = & $invokeApi "${baseUri}/api2/json/cluster/sdn" $hdrName $hdrVal $ignoreCert
                $sdnListEndpointHealthy = $true

                $sdnCollections = @(
                    @{ Name = 'zones';       Key = 'zone' }
                    @{ Name = 'vnets';       Key = 'vnet' }
                    @{ Name = 'controllers'; Key = 'controller' }
                    @{ Name = 'ipams';       Key = 'ipam' }
                    @{ Name = 'dns';         Key = 'dns' }
                )
                foreach ($c in $sdnCollections) {
                    try {
                        $listResp = & $invokeApi "${baseUri}/api2/json/cluster/sdn/$($c.Name)" $hdrName $hdrVal $ignoreCert
                        if ($listResp.data) {
                            foreach ($obj in @($listResp.data)) {
                                $idVal = $obj.($c.Key)
                                if (-not $idVal -and $obj.id) { $idVal = $obj.id }
                                if ($idVal) {
                                    $sdnObjectMap += @{ Collection = $c.Name; Key = $c.Key; Id = [string]$idVal }
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Proxmox SDN collection endpoint unavailable: $($c.Name) ($_ )"
                    }
                }
            }
            catch {
                Write-Verbose "Proxmox SDN endpoint unavailable: $_"
            }

            # Validate QEMU VMs
            Write-Host "  Validating VM metrics..." -ForegroundColor DarkGray
            foreach ($vmid in @($vmMap.Keys | Sort-Object { [int]$_ })) {
                $vmInfo = $vmMap[$vmid]
                if ($vmInfo.Status -ne 'running') {
                    # Stopped VMs — include all perf keys (benefit of the doubt)
                    $guestValidated[$vmid] = @($guestPerfDefs | ForEach-Object { $_.Key })
                    Write-Host "    $($vmInfo.Name) (VM $vmid): stopped — perf monitors included (unvalidated)" -ForegroundColor DarkYellow
                    continue
                }
                try {
                    $resp = & $invokeApi "${baseUri}/api2/json/nodes/$($vmInfo.Node)/qemu/${vmid}/status/current" $hdrName $hdrVal $ignoreCert
                    $d = $resp.data
                    $validKeys = [System.Collections.Generic.List[string]]::new()
                    foreach ($pm in $guestPerfDefs) {
                        $val = & $resolveField $d $pm.Field
                        if ($null -ne $val -and ($val -is [double] -or $val -is [int] -or $val -is [long] -or $val -is [decimal] -or $val -is [float] -or $val -is [single] -or "$val" -match '^\d')) {
                            $validKeys.Add($pm.Key)
                        }
                    }
                    $guestValidated[$vmid] = @($validKeys)
                    $dropped = $guestPerfDefs.Count - $validKeys.Count
                    if ($dropped -gt 0) {
                        Write-Host "    $($vmInfo.Name) (VM $vmid): $($validKeys.Count)/$($guestPerfDefs.Count) validated ($dropped dropped)" -ForegroundColor DarkYellow
                    } else {
                        Write-Host "    $($vmInfo.Name) (VM $vmid): $($validKeys.Count)/$($guestPerfDefs.Count) validated" -ForegroundColor DarkGray
                    }
                }
                catch {
                    Write-Warning "    Could not probe VM $($vmInfo.Name) ($vmid) — keeping all: $_"
                    $guestValidated[$vmid] = @($guestPerfDefs | ForEach-Object { $_.Key })
                }
            }

            # Validate per-storage metrics
            if ($nodeStorageMap.Count -gt 0) {
                Write-Host "  Validating storage metrics..." -ForegroundColor DarkGray
                foreach ($nodeName in @($nodeStorageMap.Keys | Sort-Object)) {
                    foreach ($st in @($nodeStorageMap[$nodeName])) {
                        $storageName = $st.Name
                        if (-not $storageName) { continue }
                        $svKey = "${nodeName}/${storageName}"
                        try {
                            $resp = & $invokeApi "${baseUri}/api2/json/nodes/${nodeName}/storage/${storageName}/status" $hdrName $hdrVal $ignoreCert
                            $d = $resp.data
                            $validKeys = [System.Collections.Generic.List[string]]::new()
                            foreach ($pm in $storagePerfDefs) {
                                $val = & $resolveField $d $pm.Field
                                if ($null -ne $val -and ($val -is [double] -or $val -is [int] -or $val -is [long] -or $val -is [decimal] -or $val -is [float] -or $val -is [single] -or "$val" -match '^\d')) {
                                    $validKeys.Add($pm.Key)
                                }
                            }
                            $storageValidated[$svKey] = @($validKeys)
                        }
                        catch {
                            Write-Verbose "Could not probe storage ${storageName} on ${nodeName} — keeping all metrics: $_"
                            $storageValidated[$svKey] = @($storagePerfDefs | ForEach-Object { $_.Key })
                        }
                    }
                }
            }

            # Validate LXC containers
            if ($ctMap.Count -gt 0) {
                Write-Host "  Validating container metrics..." -ForegroundColor DarkGray
                foreach ($ctid in @($ctMap.Keys | Sort-Object { [int]$_ })) {
                    $ctInfo = $ctMap[$ctid]
                    if ($ctInfo.Status -ne 'running') {
                        $guestValidated[$ctid] = @($guestPerfDefs | ForEach-Object { $_.Key })
                        Write-Host "    $($ctInfo.Name) (CT $ctid): stopped — perf monitors included (unvalidated)" -ForegroundColor DarkYellow
                        continue
                    }
                    try {
                        $resp = & $invokeApi "${baseUri}/api2/json/nodes/$($ctInfo.Node)/lxc/${ctid}/status/current" $hdrName $hdrVal $ignoreCert
                        $d = $resp.data
                        $validKeys = [System.Collections.Generic.List[string]]::new()
                        foreach ($pm in $guestPerfDefs) {
                            $val = & $resolveField $d $pm.Field
                            if ($null -ne $val -and ($val -is [double] -or $val -is [int] -or $val -is [long] -or $val -is [decimal] -or $val -is [float] -or $val -is [single] -or "$val" -match '^\d')) {
                                $validKeys.Add($pm.Key)
                            }
                        }
                        $guestValidated[$ctid] = @($validKeys)
                        $dropped = $guestPerfDefs.Count - $validKeys.Count
                        if ($dropped -gt 0) {
                            Write-Host "    $($ctInfo.Name) (CT $ctid): $($validKeys.Count)/$($guestPerfDefs.Count) validated ($dropped dropped)" -ForegroundColor DarkYellow
                        } else {
                            Write-Host "    $($ctInfo.Name) (CT $ctid): $($validKeys.Count)/$($guestPerfDefs.Count) validated" -ForegroundColor DarkGray
                        }
                    }
                    catch {
                        Write-Warning "    Could not probe container $($ctInfo.Name) ($ctid) — keeping all: $_"
                        $guestValidated[$ctid] = @($guestPerfDefs | ForEach-Object { $_.Key })
                    }
                }
            }

            # Summary
            $totalNodeMetrics = ($nodeValidated.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
            $totalGuestMetrics = ($guestValidated.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
            Write-Host "  Validation: $totalNodeMetrics node metrics + $totalGuestMetrics guest metrics confirmed" -ForegroundColor DarkGray
        }
        else {
            # No auth — cannot validate, accept all
            $clusterValidated['cluster'] = @($clusterPerfDefs | ForEach-Object { $_.Key })
            foreach ($n in $nodeMap.Keys) { $nodeValidated[$n] = @($nodePerfDefs | ForEach-Object { $_.Key }) }
            foreach ($v in $vmMap.Keys)   { $guestValidated[$v] = @($guestPerfDefs | ForEach-Object { $_.Key }) }
            foreach ($c in $ctMap.Keys)   { $guestValidated[$c] = @($guestPerfDefs | ForEach-Object { $_.Key }) }
            foreach ($nodeName in $nodeStorageMap.Keys) {
                foreach ($st in @($nodeStorageMap[$nodeName])) {
                    if (-not $st.Name) { continue }
                    $storageValidated["${nodeName}/$($st.Name)"] = @($storagePerfDefs | ForEach-Object { $_.Key })
                }
            }
        }

        # ================================================================
        # Phase 3: Build fully-resolved monitor plan
        # ================================================================
        # Each monitor gets a unique, hardcoded URL with the actual
        # node name / VMID baked in. WUG REST API monitors only support
        # %Device.Address%, %Device.Hostname%, and credential variables —
        # custom device attributes CANNOT be used in URLs.
        # Auth is handled entirely by the device's REST API credential
        # (Basic auth with API token split into user:secret).
        # Monitors set RestApiUseAnonymousAccess='0' so WUG attaches
        # the credential on every poll.

        $apiBase = "https://${apiHost}:${apiPort}/api2/json"

        $baseAttrs = @{
            'Proxmox.ApiHost' = $apiHost
            'Proxmox.ApiPort' = $apiPort
            'DiscoveryHelper.Proxmox' = 'true'
            'DiscoveryHelper.Proxmox.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
        }

        # Auth via RestApiCustomHeader with the actual token baked in.
        # WUG does NOT resolve %Credential.Password% in CustomHeader fields,
        # so we hardcode the full PVEAPIToken header at plan-generation time.
        # The credential is still created in WUG for device assignment, but
        # the actual auth goes through this header on each monitor.
        # UseAnonymous='1' disables Basic auth so WUG does not send its own
        # Authorization header.
        if ($tokenValue) {
            $tplAuthHeader = "Authorization:PVEAPIToken=$tokenValue"
        } else {
            # Ticket-based auth — no persistent token available for monitors
            $tplAuthHeader = ''
            Write-Warning "No API token available. Monitors will not have auth headers. Use -AuthMethod Token for WUG push."
        }

        # Common active monitor params
        $activeBase = @{
            RestApiMethod                 = 'GET'
            RestApiTimeoutMs              = 10000
            RestApiIgnoreCertErrors       = $ignoreCert
            RestApiUseAnonymous           = '1'
            RestApiCustomHeader           = $tplAuthHeader
            RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
        }
        # Common perf monitor params
        $perfBase = @{
            RestApiHttpMethod         = 'GET'
            RestApiHttpTimeoutMs      = 10000
            RestApiIgnoreCertErrors   = $ignoreCert
            RestApiUseAnonymousAccess = '1'
            RestApiCustomHeader       = $tplAuthHeader
        }

        # --- Cluster device (the API entry point) ---
        $clusterAttrs = $baseAttrs.Clone()
        $clusterAttrs['Proxmox.DeviceType'] = 'Cluster'
        $clusterAttrs['Proxmox.NodeCount'] = [string]$nodeMap.Count
        $clusterAttrs['Proxmox.VMCount'] = [string]$vmMap.Count
        $clusterAttrs['Proxmox.CTCount'] = [string]$ctMap.Count

        $clusterUrl = "${apiBase}/cluster/status"
        $nodeListUrl = "${apiBase}/nodes"
        $poolListUrl = "${apiBase}/pools"
        $storageListUrl = "${apiBase}/storage"
        $sdnListUrl = "${apiBase}/cluster/sdn"

        $aParams = $activeBase.Clone()
        $aParams['RestApiUrl'] = $clusterUrl
        $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data'][0]['type']`",`"AttributeType`":3,`"ComparisonType`":14}]"
        $items += New-DiscoveredItem `
            -Name "Proxmox - Cluster Status" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams $aParams `
            -UniqueKey "Proxmox:cluster:active:status" `
            -Attributes $clusterAttrs `
            -Tags @('proxmox', 'cluster')

        $aParams = $activeBase.Clone()
        $aParams['RestApiUrl'] = $nodeListUrl
        $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data'][0]['node']`",`"AttributeType`":3,`"ComparisonType`":14}]"
        $items += New-DiscoveredItem `
            -Name "Proxmox - Node List" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams $aParams `
            -UniqueKey "Proxmox:cluster:active:nodelist" `
            -Attributes $clusterAttrs `
            -Tags @('proxmox', 'cluster')

        if ($poolListEndpointHealthy) {
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $poolListUrl
            $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']`",`"AttributeType`":3,`"ComparisonType`":14}]"
            $items += New-DiscoveredItem `
                -Name "Proxmox - Pool List" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Proxmox:cluster:active:poollist" `
                -Attributes $clusterAttrs `
                -Tags @('proxmox', 'cluster', 'pool')

            foreach ($poolId in @($poolMap)) {
                $poolUrl = "${apiBase}/pools/${poolId}"
                $poolAttrs = $clusterAttrs.Clone()
                $poolAttrs['Proxmox.PoolId'] = [string]$poolId

                $aParams = $activeBase.Clone()
                $aParams['RestApiUrl'] = $poolUrl
                $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']['poolid']`",`"AttributeType`":3,`"ComparisonType`":14}]"
                $items += New-DiscoveredItem `
                    -Name "Proxmox - Pool ${poolId} Status" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $aParams `
                    -UniqueKey "Proxmox:cluster:pool:${poolId}:active:status" `
                    -Attributes $poolAttrs `
                    -Tags @('proxmox', 'cluster', 'pool', $poolId)
            }
        }

        if ($storageListEndpointHealthy) {
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $storageListUrl
            $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']`",`"AttributeType`":3,`"ComparisonType`":14}]"
            $items += New-DiscoveredItem `
                -Name "Proxmox - Storage List" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Proxmox:cluster:active:storagelist" `
                -Attributes $clusterAttrs `
                -Tags @('proxmox', 'cluster', 'storage')
        }

        if ($sdnListEndpointHealthy) {
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $sdnListUrl
            $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']`",`"AttributeType`":3,`"ComparisonType`":14}]"
            $items += New-DiscoveredItem `
                -Name "Proxmox - SDN List" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Proxmox:cluster:active:sdnlist" `
                -Attributes $clusterAttrs `
                -Tags @('proxmox', 'cluster', 'sdn')

            foreach ($sdnObj in @($sdnObjectMap)) {
                $sdnUrl = "${apiBase}/cluster/sdn/$($sdnObj.Collection)/$($sdnObj.Id)"
                $sdnAttrs = $clusterAttrs.Clone()
                $sdnAttrs['Proxmox.SdnCollection'] = [string]$sdnObj.Collection
                $sdnAttrs['Proxmox.SdnId'] = [string]$sdnObj.Id

                $aParams = $activeBase.Clone()
                $aParams['RestApiUrl'] = $sdnUrl
                $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']['$($sdnObj.Key)']`",`"AttributeType`":3,`"ComparisonType`":14}]"
                $items += New-DiscoveredItem `
                    -Name "Proxmox - SDN $($sdnObj.Collection) $($sdnObj.Id) Status" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $aParams `
                    -UniqueKey "Proxmox:cluster:sdn:$($sdnObj.Collection):$($sdnObj.Id):active:status" `
                    -Attributes $sdnAttrs `
                    -Tags @('proxmox', 'cluster', 'sdn', $sdnObj.Collection, $sdnObj.Id)
            }
        }

        # Cluster performance monitors — only validated metrics
        $validClusterKeys = if ($clusterValidated.ContainsKey('cluster')) { $clusterValidated['cluster'] } else { @($clusterPerfDefs | ForEach-Object { $_.Key }) }
        foreach ($pm in $clusterPerfDefs) {
            if ($validClusterKeys -notcontains $pm.Key) { continue }
            $pParams = $perfBase.Clone()
            $pParams['RestApiUrl']      = $clusterUrl
            $pParams['RestApiJsonPath'] = $pm.JsonPath
            $items += New-DiscoveredItem `
                -Name $pm.Name `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $pParams `
                -UniqueKey "Proxmox:cluster:perf:$($pm.Key)" `
                -Attributes $clusterAttrs `
                -Tags @('proxmox', 'cluster')
        }

        # --- Per-Node items ---
        foreach ($nodeName in @($nodeMap.Keys | Sort-Object)) {
            $nodeIP = $nodeMap[$nodeName]
            $nodeStatusUrl = "${apiBase}/nodes/${nodeName}/status"

            $nodeAttrs = $baseAttrs.Clone()
            $nodeAttrs['Proxmox.DeviceType'] = 'Node'
            $nodeAttrs['Proxmox.NodeName']   = $nodeName
            if ($nodeIP) { $nodeAttrs['Proxmox.NodeIP'] = $nodeIP }

            # Store static capacity totals as attributes (not worth polling)
            if ($nodeCapacity.ContainsKey($nodeName)) {
                $cap = $nodeCapacity[$nodeName]
                if ($cap.MemTotal)  { $nodeAttrs['Proxmox.NodeMemTotal']  = [string]$cap.MemTotal }
                if ($cap.SwapTotal) { $nodeAttrs['Proxmox.NodeSwapTotal'] = [string]$cap.SwapTotal }
                if ($cap.DiskTotal) { $nodeAttrs['Proxmox.NodeDiskTotal'] = [string]$cap.DiskTotal }
            }

            # Active monitor — DOWN if $.data.uptime is null
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $nodeStatusUrl
            $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']['uptime']`",`"AttributeType`":3,`"ComparisonType`":14}]"
            $items += New-DiscoveredItem `
                -Name "Proxmox - Node ${nodeName} Status" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Proxmox:node:${nodeName}:active:status" `
                -Attributes $nodeAttrs `
                -Tags @('proxmox', 'node', $nodeName, $(if ($nodeIP) { $nodeIP } else { 'no-ip' }))

            # Node-scoped SDN API availability
            if ($nodeSdnEndpointHealthy.ContainsKey($nodeName) -and $nodeSdnEndpointHealthy[$nodeName]) {
                $nodeSdnUrl = "${apiBase}/nodes/${nodeName}/sdn"
                $aParams = $activeBase.Clone()
                $aParams['RestApiUrl'] = $nodeSdnUrl
                $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']`",`"AttributeType`":3,`"ComparisonType`":14}]"
                $items += New-DiscoveredItem `
                    -Name "Proxmox - Node ${nodeName} SDN Status" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $aParams `
                    -UniqueKey "Proxmox:node:${nodeName}:active:sdn" `
                    -Attributes $nodeAttrs `
                    -Tags @('proxmox', 'node', 'sdn', $nodeName, $(if ($nodeIP) { $nodeIP } else { 'no-ip' }))
            }

            # Per-storage active/perf monitors on this node
            foreach ($st in @($nodeStorageMap[$nodeName])) {
                $storageName = $st.Name
                if (-not $storageName) { continue }
                $storageType = if ($st.Type) { $st.Type } else { 'unknown' }
                $storageStatusUrl = "${apiBase}/nodes/${nodeName}/storage/${storageName}/status"

                $storageAttrs = $nodeAttrs.Clone()
                $storageAttrs['Proxmox.StorageName'] = $storageName
                $storageAttrs['Proxmox.StorageType'] = $storageType

                # Active monitor — DOWN if active does not contain '1'
                $aParams = $activeBase.Clone()
                $aParams['RestApiUrl'] = $storageStatusUrl
                $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']['active']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"1`"}]"
                $items += New-DiscoveredItem `
                    -Name "Proxmox - Storage ${storageName} on ${nodeName} Status" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $aParams `
                    -UniqueKey "Proxmox:node:${nodeName}:storage:${storageName}:active:status" `
                    -Attributes $storageAttrs `
                    -Tags @('proxmox', 'node', 'storage', $nodeName, $storageName, $storageType)

                $svKey = "${nodeName}/${storageName}"
                $validStorageKeys = if ($storageValidated.ContainsKey($svKey)) { $storageValidated[$svKey] } else { @($storagePerfDefs | ForEach-Object { $_.Key }) }
                foreach ($pm in $storagePerfDefs) {
                    if ($validStorageKeys -notcontains $pm.Key) { continue }
                    $pParams = $perfBase.Clone()
                    $pParams['RestApiUrl']      = $storageStatusUrl
                    $pParams['RestApiJsonPath'] = $pm.JsonPath
                    $items += New-DiscoveredItem `
                        -Name "Proxmox - Storage ${storageName} on ${nodeName} $($pm.Name)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams $pParams `
                        -UniqueKey "Proxmox:node:${nodeName}:storage:${storageName}:perf:$($pm.Key)" `
                        -Attributes $storageAttrs `
                        -Tags @('proxmox', 'node', 'storage', $nodeName, $storageName, $storageType)
                }
            }

            # Performance monitors — only validated metrics
            $validNodeKeys = if ($nodeValidated.ContainsKey($nodeName)) { $nodeValidated[$nodeName] } else { @($nodePerfDefs | ForEach-Object { $_.Key }) }
            foreach ($pm in $nodePerfDefs) {
                if ($validNodeKeys -notcontains $pm.Key) { continue }
                $pParams = $perfBase.Clone()
                $pParams['RestApiUrl']      = $nodeStatusUrl
                $pParams['RestApiJsonPath'] = $pm.JsonPath
                $items += New-DiscoveredItem `
                    -Name "Proxmox - Node ${nodeName} $($pm.Name -replace '^Proxmox - Node ','')" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $pParams `
                    -UniqueKey "Proxmox:node:${nodeName}:perf:$($pm.Key)" `
                    -Attributes $nodeAttrs `
                    -Tags @('proxmox', 'node', $nodeName, $(if ($nodeIP) { $nodeIP } else { 'no-ip' }))
            }
        }

        # --- Per-VM items ---
        foreach ($vmid in @($vmMap.Keys | Sort-Object { [int]$_ })) {
            $vmInfo = $vmMap[$vmid]
            $vmName = if ($vmInfo.Name) { $vmInfo.Name } else { "vm-$vmid" }
            $vmIP   = $vmInfo.IP
            $vmNode = $vmInfo.Node
            $vmStatusUrl = "${apiBase}/nodes/${vmNode}/qemu/${vmid}/status/current"

            $vmAttrs = $baseAttrs.Clone()
            $vmAttrs['Proxmox.DeviceType'] = 'VM'
            $vmAttrs['Proxmox.VMID']       = [string]$vmid
            $vmAttrs['Proxmox.VMName']     = $vmName
            $vmAttrs['Proxmox.ParentNode'] = $vmNode
            $vmAttrs['Proxmox.VMStatus']   = $vmInfo.Status
            if ($vmIP)          { $vmAttrs['Proxmox.VMIP']      = $vmIP }
            if ($vmInfo.Cpus)   { $vmAttrs['Proxmox.VMCpus']    = [string]$vmInfo.Cpus }
            if ($vmInfo.MaxMem) { $vmAttrs['Proxmox.VMMaxMem']  = [string]$vmInfo.MaxMem }
            if ($vmInfo.MaxDisk){ $vmAttrs['Proxmox.VMMaxDisk'] = [string]$vmInfo.MaxDisk }

            # Active monitor — DOWN if $.data.status does not contain 'running'
            # ComparisonList: AttributeType 1=String, ComparisonType 3=DoesNotContain
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $vmStatusUrl
            $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']['status']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"running`"}]"
            $items += New-DiscoveredItem `
                -Name "Proxmox - VM ${vmName} Status" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Proxmox:vm:${vmid}:active:status" `
                -Attributes $vmAttrs `
                -Tags @('proxmox', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmNode)

            # Performance monitors — only validated metrics
            $validGuestKeys = if ($guestValidated.ContainsKey($vmid)) { $guestValidated[$vmid] } else { @($guestPerfDefs | ForEach-Object { $_.Key }) }
            foreach ($pm in $guestPerfDefs) {
                if ($validGuestKeys -notcontains $pm.Key) { continue }
                $pParams = $perfBase.Clone()
                $pParams['RestApiUrl']      = $vmStatusUrl
                $pParams['RestApiJsonPath'] = $pm.JsonPath
                $items += New-DiscoveredItem `
                    -Name "Proxmox - VM ${vmName} $($pm.Name)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $pParams `
                    -UniqueKey "Proxmox:vm:${vmid}:perf:$($pm.Key)" `
                    -Attributes $vmAttrs `
                    -Tags @('proxmox', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmNode)
            }
        }

        # --- Per-Container (LXC) items ---
        foreach ($ctid in @($ctMap.Keys | Sort-Object { [int]$_ })) {
            $ctInfo = $ctMap[$ctid]
            $ctName = if ($ctInfo.Name) { $ctInfo.Name } else { "ct-$ctid" }
            $ctIP   = $ctInfo.IP
            $ctNode = $ctInfo.Node
            $ctStatusUrl = "${apiBase}/nodes/${ctNode}/lxc/${ctid}/status/current"

            $ctAttrs = $baseAttrs.Clone()
            $ctAttrs['Proxmox.DeviceType'] = 'CT'
            $ctAttrs['Proxmox.VMID']       = [string]$ctid
            $ctAttrs['Proxmox.VMName']     = $ctName
            $ctAttrs['Proxmox.ParentNode'] = $ctNode
            $ctAttrs['Proxmox.VMStatus']   = $ctInfo.Status
            if ($ctIP)          { $ctAttrs['Proxmox.VMIP']      = $ctIP }
            if ($ctInfo.Cpus)   { $ctAttrs['Proxmox.VMCpus']    = [string]$ctInfo.Cpus }
            if ($ctInfo.MaxMem) { $ctAttrs['Proxmox.VMMaxMem']  = [string]$ctInfo.MaxMem }
            if ($ctInfo.MaxDisk){ $ctAttrs['Proxmox.VMMaxDisk'] = [string]$ctInfo.MaxDisk }

            # Active monitor — DOWN if $.data.status does not contain 'running'
            # ComparisonList: AttributeType 1=String, ComparisonType 3=DoesNotContain
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $ctStatusUrl
            $aParams['RestApiComparisonList'] = "[{`"JsonPathQuery`":`"['data']['status']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"running`"}]"
            $items += New-DiscoveredItem `
                -Name "Proxmox - CT ${ctName} Status" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Proxmox:ct:${ctid}:active:status" `
                -Attributes $ctAttrs `
                -Tags @('proxmox', 'ct', $ctName, $(if ($ctIP) { $ctIP } else { 'no-ip' }), $ctNode)

            # Performance monitors — only validated metrics
            $validCtKeys = if ($guestValidated.ContainsKey($ctid)) { $guestValidated[$ctid] } else { @($guestPerfDefs | ForEach-Object { $_.Key }) }
            foreach ($pm in $guestPerfDefs) {
                if ($validCtKeys -notcontains $pm.Key) { continue }
                $pParams = $perfBase.Clone()
                $pParams['RestApiUrl']      = $ctStatusUrl
                $pParams['RestApiJsonPath'] = $pm.JsonPath
                $items += New-DiscoveredItem `
                    -Name "Proxmox - CT ${ctName} $($pm.Name)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $pParams `
                    -UniqueKey "Proxmox:ct:${ctid}:perf:$($pm.Key)" `
                    -Attributes $ctAttrs `
                    -Tags @('proxmox', 'ct', $ctName, $(if ($ctIP) { $ctIP } else { 'no-ip' }), $ctNode)
            }
        }

        $tokenValue = $null; $ticketCookie = $null; $csrfToken = $null
        return $items
    }

# ==============================================================================
# Export-ProxmoxDashboardHtml
# ==============================================================================
function Export-ProxmoxDashboardHtml {
    <#
    .SYNOPSIS
        Generates a Proxmox dashboard HTML file from live cluster data.
    .DESCRIPTION
        Reads the Proxmox dashboard template, injects column definitions
        and row data as JSON, and writes the final HTML to OutputPath.
        Data should be pre-formatted (human-readable strings for CPU, RAM, etc.).
    .PARAMETER DashboardData
        Array of PSCustomObject rows — one per node or VM.
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title shown in header and browser tab.
    .PARAMETER TemplatePath
        Path to Proxmox-Dashboard-Template.html. Defaults to same directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Proxmox Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'proxmox\Proxmox-Dashboard-Template.html'
    }
    if (-not (Test-Path $TemplatePath)) {
        Write-Error "Template not found: $TemplatePath"
        return
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
        if ($prop.Name -eq 'Status') { $col.formatter = 'formatStatus' }
        if ($prop.Name -eq 'Type')   { $col.formatter = 'formatType' }
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBONJQGaQUr2n49
# M5HKo2/6bFZH8a39Ny3vCwTKceP48KCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBL3R1Q0pupHjGfQ01NrDZvvYoGXLIWen+9rnhN0ADVHTANBgkqhkiG9w0BAQEF
# AASCAgAoP3EKfViSCcrxc3FkWhupt+Y3RwRfe1MC7bUGCY/0PyWQQ36IuFIyXFfV
# 2vi2KTI6H64RJzGVJDuCdGzDVB5EUpQn8wSR0ubG/icc7LKdcY8JoaKMG6DjoW2o
# Yn4ivwV+C1WQ6/fFqzpD2MzukgE1i92yWzfeNUhpG9WIIWpJdTDZqL4GAPP/A/Gg
# ZL9WfX2UpZwsuFHISUMhxXR/3OEEYmV0XPvnrWhgbhkGmrM04Fw3nxLWtJqd8VZb
# F72SoIiEyTyjLCgd70x8Ns92pJ/4tT0Klwmd1BKXIyJb4BixQNhtwUM2w0c4LF7J
# uCemzDBz3U73n2rTgP9DdurncrCqfNOn3H7h3m7r8HpEuHZldNZVFUF1cfkrIKqT
# 8k38qpQUo9ve+JYIhgQQEWyfCQVucth1Cgq+FsouBJ9/Ik30zCZ7z2u7IREsZUyA
# ufs0PSLuBXksUSNS50B3zx1qgfCUAozWdnsypW5Iue1cA9F49oV8TtEgIBMVIYoS
# T02U8sfFCPNrNEDyyXChD6tvxpi8/H9JCxmeYQJ/cYytei5teH2QrzTUMoHP7Qj8
# oK2/kW8wvhaSvPosMo7MJ1kljuBLu+A6i5Iij9huBnKbqfpmg4OVspEObN9SV5Um
# r6ZizbUiIWm/tmz8Og5FVKa2X9MPOjprSnNx/P+H2KbPzBZTGqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA2MjExNzQ1NThaMC8GCSqGSIb3DQEJBDEiBCBJmfzN
# V+pjxaVy+wq+L/XlUKaxl5i/bk6/BxncVIccJDANBgkqhkiG9w0BAQEFAASCAgAW
# gF2tVNwPddbC86Bkggg+IcUw1eDVMn2IQPtWLj+LuV64uPLj840cVaNc0aW3h9Gu
# gjGOcQFJe3BDvk0rn127X/2ED7XLfFbLDvJiinqq7Xr5vJ/ARxXQ1aZ3+nMEQpT2
# JPuEcZvr/3c7psvLvnYYnLmdDeT1TjGZlxEpYM/6g6U7fh2i3wXONKfdPLc99quJ
# STQJAmnfYDd8qfJALfpdSmKCzcXSYSbsxJCl2pZljhuvemFHL/6dzu78XUnKN8rT
# 7LrpagmO0bnu6gfBOnH7YnwOZAuom3RaHSyWGcXgamGUjo6biFt139aOsa7FM1X9
# 49XuJCaq+Pd8NH6e3C/yA75vd8RDAOMYZJCuS5W5Xt9TyS7JDYlVQ/NxK4r2i3hD
# xIV3qxqxmj6Tl7Nh3X85Ai0ndPNS1TnwUDhO+onskxlVz4a1N0V0t81uz45J4Hzj
# 5hui1lBgLBSZf+AgY5yOtMPa3rFT545u626hN9lSWiv+fHZL3mrA5gTlQs3YP8+6
# kecyJlnzEBkcpZFJIEwMfkV22tyED+z8D+UiwsmgFHjrWRUZ0Ib1xDXL/sGhOb5s
# ADiQNo5uu234lNqjvjI9yjCIUV/TTeTG6+zyBE+QxxAJVaZ9dSbSVwB6419/EVFp
# nTswk0RLlzqPcfuuhTqzkeQZamSkp47G4g1c78xBpQ==
# SIG # End signature block
