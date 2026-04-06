<#
.SYNOPSIS
    Azure discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers an Azure discovery provider that discovers subscriptions,
    resource groups, and resources, then builds a monitor plan suitable
    for WhatsUp Gold or standalone use.

    Two collection methods supported:
      [1] Az PowerShell modules -- uses Az.Accounts, Az.Resources, etc.
      [2] REST API direct -- zero external dependencies (Invoke-RestMethod)

    The method is selected by the caller via Credential.UseRestApi = $true/$false.

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
      3. For Az module mode only:
         Install-Module -Name Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Monitor -Scope CurrentUser -Force

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

        # Determine collection method
        $useRest = $false
        if ($ctx.Credential -and $ctx.Credential.UseRestApi) {
            $useRest = $ctx.Credential.UseRestApi
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
            if ($useRest) {
                Connect-AzureServicePrincipalREST -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret | Out-Null
            }
            else {
                Connect-AzureServicePrincipal -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret | Out-Null
            }
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
            if ($useRest) {
                $subscriptions = Get-AzureSubscriptionsREST | Where-Object { $_.State -eq 'Enabled' }
            }
            else {
                $subscriptions = Get-AzureSubscriptions | Where-Object { $_.State -eq 'Enabled' }
            }
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
                if (-not $useRest) {
                    Set-AzContext -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue | Out-Null
                }

                try {
                    if ($useRest) {
                        $rgs = Get-AzureResourceGroupsREST -SubscriptionId $sub.SubscriptionId
                    }
                    else {
                        $rgs = Get-AzureResourceGroups
                    }
                }
                catch {
                    Write-Warning "Failed to list RGs for $($sub.SubscriptionName): $_"
                    continue
                }
                Write-Host "      Resource groups: $(@($rgs).Count)" -ForegroundColor DarkGray

                foreach ($rg in $rgs) {
                    try {
                        if ($useRest) {
                            $resources = Get-AzureResourcesREST -SubscriptionId $sub.SubscriptionId -ResourceGroupName $rg.ResourceGroupName
                        }
                        else {
                            $resources = Get-AzureResources -ResourceGroupName $rg.ResourceGroupName
                        }
                    }
                    catch {
                        Write-Warning "Failed to list resources in $($rg.ResourceGroupName): $_"
                        continue
                    }
                    if (@($resources).Count -gt 0) {
                        Write-Host "      $($rg.ResourceGroupName): $(@($resources).Count) resources" -ForegroundColor DarkGray
                    }

                    foreach ($r in $resources) {
                        $ip = $null
                        try {
                            if ($useRest) {
                                $ip = Resolve-AzureResourceIPREST -Resource $r -SubscriptionId $sub.SubscriptionId
                            }
                            else {
                                $ip = Resolve-AzureResourceIP -Resource $r
                            }
                        }
                        catch { }

                        $resourceMap[$r.ResourceId] = @{
                            Name         = $r.ResourceName
                            ResourceId   = $r.ResourceId
                            Type         = ($r.ResourceType -split '/')[-1]
                            FullType     = $r.ResourceType
                            State        = $r.ProvisioningState
                            IP           = $ip
                            Location     = $r.Location
                            Subscription = $sub.SubscriptionName
                            SubId        = $sub.SubscriptionId
                            RG           = $rg.ResourceGroupName
                            Kind         = $r.Kind
                            Sku          = $r.Sku
                            Tags         = if ($r.Tags) { $r.Tags } else { '' }
                        }

                        # Check Resource Health support for this type (once per type)
                        if (-not $healthTypeSupport.ContainsKey($r.ResourceType)) {
                            $healthTestUrl = "https://management.azure.com$($r.ResourceId)/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"
                            try {
                                $healthResp = $null
                                if ($useRest) {
                                    $healthResp = Invoke-AzureREST -Uri $healthTestUrl
                                }
                                else {
                                    $azResp = Invoke-AzRestMethod -Uri $healthTestUrl -Method GET -ErrorAction Stop
                                    if ($azResp.StatusCode -ge 400) { throw $azResp.Content }
                                    $healthResp = $azResp.Content | ConvertFrom-Json
                                }
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
                                            if ($useRest) {
                                                $providerCache[$ns] = Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/$($sub.SubscriptionId)/providers/${ns}" -ApiVersion '2021-04-01'
                                            }
                                            else {
                                                $providerCache[$ns] = Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction Stop
                                            }
                                        }
                                        catch {
                                            Write-Verbose "  Could not query provider $ns for API versions: $_"
                                            $providerCache[$ns] = $null
                                        }
                                    }

                                    $provInfo = $providerCache[$ns]
                                    $apiVer = $null
                                    if ($provInfo) {
                                        if ($useRest) {
                                            $rtInfo = @($provInfo.resourceTypes | Where-Object { $_.resourceType -eq $rtName })
                                        }
                                        else {
                                            $rtInfo = @($provInfo.ResourceTypes | Where-Object { $_.ResourceTypeName -eq $rtName })
                                        }
                                        if ($rtInfo.Count -gt 0) {
                                            if ($useRest) { $apiVersions = @($rtInfo[0].apiVersions) }
                                            else          { $apiVersions = @($rtInfo[0].ApiVersions) }
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
                                        $armResp = $null
                                        $armProbeUrl = "https://management.azure.com$($r.ResourceId)?api-version=$probeApi"
                                        if ($useRest) {
                                            $armResp = Invoke-AzureREST -Uri $armProbeUrl
                                        }
                                        else {
                                            $azArmResp = Invoke-AzRestMethod -Uri $armProbeUrl -Method GET -ErrorAction Stop
                                            if ($azArmResp.StatusCode -lt 400) {
                                                $armResp = $azArmResp.Content | ConvertFrom-Json
                                            }
                                        }
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
                    if ($useRest) {
                        $defUri = "https://management.azure.com${resId}/providers/Microsoft.Insights/metricDefinitions"
                        $defs = @(Invoke-AzureREST -Uri $defUri -ApiVersion '2024-02-01')
                    }
                    else {
                        $defs = @(Get-AzMetricDefinition -ResourceId $resId -ErrorAction Stop)
                    }

                    $mList = @()
                    foreach ($def in $defs) {
                        if ($useRest) {
                            $mName = $def.name.value
                            $mDisplay = $def.name.localizedValue
                            $mUnit = "$($def.unit)"
                            $mAgg = if ($def.primaryAggregationType) { "$($def.primaryAggregationType)" } else { 'Average' }
                        }
                        else {
                            $mName = $def.Name.Value
                            $mDisplay = $def.Name.LocalizedValue
                            $mUnit = "$($def.Unit)"
                            $mAgg = if ($def.PrimaryAggregationType) { "$($def.PrimaryAggregationType)" } else { 'Average' }
                        }

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

                        if ($useRest) {
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
                        }
                        else {
                            # Az module path — query each metric individually
                            $startTime = (Get-Date).AddDays(-1)
                            $endTime   = Get-Date
                            foreach ($bm in $batch) {
                                try {
                                    $azMetric = Get-AzMetric -ResourceId $resId -MetricName $bm.Name `
                                        -TimeGrain 01:00:00 -StartTime $startTime -EndTime $endTime `
                                        -AggregationType $bm.Aggregation -ErrorAction Stop
                                    if ($azMetric.Data) {
                                        # Determine field check order: declared aggregation first, then others
                                        $prefField = if ($declaredAgg.ContainsKey($bm.Name)) { $declaredAgg[$bm.Name] } else { $null }
                                        $azFieldOrder = @('average', 'total', 'maximum', 'minimum', 'count')
                                        if ($prefField) {
                                            $azFieldOrder = @($prefField) + @($azFieldOrder | Where-Object { $_ -ne $prefField })
                                        }
                                        # Az module returns PascalCase properties; map lowercase to PascalCase
                                        $azFieldMap = @{ 'average' = 'Average'; 'total' = 'Total'; 'maximum' = 'Maximum'; 'minimum' = 'Minimum'; 'count' = 'Count' }
                                        for ($di = @($azMetric.Data).Count - 1; $di -ge 0; $di--) {
                                            $dp = @($azMetric.Data)[$di]
                                            $val = $null
                                            $foundField = $null
                                            foreach ($fld in $azFieldOrder) {
                                                $propName = $azFieldMap[$fld]
                                                if ($null -ne $dp.$propName) {
                                                    $testVal = $dp.$propName
                                                    if ($testVal -is [double] -or $testVal -is [int] -or $testVal -is [long] -or $testVal -is [decimal] -or $testVal -is [float] -or $testVal -is [single]) {
                                                        $val = $testVal
                                                        $foundField = $fld
                                                        break
                                                    }
                                                }
                                            }
                                            if ($null -ne $val) {
                                                $namesWithData[$bm.Name] = @{
                                                    Value     = $val
                                                    Timestamp = "$($dp.TimeStamp)"
                                                    Unit      = "$($azMetric.Unit)"
                                                    DataField = $foundField
                                                }
                                                break
                                            }
                                        }
                                    }
                                }
                                catch {
                                    Write-Verbose "Az metric query failed for $($bm.Name): $_"
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
        if ($metricsMap.Count -gt 0 -and $useRest) {
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
            if ($res.State) { $resAttrs['Azure.State'] = $res.State }
            if ($res.IP)    { $resAttrs['Azure.IPAddress'] = $res.IP }
            if ($res.Kind)  { $resAttrs['Azure.Kind'] = $res.Kind }
            if ($res.Sku)   { $resAttrs['Azure.Sku']  = $res.Sku }
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
        if ($useRest) {
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDclhsd/EUwXxK4
# XTZLoEslrOiRds1PRUbgLMl1giol2aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgkB/OBW/rrGsP9qygFdGXr7UZBZZXJlZ0
# 8b3NFBj/L4kwDQYJKoZIhvcNAQEBBQAEggIArXfrSXy8MvnePwew/WMb2JNUGBcs
# JF8Rp3XQ6KH2UY24zotUzJO1BBQqPOHEaRCRGAiSjmD4egOaPySQ8cAQyAZeiH1o
# OLRjKK20NuVCRBHkhTog1sldV9Mr8bFymXRTrbHGq0cFmT05dkyQOJd5sjZgOYAC
# EhyKEOQQBMkCI8x9NiBNRoLoIwOb9Sx2ReXVOnQFc8Ne+kAGoU01rZQF7F5o816W
# BvJCpAuGDGm64JfqMXzOxczWMK/PnJqe1UTUI0Cx+c4vHEDFXP9XUl2vZbax3NkB
# LbJlzjRVROPh0dsFHYMTrCthtDxhLxTl4PRq256ppd68g7+sOEaUTyX1k64TYiF9
# Ls/SIF0/eAofVwPFqTRChdjGfh6wpJPOnGLLCqignxdktlyOY1R5z0TqsFvFCmag
# B1krZURqvWelRTa3uwaGxUwfU2KZexg4fGlKGO3SP5mCBcSqGjLQir0qBkRmb9lu
# fIJrLwuBjBgcPFn7KbJ7tfCBUsLnXQYQmzciTEPNMS3zWtDvhLXhRpGOuNQ5uwuo
# 26Om4jcbak2ENiRCvUfY9OC76lB1Nb17d2At9rgAYw51pz/oxdyoPypdV4KSKzSk
# Nrdpjc5LSKR67jrQTsLx7yZxakM7af2/erPLiW4T5DqB6dOmBFdVZ1UJycdoZI2v
# 6Ik6yQvLrAxdoVA=
# SIG # End signature block
