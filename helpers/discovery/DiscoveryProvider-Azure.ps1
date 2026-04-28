<#
.SYNOPSIS
    Azure discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers an Azure discovery provider that discovers subscriptions,
    resource groups, and resources, then builds a monitor plan suitable
    for WhatsUp Gold or standalone use.

    Uses the Azure REST API directly -- zero external module dependencies.

    Discovery discovers:
      - Azure subscriptions and resource groups
      - Resources (VMs, SQL, App Services, etc.) with provisioning state
      - Resource IPs (public/private for VMs, DNS for services)

    Authentication:
      Service Principal (TenantId + ApplicationId + ClientSecret).
      Stored in DPAPI vault as encrypted bundle.

    Prerequisites:
      1. Service principal with Reader role on target subscriptions
      2. Azure AD app registration with client secret

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 and AzureHelpers.ps1 loaded first
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

# Ensure AzureHelpers is available
$azureHelpersPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..\azure\AzureHelpers.ps1'
if (Test-Path $azureHelpersPath) {
    . $azureHelpersPath
}

# ============================================================================
# Azure Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Azure' `
    -MatchAttribute 'DiscoveryHelper.Azure' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()

        # --- Resolve credential ---
        $tenantId = $null
        $appId    = $null
        $secret   = $null

        if ($ctx.Credential) {
            if ($ctx.Credential.TenantId) {
                $tenantId = $ctx.Credential.TenantId
                $appId    = $ctx.Credential.ApplicationId
                $secret   = $ctx.Credential.ClientSecret
            }
            elseif ($ctx.Credential -is [PSCredential]) {
                # Convention: Username = "TenantId|ApplicationId", Password = ClientSecret
                $parts = $ctx.Credential.UserName -split '\|'
                if ($parts.Count -ge 2) {
                    $tenantId = $parts[0]
                    $appId    = $parts[1]
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ctx.Credential.Password)
                    try { $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                }
            }
        }

        if (-not $tenantId -or -not $appId -or -not $secret) {
            Write-Warning "No valid Azure service principal credential available."
            return $items
        }

        # Determine metrics timespan window (default P1D)
        # Wider windows (P7D) help idle resources that produce sparse data.
        # The interval always matches the timespan so we get 1 aggregated bucket.
        $metricsTimespan = 'P1D'
        if ($ctx.Credential -and $ctx.Credential.MetricsTimespan) {
            $metricsTimespan = $ctx.Credential.MetricsTimespan
        }

        # ================================================================
        # Phase 1: Authenticate and enumerate resources
        # ================================================================
        try {
            Write-Host "  Authenticating to Azure tenant $tenantId..." -ForegroundColor DarkGray
            Connect-AzureServicePrincipalREST -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret | Out-Null
            Write-Host "  Authenticated." -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "Failed to authenticate to Azure: $_"
            return $items
        }

        $resourceMap = @{}  # resourceId -> @{ ... }
        $healthTypeSupport = @{}   # FullType -> $true/$false
        $healthFallbackApi = @{}   # FullType -> API version string for ARM GET
        $healthJsonProp    = @{}   # FullType -> property name found in response (e.g. 'availabilityState','enabled','provisioningState')
        $healthJsonValue   = @{}   # FullType -> actual observed value of the health property (e.g. 'Succeeded','Enabled','Active')
        $providerCache = @{}       # namespace -> provider info (for API version lookup)

        try {
            Write-Host "  Listing subscriptions..." -ForegroundColor DarkGray
            $subscriptions = Get-AzureSubscriptionsREST | Where-Object { $_.State -eq 'Enabled' }
            # If target specified, filter to specific subscriptions
            if ($ctx.DeviceIP -and $ctx.DeviceIP -ne $tenantId) {
                $targetSubs = @($ctx.DeviceIP -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($targetSubs.Count -gt 0 -and $targetSubs[0] -ne $tenantId) {
                    $subscriptions = $subscriptions | Where-Object {
                        $_.SubscriptionId -in $targetSubs -or $_.SubscriptionName -in $targetSubs
                    }
                }
            }
            Write-Host "  Subscriptions: $(@($subscriptions).Count)" -ForegroundColor DarkGray

            foreach ($sub in $subscriptions) {
                Write-Host "    Subscription: $($sub.SubscriptionName)" -ForegroundColor DarkGray

                # --- Pre-fetch all resources + network data at subscription level ---
                # Reduces hundreds of API calls to ~4 per subscription.
                $subResourceCache = $null
                $netDataCache = $null
                try {
                    $subResourceCache = @(Get-AzureSubscriptionResourcesREST -SubscriptionId $sub.SubscriptionId)
                    Write-Host "      Resources: $(@($subResourceCache).Count) (subscription-level query)" -ForegroundColor DarkGray
                    Write-Host "      Pre-fetching network data for IP resolution..." -ForegroundColor DarkGray
                    $netDataCache = Get-AzureNetworkDataREST -SubscriptionId $sub.SubscriptionId
                    Write-Host "      Network: $($netDataCache.VMIPs.Count) VM IPs, $($netDataCache.PIPs.Count) public IPs, $($netDataCache.LBIPs.Count) LB IPs" -ForegroundColor DarkGray
                }
                catch {
                    Write-Warning "Subscription-level pre-fetch failed, falling back to per-RG: $_"
                    $subResourceCache = $null
                }

                if ($subResourceCache) {
                    # Derive RG list from pre-fetched resources (no additional API call)
                    $rgNames = @($subResourceCache | ForEach-Object {
                        if ($_.ResourceId -match '/resourceGroups/([^/]+)/') { $Matches[1] }
                    } | Select-Object -Unique)
                    $rgs = $rgNames | ForEach-Object { [PSCustomObject]@{ ResourceGroupName = $_ } }
                }
                else {
                    try {
                        $rgs = Get-AzureResourceGroupsREST -SubscriptionId $sub.SubscriptionId
                    }
                    catch {
                        Write-Warning "Failed to list RGs for $($sub.SubscriptionName): $_"
                        continue
                    }
                }
                Write-Host "      Resource groups: $(@($rgs).Count)" -ForegroundColor DarkGray

                foreach ($rg in $rgs) {
                    if ($subResourceCache) {
                        # Filter from pre-fetched subscription-level data (no API call)
                        $rgPattern = "/resourceGroups/$([regex]::Escape($rg.ResourceGroupName))/"
                        $resources = @($subResourceCache | Where-Object { $_.ResourceId -match $rgPattern })
                    }
                    else {
                        try {
                            $resources = Get-AzureResourcesREST -SubscriptionId $sub.SubscriptionId -ResourceGroupName $rg.ResourceGroupName
                        }
                        catch {
                            Write-Warning "Failed to list resources in $($rg.ResourceGroupName): $_"
                            continue
                        }
                    }
                    if (@($resources).Count -gt 0) {
                        Write-Host "      $($rg.ResourceGroupName): $(@($resources).Count) resources" -ForegroundColor DarkGray
                    }

                    foreach ($r in $resources) {
                        $ip = $null
                        if ($netDataCache) {
                            # Fast IP resolution from pre-fetched network data (no API calls)
                            switch -Wildcard ($r.ResourceType) {
                                'Microsoft.Compute/virtualMachines' {
                                    if ($netDataCache.VMIPs.ContainsKey($r.ResourceId)) { $ip = $netDataCache.VMIPs[$r.ResourceId] }
                                }
                                'Microsoft.Network/publicIPAddresses' {
                                    if ($netDataCache.PIPs.ContainsKey($r.ResourceId)) { $ip = $netDataCache.PIPs[$r.ResourceId] }
                                }
                                'Microsoft.Network/loadBalancers' {
                                    if ($netDataCache.LBIPs.ContainsKey($r.ResourceId)) { $ip = $netDataCache.LBIPs[$r.ResourceId] }
                                }
                                'Microsoft.Sql/servers' {
                                    try {
                                        $fqdn = "$($r.ResourceName).database.windows.net"
                                        $resolved = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -First 1
                                        if ($resolved) { $ip = $resolved.IPAddressToString }
                                    } catch { }
                                }
                                'Microsoft.Web/sites' {
                                    try {
                                        $fqdn = "$($r.ResourceName).azurewebsites.net"
                                        $resolved = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -First 1
                                        if ($resolved) { $ip = $resolved.IPAddressToString }
                                    } catch { }
                                }
                                default {
                                    try {
                                        $resolved = [System.Net.Dns]::GetHostAddresses($r.ResourceName) | Select-Object -First 1
                                        if ($resolved) { $ip = $resolved.IPAddressToString }
                                    } catch { }
                                }
                            }
                        }
                        else {
                            try {
                                $ip = Resolve-AzureResourceIPREST -Resource $r -SubscriptionId $sub.SubscriptionId
                            }
                            catch { }
                        }

                        $resourceMap[$r.ResourceId] = @{
                            Name           = $r.ResourceName
                            ResourceId     = $r.ResourceId
                            Type           = ($r.ResourceType -split '/')[-1]
                            FullType       = $r.ResourceType
                            State          = $r.ProvisioningState
                            HealthProperty = $null
                            IP             = $ip
                            Location       = $r.Location
                            Subscription   = $sub.SubscriptionName
                            SubId          = $sub.SubscriptionId
                            RG             = $rg.ResourceGroupName
                            Kind           = $r.Kind
                            Sku            = $r.Sku
                            Tags           = if ($r.Tags) { $r.Tags } else { '' }
                        }

                        # Check Resource Health support for this type (once per type)
                        if (-not $healthTypeSupport.ContainsKey($r.ResourceType)) {
                            $healthTestUrl = "https://management.azure.com$($r.ResourceId)/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"
                            try {
                                $healthResp = Invoke-AzureREST -Uri $healthTestUrl
                                $healthTypeSupport[$r.ResourceType] = $true

                                # Probe the response to find which property actually exists
                                if ($healthResp -and $healthResp.properties) {
                                    $props = $healthResp.properties
                                    if ($null -ne $props.availabilityState) {
                                        $healthJsonProp[$r.ResourceType] = 'availabilityState'
                                        $healthJsonValue[$r.ResourceType] = "$($props.availabilityState)"
                                    } elseif ($null -ne $props.enabled) {
                                        $healthJsonProp[$r.ResourceType] = 'enabled'
                                        $healthJsonValue[$r.ResourceType] = "$($props.enabled)"
                                    } elseif ($null -ne $props.state) {
                                        $healthJsonProp[$r.ResourceType] = 'state'
                                        $healthJsonValue[$r.ResourceType] = "$($props.state)"
                                    } elseif ($null -ne $props.provisioningState) {
                                        $healthJsonProp[$r.ResourceType] = 'provisioningState'
                                        $healthJsonValue[$r.ResourceType] = "$($props.provisioningState)"
                                    } elseif ($null -ne $props.dailyMaxActiveDevices) {
                                        $healthJsonProp[$r.ResourceType] = 'dailyMaxActiveDevices'
                                        $healthJsonValue[$r.ResourceType] = "$($props.dailyMaxActiveDevices)"
                                    }
                                    if ($healthJsonProp.ContainsKey($r.ResourceType)) {
                                        Write-Verbose "  Resource Health property for $($r.ResourceType): $($healthJsonProp[$r.ResourceType]) = $($healthJsonValue[$r.ResourceType])"
                                    }
                                }
                            }
                            catch {
                                $errMsg = "$_"
                                if ($errMsg -match 'UnsupportedResourceType|ResourceTypeNotSupported') {
                                    $healthTypeSupport[$r.ResourceType] = $false
                                    Write-Verbose "  Resource Health not supported: $($r.ResourceType)"

                                    # Look up provider's latest stable API version for the ARM fallback URL
                                    $nsParts = $r.ResourceType -split '/'
                                    $ns = $nsParts[0]
                                    $rtName = ($nsParts[1..($nsParts.Count - 1)] -join '/')
                                    if (-not $providerCache.ContainsKey($ns)) {
                                        try {
                                            $providerCache[$ns] = Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/$($sub.SubscriptionId)/providers/${ns}" -ApiVersion '2021-04-01'
                                        }
                                        catch {
                                            Write-Verbose "  Could not query provider $ns for API versions: $_"
                                            $providerCache[$ns] = $null
                                        }
                                    }

                                    $provInfo = $providerCache[$ns]
                                    $apiVer = $null
                                    if ($provInfo) {
                                        $rtInfo = @($provInfo.resourceTypes | Where-Object { $_.resourceType -eq $rtName })
                                        if ($rtInfo.Count -gt 0) {
                                            $apiVersions = @($rtInfo[0].apiVersions)
                                            $stable = @($apiVersions | Where-Object { $_ -notmatch 'preview' })
                                            if ($stable.Count -gt 0)      { $apiVer = $stable[0] }
                                            elseif ($apiVersions.Count -gt 0) { $apiVer = $apiVersions[0] }
                                        }
                                    }
                                    if ($apiVer) {
                                        $healthFallbackApi[$r.ResourceType] = $apiVer
                                        Write-Verbose "  ARM fallback API version for $($r.ResourceType): $apiVer"
                                    }

                                    # Probe the ARM resource directly to find which property exists
                                    $probeApi = if ($apiVer) { $apiVer } else { '2021-04-01' }
                                    try {
                                        $armProbeUrl = "https://management.azure.com$($r.ResourceId)?api-version=$probeApi"
                                        $armResp = Invoke-AzureREST -Uri $armProbeUrl
                                        if ($armResp -and $armResp.properties) {
                                            $armProps = $armResp.properties
                                            # Check in priority order: availabilityState > enabled > state > provisioningState > dailyMaxActiveDevices
                                            if ($null -ne $armProps.availabilityState) {
                                                $healthJsonProp[$r.ResourceType] = 'availabilityState'
                                                $healthJsonValue[$r.ResourceType] = "$($armProps.availabilityState)"
                                            } elseif ($null -ne $armProps.enabled) {
                                                $healthJsonProp[$r.ResourceType] = 'enabled'
                                                $healthJsonValue[$r.ResourceType] = "$($armProps.enabled)"
                                            } elseif ($null -ne $armProps.state) {
                                                $healthJsonProp[$r.ResourceType] = 'state'
                                                $healthJsonValue[$r.ResourceType] = "$($armProps.state)"
                                            } elseif ($null -ne $armProps.provisioningState) {
                                                $healthJsonProp[$r.ResourceType] = 'provisioningState'
                                                $healthJsonValue[$r.ResourceType] = "$($armProps.provisioningState)"
                                            } elseif ($null -ne $armProps.dailyMaxActiveDevices) {
                                                $healthJsonProp[$r.ResourceType] = 'dailyMaxActiveDevices'
                                                $healthJsonValue[$r.ResourceType] = "$($armProps.dailyMaxActiveDevices)"
                                            }
                                            if ($healthJsonProp.ContainsKey($r.ResourceType)) {
                                                Write-Verbose "  ARM fallback property for $($r.ResourceType): $($healthJsonProp[$r.ResourceType]) = $($healthJsonValue[$r.ResourceType])"
                                            } else {
                                                Write-Verbose "  ARM fallback: no known health property found for $($r.ResourceType)"
                                            }
                                        }
                                    }
                                    catch {
                                        Write-Verbose "  ARM probe failed for $($r.ResourceType): $_"
                                    }
                                }
                                else {
                                    # Other error (auth, rate-limit) — assume supported
                                    $healthTypeSupport[$r.ResourceType] = $true
                                    Write-Verbose "  Resource Health check error for $($r.ResourceType) (assuming supported): $errMsg"
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            $errDetail = "$_"
            Write-Warning "Error during Azure enumeration: $errDetail"
            if ($errDetail -match 'underlying connection was closed|unexpected error occurred on a send') {
                Write-Warning "This is typically a TLS/connectivity issue on this server. Try running:"
                Write-Warning "  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12"
                Write-Warning "  Invoke-RestMethod -Uri 'https://management.azure.com/tenants?api-version=2020-01-01' -Headers @{Authorization='Bearer test'}"
                Write-Warning "If that also fails, check: .NET Framework version (4.6.2+ recommended), outbound firewall rules for management.azure.com:443, and proxy settings."
            }
        }

        Write-Host "  Total resources: $($resourceMap.Count)" -ForegroundColor DarkGray
        $unsupCount = @($healthTypeSupport.Keys | Where-Object { -not $healthTypeSupport[$_] }).Count
        $supCount = $healthTypeSupport.Count - $unsupCount
        if ($unsupCount -gt 0) {
            Write-Host "  Resource Health: $supCount/$($healthTypeSupport.Count) types supported ($unsupCount will use ARM fallback)" -ForegroundColor DarkGray
        }

        # Back-fill each resource's State with the probed health value.
        # The listing API often returns no properties block, so State is 'N/A'.
        # Health probing discovers the actual value per resource type.
        # Skip numeric-only values (e.g. dailyMaxActiveDevices=0) -- they aren't
        # meaningful health statuses for the dashboard.
        foreach ($resId in @($resourceMap.Keys)) {
            $res = $resourceMap[$resId]
            if ($healthJsonProp.ContainsKey($res.FullType)) {
                $res.HealthProperty = $healthJsonProp[$res.FullType]
            }
            if ((-not $res.State -or $res.State -eq 'N/A') -and $healthJsonValue.ContainsKey($res.FullType)) {
                $probed = $healthJsonValue[$res.FullType]
                # Only use string-based status values; skip pure numerics
                if ($probed -match '^\d+(\.\d+)?$') {
                    # Numeric property (e.g. dailyMaxActiveDevices) -- not a health status
                    Write-Verbose "  Skipping numeric health value for $($res.Name): $($res.HealthProperty) = $probed"
                }
                else {
                    $res.State = $probed
                }
            }
        }

        # ================================================================
        # Phase 2: Enumerate metrics per resource (optional)
        # ================================================================
        $enumMetrics = $true
        if ($ctx.Options -and $ctx.Options.ContainsKey('EnumMetrics')) {
            $enumMetrics = [bool]$ctx.Options.EnumMetrics
        }

        $metricsMap = @{}  # resourceId -> @( @{Name;Display;Unit;Agg;Type} )
        if ($enumMetrics) {
            Write-Host "  Enumerating metric definitions..." -ForegroundColor DarkGray
            $resIds = @($resourceMap.Keys | Sort-Object)
            $resCount = 0
            foreach ($resId in $resIds) {
                $resCount++
                $res = $resourceMap[$resId]
                Write-Progress -Activity 'Azure Metric Enumeration' `
                    -Status "$resCount / $($resIds.Count) - $($res.Name)" `
                    -PercentComplete ([Math]::Round(($resCount / $resIds.Count) * 100))
                try {
                    $defs = @()
                    $defUri = "https://management.azure.com${resId}/providers/Microsoft.Insights/metricDefinitions"
                    $defs = @(Invoke-AzureREST -Uri $defUri -ApiVersion '2024-02-01')

                    $mList = @()
                    foreach ($def in $defs) {
                        $mName = $def.name.value
                        $mDisplay = $def.name.localizedValue
                        $mUnit = "$($def.unit)"
                        $mAgg = if ($def.primaryAggregationType) { "$($def.primaryAggregationType)" } else { 'Average' }

                        # Determine if this metric is numeric (performance) or string-based (active)
                        $isNumeric = $mUnit -notin @('', 'Unspecified') -or $mAgg -in @('Average', 'Total', 'Count', 'Maximum', 'Minimum')

                        $mList += @{
                            Name        = $mName
                            DisplayName = $mDisplay
                            Unit        = $mUnit
                            Aggregation = $mAgg
                            IsNumeric   = $isNumeric
                        }
                    }
                    if ($mList.Count -gt 0) {
                        $metricsMap[$resId] = $mList
                    }
                }
                catch {
                    Write-Verbose "No metrics for $($res.Name) ($($res.FullType)): $_"
                }
            }
            Write-Progress -Activity 'Azure Metric Enumeration' -Completed
            $totalMetrics = ($metricsMap.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
            Write-Host "  Metric definitions: $totalMetrics across $($metricsMap.Count) resources" -ForegroundColor DarkGray
        }

        # ================================================================
        # Phase 2.5: Validate metrics return real data
        # ================================================================
        # Azure metric definitions include ALL possible metrics for a
        # resource type, but many never populate data. Query the actual
        # metrics API with a recent timespan and drop any that return
        # empty timeseries or all-null data points.
        if ($metricsMap.Count -gt 0) {
            Write-Host "  Validating metrics have real data (querying last 24h)..." -ForegroundColor DarkGray
            $validatedTotal = 0
            $droppedTotal   = 0
            $resIdx   = 0
            $resTotal = $metricsMap.Count

            foreach ($resId in @($metricsMap.Keys)) {
                $resIdx++
                $res = $resourceMap[$resId]
                $resMets = $metricsMap[$resId]
                Write-Progress -Activity 'Validating Azure Metrics' `
                    -Status "$resIdx / $resTotal - $($res.Name)" `
                    -PercentComplete ([Math]::Round(($resIdx / $resTotal) * 100))

                $validMets = [System.Collections.Generic.List[object]]::new()

                # Batch into groups of 20 (Azure API limit per request)
                for ($batchStart = 0; $batchStart -lt $resMets.Count; $batchStart += 20) {
                    $batchEnd = [Math]::Min($batchStart + 19, $resMets.Count - 1)
                    $batch = @($resMets[$batchStart..$batchEnd])
                    $batchNames = @($batch | ForEach-Object { $_.Name }) -join ','

                    try {
                        $namesWithData = @{}
                        # Build lookup of declared aggregation per metric name
                        $declaredAgg = @{}
                        foreach ($bm in $batch) {
                            $aggField = switch ($bm.Aggregation) {
                                'Average' { 'average' }
                                'Total'   { 'total' }
                                'Count'   { 'count' }
                                'Maximum' { 'maximum' }
                                'Minimum' { 'minimum' }
                                default   { 'average' }
                            }
                            $declaredAgg[$bm.Name] = $aggField
                        }

                        # Single batched call for up to 20 metrics
                        $valUrl = "https://management.azure.com${resId}/providers/Microsoft.Insights/metrics" +
                            "?api-version=2024-02-01" +
                            "&metricnames=$([uri]::EscapeDataString($batchNames))" +
                            "&timespan=P1D&interval=PT1H" +
                            "&aggregation=Average,Total,Count,Maximum,Minimum"
                        $metricResults = @(Invoke-AzureREST -Uri $valUrl)

                        foreach ($mr in $metricResults) {
                            $mrName = $mr.name.value
                            $mrUnit = "$($mr.unit)"
                            if ($mr.timeseries -and @($mr.timeseries).Count -gt 0) {
                                $tsData = @($mr.timeseries)[0].data
                                if ($tsData -and @($tsData).Count -gt 0) {
                                    # Determine field check order: declared aggregation first, then others
                                    $prefField = if ($declaredAgg.ContainsKey($mrName)) { $declaredAgg[$mrName] } else { $null }
                                    $fieldOrder = @('average', 'total', 'maximum', 'minimum', 'count')
                                    if ($prefField) {
                                        $fieldOrder = @($prefField) + @($fieldOrder | Where-Object { $_ -ne $prefField })
                                    }

                                    # Walk backwards to find most recent data point with a numeric value
                                    for ($di = @($tsData).Count - 1; $di -ge 0; $di--) {
                                        $dp = @($tsData)[$di]
                                        $val = $null
                                        $foundField = $null
                                        foreach ($fld in $fieldOrder) {
                                            if ($null -ne $dp.$fld) {
                                                $testVal = $dp.$fld
                                                if ($testVal -is [double] -or $testVal -is [int] -or $testVal -is [long] -or $testVal -is [decimal] -or $testVal -is [float] -or $testVal -is [single]) {
                                                    $val = $testVal
                                                    $foundField = $fld
                                                    break
                                                }
                                            }
                                        }
                                        if ($null -ne $val) {
                                            $namesWithData[$mrName] = @{
                                                Value     = $val
                                                Timestamp = "$($dp.timeStamp)"
                                                Unit      = $mrUnit
                                                DataField = $foundField
                                            }
                                            break
                                        }
                                    }
                                }
                            }
                        }

                        foreach ($bm in $batch) {
                            if ($namesWithData.ContainsKey($bm.Name)) {
                                $valInfo = $namesWithData[$bm.Name]
                                $bm['LastValue']     = $valInfo.Value
                                $bm['LastTimestamp']  = $valInfo.Timestamp
                                if ($valInfo.Unit) { $bm['Unit'] = $valInfo.Unit }
                                if ($valInfo.DataField) { $bm['DataField'] = $valInfo.DataField }
                                $validMets.Add($bm)
                            }
                        }
                    }
                    catch {
                        # API error on entire batch — skip; only confirmed-numeric metrics pass
                        Write-Verbose "Metric validation failed for batch on $($res.Name): $_"
                    }
                }

                $dropped = $resMets.Count - $validMets.Count
                $droppedTotal += $dropped
                if ($validMets.Count -gt 0) {
                    $metricsMap[$resId] = @($validMets)
                    $validatedTotal += $validMets.Count
                }
                else {
                    $metricsMap.Remove($resId)
                }
                if ($dropped -gt 0) {
                    Write-Verbose "  $($res.Name): $($validMets.Count)/$($resMets.Count) metrics have data ($dropped dropped)"
                }
            }

            Write-Progress -Activity 'Validating Azure Metrics' -Completed
            Write-Host "  Validated: $validatedTotal metrics with data, $droppedTotal dropped (no data in 24h)" -ForegroundColor DarkGray
        }

        # ================================================================
        # Phase 2.6: Strict validation — verify WUG poll URL returns data
        # ================================================================
        # WUG polls performance monitors every 10 minutes. Validate using the
        # EXACT URL pattern WUG will use: PT1H timespan, PT1H interval (returns
        # 1 aggregated data point over the last hour). This wider window is more
        # resilient than PT10M for resources with sporadic or low-frequency metrics.
        # The metric must have $.value[0].timeseries[0].data[0].{field} as a numeric
        # value. Query with the SINGLE aggregation type (not all 5) because Azure
        # omits the field when only one is requested and there's no data.
        if ($metricsMap.Count -gt 0) {
            Write-Host "  Live-probing metrics (verifying WUG poll pattern with ${metricsTimespan} window)..." -ForegroundColor DarkGray
            $liveDropped = 0
            $liveKept    = 0
            $resIdx   = 0
            $resTotal = $metricsMap.Count

            foreach ($resId in @($metricsMap.Keys)) {
                $resIdx++
                $res = $resourceMap[$resId]
                $resMets = $metricsMap[$resId]
                Write-Progress -Activity 'Live-probing metrics' `
                    -Status "$resIdx / $resTotal - $($res.Name)" `
                    -PercentComplete ([Math]::Round(($resIdx / $resTotal) * 100))

                $confirmedMets = [System.Collections.Generic.List[object]]::new()
                $resDropped = [System.Collections.Generic.List[string]]::new()

                # Group metrics by their aggregation type so we can batch per-aggregation
                $aggGroups = @{}  # aggType -> list of metrics
                foreach ($bm in $resMets) {
                    $aggType = if ($bm.ContainsKey('DataField') -and $bm.DataField) {
                        switch ($bm.DataField) {
                            'average' { 'Average' }
                            'total'   { 'Total' }
                            'count'   { 'Count' }
                            'maximum' { 'Maximum' }
                            'minimum' { 'Minimum' }
                            default   { 'Average' }
                        }
                    } else { 'Average' }
                    if (-not $aggGroups.ContainsKey($aggType)) {
                        $aggGroups[$aggType] = [System.Collections.Generic.List[object]]::new()
                    }
                    $aggGroups[$aggType].Add($bm)
                }

                foreach ($aggType in $aggGroups.Keys) {
                    $aggMets = $aggGroups[$aggType]

                    # Batch into groups of 20 (Azure API limit)
                    for ($batchStart = 0; $batchStart -lt $aggMets.Count; $batchStart += 20) {
                        $batchEnd = [Math]::Min($batchStart + 19, $aggMets.Count - 1)
                        $batch = @($aggMets[$batchStart..$batchEnd])
                        $batchNames = @($batch | ForEach-Object { $_.Name }) -join ','

                        try {
                            # Query with EXACT WUG poll pattern: configurable window + interval, single aggregation.
                            # Returns 1 aggregated bucket. Wider windows (P7D) catch idle resources.
                            $probeUrl = "https://management.azure.com${resId}/providers/Microsoft.Insights/metrics" +
                                "?api-version=2024-02-01" +
                                "&metricnames=$([uri]::EscapeDataString($batchNames))" +
                                "&timespan=${metricsTimespan}&interval=${metricsTimespan}" +
                                "&aggregation=$aggType"
                            $probeResults = @(Invoke-AzureREST -Uri $probeUrl)

                            $passedProbe = @{}
                            foreach ($mr in $probeResults) {
                                $mrName = $mr.name.value
                                if ($mr.timeseries -and @($mr.timeseries).Count -gt 0) {
                                    $tsData = @($mr.timeseries)[0].data
                                    if ($tsData -and @($tsData).Count -gt 0) {
                                        $matchedMet = $batch | Where-Object { $_.Name -eq $mrName } | Select-Object -First 1
                                        $targetField = if ($matchedMet -and $matchedMet.ContainsKey('DataField')) { $matchedMet.DataField } else { $null }
                                        if ($targetField) {
                                            $dp0 = @($tsData)[0]
                                            # Verify field explicitly exists on the object
                                            $fieldExists = $dp0.PSObject.Properties.Name -contains $targetField
                                            if ($fieldExists) {
                                                $testVal = $dp0.$targetField
                                                if ($null -ne $testVal -and ($testVal -is [double] -or $testVal -is [int] -or $testVal -is [long] -or $testVal -is [decimal] -or $testVal -is [float] -or $testVal -is [single])) {
                                                    $passedProbe[$mrName] = $true
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            foreach ($bm in $batch) {
                                if ($passedProbe.ContainsKey($bm.Name)) {
                                    $confirmedMets.Add($bm)
                                } else {
                                    $resDropped.Add("$($bm.DisplayName) [$aggType -> $($bm.DataField)]")
                                }
                            }
                        }
                        catch {
                            Write-Verbose "  Probe failed for batch on $($res.Name) ($aggType): $_"
                            # On error, keep metrics (benefit of the doubt)
                            foreach ($bm in $batch) {
                                $confirmedMets.Add($bm)
                            }
                        }
                    }
                }

                $dropped = $resMets.Count - $confirmedMets.Count
                $liveDropped += $dropped
                $liveKept += $confirmedMets.Count
                if ($confirmedMets.Count -gt 0) {
                    $metricsMap[$resId] = @($confirmedMets)
                } else {
                    $metricsMap.Remove($resId)
                }
                # Per-resource summary
                if ($dropped -gt 0) {
                    Write-Host "    $($res.Name): $($confirmedMets.Count)/$($resMets.Count) passed ($dropped dropped)" -ForegroundColor DarkYellow
                    foreach ($dName in $resDropped) {
                        Write-Host "      DROPPED: $dName" -ForegroundColor DarkGray
                    }
                } else {
                    Write-Verbose "  $($res.Name): $($confirmedMets.Count)/$($resMets.Count) all passed"
                }
            }

            Write-Progress -Activity 'Live-probing metrics' -Completed
            Write-Host "  Live probe: $liveKept confirmed, $liveDropped dropped (WUG poll pattern returned no data)" -ForegroundColor DarkGray
        }

        # ================================================================
        # Phase 3: Build discovery plan
        # ================================================================
        $baseAttrs = @{
            'Vendor'                         = 'Azure'
            'DiscoveryHelper.Azure'          = 'true'
            'DiscoveryHelper.Azure.LastRun'  = (Get-Date).ToUniversalTime().ToString('o')
        }

        foreach ($resId in @($resourceMap.Keys | Sort-Object)) {
            $res = $resourceMap[$resId]
            $resName = $res.Name

            $resAttrs = $baseAttrs.Clone()
            $shortType = ($res.FullType -split '/')[-1]

            # WUG-standard attribute names (spaces, not dots)
            $resAttrs['Azure Subscription ID'] = $res.SubId
            $resAttrs['Azure Resource Group']   = $res.RG
            $resAttrs['Azure Location']         = $res.Location
            $resAttrs['Cloud Type']             = $shortType
            $resAttrs['ComputedDisplayName']    = $resName
            $resAttrs['HostName']               = $resName

            # SYS attributes used by Cloud Resource Monitor
            $resAttrs['SYS:AzureResourceID']   = $resId
            $resAttrs['SYS:CloudResourceID']   = "AzureRM/$($res.Location)/$shortType/$($res.RG){$($res.SubId)}/$resName"

            # Extra discovery-specific attributes (dot-prefixed)
            if ($res.State)          { $resAttrs['Azure.State'] = $res.State }
            if ($res.HealthProperty) { $resAttrs['Azure.HealthProperty'] = $res.HealthProperty }
            if ($res.IP)             { $resAttrs['Azure.IPAddress'] = $res.IP }
            if ($res.Kind)           { $resAttrs['Azure.Kind'] = $res.Kind }
            if ($res.Sku)            { $resAttrs['Azure.Sku']  = $res.Sku }
            if ($res.Tags)  { $resAttrs['Azure.Tags'] = $res.Tags }

            # Collect available metric names as an attribute for the device
            $resMetrics = @()
            if ($metricsMap.ContainsKey($resId)) {
                $resMetrics = $metricsMap[$resId]
                $resAttrs['Azure.MetricCount'] = "$($resMetrics.Count)"
                $metricNames = @($resMetrics | ForEach-Object { $_.DisplayName }) -join '; '
                if ($metricNames.Length -gt 4000) { $metricNames = $metricNames.Substring(0, 4000) + '...' }
                $resAttrs['Azure.AvailableMetrics'] = $metricNames
            }

            # --- Active monitor: REST API Resource Health check ---
            # Per-device REST API Active Monitor that queries Azure for resource liveness.
            # Uses the device's REST API credential (OAuth2 client_credentials) for auth.
            # Down condition: HTTP error codes OR JSONPath comparison.
            # ComparisonList uses WUG internal format: JsonPathQuery/AttributeType/ComparisonType
            # AttributeType 1 = String, ComparisonType 3 = DoesNotContain.
            # Property is probed during discovery: availabilityState > enabled > state > provisioningState > dailyMaxActiveDevices.
            # If no property was found during probing, fall back to provisioningState.
            if ($healthTypeSupport.ContainsKey($res.FullType) -and -not $healthTypeSupport[$res.FullType]) {
                # ARM resource-exists fallback
                $fallbackApi = '2021-04-01'
                if ($healthFallbackApi.ContainsKey($res.FullType)) {
                    $fallbackApi = $healthFallbackApi[$res.FullType]
                }
                $healthUrl = "https://management.azure.com${resId}?api-version=$fallbackApi"
                $armProp = if ($healthJsonProp.ContainsKey($res.FullType)) { $healthJsonProp[$res.FullType] } else { 'provisioningState' }
                # Use the ACTUAL observed value from the ARM probe as the "healthy" baseline.
                # This handles resource-specific values like 'Enabled' (smartDetectorAlertRules.state)
                # vs 'Active' (other .state), 'Succeeded' (provisioningState), etc.
                $armSuccessValue = if ($healthJsonValue.ContainsKey($res.FullType)) {
                    $healthJsonValue[$res.FullType]
                } else {
                    # Fallback for unprobed resources
                    switch ($armProp) {
                        'provisioningState' { 'Succeeded' }
                        'enabled'           { 'true' }
                        'state'             { 'Active' }
                        'availabilityState' { 'Available' }
                        default             { $null }
                    }
                }
                if ($armSuccessValue) {
                    # Down if property Does Not Contain the healthy value (AT:1=String, CT:3=DoesNotContain)
                    $healthCompare = "[{`"JsonPathQuery`":`"['properties']['$armProp']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"$armSuccessValue`"}]"
                } else {
                    # Numeric or unknown property — fall back to IsNotNull (AT:3, CT:14)
                    $healthCompare = "[{`"JsonPathQuery`":`"['properties']['$armProp']`",`"AttributeType`":3,`"ComparisonType`":14}]"
                }
            }
            else {
                # Resource Health endpoint (supported type)
                # Down condition: availabilityState does not contain "Available" OR contains "Unknown"
                # AttributeType 1 = String, ComparisonType 3 = DoesNotContain, ComparisonType 2 = Contains
                $healthUrl = "https://management.azure.com$resId/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"
                $rhProp = if ($healthJsonProp.ContainsKey($res.FullType)) { $healthJsonProp[$res.FullType] } else { 'availabilityState' }
                $healthCompare = "[{`"JsonPathQuery`":`"['properties']['$rhProp']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"Available`"},{`"JsonPathQuery`":`"['properties']['$rhProp']`",`"AttributeType`":1,`"ComparisonType`":2,`"CompareValue`":`"Unknown`"}]"
            }
            $items += New-DiscoveredItem `
                -Name "Azure Health - $resName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $healthUrl
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = $healthCompare
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "Azure:$($res.SubId):${resName}:active:health" `
                -Attributes $resAttrs `
                -Tags @('azure', $res.Type, $resName, $res.Location)

            # --- Performance monitors: one per validated metric ---
            # Uses REST API performance monitor type with Azure Metrics API URL + JSONPath.
            # The device's REST API credential (OAuth2 client_credentials) handles auth.
            # JSONPath uses the actual aggregation field discovered during validation
            # (e.g. average, total, maximum) — WUG uses $.value[0].timeseries[0].data[0].{field}
            # Only metrics with a confirmed numeric DataField are included.
            if ($resMetrics.Count -gt 0) {
                foreach ($m in $resMetrics) {
                    $mName = $m.Name
                    $mDisplay = $m.DisplayName

                    # Only create monitors for metrics where validation confirmed a
                    # specific aggregation field returned a numeric value.
                    if (-not ($m.ContainsKey('DataField') -and $m.DataField)) {
                        Write-Verbose "Skipping metric '$mDisplay' on $resName — no confirmed numeric data field"
                        continue
                    }
                    $jsonField = $m.DataField

                    # Map the data field back to the Azure API aggregation parameter name
                    $urlAgg = switch ($jsonField) {
                        'average' { 'Average' }
                        'total'   { 'Total' }
                        'count'   { 'Count' }
                        'maximum' { 'Maximum' }
                        'minimum' { 'Minimum' }
                        default   { 'Average' }
                    }

                    # Build Azure Metrics API URL — configurable timespan/interval returns
                    # 1 aggregated bucket.  Wider windows (P7D) make polling resilient to idle
                    # resources / sparse metrics.  WUG polls periodically; each poll gets the
                    # window aggregated into a single data point so JSONPath $.data[0] always
                    # hits as long as the metric had ANY data in the window.
                    $metricUrl = "https://management.azure.com${resId}/providers/Microsoft.Insights/metrics" +
                        "?api-version=2024-02-01" +
                        "&metricnames=$([uri]::EscapeDataString($mName))" +
                        "&timespan=${metricsTimespan}&interval=${metricsTimespan}" +
                        "&aggregation=$urlAgg"

                    # JSONPath: $.value[0].timeseries[0].data[0].{field}
                    $jsonPath = "`$.value[0].timeseries[0].data[0].$jsonField"

                    $mParams = @{
                        RestApiUrl                = $metricUrl
                        RestApiJsonPath           = $jsonPath
                        RestApiHttpMethod         = 'GET'
                        RestApiHttpTimeoutMs      = '15000'
                        RestApiUseAnonymousAccess = '0'
                        # Metadata (excluded from WUG API calls, used by dashboards)
                        _MetricName               = $mName
                        _MetricDisplayName        = $mDisplay
                        _Aggregation              = $urlAgg
                        _JsonField                = $jsonField
                    }
                    if ($m.ContainsKey('LastValue'))    { $mParams['LastValue']     = $m.LastValue }
                    if ($m.ContainsKey('LastTimestamp')) { $mParams['LastTimestamp']  = $m.LastTimestamp }
                    if ($m.ContainsKey('Unit'))         { $mParams['MetricUnit']     = $m.Unit }

                    $items += New-DiscoveredItem `
                        -Name "$mDisplay - $resName ($($res.Type))" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams $mParams `
                        -UniqueKey "Azure:$($res.SubId):${resName}:perf:$mName" `
                        -Attributes $resAttrs `
                        -Tags @('azure', $res.Type, $resName, $mName, $res.Location)
                }
            }
        }

        # ================================================================
        # Phase 4: Billing monitors — discover Azure Budgets per subscription
        # ================================================================
        # Azure Budgets API (GET) returns currentSpend, forecastSpend, and
        # the budget limit — all clean numeric values extractable via JSONPath.
        # Requires a Budget to exist (created in portal or via API).
        Write-Host "  Discovering Azure Budgets for billing monitors..." -ForegroundColor DarkGray
            $budgetCount = 0

            foreach ($sub in $subscriptions) {
                $subId = $sub.SubscriptionId
                $subName = $sub.SubscriptionName

                try {
                    $budgetsUrl = "https://management.azure.com/subscriptions/${subId}/providers/Microsoft.Consumption/budgets?api-version=2024-08-01"
                    $budgets = @(Invoke-AzureREST -Uri $budgetsUrl)
                }
                catch {
                    Write-Verbose "Could not query budgets for subscription ${subName}: $_"
                    continue
                }

                # Auto-create a catch-all budget if none exist
                if ($budgets.Count -eq 0 -or (-not $budgets[0].name)) {
                    $autoBudgetName = "WUG-Discovery-Monitor"
                    Write-Host "    No budgets in '$subName' -- creating '$autoBudgetName' (monthly, `$1000 limit)..." -ForegroundColor Yellow
                    # Start date = 1st of current month (Azure requires this format)
                    $startDate = (Get-Date -Day 1).ToUniversalTime().ToString('yyyy-MM-01T00:00:00Z')
                    $budgetBody = @{
                        properties = @{
                            category   = 'Cost'
                            amount     = 1000
                            timeGrain  = 'Monthly'
                            timePeriod = @{ startDate = $startDate }
                            filter     = @{}
                        }
                    }
                    try {
                        $createUrl = "https://management.azure.com/subscriptions/${subId}/providers/Microsoft.Consumption/budgets/${autoBudgetName}?api-version=2024-08-01"
                        $created = Invoke-AzureREST -Uri $createUrl -Method PUT -Body $budgetBody
                        if ($created -and $created.name) {
                            $budgets = @($created)
                            Write-Host "    Created budget '$autoBudgetName' successfully." -ForegroundColor Green
                        }
                        else {
                            Write-Warning "    Budget creation returned no result. Skipping billing monitors for '$subName'."
                            continue
                        }
                    }
                    catch {
                        Write-Warning "    Could not create budget for '$subName': $_"
                        Write-Host "    To create manually: Azure Portal > Subscriptions > $subName > Budgets > Add" -ForegroundColor DarkGray
                        continue
                    }
                }

                foreach ($budget in $budgets) {
                    $budgetName = $budget.name
                    if (-not $budgetName) { continue }
                    $budgetCount++
                    Write-Verbose "  Found budget '$budgetName' in subscription '$subName'"

                    $budgetUrl = "https://management.azure.com/subscriptions/${subId}/providers/Microsoft.Consumption/budgets/$([uri]::EscapeDataString($budgetName))?api-version=2024-08-01"

                    # Build device-compatible attributes so the billing monitors group
                    # under a subscription-level device in the plan.
                    $billingDeviceName = "Azure Budget - $budgetName"
                    $billingAttrs = $baseAttrs.Clone()
                    $billingAttrs['Azure Subscription']    = $subName
                    $billingAttrs['Azure Subscription ID'] = $subId
                    $billingAttrs['Azure Resource Group']   = ''
                    $billingAttrs['Azure Location']         = 'global'
                    $billingAttrs['Azure Budget Name']      = $budgetName
                    $billingAttrs['Cloud Type']             = 'budget'
                    $billingAttrs['ComputedDisplayName']    = $billingDeviceName
                    $billingAttrs['HostName']               = $billingDeviceName

                    # Monitor 1: Current month-to-date spend
                    $items += New-DiscoveredItem `
                        -Name "Azure Billing - Current Spend - $budgetName ($subName)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $budgetUrl
                            RestApiJsonPath           = '$.properties.currentSpend.amount'
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'CurrentSpend'
                            _MetricDisplayName        = "Current Spend - $budgetName"
                            _Aggregation              = 'Total'
                            _JsonField                = 'amount'
                        } `
                        -UniqueKey "Azure:${subId}:billing:${budgetName}:currentSpend" `
                        -Attributes $billingAttrs `
                        -Tags @('azure', 'billing', $subName, $budgetName, 'currentSpend')

                    # Monitor 2: Budget limit amount
                    $items += New-DiscoveredItem `
                        -Name "Azure Billing - Budget Limit - $budgetName ($subName)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $budgetUrl
                            RestApiJsonPath           = '$.properties.amount'
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'BudgetLimit'
                            _MetricDisplayName        = "Budget Limit - $budgetName"
                            _Aggregation              = 'Total'
                            _JsonField                = 'amount'
                        } `
                        -UniqueKey "Azure:${subId}:billing:${budgetName}:budgetLimit" `
                        -Attributes $billingAttrs `
                        -Tags @('azure', 'billing', $subName, $budgetName, 'budgetLimit')

                    # Monitor 3: Forecasted spend (may be null if Azure hasn't computed it yet)
                    $items += New-DiscoveredItem `
                        -Name "Azure Billing - Forecast Spend - $budgetName ($subName)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams @{
                            RestApiUrl                = $budgetUrl
                            RestApiJsonPath           = '$.properties.forecastSpend.amount'
                            RestApiHttpMethod         = 'GET'
                            RestApiHttpTimeoutMs      = '15000'
                            RestApiUseAnonymousAccess = '0'
                            _MetricName               = 'ForecastSpend'
                            _MetricDisplayName        = "Forecast Spend - $budgetName"
                            _Aggregation              = 'Total'
                            _JsonField                = 'amount'
                        } `
                        -UniqueKey "Azure:${subId}:billing:${budgetName}:forecastSpend" `
                        -Attributes $billingAttrs `
                        -Tags @('azure', 'billing', $subName, $budgetName, 'forecastSpend')
                }
            }

            if ($budgetCount -gt 0) {
                Write-Host "  Discovered $budgetCount budget(s) ($($budgetCount * 3) billing monitors)" -ForegroundColor DarkGray
            }

        $secret = $null; $tenantId = $null; $appId = $null
        return $items
    }

# ==============================================================================
# Export-AzureDiscoveryDashboardHtml
# ==============================================================================
function Export-AzureDiscoveryDashboardHtml {
    <#
    .SYNOPSIS
        Generates an Azure dashboard HTML file from resource data.
    .DESCRIPTION
        Reads the Azure dashboard template, injects column definitions
        and row data as JSON, and writes the final HTML to OutputPath.
    .PARAMETER DashboardData
        Array of PSCustomObject rows from Get-AzureDashboard.
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title shown in header and browser tab.
    .PARAMETER TemplatePath
        Path to Azure-Dashboard-Template.html.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Azure Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'azure\\Azure-Dashboard-Template.html'
    }
    if (-not (Test-Path $TemplatePath)) {
        Write-Error "Template not found: $TemplatePath"
        return
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '(?<=[a-z])([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'ProvisioningState') { $col.formatter = 'formatState' }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA7hM2h4uD9tSCR
# RDBoEx1lDpr7YcFDVOVr/7yKA8HIqaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBzenYZiL5SgDoofEKc9XThiUd9hK4K1P2f/c83MkGctDANBgkqhkiG9w0BAQEF
# AASCAgBUeUv1TFjbPN/J0IiUo4E3xYxvW7shGeSokCqlXwhhiYRGMdFca/dqCXx9
# J2cYcvgnprFjeBm8K7BdlnC/HK9awuPrGqMdVEAQ7gIkpw5s3tnKfHDlpSpNB4t+
# gA/8PWkNRAmn6L3zkYu+HC850NI1hSEM4twZuICvaXTb7J206S6eQMTHZOo8QZ2Q
# OBWFLIkoVbTNvshDvENzslzl5RiBi0vI2sA0vXgZqBN6Rf5vkmgPiG/KKQj2lwCU
# zdDYk2Egb0D73v9TFF+fYkCj+sEr/xhhs2uboi9jI16C6BCK7blm1rioa6TwDSv0
# vUYEY83NTYbI0gUvzV9MVHfRyrC8hJahRONCl+MuGIvxis9Oe+m3+8eFvSs+wRy8
# TCZhMRMDG2zp4brLFhdSW+U5A1I9hWhEHTHI6+MRZrNWU8wWtbaPBKxaZPRx4iQm
# vRMMi2s0EW9mrgXj+pOVrJ+DgAGvKqkwfZBEhYBIAOcQ3Ta2e3zZCUEtLDwSEdFF
# M/OTcRJsh8frhVcQPjWu0GAJAWO5uPYZ7YSJIIBc1L/BNQJYq2pQjLAJrZpIeolR
# lsgTvX1NMvedRWFPYSIa2Huwifm1qkfS/e5LGxhej3trwYqFNm2m6/SigAneUO/k
# /9woA1FcCeQLbwIXeTHWMEHkTGOujtkY51cl9QDksDXZ9luRVaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjYxNDQyNDFaMC8GCSqGSIb3DQEJBDEiBCCtwr4H
# ocBROsO7tTmlziOpZuurTgdJHc9K2dwNaxSdhTANBgkqhkiG9w0BAQEFAASCAgAz
# lXxBeYc91sbRrTJu5ey2cQ6Bjx4BsLd0Kqv3p9oexBjXPgBwuNTYbcsAxS8tkz5Z
# qxcw2JSudTU3FPMUB6vBT5ZJdJ6HHhkmh1Qo2kfDcJ1AIbMF3c/5JNqKeWmLJ+7k
# 8KFuDaPE7HgdmBb4fOXRoUrOXFaOcCrLLCOqyCFurvXs/RycuUQwyHo5VLiqo/hE
# 4k2MwYBEicvF4iD9hCPSToYIMBQ6w/yC3c3LKl50/Wo+ERM70RxyC8imO6KhdSIP
# hg+M3iiz/umFP1dGa1thylUdNTQK5d3s+hr+e5X15ifBswV7iPhfj3FEhRuc7zdU
# ooM1iwudiMB/3w3ndzhqsmOCGVnqu3PRGOIx8VAcP3reHNpfnLyGpGa9bEfyI9ND
# hy6C7t0Sex39RCbvPwuULoh/pY3MZhgrpJ5ZkMZUAYkUg1O4VmTzeK4gY6BgYo53
# MTG2gYFApJ7yzpzqlI8B6L+kjjPiyt8vI84Kstz4kPx4JxfTZ5DNDOsSWVk6Ol/R
# dehkFN9E2gRXnrqzEviHW+6yddxNDlppDa36ji0lOE/1T+GcQnkg/ODXMS7CapU2
# g6nstPlOBWQ6Wi1fiE23i0stPTG92oMlvnig8Hubj88n0B+dmKyDITRQnmZ2rqU3
# LNxA8qHTwGFimj3ofWxU3jACfjX+iozLZPPWVo7PTg==
# SIG # End signature block
