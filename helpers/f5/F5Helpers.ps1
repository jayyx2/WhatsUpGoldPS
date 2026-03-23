# =============================================================================
# F5 BIG-IP Helpers for WhatsUpGoldPS
# Uses the F5 iControl REST API (BIG-IP 11.5+).
# No additional modules required - uses Invoke-RestMethod directly.
#
# Typical workflow:
#   1. Connect-F5Server  (authenticates, stores token/headers in script scope)
#   2. Get-F5VirtualServers / Get-F5Pools / Get-F5PoolMembers  (query data)
#   3. Get-F5Dashboard   (builds a combined view of VS + pools + members)
#   4. Export-F5DashboardHtml  (renders an HTML report)
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
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
    }
}
"@
        }
        [SSLValidator]::OverrideValidation()
    }
}

# ---------------------------------------------------------------------------
# Script-scoped state - keeps auth context between calls
# ---------------------------------------------------------------------------
$script:F5Session = @{
    BaseUri  = $null
    Headers  = $null
    Token    = $null
}

# ---------------------------------------------------------------------------
# Connect-F5Server
# ---------------------------------------------------------------------------
function Connect-F5Server {
    <#
    .SYNOPSIS
        Authenticates to an F5 BIG-IP appliance via iControl REST.
    .DESCRIPTION
        Obtains an authentication token from /mgmt/shared/authn/login and
        stores it for subsequent helper calls. Falls back to Basic auth if
        token-based auth is unavailable.
    .PARAMETER F5Host
        Hostname or IP address of the BIG-IP management interface.
    .PARAMETER Credential
        PSCredential for a user with at least read access to the BIG-IP.
    .PARAMETER Port
        Management port. Defaults to 443.
    .PARAMETER IgnoreSSLErrors
        Skip certificate validation (self-signed certs on the BIG-IP).
    .EXAMPLE
        $cred = Get-Credential
        Connect-F5Server -F5Host "bigip01.domain.com" -Credential $cred
        # Connects using default port 443 with certificate validation.
    .EXAMPLE
        Connect-F5Server -F5Host "10.0.0.50" -Credential $cred -Port 8443 -IgnoreSSLErrors
        # Connects on port 8443 and skips self-signed cert validation.
    .EXAMPLE
        $cred = Get-Credential -Message "F5 Admin"
        Connect-F5Server -F5Host "bigip-ha01" -Credential $cred -IgnoreSSLErrors
        Get-F5SystemInfo
        # Connect then immediately verify with system info.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$F5Host,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [int]$Port = 443,
        [switch]$IgnoreSSLErrors
    )

    if ($IgnoreSSLErrors) {
        Initialize-SSLBypass
        $script:F5SkipCert = $true
    }

    $script:F5Session.BaseUri = "https://${F5Host}:${Port}"

    # Attempt token-based auth
    $loginBody = @{
        username          = $Credential.UserName
        password          = $Credential.GetNetworkCredential().Password
        loginProviderName = "tmos"
    } | ConvertTo-Json

    $splat = @{
        Uri         = "$($script:F5Session.BaseUri)/mgmt/shared/authn/login"
        Method      = "POST"
        Body        = $loginBody
        ContentType = "application/json"
        ErrorAction = "Stop"
    }
    if ($script:F5SkipCert) { $splat["SkipCertificateCheck"] = $true }

    try {
        $response = Invoke-RestMethod @splat
        $script:F5Session.Token = $response.token.token
        $script:F5Session.Headers = @{
            "X-F5-Auth-Token" = $script:F5Session.Token
            "Content-Type"    = "application/json"
        }
        Write-Verbose "Authenticated to F5 $F5Host via token."
    }
    catch {
        # Fallback: basic auth
        Write-Verbose "Token auth failed ($($_.Exception.Message)). Falling back to Basic auth."
        $pair = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        $script:F5Session.Headers = @{
            "Authorization" = "Basic $encoded"
            "Content-Type"  = "application/json"
        }
        $script:F5Session.Token = $null
    }

    # Validate connectivity
    $testSplat = @{
        Uri         = "$($script:F5Session.BaseUri)/mgmt/tm/sys/version"
        Headers     = $script:F5Session.Headers
        Method      = "GET"
        ErrorAction = "Stop"
    }
    if ($script:F5SkipCert) { $testSplat["SkipCertificateCheck"] = $true }

    try {
        $version = Invoke-RestMethod @testSplat
        $entry = $version.entries.PSObject.Properties | Select-Object -First 1
        $ver = $entry.Value.nestedStats.entries.Version.description
        $build = $entry.Value.nestedStats.entries.Build.description
        Write-Verbose "Connected to F5 BIG-IP version $ver build $build"
    }
    catch {
        throw "Failed to connect to F5 BIG-IP at $F5Host : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Internal: Invoke-F5RestMethod
# ---------------------------------------------------------------------------
function Invoke-F5RestMethod {
    <#
    .SYNOPSIS
        Internal wrapper for REST calls to the F5 BIG-IP.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$Method = "GET"
    )

    if (-not $script:F5Session.BaseUri) {
        throw "Not connected to an F5 BIG-IP. Run Connect-F5Server first."
    }

    $uri = "$($script:F5Session.BaseUri)$Endpoint"
    $splat = @{
        Uri         = $uri
        Headers     = $script:F5Session.Headers
        Method      = $Method
        ErrorAction = "Stop"
    }
    if ($script:F5SkipCert) { $splat["SkipCertificateCheck"] = $true }

    Invoke-RestMethod @splat
}

# ---------------------------------------------------------------------------
# Get-F5SystemInfo
# ---------------------------------------------------------------------------
function Get-F5SystemInfo {
    <#
    .SYNOPSIS
        Returns basic system information for the connected BIG-IP.
    .DESCRIPTION
        Queries /mgmt/tm/sys/global-settings and /mgmt/tm/sys/version to
        return hostname, version, build, base MAC, etc.
    .EXAMPLE
        Get-F5SystemInfo
        # Returns hostname, version, build, edition, and base MAC.
    .EXAMPLE
        $info = Get-F5SystemInfo
        Write-Host "Connected to $($info.Hostname) running v$($info.Version)"
    #>
    [CmdletBinding()]
    param()

    $gs = Invoke-F5RestMethod -Endpoint "/mgmt/tm/sys/global-settings"
    $ver = Invoke-F5RestMethod -Endpoint "/mgmt/tm/sys/version"
    $entry = $ver.entries.PSObject.Properties | Select-Object -First 1
    $v = $entry.Value.nestedStats.entries

    [PSCustomObject]@{
        Hostname    = $gs.hostname
        Version     = $v.Version.description
        Build       = $v.Build.description
        Edition     = $v.Edition.description
        Product     = $v.Product.description
        BaseMac     = if ($gs.baseMac) { $gs.baseMac } else { "N/A" }
        ConsoleIP   = $script:F5Session.BaseUri
    }
}

# ---------------------------------------------------------------------------
# Get-F5VirtualServers
# ---------------------------------------------------------------------------
function Get-F5VirtualServers {
    <#
    .SYNOPSIS
        Returns all LTM virtual servers from the BIG-IP.
    .DESCRIPTION
        Queries /mgmt/tm/ltm/virtual and returns key properties for each VS
        including destination address:port, status, pool, profiles, etc.
    .PARAMETER Partition
        Filter by partition name. Defaults to all partitions.
    .PARAMETER ExpandSubcollections
        Expand profiles and other sub-collections. Defaults to $true.
    .EXAMPLE
        Get-F5VirtualServers
        # Returns all virtual servers across all partitions.
    .EXAMPLE
        Get-F5VirtualServers -Partition "Common"
        # Returns only virtual servers in the Common partition.
    .EXAMPLE
        Get-F5VirtualServers | Select-Object Name, Address, Port, Pool, Enabled | Format-Table
        # Quick overview of all VS destinations and assigned pools.
    .EXAMPLE
        Get-F5VirtualServers -ExpandSubcollections $false
        # Skip profile expansion for faster results.
    #>
    [CmdletBinding()]
    param(
        [string]$Partition,
        [bool]$ExpandSubcollections = $true
    )

    $endpoint = "/mgmt/tm/ltm/virtual"
    if ($ExpandSubcollections) {
        $endpoint += '?expandSubcollections=true'
    }

    $response = Invoke-F5RestMethod -Endpoint $endpoint

    foreach ($vs in $response.items) {
        # Skip if partition filter doesn't match
        if ($Partition -and $vs.partition -ne $Partition) { continue }

        # Parse destination  e.g. "/Common/10.0.0.1:443" or "/Common/10.0.0.1%1:443"
        $dest = $vs.destination -replace '^/[^/]+/', ''
        $destParts = $dest -split ':'
        $vsAddress = ($destParts[0] -replace '%\d+$', '')
        $vsPort = if ($destParts.Count -gt 1) { $destParts[1] } else { "any" }

        # Pool name (strip partition prefix)
        $poolName = if ($vs.pool) { ($vs.pool -replace '^/[^/]+/', '') } else { "None" }
        $poolPath = if ($vs.pool) { $vs.pool } else { $null }

        # Profiles - detailed with context (clientside / serverside / all)
        $profiles = @()
        $profilesDetailed = @()
        if ($vs.profilesReference -and $vs.profilesReference.items) {
            $profiles = $vs.profilesReference.items | ForEach-Object {
                [PSCustomObject]@{
                    Name    = $_.name
                    Context = $_.context
                    FullPath = $_.fullPath
                }
            }
            $profilesDetailed = $vs.profilesReference.items | ForEach-Object {
                "$($_.name)($($_.context))"
            }
        }
        $profileNames = ($profiles | ForEach-Object { $_.Name }) -join ", "
        $profilesDetailedStr = $profilesDetailed -join ", "

        # Persistence + fallback persistence
        $persistence = if ($vs.persist) {
            ($vs.persist | ForEach-Object { $_.name }) -join ", "
        } else { "None" }
        $fallbackPersistence = if ($vs.fallbackPersistence) {
            ($vs.fallbackPersistence -replace '^/[^/]+/', '')
        } else { "None" }

        # iRules (ordered)
        $irules = if ($vs.rules) {
            ($vs.rules | ForEach-Object { ($_ -replace '^/[^/]+/', '') }) -join ", "
        } else { "None" }

        # SNAT type + pool
        $snatType = if ($vs.sourceAddressTranslation) {
            $vs.sourceAddressTranslation.type
        } else { "None" }
        $snatPool = if ($vs.sourceAddressTranslation -and $vs.sourceAddressTranslation.pool) {
            ($vs.sourceAddressTranslation.pool -replace '^/[^/]+/', '')
        } else { "N/A" }

        # LTM Policies
        $policies = @()
        if ($vs.policiesReference -and $vs.policiesReference.items) {
            $policies = $vs.policiesReference.items | ForEach-Object { $_.name }
        }
        $policiesStr = if ($policies.Count -gt 0) { $policies -join ", " } else { "None" }

        # VLANs
        $vlansEnabled = if ($vs.vlansEnabled -eq $true) { $true } else { $false }
        $vlansDisabled = if ($vs.vlansDisabled -eq $true) { $true } else { $false }
        $vlans = if ($vs.vlans) {
            ($vs.vlans | ForEach-Object { ($_ -replace '^/[^/]+/', '') }) -join ", "
        } else { "None" }

        # Security / firewall
        $fwEnforcedPolicy = if ($vs.fwEnforcedPolicy) {
            ($vs.fwEnforcedPolicy -replace '^/[^/]+/', '')
        } else { "None" }
        $fwStagedPolicy = if ($vs.fwStagedPolicy) {
            ($vs.fwStagedPolicy -replace '^/[^/]+/', '')
        } else { "None" }
        $securityLogProfiles = if ($vs.securityLogProfiles) {
            ($vs.securityLogProfiles | ForEach-Object { ($_ -replace '^/[^/]+/', '') }) -join ", "
        } else { "None" }
        $ipIntelligencePolicy = if ($vs.ipIntelligencePolicy) {
            ($vs.ipIntelligencePolicy -replace '^/[^/]+/', '')
        } else { "None" }

        # Additional configuration flags
        $enabled = if ($vs.enabled -eq $true) { "Enabled" } else { "Disabled" }
        $autoLasthop = if ($vs.autoLasthop) { $vs.autoLasthop } else { "default" }
        $cmpEnabled = if ($vs.cmpEnabled) { $vs.cmpEnabled } else { "N/A" }
        $mirror = if ($vs.mirror) { $vs.mirror } else { "disabled" }
        $nat64 = if ($vs.nat64) { $vs.nat64 } else { "disabled" }
        $sourcePort = if ($vs.sourcePort) { $vs.sourcePort } else { "preserve" }
        $vsIndex = if ($vs.vsIndex) { $vs.vsIndex } else { 0 }
        $gtmScore = if ($vs.gtmScore) { $vs.gtmScore } else { 0 }
        $serviceDownImmediateAction = if ($vs.serviceDownImmediateAction) {
            $vs.serviceDownImmediateAction
        } else { "none" }
        $lastHopPool = if ($vs.lastHopPool) {
            ($vs.lastHopPool -replace '^/[^/]+/', '')
        } else { "None" }
        $clonePools = if ($vs.clonePools) {
            ($vs.clonePools | ForEach-Object { $_.name }) -join ", "
        } else { "None" }
        $addressStatus = if ($vs.addressStatus) { $vs.addressStatus } else { "N/A" }

        # Rate-limiting detail
        $rateLimitMode = if ($vs.rateLimitMode) { $vs.rateLimitMode } else { "object" }
        $rateLimitDstMask = if ($vs.rateLimitDstMask) { $vs.rateLimitDstMask } else { 0 }
        $rateLimitSrcMask = if ($vs.rateLimitSrcMask) { $vs.rateLimitSrcMask } else { 0 }

        # Metadata (key/value pairs attached to the VS)
        $metadata = if ($vs.metadata) {
            ($vs.metadata | ForEach-Object { "$($_.name)=$($_.value)" }) -join "; "
        } else { "" }

        # Eviction
        $flowEvictionPolicy = if ($vs.flowEvictionPolicy) {
            ($vs.flowEvictionPolicy -replace '^/[^/]+/', '')
        } else { "None" }
        $evictionProtected = if ($vs.evictionProtected) { $vs.evictionProtected } else { "disabled" }

        # Type / subtype flags
        $vsType = if ($vs.kind) { ($vs.kind -replace 'tm:ltm:virtual:', '' -replace 'state$', '') } else { "standard" }
        $ipForward = if ($vs.ipForward -eq $true) { "Yes" } else { "No" }
        $internal = if ($vs.internal -eq $true) { "Yes" } else { "No" }
        $reject = if ($vs.reject -eq $true) { "Yes" } else { "No" }
        $l2Forward = if ($vs.l2Forward -eq $true) { "Yes" } else { "No" }
        $stateless = if ($vs.stateless -eq $true) { "Yes" } else { "No" }

        # HA / traffic group
        $trafficGroup = if ($vs.trafficGroup) {
            ($vs.trafficGroup -replace '^/[^/]+/', '')
        } else { "N/A" }

        # iApp association
        $appService = if ($vs.appService) {
            ($vs.appService -replace '^/[^/]+/', '')
        } else { "None" }
        $subPath = if ($vs.subPath) { $vs.subPath } else { "N/A" }

        # Generation (config revision)
        $generation = if ($vs.generation) { $vs.generation } else { 0 }

        # Bandwidth controller policy
        $bwcPolicy = if ($vs.bwcPolicy) {
            ($vs.bwcPolicy -replace '^/[^/]+/', '')
        } else { "None" }

        # PVA hardware acceleration
        $pvaAcceleration = if ($vs.pvaAcceleration) { $vs.pvaAcceleration } else { "none" }

        # Security NAT policy
        $securityNatPolicy = if ($vs.securityNatPolicy) {
            ($vs.securityNatPolicy -replace '^/[^/]+/', '')
        } else { "None" }

        # Service policy
        $servicePolicy = if ($vs.servicePolicy) {
            ($vs.servicePolicy -replace '^/[^/]+/', '')
        } else { "None" }

        # Per-flow APM access policy
        $perFlowRequestAccessPolicy = if ($vs.perFlowRequestAccessPolicy) {
            ($vs.perFlowRequestAccessPolicy -replace '^/[^/]+/', '')
        } else { "None" }

        # HTTP MRF routing
        $httpMrfRoutingEnabled = if ($vs.httpMrfRoutingEnabled) { $vs.httpMrfRoutingEnabled } else { "disabled" }

        # Traffic matching criteria (BIG-IP 14.1+ alternative to destination)
        $trafficMatchingCriteria = if ($vs.trafficMatchingCriteria) {
            ($vs.trafficMatchingCriteria -replace '^/[^/]+/', '')
        } else { "N/A" }

        # Inline firewall rules
        $fwRules = if ($vs.fwRules) {
            ($vs.fwRules | ForEach-Object { if ($_.name) { $_.name } else { $_ } }) -join ", "
        } else { "None" }

        # Creation / modification timestamps
        $creationTime = if ($vs.creationTime) { $vs.creationTime } else { "N/A" }
        $lastModifiedTime = if ($vs.lastModifiedTime) { $vs.lastModifiedTime } else { "N/A" }

        [PSCustomObject]@{
            Name                       = $vs.name
            FullPath                   = $vs.fullPath
            Partition                  = $vs.partition
            Description                = if ($vs.description) { $vs.description } else { "" }
            Destination                = $dest
            Address                    = $vsAddress
            Port                       = $vsPort
            Protocol                   = if ($vs.ipProtocol) { $vs.ipProtocol.ToUpper() } else { "N/A" }
            Pool                       = $poolName
            PoolPath                   = $poolPath
            Enabled                    = $enabled
            Profiles                   = $profileNames
            ProfilesDetailed           = $profilesDetailedStr
            Persistence                = $persistence
            FallbackPersistence        = $fallbackPersistence
            iRules                     = $irules
            Policies                   = $policiesStr
            SNATType                   = $snatType
            SNATPool                   = $snatPool
            Source                     = if ($vs.source) { $vs.source } else { "0.0.0.0/0" }
            Mask                       = if ($vs.mask) { $vs.mask } else { "N/A" }
            ConnectionLimit            = if ($vs.connectionLimit) { $vs.connectionLimit } else { 0 }
            RateLimit                  = if ($vs.rateLimit) { $vs.rateLimit } else { "disabled" }
            RateLimitMode              = $rateLimitMode
            RateLimitDstMask           = $rateLimitDstMask
            RateLimitSrcMask           = $rateLimitSrcMask
            TranslateAddress           = if ($vs.translateAddress) { $vs.translateAddress } else { "N/A" }
            TranslatePort              = if ($vs.translatePort) { $vs.translatePort } else { "N/A" }
            AutoLasthop                = $autoLasthop
            CMPEnabled                 = $cmpEnabled
            Mirror                     = $mirror
            NAT64                      = $nat64
            SourcePort                 = $sourcePort
            AddressStatus              = $addressStatus
            VSIndex                    = $vsIndex
            GTMScore                   = $gtmScore
            ServiceDownAction          = $serviceDownImmediateAction
            LastHopPool                = $lastHopPool
            ClonePools                 = $clonePools
            VLANs                      = $vlans
            VLANsEnabled               = $vlansEnabled
            VLANsDisabled              = $vlansDisabled
            FWEnforcedPolicy           = $fwEnforcedPolicy
            FWStagedPolicy             = $fwStagedPolicy
            FWRules                    = $fwRules
            SecurityLogProfiles        = $securityLogProfiles
            IPIntelligencePolicy       = $ipIntelligencePolicy
            SecurityNatPolicy          = $securityNatPolicy
            FlowEvictionPolicy         = $flowEvictionPolicy
            EvictionProtected          = $evictionProtected
            Metadata                   = $metadata
            IPForward                  = $ipForward
            Internal                   = $internal
            Reject                     = $reject
            L2Forward                  = $l2Forward
            Stateless                  = $stateless
            VSType                     = $vsType
            TrafficGroup               = $trafficGroup
            AppService                 = $appService
            SubPath                    = $subPath
            Generation                 = $generation
            BwcPolicy                  = $bwcPolicy
            PvaAcceleration            = $pvaAcceleration
            ServicePolicy              = $servicePolicy
            PerFlowRequestAccessPolicy = $perFlowRequestAccessPolicy
            HttpMrfRoutingEnabled      = $httpMrfRoutingEnabled
            TrafficMatchingCriteria    = $trafficMatchingCriteria
            CreationTime               = $creationTime
            LastModifiedTime           = $lastModifiedTime
        }
    }
}

# ---------------------------------------------------------------------------
# Get-F5VirtualServerStats
# ---------------------------------------------------------------------------
function Get-F5VirtualServerStats {
    <#
    .SYNOPSIS
        Returns real-time statistics for all virtual servers.
    .DESCRIPTION
        Queries /mgmt/tm/ltm/virtual/stats to retrieve connection counts,
        bytes in/out, availability state, etc.
    .EXAMPLE
        Get-F5VirtualServerStats
        # Returns stats for all virtual servers.
    .EXAMPLE
        Get-F5VirtualServerStats | Where-Object { $_.ClientsideCurConns -gt 0 } | Select-Object Name, ClientsideCurConns, AvailabilityState
        # Show only VS with active connections.
    .EXAMPLE
        Get-F5VirtualServerStats | Sort-Object ClientsideTotConns -Descending | Select-Object -First 10 Name, ClientsideTotConns
        # Top 10 virtual servers by total connection count.
    #>
    [CmdletBinding()]
    param()

    $response = Invoke-F5RestMethod -Endpoint "/mgmt/tm/ltm/virtual/stats"
    $results = @()

    foreach ($prop in $response.entries.PSObject.Properties) {
        $stats = $prop.Value.nestedStats.entries

        $vsName = $stats.'tmName'.description -replace '^/[^/]+/', ''

        # Helper to safely read a stat value
        $readLong = { param($key) if ($stats.$key) { [long]$stats.$key.value } else { 0 } }
        $readInt  = { param($key) if ($stats.$key) { [int]$stats.$key.value } else { 0 } }
        $readDesc = { param($key) if ($stats.$key) { $stats.$key.description } else { "N/A" } }

        $results += [PSCustomObject]@{
            Name                       = $vsName
            Destination                = & $readDesc 'destination'
            # --- Status ---
            AvailabilityState          = $stats.'status.availabilityState'.description
            EnabledState               = $stats.'status.enabledState'.description
            StatusReason               = $stats.'status.statusReason'.description
            # --- Client-side traffic ---
            ClientsideBitsIn           = [long]$stats.'clientside.bitsIn'.value
            ClientsideBitsOut          = [long]$stats.'clientside.bitsOut'.value
            ClientsideCurConns         = [int]$stats.'clientside.curConns'.value
            ClientsideMaxConns         = [int]$stats.'clientside.maxConns'.value
            ClientsideTotConns         = [long]$stats.'clientside.totConns'.value
            ClientsidePktsIn           = [long]$stats.'clientside.pktsIn'.value
            ClientsidePktsOut          = [long]$stats.'clientside.pktsOut'.value
            ClientsideEvictedConns     = & $readLong 'clientside.evictedConns'
            ClientsideSlowKilled       = & $readLong 'clientside.slowKilled'
            # --- Ephemeral traffic ---
            EphemeralBitsIn            = & $readLong 'ephemeral.bitsIn'
            EphemeralBitsOut           = & $readLong 'ephemeral.bitsOut'
            EphemeralCurConns          = & $readInt  'ephemeral.curConns'
            EphemeralMaxConns          = & $readInt  'ephemeral.maxConns'
            EphemeralTotConns          = & $readLong 'ephemeral.totConns'
            EphemeralPktsIn            = & $readLong 'ephemeral.pktsIn'
            EphemeralPktsOut           = & $readLong 'ephemeral.pktsOut'
            EphemeralEvictedConns      = & $readLong 'ephemeral.evictedConns'
            EphemeralSlowKilled        = & $readLong 'ephemeral.slowKilled'
            # --- Request / response ---
            TotalRequests              = & $readLong 'totRequests'
            # --- Connection duration ---
            CsMeanConnDuration         = & $readLong 'csMeanConnDur'
            CsMaxConnDuration          = & $readLong 'csMaxConnDur'
            CsMinConnDuration          = & $readLong 'csMinConnDur'
            # --- Usage ratios ---
            FiveSecAvgUsageRatio       = & $readInt 'fiveSecAvgUsageRatio'
            OneMinAvgUsageRatio        = & $readInt 'oneMinAvgUsageRatio'
            FiveMinAvgUsageRatio       = & $readInt 'fiveMinAvgUsageRatio'
            # --- SYN cookies ---
            SyncookieStatus            = & $readDesc 'syncookieStatus'
            SyncookieAccepts           = & $readLong 'syncookie.accepts'
            SyncookieRejects           = & $readLong 'syncookie.rejects'
            SyncookieSyncacheCurr      = & $readInt  'syncookie.syncacheCurr'
            SyncookieSyncacheOver      = & $readLong 'syncookie.syncacheOver'
            SyncookieSwTotal           = & $readLong 'syncookie.swsyncookieInstance'
            # --- Hardware SYN cookies ---
            SyncookieHwAccepts         = & $readLong 'syncookieHw.accepts'
            SyncookieHwRejects         = & $readLong 'syncookieHw.rejects'
            SyncookieHwSyncookies      = & $readLong 'syncookieHw.syncookies'
            # --- Misc counters ---
            TotPvaAssistConn           = & $readLong 'totPvaAssistConn'
            CmpEnableMode              = & $readDesc 'cmpEnableMode'
            CmpEnabled                 = & $readDesc 'cmpEnabled'
            VSType                     = & $readDesc 'vsType'
            # --- Additional counters ---
            ClientsideTotRequests      = & $readLong 'clientside.totRequests'
            EphemeralTotRequests       = & $readLong 'ephemeral.totRequests'
            StatusCount                = & $readLong 'status.statusCount'
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Get-F5Pools
# ---------------------------------------------------------------------------
function Get-F5Pools {
    <#
    .SYNOPSIS
        Returns all LTM pools from the BIG-IP.
    .DESCRIPTION
        Queries /mgmt/tm/ltm/pool and returns key properties including
        load balancing mode, monitor, active/total member counts.
    .PARAMETER Partition
        Filter by partition name. Defaults to all partitions.
    .EXAMPLE
        Get-F5Pools
        # Returns all pools across all partitions.
    .EXAMPLE
        Get-F5Pools -Partition "Common" | Select-Object Name, LoadBalancingMode, Monitor, ActiveMemberCount
        # List pools in the Common partition with their LB mode and health monitors.
    .EXAMPLE
        Get-F5Pools | Where-Object { $_.ActiveMemberCount -eq 0 }
        # Find pools with no active members (potential outage).
    #>
    [CmdletBinding()]
    param(
        [string]$Partition
    )

    $response = Invoke-F5RestMethod -Endpoint "/mgmt/tm/ltm/pool"

    foreach ($pool in $response.items) {
        if ($Partition -and $pool.partition -ne $Partition) { continue }

        $monitor = if ($pool.monitor) {
            ($pool.monitor -replace ' and ', ', ') -replace '/Common/', ''
        } else { "None" }

        [PSCustomObject]@{
            Name              = $pool.name
            FullPath          = $pool.fullPath
            Partition         = $pool.partition
            Description       = if ($pool.description) { $pool.description } else { "" }
            LoadBalancingMode = if ($pool.loadBalancingMode) { $pool.loadBalancingMode } else { "round-robin" }
            Monitor           = $monitor
            ActiveMemberCount = if ($null -ne $pool.activeMemberCnt) { $pool.activeMemberCnt } else { 0 }
            MembersTotal      = if ($pool.membersReference -and $pool.membersReference.items) { $pool.membersReference.items.Count } else { 0 }
            MinActiveMembers  = if ($pool.minActiveMembers) { $pool.minActiveMembers } else { 0 }
            SlowRampTime      = if ($pool.slowRampTime) { $pool.slowRampTime } else { 10 }
        }
    }
}

# ---------------------------------------------------------------------------
# Get-F5PoolMembers
# ---------------------------------------------------------------------------
function Get-F5PoolMembers {
    <#
    .SYNOPSIS
        Returns the members (real servers) of one or all pools.
    .DESCRIPTION
        Queries /mgmt/tm/ltm/pool/~{partition}~{poolName}/members for
        each pool. Returns address, port, state, session, ratio, etc.
    .PARAMETER PoolName
        Name of a specific pool to query. If omitted, queries all pools.
    .PARAMETER Partition
        Partition name. Defaults to Common.
    .EXAMPLE
        Get-F5PoolMembers
        # Returns all members across all pools in the Common partition.
    .EXAMPLE
        Get-F5PoolMembers -PoolName "web_pool" | Select-Object MemberName, Address, Port, State, Session
        # List members of a specific pool with their health state.
    .EXAMPLE
        Get-F5PoolMembers -Partition "Production" | Where-Object { $_.State -ne 'up' }
        # Find unhealthy pool members in the Production partition.
    #>
    [CmdletBinding()]
    param(
        [string]$PoolName,
        [string]$Partition = "Common"
    )

    if ($PoolName) {
        $pools = @([PSCustomObject]@{ Name = $PoolName; Partition = $Partition })
    }
    else {
        $pools = Get-F5Pools -Partition $Partition
    }

    foreach ($pool in $pools) {
        $endpoint = "/mgmt/tm/ltm/pool/~$($pool.Partition)~$($pool.Name)/members"
        try {
            $response = Invoke-F5RestMethod -Endpoint $endpoint
        }
        catch {
            Write-Verbose "Could not retrieve members for pool $($pool.Name): $($_.Exception.Message)"
            continue
        }

        foreach ($member in $response.items) {
            # Parse name  "server1:80"
            $nameParts = $member.name -split ':'
            $nodeName = $nameParts[0]
            $nodePort = if ($nameParts.Count -gt 1) { $nameParts[1] } else { "any" }

            [PSCustomObject]@{
                PoolName      = $pool.Name
                MemberName    = $member.name
                NodeName      = $nodeName
                Address       = if ($member.address) { ($member.address -replace '%\d+$', '') } else { "N/A" }
                Port          = $nodePort
                State         = if ($member.state) { $member.state } else { "N/A" }
                Session       = if ($member.session) { $member.session } else { "N/A" }
                MonitorStatus = if ($member.monitor) { $member.monitor } else { "default" }
                Ratio         = if ($member.ratio) { $member.ratio } else { 1 }
                Priority      = if ($member.priorityGroup) { $member.priorityGroup } else { 0 }
                ConnectionLimit = if ($member.connectionLimit) { $member.connectionLimit } else { 0 }
                Description   = if ($member.description) { $member.description } else { "" }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Get-F5PoolMemberStats
# ---------------------------------------------------------------------------
function Get-F5PoolMemberStats {
    <#
    .SYNOPSIS
        Returns live statistics for members of one or all pools.
    .DESCRIPTION
        Queries the stats sub-collection for pool members to get current
        connections, availability, bytes in/out, etc.
    .PARAMETER PoolName
        Name of a specific pool. If omitted, queries all pools.
    .PARAMETER Partition
        Partition name. Defaults to Common.
    .EXAMPLE
        Get-F5PoolMemberStats
        # Returns stats for all pool members in the Common partition.
    .EXAMPLE
        Get-F5PoolMemberStats -PoolName "web_pool" | Select-Object MemberName, CurConns, AvailabilityState
        # Check active connections and health for a specific pool's members.
    .EXAMPLE
        Get-F5PoolMemberStats | Sort-Object CurConns -Descending | Select-Object -First 5 PoolName, MemberName, CurConns
        # Top 5 busiest pool members.
    #>
    [CmdletBinding()]
    param(
        [string]$PoolName,
        [string]$Partition = "Common"
    )

    if ($PoolName) {
        $pools = @([PSCustomObject]@{ Name = $PoolName; Partition = $Partition })
    }
    else {
        $pools = Get-F5Pools -Partition $Partition
    }

    $results = @()
    foreach ($pool in $pools) {
        $endpoint = "/mgmt/tm/ltm/pool/~$($pool.Partition)~$($pool.Name)/members/stats"
        try {
            $response = Invoke-F5RestMethod -Endpoint $endpoint
        }
        catch {
            Write-Verbose "Could not retrieve member stats for pool $($pool.Name): $($_.Exception.Message)"
            continue
        }

        foreach ($prop in $response.entries.PSObject.Properties) {
            $stats = $prop.Value.nestedStats.entries
            $memberName = $stats.'tmName'.description -replace '^/[^/]+/', ''
            $nodeName = $stats.'nodeName'.description -replace '^/[^/]+/', ''

            $results += [PSCustomObject]@{
                PoolName              = $pool.Name
                MemberName            = $memberName
                NodeName              = $nodeName
                Address               = $stats.'addr'.description
                Port                  = [int]$stats.'port'.value
                AvailabilityState     = $stats.'status.availabilityState'.description
                EnabledState          = $stats.'status.enabledState'.description
                StatusReason          = $stats.'status.statusReason'.description
                CurrentSessions       = [int]$stats.'curSessions'.value
                ServersideBitsIn      = [long]$stats.'serverside.bitsIn'.value
                ServersideBitsOut     = [long]$stats.'serverside.bitsOut'.value
                ServersideCurConns    = [int]$stats.'serverside.curConns'.value
                ServersideMaxConns    = [int]$stats.'serverside.maxConns'.value
                ServersideTotConns    = [long]$stats.'serverside.totConns'.value
                TotalRequests         = if ($stats.'totRequests') { [long]$stats.'totRequests'.value } else { 0 }
            }
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Get-F5Nodes
# ---------------------------------------------------------------------------
function Get-F5Nodes {
    <#
    .SYNOPSIS
        Returns all LTM nodes from the BIG-IP.
    .DESCRIPTION
        Queries /mgmt/tm/ltm/node for every node and returns address,
        FQDN, state, monitor, etc.
    .EXAMPLE
        Get-F5Nodes
        # Returns all nodes.
    .EXAMPLE
        Get-F5Nodes | Select-Object Name, Address, FQDN, State | Format-Table
        # Quick overview of all node addresses and health.
    .EXAMPLE
        Get-F5Nodes | Where-Object { $_.State -ne 'up' }
        # Find nodes that are not in an 'up' state.
    #>
    [CmdletBinding()]
    param()

    $response = Invoke-F5RestMethod -Endpoint "/mgmt/tm/ltm/node"

    foreach ($node in $response.items) {
        $fqdn = if ($node.fqdn -and $node.fqdn.tmName) { $node.fqdn.tmName } else { "N/A" }

        [PSCustomObject]@{
            Name      = $node.name
            FullPath  = $node.fullPath
            Partition = $node.partition
            Address   = if ($node.address) { ($node.address -replace '%\d+$', '') } else { "N/A" }
            FQDN      = $fqdn
            State     = if ($node.state) { $node.state } else { "N/A" }
            Session   = if ($node.session) { $node.session } else { "N/A" }
            Monitor   = if ($node.monitor) { ($node.monitor -replace '/Common/', '') } else { "default" }
            Ratio     = if ($node.ratio) { $node.ratio } else { 1 }
        }
    }
}

# ---------------------------------------------------------------------------
# Get-F5Dashboard
# ---------------------------------------------------------------------------
function Get-F5Dashboard {
    <#
    .SYNOPSIS
        Builds a comprehensive dashboard combining VS, pool, and member data.
    .DESCRIPTION
        Correlates virtual servers with their pools and pool members to
        produce a flat collection of objects suitable for HTML table rendering.
        Each row represents one pool member within the context of its VS.
        Virtual servers with no pool still appear as a single row.
    .PARAMETER IncludeStats
        Whether to include live statistics (connections, bytes, etc.).
        Defaults to $true.
    .PARAMETER Partition
        Filter by partition. Defaults to all partitions.
    .EXAMPLE
        $data = Get-F5Dashboard
        $data | Select-Object VSName, VSStatus, PoolName, MemberName, MemberState | Format-Table
        # Full dashboard with stats - VS, pool, and member health at a glance.
    .EXAMPLE
        Get-F5Dashboard -IncludeStats $false
        # Skip live stats for faster results (config data only).
    .EXAMPLE
        Get-F5Dashboard -Partition "Production" | Where-Object { $_.VSStatus -match 'Offline' }
        # Find offline virtual servers in the Production partition.
    .EXAMPLE
        $data = Get-F5Dashboard
        $data | Group-Object VSStatus | Select-Object Name, Count
        # Summary of VS health statuses.
    #>
    [CmdletBinding()]
    param(
        [bool]$IncludeStats = $true,
        [string]$Partition
    )

    # Gather all virtual servers
    $virtualServers = @(Get-F5VirtualServers -Partition $Partition)

    # Discover every partition that has a pool referenced by a VS
    $partitions = @($virtualServers | ForEach-Object { $_.Partition } | Sort-Object -Unique)
    if ($partitions.Count -eq 0) { $partitions = @("Common") }

    # Gather all pools and members across all relevant partitions
    $allPools   = @()
    $allMembers = @()
    foreach ($part in $partitions) {
        $allPools   += @(Get-F5Pools -Partition $part)
        $allMembers += @(Get-F5PoolMembers -Partition $part)
    }

    # Index pools by name for fast lookup (key = "partition/poolName")
    $poolIndex = @{}
    foreach ($p in $allPools) {
        $poolIndex["$($p.Partition)/$($p.Name)"] = $p
        $poolIndex[$p.Name] = $p           # also index by bare name for convenience
    }

    $vsStats = @{}
    $memberStats = @{}

    if ($IncludeStats) {
        $vsStatsRaw = @(Get-F5VirtualServerStats)
        foreach ($s in $vsStatsRaw) { $vsStats[$s.Name] = $s }

        foreach ($part in $partitions) {
            $memberStatsRaw = @(Get-F5PoolMemberStats -Partition $part)
            foreach ($s in $memberStatsRaw) {
                $key = "$($s.PoolName)::$($s.MemberName)"
                $memberStats[$key] = $s
            }
        }
    }

    # Resolve node hostnames
    $nodes = @{}
    try {
        $nodeList = @(Get-F5Nodes)
        foreach ($n in $nodeList) {
            $nodes[$n.Name] = $n
        }
    }
    catch {
        Write-Verbose "Could not retrieve nodes: $($_.Exception.Message)"
    }

    $dashboard = @()

    foreach ($vs in $virtualServers) {
        # VS-level stats
        $vsStat = if ($vsStats.ContainsKey($vs.Name)) { $vsStats[$vs.Name] } else { $null }
        $vsAvail = if ($vsStat) { $vsStat.AvailabilityState } else { "unknown" }
        $vsEnabledState = if ($vsStat) { $vsStat.EnabledState } else { $vs.Enabled }
        $vsStatusReason = if ($vsStat) { $vsStat.StatusReason } else { "" }
        $vsCurrentConns = if ($vsStat) { $vsStat.ClientsideCurConns } else { 0 }
        $vsTotalConns = if ($vsStat) { $vsStat.ClientsideTotConns } else { 0 }
        $vsBitsIn = if ($vsStat) { $vsStat.ClientsideBitsIn } else { 0 }
        $vsBitsOut = if ($vsStat) { $vsStat.ClientsideBitsOut } else { 0 }
        $vsMaxConns = if ($vsStat) { $vsStat.ClientsideMaxConns } else { 0 }
        $vsPktsIn = if ($vsStat) { $vsStat.ClientsidePktsIn } else { 0 }
        $vsPktsOut = if ($vsStat) { $vsStat.ClientsidePktsOut } else { 0 }
        $vsEvictedConns = if ($vsStat) { $vsStat.ClientsideEvictedConns } else { 0 }
        $vsSlowKilled = if ($vsStat) { $vsStat.ClientsideSlowKilled } else { 0 }
        $vsTotalRequests = if ($vsStat) { $vsStat.TotalRequests } else { 0 }
        $vsMeanConnDur = if ($vsStat) { $vsStat.CsMeanConnDuration } else { 0 }
        $vsMaxConnDur = if ($vsStat) { $vsStat.CsMaxConnDuration } else { 0 }
        $vsMinConnDur = if ($vsStat) { $vsStat.CsMinConnDuration } else { 0 }
        $vs5secAvg = if ($vsStat) { $vsStat.FiveSecAvgUsageRatio } else { 0 }
        $vs1minAvg = if ($vsStat) { $vsStat.OneMinAvgUsageRatio } else { 0 }
        $vs5minAvg = if ($vsStat) { $vsStat.FiveMinAvgUsageRatio } else { 0 }
        $vsSyncookieStatus = if ($vsStat) { $vsStat.SyncookieStatus } else { "N/A" }
        # Ephemeral stats
        $vsEphBitsIn = if ($vsStat) { $vsStat.EphemeralBitsIn } else { 0 }
        $vsEphBitsOut = if ($vsStat) { $vsStat.EphemeralBitsOut } else { 0 }
        $vsEphCurConns = if ($vsStat) { $vsStat.EphemeralCurConns } else { 0 }
        $vsEphTotConns = if ($vsStat) { $vsStat.EphemeralTotConns } else { 0 }

        # Determine a combined VS status indicator
        $vsStatus = Get-F5StatusIndicator -AvailabilityState $vsAvail -EnabledState $vsEnabledState

        # Build a reusable hashtable of all VS-level columns
        $vsColumns = [ordered]@{
            # --- Identity ---
            VSName                     = $vs.Name
            VSFullPath                 = $vs.FullPath
            VSPartition                = $vs.Partition
            VSDescription              = $vs.Description
            VSType                     = $vs.VSType
            VSIndex                    = $vs.VSIndex
            VSCreationTime             = $vs.CreationTime
            VSLastModifiedTime         = $vs.LastModifiedTime
            # --- Destination ---
            VSAddress                  = $vs.Address
            VSPort                     = $vs.Port
            VSProtocol                 = $vs.Protocol
            VSDestination              = $vs.Destination
            VSSource                   = $vs.Source
            VSMask                     = $vs.Mask
            # --- Status ---
            VSStatus                   = $vsStatus
            VSAvailability             = $vsAvail
            VSEnabled                  = $vsEnabledState
            VSStatusReason             = $vsStatusReason
            # --- Traffic stats: client-side ---
            VSCurrentConns             = $vsCurrentConns
            VSMaxConns                 = $vsMaxConns
            VSTotalConns               = $vsTotalConns
            VSTotalRequests            = $vsTotalRequests
            VSBitsIn                   = Format-F5Bytes -Bits $vsBitsIn
            VSBitsOut                  = Format-F5Bytes -Bits $vsBitsOut
            VSPktsIn                   = $vsPktsIn
            VSPktsOut                  = $vsPktsOut
            VSEvictedConns             = $vsEvictedConns
            VSSlowKilled               = $vsSlowKilled
            # --- Connection duration ---
            VSMeanConnDuration         = $vsMeanConnDur
            VSMaxConnDuration          = $vsMaxConnDur
            VSMinConnDuration          = $vsMinConnDur
            # --- Usage ratios ---
            VS5SecAvgUsage             = $vs5secAvg
            VS1MinAvgUsage             = $vs1minAvg
            VS5MinAvgUsage             = $vs5minAvg
            # --- Ephemeral traffic ---
            VSEphBitsIn                = Format-F5Bytes -Bits $vsEphBitsIn
            VSEphBitsOut               = Format-F5Bytes -Bits $vsEphBitsOut
            VSEphCurrentConns          = $vsEphCurConns
            VSEphTotalConns            = $vsEphTotConns
            # --- SYN cookie ---
            VSSyncookieStatus          = $vsSyncookieStatus
            # --- Configuration ---
            VSProfiles                 = $vs.Profiles
            VSProfilesDetailed         = $vs.ProfilesDetailed
            VSPersistence              = $vs.Persistence
            VSFallbackPersistence      = $vs.FallbackPersistence
            VSiRules                   = $vs.iRules
            VSPolicies                 = $vs.Policies
            VSSNATType                 = $vs.SNATType
            VSSNATPool                 = $vs.SNATPool
            VSTranslateAddress         = $vs.TranslateAddress
            VSTranslatePort            = $vs.TranslatePort
            VSSourcePort               = $vs.SourcePort
            VSConnectionLimit          = $vs.ConnectionLimit
            VSRateLimit                = $vs.RateLimit
            VSRateLimitMode            = $vs.RateLimitMode
            VSRateLimitDstMask         = $vs.RateLimitDstMask
            VSRateLimitSrcMask         = $vs.RateLimitSrcMask
            # --- Networking ---
            VSAutoLasthop              = $vs.AutoLasthop
            VSLastHopPool              = $vs.LastHopPool
            VSCMPEnabled               = $vs.CMPEnabled
            VSMirror                   = $vs.Mirror
            VSNAT64                    = $vs.NAT64
            VSVLANs                    = $vs.VLANs
            VSVLANsEnabled             = $vs.VLANsEnabled
            VSVLANsDisabled            = $vs.VLANsDisabled
            VSAddressStatus            = $vs.AddressStatus
            # --- Security ---
            VSFWEnforcedPolicy         = $vs.FWEnforcedPolicy
            VSFWStagedPolicy           = $vs.FWStagedPolicy
            VSSecurityLogProfiles      = $vs.SecurityLogProfiles
            VSIPIntelligencePolicy     = $vs.IPIntelligencePolicy
            # --- Advanced ---
            VSGTMScore                 = $vs.GTMScore
            VSServiceDownAction        = $vs.ServiceDownAction
            VSClonePools               = $vs.ClonePools
            VSFlowEvictionPolicy       = $vs.FlowEvictionPolicy
            VSEvictionProtected        = $vs.EvictionProtected
            VSIPForward                = $vs.IPForward
            VSInternal                 = $vs.Internal
            VSReject                   = $vs.Reject
            VSL2Forward                = $vs.L2Forward
            VSStateless                = $vs.Stateless
            VSMetadata                 = $vs.Metadata
            # --- HA / iApp ---
            VSTrafficGroup             = $vs.TrafficGroup
            VSAppService               = $vs.AppService
            VSSubPath                  = $vs.SubPath
            VSGeneration               = $vs.Generation
            # --- Bandwidth / accel ---
            VSBwcPolicy                = $vs.BwcPolicy
            VSPvaAcceleration          = $vs.PvaAcceleration
            # --- Additional security ---
            VSSecurityNatPolicy        = $vs.SecurityNatPolicy
            VSFWRules                  = $vs.FWRules
            # --- Policies / routing ---
            VSServicePolicy            = $vs.ServicePolicy
            VSPerFlowAccessPolicy      = $vs.PerFlowRequestAccessPolicy
            VSHttpMrfRoutingEnabled    = $vs.HttpMrfRoutingEnabled
            VSTrafficMatchingCriteria  = $vs.TrafficMatchingCriteria
        }

        # Members for this VS's pool
        $poolMembers = @($allMembers | Where-Object { $_.PoolName -eq $vs.Pool })

        # Look up pool-level info from the pre-cached index
        $poolInfo = if ($poolIndex.ContainsKey("$($vs.Partition)/$($vs.Pool)")) {
            $poolIndex["$($vs.Partition)/$($vs.Pool)"]
        } elseif ($poolIndex.ContainsKey($vs.Pool)) {
            $poolIndex[$vs.Pool]
        } else { $null }

        if ($poolMembers.Count -eq 0) {
            # VS with no pool or no members - emit a single row with all VS columns
            $row = [ordered]@{}
            $row["TrafficChain"]           = "$($vs.Name) -> $($vs.Pool) -> (no members)"
            foreach ($k in $vsColumns.Keys) { $row[$k] = $vsColumns[$k] }
            $row["PoolName"]              = $vs.Pool
            $row["PoolFullPath"]          = if ($vs.PoolPath) { $vs.PoolPath } else { "" }
            $row["PoolLBMode"]            = if ($poolInfo) { $poolInfo.LoadBalancingMode } else { "" }
            $row["PoolMonitor"]           = if ($poolInfo) { $poolInfo.Monitor } else { "" }
            $row["PoolActiveMembers"]     = if ($poolInfo) { $poolInfo.ActiveMemberCount } else { 0 }
            $row["PoolTotalMembers"]      = if ($poolInfo) { $poolInfo.MembersTotal } else { 0 }
            $row["PoolMinActiveMembers"]  = if ($poolInfo) { $poolInfo.MinActiveMembers } else { 0 }
            $row["PoolSlowRampTime"]      = if ($poolInfo) { $poolInfo.SlowRampTime } else { 0 }
            $row["MemberName"]            = "N/A"
            $row["MemberAddress"]         = "N/A"
            $row["MemberPort"]            = "N/A"
            $row["MemberHostname"]        = "N/A"
            $row["MemberState"]           = "N/A"
            $row["MemberSession"]         = "N/A"
            $row["MemberMonitor"]         = "N/A"
            $row["MemberRatio"]           = 0
            $row["MemberPriority"]        = 0
            $row["MemberConnLimit"]       = 0
            $row["MemberDescription"]     = ""
            $row["MemberStatus"]          = "N/A"
            $row["MemberAvailability"]    = "N/A"
            $row["MemberCurrentConns"]    = 0
            $row["MemberMaxConns"]        = 0
            $row["MemberTotalConns"]      = 0
            $row["MemberTotalRequests"]   = 0
            $row["MemberBitsIn"]          = "0 B"
            $row["MemberBitsOut"]         = "0 B"
            $row["MemberCurrentSessions"] = 0
            $row["MemberStatusReason"]    = ""
            $dashboard += [PSCustomObject]$row
        }
        else {
            foreach ($member in $poolMembers) {
                $mKey = "$($member.PoolName)::$($member.MemberName)"
                $mStat = if ($memberStats.ContainsKey($mKey)) { $memberStats[$mKey] } else { $null }
                $mAvail = if ($mStat) { $mStat.AvailabilityState } else { "unknown" }
                $mEnabled = if ($mStat) { $mStat.EnabledState } else { $member.Session }
                $mCurConns = if ($mStat) { $mStat.ServersideCurConns } else { 0 }
                $mMaxConns = if ($mStat) { $mStat.ServersideMaxConns } else { 0 }
                $mTotConns = if ($mStat) { $mStat.ServersideTotConns } else { 0 }
                $mTotReqs = if ($mStat) { $mStat.TotalRequests } else { 0 }
                $mBitsIn = if ($mStat) { $mStat.ServersideBitsIn } else { 0 }
                $mBitsOut = if ($mStat) { $mStat.ServersideBitsOut } else { 0 }
                $mCurSessions = if ($mStat) { $mStat.CurrentSessions } else { 0 }
                $mStatusReason = if ($mStat) { $mStat.StatusReason } else { "" }
                $mStatus = Get-F5StatusIndicator -AvailabilityState $mAvail -EnabledState $mEnabled

                # Resolve hostname from node data
                $hostname = "N/A"
                if ($nodes.ContainsKey($member.NodeName)) {
                    $nodeObj = $nodes[$member.NodeName]
                    if ($nodeObj.FQDN -and $nodeObj.FQDN -ne "N/A") {
                        $hostname = $nodeObj.FQDN
                    }
                    else {
                        $hostname = $nodeObj.Name
                    }
                }

                $row = [ordered]@{}
                $row["TrafficChain"]           = "$($vs.Name) -> $($vs.Pool) -> $($member.NodeName):$($member.Port)"
                foreach ($k in $vsColumns.Keys) { $row[$k] = $vsColumns[$k] }
                $row["PoolName"]              = $vs.Pool
                $row["PoolFullPath"]          = if ($vs.PoolPath) { $vs.PoolPath } else { "" }
                $row["PoolLBMode"]            = if ($poolInfo) { $poolInfo.LoadBalancingMode } else { "" }
                $row["PoolMonitor"]           = if ($poolInfo) { $poolInfo.Monitor } else { "" }
                $row["PoolActiveMembers"]     = if ($poolInfo) { $poolInfo.ActiveMemberCount } else { 0 }
                $row["PoolTotalMembers"]      = if ($poolInfo) { $poolInfo.MembersTotal } else { 0 }
                $row["PoolMinActiveMembers"]  = if ($poolInfo) { $poolInfo.MinActiveMembers } else { 0 }
                $row["PoolSlowRampTime"]      = if ($poolInfo) { $poolInfo.SlowRampTime } else { 0 }
                $row["MemberName"]            = $member.NodeName
                $row["MemberAddress"]         = $member.Address
                $row["MemberPort"]            = $member.Port
                $row["MemberHostname"]        = $hostname
                $row["MemberState"]           = $member.State
                $row["MemberSession"]         = $member.Session
                $row["MemberMonitor"]         = $member.MonitorStatus
                $row["MemberRatio"]           = $member.Ratio
                $row["MemberPriority"]        = $member.Priority
                $row["MemberConnLimit"]       = $member.ConnectionLimit
                $row["MemberDescription"]     = $member.Description
                $row["MemberStatus"]          = $mStatus
                $row["MemberAvailability"]    = $mAvail
                $row["MemberCurrentConns"]    = $mCurConns
                $row["MemberMaxConns"]        = $mMaxConns
                $row["MemberTotalConns"]      = $mTotConns
                $row["MemberTotalRequests"]   = $mTotReqs
                $row["MemberBitsIn"]          = Format-F5Bytes -Bits $mBitsIn
                $row["MemberBitsOut"]         = Format-F5Bytes -Bits $mBitsOut
                $row["MemberCurrentSessions"] = $mCurSessions
                $row["MemberStatusReason"]    = $mStatusReason
                $dashboard += [PSCustomObject]$row
            }
        }
    }

    return $dashboard
}

# ---------------------------------------------------------------------------
# Get-F5StatusIndicator
# ---------------------------------------------------------------------------
function Get-F5StatusIndicator {
    <#
    .SYNOPSIS
        Converts F5 availability and enabled states into a human-readable indicator.
    .EXAMPLE
        Get-F5StatusIndicator -AvailabilityState "available" -EnabledState "enabled"
        # Returns: "Available (Green)"
    .EXAMPLE
        Get-F5StatusIndicator -AvailabilityState "offline" -EnabledState "enabled"
        # Returns: "Offline (Red)"
    .EXAMPLE
        Get-F5StatusIndicator -AvailabilityState "available" -EnabledState "disabled"
        # Returns: "Disabled"
    #>
    [CmdletBinding()]
    param(
        [string]$AvailabilityState,
        [string]$EnabledState
    )

    if ($EnabledState -match 'disabled') {
        return "Disabled"
    }

    switch ($AvailabilityState) {
        "available" { return "Available (Green)" }
        "offline"   { return "Offline (Red)" }
        "unknown"   { return "Unknown (Blue)" }
        default     { return "$AvailabilityState" }
    }
}

# ---------------------------------------------------------------------------
# Format-F5Bytes
# ---------------------------------------------------------------------------
function Format-F5Bytes {
    <#
    .SYNOPSIS
        Formats a bit count into a human-readable byte string (KB/MB/GB/TB).
    .EXAMPLE
        Format-F5Bytes -Bits 8388608
        # Returns: "1.00 MB" (8388608 bits = 1 MB)
    .EXAMPLE
        Format-F5Bytes -Bits 0
        # Returns: "0 B"
    #>
    [CmdletBinding()]
    param(
        [long]$Bits
    )

    $bytes = $Bits / 8
    if ($bytes -ge 1TB) { return "{0:N2} TB" -f ($bytes / 1TB) }
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

# ---------------------------------------------------------------------------
# Export-F5DashboardHtml
# ---------------------------------------------------------------------------
function Export-F5DashboardHtml {
    <#
    .SYNOPSIS
        Renders the F5 dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-F5Dashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. Uses
        colour-coded status indicators matching the F5 UI conventions.
    .PARAMETER DashboardData
        Array of objects from Get-F5Dashboard.
    .PARAMETER OutputPath
        File path for the output HTML file.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "F5 BIG-IP Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        built-in template at helpers/f5/F5-Dashboard-Template.html.
    .EXAMPLE
        $data = Get-F5Dashboard
        Export-F5DashboardHtml -DashboardData $data -OutputPath "C:\Reports\f5.html"
        # Generates an HTML dashboard at the specified path.
    .EXAMPLE
        $data = Get-F5Dashboard
        Export-F5DashboardHtml -DashboardData $data -OutputPath "$env:TEMP\f5.html" -ReportTitle "Production F5 Status"
        # Custom report title.
    .EXAMPLE
        # Full end-to-end: connect -> gather -> render -> open
        Connect-F5Server -F5Host "bigip01" -Credential (Get-Credential) -IgnoreSSLErrors
        $data = Get-F5Dashboard
        $outPath = "$env:TEMP\F5-Dashboard.html"
        Export-F5DashboardHtml -DashboardData $data -OutputPath $outPath
        Start-Process $outPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "F5 BIG-IP Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "F5-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    # Build column definitions
    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        # Apply formatters for status columns
        if ($prop.Name -match 'Status$|Availability$') {
            $col.formatter = 'formatStatus'
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson = $DashboardData | ConvertTo-Json -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "F5 Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBf6+IuGO2F8WR6
# oeG/Xo2i9TlWPoAj118pl47XblaZd6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgQ0fj79dzK1dhMZhwqDolQ4i46ivd/D1K
# oRCrx+lh+b8wDQYJKoZIhvcNAQEBBQAEggIAFSYHxn1gaov6e9fRdpT/eLi2w+Nu
# E21bDNytZDLvU08ToROQ3etuTvQTVGjftarCoZQW7OnHhdhWIYFNyVIYQvMhT0q8
# 63eKpJlPMOTjucAngZhFAHzjLqb4Ik8NuDzdU7+vS15mOhRyNn6+QwkgFJuTueJT
# uddTTREo/2diBlWjpHNHQ0sfrXVEJhFXom5KNr5QnlvBNHC/YXtR8+sWi1JNXEdb
# Oa2sJqH9MaTlIv2M0mEqPw+/L8GR1dzGtaS9LPnOU6RBFBwk8IgQBnksNLCHHjh2
# VyzjANMnRWPGpnzA7V8rAiZhYyQESh9wvOxJ6IK8WeTColurYtBNaPwZTAg+EziS
# Mxjvw10OpH6UKLR8yqStAW8UARGIAYl6fzDAuknvSy+kmMgfCAMFnAplXJSd5QXe
# jylSfAE69UZg2zQTAsO0QqSRdKyhd5GEOjRepWHsHXY3KxxccdNhMI0GJxTgJQ9M
# W16QjKnWgIuUKB0N/BZNOcEEgr8sYIJX7ZzFZ6wgGQg+jIZ8/5HlSVNo97Ucytn7
# 6zXighuEcmMSwABI+Tieg/tnkKzxTGq7r4PxAKH7cu7OoI/Wt2GjUKRvxCQSz9nA
# fxv7qAQ3ZbIf8cc1XggFuiq1K/GeSP8D8gcx74xVJkUnXSPIwGz39s5kVIS3Gty2
# 2PgWfZa3uDDoRKs=
# SIG # End signature block
