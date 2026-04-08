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
            Write-Warning "Error during Azure enumeration: $_"
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
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDUkCxM6Gsu67gX
# s5DCNW+1rD7in/ApgZ69ttxA5P+dNKCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD61fRk
# YFjGAMRxviHAGrps4h89H8WsTAXpLcMffxlPgjANBgkqhkiG9w0BAQEFAASCAgDq
# VjLDha/sTi9gX6K9iA1k2hijO9DxnDclYeCddLG31ZRAoqdP0Tj1yY8ES77Q0RMU
# kiochywpH4GVZUaPww9xjitFb4hah7750A5ahWiBhWG0Q190X8senQwreG9Cy1jd
# zQ0IL3QDdu+zo7ERNXtPSGkPv+YpUC8uM2f/vgNH2HSDuWnZ1k8iOOtojre2hqXi
# 82q0A9/PWDOc0B3UEJbISXE83fz9EvYFc9l4v7htkaraTDGI3D3qA+GUsTa/oKA6
# tS9J39gicH68bj69lqsJnAIqkvKK0mOeipBhh9GQQMCQ0czbjbaqmagKQxmiIbh5
# yAejjp2zwHeYswTzLd0SyEr1S8BtGvuYMAdDZcJi7hZDgRDQ+kaTYH+Bh9o7L3KE
# LGF/ZC9nIHQskYDAYbQjXq4JST1NDTmzvGx6q6OkPNy4327sgNxOQ+HWa3bNr1UR
# m2OQ5/jNHzUJ1wRuis0ei3C8dOv33MrXqiGLRa7f2K+RtnTdbccfoJDnyOdKw5n8
# 8mHn2l6JbsP/krWSwH9xqVSxTeo1iuC/20O3NzKNTGdj1kptIjhZDaOgJ76uT00o
# KXQX7l250ajAxUqUix1pafIQWSiBJoyVaQTfiPDrJ8L3N9NivXERkNwwHYRZzGjZ
# S26B2k7c7sTALJOXPVm2sExNo6d9l25qFgOtbabG6aGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzE5NTg1
# OFowPwYJKoZIhvcNAQkEMTIEMIXgPFvqSP0cNu3jWI/V2YL7rtRSzNURoOrTgrbE
# cw0DEsGMmkHu35PVVSWMSCzqRzANBgkqhkiG9w0BAQEFAASCAgCFMZkXgEvgtNmE
# c61pGNZg4smQUdEGiZYqasOFle0lLvEyfumF0dVfh9V0o6BxB7UVH8TZkyB5KZv7
# FSd0/8yP0QCfwVqgCGjtl6nUdtERceiLlJBYp9NIfzOHBi3TH7C7kNHtE/P48lUW
# jPIVAzoVpjgb7Nt4teh6k4qHI8VRJxZT2LdVJtYy675Grtf+Cc5bY4dZHTj+5kuo
# 2lOd1U+Wz/Q7c4rUQBNzv1pZ1eoaxhn99rood8Q2FDBpU3HT6PmzewtFCO0uYoDz
# pR1B/UR7RFWimJV9djZSu24Z5DowF52seeSY1yZwwYSLMiPR28eY+3bFzWLl3RNd
# FtAS410NbYEeS5q6rp7MzWCsCXKf5dUvTzyuzjmKTPKu/QeAda6L6ahB6GZY/k0i
# PA1aYnoFoSRMOa4sCIyp09oFu5XywHvj5FwskL9jpRmibkdDEnEPp8HXtSW/Xya0
# Fe3mF/uWR2gIXMqEJpoSEFbkkjje2bGsLOmI/NRJ9ybj83f11B9CIikVEOvqN615
# fmJ1wxkKWLhUt3hcAoqymYqGm6FPZ8O5tVYUPgylqZKYx/X3icJxAaItLNvW9ggU
# Gx5iCpyUyIyNtRH26kjjgGSsfbtzjlmbR+D+AaRZm4DZcau7Q4eWUD0760BRqGxX
# oUu5VxIY+N/taZMGP0byY0FFQCwOFQ==
# SIG # End signature block
