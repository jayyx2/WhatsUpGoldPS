<#
.SYNOPSIS
    Kemp LoadMaster discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers a LoadMaster discovery provider that queries the LoadMaster
    RESTful APIv2 to discover the appliance, virtual services, sub-virtual
    services, and real servers, then builds a monitor plan suitable for
    WhatsUp Gold or standalone use.

    Hierarchy:
      LoadMaster (appliance)
        +-- Virtual Service (VS)
              +-- Sub-Virtual Service (SubVS)
              +-- Real Server (RS)

    Active Monitors (up/down):
      - Appliance: stats endpoint returns status=ok
      - VS: showvs returns Status field
      - RS: showvs returns Rs[].Status field

    Performance Monitors (stats over time):
      - Appliance: CPU, Memory, TotalConns, ActiveConns, TPS, SSL_TPS, BytesPerSec
      - VS: ActiveConns, ConnsPerSec, TotalConns, TotalBytes, BytesRead, BytesWritten
      - RS: ActiveConns, Conns, Bytes, Pkts

    Authentication:
      - API Key (recommended for WUG monitoring)
      - Basic Auth (bal:password)

    Prerequisites:
      1. LoadMaster API enabled (Certificates & Security > Remote Access)
      2. Session Management enabled + Basic Auth disabled (for APIv2)
      3. API key generated OR valid bal credentials

    API Reference:
      https://loadmasterapiv2.docs.progress.com/

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

# ============================================================================
# LoadMaster API Helper
# ============================================================================

function Invoke-LoadMasterAPI {
    <#
    .SYNOPSIS
        Calls a LoadMaster APIv2 command via POST to /accessv2.
    .PARAMETER LMHost
        LoadMaster hostname or IP.
    .PARAMETER LMPort
        API port (default 443).
    .PARAMETER Command
        API command name (stats, listvs, showvs, etc.).
    .PARAMETER Params
        Additional parameters as a hashtable (e.g. @{ vs = '1' }).
    .PARAMETER ApiKey
        API key for authentication.
    .PARAMETER Credential
        PSCredential for Basic Auth (bal:password).
    .PARAMETER IgnoreCertErrors
        Skip SSL certificate validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LMHost,
        [int]$LMPort = 443,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Params,
        [string]$ApiKey,
        [PSCredential]$Credential,
        [bool]$IgnoreCertErrors = $true
    )

    # Enforce TLS 1.2
    if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }

    $uri = "https://${LMHost}:${LMPort}/accessv2"
    $body = @{ cmd = $Command }

    if ($ApiKey) {
        $body['apikey'] = $ApiKey
    }
    elseif ($Credential) {
        $body['apiuser'] = $Credential.UserName
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        try {
            $body['apipass'] = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    if ($Params) {
        foreach ($k in $Params.Keys) { $body[$k] = $Params[$k] }
    }

    $jsonBody = $body | ConvertTo-Json -Depth 10 -Compress

    $irmSplat = @{
        Uri         = $uri
        Method      = 'POST'
        Body        = $jsonBody
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }

    # Handle cert errors — PS 5.1 uses process-wide callback, PS 7+ uses per-request parameter
    if ($IgnoreCertErrors) {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $irmSplat['SkipCertificateCheck'] = $true
        }
        else {
            # PS 5.1: process-wide SSL bypass via ServerCertificateValidationCallback
            if (-not $script:_LMCertBypassSet) {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                Write-Warning "SSL certificate validation is disabled for LoadMaster API calls. Use -IgnoreCertErrors `$false to enforce validation."
                $script:_LMCertBypassSet = $true
            }
        }
    }

    $resp = Invoke-RestMethod @irmSplat

    # Some LM commands (showvs, listvs) may return raw JSON string instead of parsed object
    if ($resp -is [string]) {
        try { $resp = $resp | ConvertFrom-Json } catch { Write-Verbose "Response was string but not valid JSON" }
    }

    if ($resp.code -and [int]$resp.code -ne 200) {
        throw "LoadMaster API error ($Command): $($resp.message) (code $($resp.code))"
    }

    return $resp
}

# ============================================================================
# LoadMaster Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'LoadMaster' `
    -MatchAttribute 'DiscoveryHelper.LoadMaster' `
    -AuthType 'BasicAuth' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $lmHost = $ctx.DeviceIP
        $lmPort = if ($ctx.Port) { $ctx.Port } else { 443 }
        $ignoreCert = if ($ctx.IgnoreCertErrors -eq $false) { $false } else { $true }
        $ignoreCertStr = if ($ignoreCert) { '1' } else { '0' }

        # --- Resolve credential ---
        $apiKey = $null
        $credential = $null
        $authMode = 'ApiKey'

        if ($ctx.Credential) {
            if ($ctx.Credential -is [string]) {
                $apiKey = $ctx.Credential
            }
            elseif ($ctx.Credential -is [PSCredential]) {
                $credential = $ctx.Credential
                $authMode = 'BasicAuth'
            }
            elseif ($ctx.Credential.ApiKey) {
                $apiKey = $ctx.Credential.ApiKey
            }
            elseif ($ctx.Credential.UserName -or $ctx.Credential.Username) {
                $uname = if ($ctx.Credential.UserName) { $ctx.Credential.UserName } else { $ctx.Credential.Username }
                $pw = $ctx.Credential.Password
                if ($pw -is [System.Security.SecureString]) {
                    $credential = New-Object System.Management.Automation.PSCredential($uname, $pw)
                }
                else {
                    $secPw = ConvertTo-SecureString -String "$pw" -AsPlainText -Force
                    $credential = New-Object System.Management.Automation.PSCredential($uname, $secPw)
                }
                $authMode = 'BasicAuth'
            }
        }

        $apiSplat = @{
            LMHost          = $lmHost
            LMPort          = $lmPort
            IgnoreCertErrors = $ignoreCert
        }
        if ($apiKey)     { $apiSplat['ApiKey'] = $apiKey }
        if ($credential) { $apiSplat['Credential'] = $credential }

        # Helper: build monitor URL for WUG polling (GET to /accessv2 with query params)
        $monBaseUrl = "https://${lmHost}:${lmPort}/accessv2"
        $authSuffix = ''
        $useAnonymous = '0'
        if ($apiKey) {
            $authSuffix = "&apikey=$([uri]::EscapeDataString($apiKey))"
            $useAnonymous = '1'
        }

        # ================================================================
        # Phase 1: System Discovery
        # ================================================================
        Write-Host "  Querying LoadMaster system stats..." -ForegroundColor DarkGray
        $sysStats = $null
        try {
            $sysStats = Invoke-LoadMasterAPI @apiSplat -Command 'stats'
        }
        catch {
            Write-Warning "Failed to query system stats: $_"
            return $items
        }

        # Get system info
        $hostname = ''
        $version = ''
        $hamode = 0
        $serialNumber = ''
        try {
            $infoResp = Invoke-LoadMasterAPI @apiSplat -Command 'getall'
            if ($infoResp.hostname)     { $hostname = "$($infoResp.hostname)" }
            if ($infoResp.version)      { $version = "$($infoResp.version)" }
            if ($null -ne $infoResp.hamode) { $hamode = [int]$infoResp.hamode }
            if ($infoResp.serialnumber) { $serialNumber = "$($infoResp.serialnumber)" }
        }
        catch {
            Write-Verbose "Could not fetch system info: $_"
            # Try individual gets as fallback
            try { $hostname = "$((Invoke-LoadMasterAPI @apiSplat -Command 'get' -Params @{param='hostname'}).hostname)" } catch { }
            try { $version = "$((Invoke-LoadMasterAPI @apiSplat -Command 'get' -Params @{param='version'}).version)" } catch { }
        }
        if (-not $hostname) { $hostname = $lmHost }

        Write-Host "    Hostname: $hostname" -ForegroundColor DarkGray
        Write-Host "    Version: $version" -ForegroundColor DarkGray
        Write-Host "    Serial: $serialNumber" -ForegroundColor DarkGray
        Write-Host "    HA Mode: $(switch ($hamode) { 0 {'None'} 1 {'Master'} 2 {'Standby'} default {"$hamode"} })" -ForegroundColor DarkGray

        # --- Helper: extract all numeric properties from a PSObject ---
        # Returns array of @{ Field; Label; JsonPath; Value }
        $extractNumericProps = {
            param([object]$Obj, [string]$JsonPrefix, [string]$LabelPrefix, [string[]]$Skip)
            $out = @()
            if ($null -eq $Obj) { return $out }
            foreach ($p in $Obj.PSObject.Properties) {
                if ($Skip -contains $p.Name) { continue }
                $v = $p.Value
                if ($null -eq $v) { continue }
                $numVal = $null
                $isNum = ($v -is [int]) -or ($v -is [long]) -or ($v -is [double]) -or ($v -is [decimal])
                if (-not $isNum -and ($v -is [string])) { $isNum = [double]::TryParse($v, [ref]$numVal) }
                if ($isNum) {
                    if ($null -eq $numVal) { $numVal = [double]$v }
                    $out += @{
                        Field    = $p.Name
                        Label    = if ($LabelPrefix) { "${LabelPrefix} $($p.Name)" } else { $p.Name }
                        JsonPath = "${JsonPrefix}.$($p.Name)"
                        Value    = $numVal
                    }
                }
            }
            return $out
        }

        # ====================================================================
        # Discover ALL system metrics from nested stats response
        # ====================================================================
        $systemMetrics = [System.Collections.ArrayList]@()

        # CPU totals ($.CPU.total.*)
        if ($sysStats.CPU -and $sysStats.CPU.total) {
            foreach ($m in (& $extractNumericProps $sysStats.CPU.total '$.CPU.total' 'CPU' @())) {
                [void]$systemMetrics.Add($m)
            }
        }

        # Memory ($.Memory.*)
        if ($sysStats.Memory) {
            foreach ($m in (& $extractNumericProps $sysStats.Memory '$.Memory' 'Mem' @())) {
                [void]$systemMetrics.Add($m)
            }
        }

        # VS aggregate totals ($.VStotals.*)
        if ($sysStats.VStotals) {
            foreach ($m in (& $extractNumericProps $sysStats.VStotals '$.VStotals' 'VSTotals' @())) {
                [void]$systemMetrics.Add($m)
            }
        }

        # TPS ($.TPS.*)
        if ($sysStats.TPS) {
            foreach ($m in (& $extractNumericProps $sysStats.TPS '$.TPS' 'TPS' @())) {
                [void]$systemMetrics.Add($m)
            }
        }

        # Client limits ($.ClientLimits.Totals.*)
        if ($sysStats.ClientLimits -and $sysStats.ClientLimits.Totals) {
            foreach ($m in (& $extractNumericProps $sysStats.ClientLimits.Totals '$.ClientLimits.Totals' 'Clients' @())) {
                [void]$systemMetrics.Add($m)
            }
        }

        # Network interfaces ($.Network.Interface[i].*)
        if ($sysStats.Network -and $sysStats.Network.Interface) {
            $ifaces = @($sysStats.Network.Interface)
            for ($ni = 0; $ni -lt $ifaces.Count; $ni++) {
                $iface = $ifaces[$ni]
                $ifName = if ($iface.Name) { "$($iface.Name)" } else { "if${ni}" }
                $ifPrefix = '$.Network.Interface[' + $ni + ']'
                foreach ($m in (& $extractNumericProps $iface $ifPrefix "Net ${ifName}" @('Name', 'ifaceID'))) {
                    [void]$systemMetrics.Add($m)
                }
            }
        }

        # Disk partitions ($.DiskUsage.partition[i].*)
        if ($sysStats.DiskUsage -and $sysStats.DiskUsage.partition) {
            $parts = @($sysStats.DiskUsage.partition)
            for ($di = 0; $di -lt $parts.Count; $di++) {
                $part = $parts[$di]
                $partName = if ($part.name) { "$($part.name)" } else { "disk${di}" }
                $diskPrefix = '$.DiskUsage.partition[' + $di + ']'
                foreach ($m in (& $extractNumericProps $part $diskPrefix "Disk ${partName}" @('name'))) {
                    [void]$systemMetrics.Add($m)
                }
            }
        }

        Write-Host "    System metrics: $($systemMetrics.Count) available" -ForegroundColor DarkGray

        # ---- Pre-build VS and RS stats maps from stats response ----
        $vsStatsMap = @{}   # Key: VS Index string -> @{ ArrayIdx; Entry; Metrics }
        if ($sysStats.Vs) {
            $vsArr = @($sysStats.Vs)
            for ($vi = 0; $vi -lt $vsArr.Count; $vi++) {
                $vsE = $vsArr[$vi]
                $vIdx = "$($vsE.Index)"
                $vsPrefix = '$.Vs[' + $vi + ']'
                $vMetrics = & $extractNumericProps $vsE $vsPrefix '' @('Index', 'ErrorCode', 'Enable', 'WafEnable', 'InterceptMode')
                $vsStatsMap[$vIdx] = @{ ArrayIdx = $vi; Entry = $vsE; Metrics = $vMetrics }
            }
        }

        $rsStatsMap = @{}   # Key: "VSIndex:RSIndex" -> @{ ArrayIdx; Entry; Metrics }
        if ($sysStats.Rs) {
            $rsArr = @($sysStats.Rs)
            for ($rsi = 0; $rsi -lt $rsArr.Count; $rsi++) {
                $rsE = $rsArr[$rsi]
                $rsKey = "$($rsE.VSIndex):$($rsE.RSIndex)"
                $rsPrefix = '$.Rs[' + $rsi + ']'
                $rMetrics = & $extractNumericProps $rsE $rsPrefix '' @('VSIndex', 'RSIndex', 'Enable', 'Persist', 'Port')
                $rsStatsMap[$rsKey] = @{ ArrayIdx = $rsi; Entry = $rsE; Metrics = $rMetrics }
            }
        }

        Write-Host "    VS stats entries: $($vsStatsMap.Count) | RS stats entries: $($rsStatsMap.Count)" -ForegroundColor DarkGray

        # --- Appliance monitor URL ---
        $statsUrl = "${monBaseUrl}?cmd=stats${authSuffix}"

        $applianceAttrs = @{
            'LoadMaster.Hostname'     = $hostname
            'LoadMaster.Version'      = $version
            'LoadMaster.Serial'       = $serialNumber
            'LoadMaster.HAMode'       = "$hamode"
            'LoadMaster.ApiHost'      = $lmHost
            'LoadMaster.ApiPort'      = "$lmPort"
            'LoadMaster.AuthMode'     = $authMode
            'LoadMaster.DeviceType'   = 'Appliance'
            'LoadMaster.MetricCount'  = "$($systemMetrics.Count)"
        }

        # --- Appliance active monitor (health check) ---
        $items += New-DiscoveredItem `
            -Name "LM Health [$hostname]" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams @{
                RestApiUrl                    = $statsUrl
                RestApiMethod                 = 'GET'
                RestApiTimeoutMs              = '10000'
                RestApiIgnoreCertErrors       = $ignoreCertStr
                RestApiUseAnonymous           = $useAnonymous
                RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                RestApiComparisonList         = '[]'
            } `
            -UniqueKey "LM:${lmHost}:active:health" `
            -DeviceId 0 `
            -Attributes $applianceAttrs `
            -Tags @('loadmaster', 'appliance', 'active')

        # --- Appliance perf monitors (ALL discovered system metrics) ---
        foreach ($m in $systemMetrics) {
            $items += New-DiscoveredItem `
                -Name "LM $($m.Label) [$hostname]" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                = $statsUrl
                    RestApiJsonPath           = $m.JsonPath
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '10000'
                    RestApiIgnoreCertErrors   = $ignoreCertStr
                    RestApiUseAnonymousAccess = $useAnonymous
                } `
                -UniqueKey "LM:${lmHost}:perf:sys:$($m.JsonPath)" `
                -DeviceId 0 `
                -Tags @('loadmaster', 'appliance', 'performance', $m.Field.ToLower())
        }

        # ================================================================
        # Phase 2: Virtual Service Discovery
        # ================================================================
        Write-Host "  Listing virtual services..." -ForegroundColor DarkGray
        $vsList = @()
        try {
            $vsResp = Invoke-LoadMasterAPI @apiSplat -Command 'listvs'
            if ($vsResp.VS) {
                $vsList = @($vsResp.VS)
            }
        }
        catch {
            Write-Warning "Failed to list virtual services: $_"
        }
        Write-Host "    Virtual services: $($vsList.Count)" -ForegroundColor DarkGray

        # ================================================================
        # Phase 3: VS + RS Drill-Down
        # ================================================================
        $vsDeviceIdx = 1
        $rsDeviceIdx = 1000
        foreach ($vs in $vsList) {
            $vsIndex = "$($vs.Index)"
            $vsNick = if ($vs.NickName) { "$($vs.NickName)" } else { '' }
            $vsAddr = if ($vs.VSAddress) { "$($vs.VSAddress)" } else { '' }
            $vsPort = if ($vs.VSPort) { "$($vs.VSPort)" } else { '' }
            $vsProto = if ($vs.VSProtocol) { "$($vs.VSProtocol)" } else { '' }
            $vsStatus = if ($vs.Status) { "$($vs.Status)" } else { 'Unknown' }
            $vsEnable = if ($vs.Enable) { "$($vs.Enable)" } else { '' }

            $vsLabel = if ($vsNick) { $vsNick } else { "${vsAddr}:${vsPort}" }
            Write-Host "    VS ${vsIndex}: $vsLabel (${vsAddr}:${vsPort} $vsProto) - $vsStatus" -ForegroundColor DarkGray

            # --- Get VS stats from the pre-built stats map ---
            $vsStatsEntry = $vsStatsMap[$vsIndex]
            $vsMetrics = if ($vsStatsEntry) { @($vsStatsEntry.Metrics) } else { @() }
            Write-Host "      Stats metrics: $($vsMetrics.Count)" -ForegroundColor DarkGray

            # --- Get RS list from showvs (now properly parsed) ---
            $rsArray = @()
            $subVSArray = @()
            try {
                $vsDetail = Invoke-LoadMasterAPI @apiSplat -Command 'showvs' -Params @{ vs = $vsIndex }
                # showvs response has Rs at root level (no .VS wrapper)
                if ($vsDetail.Rs) { $rsArray = @($vsDetail.Rs) }
                if ($vsDetail.SubVS) { $subVSArray = @($vsDetail.SubVS) }
            }
            catch {
                Write-Verbose "Could not get details for VS ${vsIndex}: $_"
            }

            # --- VS monitor URL (showvs for health check) ---
            $vsShowUrl = "${monBaseUrl}?cmd=showvs&vs=${vsIndex}${authSuffix}"

            # --- VS device attributes ---
            $vsAttrs = @{
                'LoadMaster.DeviceType'      = 'VirtualService'
                'LoadMaster.VSIndex'         = $vsIndex
                'LoadMaster.VSAddress'       = $vsAddr
                'LoadMaster.VSPort'          = $vsPort
                'LoadMaster.VSProtocol'      = $vsProto
                'LoadMaster.VSNickName'      = $vsNick
                'LoadMaster.VSStatus'        = $vsStatus
                'LoadMaster.VSEnable'        = $vsEnable
                'LoadMaster.ApiHost'         = $lmHost
                'LoadMaster.ApiPort'         = "$lmPort"
                'LoadMaster.ParentAppliance' = $hostname
                'LoadMaster.RSCount'         = "$($rsArray.Count)"
                'LoadMaster.SubVSCount'      = "$($subVSArray.Count)"
                'LoadMaster.MetricCount'     = "$($vsMetrics.Count)"
            }

            # --- VS active monitor ---
            $items += New-DiscoveredItem `
                -Name "LM VS Health [$vsLabel]" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $vsShowUrl
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = '10000'
                    RestApiIgnoreCertErrors       = $ignoreCertStr
                    RestApiUseAnonymous           = $useAnonymous
                    RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                    RestApiComparisonList         = '[]'
                } `
                -UniqueKey "LM:${lmHost}:active:vs:${vsIndex}" `
                -DeviceId $vsDeviceIdx `
                -Attributes $vsAttrs `
                -Tags @('loadmaster', 'vs', 'active')

            # --- VS perf monitors (from stats.Vs[] via stats endpoint) ---
            foreach ($m in $vsMetrics) {
                $items += New-DiscoveredItem `
                    -Name "LM VS $($m.Label) [$vsLabel]" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                = $statsUrl
                        RestApiJsonPath           = $m.JsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '10000'
                        RestApiIgnoreCertErrors   = $ignoreCertStr
                        RestApiUseAnonymousAccess = $useAnonymous
                    } `
                    -UniqueKey "LM:${lmHost}:perf:vs:${vsIndex}:$($m.Field)" `
                    -DeviceId $vsDeviceIdx `
                    -Tags @('loadmaster', 'vs', 'performance', $m.Field.ToLower())
            }

            $vsDeviceIdx++

            # ============================================================
            # Phase 3a: SubVS Drill-Down (if present)
            # ============================================================
            if ($subVSArray.Count -gt 0) {
                Write-Host "      SubVS: $($subVSArray.Count)" -ForegroundColor DarkGray
                foreach ($subVS in $subVSArray) {
                    $subVSIndex = "$($subVS.VSIndex)"
                    if (-not $subVSIndex -and $subVS.Index) { $subVSIndex = "$($subVS.Index)" }
                    if (-not $subVSIndex) { continue }

                    $subVSLabel = if ($subVS.NickName) { "$($subVS.NickName)" } else { "SubVS-$subVSIndex" }

                    # Get SubVS stats from stats map (SubVS have their own Index)
                    $subVSStats = $vsStatsMap[$subVSIndex]
                    $subVSMetrics = if ($subVSStats) { @($subVSStats.Metrics) } else { @() }

                    $subVSShowUrl = "${monBaseUrl}?cmd=showvs&vs=${subVSIndex}${authSuffix}"

                    $subVSAttrs = @{
                        'LoadMaster.DeviceType'      = 'SubVirtualService'
                        'LoadMaster.VSIndex'         = $subVSIndex
                        'LoadMaster.ParentVSIndex'   = $vsIndex
                        'LoadMaster.ParentVSName'    = $vsLabel
                        'LoadMaster.ApiHost'         = $lmHost
                        'LoadMaster.ApiPort'         = "$lmPort"
                        'LoadMaster.ParentAppliance' = $hostname
                        'LoadMaster.MetricCount'     = "$($subVSMetrics.Count)"
                    }

                    # SubVS active monitor
                    $items += New-DiscoveredItem `
                        -Name "LM SubVS Health [$subVSLabel]" `
                        -ItemType 'ActiveMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                    = $subVSShowUrl
                            RestApiMethod                 = 'GET'
                            RestApiTimeoutMs              = '10000'
                            RestApiIgnoreCertErrors       = $ignoreCertStr
                            RestApiUseAnonymous           = $useAnonymous
                            RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
                            RestApiComparisonList         = '[]'
                        } `
                        -UniqueKey "LM:${lmHost}:active:subvs:${subVSIndex}" `
                        -DeviceId $vsDeviceIdx `
                        -Attributes $subVSAttrs `
                        -Tags @('loadmaster', 'subvs', 'active')

                    # SubVS perf monitors (from stats.Vs[] via stats endpoint)
                    foreach ($m in $subVSMetrics) {
                        $items += New-DiscoveredItem `
                            -Name "LM SubVS $($m.Label) [$subVSLabel]" `
                            -ItemType 'PerformanceMonitor' `
                            -MonitorType 'RestApi' `
                            -MonitorParams @{
                                RestApiUrl                = $statsUrl
                                RestApiJsonPath           = $m.JsonPath
                                RestApiHttpMethod         = 'GET'
                                RestApiHttpTimeoutMs      = '10000'
                                RestApiIgnoreCertErrors   = $ignoreCertStr
                                RestApiUseAnonymousAccess = $useAnonymous
                            } `
                            -UniqueKey "LM:${lmHost}:perf:subvs:${subVSIndex}:$($m.Field)" `
                            -DeviceId $vsDeviceIdx `
                            -Tags @('loadmaster', 'subvs', 'performance', $m.Field.ToLower())
                    }

                    $vsDeviceIdx++
                }
            }

            # ============================================================
            # Phase 3b: Real Server Drill-Down
            # ============================================================
            if ($rsArray.Count -gt 0) {
                Write-Host "      RS: $($rsArray.Count)" -ForegroundColor DarkGray
            }
            foreach ($rs in $rsArray) {
                $rsAddr = if ($rs.Addr) { "$($rs.Addr)" } else { '' }
                $rsPort = if ($rs.Port) { "$($rs.Port)" } else { '' }
                $rsStatus = if ($rs.Status) { "$($rs.Status)" } else { 'Unknown' }
                $rsWeight = if ($null -ne $rs.Weight) { "$($rs.Weight)" } else { '' }
                $rsLabel = "${rsAddr}:${rsPort}"

                # Match RS to stats.Rs[] using VSIndex:RSIndex
                $rsVSIdx = if ($rs.VSIndex) { "$($rs.VSIndex)" } else { $vsIndex }
                $rsRSIdx = if ($rs.RsIndex) { "$($rs.RsIndex)" } else { if ($rs.RSIndex) { "$($rs.RSIndex)" } else { '' } }
                $rsKey = "${rsVSIdx}:${rsRSIdx}"
                $rsStatsEntry = $rsStatsMap[$rsKey]
                $rsMetrics = if ($rsStatsEntry) { @($rsStatsEntry.Metrics) } else { @() }

                Write-Host "        RS: $rsLabel ($rsStatus) Weight=$rsWeight Metrics=$($rsMetrics.Count)" -ForegroundColor DarkGray

                $rsAttrs = @{
                    'LoadMaster.DeviceType'      = 'RealServer'
                    'LoadMaster.RSAddress'       = $rsAddr
                    'LoadMaster.RSPort'          = $rsPort
                    'LoadMaster.RSStatus'        = $rsStatus
                    'LoadMaster.RSWeight'        = $rsWeight
                    'LoadMaster.RSIndex'         = $rsRSIdx
                    'LoadMaster.ParentVSIndex'   = $vsIndex
                    'LoadMaster.ParentVSName'    = $vsLabel
                    'LoadMaster.ApiHost'         = $lmHost
                    'LoadMaster.ApiPort'         = "$lmPort"
                    'LoadMaster.ParentAppliance' = $hostname
                    'LoadMaster.MetricCount'     = "$($rsMetrics.Count)"
                }

                # RS perf monitors (from stats.Rs[] via stats endpoint)
                foreach ($m in $rsMetrics) {
                    $items += New-DiscoveredItem `
                        -Name "LM RS $($m.Label) [$rsLabel on $vsLabel]" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $statsUrl
                            RestApiJsonPath           = $m.JsonPath
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '10000'
                            RestApiIgnoreCertErrors   = $ignoreCertStr
                            RestApiUseAnonymousAccess = $useAnonymous
                        } `
                        -UniqueKey "LM:${lmHost}:perf:rs:${rsVSIdx}:${rsRSIdx}:$($m.Field)" `
                        -DeviceId $rsDeviceIdx `
                        -Tags @('loadmaster', 'rs', 'performance', $m.Field.ToLower())
                }

                $rsDeviceIdx++
            }
        }

        # ================================================================
        # Summary
        # ================================================================
        $activeCount = @($items | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
        $perfCount = @($items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count
        $rsTotal = @($rsStatsMap.Keys).Count
        Write-Host "  Discovery complete: $activeCount active monitors, $perfCount perf monitors" -ForegroundColor Green
        Write-Host "  Hierarchy: 1 appliance, $($vsList.Count) VS, $rsTotal RS" -ForegroundColor DarkGray

        return $items
    }

# ============================================================================
# LoadMaster Discovery Dashboard Export
# ============================================================================
function Export-LoadMasterDashboardHtml {
    <#
    .SYNOPSIS
        Generates a LoadMaster discovery dashboard from live API data.
    .PARAMETER LMHost
        LoadMaster hostname or IP.
    .PARAMETER LMPort
        API port (default 443).
    .PARAMETER ApiKey
        API key for authentication.
    .PARAMETER Credential
        PSCredential for Basic Auth.
    .PARAMETER OutputPath
        Path for the generated HTML file.
    .PARAMETER Title
        Dashboard title.
    .PARAMETER IgnoreCertErrors
        Skip SSL validation (default $true).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LMHost,
        [int]$LMPort = 443,
        [string]$ApiKey,
        [PSCredential]$Credential,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$Title = 'LoadMaster Discovery Dashboard',
        [bool]$IgnoreCertErrors = $true
    )

    $apiSplat = @{
        LMHost           = $LMHost
        LMPort           = $LMPort
        IgnoreCertErrors = $IgnoreCertErrors
    }
    if ($ApiKey)     { $apiSplat['ApiKey'] = $ApiKey }
    if ($Credential) { $apiSplat['Credential'] = $Credential }

    # Gather live data
    $rows = @()

    # System stats
    try {
        $stats = Invoke-LoadMasterAPI @apiSplat -Command 'stats'
        $hostname = ''
        try { $hostname = "$((Invoke-LoadMasterAPI @apiSplat -Command 'get' -Params @{param='hostname'}).hostname)" } catch { $hostname = $LMHost }
        $version = ''
        try { $version = "$((Invoke-LoadMasterAPI @apiSplat -Command 'get' -Params @{param='version'}).version)" } catch { }

        # Extract nested stats values
        $cpuUser = if ($stats.CPU -and $stats.CPU.total) { "$($stats.CPU.total.User)%" } else { 'N/A' }
        $memInfo = if ($stats.Memory) { "$($stats.Memory.MBused)/$($stats.Memory.MBtotal) MB ($($stats.Memory.percentmemused)%)" } else { 'N/A' }
        $vsActiveConns = if ($stats.VStotals -and $null -ne $stats.VStotals.TotalConns) { "$($stats.VStotals.TotalConns)" } else { 'N/A' }
        $tpsTotal = if ($stats.TPS) { "$($stats.TPS.Total)" } else { 'N/A' }
        $tpsSSL = if ($stats.TPS) { "$($stats.TPS.SSL)" } else { 'N/A' }
        $bytesPerSec = if ($stats.VStotals -and $null -ne $stats.VStotals.BytesPerSec) { "$($stats.VStotals.BytesPerSec)" } else { 'N/A' }

        $rows += [PSCustomObject]@{
            Type         = 'Appliance'
            Name         = $hostname
            Address      = $LMHost
            Port         = "$LMPort"
            Status       = 'Up'
            Version      = $version
            CPU          = $cpuUser
            Memory       = $memInfo
            ActiveConns  = $vsActiveConns
            TotalConns   = if ($stats.VStotals) { "$($stats.VStotals.TotalConns)" } else { 'N/A' }
            TPS          = $tpsTotal
            SSL_TPS      = $tpsSSL
            BytesPerSec  = $bytesPerSec
            ParentVS     = ''
            Weight       = ''
        }
    }
    catch {
        Write-Warning "Failed to get system stats for dashboard: $_"
    }

    # VS + RS data
    try {
        $vsResp = Invoke-LoadMasterAPI @apiSplat -Command 'listvs'
        if ($vsResp.VS) {
            foreach ($vs in @($vsResp.VS)) {
                $vsIndex = "$($vs.Index)"
                $vsNick = if ($vs.NickName) { "$($vs.NickName)" } else { '' }
                $vsAddr = if ($vs.VSAddress) { "$($vs.VSAddress)" } else { '' }
                $vsPort = if ($vs.VSPort) { "$($vs.VSPort)" } else { '' }
                $vsLabel = if ($vsNick) { $vsNick } else { "${vsAddr}:${vsPort}" }
                $vsStatus = if ($vs.Status) { "$($vs.Status)" } else { 'Unknown' }

                $rows += [PSCustomObject]@{
                    Type         = 'Virtual Service'
                    Name         = $vsLabel
                    Address      = $vsAddr
                    Port         = $vsPort
                    Status       = $vsStatus
                    Version      = ''
                    CPU          = ''
                    Memory       = ''
                    ActiveConns  = if ($null -ne $vs.ActiveConns) { "$($vs.ActiveConns)" } else { 'N/A' }
                    TotalConns   = if ($null -ne $vs.TotalConns) { "$($vs.TotalConns)" } else { 'N/A' }
                    TPS          = if ($null -ne $vs.ConnsPerSec) { "$($vs.ConnsPerSec)" } else { 'N/A' }
                    SSL_TPS      = ''
                    BytesPerSec  = ''
                    ParentVS     = ''
                    Weight       = ''
                }

                # Get RS for this VS
                try {
                    $vsDetail = Invoke-LoadMasterAPI @apiSplat -Command 'showvs' -Params @{ vs = $vsIndex }
                    if ($vsDetail.Rs) {
                        foreach ($rs in @($vsDetail.Rs)) {
                            $rsAddr = if ($rs.Addr) { "$($rs.Addr)" } else { '' }
                            $rsPort = if ($rs.Port) { "$($rs.Port)" } else { '' }
                            $rsStatus = if ($rs.Status) { "$($rs.Status)" } else { 'Unknown' }
                            $rsWeight = if ($null -ne $rs.Weight) { "$($rs.Weight)" } else { '' }

                            $rows += [PSCustomObject]@{
                                Type         = 'Real Server'
                                Name         = "${rsAddr}:${rsPort}"
                                Address      = $rsAddr
                                Port         = $rsPort
                                Status       = $rsStatus
                                Version      = ''
                                CPU          = ''
                                Memory       = ''
                                ActiveConns  = if ($null -ne $rs.ActiveConns) { "$($rs.ActiveConns)" } else { 'N/A' }
                                TotalConns   = if ($null -ne $rs.Conns) { "$($rs.Conns)" } else { 'N/A' }
                                TPS          = ''
                                SSL_TPS      = ''
                                BytesPerSec  = ''
                                ParentVS     = $vsLabel
                                Weight       = $rsWeight
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not get RS for VS ${vsIndex}: $_"
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to get VS data for dashboard: $_"
    }

    # Generate HTML using dynamic dashboard if available
    $dynDashFunc = Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue
    if ($dynDashFunc) {
        Export-DynamicDashboardHtml -Data $rows `
            -ReportTitle $Title `
            -OutputPath $OutputPath `
            -StatusField 'Status'
        Write-Host "  Dashboard saved: $OutputPath" -ForegroundColor Green
    }
    else {
        # Fallback: simple HTML table
        $htmlRows = $rows | ConvertTo-Html -Fragment
        $html = @"
<!DOCTYPE html>
<html><head><title>$Title</title>
<style>body{font-family:Arial,sans-serif;margin:20px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ddd;padding:8px;text-align:left}th{background:#4a90d9;color:#fff}tr:nth-child(even){background:#f2f2f2}</style>
</head><body><h1>$Title</h1><p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
$htmlRows
</body></html>
"@
        $html | Out-File -FilePath $OutputPath -Encoding utf8 -Force
        Write-Host "  Dashboard saved: $OutputPath" -ForegroundColor Green
    }
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBr8anwMzAli2vf
# Mul8DO3yQS/PaMI4ZZSgpkNmJhBefqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCA/N/TMxh5JxaVSm4k/OUoZkLK2CdBLoUf4AojegUCFrjANBgkqhkiG9w0BAQEF
# AASCAgBtnuY78kA/V3D6l9FWMbKJcccRd/GayZt9IGnjH1gwUqUTIKnchF+6V4dB
# +t8JfeLiLBcearV59K82d67bV00fo6bsuA9McTxYjIYNBCH4RTTB2M1KfoK5uU+n
# 9sFnCbSYTOCsYLK0DoTUW3p6yHIUTXWzq/3BTMMvGq4inz/vbmo5mShTGa78R3M1
# 5fJrXySFOWznI5fiwYOnOVJAf4kvrpLq2wyvih7s/wI/pLbodFseIwnA+0iaUIA3
# ZZNf22Rsa2Glb7YK9MW+M8GR2Mj2Fq1IOBL/KCZ92EDjGetKn2KH0YVpORNaNTp3
# m7+YCoJeVu+9CUWiCl/96vKNhGTYvBUScV6xmmIiIUnKhV86Lp709IBXoCKQ4SrV
# 7bAajGdOKv5nuMTQD/+M7bjWKXqTarKma6i6cs/yBw8yLBfWJrnbie67ouCEKY/p
# oraZjrQp+lES2/L1vbHGgAZ7wnaUTWQarH8S2gIiTIoLqv6ZbdUQE4NUoPRsOc6W
# +ClhNvRvTxu8rBjAjDZ2vTQva7+ciDcxru0F6ro4b1PCmOe6bfbEJSUUojph9Buk
# WWvE5yi/K4Z1J3zAnfg7JfAp9srSqrEesneVdqFaScu+l5h/SqJ3RTVtCOnNqS/7
# sXIfV5UJIpAmDED+1kZe1VsHkb962M85uNmnMhAf1t6UPdd986GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MjQxNzQwNTRaMC8GCSqGSIb3DQEJBDEiBCDwBucj
# PzvfZcqadS4xjl290gDDmN8GujDYPG7myDw3ezANBgkqhkiG9w0BAQEFAASCAgAp
# DR0nMB8iII8m6dUeymLasZOQ2DxXz0GxqVqZYxlTjGQJgSCMRQqLEwZnninDivH2
# 7dj/8+VpPjYpoywNennJcnpLZA9eCGvGnW++lW6OuL14vJ87UKF62DTEEBucE5ki
# 5V8/tC2BWte+9SnTDlJCgQz3sd8kWwI1wUF7U1iK2NQp8w9QKU6MRUT/0xvpODHE
# 0CASH35KlsIwvyo4DC1Tr1NN6eQBL/fSPci4kOhfwIs1337ka1+4cr8smR3I/YsN
# XHGsnhVQr2q1UgHynSxXTKsfqZZcE/Vw83E8KEInD/bWVA3onbMqj+IpJIPkzXaY
# OMq+/KMviHB2lqg0L+Q7xkZKWdwYdo3uILEhhjHBGV4xjv3gFcU9h/K3cjtU5Zin
# OZnLnGzdiN2gXjdQkMa9yOb7Y1RC3bwCEUk5Ev4B6pt2oAoI3Xd+nGVAaRgN5cxD
# OOi6i6Hy+opGyVFsd9CrqPH1/Cy/+bmPZfenjavfoH4Qx8zws8gMP1UQJf/RkHyO
# hkjrd46xpzQTReGTNVaGcug3ejdSdPjf3k3tGBrzj0pC8vrl/32P4Xyh46icpPgy
# qiUXs/0m+x30itGslEBSuMprgqdWAENRRKBaCKCZRVjvLIyrb3GE+lT21pVmnC+I
# wErPuQWVuW5Y9J064Ok+wwP6Usydh32TbcCbNvugfw==
# SIG # End signature block
