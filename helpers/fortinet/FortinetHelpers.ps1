# =============================================================================
# FortinetHelpers.ps1 - Fortinet Helpers for WhatsUpGoldPS
# Uses the FortiOS REST API (FortiGate 6.0+) and FortiManager JSON-RPC API.
# No additional modules required - uses Invoke-RestMethod directly.
#
# Sections:
#   Core        - Authentication, API wrapper, HTML dashboard generator
#   System      - Status, resources, HA, firmware, license, admin accounts
#   Network     - Interfaces, zones, routing, ARP, DHCP, DNS
#   Firewall    - Policies, addresses, services, schedules, NAT, VIPs, shaping
#   VPN         - IPSec tunnels (live + config), SSL VPN sessions + settings
#   SD-WAN      - Members, health checks, rules, zones
#   Security    - AV, IPS, Web Filter, App Control, DLP, DNS Filter, SSL/SSH
#   User & Auth - Local users, groups, LDAP, RADIUS, active auth, FortiTokens
#   Wireless    - Managed APs, WiFi clients, rogue APs, SSIDs, AP profiles
#   Switch      - Managed switches, ports, VLANs, LLDP
#   Endpoint    - FortiClient EMS, security rating, endpoint profiles
#   Log         - Traffic/event/UTM logs, stats, FortiGuard, alerts
#   FortiManager- JSON-RPC auth, ADOMs, devices, policy packages
# =============================================================================

# ---------------------------------------------------------------------------
# Initialize-SSLBypass -- compiled C# callback for PS 5.1 cert bypass
# ---------------------------------------------------------------------------
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
}

# ---------------------------------------------------------------------------
# Script-scoped session state
# ---------------------------------------------------------------------------
$script:FortiSession = @{
    BaseUri    = $null
    Headers    = $null
    Cookie     = $null
    WebSession = $null
}
$script:FortiSkipCert = $false
$script:FortiManagerSession = @{
    BaseUri   = $null
    SessionId = $null
}

# ---------------------------------------------------------------------------
# Invoke-FortiAPI â€” central REST wrapper with retry logic
# ---------------------------------------------------------------------------
function Invoke-FortiAPI {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Body
    )

    $splat = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $script:FortiSession.Headers
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($Body) { $splat.Body = ($Body | ConvertTo-Json -Depth 10) }
    if ($script:FortiSession.Cookie) {
        $splat.WebSession = $script:FortiSession.WebSession
    }
    if ($script:FortiSkipCert) { $splat['SkipCertificateCheck'] = $true }

    $maxRetries = 2
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        try {
            return Invoke-RestMethod @splat
        }
        catch {
            $msg = $_.Exception.Message
            if (($msg -match 'underlying connection was closed|unexpected error occurred on a send') -and $attempt -lt $maxRetries) {
                Start-Sleep -Milliseconds (500 * ($attempt + 1))
            }
            else { throw }
        }
    }
}

# ---------------------------------------------------------------------------
# Connect-FortiGate
# ---------------------------------------------------------------------------
function Connect-FortiGate {
    <#
    .SYNOPSIS
        Authenticates to a FortiGate appliance via REST API.
    .DESCRIPTION
        Supports API Token (recommended) or Credential (username/password) auth.
    .PARAMETER Server
        FortiGate hostname or IP.
    .PARAMETER Port
        HTTPS port. Default 443.
    .PARAMETER ApiToken
        REST API admin token.
    .PARAMETER Credential
        PSCredential for username/password login.
    .PARAMETER IgnoreSSLErrors
        Skip certificate validation.
    .EXAMPLE
        Connect-FortiGate -Server "192.168.1.1" -ApiToken $token -IgnoreSSLErrors
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [int]$Port = 443,
        [string]$ApiToken,
        [PSCredential]$Credential,
        [switch]$IgnoreSSLErrors
    )

    if (-not $ApiToken -and -not $Credential) {
        throw "Provide either -ApiToken or -Credential."
    }

    if ($IgnoreSSLErrors) {
        Initialize-SSLBypass
        $script:FortiSkipCert = $true
    }

    $script:FortiSession.BaseUri = "https://${Server}:${Port}"

    if ($ApiToken) {
        $script:FortiSession.Headers = @{ 'Authorization' = "Bearer $ApiToken" }
        $script:FortiSession.Cookie = $null
        Write-Verbose "Authenticated to FortiGate $Server via API token."
    }
    else {
        $loginUri = "$($script:FortiSession.BaseUri)/logincheck"
        $formBody = "username=$([uri]::EscapeDataString($Credential.UserName))&secretkey=$([uri]::EscapeDataString($Credential.GetNetworkCredential().Password))"
        $loginSplat = @{
            Uri             = $loginUri
            Method          = 'POST'
            Body            = $formBody
            ContentType     = 'application/x-www-form-urlencoded'
            SessionVariable = 'fgtSession'
            ErrorAction     = 'Stop'
        }
        if ($script:FortiSkipCert) { $loginSplat['SkipCertificateCheck'] = $true }
        Invoke-RestMethod @loginSplat | Out-Null
        $formBody = $null

        $csrfToken = ($fgtSession.Cookies.GetCookies("$($script:FortiSession.BaseUri)") |
            Where-Object { $_.Name -eq 'ccsrftoken' }).Value -replace '"', ''

        $script:FortiSession.WebSession = $fgtSession
        $script:FortiSession.Headers = @{}
        if ($csrfToken) { $script:FortiSession.Headers['X-CSRFTOKEN'] = $csrfToken }
        $script:FortiSession.Cookie = $true
        Write-Verbose "Authenticated to FortiGate $Server via credentials."
    }

    $status = Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/status"
    Write-Verbose "Connected to: $($status.results.hostname) running FortiOS $($status.results.version)"
    return $status.results
}

# ---------------------------------------------------------------------------
# Disconnect-FortiGate
# ---------------------------------------------------------------------------
function Disconnect-FortiGate {
    <#
    .SYNOPSIS
        Logs out of a FortiGate session.
    #>
    [CmdletBinding()]
    param()

    if ($script:FortiSession.Cookie) {
        try {
            $splat = @{ Uri = "$($script:FortiSession.BaseUri)/logout"; Method = 'POST'; WebSession = $script:FortiSession.WebSession }
            if ($script:FortiSkipCert) { $splat['SkipCertificateCheck'] = $true }
            Invoke-RestMethod @splat | Out-Null
        }
        catch { Write-Verbose "Logout call failed: $_" }
    }
    $script:FortiSession = @{ BaseUri = $null; Headers = $null; Cookie = $null; WebSession = $null }
    $script:FortiSkipCert = $false
    Write-Verbose "FortiGate session cleared."
}

# ---------------------------------------------------------------------------
# New-FortinetDashboardHtml â€” Universal HTML generator
# ---------------------------------------------------------------------------
function New-FortinetDashboardHtml {
    <#
    .SYNOPSIS
        Generates a dark-themed Bootstrap Table HTML dashboard from structured data.
    .PARAMETER ReportTitle
        Title shown in the dashboard header.
    .PARAMETER SummaryCards
        Array of @{ Label='...'; Value='...' } for the top summary row.
    .PARAMETER Tables
        Array of @{ Id='...'; Title='...'; Columns=@(@{field='...';title='...'}, ...); Data=@(...) }.
    .PARAMETER OutputPath
        File path for the generated HTML.
    #>
    param(
        [Parameter(Mandatory)][string]$ReportTitle,
        [array]$SummaryCards = @(),
        [Parameter(Mandatory)][array]$Tables,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $templatePath = Join-Path $PSScriptRoot 'Fortinet-Dashboard-Template.html'
    if (-not (Test-Path $templatePath)) {
        throw "Dashboard template not found at $templatePath"
    }

    $config = @{
        title        = $ReportTitle
        generated    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        summaryCards = $SummaryCards
        tables       = $Tables
    }

    $configJson = $config | ConvertTo-Json -Depth 20 -Compress
    # Prevent XSS from data containing </script>
    $configJson = $configJson -replace '</script>', '<\/script>'

    $template = Get-Content $templatePath -Raw
    $html = $template.Replace('DASHBOARD_CONFIG_JSON', $configJson)

    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
    Write-Verbose "Dashboard exported to $OutputPath"
}

#region -- System ----------------------------------------------------------------

function Get-FortiGateSystemStatus {
    <#
    .SYNOPSIS  Returns system status (hostname, serial, firmware, uptime, HA mode).
    .EXAMPLE   Get-FortiGateSystemStatus
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/status").results
    [PSCustomObject]@{
        Hostname     = $r.hostname
        SerialNumber = $r.serial
        Version      = $r.version
        Build        = $r.build
        Model        = if ($r.model_name) { $r.model_name } else { $r.model }
        Uptime       = if ($r.uptime) { [TimeSpan]::FromSeconds($r.uptime).ToString('d\.hh\:mm\:ss') } else { 'N/A' }
        VDOM         = $r.current_vdom
        HAMode       = if ($r.ha_mode) { $r.ha_mode } else { 'Standalone' }
    }
}

function Get-FortiGateSystemResources {
    <#
    .SYNOPSIS  Returns current CPU, memory, disk, and session utilization.
    .EXAMPLE   Get-FortiGateSystemResources
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/resource/usage?interval=1-min").results
    [PSCustomObject]@{
        CPUPercent    = $r.cpu
        MemoryPercent = $r.mem
        DiskPercent   = $r.disk
        SessionCount  = $r.session
        SetupRate     = $r.setuprate
    }
}

function Get-FortiGateHAStatus {
    <#
    .SYNOPSIS  Returns HA cluster peer status and sync state.
    .EXAMPLE   Get-FortiGateHAStatus | Format-Table
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/ha-peer").results
    foreach ($peer in $r) {
        [PSCustomObject]@{
            Hostname    = $peer.hostname
            SerialNo    = $peer.serial_no
            Role        = if ($peer.is_root_primary -or $peer.is_management_master) { 'Primary' } else { 'Secondary' }
            Priority    = $peer.priority
            SyncStatus  = if ($peer.configuration_status -eq 1) { 'In-Sync' } else { 'Out-of-Sync' }
            Uptime      = if ($peer.uptime) { [TimeSpan]::FromSeconds($peer.uptime).ToString('d\.hh\:mm\:ss') } else { 'N/A' }
            Sessions    = $peer.sessions
        }
    }
}

function Get-FortiGateHAChecksums {
    <#
    .SYNOPSIS  Returns HA configuration checksums for each VDOM.
    .EXAMPLE   Get-FortiGateHAChecksums
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/ha-checksums").results
    foreach ($item in $r) {
        [PSCustomObject]@{
            SerialNo   = $item.serial_no
            IsManagementMaster = $item.is_management_master
            Checksums  = $item.checksums
        }
    }
}

function Get-FortiGateFirmware {
    <#
    .SYNOPSIS  Returns available firmware versions and current firmware info.
    .EXAMPLE   Get-FortiGateFirmware
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/firmware").results
    [PSCustomObject]@{
        CurrentVersion = $r.current
        Available      = $r.available
    }
}

function Get-FortiGateLicenseStatus {
    <#
    .SYNOPSIS  Returns license/subscription status for all FortiGuard services.
    .EXAMPLE   Get-FortiGateLicenseStatus
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/license/status").results
    $output = @()
    foreach ($prop in $r.PSObject.Properties) {
        $v = $prop.Value
        $output += [PSCustomObject]@{
            Service    = $prop.Name
            Status     = $v.status
            Version    = $v.version
            Type       = $v.type
            Expires    = $v.expires
            LastUpdate = $v.last_update
        }
    }
    $output
}

function Get-FortiGateGlobalSettings {
    <#
    .SYNOPSIS  Returns global system settings from /api/v2/cmdb/system/global.
    .EXAMPLE   Get-FortiGateGlobalSettings
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system/global").results
    [PSCustomObject]@{
        Hostname           = $r.hostname
        Timezone           = $r.timezone
        AdminSport         = $r.'admin-sport'
        AdminSSHPort       = $r.'admin-ssh-port'
        AdminLoginMax      = $r.'admin-login-max'
        AdminIdleTimeout   = $r.'admintimeout'
        Language           = $r.language
        GUITheme           = $r.'gui-theme'
        DailyRestart       = $r.'daily-restart'
        StrongCrypto       = $r.'strong-crypto'
        SSLMinVersion      = $r.'ssl-min-proto-version'
    }
}

function Get-FortiGateAdmins {
    <#
    .SYNOPSIS  Returns configured admin accounts.
    .EXAMPLE   Get-FortiGateAdmins
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system/admin").results
    foreach ($a in $r) {
        [PSCustomObject]@{
            Name       = $a.name
            AccProfile = $a.accprofile
            TwoFactor  = $a.'two-factor'
            FortiToken = $a.'fortitoken'
            TrustHost1 = $a.'trusthost1'
            TrustHost2 = $a.'trusthost2'
            Comments   = $a.comments
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateSystemDashboard {
    <#
    .SYNOPSIS  Aggregates all system monitoring data into a single object.
    .EXAMPLE   $d = Get-FortiGateSystemDashboard
    #>
    [CmdletBinding()] param()
    [PSCustomObject]@{
        Status      = Get-FortiGateSystemStatus
        Resources   = Get-FortiGateSystemResources
        HA          = $(try { @(Get-FortiGateHAStatus)  } catch { @() })
        HAChecksums = $(try { @(Get-FortiGateHAChecksums) } catch { @() })
        Firmware    = $(try {   Get-FortiGateFirmware    } catch { $null })
        License     = $(try { @(Get-FortiGateLicenseStatus) } catch { @() })
        Global      = $(try {   Get-FortiGateGlobalSettings } catch { $null })
        Admins      = $(try { @(Get-FortiGateAdmins)     } catch { @() })
    }
}

function Export-FortiGateSystemDashboardHtml {
    <#
    .SYNOPSIS  Exports a System dashboard HTML report.
    .PARAMETER DashboardData  Output of Get-FortiGateSystemDashboard.
    .PARAMETER OutputPath     HTML file path.
    .EXAMPLE   Export-FortiGateSystemDashboardHtml -DashboardData (Get-FortiGateSystemDashboard) -OutputPath "$env:TEMP\forti-system.html"
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate System Dashboard'
    )

    $s = $DashboardData.Status
    $res = $DashboardData.Resources
    $summary = @(
        @{ Label = 'Hostname';     Value = $s.Hostname }
        @{ Label = 'Model';        Value = $s.Model }
        @{ Label = 'Version';      Value = $s.Version }
        @{ Label = 'Serial';       Value = $s.SerialNumber }
        @{ Label = 'Uptime';       Value = $s.Uptime }
        @{ Label = 'HA Mode';      Value = $s.HAMode }
        @{ Label = 'CPU';          Value = "$($res.CPUPercent)%" }
        @{ Label = 'Memory';       Value = "$($res.MemoryPercent)%" }
        @{ Label = 'Disk';         Value = "$($res.DiskPercent)%" }
        @{ Label = 'Sessions';     Value = $res.SessionCount }
    )

    $tables = @()
    if ($DashboardData.HA.Count -gt 0) {
        $tables += @{
            Id = 'ha'; Title = 'HA Cluster Peers'
            Columns = @(
                @{field='Hostname';title='Hostname'}, @{field='SerialNo';title='Serial'},
                @{field='Role';title='Role'}, @{field='Priority';title='Priority'},
                @{field='SyncStatus';title='Sync'}, @{field='Uptime';title='Uptime'},
                @{field='Sessions';title='Sessions'}
            )
            Data = @($DashboardData.HA)
        }
    }
    if ($DashboardData.License.Count -gt 0) {
        $tables += @{
            Id = 'license'; Title = 'License / FortiGuard Services'
            Columns = @(
                @{field='Service';title='Service'}, @{field='Status';title='Status'},
                @{field='Version';title='Version'}, @{field='Type';title='Type'},
                @{field='Expires';title='Expires'}, @{field='LastUpdate';title='Last Update'}
            )
            Data = @($DashboardData.License)
        }
    }
    if ($DashboardData.Admins.Count -gt 0) {
        $tables += @{
            Id = 'admins'; Title = 'Admin Accounts'
            Columns = @(
                @{field='Name';title='Name'}, @{field='AccProfile';title='Profile'},
                @{field='TwoFactor';title='2FA'}, @{field='TrustHost1';title='Trusted Host 1'},
                @{field='TrustHost2';title='Trusted Host 2'}, @{field='Comments';title='Comments'}
            )
            Data = @($DashboardData.Admins)
        }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Network ---------------------------------------------------------------

function Get-FortiGateInterfaces {
    <#
    .SYNOPSIS  Returns all network interfaces with live status and traffic counters.
    .EXAMPLE   Get-FortiGateInterfaces | Where-Object Link -eq 'up'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/interface?include_vlan=true&include_aggregate=true").results
    foreach ($iface in $r.PSObject.Properties) {
        $v = $iface.Value
        [PSCustomObject]@{
            Name       = $iface.Name
            IP         = $v.ip
            Mask       = $v.mask
            Link       = $v.link
            Speed      = if ($v.speed -and $v.speed -ne 'n/a') { $v.speed } else { 'N/A' }
            Duplex     = if ($v.duplex) { $v.duplex } else { 'N/A' }
            TxBytes    = $v.tx_bytes
            RxBytes    = $v.rx_bytes
            TxPackets  = $v.tx_packets
            RxPackets  = $v.rx_packets
            TxErrors   = $v.tx_errors
            RxErrors   = $v.rx_errors
            Type       = $v.type
            VDOM       = $v.vdom
            Media      = $v.media
            MTU        = $v.mtu
        }
    }
}

function Get-FortiGateInterfaceConfig {
    <#
    .SYNOPSIS  Returns interface configuration objects from CMDB.
    .EXAMPLE   Get-FortiGateInterfaceConfig | Where-Object Mode -eq 'static'
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system/interface?vdom=$VDOM").results
    foreach ($i in $r) {
        [PSCustomObject]@{
            Name          = $i.name
            Type          = $i.type
            Mode          = $i.mode
            IP            = $i.ip
            Allowaccess   = $i.allowaccess
            Status        = $i.status
            VDOM          = $i.vdom
            DeviceIdent   = $i.'device-identification'
            Role          = $i.role
            Interface     = $i.interface
            VLANID        = $i.vlanid
            MTU           = $i.mtu
            Description   = $i.description
            Alias         = $i.alias
            Speed         = $i.speed
            DefaultGW     = $i.defaultgw
            DNS1          = $i.'dns-server-override'
            SecondaryIP   = $i.secondaryip
        }
    }
}

function Get-FortiGateZones {
    <#
    .SYNOPSIS  Returns configured zones.
    .EXAMPLE   Get-FortiGateZones
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system/zone?vdom=$VDOM").results
    foreach ($z in $r) {
        [PSCustomObject]@{
            Name             = $z.name
            IntraZoneTraffic = $z.intrazone
            Interfaces       = ($z.interface | ForEach-Object { $_.'interface-name' }) -join ', '
            Description      = $z.description
        }
    }
}

function Get-FortiGateRoutes {
    <#
    .SYNOPSIS  Returns the active IPv4 routing table.
    .EXAMPLE   Get-FortiGateRoutes | Where-Object Type -eq 'static'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/router/ipv4").results
    foreach ($rt in $r) {
        [PSCustomObject]@{
            Destination = $rt.ip_mask
            Gateway     = $rt.gateway
            Interface   = $rt.interface
            Type        = $rt.type
            Distance    = $rt.distance
            Metric      = $rt.metric
            Priority    = $rt.priority
            IsConnected = $rt.is_connected
        }
    }
}

function Get-FortiGateIPv6Routes {
    <#
    .SYNOPSIS  Returns the active IPv6 routing table.
    .EXAMPLE   Get-FortiGateIPv6Routes
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/router/ipv6").results
    foreach ($rt in $r) {
        [PSCustomObject]@{
            Destination = $rt.ip_mask
            Gateway     = $rt.gateway
            Interface   = $rt.interface
            Type        = $rt.type
            Distance    = $rt.distance
            Metric      = $rt.metric
        }
    }
}

function Get-FortiGateStaticRoutes {
    <#
    .SYNOPSIS  Returns configured static routes from CMDB.
    .EXAMPLE   Get-FortiGateStaticRoutes
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/router/static?vdom=$VDOM").results
    foreach ($rt in $r) {
        [PSCustomObject]@{
            SeqNum      = $rt.'seq-num'
            Status      = $rt.status
            Destination = $rt.dst
            Gateway     = $rt.gateway
            Device      = $rt.device
            Distance    = $rt.distance
            Weight      = $rt.weight
            Priority    = $rt.priority
            Comment     = $rt.comment
            Blackhole   = $rt.blackhole
            VWLService  = $rt.'virtual-wan-link'
            SDWAN       = $rt.sdwan
        }
    }
}

function Get-FortiGateARP {
    <#
    .SYNOPSIS  Returns the ARP table.
    .EXAMPLE   Get-FortiGateARP | Where-Object Interface -eq 'port1'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/arp").results
    foreach ($entry in $r) {
        [PSCustomObject]@{
            IP        = $entry.ip
            MAC       = $entry.mac
            Interface = $entry.interface
        }
    }
}

function Get-FortiGateDHCPLeases {
    <#
    .SYNOPSIS  Returns active DHCP leases from the FortiGate DHCP server.
    .EXAMPLE   Get-FortiGateDHCPLeases
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/dhcp").results
    foreach ($lease in $r) {
        [PSCustomObject]@{
            IP        = $lease.ip
            MAC       = $lease.mac
            Hostname  = $lease.hostname
            Interface = $lease.interface
            Status    = $lease.status
            Expire    = $lease.expire
            Type      = $lease.type
            ServerID  = $lease.server_id
            VDOM      = $lease.vdom
        }
    }
}

function Get-FortiGateDHCPServers {
    <#
    .SYNOPSIS  Returns DHCP server configuration.
    .EXAMPLE   Get-FortiGateDHCPServers
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system.dhcp/server?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            ID            = $s.id
            Status        = $s.status
            Interface     = $s.interface
            DefaultGateway = $s.'default-gateway'
            Netmask       = $s.netmask
            DNS1          = $s.'dns-server1'
            DNS2          = $s.'dns-server2'
            Domain        = $s.domain
            LeaseTime     = $s.'lease-time'
            IPRanges      = ($s.'ip-range' | ForEach-Object { "$($_.'start-ip') - $($_.'end-ip')" }) -join '; '
            ReservedAddr  = ($s.'reserved-address' | Measure-Object).Count
            WINSServer1   = $s.'wins-server1'
            NTPServer1    = $s.'ntp-server1'
        }
    }
}

function Get-FortiGateDNS {
    <#
    .SYNOPSIS  Returns DNS configuration.
    .EXAMPLE   Get-FortiGateDNS
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system/dns").results
    [PSCustomObject]@{
        Primary   = $r.primary
        Secondary = $r.secondary
        Protocol  = $r.protocol
        Domain    = $r.domain
        SSLCERT   = $r.'ssl-certificate'
        CacheLimit = $r.'cache-notfound-responses'
        DNSOverTLS = $r.'dns-over-tls'
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateNetworkDashboard {
    <#
    .SYNOPSIS  Aggregates all network data into a single object.
    .EXAMPLE   $d = Get-FortiGateNetworkDashboard
    #>
    [CmdletBinding()] param()
    [PSCustomObject]@{
        Interfaces      = $(try { @(Get-FortiGateInterfaces)      } catch { @() })
        InterfaceConfig = $(try { @(Get-FortiGateInterfaceConfig)  } catch { @() })
        Zones           = $(try { @(Get-FortiGateZones)            } catch { @() })
        Routes          = $(try { @(Get-FortiGateRoutes)           } catch { @() })
        IPv6Routes      = $(try { @(Get-FortiGateIPv6Routes)       } catch { @() })
        StaticRoutes    = $(try { @(Get-FortiGateStaticRoutes)     } catch { @() })
        ARP             = $(try { @(Get-FortiGateARP)              } catch { @() })
        DHCPLeases      = $(try { @(Get-FortiGateDHCPLeases)       } catch { @() })
        DHCPServers     = $(try { @(Get-FortiGateDHCPServers)      } catch { @() })
        DNS             = $(try {   Get-FortiGateDNS               } catch { $null })
    }
}

function Export-FortiGateNetworkDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Network Dashboard'
    )

    $upCount   = @($DashboardData.Interfaces | Where-Object Link -eq 'up').Count
    $downCount = @($DashboardData.Interfaces | Where-Object Link -eq 'down').Count
    $summary = @(
        @{ Label = 'Interfaces Up';   Value = $upCount }
        @{ Label = 'Interfaces Down'; Value = $downCount }
        @{ Label = 'Zones';           Value = $DashboardData.Zones.Count }
        @{ Label = 'Active Routes';   Value = $DashboardData.Routes.Count }
        @{ Label = 'Static Routes';   Value = $DashboardData.StaticRoutes.Count }
        @{ Label = 'ARP Entries';     Value = $DashboardData.ARP.Count }
        @{ Label = 'DHCP Leases';     Value = $DashboardData.DHCPLeases.Count }
        @{ Label = 'DNS Primary';     Value = if ($DashboardData.DNS) { $DashboardData.DNS.Primary } else { 'N/A' } }
    )

    $tables = @()
    if ($DashboardData.Interfaces.Count) {
        $tables += @{ Id='ifaces'; Title='Interfaces (Live Status)'; Columns=@(
            @{field='Name';title='Name'},@{field='IP';title='IP'},@{field='Mask';title='Mask'},
            @{field='Link';title='Link'},@{field='Speed';title='Speed'},@{field='Duplex';title='Duplex'},
            @{field='Type';title='Type'},@{field='TxBytes';title='TX Bytes'},@{field='RxBytes';title='RX Bytes'},
            @{field='TxPackets';title='TX Pkts'},@{field='RxPackets';title='RX Pkts'},
            @{field='TxErrors';title='TX Err'},@{field='RxErrors';title='RX Err'},@{field='VDOM';title='VDOM'}
        ); Data=@($DashboardData.Interfaces) }
    }
    if ($DashboardData.InterfaceConfig.Count) {
        $tables += @{ Id='ifcfg'; Title='Interface Configuration'; Columns=@(
            @{field='Name';title='Name'},@{field='Type';title='Type'},@{field='Mode';title='Mode'},
            @{field='IP';title='IP'},@{field='Allowaccess';title='Allow Access'},@{field='Status';title='Status'},
            @{field='Role';title='Role'},@{field='VLANID';title='VLAN'},@{field='MTU';title='MTU'},
            @{field='Description';title='Description'}
        ); Data=@($DashboardData.InterfaceConfig) }
    }
    if ($DashboardData.Zones.Count) {
        $tables += @{ Id='zones'; Title='Zones'; Columns=@(
            @{field='Name';title='Name'},@{field='IntraZoneTraffic';title='Intra-Zone'},
            @{field='Interfaces';title='Interfaces'},@{field='Description';title='Description'}
        ); Data=@($DashboardData.Zones) }
    }
    if ($DashboardData.Routes.Count) {
        $tables += @{ Id='routes'; Title='Active Routing Table (IPv4)'; Columns=@(
            @{field='Destination';title='Destination'},@{field='Gateway';title='Gateway'},
            @{field='Interface';title='Interface'},@{field='Type';title='Type'},
            @{field='Distance';title='Distance'},@{field='Metric';title='Metric'},@{field='Priority';title='Priority'}
        ); Data=@($DashboardData.Routes) }
    }
    if ($DashboardData.IPv6Routes.Count) {
        $tables += @{ Id='routes6'; Title='Active Routing Table (IPv6)'; Columns=@(
            @{field='Destination';title='Destination'},@{field='Gateway';title='Gateway'},
            @{field='Interface';title='Interface'},@{field='Type';title='Type'},
            @{field='Distance';title='Distance'},@{field='Metric';title='Metric'}
        ); Data=@($DashboardData.IPv6Routes) }
    }
    if ($DashboardData.StaticRoutes.Count) {
        $tables += @{ Id='static'; Title='Static Routes (CMDB)'; Columns=@(
            @{field='SeqNum';title='#'},@{field='Status';title='Status'},@{field='Destination';title='Destination'},
            @{field='Gateway';title='Gateway'},@{field='Device';title='Device'},
            @{field='Distance';title='Distance'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.StaticRoutes) }
    }
    if ($DashboardData.ARP.Count) {
        $tables += @{ Id='arp'; Title='ARP Table'; Columns=@(
            @{field='IP';title='IP'},@{field='MAC';title='MAC'},@{field='Interface';title='Interface'}
        ); Data=@($DashboardData.ARP) }
    }
    if ($DashboardData.DHCPLeases.Count) {
        $tables += @{ Id='dhcp'; Title='DHCP Leases'; Columns=@(
            @{field='IP';title='IP'},@{field='MAC';title='MAC'},@{field='Hostname';title='Hostname'},
            @{field='Interface';title='Interface'},@{field='Status';title='Status'},@{field='Expire';title='Expire'}
        ); Data=@($DashboardData.DHCPLeases) }
    }
    if ($DashboardData.DHCPServers.Count) {
        $tables += @{ Id='dhcpsrv'; Title='DHCP Servers'; Columns=@(
            @{field='ID';title='ID'},@{field='Status';title='Status'},@{field='Interface';title='Interface'},
            @{field='DefaultGateway';title='Gateway'},@{field='Netmask';title='Mask'},
            @{field='DNS1';title='DNS1'},@{field='LeaseTime';title='Lease(s)'},@{field='IPRanges';title='Ranges'}
        ); Data=@($DashboardData.DHCPServers) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Firewall --------------------------------------------------------------

function Get-FortiGateFirewallPolicies {
    <#
    .SYNOPSIS  Returns all IPv4 firewall policies.
    .PARAMETER VDOM  Virtual domain. Default 'root'.
    .EXAMPLE   Get-FortiGateFirewallPolicies | Where-Object Action -eq 'accept'
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/policy?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            PolicyID     = $p.policyid
            Name         = $p.name
            UUID         = $p.uuid
            SrcIntf      = ($p.srcintf  | ForEach-Object { $_.name }) -join ', '
            DstIntf      = ($p.dstintf  | ForEach-Object { $_.name }) -join ', '
            SrcAddr      = ($p.srcaddr  | ForEach-Object { $_.name }) -join ', '
            DstAddr      = ($p.dstaddr  | ForEach-Object { $_.name }) -join ', '
            Service      = ($p.service  | ForEach-Object { $_.name }) -join ', '
            Action       = $p.action
            NAT          = $p.nat
            Status       = $p.status
            LogTraffic   = $p.logtraffic
            Schedule     = $p.schedule
            AVProfile    = $p.'av-profile'
            IPSSensor    = $p.'ips-sensor'
            WebFilter    = $p.'webfilter-profile'
            AppList      = $p.'application-list'
            SSLSSHProfile = $p.'ssl-ssh-profile'
            UTMStatus    = $p.'utm-status'
            Comments     = $p.comments
        }
    }
}

function Get-FortiGateFirewallAddresses {
    <#
    .SYNOPSIS  Returns all firewall address objects.
    .EXAMPLE   Get-FortiGateFirewallAddresses | Where-Object Type -eq 'ipmask'
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/address?vdom=$VDOM").results
    foreach ($a in $r) {
        [PSCustomObject]@{
            Name       = $a.name
            UUID       = $a.uuid
            Type       = $a.type
            Subnet     = $a.subnet
            FQDN       = $a.fqdn
            StartIP    = $a.'start-ip'
            EndIP      = $a.'end-ip'
            Country    = $a.country
            Visibility = $a.visibility
            Color      = $a.color
            Comment    = $a.comment
            AssocIntf  = $a.'associated-interface'
            ObjType    = $a.'obj-type'
            FabricObj  = $a.'fabric-object'
        }
    }
}

function Get-FortiGateFirewallAddressGroups {
    <#
    .SYNOPSIS  Returns firewall address group objects.
    .EXAMPLE   Get-FortiGateFirewallAddressGroups
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/addrgrp?vdom=$VDOM").results
    foreach ($g in $r) {
        [PSCustomObject]@{
            Name       = $g.name
            UUID       = $g.uuid
            Members    = ($g.member | ForEach-Object { $_.name }) -join ', '
            Comment    = $g.comment
            Color      = $g.color
            Visibility = $g.visibility
            FabricObj  = $g.'fabric-object'
        }
    }
}

function Get-FortiGateFirewallServices {
    <#
    .SYNOPSIS  Returns custom service objects.
    .EXAMPLE   Get-FortiGateFirewallServices
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall.service/custom?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            Name         = $s.name
            Protocol     = $s.protocol
            TCPPortRange = $s.'tcp-portrange'
            UDPPortRange = $s.'udp-portrange'
            SCTPPortRange = $s.'sctp-portrange'
            ICMP         = if ($s.icmptype -ne '') { "type=$($s.icmptype) code=$($s.icmpcode)" } else { '' }
            Category     = $s.category
            Visibility   = $s.visibility
            Comment      = $s.comment
            Color        = $s.color
        }
    }
}

function Get-FortiGateFirewallServiceGroups {
    <#
    .SYNOPSIS  Returns service group objects.
    .EXAMPLE   Get-FortiGateFirewallServiceGroups
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall.service/group?vdom=$VDOM").results
    foreach ($g in $r) {
        [PSCustomObject]@{
            Name    = $g.name
            Members = ($g.member | ForEach-Object { $_.name }) -join ', '
            Comment = $g.comment
            Color   = $g.color
        }
    }
}

function Get-FortiGateFirewallSchedules {
    <#
    .SYNOPSIS  Returns recurring firewall schedule objects.
    .EXAMPLE   Get-FortiGateFirewallSchedules
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall.schedule/recurring?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            Name      = $s.name
            Start     = $s.start
            End       = $s.end
            Day       = $s.day
            Color     = $s.color
            FabricObj = $s.'fabric-object'
        }
    }
}

function Get-FortiGateFirewallIPPools {
    <#
    .SYNOPSIS  Returns IP pool objects (SNAT).
    .EXAMPLE   Get-FortiGateFirewallIPPools
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/ippool?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name       = $p.name
            Type       = $p.type
            StartIP    = $p.startip
            EndIP      = $p.endip
            SourceStartIP = $p.'source-startip'
            SourceEndIP   = $p.'source-endip'
            ARPReply   = $p.'arp-reply'
            Comments   = $p.comments
        }
    }
}

function Get-FortiGateFirewallVIPs {
    <#
    .SYNOPSIS  Returns Virtual IP objects (DNAT).
    .EXAMPLE   Get-FortiGateFirewallVIPs
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/vip?vdom=$VDOM").results
    foreach ($v in $r) {
        [PSCustomObject]@{
            Name       = $v.name
            UUID       = $v.uuid
            ExtIP      = $v.extip
            MappedIP   = ($v.mappedip | ForEach-Object { $_.range }) -join ', '
            ExtIntf    = $v.extintf
            Type       = $v.type
            PortFwd    = $v.portforward
            ExtPort    = $v.extport
            MappedPort = $v.mappedport
            Protocol   = $v.protocol
            Status     = $v.status
            Comment    = $v.comment
            Color      = $v.color
        }
    }
}

function Get-FortiGateFirewallShapingPolicies {
    <#
    .SYNOPSIS  Returns traffic shaping policies.
    .EXAMPLE   Get-FortiGateFirewallShapingPolicies
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/shaping-policy?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            ID            = $p.id
            Status        = $p.status
            SrcAddr       = ($p.srcaddr | ForEach-Object { $_.name }) -join ', '
            DstAddr       = ($p.dstaddr | ForEach-Object { $_.name }) -join ', '
            Service       = ($p.service | ForEach-Object { $_.name }) -join ', '
            SrcIntf       = ($p.srcintf | ForEach-Object { $_.name }) -join ', '
            DstIntf       = ($p.dstintf | ForEach-Object { $_.name }) -join ', '
            TrafficShaper = $p.'traffic-shaper'
            TrafficShaperReverse = $p.'traffic-shaper-reverse'
            PerIPShaper   = $p.'per-ip-shaper'
            Comment       = $p.comment
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateFirewallDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        Policies       = $(try { @(Get-FortiGateFirewallPolicies)        } catch { @() })
        Addresses      = $(try { @(Get-FortiGateFirewallAddresses)       } catch { @() })
        AddressGroups  = $(try { @(Get-FortiGateFirewallAddressGroups)   } catch { @() })
        Services       = $(try { @(Get-FortiGateFirewallServices)        } catch { @() })
        ServiceGroups  = $(try { @(Get-FortiGateFirewallServiceGroups)   } catch { @() })
        Schedules      = $(try { @(Get-FortiGateFirewallSchedules)       } catch { @() })
        IPPools        = $(try { @(Get-FortiGateFirewallIPPools)         } catch { @() })
        VIPs           = $(try { @(Get-FortiGateFirewallVIPs)            } catch { @() })
        ShapingPolicies = $(try { @(Get-FortiGateFirewallShapingPolicies)} catch { @() })
    }
}

function Export-FortiGateFirewallDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Firewall Dashboard'
    )

    $accept = @($DashboardData.Policies | Where-Object Action -eq 'accept').Count
    $deny   = @($DashboardData.Policies | Where-Object Action -eq 'deny').Count
    $summary = @(
        @{ Label = 'Total Policies';   Value = $DashboardData.Policies.Count }
        @{ Label = 'Accept';           Value = $accept }
        @{ Label = 'Deny';             Value = $deny }
        @{ Label = 'Addresses';        Value = $DashboardData.Addresses.Count }
        @{ Label = 'Address Groups';   Value = $DashboardData.AddressGroups.Count }
        @{ Label = 'Services';         Value = $DashboardData.Services.Count }
        @{ Label = 'IP Pools (SNAT)';  Value = $DashboardData.IPPools.Count }
        @{ Label = 'VIPs (DNAT)';      Value = $DashboardData.VIPs.Count }
    )

    $tables = @()
    if ($DashboardData.Policies.Count) {
        $tables += @{ Id='policies'; Title='Firewall Policies'; Columns=@(
            @{field='PolicyID';title='ID'},@{field='Name';title='Name'},@{field='Status';title='Status'},
            @{field='Action';title='Action'},@{field='SrcIntf';title='Src Intf'},@{field='DstIntf';title='Dst Intf'},
            @{field='SrcAddr';title='Src Addr'},@{field='DstAddr';title='Dst Addr'},@{field='Service';title='Service'},
            @{field='NAT';title='NAT'},@{field='LogTraffic';title='Log'},
            @{field='AVProfile';title='AV'},@{field='IPSSensor';title='IPS'},
            @{field='WebFilter';title='Web Filter'},@{field='Schedule';title='Schedule'},@{field='Comments';title='Comments'}
        ); Data=@($DashboardData.Policies) }
    }
    if ($DashboardData.Addresses.Count) {
        $tables += @{ Id='addrs'; Title='Firewall Addresses'; Columns=@(
            @{field='Name';title='Name'},@{field='Type';title='Type'},@{field='Subnet';title='Subnet'},
            @{field='FQDN';title='FQDN'},@{field='StartIP';title='Start IP'},@{field='EndIP';title='End IP'},
            @{field='Country';title='Country'},@{field='AssocIntf';title='Interface'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.Addresses) }
    }
    if ($DashboardData.AddressGroups.Count) {
        $tables += @{ Id='addrgrp'; Title='Address Groups'; Columns=@(
            @{field='Name';title='Name'},@{field='Members';title='Members'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.AddressGroups) }
    }
    if ($DashboardData.Services.Count) {
        $tables += @{ Id='svc'; Title='Service Objects'; Columns=@(
            @{field='Name';title='Name'},@{field='Protocol';title='Protocol'},
            @{field='TCPPortRange';title='TCP Ports'},@{field='UDPPortRange';title='UDP Ports'},
            @{field='Category';title='Category'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.Services) }
    }
    if ($DashboardData.ServiceGroups.Count) {
        $tables += @{ Id='svcgrp'; Title='Service Groups'; Columns=@(
            @{field='Name';title='Name'},@{field='Members';title='Members'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.ServiceGroups) }
    }
    if ($DashboardData.IPPools.Count) {
        $tables += @{ Id='ippool'; Title='IP Pools (SNAT)'; Columns=@(
            @{field='Name';title='Name'},@{field='Type';title='Type'},
            @{field='StartIP';title='Start IP'},@{field='EndIP';title='End IP'},
            @{field='ARPReply';title='ARP Reply'},@{field='Comments';title='Comments'}
        ); Data=@($DashboardData.IPPools) }
    }
    if ($DashboardData.VIPs.Count) {
        $tables += @{ Id='vips'; Title='Virtual IPs (DNAT)'; Columns=@(
            @{field='Name';title='Name'},@{field='ExtIP';title='External IP'},
            @{field='MappedIP';title='Mapped IP'},@{field='ExtIntf';title='Ext Interface'},
            @{field='PortFwd';title='Port Forward'},@{field='ExtPort';title='Ext Port'},
            @{field='MappedPort';title='Mapped Port'},@{field='Status';title='Status'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.VIPs) }
    }
    if ($DashboardData.ShapingPolicies.Count) {
        $tables += @{ Id='shaping'; Title='Traffic Shaping Policies'; Columns=@(
            @{field='ID';title='ID'},@{field='Status';title='Status'},
            @{field='SrcAddr';title='Src'},@{field='DstAddr';title='Dst'},@{field='Service';title='Service'},
            @{field='TrafficShaper';title='Shaper'},@{field='TrafficShaperReverse';title='Reverse Shaper'},
            @{field='Comment';title='Comment'}
        ); Data=@($DashboardData.ShapingPolicies) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- VPN -------------------------------------------------------------------

function Get-FortiGateIPSecTunnels {
    <#
    .SYNOPSIS  Returns live IPSec VPN tunnel status with Phase 2 SAs.
    .EXAMPLE   Get-FortiGateIPSecTunnels | Where-Object Status -eq 'up'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/vpn/ipsec").results
    foreach ($t in $r) {
        foreach ($p2 in $t.proxyid) {
            [PSCustomObject]@{
                TunnelName   = $t.name
                Phase2Name   = $p2.p2name
                Status       = $p2.status
                RemoteGW     = $t.rgwy
                InBytes      = $p2.incoming_bytes
                OutBytes     = $p2.outgoing_bytes
                LocalSubnet  = "$($p2.proxy_src)"
                RemoteSubnet = "$($p2.proxy_dst)"
                TunnelIP     = $t.tun_id
                Comments     = $t.comments
            }
        }
    }
}

function Get-FortiGateIPSecPhase1 {
    <#
    .SYNOPSIS  Returns IPSec Phase 1 interface configuration.
    .EXAMPLE   Get-FortiGateIPSecPhase1
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/vpn.ipsec/phase1-interface?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name           = $p.name
            Type           = $p.type
            Interface      = $p.interface
            IKEVersion     = $p.'ike-version'
            RemoteGW       = $p.'remote-gw'
            Proposal       = $p.proposal
            DHGroup        = $p.dhgrp
            AuthMethod     = $p.authmethod
            Mode           = $p.mode
            Keepalive      = $p.keepalive
            NATTraversal   = $p.nattraversal
            DPD            = $p.dpd
            DPDRetryCount  = $p.'dpd-retrycount'
            DPDRetryInterval = $p.'dpd-retryinterval'
            IdleTimeout    = $p.'idle-timeout'
            Comments       = $p.comments
        }
    }
}

function Get-FortiGateIPSecPhase2 {
    <#
    .SYNOPSIS  Returns IPSec Phase 2 interface configuration.
    .EXAMPLE   Get-FortiGateIPSecPhase2
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/vpn.ipsec/phase2-interface?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name          = $p.name
            Phase1Name    = $p.'phase1name'
            Proposal      = $p.proposal
            DHGroup       = $p.dhgrp
            PFS           = $p.pfs
            Replay        = $p.replay
            SrcSubnet     = $p.'src-subnet'
            DstSubnet     = $p.'dst-subnet'
            SrcAddrType   = $p.'src-addr-type'
            DstAddrType   = $p.'dst-addr-type'
            KeyLifeSeconds = $p.keylifeseconds
            Comments      = $p.comments
        }
    }
}

function Get-FortiGateSSLVPNSessions {
    <#
    .SYNOPSIS  Returns active SSL VPN sessions.
    .EXAMPLE   Get-FortiGateSSLVPNSessions
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/vpn/ssl").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            Index      = $s.index
            UserName   = $s.user_name
            RemoteHost = $s.remote_host
            TunnelIP   = if ($s.subsessions) { $s.subsessions[0].aip } else { '' }
            InBytes    = if ($s.subsessions) { $s.subsessions[0].in_bytes } else { 0 }
            OutBytes   = if ($s.subsessions) { $s.subsessions[0].out_bytes } else { 0 }
            Duration   = if ($s.subsessions -and $s.subsessions[0].duration) {
                [TimeSpan]::FromSeconds($s.subsessions[0].duration).ToString('d\.hh\:mm\:ss')
            } else { 'N/A' }
            LoginTime  = $s.login_time
        }
    }
}

function Get-FortiGateSSLVPNSettings {
    <#
    .SYNOPSIS  Returns SSL VPN server configuration.
    .EXAMPLE   Get-FortiGateSSLVPNSettings
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/vpn.ssl/settings?vdom=$VDOM").results
    [PSCustomObject]@{
        Status         = $r.status
        Port           = $r.port
        TunnelIPPools  = ($r.'tunnel-ip-pools' | ForEach-Object { $_.name }) -join ', '
        SourceInterface = ($r.'source-interface' | ForEach-Object { $_.name }) -join ', '
        SourceAddress  = ($r.'source-address' | ForEach-Object { $_.name }) -join ', '
        ServerCert     = $r.servercert
        Algorithm      = $r.algorithm
        IdleTimeout    = $r.'idle-timeout'
        AuthTimeout    = $r.'auth-timeout'
        LoginAttemptLimit = $r.'login-attempt-limit'
        LoginBlockTime = $r.'login-block-time'
        DTLSTunnel     = $r.'dtls-tunnel'
        DTLSMaxVersion = $r.'dtls-max-proto-ver'
        TunnelConnectWithoutReAuth = $r.'tunnel-connect-without-reauth'
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateVPNDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        IPSecTunnels   = $(try { @(Get-FortiGateIPSecTunnels)   } catch { @() })
        IPSecPhase1    = $(try { @(Get-FortiGateIPSecPhase1)    } catch { @() })
        IPSecPhase2    = $(try { @(Get-FortiGateIPSecPhase2)    } catch { @() })
        SSLVPNSessions = $(try { @(Get-FortiGateSSLVPNSessions) } catch { @() })
        SSLVPNSettings = $(try {   Get-FortiGateSSLVPNSettings  } catch { $null })
    }
}

function Export-FortiGateVPNDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate VPN Dashboard'
    )

    $ipsecUp   = @($DashboardData.IPSecTunnels | Where-Object Status -eq 'up').Count
    $ipsecDown = @($DashboardData.IPSecTunnels | Where-Object Status -eq 'down').Count
    $summary = @(
        @{ Label='IPSec Tunnels Up';   Value=$ipsecUp }
        @{ Label='IPSec Tunnels Down'; Value=$ipsecDown }
        @{ Label='Phase1 Configs';     Value=$DashboardData.IPSecPhase1.Count }
        @{ Label='Phase2 Configs';     Value=$DashboardData.IPSecPhase2.Count }
        @{ Label='SSL VPN Sessions';   Value=$DashboardData.SSLVPNSessions.Count }
    )

    $tables = @()
    if ($DashboardData.IPSecTunnels.Count) {
        $tables += @{ Id='ipsec'; Title='IPSec Tunnel Status'; Columns=@(
            @{field='TunnelName';title='Tunnel'},@{field='Phase2Name';title='Phase2'},@{field='Status';title='Status'},
            @{field='RemoteGW';title='Remote GW'},@{field='LocalSubnet';title='Local Net'},
            @{field='RemoteSubnet';title='Remote Net'},@{field='InBytes';title='In Bytes'},@{field='OutBytes';title='Out Bytes'}
        ); Data=@($DashboardData.IPSecTunnels) }
    }
    if ($DashboardData.IPSecPhase1.Count) {
        $tables += @{ Id='p1'; Title='IPSec Phase 1 Configuration'; Columns=@(
            @{field='Name';title='Name'},@{field='IKEVersion';title='IKE'},@{field='RemoteGW';title='Remote GW'},
            @{field='Interface';title='Interface'},@{field='Proposal';title='Proposal'},
            @{field='DHGroup';title='DH Group'},@{field='AuthMethod';title='Auth'},@{field='NATTraversal';title='NAT-T'},
            @{field='DPD';title='DPD'},@{field='Comments';title='Comments'}
        ); Data=@($DashboardData.IPSecPhase1) }
    }
    if ($DashboardData.IPSecPhase2.Count) {
        $tables += @{ Id='p2'; Title='IPSec Phase 2 Configuration'; Columns=@(
            @{field='Name';title='Name'},@{field='Phase1Name';title='Phase1'},
            @{field='Proposal';title='Proposal'},@{field='DHGroup';title='DH Group'},@{field='PFS';title='PFS'},
            @{field='SrcSubnet';title='Source'},@{field='DstSubnet';title='Destination'},
            @{field='KeyLifeSeconds';title='Key Life (s)'},@{field='Comments';title='Comments'}
        ); Data=@($DashboardData.IPSecPhase2) }
    }
    if ($DashboardData.SSLVPNSessions.Count) {
        $tables += @{ Id='sslsess'; Title='SSL VPN Active Sessions'; Columns=@(
            @{field='UserName';title='User'},@{field='RemoteHost';title='Remote Host'},
            @{field='TunnelIP';title='Tunnel IP'},@{field='Duration';title='Duration'},
            @{field='InBytes';title='In Bytes'},@{field='OutBytes';title='Out Bytes'},@{field='LoginTime';title='Login'}
        ); Data=@($DashboardData.SSLVPNSessions) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- SD-WAN ----------------------------------------------------------------

function Get-FortiGateSDWANMembers {
    <#
    .SYNOPSIS  Returns live SD-WAN member interface status (bandwidth, gateway, etc.).
    .EXAMPLE   Get-FortiGateSDWANMembers
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/sdwan/members").results
    foreach ($m in $r) {
        [PSCustomObject]@{
            Interface    = $m.interface
            Zone         = $m.zone
            Status       = $m.status
            Gateway      = $m.gateway
            Priority     = $m.priority
            Weight       = $m.weight
            Cost         = $m.cost
            InBandwidth  = $m.bi_bandwidth_in
            OutBandwidth = $m.bi_bandwidth_out
            VolumeRatio  = $m.volume_ratio
        }
    }
}

function Get-FortiGateSDWANHealthCheck {
    <#
    .SYNOPSIS  Returns SD-WAN health check results per member link.
    .EXAMPLE   Get-FortiGateSDWANHealthCheck | Where-Object Status -ne 'alive'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/sdwan/health-check").results
    foreach ($hc in $r) {
        foreach ($link in $hc.members) {
            [PSCustomObject]@{
                HealthCheck = $hc.name
                Interface   = $link.interface
                Status      = $link.status
                Latency     = $link.latency
                Jitter      = $link.jitter
                PacketLoss  = $link.packet_loss
                SLA         = $link.sla_met
                Target      = $hc.server
            }
        }
    }
}

function Get-FortiGateSDWANConfig {
    <#
    .SYNOPSIS  Returns SD-WAN member configuration from CMDB.
    .EXAMPLE   Get-FortiGateSDWANConfig
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system.sdwan/members?vdom=$VDOM").results
    foreach ($m in $r) {
        [PSCustomObject]@{
            SeqNum     = $m.'seq-num'
            Interface  = $m.interface
            Zone       = $m.zone
            Gateway    = $m.gateway
            Cost       = $m.cost
            Weight     = $m.weight
            Priority   = $m.priority
            Status     = $m.status
            Comment    = $m.comment
        }
    }
}

function Get-FortiGateSDWANHealthCheckConfig {
    <#
    .SYNOPSIS  Returns SD-WAN health check configuration.
    .EXAMPLE   Get-FortiGateSDWANHealthCheckConfig
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system.sdwan/health-check?vdom=$VDOM").results
    foreach ($hc in $r) {
        [PSCustomObject]@{
            Name        = $hc.name
            Server      = $hc.server
            Protocol    = $hc.protocol
            Port        = $hc.port
            Interval    = $hc.interval
            FailTime    = $hc.failtime
            RecoverTime = $hc.recovertime
            Members     = ($hc.members | ForEach-Object { $_.'seq-num' }) -join ', '
            ThresholdLatency    = $hc.'threshold-warning-latency'
            ThresholdJitter     = $hc.'threshold-warning-jitter'
            ThresholdPacketLoss = $hc.'threshold-warning-packetloss'
        }
    }
}

function Get-FortiGateSDWANRules {
    <#
    .SYNOPSIS  Returns SD-WAN service rules (traffic steering).
    .EXAMPLE   Get-FortiGateSDWANRules
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system.sdwan/service?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            ID          = $s.id
            Name        = $s.name
            Status      = $s.status
            Mode        = $s.mode
            Src         = ($s.src | ForEach-Object { $_.name }) -join ', '
            Dst         = ($s.dst | ForEach-Object { $_.name }) -join ', '
            Protocol    = $s.protocol
            HealthCheck = ($s.'health-check' | ForEach-Object { $_.name }) -join ', '
            Members     = ($s.'priority-members' | ForEach-Object { $_.'seq-num' }) -join ', '
            TieBreak    = $s.'tie-break'
            Comment     = $s.comment
        }
    }
}

function Get-FortiGateSDWANZones {
    <#
    .SYNOPSIS  Returns SD-WAN zone configuration.
    .EXAMPLE   Get-FortiGateSDWANZones
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/system.sdwan/zone?vdom=$VDOM").results
    foreach ($z in $r) {
        [PSCustomObject]@{
            Name              = $z.name
            ServiceSlaCheck   = $z.'service-sla-tie-break'
            MinimumSlaMembers = $z.'minimum-sla-meet-members'
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateSDWANDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        Members          = $(try { @(Get-FortiGateSDWANMembers)           } catch { @() })
        HealthChecks     = $(try { @(Get-FortiGateSDWANHealthCheck)       } catch { @() })
        MemberConfig     = $(try { @(Get-FortiGateSDWANConfig)            } catch { @() })
        HealthCheckConfig = $(try { @(Get-FortiGateSDWANHealthCheckConfig)} catch { @() })
        Rules            = $(try { @(Get-FortiGateSDWANRules)             } catch { @() })
        Zones            = $(try { @(Get-FortiGateSDWANZones)             } catch { @() })
    }
}

function Export-FortiGateSDWANDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate SD-WAN Dashboard'
    )

    $summary = @(
        @{ Label='Members';       Value=$DashboardData.Members.Count }
        @{ Label='Health Checks';  Value=$DashboardData.HealthChecks.Count }
        @{ Label='SD-WAN Rules';   Value=$DashboardData.Rules.Count }
        @{ Label='Zones';          Value=$DashboardData.Zones.Count }
    )

    $tables = @()
    if ($DashboardData.Members.Count) {
        $tables += @{ Id='members'; Title='SD-WAN Member Status (Live)'; Columns=@(
            @{field='Interface';title='Interface'},@{field='Zone';title='Zone'},@{field='Status';title='Status'},
            @{field='Gateway';title='Gateway'},@{field='Priority';title='Priority'},@{field='Weight';title='Weight'},
            @{field='Cost';title='Cost'},@{field='InBandwidth';title='In BW'},@{field='OutBandwidth';title='Out BW'}
        ); Data=@($DashboardData.Members) }
    }
    if ($DashboardData.HealthChecks.Count) {
        $tables += @{ Id='hc'; Title='Health Check Results (Live)'; Columns=@(
            @{field='HealthCheck';title='Check'},@{field='Interface';title='Interface'},@{field='Status';title='Status'},
            @{field='Latency';title='Latency'},@{field='Jitter';title='Jitter'},@{field='PacketLoss';title='Loss'},
            @{field='SLA';title='SLA Met'},@{field='Target';title='Target'}
        ); Data=@($DashboardData.HealthChecks) }
    }
    if ($DashboardData.MemberConfig.Count) {
        $tables += @{ Id='mcfg'; Title='Member Configuration'; Columns=@(
            @{field='SeqNum';title='#'},@{field='Interface';title='Interface'},@{field='Zone';title='Zone'},
            @{field='Gateway';title='Gateway'},@{field='Cost';title='Cost'},@{field='Weight';title='Weight'},
            @{field='Priority';title='Priority'},@{field='Status';title='Status'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.MemberConfig) }
    }
    if ($DashboardData.HealthCheckConfig.Count) {
        $tables += @{ Id='hccfg'; Title='Health Check Configuration'; Columns=@(
            @{field='Name';title='Name'},@{field='Server';title='Server'},@{field='Protocol';title='Protocol'},
            @{field='Port';title='Port'},@{field='Interval';title='Interval'},@{field='FailTime';title='Fail Time'},
            @{field='RecoverTime';title='Recover Time'},@{field='Members';title='Members'}
        ); Data=@($DashboardData.HealthCheckConfig) }
    }
    if ($DashboardData.Rules.Count) {
        $tables += @{ Id='rules'; Title='SD-WAN Service Rules'; Columns=@(
            @{field='ID';title='ID'},@{field='Name';title='Name'},@{field='Status';title='Status'},
            @{field='Mode';title='Mode'},@{field='Src';title='Source'},@{field='Dst';title='Destination'},
            @{field='Protocol';title='Protocol'},@{field='HealthCheck';title='Health Check'},
            @{field='Members';title='Members'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.Rules) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Security Profiles -----------------------------------------------------

function Get-FortiGateAntivirusProfiles {
    <#
    .SYNOPSIS  Returns all antivirus profiles.
    .EXAMPLE   Get-FortiGateAntivirusProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/antivirus/profile?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name               = $p.name
            Comment            = $p.comment
            HTTP               = $p.http.status
            FTP                = $p.ftp.status
            IMAP               = $p.imap.status
            POP3               = $p.pop3.status
            SMTP               = $p.smtp.status
            CIFS               = $p.cifs.status
            SSH                = $p.ssh.status
            InspectionMode     = $p.'inspection-mode'
            FTGDAnalytics      = $p.'ftgd-analytics'
            AnalyticsMaxUpload = $p.'analytics-max-upload'
            ScanMode           = $p.'scan-mode'
        }
    }
}

function Get-FortiGateIPSSensors {
    <#
    .SYNOPSIS  Returns all IPS sensor profiles.
    .EXAMPLE   Get-FortiGateIPSSensors
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/ips/sensor?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            Name         = $s.name
            Comment      = $s.comment
            EntriesCount = if ($s.entries) { ($s.entries | Measure-Object).Count } else { 0 }
            BlockMalURL  = $s.'block-malicious-url'
            ScanBotnet   = $s.'scan-botnet-connections'
        }
    }
}

function Get-FortiGateWebFilterProfiles {
    <#
    .SYNOPSIS  Returns all web filter profiles.
    .EXAMPLE   Get-FortiGateWebFilterProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/webfilter/profile?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name             = $p.name
            Comment          = $p.comment
            InspectionMode   = $p.'inspection-mode'
            HTTPSReplacemsg  = $p.'https-replacemsg'
            WebFTGD          = if ($p.ftgd_wf) { $p.ftgd_wf.options } else { '' }
            SafeSearch       = $p.'safe-search'
            YouTubeRestrict  = $p.'youtube-restrict'
            LogAllURL        = $p.'log-all-url'
            WebContentLog    = $p.'web-content-log'
            WebFilterLog     = $p.'web-filter-activex-log'
        }
    }
}

function Get-FortiGateAppControlProfiles {
    <#
    .SYNOPSIS  Returns all application control profiles.
    .EXAMPLE   Get-FortiGateAppControlProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/application/list?vdom=$VDOM").results
    foreach ($a in $r) {
        [PSCustomObject]@{
            Name             = $a.name
            Comment          = $a.comment
            EntriesCount     = if ($a.entries) { ($a.entries | Measure-Object).Count } else { 0 }
            DeepAppInspect   = $a.'deep-app-inspection'
            UnknownAppAction = $a.'unknown-application-action'
            UnknownAppLog    = $a.'unknown-application-log'
            Options          = $a.options
        }
    }
}

function Get-FortiGateDLPSensors {
    <#
    .SYNOPSIS  Returns all DLP (Data Loss Prevention) sensors.
    .EXAMPLE   Get-FortiGateDLPSensors
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/dlp/sensor?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            Name         = $s.name
            Comment      = $s.comment
            EntriesCount = if ($s.entries) { ($s.entries | Measure-Object).Count } else { 0 }
            FullArchive  = $s.'full-archive-proto'
            Summary      = $s.'summary-proto'
        }
    }
}

function Get-FortiGateDNSFilterProfiles {
    <#
    .SYNOPSIS  Returns all DNS filter profiles.
    .EXAMPLE   Get-FortiGateDNSFilterProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/dnsfilter/profile?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name           = $p.name
            Comment        = $p.comment
            BlockBotnet    = $p.'block-botnet'
            BlockAction    = $p.'block-action'
            SafeSearch     = $p.'safe-search'
            YouTubeRestrict = $p.'youtube-restrict'
            RedirectPortal = $p.'redirect-portal'
            LogAllDomain   = $p.'log-all-domain'
        }
    }
}

function Get-FortiGateSSLSSHProfiles {
    <#
    .SYNOPSIS  Returns SSL/SSH inspection profiles.
    .EXAMPLE   Get-FortiGateSSLSSHProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/firewall/ssl-ssh-profile?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name          = $p.name
            Comment       = $p.comment
            HTTPS         = if ($p.https) { $p.https.status } else { '' }
            SMTPS         = if ($p.smtps) { $p.smtps.status } else { '' }
            IMAPS         = if ($p.imaps) { $p.imaps.status } else { '' }
            POP3S         = if ($p.pop3s) { $p.pop3s.status } else { '' }
            FTPS          = if ($p.ftps)  { $p.ftps.status  } else { '' }
            SSH           = if ($p.ssh)   { $p.ssh.status   } else { '' }
            CACert        = $p.'server-cert'
            UntrustedCACert = $p.'untrusted-caname'
            MAPIOverHTTPS = $p.'mapi-over-https'
            RPC           = $p.'rpc-over-https'
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateSecurityDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        Antivirus   = $(try { @(Get-FortiGateAntivirusProfiles)  } catch { @() })
        IPS         = $(try { @(Get-FortiGateIPSSensors)         } catch { @() })
        WebFilter   = $(try { @(Get-FortiGateWebFilterProfiles)  } catch { @() })
        AppControl  = $(try { @(Get-FortiGateAppControlProfiles) } catch { @() })
        DLP         = $(try { @(Get-FortiGateDLPSensors)         } catch { @() })
        DNSFilter   = $(try { @(Get-FortiGateDNSFilterProfiles)  } catch { @() })
        SSLSSH      = $(try { @(Get-FortiGateSSLSSHProfiles)     } catch { @() })
    }
}

function Export-FortiGateSecurityDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Security Profiles Dashboard'
    )

    $summary = @(
        @{ Label='Antivirus Profiles'; Value=$DashboardData.Antivirus.Count }
        @{ Label='IPS Sensors';        Value=$DashboardData.IPS.Count }
        @{ Label='Web Filter';         Value=$DashboardData.WebFilter.Count }
        @{ Label='App Control';        Value=$DashboardData.AppControl.Count }
        @{ Label='DLP Sensors';        Value=$DashboardData.DLP.Count }
        @{ Label='DNS Filter';         Value=$DashboardData.DNSFilter.Count }
        @{ Label='SSL/SSH Profiles';   Value=$DashboardData.SSLSSH.Count }
    )

    $tables = @()
    if ($DashboardData.Antivirus.Count) {
        $tables += @{ Id='av'; Title='Antivirus Profiles'; Columns=@(
            @{field='Name';title='Name'},@{field='HTTP';title='HTTP'},@{field='FTP';title='FTP'},
            @{field='IMAP';title='IMAP'},@{field='POP3';title='POP3'},@{field='SMTP';title='SMTP'},
            @{field='InspectionMode';title='Mode'},@{field='ScanMode';title='Scan'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.Antivirus) }
    }
    if ($DashboardData.IPS.Count) {
        $tables += @{ Id='ips'; Title='IPS Sensors'; Columns=@(
            @{field='Name';title='Name'},@{field='EntriesCount';title='Rules'},
            @{field='BlockMalURL';title='Block Mal URL'},@{field='ScanBotnet';title='Scan Botnet'},
            @{field='Comment';title='Comment'}
        ); Data=@($DashboardData.IPS) }
    }
    if ($DashboardData.WebFilter.Count) {
        $tables += @{ Id='wf'; Title='Web Filter Profiles'; Columns=@(
            @{field='Name';title='Name'},@{field='InspectionMode';title='Mode'},
            @{field='SafeSearch';title='Safe Search'},@{field='YouTubeRestrict';title='YouTube'},
            @{field='LogAllURL';title='Log All'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.WebFilter) }
    }
    if ($DashboardData.AppControl.Count) {
        $tables += @{ Id='app'; Title='Application Control Profiles'; Columns=@(
            @{field='Name';title='Name'},@{field='EntriesCount';title='Entries'},
            @{field='DeepAppInspect';title='Deep Inspect'},@{field='UnknownAppAction';title='Unknown Action'},
            @{field='Options';title='Options'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.AppControl) }
    }
    if ($DashboardData.DLP.Count) {
        $tables += @{ Id='dlp'; Title='DLP Sensors'; Columns=@(
            @{field='Name';title='Name'},@{field='EntriesCount';title='Rules'},
            @{field='FullArchive';title='Full Archive'},@{field='Summary';title='Summary'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.DLP) }
    }
    if ($DashboardData.DNSFilter.Count) {
        $tables += @{ Id='dns'; Title='DNS Filter Profiles'; Columns=@(
            @{field='Name';title='Name'},@{field='BlockBotnet';title='Block Botnet'},
            @{field='SafeSearch';title='Safe Search'},@{field='YouTubeRestrict';title='YouTube'},
            @{field='LogAllDomain';title='Log All'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.DNSFilter) }
    }
    if ($DashboardData.SSLSSH.Count) {
        $tables += @{ Id='ssl'; Title='SSL/SSH Inspection Profiles'; Columns=@(
            @{field='Name';title='Name'},@{field='HTTPS';title='HTTPS'},@{field='SMTPS';title='SMTPS'},
            @{field='IMAPS';title='IMAPS'},@{field='POP3S';title='POP3S'},@{field='FTPS';title='FTPS'},
            @{field='SSH';title='SSH'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.SSLSSH) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- User & Auth -----------------------------------------------------------

function Get-FortiGateLocalUsers {
    <#
    .SYNOPSIS  Returns local user accounts.
    .EXAMPLE   Get-FortiGateLocalUsers
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/user/local?vdom=$VDOM").results
    foreach ($u in $r) {
        [PSCustomObject]@{
            Name         = $u.name
            Status       = $u.status
            Type         = $u.type
            TwoFactor    = $u.'two-factor'
            FortiToken   = $u.'fortitoken'
            EmailTo      = $u.'email-to'
            SMSPhone     = $u.'sms-phone'
            AuthConcurrent = $u.'auth-concurrent-override'
            LDAPServer   = $u.'ldap-server'
            RADIUSServer = $u.'radius-server'
        }
    }
}

function Get-FortiGateUserGroups {
    <#
    .SYNOPSIS  Returns user groups.
    .EXAMPLE   Get-FortiGateUserGroups
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/user/group?vdom=$VDOM").results
    foreach ($g in $r) {
        [PSCustomObject]@{
            Name         = $g.name
            GroupType    = $g.'group-type'
            Members      = ($g.member | ForEach-Object { $_.name }) -join ', '
            AuthType     = $g.'auth-concurrent-override'
            MatchType    = ($g.match | ForEach-Object { "$($_.'server-name'):$($_.'group-name')" }) -join '; '
            SSO          = $g.sso
        }
    }
}

function Get-FortiGateLDAPServers {
    <#
    .SYNOPSIS  Returns configured LDAP server connections.
    .EXAMPLE   Get-FortiGateLDAPServers
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/user/ldap?vdom=$VDOM").results
    foreach ($l in $r) {
        [PSCustomObject]@{
            Name         = $l.name
            Server       = $l.server
            SecondaryServer = $l.'secondary-server'
            Port         = $l.port
            Secure       = $l.secure
            CNID         = $l.cnid
            DN           = $l.dn
            Type         = $l.type
            Username     = $l.username
            GroupFilter  = $l.'group-filter'
            MemberAttr   = $l.'group-member-check'
            CACert       = $l.'ca-cert'
        }
    }
}

function Get-FortiGateRADIUSServers {
    <#
    .SYNOPSIS  Returns configured RADIUS servers.
    .EXAMPLE   Get-FortiGateRADIUSServers
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/user/radius?vdom=$VDOM").results
    foreach ($rs in $r) {
        [PSCustomObject]@{
            Name               = $rs.name
            Server             = $rs.server
            SecondaryServer    = $rs.'secondary-server'
            AuthType           = $rs.'auth-type'
            NASIPAddr          = $rs.'nas-ip'
            AcctInterimInterval = $rs.'acct-interim-interval'
            AllUsergroup       = $rs.'all-usergroup'
            UseManagementVDOM  = $rs.'use-management-vdom'
        }
    }
}

function Get-FortiGateActiveAuthUsers {
    <#
    .SYNOPSIS  Returns currently authenticated firewall users.
    .EXAMPLE   Get-FortiGateActiveAuthUsers
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/user/firewall").results
    foreach ($u in $r) {
        [PSCustomObject]@{
            UserName  = $u.user
            SrcIP     = $u.ip
            Type      = $u.type
            Method    = $u.method
            Server    = $u.server
            Group     = $u.group
            Duration  = $u.duration
            TrafficVol = $u.traffic_vol
        }
    }
}

function Get-FortiGateFortiTokens {
    <#
    .SYNOPSIS  Returns FortiToken status.
    .EXAMPLE   Get-FortiGateFortiTokens
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/user/fortitoken?vdom=$VDOM").results
    foreach ($t in $r) {
        [PSCustomObject]@{
            SerialNumber = $t.'serial-number'
            Status       = $t.status
            Seed         = $t.seed
            Comments     = $t.comments
            License      = $t.license
            ActivationCode = $t.'activation-code'
        }
    }
}

function Get-FortiGateSAMLSP {
    <#
    .SYNOPSIS  Returns SAML service provider configuration.
    .EXAMPLE   Get-FortiGateSAMLSP
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/user/saml?vdom=$VDOM").results
    foreach ($s in $r) {
        [PSCustomObject]@{
            Name       = $s.name
            EntityID   = $s.'entity-id'
            SSOURL     = $s.'idp-single-sign-on-url'
            Cert       = $s.cert
            UserName   = $s.'user-name'
            GroupName  = $s.'group-name'
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateUserAuthDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        LocalUsers    = $(try { @(Get-FortiGateLocalUsers)      } catch { @() })
        UserGroups    = $(try { @(Get-FortiGateUserGroups)       } catch { @() })
        LDAPServers   = $(try { @(Get-FortiGateLDAPServers)      } catch { @() })
        RADIUSServers = $(try { @(Get-FortiGateRADIUSServers)    } catch { @() })
        ActiveUsers   = $(try { @(Get-FortiGateActiveAuthUsers)  } catch { @() })
        FortiTokens   = $(try { @(Get-FortiGateFortiTokens)      } catch { @() })
        SAML          = $(try { @(Get-FortiGateSAMLSP)           } catch { @() })
    }
}

function Export-FortiGateUserAuthDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate User & Auth Dashboard'
    )

    $summary = @(
        @{ Label='Local Users';    Value=$DashboardData.LocalUsers.Count }
        @{ Label='User Groups';    Value=$DashboardData.UserGroups.Count }
        @{ Label='LDAP Servers';   Value=$DashboardData.LDAPServers.Count }
        @{ Label='RADIUS Servers'; Value=$DashboardData.RADIUSServers.Count }
        @{ Label='Active Auth';    Value=$DashboardData.ActiveUsers.Count }
        @{ Label='FortiTokens';    Value=$DashboardData.FortiTokens.Count }
    )

    $tables = @()
    if ($DashboardData.ActiveUsers.Count) {
        $tables += @{ Id='active'; Title='Currently Authenticated Users'; Columns=@(
            @{field='UserName';title='User'},@{field='SrcIP';title='Source IP'},@{field='Type';title='Type'},
            @{field='Method';title='Method'},@{field='Server';title='Server'},@{field='Group';title='Group'},
            @{field='Duration';title='Duration'},@{field='TrafficVol';title='Traffic'}
        ); Data=@($DashboardData.ActiveUsers) }
    }
    if ($DashboardData.LocalUsers.Count) {
        $tables += @{ Id='local'; Title='Local Users'; Columns=@(
            @{field='Name';title='Name'},@{field='Status';title='Status'},@{field='Type';title='Type'},
            @{field='TwoFactor';title='2FA'},@{field='FortiToken';title='Token'},
            @{field='EmailTo';title='Email'},@{field='LDAPServer';title='LDAP'},@{field='RADIUSServer';title='RADIUS'}
        ); Data=@($DashboardData.LocalUsers) }
    }
    if ($DashboardData.UserGroups.Count) {
        $tables += @{ Id='groups'; Title='User Groups'; Columns=@(
            @{field='Name';title='Name'},@{field='GroupType';title='Type'},
            @{field='Members';title='Members'},@{field='MatchType';title='Match'}
        ); Data=@($DashboardData.UserGroups) }
    }
    if ($DashboardData.LDAPServers.Count) {
        $tables += @{ Id='ldap'; Title='LDAP Servers'; Columns=@(
            @{field='Name';title='Name'},@{field='Server';title='Server'},@{field='Port';title='Port'},
            @{field='Secure';title='Secure'},@{field='DN';title='Base DN'},@{field='Type';title='Type'}
        ); Data=@($DashboardData.LDAPServers) }
    }
    if ($DashboardData.RADIUSServers.Count) {
        $tables += @{ Id='radius'; Title='RADIUS Servers'; Columns=@(
            @{field='Name';title='Name'},@{field='Server';title='Server'},
            @{field='AuthType';title='Auth Type'},@{field='NASIPAddr';title='NAS IP'}
        ); Data=@($DashboardData.RADIUSServers) }
    }
    if ($DashboardData.FortiTokens.Count) {
        $tables += @{ Id='tokens'; Title='FortiTokens'; Columns=@(
            @{field='SerialNumber';title='Serial'},@{field='Status';title='Status'},
            @{field='License';title='License'},@{field='Comments';title='Comments'}
        ); Data=@($DashboardData.FortiTokens) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Wireless --------------------------------------------------------------

function Get-FortiGateManagedAPs {
    <#
    .SYNOPSIS  Returns FortiAP devices managed by the FortiGate WiFi controller.
    .EXAMPLE   Get-FortiGateManagedAPs | Where-Object ConnectionState -eq 'Connected'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/wifi/managed_ap").results
    foreach ($ap in $r) {
        [PSCustomObject]@{
            Name            = $ap.name
            SerialNumber    = $ap.serial
            Model           = $ap.os_type
            ConnectionState = $ap.connection_state
            Status          = $ap.status
            Firmware        = $ap.os_version
            IP              = $ap.ip
            Clients         = $ap.clients
            Radios          = if ($ap.radio) {
                ($ap.radio | ForEach-Object {
                    "Radio$($_.radio_id):Ch$($_.channel)/Pwr$($_.tx_power)dBm/$($_.client_count)clients/$($_.mode)"
                }) -join '; '
            } else { 'N/A' }
            Uptime          = if ($ap.uptime) { [TimeSpan]::FromSeconds($ap.uptime).ToString('d\.hh\:mm\:ss') } else { 'N/A' }
            JoinTime        = $ap.join_time
            WTPProfile      = $ap.wtp_profile
            Country         = $ap.country_name
            MeshUplink      = $ap.mesh_uplink
        }
    }
}

function Get-FortiGateWiFiClients {
    <#
    .SYNOPSIS  Returns connected WiFi clients.
    .EXAMPLE   Get-FortiGateWiFiClients | Group-Object SSID
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/wifi/client").results
    foreach ($c in $r) {
        [PSCustomObject]@{
            MAC          = $c.mac
            IP           = $c.ip
            Hostname     = $c.hostname
            SSID         = $c.ssid
            AP           = $c.ap
            APSerial     = $c.ap_serial
            Band         = $c.band
            Signal       = $c.signal
            SNR          = $c.snr
            Channel      = $c.channel
            VLAN         = $c.vlan_id
            DataRateMbps = $c.data_rate
            TxBytes      = $c.tx_bytes
            RxBytes      = $c.rx_bytes
            IdleSeconds  = $c.idle_time
            AssocTime    = $c.assoc_time
            OS           = $c.os
            Manufacturer = $c.manufacturer
            Security     = $c.security
            EncryptMethod = $c.encrypt
            Health       = $c.health
            BandwidthTx  = $c.bandwidth_tx
            BandwidthRx  = $c.bandwidth_rx
        }
    }
}

function Get-FortiGateRogueAPs {
    <#
    .SYNOPSIS  Returns detected rogue/interfering APs.
    .EXAMPLE   Get-FortiGateRogueAPs
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/wifi/rogue_ap").results
    foreach ($rogue in $r) {
        [PSCustomObject]@{
            BSSID        = $rogue.bssid
            SSID         = $rogue.ssid
            Channel      = $rogue.channel
            Signal       = $rogue.signal
            Security     = $rogue.security
            APName       = $rogue.ap_name
            Classification = $rogue.classification
            FirstSeen    = $rogue.first_seen
            LastSeen     = $rogue.last_seen
            OnWire       = $rogue.on_wire
        }
    }
}

function Get-FortiGateSSIDs {
    <#
    .SYNOPSIS  Returns configured VAP (Virtual AP / SSID) profiles.
    .EXAMPLE   Get-FortiGateSSIDs
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/wireless-controller/vap?vdom=$VDOM").results
    foreach ($v in $r) {
        [PSCustomObject]@{
            Name             = $v.name
            SSID             = $v.ssid
            Security         = $v.security
            Encrypt          = $v.encrypt
            Passphrase       = '[hidden]'
            Auth             = $v.auth
            PortalType       = $v.'portal-type'
            BroadcastSSID    = $v.'broadcast-ssid'
            ScheduleEnabled  = $v.schedule
            MaxClients       = $v.'max-clients'
            LocalBridging    = $v.'local-bridging'
            VLANID           = $v.vlanid
            Interface        = $v.interface
            RadioSensitivity = $v.'radio-sensitivity'
            IntraVAPPrivacy  = $v.'intra-vap-privacy'
            MacFilter        = $v.'mac-filter'
            MACFilterPolicy  = $v.'mac-filter-policy-other'
        }
    }
}

function Get-FortiGateWTPProfiles {
    <#
    .SYNOPSIS  Returns WTP (Wireless Termination Point / AP) profiles.
    .EXAMPLE   Get-FortiGateWTPProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/wireless-controller/wtp-profile?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name       = $p.name
            Comment    = $p.comment
            Platform   = if ($p.platform) { $p.platform.type } else { '' }
            HandoffRSSI = $p.'handoff-rssi'
            LBS        = $p.lbs
            Radio1Band = if ($p.radio_1) { $p.radio_1.band } else { '' }
            Radio1Channel = if ($p.radio_1) { ($p.radio_1.channel | ForEach-Object { $_.'chan' }) -join ',' } else { '' }
            Radio2Band = if ($p.radio_2) { $p.radio_2.band } else { '' }
            Radio2Channel = if ($p.radio_2) { ($p.radio_2.channel | ForEach-Object { $_.'chan' }) -join ',' } else { '' }
            LEDState   = $p.'led-state'
            AllowAccess = $p.allowaccess
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateWirelessDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        ManagedAPs  = $(try { @(Get-FortiGateManagedAPs)   } catch { @() })
        WiFiClients = $(try { @(Get-FortiGateWiFiClients)  } catch { @() })
        RogueAPs    = $(try { @(Get-FortiGateRogueAPs)     } catch { @() })
        SSIDs       = $(try { @(Get-FortiGateSSIDs)         } catch { @() })
        WTPProfiles = $(try { @(Get-FortiGateWTPProfiles)   } catch { @() })
    }
}

function Export-FortiGateWirelessDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Wireless Dashboard'
    )

    $connected = @($DashboardData.ManagedAPs | Where-Object ConnectionState -eq 'Connected').Count
    $summary = @(
        @{ Label='Managed APs';     Value=$DashboardData.ManagedAPs.Count }
        @{ Label='APs Connected';   Value=$connected }
        @{ Label='WiFi Clients';    Value=$DashboardData.WiFiClients.Count }
        @{ Label='Rogue APs';       Value=$DashboardData.RogueAPs.Count }
        @{ Label='SSIDs';           Value=$DashboardData.SSIDs.Count }
        @{ Label='AP Profiles';     Value=$DashboardData.WTPProfiles.Count }
    )

    $tables = @()
    if ($DashboardData.ManagedAPs.Count) {
        $tables += @{ Id='aps'; Title='Managed FortiAP Devices'; Columns=@(
            @{field='Name';title='Name'},@{field='SerialNumber';title='Serial'},@{field='Model';title='Model'},
            @{field='ConnectionState';title='State'},@{field='Firmware';title='Firmware'},@{field='IP';title='IP'},
            @{field='Clients';title='Clients'},@{field='Radios';title='Radios'},
            @{field='Uptime';title='Uptime'},@{field='WTPProfile';title='Profile'},@{field='Country';title='Country'}
        ); Data=@($DashboardData.ManagedAPs) }
    }
    if ($DashboardData.WiFiClients.Count) {
        $tables += @{ Id='clients'; Title='Connected WiFi Clients'; Columns=@(
            @{field='MAC';title='MAC'},@{field='IP';title='IP'},@{field='Hostname';title='Hostname'},
            @{field='SSID';title='SSID'},@{field='AP';title='AP'},@{field='Band';title='Band'},
            @{field='Signal';title='Signal'},@{field='SNR';title='SNR'},@{field='Channel';title='Ch'},
            @{field='DataRateMbps';title='Rate(Mbps)'},@{field='Security';title='Security'},
            @{field='OS';title='OS'},@{field='Manufacturer';title='Vendor'},
            @{field='TxBytes';title='TX Bytes'},@{field='RxBytes';title='RX Bytes'}
        ); Data=@($DashboardData.WiFiClients) }
    }
    if ($DashboardData.RogueAPs.Count) {
        $tables += @{ Id='rogues'; Title='Rogue / Interfering APs'; Columns=@(
            @{field='BSSID';title='BSSID'},@{field='SSID';title='SSID'},@{field='Channel';title='Channel'},
            @{field='Signal';title='Signal'},@{field='Security';title='Security'},
            @{field='Classification';title='Class'},@{field='OnWire';title='On Wire'},
            @{field='FirstSeen';title='First Seen'},@{field='LastSeen';title='Last Seen'}
        ); Data=@($DashboardData.RogueAPs) }
    }
    if ($DashboardData.SSIDs.Count) {
        $tables += @{ Id='ssids'; Title='SSID Configuration'; Columns=@(
            @{field='Name';title='Name'},@{field='SSID';title='SSID'},@{field='Security';title='Security'},
            @{field='Encrypt';title='Encrypt'},@{field='BroadcastSSID';title='Broadcast'},
            @{field='MaxClients';title='Max Clients'},@{field='VLANID';title='VLAN'},
            @{field='MacFilter';title='MAC Filter'},@{field='IntraVAPPrivacy';title='Client Isolation'}
        ); Data=@($DashboardData.SSIDs) }
    }
    if ($DashboardData.WTPProfiles.Count) {
        $tables += @{ Id='wtps'; Title='AP Profiles (WTP)'; Columns=@(
            @{field='Name';title='Name'},@{field='Platform';title='Platform'},
            @{field='Radio1Band';title='Radio1 Band'},@{field='Radio2Band';title='Radio2 Band'},
            @{field='LEDState';title='LED'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.WTPProfiles) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Switch Controller -----------------------------------------------------

function Get-FortiGateManagedSwitches {
    <#
    .SYNOPSIS  Returns FortiSwitch devices managed via FortiLink.
    .EXAMPLE   Get-FortiGateManagedSwitches
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/switch-controller/managed-switch").results
    foreach ($sw in $r) {
        [PSCustomObject]@{
            Name           = $sw.name
            SerialNumber   = $sw.serial
            SwitchID       = $sw.'switch-id'
            Status         = $sw.status
            State          = $sw.state
            Firmware       = $sw.os_version
            IP             = $sw.ip
            Ports          = if ($sw.ports) { ($sw.ports | Measure-Object).Count } else { 0 }
            ConnectedSince = $sw.join_time
            MaxPoeWatts    = $sw.max_poe_budget
            PoeUsedWatts   = $sw.poe_used
            Model          = $sw.platform
            ImageVersion   = $sw.image_version
        }
    }
}

function Get-FortiGateSwitchPorts {
    <#
    .SYNOPSIS  Returns port statistics for a managed FortiSwitch.
    .PARAMETER SwitchSerial  Serial number of the FortiSwitch.
    .EXAMPLE   Get-FortiGateSwitchPorts -SwitchSerial "S424ENTF12345678"
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$SwitchSerial
    )
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/switch-controller/managed-switch/port-stats?mkey=$SwitchSerial").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            SwitchSerial = $SwitchSerial
            Port         = $p.name
            Status       = $p.status
            Speed        = $p.speed
            Duplex       = $p.duplex
            VLAN         = $p.vlan
            PoeStatus    = $p.poe_status
            TxBytes      = $p.tx_bytes
            RxBytes      = $p.rx_bytes
            TxPackets    = $p.tx_packets
            RxPackets    = $p.rx_packets
            MediaType    = $p.media_type
            Flags        = $p.flags
        }
    }
}

function Get-FortiGateSwitchConfig {
    <#
    .SYNOPSIS  Returns FortiSwitch CMDB configuration.
    .EXAMPLE   Get-FortiGateSwitchConfig
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/switch-controller/managed-switch?vdom=$VDOM").results
    foreach ($sw in $r) {
        [PSCustomObject]@{
            SwitchID         = $sw.'switch-id'
            Name             = $sw.name
            Description      = $sw.description
            FSWWanLinkPause  = $sw.'fsw-wan-link-pause'
            Type             = $sw.type
            SwitchProfile    = $sw.'switch-profile'
            Owner            = $sw.'owner-vdom'
            PreProvisioned   = $sw.'pre-provisioned'
            PortCount        = if ($sw.ports) { ($sw.ports | Measure-Object).Count } else { 0 }
            Ports            = ($sw.ports | ForEach-Object {
                "$($_.port_name):vlan$($_.vlan):$($_.poe_status)"
            }) -join '; '
        }
    }
}

function Get-FortiGateSwitchVLANs {
    <#
    .SYNOPSIS  Returns switch-controller VLAN settings (interface-based VLANs managed by switch-controller).
    .EXAMPLE   Get-FortiGateSwitchVLANs
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/switch-controller/vlan?vdom=$VDOM").results
    foreach ($v in $r) {
        [PSCustomObject]@{
            Name   = $v.name
            VLANID = $v.vlanid
            Auth   = $v.auth
            Color  = $v.color
            Comment = $v.comment
        }
    }
}

function Get-FortiGateSwitchLLDP {
    <#
    .SYNOPSIS  Returns LLDP profiles for the switch controller.
    .EXAMPLE   Get-FortiGateSwitchLLDP
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/switch-controller/lldp-profile?vdom=$VDOM").results
    foreach ($l in $r) {
        [PSCustomObject]@{
            Name        = $l.name
            MedTLVs     = $l.'med-tlvs'
            AutoISL     = $l.'auto-isl'
            N8021TLVs   = $l.'802.1-tlvs'
            N8023TLVs   = $l.'802.3-tlvs'
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateSwitchDashboard {
    [CmdletBinding()] param()
    $switchData = [PSCustomObject]@{
        ManagedSwitches = $(try { @(Get-FortiGateManagedSwitches) } catch { @() })
        SwitchConfig    = $(try { @(Get-FortiGateSwitchConfig)    } catch { @() })
        VLANs           = $(try { @(Get-FortiGateSwitchVLANs)    } catch { @() })
        LLDPProfiles    = $(try { @(Get-FortiGateSwitchLLDP)     } catch { @() })
        SwitchPorts     = @()
    }
    # Auto-collect port stats for each managed switch
    foreach ($sw in $switchData.ManagedSwitches) {
        if ($sw.SerialNumber) {
            try {
                $ports = @(Get-FortiGateSwitchPorts -SwitchSerial $sw.SerialNumber)
                $switchData.SwitchPorts += $ports
            } catch { }
        }
    }
    $switchData
}

function Export-FortiGateSwitchDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Switch Controller Dashboard'
    )

    $summary = @(
        @{ Label='Managed Switches';   Value=$DashboardData.ManagedSwitches.Count }
        @{ Label='Total Ports';        Value=$DashboardData.SwitchPorts.Count }
        @{ Label='VLANs';             Value=$DashboardData.VLANs.Count }
        @{ Label='LLDP Profiles';     Value=$DashboardData.LLDPProfiles.Count }
    )

    $tables = @()
    if ($DashboardData.ManagedSwitches.Count) {
        $tables += @{ Id='switches'; Title='Managed FortiSwitch Inventory'; Columns=@(
            @{field='Name';title='Name'},@{field='SerialNumber';title='Serial'},@{field='SwitchID';title='Switch ID'},
            @{field='Status';title='Status'},@{field='State';title='State'},@{field='Firmware';title='Firmware'},
            @{field='IP';title='IP'},@{field='Ports';title='Port Count'},@{field='Model';title='Platform'},
            @{field='MaxPoeWatts';title='PoE Max (W)'},@{field='PoeUsedWatts';title='PoE Used (W)'},
            @{field='ConnectedSince';title='Connected Since'}
        ); Data=@($DashboardData.ManagedSwitches) }
    }
    if ($DashboardData.SwitchPorts.Count) {
        $tables += @{ Id='ports'; Title='Switch Port Statistics'; Columns=@(
            @{field='SwitchSerial';title='Switch'},@{field='Port';title='Port'},@{field='Status';title='Status'},
            @{field='Speed';title='Speed'},@{field='Duplex';title='Duplex'},@{field='VLAN';title='VLAN'},
            @{field='PoeStatus';title='PoE'},@{field='TxBytes';title='TX Bytes'},@{field='RxBytes';title='RX Bytes'},
            @{field='MediaType';title='Media'}
        ); Data=@($DashboardData.SwitchPorts) }
    }
    if ($DashboardData.VLANs.Count) {
        $tables += @{ Id='vlans'; Title='Switch Controller VLANs'; Columns=@(
            @{field='Name';title='Name'},@{field='VLANID';title='VLAN ID'},
            @{field='Auth';title='Auth'},@{field='Comment';title='Comment'}
        ); Data=@($DashboardData.VLANs) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Endpoint Security -----------------------------------------------------

function Get-FortiGateEMSEndpoints {
    <#
    .SYNOPSIS  Returns FortiClient endpoints registered via EMS connector.
    .EXAMPLE   Get-FortiGateEMSEndpoints | Where-Object ComplianceStatus -eq 'non-compliant'
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/endpoint-control/ems/status").results
    foreach ($ep in $r) {
        [PSCustomObject]@{
            Hostname         = $ep.host_name
            IP               = $ep.ip
            MAC              = $ep.mac
            OS               = $ep.os_type
            OSVersion        = $ep.os_version
            FortiClientVer   = $ep.forticlient_version
            ComplianceStatus = $ep.compliance_status
            OnlineStatus     = $ep.online_status
            EMSServer        = $ep.ems_sn
            LastSeen         = $ep.last_seen
            UserName         = $ep.user_name
            Domain           = $ep.domain
            RegistrationStatus = $ep.registration_status
            AVStatus         = $ep.av_status
            VulnStatus       = $ep.vuln_status
        }
    }
}

function Get-FortiGateEMSConfig {
    <#
    .SYNOPSIS  Returns FortiClient EMS connector configuration.
    .EXAMPLE   Get-FortiGateEMSConfig
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/endpoint-control/fctems?vdom=$VDOM").results
    foreach ($e in $r) {
        [PSCustomObject]@{
            Name               = $e.name
            Server             = $e.server
            SerialNumber       = $e.'serial-number'
            FortinetOneCloud   = $e.'fortinetone-cloud-authentication'
            HTTPSPort          = $e.'https-port'
            AdminUsername      = $e.'admin-username'
            SourceIP           = $e.'source-ip'
            PullSysinfo        = $e.'pull-sysinfo'
            PullTags           = $e.'pull-tags'
            PullVulnerabilities = $e.'pull-vulnerabilities'
            PullAvatars        = $e.'pull-avatars'
            Status             = $e.status
            CloudServerType    = $e.'cloud-server-type'
            Capabilities       = $e.capabilities
        }
    }
}

function Get-FortiGateSecurityRating {
    <#
    .SYNOPSIS  Returns the FortiGate security rating / security posture score.
    .EXAMPLE   Get-FortiGateSecurityRating
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/security-rating").results
    foreach ($item in $r) {
        [PSCustomObject]@{
            ID          = $item.id
            Title       = $item.title
            Description = $item.description
            Result      = $item.result
            Score       = $item.score
            Status      = $item.status
            Category    = $item.category
        }
    }
}

function Get-FortiGateEndpointProfiles {
    <#
    .SYNOPSIS  Returns endpoint control profiles.
    .EXAMPLE   Get-FortiGateEndpointProfiles
    #>
    [CmdletBinding()] param([string]$VDOM = 'root')
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/cmdb/endpoint-control/profile?vdom=$VDOM").results
    foreach ($p in $r) {
        [PSCustomObject]@{
            Name             = $p.'profile-name'
            FortiClientWinsCompliance = $p.'forticlient-winmac-settings'
            Description      = $p.description
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateEndpointDashboard {
    [CmdletBinding()] param()
    [PSCustomObject]@{
        Endpoints      = $(try { @(Get-FortiGateEMSEndpoints)     } catch { @() })
        EMSConfig      = $(try { @(Get-FortiGateEMSConfig)        } catch { @() })
        SecurityRating = $(try { @(Get-FortiGateSecurityRating)   } catch { @() })
        Profiles       = $(try { @(Get-FortiGateEndpointProfiles) } catch { @() })
    }
}

function Export-FortiGateEndpointDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Endpoint Security Dashboard'
    )

    $compliant = @($DashboardData.Endpoints | Where-Object ComplianceStatus -eq 'compliant').Count
    $noncomp   = @($DashboardData.Endpoints | Where-Object ComplianceStatus -eq 'non-compliant').Count
    $summary = @(
        @{ Label='Total Endpoints';      Value=$DashboardData.Endpoints.Count }
        @{ Label='Compliant';            Value=$compliant }
        @{ Label='Non-Compliant';        Value=$noncomp }
        @{ Label='EMS Connectors';       Value=$DashboardData.EMSConfig.Count }
        @{ Label='Security Rating Items'; Value=$DashboardData.SecurityRating.Count }
    )

    $tables = @()
    if ($DashboardData.Endpoints.Count) {
        $tables += @{ Id='endpoints'; Title='FortiClient Endpoints'; Columns=@(
            @{field='Hostname';title='Hostname'},@{field='IP';title='IP'},@{field='MAC';title='MAC'},
            @{field='OS';title='OS'},@{field='OSVersion';title='OS Ver'},
            @{field='FortiClientVer';title='FC Ver'},@{field='ComplianceStatus';title='Compliance'},
            @{field='OnlineStatus';title='Online'},@{field='UserName';title='User'},
            @{field='Domain';title='Domain'},@{field='AVStatus';title='AV'},
            @{field='VulnStatus';title='Vuln'},@{field='LastSeen';title='Last Seen'}
        ); Data=@($DashboardData.Endpoints) }
    }
    if ($DashboardData.EMSConfig.Count) {
        $tables += @{ Id='ems'; Title='EMS Connector Configuration'; Columns=@(
            @{field='Name';title='Name'},@{field='Server';title='Server'},
            @{field='SerialNumber';title='Serial'},@{field='Status';title='Status'},
            @{field='PullTags';title='Pull Tags'},@{field='PullVulnerabilities';title='Pull Vulns'},
            @{field='CloudServerType';title='Cloud Type'}
        ); Data=@($DashboardData.EMSConfig) }
    }
    if ($DashboardData.SecurityRating.Count) {
        $tables += @{ Id='rating'; Title='Security Rating / Posture'; Columns=@(
            @{field='ID';title='ID'},@{field='Title';title='Title'},
            @{field='Result';title='Result'},@{field='Score';title='Score'},
            @{field='Status';title='Status'},@{field='Category';title='Category'},
            @{field='Description';title='Description'}
        ); Data=@($DashboardData.SecurityRating) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- Log & Report ----------------------------------------------------------

function Get-FortiGateTrafficLogs {
    <#
    .SYNOPSIS  Returns traffic log entries (forward, local, multicast).
    .PARAMETER SubType  Sub-type: forward, local, multicast. Default: all.
    .PARAMETER Rows     Number of rows. Default 50.
    .EXAMPLE   Get-FortiGateTrafficLogs -Rows 20
    .EXAMPLE   Get-FortiGateTrafficLogs -SubType forward -Rows 100
    #>
    [CmdletBinding()] param(
        [string]$SubType,
        [int]$Rows = 50
    )
    $uri = "$($script:FortiSession.BaseUri)/api/v2/log/disk/traffic/raw?rows=$Rows"
    if ($SubType) { $uri += "&subtype=$SubType" }
    $r = (Invoke-FortiAPI -Uri $uri).results
    foreach ($log in $r) {
        [PSCustomObject]@{
            Date       = $log.date
            Time       = $log.time
            Type       = $log.type
            SubType    = $log.subtype
            Level      = $log.level
            SrcIP      = $log.srcip
            SrcPort    = $log.srcport
            DstIP      = $log.dstip
            DstPort    = $log.dstport
            Protocol   = $log.proto
            Action     = $log.action
            PolicyID   = $log.policyid
            Service    = $log.service
            SentBytes  = $log.sentbyte
            RecvBytes  = $log.rcvdbyte
            SentPkts   = $log.sentpkt
            RecvPkts   = $log.rcvdpkt
            Duration   = $log.duration
            SrcIntf    = $log.srcintf
            DstIntf    = $log.dstintf
            SrcCountry = $log.srccountry
            DstCountry = $log.dstcountry
            AppCat     = $log.appcat
            App        = $log.app
            User       = $log.user
        }
    }
}

function Get-FortiGateEventLogs {
    <#
    .SYNOPSIS  Returns event log entries (system, user, router, vpn, etc.).
    .PARAMETER SubType  Sub-type: system, user, router, vpn, etc. Default: all.
    .PARAMETER Rows     Number of rows. Default 50.
    .EXAMPLE   Get-FortiGateEventLogs -SubType system -Rows 30
    #>
    [CmdletBinding()] param(
        [string]$SubType,
        [int]$Rows = 50
    )
    $uri = "$($script:FortiSession.BaseUri)/api/v2/log/disk/event/raw?rows=$Rows"
    if ($SubType) { $uri += "&subtype=$SubType" }
    $r = (Invoke-FortiAPI -Uri $uri).results
    foreach ($log in $r) {
        [PSCustomObject]@{
            Date     = $log.date
            Time     = $log.time
            Type     = $log.type
            SubType  = $log.subtype
            Level    = $log.level
            LogDesc  = $log.logdesc
            Action   = $log.action
            Status   = $log.status
            Message  = $log.msg
            User     = $log.user
            UI       = $log.ui
            SrcIP    = $log.srcip
            DstIP    = $log.dstip
        }
    }
}

function Get-FortiGateUTMLogs {
    <#
    .SYNOPSIS  Returns UTM/security log entries (virus, webfilter, ips, app-ctrl, etc.).
    .PARAMETER SubType  Sub-type: virus, webfilter, ips, app-ctrl, dlp, emailfilter, dns. Default: all.
    .PARAMETER Rows     Number of rows. Default 50.
    .EXAMPLE   Get-FortiGateUTMLogs -SubType ips -Rows 100
    #>
    [CmdletBinding()] param(
        [string]$SubType,
        [int]$Rows = 50
    )
    $uri = "$($script:FortiSession.BaseUri)/api/v2/log/disk/utm/raw?rows=$Rows"
    if ($SubType) { $uri += "&subtype=$SubType" }
    $r = (Invoke-FortiAPI -Uri $uri).results
    foreach ($log in $r) {
        [PSCustomObject]@{
            Date       = $log.date
            Time       = $log.time
            Type       = $log.type
            SubType    = $log.subtype
            Level      = $log.level
            SrcIP      = $log.srcip
            DstIP      = $log.dstip
            Action     = $log.action
            Service    = $log.service
            PolicyID   = $log.policyid
            Profile    = $log.profile
            Msg        = $log.msg
            URL        = $log.url
            Hostname   = $log.hostname
            Category   = $log.catdesc
            Attack     = $log.attack
            Severity   = $log.severity
            VirusName  = $log.virus
            User       = $log.user
        }
    }
}

function Get-FortiGateLogStats {
    <#
    .SYNOPSIS  Returns log storage statistics (disk usage, log count).
    .EXAMPLE   Get-FortiGateLogStats
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/log/stats").results
    [PSCustomObject]@{
        DiskUsageMB  = $r.used
        DiskTotalMB  = $r.total
        DiskFreePercent = if ($r.total -gt 0) { [math]::Round(($r.total - $r.used) / $r.total * 100, 1) } else { 'N/A' }
        LogCount     = $r.log_count
        RollPolicy   = $r.roll_policy
    }
}

function Get-FortiGateFortiGuardStatus {
    <#
    .SYNOPSIS  Returns FortiGuard server/subscription info and last update times.
    .EXAMPLE   Get-FortiGateFortiGuardStatus
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/fortiguard/server-info").results
    [PSCustomObject]@{
        ServiceProvider     = $r.service_provider
        ServicePort         = $r.service_port
        AnycastIP           = $r.anycast_sdns_server_ip
        ScheduledUpdateFreq = $r.scheduled_update_freq
        LastUpdate          = $r.last_update
        UpdateServerStatus  = $r.update_server_status
    }
}

function Get-FortiGateAlertMessages {
    <#
    .SYNOPSIS  Returns system alert/notification messages.
    .EXAMPLE   Get-FortiGateAlertMessages
    #>
    [CmdletBinding()] param()
    $r = (Invoke-FortiAPI -Uri "$($script:FortiSession.BaseUri)/api/v2/monitor/system/alert-email/select").results
    foreach ($a in $r) {
        [PSCustomObject]@{
            Severity   = $a.severity
            Category   = $a.category
            Msg        = $a.msg
            Timestamp  = $a.timestamp
        }
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiGateLogDashboard {
    [CmdletBinding()] param(
        [int]$Rows = 50
    )
    [PSCustomObject]@{
        TrafficLogs    = $(try { @(Get-FortiGateTrafficLogs -Rows $Rows) } catch { @() })
        EventLogs      = $(try { @(Get-FortiGateEventLogs -Rows $Rows)   } catch { @() })
        UTMLogs        = $(try { @(Get-FortiGateUTMLogs -Rows $Rows)     } catch { @() })
        LogStats       = $(try { Get-FortiGateLogStats                   } catch { $null })
        FortiGuard     = $(try { Get-FortiGateFortiGuardStatus           } catch { $null })
        Alerts         = $(try { @(Get-FortiGateAlertMessages)           } catch { @() })
    }
}

function Export-FortiGateLogDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiGate Log & Report Dashboard'
    )

    $logStatLabel = 'N/A'
    if ($DashboardData.LogStats) { $logStatLabel = "$($DashboardData.LogStats.DiskUsageMB) / $($DashboardData.LogStats.DiskTotalMB) MB" }
    $summary = @(
        @{ Label='Traffic Logs';  Value=$DashboardData.TrafficLogs.Count }
        @{ Label='Event Logs';    Value=$DashboardData.EventLogs.Count }
        @{ Label='UTM Logs';      Value=$DashboardData.UTMLogs.Count }
        @{ Label='Disk Usage';    Value=$logStatLabel }
        @{ Label='Alerts';        Value=$DashboardData.Alerts.Count }
    )

    $tables = @()
    if ($DashboardData.TrafficLogs.Count) {
        $tables += @{ Id='traffic'; Title='Traffic Logs'; Columns=@(
            @{field='Date';title='Date'},@{field='Time';title='Time'},@{field='SubType';title='SubType'},
            @{field='SrcIP';title='Src IP'},@{field='SrcPort';title='Src Port'},
            @{field='DstIP';title='Dst IP'},@{field='DstPort';title='Dst Port'},
            @{field='Protocol';title='Proto'},@{field='Action';title='Action'},@{field='PolicyID';title='Policy'},
            @{field='Service';title='Service'},@{field='SentBytes';title='Sent'},@{field='RecvBytes';title='Rcvd'},
            @{field='Duration';title='Dur(s)'},@{field='App';title='App'},@{field='User';title='User'}
        ); Data=@($DashboardData.TrafficLogs) }
    }
    if ($DashboardData.EventLogs.Count) {
        $tables += @{ Id='events'; Title='Event Logs'; Columns=@(
            @{field='Date';title='Date'},@{field='Time';title='Time'},@{field='SubType';title='SubType'},
            @{field='Level';title='Level'},@{field='LogDesc';title='Description'},
            @{field='Action';title='Action'},@{field='Status';title='Status'},
            @{field='Message';title='Message'},@{field='User';title='User'},@{field='SrcIP';title='Src IP'}
        ); Data=@($DashboardData.EventLogs) }
    }
    if ($DashboardData.UTMLogs.Count) {
        $tables += @{ Id='utm'; Title='UTM / Security Logs'; Columns=@(
            @{field='Date';title='Date'},@{field='Time';title='Time'},@{field='SubType';title='SubType'},
            @{field='Level';title='Level'},@{field='SrcIP';title='Src IP'},@{field='DstIP';title='Dst IP'},
            @{field='Action';title='Action'},@{field='Service';title='Service'},@{field='PolicyID';title='Policy'},
            @{field='Attack';title='Attack'},@{field='Severity';title='Severity'},@{field='VirusName';title='Virus'},
            @{field='URL';title='URL'},@{field='Category';title='Category'},@{field='Msg';title='Message'}
        ); Data=@($DashboardData.UTMLogs) }
    }
    if ($DashboardData.Alerts.Count) {
        $tables += @{ Id='alerts'; Title='System Alerts'; Columns=@(
            @{field='Severity';title='Severity'},@{field='Category';title='Category'},
            @{field='Msg';title='Message'},@{field='Timestamp';title='Time'}
        ); Data=@($DashboardData.Alerts) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

#region -- FortiManager ----------------------------------------------------------

# ---------------------------------------------------------------------------
# Internal helper for FortiManager JSON-RPC calls
# ---------------------------------------------------------------------------
function Invoke-FortiManagerAPI {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][array]$Params
    )
    $body = @{
        id      = 1
        method  = $Method
        params  = $Params
        session = $script:FortiManagerSession.SessionId
    } | ConvertTo-Json -Depth 10

    $splat = @{
        Uri         = "$($script:FortiManagerSession.BaseUri)/jsonrpc"
        Method      = 'POST'
        Body        = $body
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($script:FortiSkipCert) { $splat['SkipCertificateCheck'] = $true }

    $r = Invoke-RestMethod @splat
    if ($r.result -and $r.result.status -and $r.result.status.code -ne 0) {
        throw "FortiManager API error: $($r.result.status.message)"
    }
    return $r
}

# ---------------------------------------------------------------------------
# Connect-FortiManager
# ---------------------------------------------------------------------------
function Connect-FortiManager {
    <#
    .SYNOPSIS  Authenticates to FortiManager via JSON-RPC.
    .PARAMETER Server     FortiManager hostname or IP.
    .PARAMETER Credential PSCredential for admin login.
    .PARAMETER Port       HTTPS port. Default 443.
    .PARAMETER IgnoreSSLErrors Skip cert validation.
    .EXAMPLE   Connect-FortiManager -Server "fmg.domain.com" -Credential (Get-Credential) -IgnoreSSLErrors
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [int]$Port = 443,
        [switch]$IgnoreSSLErrors
    )

    if ($IgnoreSSLErrors) {
        Initialize-SSLBypass
        $script:FortiSkipCert = $true
    }

    $script:FortiManagerSession = @{
        BaseUri   = "https://${Server}:${Port}"
        SessionId = $null
    }

    $loginBody = @{
        id      = 1
        method  = 'exec'
        params  = @(@{
            url  = '/sys/login/user'
            data = @{
                user   = $Credential.UserName
                passwd = $Credential.GetNetworkCredential().Password
            }
        })
    } | ConvertTo-Json -Depth 5

    $splat = @{
        Uri         = "$($script:FortiManagerSession.BaseUri)/jsonrpc"
        Method      = 'POST'
        Body        = $loginBody
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($script:FortiSkipCert) { $splat['SkipCertificateCheck'] = $true }

    $r = Invoke-RestMethod @splat
    if ($r.result.status.code -ne 0) {
        throw "FortiManager login failed: $($r.result.status.message)"
    }
    $script:FortiManagerSession.SessionId = $r.session
    Write-Verbose "Authenticated to FortiManager $Server."
    return $r.result
}

function Disconnect-FortiManager {
    <#
    .SYNOPSIS  Logs out of FortiManager.
    #>
    [CmdletBinding()] param()
    if ($script:FortiManagerSession.SessionId) {
        try {
            Invoke-FortiManagerAPI -Method 'exec' -Params @(@{ url = '/sys/logout' })
        } catch { Write-Verbose "FMG logout failed: $_" }
    }
    $script:FortiManagerSession = @{ BaseUri = $null; SessionId = $null }
}

# ---------------------------------------------------------------------------
# ADOMs
# ---------------------------------------------------------------------------
function Get-FortiManagerADOMs {
    <#
    .SYNOPSIS  Returns all Administrative Domains.
    .EXAMPLE   Get-FortiManagerADOMs
    #>
    [CmdletBinding()] param()
    $r = Invoke-FortiManagerAPI -Method 'get' -Params @(@{ url = '/dvmdb/adom' })
    foreach ($a in $r.result.data) {
        [PSCustomObject]@{
            Name        = $a.name
            Description = $a.desc
            State       = $a.state
            OS          = $a.os_ver
            MR          = $a.mr
            Restricted  = $a.restricted_prds
            DeviceCount = if ($a.device_count) { $a.device_count } else { 0 }
        }
    }
}

# ---------------------------------------------------------------------------
# Managed Devices
# ---------------------------------------------------------------------------
function Get-FortiManagerDevices {
    <#
    .SYNOPSIS  Returns all managed devices from FortiManager.
    .PARAMETER ADOM  Administrative domain. Default 'root'.
    .EXAMPLE   Get-FortiManagerDevices -ADOM 'root'
    #>
    [CmdletBinding()] param([string]$ADOM = 'root')
    $r = Invoke-FortiManagerAPI -Method 'get' -Params @(@{ url = "/dvmdb/adom/$ADOM/device" })
    foreach ($d in $r.result.data) {
        [PSCustomObject]@{
            Name             = $d.name
            SerialNumber     = $d.sn
            Platform         = $d.platform_str
            Firmware         = $d.os_ver
            IP               = $d.ip
            ConnectionStatus = $d.conn_status
            ADOM             = $ADOM
            HAMode           = $d.ha_mode
            HARole           = $d.ha_slave
            ConfigStatus     = $d.conf_status
            DeviceStatus     = $d.dev_status
            Hostname         = $d.hostname
            MR               = $d.mr
            VDOM             = ($d.vdom | ForEach-Object { $_.name }) -join ', '
        }
    }
}

# ---------------------------------------------------------------------------
# Policy Packages
# ---------------------------------------------------------------------------
function Get-FortiManagerPolicyPackages {
    <#
    .SYNOPSIS  Returns policy packages from FortiManager.
    .PARAMETER ADOM  Administrative domain. Default 'root'.
    .EXAMPLE   Get-FortiManagerPolicyPackages
    #>
    [CmdletBinding()] param([string]$ADOM = 'root')
    $r = Invoke-FortiManagerAPI -Method 'get' -Params @(@{ url = "/pm/pkg/adom/$ADOM" })
    foreach ($pkg in $r.result.data) {
        [PSCustomObject]@{
            Name       = $pkg.name
            Type       = $pkg.type
            OID        = $pkg.oid
            ScopeDevice = ($pkg.'scope member' | ForEach-Object { $_.name }) -join ', '
        }
    }
}

# ---------------------------------------------------------------------------
# FortiManager System Status
# ---------------------------------------------------------------------------
function Get-FortiManagerSystemStatus {
    <#
    .SYNOPSIS  Returns FortiManager system status.
    .EXAMPLE   Get-FortiManagerSystemStatus
    #>
    [CmdletBinding()] param()
    $r = Invoke-FortiManagerAPI -Method 'get' -Params @(@{ url = '/sys/status' })
    $d = $r.result.data
    [PSCustomObject]@{
        Hostname        = $d.Hostname
        SerialNumber    = $d.'Serial Number'
        Version         = $d.Version
        AdminDomain     = $d.'Admin Domain Configuration'
        Platform        = $d.'Platform Full Name'
        CurrentTime     = $d.'Current Time'
        Uptime          = $d.Uptime
        MaxDevices      = $d.'Max Number of Admin Domains'
        MaxFortiAPs     = $d.'Max Number of FortiAPs'
    }
}

# ---------------------------------------------------------------------------
# Dashboard & Export
# ---------------------------------------------------------------------------
function Get-FortiManagerDashboard {
    [CmdletBinding()] param([string]$ADOM = 'root')
    [PSCustomObject]@{
        SystemStatus    = $(try { Get-FortiManagerSystemStatus            } catch { $null })
        ADOMs           = $(try { @(Get-FortiManagerADOMs)                } catch { @() })
        Devices         = $(try { @(Get-FortiManagerDevices -ADOM $ADOM)  } catch { @() })
        PolicyPackages  = $(try { @(Get-FortiManagerPolicyPackages -ADOM $ADOM) } catch { @() })
    }
}

function Export-FortiManagerDashboardHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'FortiManager Dashboard'
    )

    $summary = @(
        @{ Label='Hostname';   Value = if ($DashboardData.SystemStatus) { $DashboardData.SystemStatus.Hostname } else { 'N/A' } }
        @{ Label='Version';    Value = if ($DashboardData.SystemStatus) { $DashboardData.SystemStatus.Version }  else { 'N/A' } }
        @{ Label='ADOMs';      Value=$DashboardData.ADOMs.Count }
        @{ Label='Devices';    Value=$DashboardData.Devices.Count }
        @{ Label='Policy Pkgs'; Value=$DashboardData.PolicyPackages.Count }
    )

    $tables = @()
    if ($DashboardData.Devices.Count) {
        $tables += @{ Id='devices'; Title='Managed Devices'; Columns=@(
            @{field='Name';title='Name'},@{field='SerialNumber';title='Serial'},
            @{field='Platform';title='Platform'},@{field='Firmware';title='Firmware'},
            @{field='IP';title='IP'},@{field='ConnectionStatus';title='Connection'},
            @{field='ConfigStatus';title='Config Status'},@{field='DeviceStatus';title='Device Status'},
            @{field='HAMode';title='HA Mode'},@{field='ADOM';title='ADOM'},@{field='VDOM';title='VDOM'}
        ); Data=@($DashboardData.Devices) }
    }
    if ($DashboardData.ADOMs.Count) {
        $tables += @{ Id='adoms'; Title='Administrative Domains'; Columns=@(
            @{field='Name';title='Name'},@{field='Description';title='Description'},
            @{field='State';title='State'},@{field='OS';title='OS'},
            @{field='DeviceCount';title='Devices'},@{field='Restricted';title='Restricted'}
        ); Data=@($DashboardData.ADOMs) }
    }
    if ($DashboardData.PolicyPackages.Count) {
        $tables += @{ Id='pkgs'; Title='Policy Packages'; Columns=@(
            @{field='Name';title='Name'},@{field='Type';title='Type'},
            @{field='OID';title='OID'},@{field='ScopeDevice';title='Scope (Devices)'}
        ); Data=@($DashboardData.PolicyPackages) }
    }

    New-FortinetDashboardHtml -ReportTitle $ReportTitle -SummaryCards $summary -Tables $tables -OutputPath $OutputPath
}

#endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBIZFpJd03QDktv
# CE95HJbOxNKv8SdnwaonyNgNV7iq0KCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBuRMSABIio6RtGYrdeFmD/JbQYG4G53BoIMJ5WO/XITTANBgkqhkiG9w0BAQEF
# AASCAgB+YEskhhRpPWEaLvK3oAlOhA1N9IuTEbrNl0pmtjCTFt9dVuqfww/3sgzu
# GPI3o3ozgJmM0tZ0re/h1sKfeko6yzUhcxsGKdxYGG/YZTysw/7v5YCh9pQjNu6s
# gfQ7M4wlVbzDmB6A+srJcacv+6S3lXi5Ipggxq6YoRBsIO+9Cu0XhHQQRumlGeiI
# qw2ABm4HtQAU6YDGQRdxYPJfckFNRfyvNvq0wVy14BWUZgpEjMKrvfN7wPROhGUD
# exg6dSt07jOXaRomw4bhKYpuFnK+0RgqbnrLrQQcq+Qov0PlObkoHJZlYgpnvJCk
# 0uWT02e6qGs/pUq7Y3NYi2Q/3sTy9pK2dH5cNFcJsTuEEJTvjnacdxuaJHWJktee
# yiJGJJN3SfkvDBeBJizssGo8A0P94EjQWTU3l1rdtipKwDKwoNLkbhhMONs+xKvQ
# GxjVQ4Z4fECTIUETLA51uR0XVagKjQ7NJtqR91AyQDKdcQenpKD9cI+1xsE67E5I
# koqAloM66oJRTRBR+wGKf8FutUlPBERmmocHE+qbwvYctSJf6kdzgQtcIO8XJ4nr
# mn6uGIuNx6pQoMdh/Fds6N8czFwhHV4Z91guETVjzmeL8QkLwfSzAOvBvFPeCkTH
# E+S7Yyjpmc7kyHWtrMaW6AeOcelM+R9U67OeA/dx3hkh0GlPlqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDE2NDNaMC8GCSqGSIb3DQEJBDEiBCARlgI4
# ZQPPGGdgVZPWqGPCfhTYDMrhcTnAL/g0e5MiZjANBgkqhkiG9w0BAQEFAASCAgAo
# nnzZGP51lIQIDCGVy7yFl7JwsbN6Uk0Dw+5TMmVJ31871xDMjo709q/+hSHjTfMX
# OsiQtsOtspfE/0LyUG6olxRW3P4yHVztEijkG87m19eoYVzopfwOSPDN4++4lNBx
# JfRYKU8WNwz4pWzYCMDH86C4JxRjtkgQL1uQr/niDwq7zMMcsQjES67iY1TkNL9g
# 8JxLVDze4rdD7CZ6J8vIrOtnXnWOAc+QfdRrDiYLgakSFc/ullJXtTsgrkmeN85/
# G6Z228xwov7YbHpKAcbyQAXHYMznj/mBzCWySL1K8+QfAulj545afNHJCtF9yfPk
# wmcleIV9hrufr7GS675iPDvRI2ROoJGyCQChSG6pxXAYVw12obTlfFgmcr8MlqSF
# f0Pc+8nrT6Qoj/JTEVXM+0lNNmMQqSGuKyyhuprQiFvBkYlUvpZ76YS8vAMFJCx+
# 9YORj1YJMEGLvgYBjLN0oD5et/aPwLsUDo3gRQk0bJKrnxzzANuICSrukzXLkUAf
# gOqXpJKGjdfXwQbL32q3Y6YxkuE9AW/MNOj55iZgoIGkjjgy5t/uW/IqoEr/G8jT
# EKTYdrGdnQHGVlzda/9kUeR9rMU7fZxNDn06STZguTX2wX34g0fxKUP8qDS6Xfhc
# 2oNb6p4rqRShW32VElVxJ3u+oQPM+li0xzsOVW3s/A==
# SIG # End signature block
