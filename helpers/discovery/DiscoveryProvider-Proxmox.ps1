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
                        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
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

        # ================================================================
        # WUG Context Variable Syntax
        # ================================================================
        # These are used in monitor URL/header templates so WUG resolves
        # them per-device at poll time. Adjust if your WUG version uses
        # different substitution syntax.
        # The credential password holds the full PVE API token string.
        $credPwdVar    = '%Credential.Password%'

        # Template URLs using device attributes (resolved by WUG at poll time)
        $tplClusterUrl = "https://%Proxmox.ApiHost%:%Proxmox.ApiPort%/api2/json/cluster/status"
        $tplNodeListUrl= "https://%Proxmox.ApiHost%:%Proxmox.ApiPort%/api2/json/nodes"
        $tplNodeUrl    = "https://%Proxmox.ApiHost%:%Proxmox.ApiPort%/api2/json/nodes/%Proxmox.NodeName%/status"
        $tplVmUrl      = "https://%Proxmox.ApiHost%:%Proxmox.ApiPort%/api2/json/nodes/%Proxmox.ParentNode%/qemu/%Proxmox.VMID%/status/current"

        # Auth header template (references WUG credential — no plaintext token)
        $tplAuthHeader = "Authorization:PVEAPIToken=${credPwdVar}"

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
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                }
                $ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                if ($HdrName -eq 'Cookie') {
                    $parsed = [System.Uri]$Url
                    $parts = $HdrVal -split '=', 2
                    $ws.Cookies.Add((New-Object System.Net.Cookie($parts[0], $parts[1], '/', $parsed.Host)))
                }
                else {
                    $m = [System.Net.WebHeaderCollection].GetMethod(
                        'AddWithoutValidate',
                        [System.Reflection.BindingFlags]'Instance,NonPublic'
                    )
                    $m.Invoke($ws.Headers, @($HdrName, $HdrVal))
                }
                Invoke-RestMethod -Uri $Url -Method GET -WebSession $ws -ErrorAction Stop
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
        $vmMap   = @{}   # vmid -> @{ Name; IP; Node; Status; Cpus; MaxMem; MaxDisk }

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
            catch { Write-Warning "Could not query cluster status for node IPs." }

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
            catch { Write-Warning "Could not query node list." }

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
                            }
                        }
                    }
                }
                catch { Write-Warning "Could not query VMs on node ${node}." }
            }
        }

        Write-Verbose "Topology: $($nodeMap.Count) nodes, $($vmMap.Count) VMs"

        # ================================================================
        # Phase 2: Build template-based monitor plan
        # ================================================================
        # Each item carries device attributes. The setup script uses these
        # to create/find WUG devices and set attributes before syncing.
        # Monitor URLs use context variables — WUG resolves them per device.

        $baseAttrs = @{
            'Proxmox.ApiHost' = $apiHost
            'Proxmox.ApiPort' = $apiPort
            'DiscoveryHelper.Proxmox' = 'true'
            'DiscoveryHelper.Proxmox.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
        }

        # --- Cluster device (the API entry point) ---
        $clusterAttrs = $baseAttrs.Clone()
        $clusterAttrs['Proxmox.DeviceType'] = 'Cluster'

        $items += New-DiscoveredItem `
            -Name 'Proxmox - Cluster Status' `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                    = $tplClusterUrl
                RestApiMethod                 = 'GET'
                RestApiTimeoutMs              = 10000
                RestApiIgnoreCertErrors       = $ignoreCert
                RestApiUseAnonymous           = '1'
                RestApiCustomHeader           = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList         = '[]'
            } `
            -UniqueKey "Proxmox:cluster:active:status" `
            -Attributes $clusterAttrs `
            -Tags @('proxmox', 'cluster')

        $items += New-DiscoveredItem `
            -Name 'Proxmox - Node List' `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                    = $tplNodeListUrl
                RestApiMethod                 = 'GET'
                RestApiTimeoutMs              = 10000
                RestApiIgnoreCertErrors       = $ignoreCert
                RestApiUseAnonymous           = '1'
                RestApiCustomHeader           = $tplAuthHeader
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList         = '[]'
            } `
            -UniqueKey "Proxmox:cluster:active:nodelist" `
            -Attributes $clusterAttrs `
            -Tags @('proxmox', 'cluster')

        # --- Per-Node items ---
        foreach ($nodeName in @($nodeMap.Keys | Sort-Object)) {
            $nodeIP = $nodeMap[$nodeName]
            $nodeAttrs = $baseAttrs.Clone()
            $nodeAttrs['Proxmox.DeviceType'] = 'Node'
            $nodeAttrs['Proxmox.NodeName']   = $nodeName
            if ($nodeIP) { $nodeAttrs['Proxmox.NodeIP'] = $nodeIP }

            # Active monitor: shared "Proxmox - Node Status" assigned to each node
            $items += New-DiscoveredItem `
                -Name 'Proxmox - Node Status' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $tplNodeUrl
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 10000
                    RestApiIgnoreCertErrors       = $ignoreCert
                    RestApiUseAnonymous           = '1'
                    RestApiCustomHeader           = $tplAuthHeader
                    RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                    RestApiComparisonList         = '[]'
                } `
                -UniqueKey "Proxmox:node:${nodeName}:active:status" `
                -Attributes $nodeAttrs `
                -Tags @('proxmox', 'node', $nodeName, $(if ($nodeIP) { $nodeIP } else { 'no-ip' }))

            # Performance monitors: same template name per metric, created per device
            $nodePerfMonitors = @(
                @{ Name = 'Proxmox - Node CPU';          JsonPath = '$.data.cpu';          Key = 'cpu' }
                @{ Name = 'Proxmox - Node Memory Used';  JsonPath = '$.data.memory.used';  Key = 'memused' }
                @{ Name = 'Proxmox - Node Memory Total'; JsonPath = '$.data.memory.total'; Key = 'memtotal' }
                @{ Name = 'Proxmox - Node Disk Used';    JsonPath = '$.data.rootfs.used';  Key = 'diskused' }
                @{ Name = 'Proxmox - Node Disk Total';   JsonPath = '$.data.rootfs.total'; Key = 'disktotal' }
                @{ Name = 'Proxmox - Node Load Avg';     JsonPath = '$.data.loadavg[0]';   Key = 'loadavg' }
            )
            foreach ($pm in $nodePerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $tplNodeUrl
                        RestApiJsonPath           = $pm.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = 10000
                        RestApiIgnoreCertErrors   = $ignoreCert
                        RestApiUseAnonymousAccess = '1'
                        RestApiCustomHeader       = $tplAuthHeader
                    } `
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

            # Active monitor: shared "Proxmox - VM Status" assigned to each VM device
            $items += New-DiscoveredItem `
                -Name 'Proxmox - VM Status' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $tplVmUrl
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 10000
                    RestApiIgnoreCertErrors       = $ignoreCert
                    RestApiUseAnonymous           = '1'
                    RestApiCustomHeader           = $tplAuthHeader
                    RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                    RestApiComparisonList         = '[]'
                } `
                -UniqueKey "Proxmox:vm:${vmid}:active:status" `
                -Attributes $vmAttrs `
                -Tags @('proxmox', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmNode)

            $vmPerfMonitors = @(
                @{ Name = 'Proxmox - VM CPU';        JsonPath = '$.data.cpu';       Key = 'cpu' }
                @{ Name = 'Proxmox - VM Memory';     JsonPath = '$.data.mem';       Key = 'mem' }
                @{ Name = 'Proxmox - VM Net In';     JsonPath = '$.data.netin';     Key = 'netin' }
                @{ Name = 'Proxmox - VM Net Out';    JsonPath = '$.data.netout';    Key = 'netout' }
                @{ Name = 'Proxmox - VM Disk Read';  JsonPath = '$.data.diskread';  Key = 'diskread' }
                @{ Name = 'Proxmox - VM Disk Write'; JsonPath = '$.data.diskwrite'; Key = 'diskwrite' }
            )
            foreach ($pm in $vmPerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $tplVmUrl
                        RestApiJsonPath           = $pm.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = 10000
                        RestApiIgnoreCertErrors   = $ignoreCert
                        RestApiUseAnonymousAccess = '1'
                        RestApiCustomHeader       = $tplAuthHeader
                    } `
                    -UniqueKey "Proxmox:vm:${vmid}:perf:$($pm.Key)" `
                    -Attributes $vmAttrs `
                    -Tags @('proxmox', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmNode)
            }
        }

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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCt3tAf6jVIMs/K
# p14p35OLopeltPrUcvXPFjNW9kJsgKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgoedj92x8HAWZclKkbvBf8aG37WqppS1F
# L7GKr/FR2l0wDQYJKoZIhvcNAQEBBQAEggIA6pw5D3VdqDJUEOefGmi5YZZVCv4p
# 7fsHENIft7xwxNmH6Hcjk91/WinLevg4AARaVYD3lAApJ7O4+6p3r3PFvlIRtYB+
# BRweVf53rIoMOJIR4vLelmKyoj3qdlfCvtlEtLPX9kqr2fiiHzTKSdqFXidFB5x2
# iE5gRv7hM65W40/bcGFM1V6J8bkxBhxe8JR11o30PkAmJT2pmmDfbQ8IrDo74/Es
# +s26AoDgxxjMbFFYUGw4ZfrWkLHoLBACtxznS4guddSOLPjUiScrAFvQ4M1JnYn9
# a85XMEKwPX/HchxU0+Q/5qyVb1u4A1RSsuVrohvmAVshG4b4vPmtpjuFhlFk/hQv
# nvVNqE7yzriqlFt/3XmLUQSZjZhgSEXt9a8cvAn5in8TbQfy0J8TmVKhwrUSL5Oq
# sQlNyPxgjcLxaO/RzazZtf3v5nNhuXakF0xMMRxWGXODLdAmtuEgqIgnjnhmU61O
# 1PHBet1cjMq1c2c66kAnXKZAJjbAFJFzBLLLcvg1R1pnUmwx1NpU7G0F7wc3ox45
# OeyMVJlrpXFj557ehLc2Jno0qM/Gs/YDxX2RdbhY1s96fDBrEWys+cpiwqYgXpBo
# Qlo/M91+ckXPPpHgAEaVVRx4llrqf4BciII6zgyyAeVivLPAu2kZnLYlny5zu7WC
# i5f5kEsPCaAPrtA=
# SIG # End signature block
