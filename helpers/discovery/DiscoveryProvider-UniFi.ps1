<#
.SYNOPSIS
    Discovers local UniFi Network sites, adopted devices, clients, and REST monitors.

.DESCRIPTION
    Uses the local UniFi Network Integration API with a read-only API key sent in
    the X-API-KEY header. WUG monitor templates use controller-specific endpoint
    URLs and a static custom header because WUG does not expand credential
    variables in REST custom-header property bags.
#>

function Invoke-UniFiNetworkApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [bool]$IgnoreCertificateErrors = $true
    )

    $headers = @{ 'X-API-KEY' = $ApiKey; Accept = 'application/json' }
    $invokeParams = @{ Uri = $Uri; Method = 'GET'; Headers = $headers; TimeoutSec = 30; ErrorAction = 'Stop' }
    $oldCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

    if ($IgnoreCertificateErrors -and $PSVersionTable.PSVersion.Major -ge 6) {
        $invokeParams['SkipCertificateCheck'] = $true
    }
    elseif ($IgnoreCertificateErrors) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    try {
        return Invoke-RestMethod @invokeParams
    }
    finally {
        if ($PSVersionTable.PSVersion.Major -lt 6 -and $IgnoreCertificateErrors) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback
        }
    }
}

function Get-UniFiNetworkCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [bool]$IgnoreCertificateErrors = $true,
        [int]$PageSize = 200
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    $offset = 0
    do {
        $separator = if ($Url.Contains('?')) { '&' } else { '?' }
        $pageUrl = "${Url}${separator}offset=$offset&limit=$PageSize"
        $page = Invoke-UniFiNetworkApi -Uri $pageUrl -ApiKey $ApiKey -IgnoreCertificateErrors $IgnoreCertificateErrors
        foreach ($row in @($page.data)) { $results.Add($row) }
        $total = if ($null -ne $page.totalCount) { [int]$page.totalCount } else { $results.Count }
        $offset += @($page.data).Count
    } while ($offset -lt $total -and @($page.data).Count -gt 0)

    return $results.ToArray()
}

function New-UniFiHealthComparison {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Expected)

    $comparison = @{
        JsonPathQuery  = "['state']"
        AttributeType  = 1
        ComparisonType = 3
        CompareValue   = $Expected
    }
    return ConvertTo-Json -InputObject @($comparison) -Compress
}

function Get-UniFiObjectValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Name
    )

    foreach ($propertyName in $Name) {
        if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($propertyName)) {
            return $InputObject[$propertyName]
        }
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($property) { return $property.Value }
    }
    return $null
}

function New-UniFiInventoryRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [string]$Site,
        [string]$Name,
        [string]$State,
        [string]$Address,
        [string]$MACAddress,
        [string]$Model,
        [string]$Firmware,
        [string]$Network,
        [string]$VLAN,
        [string]$Category,
        [string]$Enabled,
        [string]$CPU,
        [string]$Memory,
        [string]$UptimeSeconds,
        [string]$RadioRetryPct,
        [string]$Insight,
        [string]$Severity,
        [string]$ObjectId
    )

    [PSCustomObject]@{
        Type          = $Type
        Site          = $Site
        Name          = $Name
        State         = $State
        Address       = $Address
        MACAddress    = $MACAddress
        Model         = $Model
        Firmware      = $Firmware
        Network       = $Network
        VLAN          = $VLAN
        Category      = $Category
        Enabled       = $Enabled
        CPU           = $CPU
        Memory        = $Memory
        UptimeSeconds = $UptimeSeconds
        RadioRetryPct = $RadioRetryPct
        Insight       = $Insight
        Severity      = $Severity
        ObjectId      = $ObjectId
    }
}

function Get-UniFiOptionalCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [string]$Label,
        [bool]$IgnoreCertificateErrors = $true
    )

    try {
        return @(Get-UniFiNetworkCollection -Url $Url -ApiKey $ApiKey -IgnoreCertificateErrors $IgnoreCertificateErrors)
    }
    catch {
        Write-Verbose "Optional UniFi inventory '$Label' is unavailable at '$Url': $($_.Exception.Message)"
        return @()
    }
}

if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $helpersPath = Join-Path $PSScriptRoot 'DiscoveryHelpers.ps1'
    if (-not (Test-Path $helpersPath)) { throw 'DiscoveryHelpers.ps1 is required.' }
    . $helpersPath
}

Register-DiscoveryProvider -Name 'UniFi' `
    -MatchAttribute 'DiscoveryHelper.UniFi' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $apiKey = if ($ctx.Credential -and $ctx.Credential.ApiToken) { [string]$ctx.Credential.ApiToken } else { [string]$ctx.AttributeValue }
        if (-not $apiKey) { throw 'A local UniFi Network API key is required.' }

        $apiPrefix = '/proxy/network/integration'
        if ($ctx.Options -and $ctx.Options.ApiPathPrefix) {
            $apiPrefix = '/' + ([string]$ctx.Options.ApiPathPrefix).Trim('/')
        }
        $apiBase = $ctx.BaseUri.TrimEnd('/') + $apiPrefix.TrimEnd('/') + '/v1'
        $ignoreCert = [bool]$ctx.IgnoreCertErrors

        Write-Host "UniFi: checking API at $apiBase/info ..." -ForegroundColor Cyan
        $info = Invoke-UniFiNetworkApi -Uri "$apiBase/info" -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert
        if (-not $info.applicationVersion) { throw 'UniFi API did not return applicationVersion from /v1/info.' }
        Write-Host "UniFi API is responding (application version $($info.applicationVersion))." -ForegroundColor Green

        Write-Host 'UniFi: retrieving sites and pending-adoption inventory ...' -ForegroundColor Cyan
        $sites = @(Get-UniFiNetworkCollection -Url "$apiBase/sites" -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert)
        if ($sites.Count -eq 0) { throw 'UniFi Network API returned no sites.' }
        Write-Host "UniFi: found $($sites.Count) site(s)." -ForegroundColor Green

        $maxDevicesPerSite = 100
        if ($ctx.Options -and $ctx.Options.MaxDevicesPerSite) {
            $maxDevicesPerSite = [Math]::Max(1, [int]$ctx.Options.MaxDevicesPerSite)
        }

        $header = "X-API-KEY: $apiKey"
        $items = New-Object 'System.Collections.Generic.List[object]'
        $inventoryRows = New-Object 'System.Collections.Generic.List[object]'
        $adoptedDevices = New-Object 'System.Collections.Generic.List[object]'
        $pendingDevices = @()
        $pendingDevicesSupported = $true
        try {
            $pendingDevices = @(Get-UniFiNetworkCollection -Url "$apiBase/pending-devices" -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert)
        }
        catch {
            $pendingDevicesSupported = $false
            Write-Verbose "Pending-adoption inventory is unavailable: $($_.Exception.Message)"
        }
        if ($pendingDevicesSupported) {
            Write-Host "UniFi: found $($pendingDevices.Count) device(s) pending adoption." -ForegroundColor Gray
        }
        else {
            Write-Warning 'UniFi: pending-adoption inventory is unavailable; continuing with adopted devices.'
        }
        foreach ($pending in $pendingDevices) {
            $pendingName = [string](Get-UniFiObjectValue -InputObject $pending -Name @('name', 'model', 'macAddress'))
            $pendingFeatures = @(Get-UniFiObjectValue -InputObject $pending -Name @('features')) -join ', '
            [void]$inventoryRows.Add((New-UniFiInventoryRow `
                -Type 'Pending Device' -Name $pendingName -State 'Pending Adoption' `
                -Address ([string]$pending.ipAddress) -MACAddress ([string]$pending.macAddress) `
                -Model ([string]$pending.model) -Firmware ([string]$pending.firmwareVersion) `
                -Category $pendingFeatures -Insight 'Adoption required' -Severity 'Warning' `
                -ObjectId ([string]$pending.macAddress)))
        }
        $activeBase = @{
            RestApiMethod                  = 'GET'
            RestApiTimeoutMs               = 30000
            RestApiIgnoreCertErrors        = '1'
            RestApiUseAnonymous            = '1'
            RestApiCustomHeader            = $header
            RestApiDownIfResponseCodeIsIn  = '[400,401,403,404,500,502,503]'
            RestApiComparisonList          = '[]'
        }
        $perfBase = @{
            RestApiHttpMethod              = 'GET'
            RestApiHttpTimeoutMs           = 30000
            RestApiIgnoreCertErrors        = '1'
            RestApiUseAnonymousAccess      = '1'
            RestApiCustomHeader            = $header
        }

        [void]$items.Add((New-DiscoveredItem `
            -Name "UniFi - $($ctx.DeviceName) API Health" `
            -ItemType 'ActiveMonitor' -MonitorType 'RestApi' `
            -MonitorParams (@{ RestApiUrl = "$apiBase/info" } + $activeBase) `
            -UniqueKey "UniFi:$($ctx.DeviceIP):active:api" -DeviceId $ctx.DeviceId `
            -Attributes @{ 'UniFi.ApplicationVersion' = [string]$info.applicationVersion } `
            -Tags @('unifi', 'active', 'controller')))

        $siteIndex = 0
        foreach ($site in $sites) {
            $siteIndex++
            $siteId = [string]$site.id
            if (-not $siteId) { continue }
            $siteSegment = [uri]::EscapeDataString($siteId)
            $siteName = if ($site.name) { [string]$site.name } else { $siteId }
            $siteUrl = "$apiBase/sites/$siteSegment"
            $devicesUrl = "$siteUrl/devices"
            $clientsUrl = "$siteUrl/clients"

            Write-Host "UniFi: collecting site $siteIndex/$($sites.Count) '$siteName' ..." -ForegroundColor Cyan
            $devices = @(Get-UniFiNetworkCollection -Url $devicesUrl -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert)
            $clients = @(Get-UniFiOptionalCollection -Url $clientsUrl -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert -Label "$siteName clients")
            $networks = @(Get-UniFiOptionalCollection -Url "$siteUrl/networks" -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert -Label "$siteName networks")
            $wifiBroadcasts = @(Get-UniFiOptionalCollection -Url "$siteUrl/wifi/broadcasts" -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert -Label "$siteName Wi-Fi broadcasts")
            $wans = @(Get-UniFiOptionalCollection -Url "$siteUrl/wans" -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert -Label "$siteName WANs")
            $deviceInventoryById = @{}
            Write-Host "  Site inventory: $($devices.Count) adopted devices, $($clients.Count) clients, $($networks.Count) networks, $($wifiBroadcasts.Count) Wi-Fi broadcasts, $($wans.Count) WANs." -ForegroundColor Gray

            foreach ($client in $clients) {
                $clientName = [string](Get-UniFiObjectValue -InputObject $client -Name @('name', 'hostname', 'id'))
                [void]$inventoryRows.Add((New-UniFiInventoryRow `
                    -Type 'Connected Client' -Site $siteName -Name $clientName -State 'Connected' `
                    -Address ([string]$client.ipAddress) -Category ([string]$client.type) `
                    -Network ([string]$client.access.type) -ObjectId ([string]$client.id)))
            }

            foreach ($network in $networks) {
                $networkName = [string](Get-UniFiObjectValue -InputObject $network -Name @('name', 'id'))
                $networkState = if ($network.enabled -eq $false) { 'Disabled' } else { 'Enabled' }
                $networkInsight = if ($network.default) { 'Default network' } else { '' }
                [void]$inventoryRows.Add((New-UniFiInventoryRow `
                    -Type 'Network' -Site $siteName -Name $networkName -State $networkState `
                    -VLAN ([string]$network.vlanId) -Category ([string]$network.management) `
                    -Enabled ([string]$network.enabled) -Insight $networkInsight `
                    -ObjectId ([string]$network.id)))
            }

            foreach ($broadcast in $wifiBroadcasts) {
                $broadcastName = [string](Get-UniFiObjectValue -InputObject $broadcast -Name @('name', 'id'))
                $broadcastState = if ($broadcast.enabled -eq $false) { 'Disabled' } else { 'Enabled' }
                $broadcastInsight = if ($broadcast.enabled -eq $false) { 'Wi-Fi network disabled' } else { '' }
                [void]$inventoryRows.Add((New-UniFiInventoryRow `
                    -Type 'Wi-Fi Broadcast' -Site $siteName -Name $broadcastName -State $broadcastState `
                    -Network ([string]$broadcast.network.type) -Category ([string]$broadcast.securityConfiguration.type) `
                    -Enabled ([string]$broadcast.enabled) -Insight $broadcastInsight `
                    -Severity $(if ($broadcast.enabled -eq $false) { 'Warning' } else { '' }) `
                    -ObjectId ([string]$broadcast.id)))
            }

            foreach ($wan in $wans) {
                [void]$inventoryRows.Add((New-UniFiInventoryRow `
                    -Type 'WAN' -Site $siteName -Name ([string](Get-UniFiObjectValue -InputObject $wan -Name @('name', 'id'))) `
                    -State 'Configured' -ObjectId ([string]$wan.id)))
            }

            $siteCollections = @(
                @{ Type = 'Device Tag'; Path = 'device-tags' }
                @{ Type = 'Firewall Policy'; Path = 'firewall/policies' }
                @{ Type = 'Firewall Zone'; Path = 'firewall/zones' }
                @{ Type = 'ACL Rule'; Path = 'acl-rules' }
                @{ Type = 'DNS Policy'; Path = 'dns/policies' }
                @{ Type = 'Traffic Matching List'; Path = 'traffic-matching-lists' }
                @{ Type = 'VPN Server'; Path = 'vpn/servers' }
                @{ Type = 'Site-to-Site VPN'; Path = 'vpn/site-to-site-tunnels' }
                @{ Type = 'Switch LAG'; Path = 'switching/lags' }
                @{ Type = 'MC-LAG Domain'; Path = 'switching/mc-lag-domains' }
                @{ Type = 'Switch Stack'; Path = 'switching/switch-stacks' }
            )
            foreach ($collection in $siteCollections) {
                $resources = @(Get-UniFiOptionalCollection -Url "$siteUrl/$($collection.Path)" -ApiKey $apiKey `
                    -IgnoreCertificateErrors $ignoreCert -Label "$siteName $($collection.Type)")
                foreach ($resource in $resources) {
                    $resourceName = [string](Get-UniFiObjectValue -InputObject $resource -Name @('name', 'displayName', 'id'))
                    $resourceId = [string](Get-UniFiObjectValue -InputObject $resource -Name @('id', 'uuid', 'name'))
                    $resourceEnabled = Get-UniFiObjectValue -InputObject $resource -Name @('enabled')
                    $resourceState = [string](Get-UniFiObjectValue -InputObject $resource -Name @('state', 'status'))
                    if (-not $resourceState -and $null -ne $resourceEnabled) {
                        $resourceState = if ($resourceEnabled) { 'Enabled' } else { 'Disabled' }
                    }
                    [void]$inventoryRows.Add((New-UniFiInventoryRow `
                        -Type $collection.Type -Site $siteName -Name $resourceName -State $resourceState `
                        -Enabled ([string]$resourceEnabled) -ObjectId $resourceId))
                }
            }

            $onlineDevices = @($devices | Where-Object { $_.state -eq 'ONLINE' }).Count
            $offlineDevices = $devices.Count - $onlineDevices
            $siteInsight = @()
            if ($offlineDevices -gt 0) { $siteInsight += "$offlineDevices adopted device(s) offline" }
            $siteSeverity = if ($offlineDevices -gt 0) { 'Critical' } else { 'Normal' }
            [void]$inventoryRows.Add((New-UniFiInventoryRow `
                -Type 'Site Summary' -Site $siteName -Name $siteName -State 'Inventory Complete' `
                -Category "$($devices.Count) devices; $($clients.Count) clients; $($networks.Count) networks; $($wifiBroadcasts.Count) Wi-Fi; $($wans.Count) WANs" `
                -Insight ($siteInsight -join '; ') -Severity $siteSeverity -ObjectId $siteId))

            [void]$items.Add((New-DiscoveredItem `
                -Name "UniFi - $($ctx.DeviceName) - $siteName Connected Clients" `
                -ItemType 'PerformanceMonitor' -MonitorType 'RestApi' `
                -MonitorParams (@{ RestApiUrl = "$clientsUrl?offset=0&limit=1"; RestApiJsonPath = '$.totalCount' } + $perfBase) `
                -UniqueKey "UniFi:$($ctx.DeviceIP):site:$siteId:clients" -DeviceId $ctx.DeviceId `
                -Tags @('unifi', 'performance', 'clients')))

            [void]$items.Add((New-DiscoveredItem `
                -Name "UniFi - $($ctx.DeviceName) - $siteName Adopted Devices" `
                -ItemType 'PerformanceMonitor' -MonitorType 'RestApi' `
                -MonitorParams (@{ RestApiUrl = "$devicesUrl`?offset=0&limit=1"; RestApiJsonPath = '$.totalCount' } + $perfBase) `
                -UniqueKey "UniFi:$($ctx.DeviceIP):site:$siteId:devicecount" -DeviceId $ctx.DeviceId `
                -Tags @('unifi', 'performance', 'devices')))

            foreach ($device in $devices) {
                $deviceId = [string]$device.id
                if (-not $deviceId) { continue }
                $deviceName = if ($device.name) { [string]$device.name } else { [string]$device.macAddress }
                if (-not $deviceName) { $deviceName = $deviceId }
                $featureObject = Get-UniFiObjectValue -InputObject $device -Name @('features')
                $featureNames = @()
                if ($featureObject -is [string]) { $featureNames = @($featureObject) }
                elseif ($featureObject -is [System.Collections.IEnumerable]) { $featureNames = @($featureObject | ForEach-Object { [string]$_ }) }
                elseif ($featureObject) { $featureNames = @($featureObject.PSObject.Properties.Name) }
                $deviceType = if ($featureNames -contains 'accessPoint') { 'Access Point' }
                    elseif ($featureNames -contains 'switching') { 'Switch' }
                    elseif ([string]$device.model -match '(?i)UDM|UXG|USG') { 'Gateway' }
                    else { 'UniFi Device' }

                $deviceInsights = @()
                if ($device.state -and $device.state -ne 'ONLINE') { $deviceInsights += "Device state: $($device.state)" }
                if ($device.firmwareUpdatable) { $deviceInsights += 'Firmware update available' }
                $deviceSeverity = if ($device.state -and $device.state -ne 'ONLINE') { 'Critical' }
                    elseif ($device.firmwareUpdatable) { 'Warning' }
                    else { 'Normal' }
                $deviceRow = New-UniFiInventoryRow `
                    -Type 'Adopted Device' -Site $siteName -Name $deviceName -State ([string]$device.state) `
                    -Address ([string]$device.ipAddress) -MACAddress ([string]$device.macAddress) `
                    -Model ([string]$device.model) -Firmware ([string]$device.firmwareVersion) `
                    -Category $deviceType -Insight ($deviceInsights -join '; ') -Severity $deviceSeverity `
                    -ObjectId $deviceId
                [void]$inventoryRows.Add($deviceRow)

                $deviceAttributes = [ordered]@{
                    'UniFi.Site' = $siteName
                    'UniFi.SiteId' = $siteId
                    'UniFi.AdoptedDeviceId' = $deviceId
                    'UniFi.DeviceType' = $deviceType
                    'UniFi.MACAddress' = [string]$device.macAddress
                    'UniFi.Model' = [string]$device.model
                    'UniFi.FirmwareVersion' = [string]$device.firmwareVersion
                    'UniFi.FirmwareUpdateAvailable' = [string][bool]$device.firmwareUpdatable
                    'UniFi.State' = [string]$device.state
                    'UniFi.IPAddress' = [string]$device.ipAddress
                }
                $inventoryDevice = [PSCustomObject]@{
                    ApiDeviceId = $deviceId
                    SiteId = $siteId
                    SiteName = $siteName
                    Name = $deviceName
                    DisplayName = "UniFi - $siteName - $deviceName"
                    Address = [string]$device.ipAddress
                    MACAddress = [string]$device.macAddress
                    Model = [string]$device.model
                    DeviceType = $deviceType
                    State = [string]$device.state
                    Row = $deviceRow
                    Attributes = $deviceAttributes
                }
                $deviceInventoryById[$deviceId] = $inventoryDevice
                [void]$adoptedDevices.Add($inventoryDevice)
            }

            $devicesForMonitors = @($devices)
            if ($devicesForMonitors.Count -gt $maxDevicesPerSite) {
                Write-Warning "Site '$siteName' has $($devices.Count) devices; limiting per-device monitors to $maxDevicesPerSite."
                $devicesForMonitors = @($devicesForMonitors | Select-Object -First $maxDevicesPerSite)
            }

            foreach ($device in $devicesForMonitors) {
                $deviceId = [string]$device.id
                if (-not $deviceId) { continue }
                $deviceSegment = [uri]::EscapeDataString($deviceId)
                $deviceName = if ($device.name) { [string]$device.name } else { [string]$device.macAddress }
                if (-not $deviceName) { $deviceName = $deviceId }
                $deviceUrl = "$siteUrl/devices/$deviceSegment"
                $statsUrl = "$deviceUrl/statistics/latest"
                $safeName = "$($ctx.DeviceName) - $siteName - $deviceName"

                Write-Verbose "UniFi: reading detail and statistics for '$siteName / $deviceName'."
                $deviceDetails = $device
                try {
                    $deviceDetails = Invoke-UniFiNetworkApi -Uri $deviceUrl -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert
                }
                catch {
                    Write-Verbose "Could not read details for UniFi device '$deviceName': $($_.Exception.Message)"
                }
                $stats = $null
                try {
                    $stats = Invoke-UniFiNetworkApi -Uri $statsUrl -ApiKey $apiKey -IgnoreCertificateErrors $ignoreCert
                }
                catch {
                    Write-Verbose "Could not read latest statistics for UniFi device '$deviceName': $($_.Exception.Message)"
                }

                $inventoryDevice = $deviceInventoryById[$deviceId]
                $inventoryDevice.Row.Category = "$($inventoryDevice.DeviceType)"
                if ($stats) {
                    if ($null -ne $stats.cpuUtilizationPct) { $inventoryDevice.Row.CPU = [string]$stats.cpuUtilizationPct }
                    if ($null -ne $stats.memoryUtilizationPct) { $inventoryDevice.Row.Memory = [string]$stats.memoryUtilizationPct }
                    if ($null -ne $stats.uptimeSec) { $inventoryDevice.Row.UptimeSeconds = [string]$stats.uptimeSec }
                    if ($stats.lastHeartbeatAt) { $inventoryDevice.Attributes['UniFi.LastHeartbeatAt'] = [string]$stats.lastHeartbeatAt }
                    if ($null -ne $stats.cpuUtilizationPct) { $inventoryDevice.Attributes['UniFi.CPUUtilizationPct'] = [string]$stats.cpuUtilizationPct }
                    if ($null -ne $stats.memoryUtilizationPct) { $inventoryDevice.Attributes['UniFi.MemoryUtilizationPct'] = [string]$stats.memoryUtilizationPct }
                    if ($null -ne $stats.uptimeSec) { $inventoryDevice.Attributes['UniFi.UptimeSeconds'] = [string]$stats.uptimeSec }

                    $radioStats = @($stats.interfaces.radios)
                    $retryValues = @($radioStats | Where-Object { $null -ne $_.txRetriesPct } | ForEach-Object { [double]$_.txRetriesPct })
                    if ($retryValues.Count -gt 0) {
                        $retryAverage = [Math]::Round(($retryValues | Measure-Object -Average).Average, 1)
                        $inventoryDevice.Row.RadioRetryPct = [string]$retryAverage
                        $inventoryDevice.Attributes['UniFi.RadioTxRetriesPct'] = [string]$retryAverage
                    }

                    $insights = @()
                    if ($inventoryDevice.Row.Insight) { $insights += $inventoryDevice.Row.Insight }
                    if ($stats.cpuUtilizationPct -ge 85) { $insights += "High CPU ($($stats.cpuUtilizationPct)%)" }
                    if ($stats.memoryUtilizationPct -ge 85) { $insights += "High memory ($($stats.memoryUtilizationPct)%)" }
                    if ($retryValues.Count -gt 0 -and $retryAverage -ge 25) { $insights += "High radio retries ($retryAverage%)" }
                    $inventoryDevice.Row.Insight = $insights -join '; '
                    if ($stats.cpuUtilizationPct -ge 95 -or $stats.memoryUtilizationPct -ge 95) {
                        $inventoryDevice.Row.Severity = 'Critical'
                    }
                    elseif (($stats.cpuUtilizationPct -ge 85) -or ($stats.memoryUtilizationPct -ge 85) -or ($retryValues.Count -gt 0 -and $retryAverage -ge 25)) {
                        if ($inventoryDevice.Row.Severity -ne 'Critical') { $inventoryDevice.Row.Severity = 'Warning' }
                    }
                }
                $portCount = @($deviceDetails.interfaces.ports).Count
                $radioCount = @($deviceDetails.interfaces.radios).Count
                if ($radioCount -eq 0 -and $stats) { $radioCount = @($stats.interfaces.radios).Count }
                $inventoryDevice.Attributes['UniFi.PortCount'] = [string]$portCount
                $inventoryDevice.Attributes['UniFi.RadioCount'] = [string]$radioCount
                $inventoryDevice.Row.Category = "$($inventoryDevice.DeviceType); $portCount ports; $radioCount radios"
                if ($deviceDetails.adoptedAt) { $inventoryDevice.Attributes['UniFi.AdoptedAt'] = [string]$deviceDetails.adoptedAt }
                if ($deviceDetails.provisionedAt) { $inventoryDevice.Attributes['UniFi.ProvisionedAt'] = [string]$deviceDetails.provisionedAt }
                if ($deviceDetails.uplink.deviceId) { $inventoryDevice.Attributes['UniFi.UplinkDeviceId'] = [string]$deviceDetails.uplink.deviceId }

                $deviceActive = $activeBase.Clone()
                $deviceActive['RestApiUrl'] = $deviceUrl
                $deviceActive['RestApiComparisonList'] = New-UniFiHealthComparison -Expected 'ONLINE'
                [void]$items.Add((New-DiscoveredItem `
                    -Name "UniFi - $safeName Online" `
                    -ItemType 'ActiveMonitor' -MonitorType 'RestApi' `
                    -MonitorParams $deviceActive `
                    -UniqueKey "UniFi:$($ctx.DeviceIP):site:$siteId:device:$deviceId:online" -DeviceId $ctx.DeviceId `
                    -Attributes @{ 'UniFi.Site' = $siteName; 'UniFi.SiteId' = $siteId; 'UniFi.AdoptedDeviceId' = $deviceId; 'UniFi.DeviceIP' = [string]$device.ipAddress; 'UniFi.Model' = [string]$device.model } `
                    -Tags @('unifi', 'active', 'device')))

                $deviceMetrics = @(
                    @{ Name = 'CPU'; Path = '$.cpuUtilizationPct'; Tag = 'cpu' }
                    @{ Name = 'Memory'; Path = '$.memoryUtilizationPct'; Tag = 'memory' }
                    @{ Name = 'Uptime'; Path = '$.uptimeSec'; Tag = 'uptime' }
                    @{ Name = 'Uplink RX'; Path = '$.uplink.rxRateBps'; Tag = 'network' }
                    @{ Name = 'Uplink TX'; Path = '$.uplink.txRateBps'; Tag = 'network' }
                )
                if ($radioCount -gt 0) {
                    $deviceMetrics += @{ Name = 'Radio TX Retries'; Path = '$.interfaces.radios[0].txRetriesPct'; Tag = 'wireless' }
                }
                foreach ($metric in $deviceMetrics) {
                    $devicePerf = $perfBase.Clone()
                    $devicePerf['RestApiUrl'] = $statsUrl
                    $devicePerf['RestApiJsonPath'] = $metric.Path
                    [void]$items.Add((New-DiscoveredItem `
                        -Name "UniFi - $safeName $($metric.Name)" `
                        -ItemType 'PerformanceMonitor' -MonitorType 'RestApi' `
                        -MonitorParams $devicePerf `
                        -UniqueKey "UniFi:$($ctx.DeviceIP):site:$siteId:device:${deviceId}:$($metric.Tag)" -DeviceId $ctx.DeviceId `
                        -Attributes @{ 'UniFi.Site' = $siteName; 'UniFi.SiteId' = $siteId; 'UniFi.AdoptedDeviceId' = $deviceId; 'UniFi.Model' = [string]$device.model } `
                        -Tags @('unifi', 'performance', $metric.Tag)))
                }
            }
        }

        if ($pendingDevicesSupported) {
            [void]$items.Add((New-DiscoveredItem `
                -Name "UniFi - $($ctx.DeviceName) Pending Adoption Count" `
                -ItemType 'PerformanceMonitor' -MonitorType 'RestApi' `
                -MonitorParams (@{ RestApiUrl = "$apiBase/pending-devices?offset=0&limit=1"; RestApiJsonPath = '$.totalCount' } + $perfBase) `
                -UniqueKey "UniFi:$($ctx.DeviceIP):pending-devices" -DeviceId $ctx.DeviceId `
                -Tags @('unifi', 'performance', 'adoption')))
        }

        $onlineDeviceCount = @($adoptedDevices | Where-Object { $_.State -eq 'ONLINE' }).Count
        $offlineDeviceCount = $adoptedDevices.Count - $onlineDeviceCount
        $firmwareUpdateCount = @($adoptedDevices | Where-Object { $_.Attributes['UniFi.FirmwareUpdateAvailable'] -eq 'True' }).Count
        $inventoryCounts = @{}
        foreach ($row in $inventoryRows) {
            if (-not $inventoryCounts.ContainsKey($row.Type)) { $inventoryCounts[$row.Type] = 0 }
            $inventoryCounts[$row.Type]++
        }
        foreach ($inventoryType in @('Connected Client', 'Network', 'Wi-Fi Broadcast', 'WAN', 'Firewall Policy', 'Firewall Zone', 'ACL Rule', 'DNS Policy', 'VPN Server', 'Site-to-Site VPN', 'Switch LAG', 'MC-LAG Domain', 'Switch Stack')) {
            if (-not $inventoryCounts.ContainsKey($inventoryType)) { $inventoryCounts[$inventoryType] = 0 }
        }
        $clientTypeCounts = @($inventoryRows | Where-Object { $_.Type -eq 'Connected Client' } |
            Group-Object -Property Category | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '; '
        $summaryInsights = @()
        if ($offlineDeviceCount -gt 0) { $summaryInsights += "$offlineDeviceCount adopted device(s) offline" }
        if ($pendingDevices.Count -gt 0) { $summaryInsights += "$($pendingDevices.Count) device(s) pending adoption" }
        if ($firmwareUpdateCount -gt 0) { $summaryInsights += "$firmwareUpdateCount firmware update(s) available" }
        $summarySeverity = if ($offlineDeviceCount -gt 0) { 'Critical' }
            elseif ($pendingDevices.Count -gt 0 -or $firmwareUpdateCount -gt 0) { 'Warning' }
            else { 'Normal' }
        [void]$inventoryRows.Add((New-UniFiInventoryRow `
            -Type 'Controller Summary' -Name ([string]$ctx.DeviceName) -State 'Inventory Complete' `
            -Category "$($sites.Count) sites; $($adoptedDevices.Count) adopted devices; $($inventoryCounts['Connected Client']) clients" `
            -Insight ($summaryInsights -join '; ') -Severity $summarySeverity -ObjectId ([string]$ctx.DeviceIP)))

        $controllerAttributes = @{
            'UniFi.ApplicationVersion' = [string]$info.applicationVersion
            'UniFi.LastInventoryScan' = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            'UniFi.SiteCount' = [string]$sites.Count
            'UniFi.AdoptedDeviceCount' = [string]$adoptedDevices.Count
            'UniFi.OnlineDeviceCount' = [string]$onlineDeviceCount
            'UniFi.OfflineDeviceCount' = [string]$offlineDeviceCount
            'UniFi.PendingAdoptionCount' = [string]$pendingDevices.Count
            'UniFi.FirmwareUpdateCount' = [string]$firmwareUpdateCount
            'UniFi.ConnectedClientCount' = [string]$inventoryCounts['Connected Client']
            'UniFi.NetworkCount' = [string]$inventoryCounts['Network']
            'UniFi.WiFiBroadcastCount' = [string]$inventoryCounts['Wi-Fi Broadcast']
            'UniFi.WANCount' = [string]$inventoryCounts['WAN']
            'UniFi.ClientTypeCounts' = [string]$clientTypeCounts
        }
        foreach ($attributeType in @('Firewall Policy', 'Firewall Zone', 'ACL Rule', 'DNS Policy', 'VPN Server', 'Site-to-Site VPN', 'Switch LAG', 'MC-LAG Domain', 'Switch Stack')) {
            $attributeName = 'UniFi.' + ($attributeType -replace '[^A-Za-z0-9]', '') + 'Count'
            $controllerAttributes[$attributeName] = [string]$inventoryCounts[$attributeType]
        }
        if ($items.Count -gt 0) {
            $items[0].Attributes = $controllerAttributes
            $items[0] | Add-Member -MemberType NoteProperty -Name 'UniFiInventoryRows' -Value $inventoryRows.ToArray() -Force
            $items[0] | Add-Member -MemberType NoteProperty -Name 'UniFiAdoptedDevices' -Value $adoptedDevices.ToArray() -Force
        }

        Write-Host "UniFi discovery data collected: $($inventoryRows.Count) inventory rows, $($adoptedDevices.Count) adopted devices, $($items.Count) monitor plan items." -ForegroundColor Green
        Write-Host "  Health: $onlineDeviceCount online, $offlineDeviceCount offline, $($pendingDevices.Count) pending adoption, $firmwareUpdateCount firmware update(s) available." -ForegroundColor Gray

        return $items.ToArray()
    }
# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDpI1as0FqMvH+a
# QBwLtsgVwnGWZvtLMl0aG6R6Vyx+zqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCAyW11Mqt/7H6rU8f010PRS9+dyedjOhRknPn9NZrHKHTANBgkqhkiG9w0BAQEF
# AASCAgBZb5WeaeN74GFNyhkUWbR7JfyMK79iLM7eQC8B30gZQCNkLwag4GYOnTwp
# Q32ayBuHxR2EbcyZo3kNolvCZSNeak7+Cfoi11hvOuuc5p/4JLj1padPx49Ho2gr
# 963D/gXg9hdZZ7dXrXltS+FoRp30dE9gmvTtnAqXfPJJ22xjQDhvwGPncqdIYUUy
# ybs/Gsn61Yn+9NDqUAmv3x7URxCXmjVqI2pbO9z9UyhSSZX0rGjzToAL/vGVEcsZ
# aexDe/RnU+DKiw1vxfvn0CslJ5mBpqYHkCYsRbVQyKpyrBYKjw66VNv/M/F90O7+
# v1VK02RGAlLYnRUDGFBlkV7U3R20O8Xy988Skf/4XVxl23KX7P9v8nhazqYHtJpv
# 96REnjdLYxpz3jZOY2aibkJBhAouQwA1zQqO+Cp9WgdLpVRz4m5AkRUoH68jLQ/7
# aTN1PUkBeJ9jPsDc38xAsVyzWyCqSqEzvcnzvF+HpFyzsCnv5Cf7QGZEe3Hq+05r
# kTQbDR3XhtLWAjsVoGUUE8B5SzIDmz4YphAo05wJFVbRZeHJLdi5V3wHPcxT2CyC
# zVFMF59+p8G5+GgC83rSoIVZgHE5e/Sl0its2ERjiTjme4ezWnIUyDbXRf33RF6W
# wX9C68alfYVPfe0v+8UQDAaz2PeBKhptt+hr6kFZWwQPpNPZPKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MzAyMTU0MDFaMC8GCSqGSIb3DQEJBDEiBCBut8p4
# gbs5YY4GMK4xTxN2J0sOuTgMTq3wvUEQughjqjANBgkqhkiG9w0BAQEFAASCAgCN
# /EA/AmaQ3OZStEX++VA+x9fTkh3Wv30LmsEV7NdHLx4bRt84ZeJgl52sAFw42Rrq
# 6IIkxThbZe4fy06dC5GnKXYzVuIaR8/HttHGNcHAFuHUNTn2XzHL71UEU12y/LVG
# 3B4aWJfnZT01wxG6XPVx9rn44fJRmCZtBJVr7bnmC603NqVASlVbyuU4FDTjV2Vx
# QAc6+/n1+ul03x3QOhi4w9chHykBlKwlIP6dd5l2nu/X5ZuGYXH/qFNauPNKYnPF
# 4gp+nT0M/zn/GKy0nimzbMxKr+6PFQGBWAcxWJJGjwK5B/iKmHQCNMQX+Erht7EP
# yQb3YONEMSnskagJAFtigbruurw25xxjyIcJWehMV514cKhARSey5zjxk3wZG/R/
# oDhYE+TvNeBToTI17J303KNZKSMxDJE+YxnxO1g7mNcDpSNdpu9t0etgY+JFNche
# X6wYEQaXe0fXPaA51Ef9EtLm/H11XtzV33aMNYwN59TQHIFLKM3rcZ4BYnDYZe0t
# XjEizDziTlL33SPOuTMzeMZ1cD2piBYw3qfNpB7TGex7K8judlse8Qx2XyHAvrH8
# 6FSRDNzwoMRp8f4RCJrzq87f8RnC+6Vq79uCyM99RxSIEf5OTl70eF4sKRsCNLHC
# NB0K7Oi18xSRbRiWOXEq3YzX/ZWbDBPFgejKMuo3jg==
# SIG # End signature block
