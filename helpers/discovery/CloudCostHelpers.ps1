#requires -Version 5.1
<#
.SYNOPSIS
    Opt-in cloud cost, quota and waste analysis for the discovery framework.
.DESCRIPTION
    Adds the operational metrics that infrastructure monitoring usually misses:
    account spend, budget consumption, service quota headroom, unattached disks,
    idle public IP addresses, stopped-but-billed compute, expiring reservations
    and orphaned load balancers.

    The design separates three layers so the logic can be tested without a cloud
    subscription:

      Collectors  Get-AzureCostQuotaFinding, Get-AWSCostQuotaFinding,
                  Get-OCICostQuotaFinding call the provider APIs.
      Parsers     ConvertFrom-* turn raw API payloads into normalized resources.
      Analyzers   Test-Cloud* / Get-CloudWasteFinding apply thresholds.

    Only the collector layer needs live credentials. Parsers and analyzers are
    pure functions.

    Costs are never invented. Sizes and counts are always reported; a monetary
    estimate appears only when you supply -UnitPrice for your own rates.
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+, provider helpers already used by discovery.
.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>

# ============================================================================
# region  Finding model
# ============================================================================

function Get-CloudCostItemCount {
    # @($null).Count is 1 in PowerShell, which would make an absent property look populated.
    [CmdletBinding()]
    param($InputObject)

    if ($null -eq $InputObject) { return 0 }
    return @($InputObject).Count
}

function New-CloudCostFinding {
    <#
    .SYNOPSIS
        Creates one normalized cost, quota or waste finding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Spend', 'Budget', 'Quota', 'UnattachedDisk', 'PublicIP', 'IdleResource', 'Reservation', 'OrphanedLoadBalancer', 'Collection')]
        [string]$Category,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warn', 'Fail', 'Info', 'Unknown')][string]$Status,
        [AllowEmptyString()][string]$Value = '',
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Resource = '',
        [AllowEmptyString()][string]$Region = '',
        $EstimatedMonthlyCost = $null
    )

    return [pscustomobject]@{
        Provider             = $Provider
        Target               = $Scope
        Category             = $Category
        Check                = $Check
        Status               = $Status
        Value                = $Value
        Resource             = $Resource
        Region               = $Region
        EstimatedMonthlyCost = $EstimatedMonthlyCost
        Detail               = $Detail
    }
}

function Get-CloudCostUnitPrice {
    <#
    .SYNOPSIS
        Looks up an optional user-supplied unit price.
    .DESCRIPTION
        Returns $null when no price is configured. Nothing in this module
        fabricates cloud pricing; supply your own rates to see cost estimates.
    .PARAMETER UnitPrice
        Hashtable such as @{ DiskGBMonth = 0.05; PublicIPMonth = 3.60 }.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$UnitPrice,
        [Parameter(Mandatory = $true)][string]$Key,
        [double]$Quantity = 1
    )

    if (-not $UnitPrice -or -not $UnitPrice.ContainsKey($Key)) { return $null }
    $rate = 0.0
    if (-not [double]::TryParse([string]$UnitPrice[$Key], [ref]$rate)) { return $null }
    return [Math]::Round($rate * $Quantity, 2)
}

# endregion

# ============================================================================
# region  Analyzers (pure)
# ============================================================================

function Test-CloudBudgetStatus {
    <#
    .SYNOPSIS
        Evaluates spend against a budget limit.
    .PARAMETER WarnPercent
        Consumption percentage that raises a warning. Default 80.
    .PARAMETER FailPercent
        Consumption percentage that raises a failure. Default 100.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Name,
        [double]$Limit,
        [double]$CurrentSpend,
        $ForecastSpend = $null,
        [string]$Currency = '',
        [int]$WarnPercent = 80,
        [int]$FailPercent = 100
    )

    if ($Limit -le 0) {
        return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Budget' `
            -Check "Budget $Name" -Status 'Unknown' -Resource $Name `
            -Detail 'Budget limit is zero or missing.'
    }

    $percent = [Math]::Round(($CurrentSpend / $Limit) * 100, 1)
    $status = 'Pass'
    if ($percent -ge $FailPercent) { $status = 'Fail' }
    elseif ($percent -ge $WarnPercent) { $status = 'Warn' }

    $detail = "Spend $CurrentSpend of $Limit $Currency."
    if ($null -ne $ForecastSpend) {
        $forecastPercent = [Math]::Round(([double]$ForecastSpend / $Limit) * 100, 1)
        $detail += " Forecast $ForecastSpend ($forecastPercent%)."
        if ($status -eq 'Pass' -and $forecastPercent -ge $FailPercent) { $status = 'Warn' }
    }

    return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Budget' `
        -Check "Budget $Name" -Status $status -Value "$percent%" -Resource $Name -Detail $detail
}

function Test-CloudQuotaUsage {
    <#
    .SYNOPSIS
        Evaluates a service quota against its limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Name,
        [double]$Current,
        [double]$Limit,
        [string]$Region = '',
        [int]$WarnPercent = 80,
        [int]$FailPercent = 90
    )

    # Unlimited quotas report a limit of -1 or 0 depending on the provider.
    if ($Limit -le 0) {
        return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Quota' `
            -Check "Quota $Name" -Status 'Info' -Value "$Current" -Resource $Name -Region $Region `
            -Detail 'No enforced limit reported.'
    }

    $percent = [Math]::Round(($Current / $Limit) * 100, 1)
    $status = 'Pass'
    if ($percent -ge $FailPercent) { $status = 'Fail' }
    elseif ($percent -ge $WarnPercent) { $status = 'Warn' }

    return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Quota' `
        -Check "Quota $Name" -Status $status -Value "$percent%" -Resource $Name -Region $Region `
        -Detail "Using $Current of $Limit."
}

function Get-CloudReservationStatus {
    <#
    .SYNOPSIS
        Evaluates how soon a reservation or commitment expires.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Name,
        $ExpiresOn,
        [int]$WarnDays = 60,
        [int]$FailDays = 30,
        [datetime]$ReferenceTime = (Get-Date)
    )

    if (-not $ExpiresOn) {
        return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Reservation' `
            -Check "Reservation $Name" -Status 'Unknown' -Resource $Name `
            -Detail 'No expiry date reported.'
    }

    $expiry = $null
    try { $expiry = [datetime]$ExpiresOn }
    catch {
        return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Reservation' `
            -Check "Reservation $Name" -Status 'Unknown' -Resource $Name `
            -Detail "Unreadable expiry value: $ExpiresOn"
    }

    $days = [Math]::Floor(($expiry - $ReferenceTime).TotalDays)
    $status = 'Pass'
    if ($days -le $FailDays) { $status = 'Fail' }
    elseif ($days -le $WarnDays) { $status = 'Warn' }

    return New-CloudCostFinding -Provider $Provider -Scope $Scope -Category 'Reservation' `
        -Check "Reservation $Name" -Status $status -Value "$days days" -Resource $Name `
        -Detail "Expires $($expiry.ToString('yyyy-MM-dd'))."
}

function Get-CloudWasteFinding {
    <#
    .SYNOPSIS
        Turns normalized waste inventory into findings.
    .PARAMETER Resource
        Objects with Category, Name, Region and optional SizeGB or Detail.
    .PARAMETER UnitPrice
        Optional rates, for example @{ DiskGBMonth = 0.05; PublicIPMonth = 3.60 }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Resource,
        [hashtable]$UnitPrice
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Resource)) {
        if (-not $item) { continue }
        $category = [string]$item.Category
        $name = [string]$item.Name
        $region = ''
        if ($item.PSObject.Properties['Region']) { $region = [string]$item.Region }

        $value = ''
        $cost = $null
        $detail = ''
        if ($item.PSObject.Properties['Detail']) { $detail = [string]$item.Detail }

        switch ($category) {
            'UnattachedDisk' {
                $sizeGb = 0
                if ($item.PSObject.Properties['SizeGB'] -and $item.SizeGB) { $sizeGb = [double]$item.SizeGB }
                $value = "$sizeGb GB"
                $cost = Get-CloudCostUnitPrice -UnitPrice $UnitPrice -Key 'DiskGBMonth' -Quantity $sizeGb
                if (-not $detail) { $detail = 'Disk is not attached to any instance but still billed.' }
            }
            'PublicIP' {
                $value = '1 address'
                $cost = Get-CloudCostUnitPrice -UnitPrice $UnitPrice -Key 'PublicIPMonth'
                if (-not $detail) { $detail = 'Public IP is reserved but not associated.' }
            }
            'IdleResource' {
                $value = 'stopped'
                if ($item.PSObject.Properties['State'] -and $item.State) { $value = [string]$item.State }
                if (-not $detail) { $detail = 'Compute is stopped; attached storage may still bill.' }
            }
            'OrphanedLoadBalancer' {
                $value = '0 targets'
                $cost = Get-CloudCostUnitPrice -UnitPrice $UnitPrice -Key 'LoadBalancerMonth'
                if (-not $detail) { $detail = 'Load balancer has no healthy backend targets.' }
            }
            default { continue }
        }

        $findings.Add((New-CloudCostFinding -Provider $Provider -Scope $Scope -Category $category `
            -Check $category -Status 'Warn' -Value $value -Resource $name -Region $region `
            -Detail $detail -EstimatedMonthlyCost $cost))
    }

    return @($findings)
}

function Get-CloudCostSummary {
    <#
    .SYNOPSIS
        Aggregates findings per provider and scope.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Finding)

    $summary = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($Finding | Group-Object -Property Provider, Target)) {
        $items = @($group.Group)
        $costs = @($items | Where-Object { $null -ne $_.EstimatedMonthlyCost })
        $total = 0.0
        foreach ($c in $costs) { $total += [double]$c.EstimatedMonthlyCost }

        $summary.Add([pscustomobject]@{
            Provider             = $items[0].Provider
            Scope                = $items[0].Target
            Fail                 = @($items | Where-Object { $_.Status -eq 'Fail' }).Count
            Warn                 = @($items | Where-Object { $_.Status -eq 'Warn' }).Count
            Pass                 = @($items | Where-Object { $_.Status -eq 'Pass' }).Count
            Findings             = $items.Count
            EstimatedMonthlyCost = $(if ($costs.Count -gt 0) { [Math]::Round($total, 2) } else { $null })
        })
    }
    return @($summary)
}

# endregion

# ============================================================================
# region  Parsers (pure)
# ============================================================================

function ConvertFrom-AzureCostResource {
    <#
    .SYNOPSIS
        Normalizes Azure disk, public IP, VM and load balancer payloads into waste inventory.
    .PARAMETER Kind
        Disk, PublicIP, VirtualMachine or LoadBalancer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Disk', 'PublicIP', 'VirtualMachine', 'LoadBalancer')][string]$Kind,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($InputObject)) {
        if (-not $item -or -not $item.name) { continue }
        $region = ''
        if ($item.PSObject.Properties['location']) { $region = [string]$item.location }

        switch ($Kind) {
            'Disk' {
                if ([string]$item.properties.diskState -ne 'Unattached') { continue }
                $result.Add([pscustomobject]@{
                    Category = 'UnattachedDisk'
                    Name     = [string]$item.name
                    Region   = $region
                    SizeGB   = [double]$item.properties.diskSizeGB
                    Detail   = "SKU $($item.sku.name); unattached."
                })
            }
            'PublicIP' {
                if ($item.properties.ipConfiguration) { continue }
                $result.Add([pscustomobject]@{
                    Category = 'PublicIP'
                    Name     = [string]$item.name
                    Region   = $region
                    Detail   = "Address $($item.properties.ipAddress); not associated."
                })
            }
            'VirtualMachine' {
                $power = ''
                foreach ($status in @($item.properties.instanceView.statuses)) {
                    if ([string]$status.code -like 'PowerState/*') { $power = ([string]$status.code) -replace '^PowerState/', '' }
                }
                if ($power -ne 'deallocated' -and $power -ne 'stopped') { continue }
                $result.Add([pscustomobject]@{
                    Category = 'IdleResource'
                    Name     = [string]$item.name
                    Region   = $region
                    State    = $power
                    Detail   = "VM power state is $power."
                })
            }
            'LoadBalancer' {
                $hasBackend = $false
                foreach ($pool in @($item.properties.backendAddressPools)) {
                    if ((Get-CloudCostItemCount $pool.properties.backendIPConfigurations) -gt 0) { $hasBackend = $true }
                    if ((Get-CloudCostItemCount $pool.properties.loadBalancerBackendAddresses) -gt 0) { $hasBackend = $true }
                }
                if ($hasBackend) { continue }
                $result.Add([pscustomobject]@{
                    Category = 'OrphanedLoadBalancer'
                    Name     = [string]$item.name
                    Region   = $region
                    Detail   = 'No backend pool members.'
                })
            }
        }
    }

    return @($result)
}

function ConvertFrom-AzureUsageQuota {
    <#
    .SYNOPSIS
        Normalizes an Azure usages payload into quota records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [string]$Region = ''
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($InputObject)) {
        if (-not $item) { continue }
        $name = ''
        if ($item.name -and $item.name.localizedValue) { $name = [string]$item.name.localizedValue }
        elseif ($item.name -and $item.name.value) { $name = [string]$item.name.value }
        elseif ($item.name) { $name = [string]$item.name }
        if (-not $name) { continue }

        $result.Add([pscustomobject]@{
            Name    = $name
            Current = [double]$item.currentValue
            Limit   = [double]$item.limit
            Region  = $Region
        })
    }
    return @($result)
}

function ConvertFrom-AwsCostResource {
    <#
    .SYNOPSIS
        Normalizes AWS EC2 and ELB query-API payloads into waste inventory.
    .PARAMETER Kind
        Volume, Address, Instance, ReservedInstance or LoadBalancer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Volume', 'Address', 'Instance', 'ReservedInstance', 'LoadBalancer')][string]$Kind,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [string]$Region = ''
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($InputObject)) {
        if (-not $item) { continue }

        switch ($Kind) {
            'Volume' {
                if ([string]$item.status -ne 'available') { continue }
                $result.Add([pscustomobject]@{
                    Category = 'UnattachedDisk'
                    Name     = [string]$item.volumeId
                    Region   = $Region
                    SizeGB   = [double]$item.size
                    Detail   = "Type $($item.volumeType); status available."
                })
            }
            'Address' {
                if ($item.instanceId -or $item.associationId -or $item.networkInterfaceId) { continue }
                $result.Add([pscustomobject]@{
                    Category = 'PublicIP'
                    Name     = [string]$item.publicIp
                    Region   = $Region
                    Detail   = 'Elastic IP allocated but not associated.'
                })
            }
            'Instance' {
                $state = ''
                if ($item.instanceState -and $item.instanceState.name) { $state = [string]$item.instanceState.name }
                elseif ($item.state -and $item.state.name) { $state = [string]$item.state.name }
                if ($state -ne 'stopped') { continue }
                $result.Add([pscustomobject]@{
                    Category = 'IdleResource'
                    Name     = [string]$item.instanceId
                    Region   = $Region
                    State    = $state
                    Detail   = "Instance type $($item.instanceType) is stopped; EBS still bills."
                })
            }
            'ReservedInstance' {
                $result.Add([pscustomobject]@{
                    Category  = 'Reservation'
                    Name      = [string]$item.reservedInstancesId
                    Region    = $Region
                    ExpiresOn = $item.end
                    Detail    = "$($item.instanceType) x$($item.instanceCount)"
                })
            }
            'LoadBalancer' {
                if ((Get-CloudCostItemCount $item.instances) -gt 0) { continue }
                $result.Add([pscustomobject]@{
                    Category = 'OrphanedLoadBalancer'
                    Name     = [string]$item.loadBalancerName
                    Region   = $Region
                    Detail   = 'No registered instances.'
                })
            }
        }
    }

    return @($result)
}

function ConvertFrom-OciCostResource {
    <#
    .SYNOPSIS
        Normalizes OCI volume, public IP, instance and load balancer objects.
    .PARAMETER Kind
        Volume, PublicIP, Instance or LoadBalancer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Volume', 'PublicIP', 'Instance', 'LoadBalancer')][string]$Kind,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [string]$Region = '',
        [string[]]$AttachedVolumeId = @()
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($InputObject)) {
        if (-not $item) { continue }

        switch ($Kind) {
            'Volume' {
                $id = [string]$item.Id
                if ($AttachedVolumeId -contains $id) { continue }
                if ([string]$item.LifecycleState -ne 'AVAILABLE') { continue }
                $result.Add([pscustomobject]@{
                    Category = 'UnattachedDisk'
                    Name     = [string]$item.DisplayName
                    Region   = $Region
                    SizeGB   = [double]$item.SizeInGBs
                    Detail   = 'Block volume is available but not attached.'
                })
            }
            'PublicIP' {
                if ($item.PrivateIpId) { continue }
                $result.Add([pscustomobject]@{
                    Category = 'PublicIP'
                    Name     = [string]$item.DisplayName
                    Region   = $Region
                    Detail   = "Reserved public IP $($item.IpAddress) is unassigned."
                })
            }
            'Instance' {
                $state = [string]$item.LifecycleState
                if ($state -ne 'STOPPED') { continue }
                $result.Add([pscustomobject]@{
                    Category = 'IdleResource'
                    Name     = [string]$item.DisplayName
                    Region   = $Region
                    State    = $state
                    Detail   = "Shape $($item.Shape) is stopped."
                })
            }
            'LoadBalancer' {
                $hasBackend = $false
                foreach ($property in @($item.BackendSets.PSObject.Properties)) {
                    if ((Get-CloudCostItemCount $property.Value.Backends) -gt 0) { $hasBackend = $true }
                }
                if ($hasBackend) { continue }
                $result.Add([pscustomobject]@{
                    Category = 'OrphanedLoadBalancer'
                    Name     = [string]$item.DisplayName
                    Region   = $Region
                    Detail   = 'No backends configured.'
                })
            }
        }
    }

    return @($result)
}

# endregion

# ============================================================================
# region  Collectors (require live credentials)
# ============================================================================

function Get-AzureCostQuotaFinding {
    <#
    .SYNOPSIS
        Collects Azure budget, quota and waste findings for one subscription.
    .DESCRIPTION
        Requires an authenticated session created by Connect-AzureServicePrincipalREST.
        Every query is wrapped so a missing permission degrades to one Unknown
        finding instead of aborting discovery.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [string]$SubscriptionName,
        [string[]]$QuotaLocation = @('eastus'),
        [hashtable]$UnitPrice,
        [int]$BudgetWarnPercent = 80,
        [int]$QuotaWarnPercent = 80,
        [int]$QuotaFailPercent = 90
    )

    if (-not (Get-Command Invoke-AzureREST -ErrorAction SilentlyContinue)) {
        throw 'Invoke-AzureREST not available. Dot-source helpers/azure/AzureHelpers.ps1 first.'
    }

    $scope = $SubscriptionName
    if (-not $scope) { $scope = $SubscriptionId }
    $findings = [System.Collections.Generic.List[object]]::new()

    $safeQuery = {
        param([string]$Label, [scriptblock]$Action)
        try { return & $Action }
        catch {
            $findings.Add((New-CloudCostFinding -Provider 'Azure' -Scope $scope -Category 'Collection' `
                -Check $Label -Status 'Unknown' -Detail $_.Exception.Message))
            return @()
        }
    }

    $budgets = @(& $safeQuery 'Budgets' {
        @(Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Consumption/budgets?api-version=2024-08-01")
    })
    foreach ($budget in @($budgets)) {
        if (-not $budget.name) { continue }
        $forecast = $null
        if ($budget.properties.forecastSpend -and $budget.properties.forecastSpend.amount) {
            $forecast = [double]$budget.properties.forecastSpend.amount
        }
        $currency = ''
        if ($budget.properties.currentSpend -and $budget.properties.currentSpend.unit) {
            $currency = [string]$budget.properties.currentSpend.unit
        }
        $findings.Add((Test-CloudBudgetStatus -Provider 'Azure' -Scope $scope -Name ([string]$budget.name) `
            -Limit ([double]$budget.properties.amount) `
            -CurrentSpend ([double]$budget.properties.currentSpend.amount) `
            -ForecastSpend $forecast -Currency $currency -WarnPercent $BudgetWarnPercent))
    }

    foreach ($location in @($QuotaLocation)) {
        $usages = @(& $safeQuery "Compute quota ($location)" {
            @(Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Compute/locations/${location}/usages?api-version=2024-07-01")
        })
        foreach ($quota in @(ConvertFrom-AzureUsageQuota -InputObject $usages -Region $location)) {
            $findings.Add((Test-CloudQuotaUsage -Provider 'Azure' -Scope $scope -Name $quota.Name `
                -Current $quota.Current -Limit $quota.Limit -Region $location `
                -WarnPercent $QuotaWarnPercent -FailPercent $QuotaFailPercent))
        }
    }

    $disks = @(& $safeQuery 'Disks' {
        @(Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Compute/disks?api-version=2024-03-02")
    })
    $publicIps = @(& $safeQuery 'Public IP addresses' {
        @(Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Network/publicIPAddresses?api-version=2024-05-01")
    })
    $vms = @(& $safeQuery 'Virtual machines' {
        @(Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01&statusOnly=true")
    })
    $loadBalancers = @(& $safeQuery 'Load balancers' {
        @(Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Network/loadBalancers?api-version=2024-05-01")
    })

    $waste = @()
    $waste += @(ConvertFrom-AzureCostResource -Kind 'Disk' -InputObject $disks)
    $waste += @(ConvertFrom-AzureCostResource -Kind 'PublicIP' -InputObject $publicIps)
    $waste += @(ConvertFrom-AzureCostResource -Kind 'VirtualMachine' -InputObject $vms)
    $waste += @(ConvertFrom-AzureCostResource -Kind 'LoadBalancer' -InputObject $loadBalancers)
    foreach ($finding in @(Get-CloudWasteFinding -Provider 'Azure' -Scope $scope -Resource $waste -UnitPrice $UnitPrice)) {
        $findings.Add($finding)
    }

    $reservations = @(& $safeQuery 'Reservations' {
        @(Invoke-AzureREST -Uri "https://management.azure.com/providers/Microsoft.Capacity/reservationOrders?api-version=2022-11-01")
    })
    foreach ($order in @($reservations)) {
        if (-not $order.name) { continue }
        $findings.Add((Get-CloudReservationStatus -Provider 'Azure' -Scope $scope `
            -Name ([string]$order.properties.displayName) -ExpiresOn $order.properties.expiryDate))
    }

    return @($findings)
}

function Get-AWSCostQuotaFinding {
    <#
    .SYNOPSIS
        Collects AWS waste and reservation findings for one region.
    .DESCRIPTION
        Requires an authenticated session created by Connect-AWSProfileREST.

        Spend is reported through the CloudWatch AWS/Billing EstimatedCharges
        metric, which the existing SigV4 query-API signer supports. Cost Explorer
        and Service Quotas use JSON protocols that the current signer does not
        implement, so they are intentionally not called.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Region,
        [string]$AccountName,
        [hashtable]$UnitPrice,
        [int]$ReservationWarnDays = 60,
        [int]$ReservationFailDays = 30
    )

    if (-not (Get-Command Invoke-AWSREST -ErrorAction SilentlyContinue)) {
        throw 'Invoke-AWSREST not available. Dot-source helpers/aws/AWSHelpers.ps1 first.'
    }

    $scope = $AccountName
    if (-not $scope) { $scope = "AWS $Region" }
    $findings = [System.Collections.Generic.List[object]]::new()

    $safeQuery = {
        param([string]$Label, [scriptblock]$Action)
        try { return & $Action }
        catch {
            $findings.Add((New-CloudCostFinding -Provider 'AWS' -Scope $scope -Category 'Collection' `
                -Check $Label -Status 'Unknown' -Region $Region -Detail $_.Exception.Message))
            return @()
        }
    }

    $volumes = @(& $safeQuery 'EBS volumes' {
        $response = Invoke-AWSREST -Service 'ec2' -Action 'DescribeVolumes' -Version '2016-11-15' -Region $Region
        @($response.DescribeVolumesResponse.volumeSet.item)
    })
    $addresses = @(& $safeQuery 'Elastic IP addresses' {
        $response = Invoke-AWSREST -Service 'ec2' -Action 'DescribeAddresses' -Version '2016-11-15' -Region $Region
        @($response.DescribeAddressesResponse.addressesSet.item)
    })
    $instances = @(& $safeQuery 'EC2 instances' {
        $response = Invoke-AWSREST -Service 'ec2' -Action 'DescribeInstances' -Version '2016-11-15' -Region $Region
        @($response.DescribeInstancesResponse.reservationSet.item.instancesSet.item)
    })
    $loadBalancers = @(& $safeQuery 'Load balancers' {
        $response = Invoke-AWSREST -Service 'elasticloadbalancing' -Action 'DescribeLoadBalancers' -Version '2012-06-01' -Region $Region
        @($response.DescribeLoadBalancersResponse.DescribeLoadBalancersResult.LoadBalancerDescriptions.member)
    })

    $waste = @()
    $waste += @(ConvertFrom-AwsCostResource -Kind 'Volume' -InputObject $volumes -Region $Region)
    $waste += @(ConvertFrom-AwsCostResource -Kind 'Address' -InputObject $addresses -Region $Region)
    $waste += @(ConvertFrom-AwsCostResource -Kind 'Instance' -InputObject $instances -Region $Region)
    $waste += @(ConvertFrom-AwsCostResource -Kind 'LoadBalancer' -InputObject $loadBalancers -Region $Region)
    foreach ($finding in @(Get-CloudWasteFinding -Provider 'AWS' -Scope $scope -Resource $waste -UnitPrice $UnitPrice)) {
        $findings.Add($finding)
    }

    $reserved = @(& $safeQuery 'Reserved instances' {
        $response = Invoke-AWSREST -Service 'ec2' -Action 'DescribeReservedInstances' -Version '2016-11-15' -Region $Region
        @($response.DescribeReservedInstancesResponse.reservedInstancesSet.item)
    })
    foreach ($item in @(ConvertFrom-AwsCostResource -Kind 'ReservedInstance' -InputObject $reserved -Region $Region)) {
        $findings.Add((Get-CloudReservationStatus -Provider 'AWS' -Scope $scope -Name $item.Name `
            -ExpiresOn $item.ExpiresOn -WarnDays $ReservationWarnDays -FailDays $ReservationFailDays))
    }

    return @($findings)
}

function Get-OCICostQuotaFinding {
    <#
    .SYNOPSIS
        Collects OCI quota and waste findings for one compartment.
    .DESCRIPTION
        Uses the OCI.PSModules cmdlets already required by OCI discovery. Each
        cmdlet is probed with Get-Command so an older module version degrades to
        an Unknown finding rather than terminating the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CompartmentId,
        [string]$CompartmentName,
        [string]$Region = '',
        [hashtable]$UnitPrice
    )

    $scope = $CompartmentName
    if (-not $scope) { $scope = $CompartmentId }
    $findings = [System.Collections.Generic.List[object]]::new()

    $safeQuery = {
        param([string]$Label, [string]$CommandName, [scriptblock]$Action)
        if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
            $findings.Add((New-CloudCostFinding -Provider 'OCI' -Scope $scope -Category 'Collection' `
                -Check $Label -Status 'Unknown' -Region $Region -Detail "Cmdlet not available: $CommandName"))
            return @()
        }
        try { return & $Action }
        catch {
            $findings.Add((New-CloudCostFinding -Provider 'OCI' -Scope $scope -Category 'Collection' `
                -Check $Label -Status 'Unknown' -Region $Region -Detail $_.Exception.Message))
            return @()
        }
    }

    $attachments = @(& $safeQuery 'Volume attachments' 'Get-OCIComputeVolumeAttachmentsList' {
        @(Get-OCIComputeVolumeAttachmentsList -CompartmentId $CompartmentId -ErrorAction Stop)
    })
    $attachedIds = @(@($attachments) | ForEach-Object { [string]$_.VolumeId } | Where-Object { $_ })

    $volumes = @(& $safeQuery 'Block volumes' 'Get-OCIBlockstorageVolumesList' {
        @(Get-OCIBlockstorageVolumesList -CompartmentId $CompartmentId -ErrorAction Stop)
    })
    $publicIps = @(& $safeQuery 'Public IP addresses' 'Get-OCIVirtualNetworkPublicIpsList' {
        @(Get-OCIVirtualNetworkPublicIpsList -CompartmentId $CompartmentId -Scope 'REGION' -ErrorAction Stop)
    })
    $instances = @(& $safeQuery 'Compute instances' 'Get-OCIComputeInstancesList' {
        @(Get-OCIComputeInstancesList -CompartmentId $CompartmentId -ErrorAction Stop)
    })
    $loadBalancers = @(& $safeQuery 'Load balancers' 'Get-OCILoadBalancerLoadBalancersList' {
        @(Get-OCILoadBalancerLoadBalancersList -CompartmentId $CompartmentId -ErrorAction Stop)
    })

    $waste = @()
    $waste += @(ConvertFrom-OciCostResource -Kind 'Volume' -InputObject $volumes -Region $Region -AttachedVolumeId $attachedIds)
    $waste += @(ConvertFrom-OciCostResource -Kind 'PublicIP' -InputObject $publicIps -Region $Region)
    $waste += @(ConvertFrom-OciCostResource -Kind 'Instance' -InputObject $instances -Region $Region)
    $waste += @(ConvertFrom-OciCostResource -Kind 'LoadBalancer' -InputObject $loadBalancers -Region $Region)
    foreach ($finding in @(Get-CloudWasteFinding -Provider 'OCI' -Scope $scope -Resource $waste -UnitPrice $UnitPrice)) {
        $findings.Add($finding)
    }

    return @($findings)
}

# endregion

# ============================================================================
# region  Output
# ============================================================================

function New-CloudCostMonitorItem {
    <#
    .SYNOPSIS
        Builds WUG performance monitor definitions for spend and quota findings.
    .DESCRIPTION
        Azure budgets expose clean numeric JSON, so they become RestApi monitors.
        AWS account spend uses the CloudWatch AWS/Billing EstimatedCharges metric.
        Returns hashtables shaped for New-DiscoveredItem.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Azure', 'AWS')][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Scope,
        [string]$SubscriptionId,
        [string]$BudgetName,
        [string]$Currency = 'USD'
    )

    $items = [System.Collections.Generic.List[object]]::new()

    if ($Provider -eq 'Azure') {
        if (-not $SubscriptionId -or -not $BudgetName) { throw 'Azure monitors require -SubscriptionId and -BudgetName.' }
        $budgetUrl = "https://management.azure.com/subscriptions/${SubscriptionId}/providers/Microsoft.Consumption/budgets/$([uri]::EscapeDataString($BudgetName))?api-version=2024-08-01"

        $map = @(
            @{ Metric = 'CurrentSpend'; Path = '$.properties.currentSpend.amount'; Label = 'Current Spend' },
            @{ Metric = 'BudgetLimit'; Path = '$.properties.amount'; Label = 'Budget Limit' },
            @{ Metric = 'ForecastSpend'; Path = '$.properties.forecastSpend.amount'; Label = 'Forecast Spend' }
        )
        foreach ($entry in $map) {
            $items.Add(@{
                Name          = "Azure Billing - $($entry.Label) - $BudgetName ($Scope)"
                ItemType      = 'PerformanceMonitor'
                MonitorType   = 'RestApi'
                UniqueKey     = "Azure:${SubscriptionId}:billing:${BudgetName}:$($entry.Metric)"
                MonitorParams = @{
                    RestApiUrl                = $budgetUrl
                    RestApiJsonPath           = $entry.Path
                    RestApiHttpMethod         = 'GET'
                    RestApiHttpTimeoutMs      = '15000'
                    RestApiUseAnonymousAccess = '0'
                    _MetricName               = $entry.Metric
                    _MetricDisplayName        = "$($entry.Label) - $BudgetName"
                    _Aggregation              = 'Total'
                    _JsonField                = 'amount'
                }
            })
        }
    }
    else {
        $items.Add(@{
            Name          = "AWS Billing - Estimated Charges ($Scope)"
            ItemType      = 'PerformanceMonitor'
            MonitorType   = 'CloudWatch'
            UniqueKey     = "AWS:${Scope}:billing:EstimatedCharges"
            MonitorParams = @{
                # Billing metrics are published only to us-east-1.
                CloudWatchNamespace  = 'AWS/Billing'
                CloudWatchMetric     = 'EstimatedCharges'
                CloudWatchRegion     = 'us-east-1'
                CloudWatchStatistic  = 'Maximum'
                CloudWatchDimensions = "Currency=$Currency"
            }
        })
    }

    return @($items)
}

function Export-CloudCostDashboard {
    <#
    .SYNOPSIS
        Renders cost, quota and waste findings using the shared dashboard template.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Finding,
        [string]$OutputPath,
        [string]$ReportTitle = 'Cloud Cost and Quota',
        [string]$RepoRoot
    )

    if (@($Finding).Count -eq 0) { throw 'No findings to render.' }
    if (-not $OutputPath) { $OutputPath = Join-Path $env:TEMP 'Cloud-Cost-Dashboard.html' }
    if (-not $RepoRoot) { $RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

    $exporter = Join-Path $RepoRoot 'helpers\reports\Export-DynamicDashboardHtml.ps1'
    $template = Join-Path $RepoRoot 'helpers\reports\Dynamic-Dashboard-Template.html'
    if (-not (Test-Path -LiteralPath $exporter)) { throw "Dashboard generator not found: $exporter" }
    if (-not (Get-Command Export-DynamicDashboardHtml -ErrorAction SilentlyContinue)) { . $exporter }

    Set-StrictMode -Off
    $Finding | Export-DynamicDashboardHtml -OutputPath $OutputPath -ReportTitle $ReportTitle `
        -CardField @('Status', 'Category', 'Provider') -StatusField 'Status' `
        -ExportPrefix 'cloud_cost' -TemplatePath $template | Out-Null

    return $OutputPath
}

# endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCACJ7qTreiBgr3H
# xjE6jI/jwbwDqdHkwl5Ccqh2keYAtKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDm1+ADZgYAiIq1AdtBb6QmumtUvkRhAUiQO7YWkFgirDANBgkqhkiG9w0BAQEF
# AASCAgA6MjkcVlBkZ+I1x8v5qUErxs0fvxWS44+Bxp9rFE+kexvmqXvyo3xTUo4S
# XVJUS0h/vBfvD93W+9i6GKgXYsyYxdlnjTe/OBc0h00lcJT5ZIRoTbXEhqdjb17y
# bH/kGE3Fd8SMj0+hDtoBJG2ijAMVl2m1mUqRTKSIj5TylXJTxTT+Xldy9k0N4flx
# Yn/qNRzv3TKykOVeVl9iS0kn1gX8PgvRb5kfyHHzcgx6yl81UZAipt8My8xVDLlV
# OfcAX6LJmk4CXyBBzEGoFGxjZC1hB+2qNPbesXalKfcldXa8/C7onmDNR5iZflrR
# /znmfUU75+u2jynU0Ibabzoz3MwhVi6HQxB2RS8t0IbpU0Min3mNq1FtFBq9ekRG
# KftZB6IaHzLBUQHoQPQToirTn7g11U5bizdDbFaD3Jxk+Nb9+wxXWiVTY2O3BNEH
# 9kT5RqvGEZSpDw32oCm5OAKkTFQq2E6Mfz8cZzv8QcjpXYLXNF0wvOojUyLGgR46
# nN/A8SHqqfhf2GajyAQ6dNyTF8fmvybDxw/ZPq83YUpGZRXNLdYkNf9yfxc1hdl6
# Qt8Cf9uBBVtQHY6uIkrGhGZKrI4EYjLxBN/ZB0d1CiNw7QVeGC5ZeWR5W1GvB4SP
# cM/ziU8clx8Hc6N8CsVq+Wjj64BF4OzX/C2X22TnkVqfZ6pE56GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkyMDExMjhaMC8GCSqGSIb3DQEJBDEiBCDblofC
# Kmt/Gy23guPVhtdyFiPygEOyIF0Oy33OofZISjANBgkqhkiG9w0BAQEFAASCAgBi
# SiF1QpMiTGr/iRVVz0hyaf5M1o8zgNxCE3jg05nssowhbvYlL/LQ8YitNOrsewWX
# 4gmfGXaQq1qRSy94Y0C1MCI+iy2HivmeGJkAnqD9SZsbL/y/jOts6GaTZYkfjni5
# eG+1OwYtMuq4rPjCLJ+4ICKGzyYCO2EAkJh7ZnpLfj119Syz90PE9UBXN6EmTzXO
# 6IiAwhPVCZ8mgEk6a3i5hUjyCt9Bm+ZTCxPdglso9iTIyVvHvK3WS9jkNXsbBErf
# WGGBsh9ssv0g1AoIk08CDBUyae56o05R8wmaMdOswOoBZR8zoqCpt+/VYtaimmeZ
# QeXoYHg1DMB6OZN7EZOK9mjFLerK/txwgvrDJH2ZZ2kGFGdlTgnIMNMDkdpPPhSP
# XIn7dTG0nX1E+9JcZhminbR5926FcqRETXawo5YKUWLHBGG6agrEnTfR/gQBHRE1
# 8yrw09JljVaJsGlDz7Q/LHRw0k4e9TUpZXszuZdMH7hGJyT/FpqngvksvRsjzIuk
# SirXmPho7gpbGeXTPzfk+atOn9SAkZiw9Nm9iYWegbG6g7QAp5yWJ/5hIPWAYsTN
# r8esS7Ijml4quXox0OQjiH2NniBxk4uXpn4+AsbStr5pMKw9FAwSkT87aY6Z3SDH
# ZrysQzVDK2IpwQflN3WpL1ZfynOBHE3rTDLKn+02Eg==
# SIG # End signature block
