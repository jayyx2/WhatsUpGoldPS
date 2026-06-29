<#
.SYNOPSIS
    Nutanix discovery provider for hypervisor/cluster monitoring.

.DESCRIPTION
    Registers a Nutanix discovery provider that queries the Prism REST API
    v2.0 to discover clusters, hosts, and VMs, then builds a monitor plan.

    Active Monitors (up/down):
      - Cluster health via /api/nutanix/v2.0/cluster
      - Per-host power state via /api/nutanix/v2.0/hosts/{uuid}
      - Per-VM power state via /api/nutanix/v2.0/vms/{uuid}

    Performance Monitors (stats over time):
      - Host CPU %, memory % via host stats
      - VM CPU %, memory usage via VM stats

    Authentication:
      Nutanix Prism uses HTTP Basic Auth.
      Port 9440 (Prism Element or Prism Central).

    Prerequisites:
      1. Nutanix Prism Element or Central accessible
      2. Username + password with viewer/admin role
      3. Device attribute 'DiscoveryHelper.Nutanix' = 'true'

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM
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

# Load Nutanix helpers
$nutanixHelperPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'nutanix\NutanixHelpers.ps1'
if (Test-Path $nutanixHelperPath) {
    . $nutanixHelperPath
}

# ============================================================================
# Nutanix Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Nutanix' `
    -MatchAttribute 'DiscoveryHelper.Nutanix' `
    -AuthType 'BasicAuth' `
    -DefaultPort 9440 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $hostTarget = $ctx.DeviceIP
        $port = $ctx.Port
        $baseUri = "https://${hostTarget}:${port}"
        $clusterUuidCandidates = @{}
        $apiPopulationLog = New-Object System.Collections.Generic.List[object]
        $apiPathLog = New-Object System.Collections.Generic.List[object]

        # Ensure TLS 1.2 at minimum for Prism calls.
        if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }

        function Enable-NutanixCertBypass {
            if ($PSVersionTable.PSEdition -eq 'Core') { return }

            try {
                # Use a broad protocol set in PS 5.1 to avoid handshake downgrades.
                [System.Net.ServicePointManager]::SecurityProtocol = (
                    [System.Net.SecurityProtocolType]::Tls -bor
                    [System.Net.SecurityProtocolType]::Tls11 -bor
                    [System.Net.SecurityProtocolType]::Tls12
                )
            }
            catch {}

            try {
                if (-not ([System.Management.Automation.PSTypeName]'NutanixSSLValidator').Type) {
                    Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class NutanixSSLValidator {
    private static bool OnValidateCertificate(
        object sender, X509Certificate certificate,
        X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
    public static void OverrideValidation() {
        ServicePointManager.ServerCertificateValidationCallback =
            new RemoteCertificateValidationCallback(OnValidateCertificate);
        ServicePointManager.Expect100Continue = false;
    }
}
"@
                }
                [NutanixSSLValidator]::OverrideValidation()
            }
            catch {}

            # Extra compatibility path for older .NET call sites that still honor CertificatePolicy.
            try {
                if (-not ([System.Management.Automation.PSTypeName]'NutanixTrustAllCertsPolicy').Type) {
                    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public sealed class NutanixTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
                }
                [System.Net.ServicePointManager]::CertificatePolicy = New-Object NutanixTrustAllCertsPolicy
            }
            catch {}
        }

        # SSL bypass for PS 5.1
        if ($ctx.IgnoreCertErrors) {
            Enable-NutanixCertBypass
        }

        function Test-NutanixCertOrTlsError {
            param([string]$Message)

            if (-not $Message) { return $false }
            return (
                ($Message -match 'certificate') -or
                ($Message -match 'trust relationship') -or
                ($Message -match 'SSL/TLS') -or
                ($Message -match 'secure channel') -or
                ($Message -match 'underlying connection was closed')
            )
        }

        function Invoke-NutanixRestInternal {
            param(
                [Parameter(Mandatory = $true)][string]$Uri,
                [ValidateSet('GET', 'POST')][string]$Method = 'GET',
                [string]$Body,
                [hashtable]$Headers,
                [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
            )

            $params = @{
                Uri         = $Uri
                Method      = $Method
                ErrorAction = 'Stop'
            }
            if ($Headers) { $params.Headers = $Headers }
            if ($WebSession) {
                $params.WebSession = $WebSession
                $params.ContentType = 'application/json'
            }
            if ($Body) {
                $params.Body = $Body
                if (-not $params.ContainsKey('ContentType')) { $params.ContentType = 'application/json' }
            }

            try {
                $response = Invoke-RestMethod @params
                Add-NxApiPathLog -Endpoint $Uri -Method $Method -Outcome 'Success' -Response $response -Reason ''
                return $response
            }
            catch {
                if ($ctx.IgnoreCertErrors -and (Test-NutanixCertOrTlsError -Message $_.Exception.Message)) {
                    Enable-NutanixCertBypass
                    $response = Invoke-RestMethod @params
                    Add-NxApiPathLog -Endpoint $Uri -Method $Method -Outcome 'Success' -Response $response -Reason ''
                    return $response
                }
                Add-NxApiPathLog -Endpoint $Uri -Method $Method -Outcome 'Failed' -Response $null -Reason $_.Exception.Message
                throw
            }
        }

        # Build auth header
        $cred = $ctx.Credential
        if (-not $cred) {
            Write-Warning "Nutanix: No credentials provided."
            return $items
        }

        $username = $null
        $password = $null
        if ($cred.PSCredential) {
            $username = $cred.PSCredential.UserName
            $password = $cred.PSCredential.GetNetworkCredential().Password
        }
        elseif ($cred.Username) {
            $username = $cred.Username
            $password = $cred.Password
        }
        if (-not $username) {
            Write-Warning "Nutanix: Could not extract credentials."
            return $items
        }

        $pair = "${username}:${password}"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
        $b64 = [System.Convert]::ToBase64String($bytes)
        $authHeaders = @{
            Authorization  = "Basic $b64"
            'Content-Type' = 'application/json'
            Accept         = 'application/json'
        }
        $pcSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $script:pcSessionReady = $false

        function Get-NxByPath {
            param(
                [Parameter(Mandatory = $true)]$Object,
                [Parameter(Mandatory = $true)][string]$Path
            )

            $current = $Object
            foreach ($segment in ($Path -split '\.')) {
                if ($null -eq $current) { return $null }

                if ($current -is [System.Collections.IDictionary]) {
                    if ($current.Contains($segment)) { $current = $current[$segment] }
                    else { return $null }
                }
                else {
                    $prop = $current.PSObject.Properties[$segment]
                    if ($prop) { $current = $prop.Value }
                    else { return $null }
                }
            }

            return $current
        }

        function Get-NxFirst {
            param(
                [Parameter(Mandatory = $true)]$Object,
                [Parameter(Mandatory = $true)][string[]]$Paths,
                [string]$Default = ''
            )

            foreach ($path in $Paths) {
                $val = Get-NxByPath -Object $Object -Path $path
                if ($null -ne $val -and "$val" -ne '') { return "$val" }
            }
            return $Default
        }

        function Get-NxVmIp {
            param([Parameter(Mandatory = $true)]$Vm)

            $candidate = Get-NxFirst -Object $Vm -Paths @(
                'ipAddress',
                'guest.ipAddress',
                'guestTools.ipAddress',
                'networkInfo.ipv4Address.value',
                'status.resources.nic_list.0.ip_endpoint_list.0.ip'
            )
            if ($candidate -match '^\d{1,3}(\.\d{1,3}){3}$') { return $candidate }

            $nics = Get-NxByPath -Object $Vm -Path 'nics'
            if ($nics) {
                foreach ($nic in @($nics)) {
                    $nicIp = Get-NxFirst -Object $nic -Paths @(
                        'ipAddress',
                        'networkInfo.ipv4Config.ipAddress.value',
                        'networkInfo.ipv4Address.value'
                    )
                    if ($nicIp -match '^\d{1,3}(\.\d{1,3}){3}$' -and $nicIp -notlike '169.254.*') { return $nicIp }
                }
            }

            $legacyNics = Get-NxByPath -Object $Vm -Path 'vm_nics'
            if ($legacyNics) {
                foreach ($nic in @($legacyNics)) {
                    foreach ($f in @('ip_address', 'requested_ip_address')) {
                        $p = $nic.PSObject.Properties[$f]
                        if ($p -and $p.Value -match '^\d{1,3}(\.\d{1,3}){3}$' -and $p.Value -notlike '169.254.*') {
                            return "$($p.Value)"
                        }
                    }
                }
            }

            return ''
        }

        function Ensure-NutanixV3Session {
            if ($script:pcSessionReady) { return $true }

            $loginUri = "${baseUri}/api/nutanix/v3/users/login"
            $loginBody = @{ username = $username; password = $password } | ConvertTo-Json -Depth 4
            try {
                Invoke-NutanixRestInternal -Uri $loginUri -Method 'POST' -Body $loginBody -WebSession $pcSession | Out-Null
                $script:pcSessionReady = $true
                return $true
            }
            catch {
                Write-Verbose "Nutanix v3 session login failed: $($_.Exception.Message)"
                return $false
            }
        }

        # Helper to query Nutanix
        function Invoke-NutanixREST {
            param(
                [string]$Endpoint,
                [ValidateSet('GET', 'POST')][string]$Method = 'GET',
                [string]$Body
            )

            $uri = if ($Endpoint -match '^https?://') { $Endpoint } else { "${baseUri}${Endpoint}" }

            $isV3 = $Endpoint -like '/api/nutanix/v3/*'
            if ($isV3) {
                if (-not (Ensure-NutanixV3Session)) {
                    throw 'Unable to establish Nutanix v3 session.'
                }

                if ($Method -eq 'POST') {
                    return Invoke-NutanixRestInternal -Uri $uri -Method 'POST' -Body $Body -WebSession $pcSession
                }
                return Invoke-NutanixRestInternal -Uri $uri -Method 'GET' -WebSession $pcSession
            }

            if ($Method -eq 'POST') {
                return Invoke-NutanixRestInternal -Uri $uri -Method 'POST' -Body $Body -Headers $authHeaders
            }
            Invoke-NutanixRestInternal -Uri $uri -Method 'GET' -Headers $authHeaders
        }

        function Convert-NutanixResponseToList {
            param([Parameter(Mandatory = $true)]$Response)

            if ($null -eq $Response) { return @() }
            if ($Response -is [System.Array]) { return @($Response) }

            $data = Get-NxByPath -Object $Response -Path 'data'
            if ($data) {
                if ($data -is [System.Array]) { return @($data) }

                $entities = Get-NxByPath -Object $data -Path 'entities'
                if ($entities) { return @($entities) }

                $itemsNode = Get-NxByPath -Object $data -Path 'items'
                if ($itemsNode) { return @($itemsNode) }

                return @($data)
            }

            $entities2 = Get-NxByPath -Object $Response -Path 'entities'
            if ($entities2) { return @($entities2) }

            $items2 = Get-NxByPath -Object $Response -Path 'items'
            if ($items2) { return @($items2) }

            $propCount = @($Response.PSObject.Properties).Count
            if ($propCount -eq 0) { return @() }

            return @($Response)
        }

        function Get-NutanixEntityList {
            param([object[]]$Endpoints)

            $lastEmptyEndpoint = $null
            foreach ($epItem in @($Endpoints)) {
                if (-not $epItem) { continue }

                $ep = $null
                $method = 'GET'
                $body = $null
                if ($epItem -is [string]) {
                    $ep = $epItem
                }
                else {
                    $ep = $epItem.Endpoint
                    if ($epItem.Method) { $method = "$($epItem.Method)" }
                    if ($epItem.Body) { $body = "$($epItem.Body)" }
                }

                try {
                    $resp = Invoke-NutanixREST -Endpoint $ep -Method $method -Body $body
                    $list = @(Convert-NutanixResponseToList -Response $resp)
                    if ($list.Count -gt 0) {
                        return @{ List = $list; Endpoint = $ep }
                    }

                    $lastEmptyEndpoint = $ep
                    Write-Verbose "Nutanix endpoint returned no entities: $ep"
                }
                catch {
                    Write-Verbose "Nutanix endpoint failed: $ep : $($_.Exception.Message)"
                }
            }

            return @{ List = @(); Endpoint = $lastEmptyEndpoint }
        }

        function Get-NutanixMetricEndpoint {
            param(
                [string[]]$Urls,
                [string[]]$CpuPaths,
                [string[]]$MemPaths
            )

            foreach ($u in @($Urls)) {
                if (-not $u) { continue }
                try {
                    $resp = Invoke-NutanixREST -Endpoint $u -Method 'GET'

                    $cpuPath = ''
                    foreach ($p in @($CpuPaths)) {
                        $v = Get-NxByPath -Object $resp -Path $p
                        if ($null -ne $v -and "$v" -ne '') {
                            $cpuPath = $p
                            break
                        }
                    }

                    $memPath = ''
                    foreach ($p in @($MemPaths)) {
                        $v = Get-NxByPath -Object $resp -Path $p
                        if ($null -ne $v -and "$v" -ne '') {
                            $memPath = $p
                            break
                        }
                    }

                    if ($cpuPath -or $memPath) {
                        return @{ Url = $u; CpuPath = $cpuPath; MemPath = $memPath }
                    }

                    Write-Verbose "Nutanix metric endpoint returned no CPU/memory stats: $u"
                }
                catch {
                    Write-Verbose "Nutanix metric endpoint probe failed: $u : $($_.Exception.Message)"
                }
            }

            return @{ Url = ''; CpuPath = ''; MemPath = '' }
        }

        function Add-NxPopulationLog {
            param(
                [string]$EntityType,
                [string]$EntityName,
                [string]$MonitorName,
                [string]$MonitorKind,
                [string]$Endpoint,
                [string]$JsonPath,
                [string]$Value,
                [string]$Status,
                [string]$Reason
            )

            [void]$apiPopulationLog.Add([pscustomobject]@{
                Timestamp  = (Get-Date).ToString('s')
                EntityType = $EntityType
                EntityName = $EntityName
                Monitor    = $MonitorName
                Kind       = $MonitorKind
                Endpoint   = $Endpoint
                JsonPath   = $JsonPath
                Value      = $Value
                Status     = $Status
                Reason     = $Reason
            })
        }

        function Get-NxResponsePropertyNames {
            param([Parameter(Mandatory = $true)]$Response)

            $names = New-Object System.Collections.Generic.List[string]
            if ($null -eq $Response) { return @() }

            if ($Response -is [System.Array]) {
                $first = @($Response | Select-Object -First 1)
                if ($first.Count -gt 0 -and $null -ne $first[0]) {
                    foreach ($prop in @($first[0].PSObject.Properties)) {
                        if ($prop.Name -and -not $names.Contains($prop.Name)) { [void]$names.Add($prop.Name) }
                    }
                }
                return @($names)
            }

            foreach ($prop in @($Response.PSObject.Properties)) {
                if ($prop.Name -and -not $names.Contains($prop.Name)) { [void]$names.Add($prop.Name) }
            }

            return @($names)
        }

        function Test-NxNumericValue {
            param($Value)

            if ($null -eq $Value) { return $false }
            $parsed = 0.0
            return [double]::TryParse("$Value", [ref]$parsed)
        }

        function Get-NxDirectNumericSamplePaths {
            param([Parameter(Mandatory = $true)]$Response)

            $paths = New-Object System.Collections.Generic.List[string]
            $dataNode = $null

            if ($Response -is [System.Collections.IDictionary]) {
                if ($Response.Contains('data')) { $dataNode = $Response['data'] }
            }
            else {
                $dataProp = $Response.PSObject.Properties['data']
                if ($dataProp) { $dataNode = $dataProp.Value }
            }

            if ($null -eq $dataNode) { return @() }

            foreach ($prop in @($dataNode.PSObject.Properties)) {
                if (-not $prop.Name) { continue }

                $propValue = $prop.Value
                if ($null -eq $propValue) { continue }

                $valueProp = $propValue.PSObject.Properties['value']
                if ($valueProp) {
                    $samples = @($valueProp.Value)
                    if ($samples.Count -gt 0 -and (Test-NxNumericValue -Value $samples[0])) {
                        if ($prop.Name -match '[^A-Za-z0-9_]') {
                            [void]$paths.Add("$.data['$($prop.Name)'].value[0]")
                        }
                        else {
                            [void]$paths.Add("$.data.$($prop.Name).value[0]")
                        }
                    }
                    continue
                }

                if (Test-NxNumericValue -Value $propValue) {
                    if ($prop.Name -match '[^A-Za-z0-9_]') {
                        [void]$paths.Add("$.data['$($prop.Name)']")
                    }
                    else {
                        [void]$paths.Add("$.data.$($prop.Name)")
                    }
                }
            }

            return @($paths)
        }

        function Get-NxResponseSummary {
            param([Parameter(Mandatory = $true)]$Response)

            $list = @()
            try { $list = @(Convert-NutanixResponseToList -Response $Response) } catch { $list = @() }

            $topLevelKeys = @(Get-NxResponsePropertyNames -Response $Response)
            $numericSamplePaths = @(Get-NxDirectNumericSamplePaths -Response $Response)
            $hasStats = ($topLevelKeys -contains 'stats') -or ($topLevelKeys -contains 'usage_stats') -or ($topLevelKeys -contains 'state') -or ($topLevelKeys -contains 'power_state') -or ($topLevelKeys -contains 'operation_mode') -or ($topLevelKeys -contains 'disk_status') -or ($topLevelKeys -contains 'marked_for_removal')
            $hasAvailability = ($topLevelKeys -contains 'state') -or ($topLevelKeys -contains 'power_state') -or ($topLevelKeys -contains 'operation_mode') -or ($topLevelKeys -contains 'disk_status') -or ($topLevelKeys -contains 'marked_for_removal')
            $moreStatsPossible = $hasStats -or ($topLevelKeys -contains 'stats') -or ($topLevelKeys -contains 'usage_stats') -or ($topLevelKeys -contains 'entities') -or ($topLevelKeys -contains 'items') -or ($topLevelKeys -contains 'data')
            $requiresArithmetic = (($numericSamplePaths -contains '$.data.storageUsageBytes.value[0]' -and $numericSamplePaths -contains '$.data.storageCapacityBytes.value[0]') -or ($numericSamplePaths -contains '$.data.overallMemoryUsageBytes.value[0]' -and $numericSamplePaths -contains '$.data.memoryCapacityBytes.value[0]'))
            $wugPerfCompatible = $numericSamplePaths.Count -gt 0

            $notes = if ($null -eq $Response) {
                'No response body returned.'
            }
            elseif ($list.Count -gt 0) {
                'Entity list returned.'
            }
            elseif ($hasStats -or $hasAvailability) {
                'Response exposes stats or availability fields.'
            }
            else {
                'Response did not expose additional stats fields.'
            }

            $compatibilityNote = if ($wugPerfCompatible) {
                'Use an indexed JSONPath to a single numeric sample for WUG REST performance monitors.'
            }
            elseif ($requiresArithmetic) {
                'Derived percent/free-space metrics require arithmetic across multiple values; WUG REST performance monitors cannot compute that directly.'
            }
            else {
                'No direct numeric sample path was detected for WUG REST performance monitor use.'
            }

            [pscustomobject]@{
                ItemCount         = $list.Count
                TopLevelKeys      = [string[]]$topLevelKeys
                NumericSamplePaths = [string[]]$numericSamplePaths
                HasStats          = [bool]$hasStats
                HasAvailability   = [bool]$hasAvailability
                MoreStatsPossible = [bool]$moreStatsPossible
                WugPerfCompatible = [bool]$wugPerfCompatible
                RequiresArithmetic = [bool]$requiresArithmetic
                CompatibilityNote = $compatibilityNote
                Notes             = $notes
            }
        }

        function Add-NxApiPathLog {
            param(
                [string]$Endpoint,
                [string]$Method,
                [string]$Outcome,
                $Response,
                [string]$Reason,
                [string]$EntityType,
                [string]$EntityName,
                [string]$Purpose,
                [string]$ResolvedJsonPath,
                [string]$ResolvedValue,
                [string[]]$CandidateJsonPaths
            )

            $summary = $null
            if ($null -ne $Response) {
                $summary = Get-NxResponseSummary -Response $Response
            }

            [void]$apiPathLog.Add([pscustomobject]@{
                Timestamp         = (Get-Date).ToString('s')
                EntityType        = $EntityType
                EntityName        = $EntityName
                Purpose           = $Purpose
                Endpoint          = $Endpoint
                Method            = $Method
                Outcome           = $Outcome
                ItemCount         = if ($summary) { $summary.ItemCount } else { 0 }
                TopLevelKeys      = if ($summary) { [string[]]$summary.TopLevelKeys } else { @() }
                NumericSamplePaths = if ($summary) { [string[]]$summary.NumericSamplePaths } else { @() }
                CandidateJsonPaths = if ($CandidateJsonPaths) { [string[]]$CandidateJsonPaths } else { @() }
                ResolvedJsonPath  = $ResolvedJsonPath
                ResolvedValue     = $ResolvedValue
                HasStats          = if ($summary) { $summary.HasStats } else { $false }
                HasAvailability   = if ($summary) { $summary.HasAvailability } else { $false }
                MoreStatsPossible = if ($summary) { $summary.MoreStatsPossible } else { $false }
                WugPerfCompatible = if ($summary) { ($summary.WugPerfCompatible -or (Test-NxNumericValue -Value $ResolvedValue)) } else { (Test-NxNumericValue -Value $ResolvedValue) }
                RequiresArithmetic = if ($summary) { $summary.RequiresArithmetic } else { $false }
                Reason            = $Reason
                CompatibilityNote = if ($summary) { $summary.CompatibilityNote } else { '' }
                Notes             = if ($summary) { $summary.Notes } else { $Reason }
            })
        }

        function Get-NxBySegments {
            param(
                [Parameter(Mandatory = $true)]$Object,
                [Parameter(Mandatory = $true)][string[]]$Segments
            )

            $current = $Object
            foreach ($segment in $Segments) {
                if ($null -eq $current) { return $null }

                if ($current -is [System.Collections.IList] -and $segment -match '^\d+$') {
                    $idx = [int]$segment
                    if ($idx -lt $current.Count) { $current = $current[$idx] }
                    else { return $null }
                    continue
                }

                if ($current -is [System.Collections.IDictionary]) {
                    if ($current.Contains($segment)) { $current = $current[$segment] }
                    else { return $null }
                }
                else {
                    $prop = $current.PSObject.Properties[$segment]
                    if ($prop) { $current = $prop.Value }
                    else { return $null }
                }
            }

            return $current
        }

        function Resolve-NxMonitorValue {
            param(
                [string]$Endpoint,
                $Response,
                [object[]]$Candidates
            )

            function Get-NxAbsoluteEndpoint {
                param([string]$Value)

                if (-not $Value) { return $Value }
                if ($Value -match '^https?://') { return $Value }
                return "${baseUri}${Value}"
            }

            $responseCache = @{}
            $candidateJsonPaths = @($Candidates | ForEach-Object { $_.JsonPath })
            $lastReason = 'No non-empty value found for expected path(s).'
            $normalizedEndpoint = Get-NxAbsoluteEndpoint -Value $Endpoint

            if ($Endpoint -and $Response) {
                $responseCache[$normalizedEndpoint] = $Response
            }

            if ($Endpoint -and -not $responseCache.ContainsKey($normalizedEndpoint)) {
                try {
                    $responseCache[$normalizedEndpoint] = Invoke-NutanixREST -Endpoint $Endpoint -Method 'GET'
                }
                catch {
                    $lastReason = $_.Exception.Message
                    $responseCache[$normalizedEndpoint] = $null
                }
            }

            if ($Candidates.Count -eq 0 -and $Endpoint) {
                $resp = $responseCache[$normalizedEndpoint]
                if ($resp) {
                    Add-NxApiPathLog -Endpoint $normalizedEndpoint -Method 'GET' -Outcome 'Unresolved' -Response $resp -Reason $lastReason -Purpose 'MonitorValue' -ResolvedJsonPath '' -ResolvedValue '' -CandidateJsonPaths $candidateJsonPaths
                }
                return @{ Valid = $false; Endpoint = $normalizedEndpoint; JsonPath = ''; Value = ''; Reason = $lastReason; Response = $resp }
            }

            foreach ($candidate in @($Candidates)) {
                if (-not $candidate) { continue }
                $segments = @($candidate.Segments)
                if ($segments.Count -eq 0) { continue }

                $candidateEndpoint = $Endpoint
                if ($candidate.Endpoint) { $candidateEndpoint = "$($candidate.Endpoint)" }
                if (-not $candidateEndpoint) { continue }
                $absoluteCandidateEndpoint = Get-NxAbsoluteEndpoint -Value $candidateEndpoint

                if (-not $responseCache.ContainsKey($absoluteCandidateEndpoint)) {
                    try {
                        $responseCache[$absoluteCandidateEndpoint] = Invoke-NutanixREST -Endpoint $candidateEndpoint -Method 'GET'
                    }
                    catch {
                        $lastReason = $_.Exception.Message
                        $responseCache[$absoluteCandidateEndpoint] = $null
                        continue
                    }
                }

                $resp = $responseCache[$absoluteCandidateEndpoint]
                if (-not $resp) { continue }

                $v = Get-NxBySegments -Object $resp -Segments $segments
                if ($v -is [System.Array]) {
                    $v = @($v | Where-Object { $null -ne $_ -and "$_" -ne '' } | Select-Object -First 1)
                    if ($v.Count -gt 0) { $v = $v[0] } else { $v = $null }
                }

                if ($null -ne $v -and "${v}" -ne '') {
                    Add-NxApiPathLog -Endpoint $absoluteCandidateEndpoint -Method 'GET' -Outcome 'Resolved' -Response $resp -Reason '' -Purpose 'MonitorValue' -ResolvedJsonPath "$($candidate.JsonPath)" -ResolvedValue "${v}" -CandidateJsonPaths $candidateJsonPaths
                    return @{ Valid = $true; Endpoint = $absoluteCandidateEndpoint; JsonPath = "$($candidate.JsonPath)"; Value = "${v}"; Reason = ''; Response = $resp }
                }
            }

            $lastEndpoint = $Endpoint
            if ($Candidates.Count -gt 0 -and $Candidates[-1] -and $Candidates[-1].Endpoint) {
                $lastEndpoint = "$($Candidates[-1].Endpoint)"
            }
            $absoluteLastEndpoint = Get-NxAbsoluteEndpoint -Value $lastEndpoint
            $lastResponse = $null
            if ($absoluteLastEndpoint -and $responseCache.ContainsKey($absoluteLastEndpoint)) {
                $lastResponse = $responseCache[$absoluteLastEndpoint]
            }

            Add-NxApiPathLog -Endpoint $absoluteLastEndpoint -Method 'GET' -Outcome 'Unresolved' -Response $lastResponse -Reason $lastReason -Purpose 'MonitorValue' -ResolvedJsonPath '' -ResolvedValue '' -CandidateJsonPaths $candidateJsonPaths
            return @{ Valid = $false; Endpoint = $absoluteLastEndpoint; JsonPath = ''; Value = ''; Reason = $lastReason; Response = $lastResponse }
        }

        function New-NxStringDoesNotContainComparison {
            param(
                [Parameter(Mandatory = $true)][string]$JsonPathQuery,
                [Parameter(Mandatory = $true)][string]$ExpectedValue
            )

            "[{`"JsonPathQuery`":`"$JsonPathQuery`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"$ExpectedValue`"}]"
        }

        function New-NxStatsQueryEndpoint {
            param(
                [Parameter(Mandatory = $true)][string]$BaseEndpoint,
                [Parameter(Mandatory = $true)][string]$Select,
                [string]$StatType = 'LAST',
                [int]$SamplingInterval = 30,
                [int]$LookbackMinutes = 5
            )

            $utcNow = (Get-Date).ToUniversalTime()
            $startUtc = $utcNow.AddMinutes(-1 * [Math]::Abs($LookbackMinutes)).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $endUtc = $utcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

            "{0}?`$startTime={1}&`$endTime={2}&`$samplingInterval={3}&`$statType={4}&`$select={5}" -f $BaseEndpoint, $startUtc, $endUtc, $SamplingInterval, $StatType, $Select
        }

        Write-Host "  Querying Nutanix v4.1 APIs at $hostTarget..." -ForegroundColor DarkGray

        # --- Clusters (required endpoints) ---
        $clusterResult = Get-NutanixEntityList -Endpoints @(
            '/api/clustermgmt/v4.1/config/clusters',
            '/api/nutanix/v2.0/cluster',
            @{ Endpoint = '/api/nutanix/v3/clusters/list'; Method = 'POST'; Body = '{"kind":"cluster","length":200,"offset":0}' }
        )
        $clusters = @($clusterResult.List)
        $clusterEndpointUsed = $clusterResult.Endpoint
        if ($clusters.Count -eq 0) {
            Write-Warning "Nutanix: Could not query clusters at $hostTarget using known v4.1/v2 endpoints."
            return $items
        }

        Write-Host "  Found $($clusters.Count) cluster object(s)" -ForegroundColor DarkGray

        foreach ($cluster in $clusters) {
            $clusterExtId = Get-NxFirst -Object $cluster -Paths @('extId', 'uuid', 'cluster_uuid', 'metadata.uuid') -Default $hostTarget
            $clusterIdRaw = Get-NxFirst -Object $cluster -Paths @('id') -Default ''
            if ($clusterExtId) { $clusterUuidCandidates[$clusterExtId] = $true }
            if ($clusterIdRaw) {
                $clusterUuidCandidates[$clusterIdRaw] = $true
                if ($clusterIdRaw -like '*::*') {
                    $clusterUuidCandidates[($clusterIdRaw -split '::')[0]] = $true
                }
            }
            $clusterName = Get-NxFirst -Object $cluster -Paths @('name', 'cluster_name', 'status.name', 'spec.name', 'status.name') -Default $hostTarget
            $clusterIp = Get-NxFirst -Object $cluster -Paths @(
                'cluster_external_ipaddress',
                'clusterExternalIPAddress',
                'network.externalAddress.ipv4.value',
                'status.resources.network.externalAddress.ipv4.value'
            ) -Default $hostTarget

            $clusterUsesV4 = $clusterEndpointUsed -and ($clusterEndpointUsed -like '/api/clustermgmt/*')
            $clusterUsesV3 = $clusterEndpointUsed -and ($clusterEndpointUsed -like '/api/nutanix/v3/*')
            if ($clusterUsesV4) {
                $clusterConfigUrl = "${baseUri}/api/clustermgmt/v4.1/config/clusters/${clusterExtId}"
                $clusterStatsUrl  = "${baseUri}/api/clustermgmt/v4.1/stats/clusters/${clusterExtId}"
            }
            elseif ($clusterUsesV3) {
                $clusterConfigUrl = "${baseUri}/api/nutanix/v3/clusters/list"
                $clusterStatsUrl  = "${baseUri}/api/nutanix/v3/clusters/list"
            }
            else {
                $clusterConfigUrl = "${baseUri}/api/nutanix/v2.0/cluster"
                $clusterStatsUrl  = "${baseUri}/api/nutanix/v2.0/cluster/stats/"
            }

            $clusterAttrs = @{
                'DiscoveryHelper.Nutanix' = 'true'
                'Nutanix.DeviceType'      = 'Cluster'
                'Nutanix.ClusterName'     = $clusterName
                'Nutanix.ClusterUuid'     = $clusterExtId
                'Nutanix.ClusterExtId'    = $clusterExtId
                'Nutanix.ClusterIP'       = $clusterIp
                'Nutanix.IPAddress'       = $clusterIp
                'Nutanix.ApiFamily'       = if ($clusterUsesV4) { 'v4' } elseif ($clusterUsesV3) { 'v3' } else { 'v2' }
                'Vendor'                  = 'Nutanix'
            }

            $clusterOpMode = Get-NxFirst -Object $cluster -Paths @('operation_mode', 'operationMode', 'status.operation_mode') -Default ''
            Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName 'EntityPopulate' -MonitorKind 'Info' -Endpoint $clusterConfigUrl -JsonPath "['operation_mode']" -Value $clusterOpMode -Status 'Captured' -Reason ''

            if ($clusterOpMode) {
                $clusterCompare = New-NxStringDoesNotContainComparison -JsonPathQuery "['operation_mode']" -ExpectedValue 'NORMAL'
                $items += New-DiscoveredItem `
                    -Name "Nutanix Cluster Health - $clusterName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                    = $clusterConfigUrl
                        RestApiMethod                 = 'GET'
                        RestApiTimeoutMs              = 15000
                        RestApiUseAnonymous           = '0'
                        RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                        RestApiComparisonList         = $clusterCompare
                    } `
                    -UniqueKey "Nutanix:${clusterExtId}:active:cluster" `
                    -Attributes $clusterAttrs `
                    -Tags @('nutanix', 'cluster', $clusterName)
                Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName "Nutanix Cluster Health - $clusterName" -MonitorKind 'Active' -Endpoint $clusterConfigUrl -JsonPath "['operation_mode']" -Value $clusterOpMode -Status 'Created' -Reason ''
            }
            else {
                Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName "Nutanix Cluster Health - $clusterName" -MonitorKind 'Active' -Endpoint $clusterConfigUrl -JsonPath "['operation_mode']" -Value '' -Status 'Skipped' -Reason 'operation_mode not present.'
                Write-Verbose "Skipping cluster health monitor '$clusterName' because operation_mode was not present."
            }

            $clusterV4StatsEndpoint = "/api/clustermgmt/v4.1/stats/clusters/${clusterExtId}"
            $clusterCpuProbe = Resolve-NxMonitorValue -Endpoint $clusterV4StatsEndpoint -Candidates @(
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $clusterV4StatsEndpoint -Select 'hypervisorCpuUsagePpm,hypervisor_cpu_usage_ppm,stats' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.hypervisorCpuUsagePpm.value[0]'; Segments = @('data', 'hypervisorCpuUsagePpm', 'value', '0') },
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $clusterV4StatsEndpoint -Select 'hypervisorCpuUsagePpm,hypervisor_cpu_usage_ppm,stats' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.hypervisor_cpu_usage_ppm.value[0]'; Segments = @('data', 'hypervisor_cpu_usage_ppm', 'value', '0') },
                @{ Endpoint = '/api/nutanix/v2.0/cluster/stats/?metrics=hypervisor_cpu_usage_ppm'; JsonPath = '$.stats_specific_responses[0].values[0]'; Segments = @('stats_specific_responses', '0', 'values', '0') },
                @{ Endpoint = '/api/nutanix/v2.0/cluster/stats/?metrics=hypervisor_cpu_usage_ppm'; JsonPath = '$.hypervisor_cpu_usage_ppm'; Segments = @('hypervisor_cpu_usage_ppm') }
            )
            if ($clusterCpuProbe.Valid) {
                $items += New-DiscoveredItem `
                    -Name "Cluster CPU ppm - $clusterName (nutanix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $clusterCpuProbe.Endpoint
                        RestApiJsonPath           = $clusterCpuProbe.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        _MetricName               = 'cluster_cpu_usage_ppm'
                        _MetricDisplayName        = 'Cluster CPU Usage (ppm)'
                    } `
                    -UniqueKey "Nutanix:${clusterExtId}:perf:cluster:cpu" `
                    -Attributes $clusterAttrs `
                    -Tags @('nutanix', 'cluster', $clusterName, 'cpu')
                Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName "Cluster CPU ppm - $clusterName (nutanix)" -MonitorKind 'Performance' -Endpoint $clusterCpuProbe.Endpoint -JsonPath $clusterCpuProbe.JsonPath -Value $clusterCpuProbe.Value -Status 'Created' -Reason ''
            }
            else {
                Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName "Cluster CPU ppm - $clusterName (nutanix)" -MonitorKind 'Performance' -Endpoint $clusterV4StatsEndpoint -JsonPath '' -Value '' -Status 'Skipped' -Reason $clusterCpuProbe.Reason
            }

            $clusterMemProbe = Resolve-NxMonitorValue -Endpoint $clusterV4StatsEndpoint -Candidates @(
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $clusterV4StatsEndpoint -Select 'hypervisorMemoryUsagePpm,hypervisor_memory_usage_ppm,stats' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.hypervisorMemoryUsagePpm.value[0]'; Segments = @('data', 'hypervisorMemoryUsagePpm', 'value', '0') },
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $clusterV4StatsEndpoint -Select 'hypervisorMemoryUsagePpm,hypervisor_memory_usage_ppm,stats' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.hypervisor_memory_usage_ppm.value[0]'; Segments = @('data', 'hypervisor_memory_usage_ppm', 'value', '0') },
                @{ Endpoint = '/api/nutanix/v2.0/cluster/stats/?metrics=hypervisor_memory_usage_ppm'; JsonPath = '$.stats_specific_responses[0].values[0]'; Segments = @('stats_specific_responses', '0', 'values', '0') },
                @{ Endpoint = '/api/nutanix/v2.0/cluster/stats/?metrics=hypervisor_memory_usage_ppm'; JsonPath = '$.hypervisor_memory_usage_ppm'; Segments = @('hypervisor_memory_usage_ppm') }
            )
            if ($clusterMemProbe.Valid) {
                $items += New-DiscoveredItem `
                    -Name "Cluster Memory ppm - $clusterName (nutanix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $clusterMemProbe.Endpoint
                        RestApiJsonPath           = $clusterMemProbe.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        _MetricName               = 'cluster_memory_usage_ppm'
                        _MetricDisplayName        = 'Cluster Memory Usage (ppm)'
                    } `
                    -UniqueKey "Nutanix:${clusterExtId}:perf:cluster:memory" `
                    -Attributes $clusterAttrs `
                    -Tags @('nutanix', 'cluster', $clusterName, 'memory')
                Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName "Cluster Memory ppm - $clusterName (nutanix)" -MonitorKind 'Performance' -Endpoint $clusterMemProbe.Endpoint -JsonPath $clusterMemProbe.JsonPath -Value $clusterMemProbe.Value -Status 'Created' -Reason ''
            }
            else {
                Add-NxPopulationLog -EntityType 'Cluster' -EntityName $clusterName -MonitorName "Cluster Memory ppm - $clusterName (nutanix)" -MonitorKind 'Performance' -Endpoint $clusterV4StatsEndpoint -JsonPath '' -Value '' -Status 'Skipped' -Reason $clusterMemProbe.Reason
            }

            $hostResult = Get-NutanixEntityList -Endpoints @(
                "/api/clustermgmt/v4.1/config/clusters/${clusterExtId}/hosts",
                '/api/nutanix/v2.0/hosts',
                '/api/nutanix/v2.0/hosts/',
                @{ Endpoint = '/api/nutanix/v3/hosts/list'; Method = 'POST'; Body = '{"kind":"host","length":500,"offset":0}' }
            )
            $hosts = @($hostResult.List)
            $hostEndpointUsed = $hostResult.Endpoint

            Write-Host "  Cluster '$clusterName': found $($hosts.Count) host object(s)" -ForegroundColor DarkGray

            foreach ($h in $hosts) {
                $hExtId = Get-NxFirst -Object $h -Paths @('extId', 'uuid', 'metadata.uuid') -Default ''
                if (-not $hExtId) { continue }

                $hostClusterUuid = Get-NxFirst -Object $h -Paths @('cluster_uuid', 'clusterUuid', 'cluster.extId') -Default ''
                if ($hostClusterUuid) { $clusterUuidCandidates[$hostClusterUuid] = $true }

                $hName = Get-NxFirst -Object $h -Paths @('name', 'hostName', 'hypervisor_hostname', 'status.name', 'spec.name') -Default "Host-$hExtId"
                $hIp = Get-NxFirst -Object $h -Paths @(
                    'hypervisor_address',
                    'service_vmexternal_ip',
                    'status.resources.network.ipv4.value',
                    'ipAddress'
                ) -Default ''
                if (-not $hIp) { $hIp = $hostTarget }

                $hostUsesV4 = $hostEndpointUsed -and ($hostEndpointUsed -like '/api/clustermgmt/*')
                $hostUsesV3 = $hostEndpointUsed -and ($hostEndpointUsed -like '/api/nutanix/v3/*')
                $hostHealthUrl = ''
                if ($hostUsesV4) {
                    $hostHealthUrl = "${baseUri}/api/clustermgmt/v4.1/config/hosts/${hExtId}"
                }
                elseif ($hostUsesV3) {
                    $hostHealthUrl = "${baseUri}/api/nutanix/v3/hosts/list"
                }
                else {
                    $hostHealthUrl = "${baseUri}/api/nutanix/v2.0/hosts/${hExtId}"
                }

                $hostDetail = $null
                if ($hostHealthUrl -like "${baseUri}/api/nutanix/v2.0/*") {
                    try { $hostDetail = Invoke-NutanixREST -Endpoint $hostHealthUrl -Method 'GET' } catch { }
                }

                $hostCvmIp = Get-NxFirst -Object $h -Paths @('service_vmexternal_ip', 'controllerVmIp', 'controllerVmExternalIp') -Default ''
                $hostMemCapacityBytes = Get-NxFirst -Object $h -Paths @('memory_capacity_in_bytes', 'memoryCapacityBytes', 'resources.memoryCapacityBytes') -Default ''

                $hostAttrs = @{
                    'DiscoveryHelper.Nutanix' = 'true'
                    'Nutanix.DeviceType'      = 'Host'
                    'Nutanix.ClusterName'     = $clusterName
                    'Nutanix.ClusterExtId'    = $clusterExtId
                    'Nutanix.HostName'        = $hName
                    'Nutanix.HostUuid'        = $hExtId
                    'Nutanix.HostExtId'       = $hExtId
                    'Nutanix.HostIP'          = $hIp
                    'Nutanix.HostCvmIP'       = $hostCvmIp
                    'Nutanix.HostMemoryCapacityBytes' = $hostMemCapacityBytes
                    'Nutanix.IPAddress'       = $hIp
                    'Nutanix.ApiFamily'       = if ($hostUsesV4) { 'v4' } elseif ($hostUsesV3) { 'v3' } else { 'v2' }
                    'Vendor'                  = 'Nutanix'
                }

                $hostStateProbe = Resolve-NxMonitorValue -Endpoint $hostHealthUrl -Response $hostDetail -Candidates @(
                    @{ JsonPath = "['state']"; Segments = @('state') }
                )
                Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName 'EntityPopulate' -MonitorKind 'Info' -Endpoint $hostHealthUrl -JsonPath "['state']" -Value $hostStateProbe.Value -Status 'Captured' -Reason ''
                if ($hostStateProbe.Valid) {
                    $hostCompare = New-NxStringDoesNotContainComparison -JsonPathQuery "['state']" -ExpectedValue 'NORMAL'
                    $items += New-DiscoveredItem `
                        -Name "Nutanix Host Health - $hName" `
                        -ItemType 'ActiveMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                    = $hostHealthUrl
                            RestApiMethod                 = 'GET'
                            RestApiTimeoutMs              = 15000
                            RestApiUseAnonymous           = '0'
                            RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                            RestApiComparisonList         = $hostCompare
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:host:${hExtId}:active:health" `
                        -Attributes $hostAttrs `
                        -Tags @('nutanix', 'host', $hName)
                    Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName "Nutanix Host Health - $hName" -MonitorKind 'Active' -Endpoint $hostHealthUrl -JsonPath "['state']" -Value $hostStateProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName "Nutanix Host Health - $hName" -MonitorKind 'Active' -Endpoint $hostHealthUrl -JsonPath "['state']" -Value '' -Status 'Skipped' -Reason $hostStateProbe.Reason
                }

                $hostV4StatsEndpoint = "/api/clustermgmt/v4.1/stats/clusters/${clusterExtId}/hosts/${hExtId}"
                $hostCpuProbe = Resolve-NxMonitorValue -Endpoint $hostV4StatsEndpoint -Candidates @(
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $hostV4StatsEndpoint -Select 'hypervisorCpuUsagePpm,hypervisor_cpu_usage_ppm,cpuUsagePpm,stats' -StatType 'AVG' -SamplingInterval 30); JsonPath = '$.data.hypervisorCpuUsagePpm.value[0]'; Segments = @('data', 'hypervisorCpuUsagePpm', 'value', '0') },
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $hostV4StatsEndpoint -Select 'hypervisorCpuUsagePpm,hypervisor_cpu_usage_ppm,cpuUsagePpm,stats' -StatType 'AVG' -SamplingInterval 30); JsonPath = '$.data.hypervisor_cpu_usage_ppm.value[0]'; Segments = @('data', 'hypervisor_cpu_usage_ppm', 'value', '0') },
                    @{ Endpoint = $hostHealthUrl; JsonPath = '$.stats.hypervisor_cpu_usage_ppm'; Segments = @('stats', 'hypervisor_cpu_usage_ppm') },
                    @{ Endpoint = $hostHealthUrl; JsonPath = '$.hypervisor_cpu_usage_ppm'; Segments = @('hypervisor_cpu_usage_ppm') }
                )
                if ($hostCpuProbe.Valid) {
                    $items += New-DiscoveredItem `
                        -Name "CPU Usage % - $hName (nutanix)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $hostCpuProbe.Endpoint
                            RestApiJsonPath           = $hostCpuProbe.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'cpu_usage_ppm'
                            _MetricDisplayName        = 'CPU Usage (ppm)'
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:host:${hExtId}:perf:cpu" `
                        -Attributes $hostAttrs `
                        -Tags @('nutanix', 'host', $hName, 'cpu')
                    Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName "CPU Usage % - $hName (nutanix)" -MonitorKind 'Performance' -Endpoint $hostCpuProbe.Endpoint -JsonPath $hostCpuProbe.JsonPath -Value $hostCpuProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName "CPU Usage % - $hName (nutanix)" -MonitorKind 'Performance' -Endpoint $hostV4StatsEndpoint -JsonPath '' -Value '' -Status 'Skipped' -Reason $hostCpuProbe.Reason
                }

                $hostMemProbe = Resolve-NxMonitorValue -Endpoint $hostV4StatsEndpoint -Candidates @(
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $hostV4StatsEndpoint -Select 'hypervisorMemoryUsagePpm,hypervisor_memory_usage_ppm,memoryUsagePpm,stats' -StatType 'AVG' -SamplingInterval 30); JsonPath = '$.data.hypervisorMemoryUsagePpm.value[0]'; Segments = @('data', 'hypervisorMemoryUsagePpm', 'value', '0') },
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $hostV4StatsEndpoint -Select 'hypervisorMemoryUsagePpm,hypervisor_memory_usage_ppm,memoryUsagePpm,stats' -StatType 'AVG' -SamplingInterval 30); JsonPath = '$.data.hypervisor_memory_usage_ppm.value[0]'; Segments = @('data', 'hypervisor_memory_usage_ppm', 'value', '0') },
                    @{ Endpoint = $hostHealthUrl; JsonPath = '$.stats.hypervisor_memory_usage_ppm'; Segments = @('stats', 'hypervisor_memory_usage_ppm') },
                    @{ Endpoint = $hostHealthUrl; JsonPath = '$.hypervisor_memory_usage_ppm'; Segments = @('hypervisor_memory_usage_ppm') }
                )
                if ($hostMemProbe.Valid) {
                    $items += New-DiscoveredItem `
                        -Name "Memory Usage % - $hName (nutanix)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $hostMemProbe.Endpoint
                            RestApiJsonPath           = $hostMemProbe.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'memory_usage_ppm'
                            _MetricDisplayName        = 'Memory Usage (ppm)'
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:host:${hExtId}:perf:memory" `
                        -Attributes $hostAttrs `
                        -Tags @('nutanix', 'host', $hName, 'memory')
                    Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName "Memory Usage % - $hName (nutanix)" -MonitorKind 'Performance' -Endpoint $hostMemProbe.Endpoint -JsonPath $hostMemProbe.JsonPath -Value $hostMemProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'Host' -EntityName $hName -MonitorName "Memory Usage % - $hName (nutanix)" -MonitorKind 'Performance' -Endpoint $hostV4StatsEndpoint -JsonPath '' -Value '' -Status 'Skipped' -Reason $hostMemProbe.Reason
                }
            }

            $diskResult = Get-NutanixEntityList -Endpoints @(
                '/api/clustermgmt/v4.1/config/disks',
                '/api/nutanix/v2.0/disks',
                '/api/nutanix/v2.0/disks/',
                @{ Endpoint = '/api/nutanix/v3/disks/list'; Method = 'POST'; Body = '{"kind":"disk","length":500,"offset":0}' }
            )
            $disks = @($diskResult.List)
            $diskEndpointUsed = $diskResult.Endpoint
            foreach ($disk in $disks) {
                $diskExtId = Get-NxFirst -Object $disk -Paths @('extId', 'disk_uuid', 'uuid', 'metadata.uuid') -Default ''
                if (-not $diskExtId) { continue }

                $diskName = Get-NxFirst -Object $disk -Paths @('name', 'serialNumber', 'status.name') -Default "Disk-$diskExtId"
                $diskUsesV4 = $diskEndpointUsed -and ($diskEndpointUsed -like '/api/clustermgmt/*')
                $diskUsesV3 = $diskEndpointUsed -and ($diskEndpointUsed -like '/api/nutanix/v3/*')
                if ($diskUsesV4) {
                    $diskStatsUrl = "${baseUri}/api/clustermgmt/v4.1/stats/disks/${diskExtId}"
                }
                elseif ($diskUsesV3) {
                    $diskStatsUrl = "${baseUri}/api/nutanix/v3/disks/list"
                }
                else {
                    $diskStatsUrl = "${baseUri}/api/nutanix/v2.0/disks/${diskExtId}"
                }

                $diskHostName = Get-NxFirst -Object $disk -Paths @('hostName', 'nodeUuid', 'status.resources.hostReference.name') -Default ''
                $diskHostExtId = Get-NxFirst -Object $disk -Paths @('hostExtId', 'nodeUuid', 'status.resources.hostReference.extId') -Default ''
                $diskState = Get-NxFirst -Object $disk -Paths @('state', 'status.state') -Default ''

                $diskAttrs = @{
                    'DiscoveryHelper.Nutanix' = 'true'
                    'Nutanix.DeviceType'      = 'Disk'
                    'Nutanix.ClusterName'     = $clusterName
                    'Nutanix.ClusterExtId'    = $clusterExtId
                    'Nutanix.DiskName'        = $diskName
                    'Nutanix.DiskExtId'       = $diskExtId
                    'Nutanix.DiskState'       = $diskState
                    'Nutanix.DiskHostName'    = $diskHostName
                    'Nutanix.DiskHostExtId'   = $diskHostExtId
                    'Nutanix.IPAddress'       = '0.0.0.0'
                    'Nutanix.ApiFamily'       = if ($diskUsesV4) { 'v4' } elseif ($diskUsesV3) { 'v3' } else { 'v2' }
                    'Vendor'                  = 'Nutanix'
                }

                $diskStateProbe = Resolve-NxMonitorValue -Endpoint $diskStatsUrl -Response $disk -Candidates @(
                    @{ JsonPath = "['disk_status']"; Segments = @('disk_status') },
                    @{ JsonPath = "['state']"; Segments = @('state') }
                )
                Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName 'EntityPopulate' -MonitorKind 'Info' -Endpoint $diskStatsUrl -JsonPath "['disk_status']" -Value $diskStateProbe.Value -Status 'Captured' -Reason ''
                if ($diskStateProbe.Valid) {
                    $diskCompare = New-NxStringDoesNotContainComparison -JsonPathQuery "['disk_status']" -ExpectedValue 'NORMAL'
                    $items += New-DiscoveredItem `
                        -Name "Nutanix Disk Health - $diskName" `
                        -ItemType 'ActiveMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                    = $diskStatsUrl
                            RestApiMethod                 = 'GET'
                            RestApiTimeoutMs              = 15000
                            RestApiUseAnonymous           = '0'
                            RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                            RestApiComparisonList         = $diskCompare
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:disk:${diskExtId}:active:health" `
                        -Attributes $diskAttrs `
                        -Tags @('nutanix', 'disk', $diskName)
                    Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName "Nutanix Disk Health - $diskName" -MonitorKind 'Active' -Endpoint $diskStatsUrl -JsonPath "['disk_status']" -Value $diskStateProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName "Nutanix Disk Health - $diskName" -MonitorKind 'Active' -Endpoint $diskStatsUrl -JsonPath "['disk_status']" -Value '' -Status 'Skipped' -Reason $diskStateProbe.Reason
                }

                $diskV4StatsEndpoint = "/api/clustermgmt/v4.1/stats/disks/${diskExtId}"
                $diskV2Endpoint = "/api/nutanix/v2.0/disks/${diskExtId}"
                $diskUsageProbe = Resolve-NxMonitorValue -Endpoint $diskV4StatsEndpoint -Candidates @(
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $diskV4StatsEndpoint -Select 'diskUsageBytes,storageUsageBytes,usageBytes' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.diskUsageBytes.value[0]'; Segments = @('data', 'diskUsageBytes', 'value', '0') },
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $diskV4StatsEndpoint -Select 'diskUsageBytes,storageUsageBytes,usageBytes' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.storageUsageBytes.value[0]'; Segments = @('data', 'storageUsageBytes', 'value', '0') },
                    @{ Endpoint = $diskV2Endpoint; JsonPath = "$.usage_stats['storage.usage_bytes']"; Segments = @('usage_stats', 'storage.usage_bytes') }
                )
                if ($diskUsageProbe.Valid) {
                    $items += New-DiscoveredItem `
                        -Name "Disk Usage bytes - $diskName (nutanix)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $diskUsageProbe.Endpoint
                            RestApiJsonPath           = $diskUsageProbe.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'disk_usage_bytes'
                            _MetricDisplayName        = 'Disk Usage (bytes)'
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:disk:${diskExtId}:perf:usagebytes" `
                        -Attributes $diskAttrs `
                        -Tags @('nutanix', 'disk', $diskName, 'usage')
                    Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName "Disk Usage bytes - $diskName (nutanix)" -MonitorKind 'Performance' -Endpoint $diskUsageProbe.Endpoint -JsonPath $diskUsageProbe.JsonPath -Value $diskUsageProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName "Disk Usage bytes - $diskName (nutanix)" -MonitorKind 'Performance' -Endpoint $diskV4StatsEndpoint -JsonPath "$.usage_stats['storage.usage_bytes']" -Value '' -Status 'Skipped' -Reason $diskUsageProbe.Reason
                }

                $diskFreeProbe = Resolve-NxMonitorValue -Endpoint $diskV4StatsEndpoint -Candidates @(
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $diskV4StatsEndpoint -Select 'diskFreeBytes,storageFreeBytes,freeBytes' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.diskFreeBytes.value[0]'; Segments = @('data', 'diskFreeBytes', 'value', '0') },
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $diskV4StatsEndpoint -Select 'diskFreeBytes,storageFreeBytes,freeBytes' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.storageFreeBytes.value[0]'; Segments = @('data', 'storageFreeBytes', 'value', '0') },
                    @{ Endpoint = $diskV2Endpoint; JsonPath = "$.usage_stats['storage.free_bytes']"; Segments = @('usage_stats', 'storage.free_bytes') }
                )
                if ($diskFreeProbe.Valid) {
                    $items += New-DiscoveredItem `
                        -Name "Disk Free bytes - $diskName (nutanix)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $diskFreeProbe.Endpoint
                            RestApiJsonPath           = $diskFreeProbe.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'disk_free_bytes'
                            _MetricDisplayName        = 'Disk Free (bytes)'
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:disk:${diskExtId}:perf:freebytes" `
                        -Attributes $diskAttrs `
                        -Tags @('nutanix', 'disk', $diskName, 'free')
                    Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName "Disk Free bytes - $diskName (nutanix)" -MonitorKind 'Performance' -Endpoint $diskFreeProbe.Endpoint -JsonPath $diskFreeProbe.JsonPath -Value $diskFreeProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'Disk' -EntityName $diskName -MonitorName "Disk Free bytes - $diskName (nutanix)" -MonitorKind 'Performance' -Endpoint $diskV4StatsEndpoint -JsonPath "$.usage_stats['storage.free_bytes']" -Value '' -Status 'Skipped' -Reason $diskFreeProbe.Reason
                }
            }

            $containerResult = Get-NutanixEntityList -Endpoints @(
                '/api/clustermgmt/v4.1/config/storage-containers',
                '/api/nutanix/v2.0/storage_containers',
                '/api/nutanix/v2.0/storage_containers/',
                @{ Endpoint = '/api/nutanix/v3/storage_containers/list'; Method = 'POST'; Body = '{"kind":"storage_container","length":500,"offset":0}' }
            )
            $containers = @($containerResult.List)
            $containerEndpointUsed = $containerResult.Endpoint
            foreach ($container in $containers) {
                $containerExtId = Get-NxFirst -Object $container -Paths @('extId', 'storage_container_uuid', 'uuid', 'metadata.uuid') -Default ''
                if (-not $containerExtId) { continue }

                $containerName = Get-NxFirst -Object $container -Paths @('name', 'status.name') -Default "StorageContainer-$containerExtId"
                $containerUsesV4 = $containerEndpointUsed -and ($containerEndpointUsed -like '/api/clustermgmt/*')
                $containerUsesV3 = $containerEndpointUsed -and ($containerEndpointUsed -like '/api/nutanix/v3/*')
                if ($containerUsesV4) {
                    $containerStatsUrl = "${baseUri}/api/clustermgmt/v4.1/stats/storage-containers/${containerExtId}"
                }
                elseif ($containerUsesV3) {
                    $containerStatsUrl = "${baseUri}/api/nutanix/v3/storage_containers/list"
                }
                else {
                    $containerStatsUrl = "${baseUri}/api/nutanix/v2.0/storage_containers/${containerExtId}"
                }

                $containerAttrs = @{
                    'DiscoveryHelper.Nutanix'     = 'true'
                    'Nutanix.DeviceType'          = 'StorageContainer'
                    'Nutanix.ClusterName'         = $clusterName
                    'Nutanix.ClusterExtId'        = $clusterExtId
                    'Nutanix.StorageContainerName' = $containerName
                    'Nutanix.StorageContainerExtId' = $containerExtId
                    'Nutanix.IPAddress'           = '0.0.0.0'
                    'Nutanix.ApiFamily'           = if ($containerUsesV4) { 'v4' } elseif ($containerUsesV3) { 'v3' } else { 'v2' }
                    'Vendor'                      = 'Nutanix'
                }

                $containerHealthProbe = Resolve-NxMonitorValue -Endpoint $containerStatsUrl -Response $container -Candidates @(
                    @{ JsonPath = "['marked_for_removal']"; Segments = @('marked_for_removal') }
                )
                Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName 'EntityPopulate' -MonitorKind 'Info' -Endpoint $containerStatsUrl -JsonPath "['marked_for_removal']" -Value $containerHealthProbe.Value -Status 'Captured' -Reason ''
                if ($containerHealthProbe.Valid) {
                    $containerCompare = New-NxStringDoesNotContainComparison -JsonPathQuery "['marked_for_removal']" -ExpectedValue 'False'
                    $items += New-DiscoveredItem `
                        -Name "Nutanix Storage Container Health - $containerName" `
                        -ItemType 'ActiveMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                    = $containerStatsUrl
                            RestApiMethod                 = 'GET'
                            RestApiTimeoutMs              = 15000
                            RestApiUseAnonymous           = '0'
                            RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                            RestApiComparisonList         = $containerCompare
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:container:${containerExtId}:active:health" `
                        -Attributes $containerAttrs `
                        -Tags @('nutanix', 'storage-container', $containerName)
                    Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName "Nutanix Storage Container Health - $containerName" -MonitorKind 'Active' -Endpoint $containerStatsUrl -JsonPath "['marked_for_removal']" -Value $containerHealthProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName "Nutanix Storage Container Health - $containerName" -MonitorKind 'Active' -Endpoint $containerStatsUrl -JsonPath "['marked_for_removal']" -Value '' -Status 'Skipped' -Reason $containerHealthProbe.Reason
                }

                $containerV4StatsEndpoint = "/api/clustermgmt/v4.1/stats/storage-containers/${containerExtId}"
                $containerV2Endpoint = "/api/nutanix/v2.0/storage_containers/${containerExtId}"
                $containerUsageProbe = Resolve-NxMonitorValue -Endpoint $containerV4StatsEndpoint -Candidates @(
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $containerV4StatsEndpoint -Select 'storageUsageBytes,usageBytes' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.storageUsageBytes.value[0]'; Segments = @('data', 'storageUsageBytes', 'value', '0') },
                    @{ Endpoint = $containerV2Endpoint; JsonPath = "$.usage_stats['storage.usage_bytes']"; Segments = @('usage_stats', 'storage.usage_bytes') }
                )
                if ($containerUsageProbe.Valid) {
                    $items += New-DiscoveredItem `
                        -Name "Storage Container Usage bytes - $containerName (nutanix)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $containerUsageProbe.Endpoint
                            RestApiJsonPath           = $containerUsageProbe.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'storage_container_usage_bytes'
                            _MetricDisplayName        = 'Storage Container Usage (bytes)'
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:container:${containerExtId}:perf:usage" `
                        -Attributes $containerAttrs `
                        -Tags @('nutanix', 'storage-container', $containerName, 'usage')
                    Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName "Storage Container Usage bytes - $containerName (nutanix)" -MonitorKind 'Performance' -Endpoint $containerUsageProbe.Endpoint -JsonPath $containerUsageProbe.JsonPath -Value $containerUsageProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName "Storage Container Usage bytes - $containerName (nutanix)" -MonitorKind 'Performance' -Endpoint $containerV4StatsEndpoint -JsonPath "$.usage_stats['storage.usage_bytes']" -Value '' -Status 'Skipped' -Reason $containerUsageProbe.Reason
                }

                $containerFreeProbe = Resolve-NxMonitorValue -Endpoint $containerV4StatsEndpoint -Candidates @(
                    @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $containerV4StatsEndpoint -Select 'storageFreeBytes,freeBytes' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.storageFreeBytes.value[0]'; Segments = @('data', 'storageFreeBytes', 'value', '0') },
                    @{ Endpoint = $containerV2Endpoint; JsonPath = "$.usage_stats['storage.free_bytes']"; Segments = @('usage_stats', 'storage.free_bytes') }
                )
                if ($containerFreeProbe.Valid) {
                    $items += New-DiscoveredItem `
                        -Name "Storage Container Free bytes - $containerName (nutanix)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $containerFreeProbe.Endpoint
                            RestApiJsonPath           = $containerFreeProbe.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'storage_container_free_bytes'
                            _MetricDisplayName        = 'Storage Container Free (bytes)'
                        } `
                        -UniqueKey "Nutanix:${clusterExtId}:container:${containerExtId}:perf:free" `
                        -Attributes $containerAttrs `
                        -Tags @('nutanix', 'storage-container', $containerName, 'free')
                    Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName "Storage Container Free bytes - $containerName (nutanix)" -MonitorKind 'Performance' -Endpoint $containerFreeProbe.Endpoint -JsonPath $containerFreeProbe.JsonPath -Value $containerFreeProbe.Value -Status 'Created' -Reason ''
                }
                else {
                    Add-NxPopulationLog -EntityType 'StorageContainer' -EntityName $containerName -MonitorName "Storage Container Free bytes - $containerName (nutanix)" -MonitorKind 'Performance' -Endpoint $containerV4StatsEndpoint -JsonPath "$.usage_stats['storage.free_bytes']" -Value '' -Status 'Skipped' -Reason $containerFreeProbe.Reason
                }
            }
        }

        # --- VMs (required endpoints) ---
        # /api/vmm/v4.1/ahv/config/vms
        # /api/vmm/v4.1/ahv/stats/vms
        # /api/vmm/v4.1/ahv/stats/vms/{extId}
        $vmEndpointCandidates = @(
            '/api/vmm/v4.1/ahv/config/vms',
            '/api/nutanix/v2.0/vms?include_vm_nic_config=true',
            '/api/nutanix/v2.0/vms/?include_vm_nic_config=true&include_vm_disk_config=true',
            '/api/nutanix/v2.0/vms/'
        )

        foreach ($c in @($clusters)) {
            $cProxy = Get-NxFirst -Object $c -Paths @('cluster_uuid', 'extId', 'uuid', 'metadata.uuid') -Default ''
            if ($cProxy) {
                $vmEndpointCandidates += "/api/nutanix/v2.0/vms/?include_vm_nic_config=true&proxyClusterUuid=${cProxy}"
                $vmEndpointCandidates += "/api/nutanix/v2.0/vms/?include_vm_nic_config=true&include_vm_disk_config=true&proxyClusterUuid=${cProxy}"
            }
        }

        foreach ($proxy in @($clusterUuidCandidates.Keys)) {
            if (-not $proxy) { continue }
            $vmEndpointCandidates += "/api/nutanix/v2.0/vms/?include_vm_nic_config=true&proxyClusterUuid=${proxy}"
            $vmEndpointCandidates += "/api/nutanix/v2.0/vms/?include_vm_nic_config=true&include_vm_disk_config=true&proxyClusterUuid=${proxy}"
        }

        $vmEndpointCandidates += @{ Endpoint = '/api/nutanix/v3/vms/list'; Method = 'POST'; Body = '{"kind":"vm","length":1000,"offset":0}' }

        $vmResult = Get-NutanixEntityList -Endpoints $vmEndpointCandidates
        $vmCfg = @($vmResult.List)
        $vmEndpointUsed = $vmResult.Endpoint
        $vmProxyClusterUuid = ''
        if ($vmEndpointUsed -match 'proxyClusterUuid=([^&]+)') {
            $vmProxyClusterUuid = [System.Uri]::UnescapeDataString($Matches[1])
        }

        Write-Host "  Found $($vmCfg.Count) VM object(s)" -ForegroundColor DarkGray

        foreach ($vm in $vmCfg) {
            $vmExtId = Get-NxFirst -Object $vm -Paths @('extId', 'uuid', 'metadata.uuid') -Default ''
            if (-not $vmExtId) { continue }

            $vmName = Get-NxFirst -Object $vm -Paths @('name', 'status.name', 'spec.name') -Default "VM-$vmExtId"
            $vmState = Get-NxFirst -Object $vm -Paths @('powerState', 'power_state', 'status.powerState') -Default 'unknown'
            $vmIp = Get-NxVmIp -Vm $vm
            if (-not $vmIp) { $vmIp = $hostTarget }
            $vmClusterName = Get-NxFirst -Object $vm -Paths @('clusterName', 'cluster_name', 'status.clusterReference.name', 'cluster.name') -Default $hostTarget

            $vmUsesV4 = $vmEndpointUsed -and ($vmEndpointUsed -like '/api/vmm/*')
            $vmUsesV3 = $vmEndpointUsed -and ($vmEndpointUsed -like '/api/nutanix/v3/*')
            $vmHealthUrl = ''
            if ($vmUsesV4) {
                $vmHealthUrl = "${baseUri}/api/vmm/v4.1/ahv/config/vms/${vmExtId}"
            }
            elseif ($vmUsesV3) {
                # v3 list endpoints are not stable single-object monitor targets.
                $vmHealthUrl = "${baseUri}/api/nutanix/v3/vms/list"
            }
            else {
                $vmHealthUrl = "${baseUri}/api/nutanix/v2.0/vms/${vmExtId}"
                if ($vmProxyClusterUuid) {
                    $vmHealthUrl = "${vmHealthUrl}?proxyClusterUuid=${vmProxyClusterUuid}"
                }

            }

            $vmDetail = $null
            try { $vmDetail = Invoke-NutanixREST -Endpoint $vmHealthUrl -Method 'GET' } catch { }

            $vmPower = Get-NxFirst -Object $vm -Paths @('powerState', 'power_state', 'status.powerState') -Default 'unknown'
            $vmHostName = Get-NxFirst -Object $vm -Paths @('hostName', 'host_name', 'status.hostReference.name') -Default ''

            $vmAttrs = @{
                'DiscoveryHelper.Nutanix' = 'true'
                'Nutanix.DeviceType'      = 'VM'
                'Nutanix.ClusterName'     = $vmClusterName
                'Nutanix.VMName'          = $vmName
                'Nutanix.VMState'         = $vmState
                'Nutanix.VMPowerState'    = $vmPower
                'Nutanix.VMUuid'          = $vmExtId
                'Nutanix.VMExtId'         = $vmExtId
                'Nutanix.VMHostName'      = $vmHostName
                'Nutanix.VMIP'            = $vmIp
                'Nutanix.IPAddress'       = $vmIp
                'Nutanix.ApiFamily'       = if ($vmUsesV4) { 'v4' } elseif ($vmUsesV3) { 'v3' } else { 'v2' }
                'Vendor'                  = 'Nutanix'
            }

            $vmPowerProbe = Resolve-NxMonitorValue -Endpoint $vmHealthUrl -Response $vmDetail -Candidates @(
                @{ JsonPath = "['power_state']"; Segments = @('power_state') },
                @{ JsonPath = "['powerState']"; Segments = @('powerState') }
            )
            Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName 'EntityPopulate' -MonitorKind 'Info' -Endpoint $vmHealthUrl -JsonPath "['power_state']" -Value $vmPowerProbe.Value -Status 'Captured' -Reason ''
            if ($vmPowerProbe.Valid) {
                $vmCompare = New-NxStringDoesNotContainComparison -JsonPathQuery "['power_state']" -ExpectedValue 'on'
                $items += New-DiscoveredItem `
                    -Name "Nutanix VM Health - $vmName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                    = $vmHealthUrl
                        RestApiMethod                 = 'GET'
                        RestApiTimeoutMs              = 15000
                        RestApiUseAnonymous           = '0'
                        RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                        RestApiComparisonList         = $vmCompare
                    } `
                    -UniqueKey "Nutanix:vm:${vmExtId}:active:health" `
                    -Attributes $vmAttrs `
                    -Tags @('nutanix', 'vm', $vmName)
                Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName "Nutanix VM Health - $vmName" -MonitorKind 'Active' -Endpoint $vmHealthUrl -JsonPath "['power_state']" -Value $vmPowerProbe.Value -Status 'Created' -Reason ''
            }
            else {
                Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName "Nutanix VM Health - $vmName" -MonitorKind 'Active' -Endpoint $vmHealthUrl -JsonPath "['power_state']" -Value '' -Status 'Skipped' -Reason $vmPowerProbe.Reason
            }

            $vmV4StatsEndpoint = "/api/vmm/v4.1/ahv/stats/vms/${vmExtId}"
            $vmV2StatsEndpoint = "/api/nutanix/v2.0/vms/${vmExtId}/stats/"
            $vmV2DetailEndpoint = "/api/nutanix/v2.0/vms/${vmExtId}"
            if ($vmProxyClusterUuid) {
                $vmV2StatsEndpoint = "${vmV2StatsEndpoint}?proxyClusterUuid=${vmProxyClusterUuid}"
                $vmV2DetailEndpoint = "${vmV2DetailEndpoint}?proxyClusterUuid=${vmProxyClusterUuid}"
            }

            $vmCpuProbe = Resolve-NxMonitorValue -Endpoint $vmV4StatsEndpoint -Candidates @(
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $vmV4StatsEndpoint -Select 'stats,cpuUsagePpm,hypervisorCpuUsagePpm,hypervisor_cpu_usage_ppm' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.cpuUsagePpm.value[0]'; Segments = @('data', 'cpuUsagePpm', 'value', '0') },
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $vmV4StatsEndpoint -Select 'stats,cpuUsagePpm,hypervisorCpuUsagePpm,hypervisor_cpu_usage_ppm' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.hypervisorCpuUsagePpm.value[0]'; Segments = @('data', 'hypervisorCpuUsagePpm', 'value', '0') },
                @{ Endpoint = $vmV2StatsEndpoint; JsonPath = '$.stats_specific_responses[0].values[0]'; Segments = @('stats_specific_responses', '0', 'values', '0') },
                @{ Endpoint = $vmV2DetailEndpoint; JsonPath = '$.stats.hypervisor_cpu_usage_ppm'; Segments = @('stats', 'hypervisor_cpu_usage_ppm') },
                @{ Endpoint = $vmV2DetailEndpoint; JsonPath = '$.hypervisor_cpu_usage_ppm'; Segments = @('hypervisor_cpu_usage_ppm') }
            )
            if ($vmCpuProbe.Valid) {
                $items += New-DiscoveredItem `
                    -Name "CPU Usage % - $vmName (nutanix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $vmCpuProbe.Endpoint
                        RestApiJsonPath           = $vmCpuProbe.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        _MetricName               = 'cpu_usage_ppm'
                        _MetricDisplayName        = 'CPU Usage (ppm)'
                    } `
                    -UniqueKey "Nutanix:vm:${vmExtId}:perf:cpu" `
                    -Attributes $vmAttrs `
                    -Tags @('nutanix', 'vm', $vmName, 'cpu')
                Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName "CPU Usage % - $vmName (nutanix)" -MonitorKind 'Performance' -Endpoint $vmCpuProbe.Endpoint -JsonPath $vmCpuProbe.JsonPath -Value $vmCpuProbe.Value -Status 'Created' -Reason ''
            }
            else {
                Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName "CPU Usage % - $vmName (nutanix)" -MonitorKind 'Performance' -Endpoint $vmV4StatsEndpoint -JsonPath '' -Value '' -Status 'Skipped' -Reason $vmCpuProbe.Reason
                Write-Verbose "Skipping VM CPU monitor for '$vmName' because no compatible stats JSONPath was found."
            }

            $vmMemProbe = Resolve-NxMonitorValue -Endpoint $vmV4StatsEndpoint -Candidates @(
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $vmV4StatsEndpoint -Select 'stats,memoryUsagePpm,hypervisorMemoryUsagePpm,hypervisor_memory_usage_ppm' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.memoryUsagePpm.value[0]'; Segments = @('data', 'memoryUsagePpm', 'value', '0') },
                @{ Endpoint = (New-NxStatsQueryEndpoint -BaseEndpoint $vmV4StatsEndpoint -Select 'stats,memoryUsagePpm,hypervisorMemoryUsagePpm,hypervisor_memory_usage_ppm' -StatType 'LAST' -SamplingInterval 30); JsonPath = '$.data.hypervisorMemoryUsagePpm.value[0]'; Segments = @('data', 'hypervisorMemoryUsagePpm', 'value', '0') },
                @{ Endpoint = $vmV2StatsEndpoint; JsonPath = '$.stats_specific_responses[0].values[0]'; Segments = @('stats_specific_responses', '0', 'values', '0') },
                @{ Endpoint = $vmV2DetailEndpoint; JsonPath = '$.stats.hypervisor_memory_usage_ppm'; Segments = @('stats', 'hypervisor_memory_usage_ppm') },
                @{ Endpoint = $vmV2DetailEndpoint; JsonPath = '$.hypervisor_memory_usage_ppm'; Segments = @('hypervisor_memory_usage_ppm') }
            )
            if ($vmMemProbe.Valid) {
                $items += New-DiscoveredItem `
                    -Name "Memory Usage % - $vmName (nutanix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $vmMemProbe.Endpoint
                        RestApiJsonPath           = $vmMemProbe.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        _MetricName               = 'memory_usage_ppm'
                        _MetricDisplayName        = 'Memory Usage (ppm)'
                    } `
                    -UniqueKey "Nutanix:vm:${vmExtId}:perf:memory" `
                    -Attributes $vmAttrs `
                    -Tags @('nutanix', 'vm', $vmName, 'memory')
                Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName "Memory Usage % - $vmName (nutanix)" -MonitorKind 'Performance' -Endpoint $vmMemProbe.Endpoint -JsonPath $vmMemProbe.JsonPath -Value $vmMemProbe.Value -Status 'Created' -Reason ''
            }
            else {
                Add-NxPopulationLog -EntityType 'VM' -EntityName $vmName -MonitorName "Memory Usage % - $vmName (nutanix)" -MonitorKind 'Performance' -Endpoint $vmV4StatsEndpoint -JsonPath '' -Value '' -Status 'Skipped' -Reason $vmMemProbe.Reason
                Write-Verbose "Skipping VM memory monitor for '$vmName' because no compatible stats JSONPath was found."
            }
        }

        $global:NutanixDiscoveryLastPopulationLog = [object[]]($apiPopulationLog.ToArray())
        $global:NutanixDiscoveryLastApiPathLog = [object[]]($apiPathLog.ToArray())
        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBAs9XZhia9VM99
# lGZtQ76ubrUUXF+iT81/pYM7ylLGbqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgecLbaDJ4hea8SevlOl2yqgIMICfasE1C
# c7QltNqM/cMwDQYJKoZIhvcNAQEBBQAEggIAi95QRbx+FVHWSE2K0I0b7ikSgbJ6
# N3LdIy79uzlLTe8XV8S9t/jUogOK6Ua1PKopFCGWfTWHGmG6osVvpx+2OMnCUUWd
# m9aToy3Hago1Kj0li2KXHevbu+gi+l2CaxuxSMYAC6MOUJrmKIIGAJLeozm5wJww
# sMJ8X280hgQAk+39a5f6pCOSPz3IVorS544omgviOJo/C9QePOXZQ2z2qifc8rMS
# 3cHkqFQgFJpmWRFIJEEGKAICZ+JLklkqDot5GaCHdXoL9ERq77XHNvgbItIcC9SH
# uVGkjTMSN84gOeeE1gwzc5y5esGB4r6LsTSXhKw69u0qJnE3mtMT/Bzqb7r/kqEf
# h1vp/4jVB1HjzCR/1G6hbDzlnQlQpawWcCw4RZxgTp2wg+P7w1C3o+z9yT92Z83T
# 7AzIyNA6/WjNeLcTi39rbBO8Fq0W3qBoPPjKI2aUdPiPFbzkLP43eycvz8gTKNXY
# KxK1o1c2EpJnutAM1iOL4aECxScT3gAHHFg+IrqQeymaXSX+xoNRD43EUvizJCtR
# wg7cLRa2ucHxARdq86m+8TXDUXqfugGEfRBDo7F3seETlF1h3y7H9qnSZFGYknaI
# aUHxktTF11GJ1xihpwrPzZzaSa84vNgb7YUGmQC24i1X/uZTJNbByCOTWVsa5iHh
# ++TwNAUmHSIfaQc=
# SIG # End signature block
