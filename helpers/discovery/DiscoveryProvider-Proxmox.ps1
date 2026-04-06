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

        Write-Host "  Topology: $($nodeMap.Count) nodes, $($vmMap.Count) VMs, $($ctMap.Count) containers" -ForegroundColor DarkGray

        # ================================================================
        # Phase 2: Validate metrics return numeric data
        # ================================================================
        # Probe each node/VM/CT status endpoint and verify that the JSON
        # paths used by performance monitors extract numeric values.
        # Dropped metrics are not added to the plan. Active monitors are
        # always kept (they only check HTTP status, not numeric values).

        # Define the metric sets once (reused in Phase 3 plan building)
        $nodePerfDefs = @(
            @{ Name = 'Proxmox - Node CPU';            JsonPath = '$.data.cpu';            Key = 'cpu';         Field = 'cpu' }
            @{ Name = 'Proxmox - Node CPU IO Wait';    JsonPath = '$.data.wait';           Key = 'iowait';     Field = 'wait' }
            @{ Name = 'Proxmox - Node Memory Used';    JsonPath = '$.data.memory.used';    Key = 'memused';    Field = 'memory.used' }
            @{ Name = 'Proxmox - Node Memory Free';    JsonPath = '$.data.memory.free';    Key = 'memfree';    Field = 'memory.free' }
            @{ Name = 'Proxmox - Node Swap Used';      JsonPath = '$.data.swap.used';      Key = 'swapused';   Field = 'swap.used' }
            @{ Name = 'Proxmox - Node Swap Free';      JsonPath = '$.data.swap.free';      Key = 'swapfree';   Field = 'swap.free' }
            @{ Name = 'Proxmox - Node Disk Used';      JsonPath = '$.data.rootfs.used';    Key = 'diskused';   Field = 'rootfs.used' }
            @{ Name = 'Proxmox - Node Disk Free';      JsonPath = '$.data.rootfs.free';    Key = 'diskfree';   Field = 'rootfs.free' }
            @{ Name = 'Proxmox - Node Load Avg 1m';    JsonPath = '$.data.loadavg[0]';     Key = 'loadavg1';   Field = 'loadavg[0]' }
            @{ Name = 'Proxmox - Node Load Avg 5m';    JsonPath = '$.data.loadavg[1]';     Key = 'loadavg5';   Field = 'loadavg[1]' }
            @{ Name = 'Proxmox - Node Load Avg 15m';   JsonPath = '$.data.loadavg[2]';     Key = 'loadavg15';  Field = 'loadavg[2]' }
            @{ Name = 'Proxmox - Node Uptime';         JsonPath = '$.data.uptime';         Key = 'uptime';     Field = 'uptime' }
        )
        $guestPerfDefs = @(
            @{ Name = 'CPU';        JsonPath = '$.data.cpu';       Key = 'cpu';       Field = 'cpu' }
            @{ Name = 'Memory';     JsonPath = '$.data.mem';       Key = 'mem';       Field = 'mem' }
            @{ Name = 'Net In';     JsonPath = '$.data.netin';     Key = 'netin';     Field = 'netin' }
            @{ Name = 'Net Out';    JsonPath = '$.data.netout';    Key = 'netout';    Field = 'netout' }
            @{ Name = 'Disk Read';  JsonPath = '$.data.diskread';  Key = 'diskread';  Field = 'diskread' }
            @{ Name = 'Disk Write'; JsonPath = '$.data.diskwrite'; Key = 'diskwrite'; Field = 'diskwrite' }
            @{ Name = 'Uptime';     JsonPath = '$.data.uptime';    Key = 'uptime';    Field = 'uptime' }
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
        $nodeValidated = @{}
        $guestValidated = @{}  # validated[vmid] = @('cpu','mem',...)
        $nodeCapacity = @{}    # nodeCapacity[nodeName] = @{ MemTotal; SwapTotal; DiskTotal }

        if ($hdrName) {
            Write-Host "  Validating node metrics..." -ForegroundColor DarkGray
            foreach ($nodeName in @($nodeMap.Keys | Sort-Object)) {
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
            foreach ($n in $nodeMap.Keys) { $nodeValidated[$n] = @($nodePerfDefs | ForEach-Object { $_.Key }) }
            foreach ($v in $vmMap.Keys)   { $guestValidated[$v] = @($guestPerfDefs | ForEach-Object { $_.Key }) }
            foreach ($c in $ctMap.Keys)   { $guestValidated[$c] = @($guestPerfDefs | ForEach-Object { $_.Key }) }
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

        $clusterUrl = "${apiBase}/cluster/status"
        $nodeListUrl = "${apiBase}/nodes"

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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBn6vwqLR/b6AA1
# ogZ9uh7Jd2Xekd32A0cOuUgWGga1caCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg7/CDaSACgJe55wH1rXMjB+xNdZUM4E70
# 9pZM4IbbVgowDQYJKoZIhvcNAQEBBQAEggIAUTb0gXWMqF5PTFrpuNopqYNJszJf
# /dpV8JOeQthtWAjs2qmNHm2cJWt5Ywp85tFyUElV4uF2H4Rk+C87mhXHgO7JDFlC
# f2v1Hw+CQJPZaKUEdOoxcK71GM3snFxlD0DT+x9DYFqGeFIVrHVUKEgajIEWVt9c
# OZxzxdz61ywMJh7O+d7upHibEvqFOri4ZLgDxDN7ZJ9i7afiS7+yQiE3dhTYdM60
# 1V3YbwFg0qcNy+M2eCGV+IzhCwLspHa2UXFYuaiFGbTpNXCWnuvFvs8VIy8JwJDn
# lz1F47/FhZf/H5jEIZAL1+F2rZdiBEo2FdYft+oADJZN3Yx9JLsXw42vxRazKRMp
# uKkcHvL0edxNwG7DF4GYhSoXyoM4lARovEkW4+a4zxXGExnB1RfdnRuMT2fiys1N
# heEdQ6RjzvjdkMMnI1gujpCpx1Ee9ryizs6KQPpGS6fnq1nQmpmsyCzulIPAmmWG
# dmEZofK8B/SuB2QnXbCuG/CjuIQfMXcUIAzc+01Ck5zgFsb+beYl8VxIkqcToVpP
# Ce+GqL4TR6w5D3xnFdri19kJWKd+SNhG+ODkvuPnXcbEKWvobFcuAkWvoWTB7nJG
# 307AcPkPYF/7xzRWwRiohwgFbT7aEXG2VWFVV+m2yxL6+WXjahDjLA+nUui+dYmy
# wHHe1Uih9359/a4=
# SIG # End signature block
