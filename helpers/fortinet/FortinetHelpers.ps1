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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCls8Y1mDWhYjMr
# 7WEiVvsXSWu5Rr8OatU9O1T5MDJ16KCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg3E8M0NkIGN9PN0RMnjB32475EUXD+PmJ
# nryayL2YriIwDQYJKoZIhvcNAQEBBQAEggIAhB/Bpd+wlPabrSDgq7jZL3/QlnVb
# VxZqDk4ech09lgENU5M+wEmyXYLIG9AR9nE/lALXC6tiLfu6qtNSx4LHqk1G6Hg6
# Dl12pH10Vw6qFfJwxr6enXXqA3WFU8QfVfvGD83QNVvpzmxRZgXvklHZ2yg334Zb
# tjYu/cMzrN8ClLWaQCGMFo9VOWrvDYD0wOKGFIevSgVIKx8ZzZt1RWf9CiHF6d8x
# YDKhPRsBBJUrm0fAFnfyLS+2zzAj9Op0YWZCIEER1oI+an8Ec4CBMvNc4wbk23SS
# dwetHGBRRTbpNYdvcc9JzZyujY8T4d5h54hmMkZgh7qvcFUEtmBwwdlB85BBqWaR
# CIq0RaB50IHAvWMXe0L0eQe4Y248KkpEvcynnkFj7rk9u7EQERZT9AmpVG2sN2h1
# Bz2+FKkFaslGZlc3wSSiSC5nGXaFuf2i3XCc9y4ctYetJZfK2Atdkh+oFQtnA7ag
# SY38Nt8Mzzb61LplviLLF3T9YbKvaBjayxM/+nZ3Gk0/fmjhW9xcrjvMysdrqNNr
# t8PA+Ky5kAdZtPUWanA/UjTAge/2MMsZI88I5xIQyOIBbo867eJZ+XUD0keWsEVt
# +/lOv5Iqgshk82YBiJIB5NmU1JV6px5spgukEejkFijCshQ0du+7Hpw3E6JjDQrR
# xfXPDEDbzDOCAZI=
# SIG # End signature block
