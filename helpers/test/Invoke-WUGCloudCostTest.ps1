#requires -Version 5.1
<#
.SYNOPSIS
    Offline test harness for the cloud cost, quota and waste helpers.
.DESCRIPTION
    Exercises the parsers and threshold analyzers in
    helpers/discovery/CloudCostHelpers.ps1 using canned Azure, AWS and OCI
    payloads. No cloud subscription, credentials or network access required.

    The collector layer (Get-*CostQuotaFinding) is not exercised here because it
    requires live cloud credentials; only its presence and guards are checked.
.EXAMPLE
    .\Invoke-WUGCloudCostTest.ps1
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+
#>
[CmdletBinding()]
param()

$script:Passed = 0
$script:Failed = 0

function Record-Test {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    if ($Status -eq 'Pass') { $script:Passed++; $color = 'Green' } else { $script:Failed++; $color = 'Red' }
    Write-Host "  [$Status] $Name  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    try {
        $null = & $Test
        Record-Test -Name $Name -Status 'Pass'
    }
    catch {
        Record-Test -Name $Name -Status 'Fail' -Detail $_.Exception.Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$(if ($Message) { $Message + ': ' })Expected '$Expected' but got '$Actual'"
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message = 'Expected true but got false')
    if (-not $Value) { throw $Message }
}

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
$helpersFile = Join-Path $repoRoot 'helpers\discovery\CloudCostHelpers.ps1'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Cloud Cost and Quota Test Harness' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

try {
    . $helpersFile
    Record-Test -Name 'Load CloudCostHelpers.ps1' -Status 'Pass'
}
catch {
    Record-Test -Name 'Load CloudCostHelpers.ps1' -Status 'Fail' -Detail $_.Exception.Message
    Write-Host 'FATAL: helpers failed to load.' -ForegroundColor Red
    return
}

Write-Host ''
Write-Host '--- Budget thresholds ---' -ForegroundColor Cyan

Invoke-Test -Name 'Spend well under budget passes' -Test {
    $f = Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Monthly' -Limit 1000 -CurrentSpend 250
    Assert-Equal 'Pass' $f.Status
    Assert-Equal '25%' $f.Value
}

Invoke-Test -Name 'Spend at 80 percent warns' -Test {
    Assert-Equal 'Warn' (Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Monthly' -Limit 1000 -CurrentSpend 800).Status
}

Invoke-Test -Name 'Spend over budget fails' -Test {
    $f = Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Monthly' -Limit 1000 -CurrentSpend 1150
    Assert-Equal 'Fail' $f.Status
    Assert-Equal '115%' $f.Value
}

Invoke-Test -Name 'Forecast overrun warns even when spend is low' -Test {
    $f = Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Monthly' -Limit 1000 -CurrentSpend 400 -ForecastSpend 1400
    Assert-Equal 'Warn' $f.Status
    Assert-True ($f.Detail -like '*Forecast 1400*') 'forecast should be reported'
}

Invoke-Test -Name 'Zero budget limit is Unknown, not divide-by-zero' -Test {
    Assert-Equal 'Unknown' (Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Broken' -Limit 0 -CurrentSpend 10).Status
}

Write-Host ''
Write-Host '--- Quota thresholds ---' -ForegroundColor Cyan

Invoke-Test -Name 'Quota headroom passes' -Test {
    Assert-Equal 'Pass' (Test-CloudQuotaUsage -Provider Azure -Scope 'Prod' -Name 'vCPUs' -Current 10 -Limit 100).Status
}

Invoke-Test -Name 'Quota near limit warns' -Test {
    Assert-Equal 'Warn' (Test-CloudQuotaUsage -Provider Azure -Scope 'Prod' -Name 'vCPUs' -Current 85 -Limit 100).Status
}

Invoke-Test -Name 'Quota at limit fails' -Test {
    $f = Test-CloudQuotaUsage -Provider Azure -Scope 'Prod' -Name 'vCPUs' -Current 95 -Limit 100
    Assert-Equal 'Fail' $f.Status
    Assert-Equal '95%' $f.Value
}

Invoke-Test -Name 'Unlimited quota reports Info' -Test {
    Assert-Equal 'Info' (Test-CloudQuotaUsage -Provider AWS -Scope 'Acct' -Name 'Unlimited' -Current 5 -Limit 0).Status
}

Write-Host ''
Write-Host '--- Reservation expiry ---' -ForegroundColor Cyan

$now = Get-Date '2026-09-29'

Invoke-Test -Name 'Distant expiry passes' -Test {
    Assert-Equal 'Pass' (Get-CloudReservationStatus -Provider AWS -Scope 'Acct' -Name 'RI-1' -ExpiresOn $now.AddDays(200) -ReferenceTime $now).Status
}

Invoke-Test -Name 'Expiry inside 60 days warns' -Test {
    Assert-Equal 'Warn' (Get-CloudReservationStatus -Provider AWS -Scope 'Acct' -Name 'RI-2' -ExpiresOn $now.AddDays(45) -ReferenceTime $now).Status
}

Invoke-Test -Name 'Expiry inside 30 days fails' -Test {
    $f = Get-CloudReservationStatus -Provider AWS -Scope 'Acct' -Name 'RI-3' -ExpiresOn $now.AddDays(10) -ReferenceTime $now
    Assert-Equal 'Fail' $f.Status
    Assert-Equal '10 days' $f.Value
}

Invoke-Test -Name 'Missing expiry is Unknown' -Test {
    Assert-Equal 'Unknown' (Get-CloudReservationStatus -Provider AWS -Scope 'Acct' -Name 'RI-4' -ExpiresOn $null).Status
}

Write-Host ''
Write-Host '--- Azure parsers ---' -ForegroundColor Cyan

$azureDisks = @(
    [pscustomobject]@{ name = 'disk-orphan'; location = 'eastus'; sku = @{ name = 'Premium_LRS' }; properties = [pscustomobject]@{ diskState = 'Unattached'; diskSizeGB = 128 } },
    [pscustomobject]@{ name = 'disk-in-use'; location = 'eastus'; sku = @{ name = 'Premium_LRS' }; properties = [pscustomobject]@{ diskState = 'Attached'; diskSizeGB = 256 } }
)

Invoke-Test -Name 'Only unattached Azure disks are reported' -Test {
    $r = @(ConvertFrom-AzureCostResource -Kind 'Disk' -InputObject $azureDisks)
    Assert-Equal 1 $r.Count
    Assert-Equal 'disk-orphan' $r[0].Name
    Assert-Equal 128 $r[0].SizeGB
}

$azureIps = @(
    [pscustomobject]@{ name = 'ip-idle'; location = 'eastus'; properties = [pscustomobject]@{ ipAddress = '20.1.2.3'; ipConfiguration = $null } },
    [pscustomobject]@{ name = 'ip-used'; location = 'eastus'; properties = [pscustomobject]@{ ipAddress = '20.1.2.4'; ipConfiguration = [pscustomobject]@{ id = '/nic/1' } } }
)

Invoke-Test -Name 'Only unassociated Azure public IPs are reported' -Test {
    $r = @(ConvertFrom-AzureCostResource -Kind 'PublicIP' -InputObject $azureIps)
    Assert-Equal 1 $r.Count
    Assert-Equal 'ip-idle' $r[0].Name
}

$azureVms = @(
    [pscustomobject]@{ name = 'vm-stopped'; location = 'eastus'; properties = [pscustomobject]@{ instanceView = [pscustomobject]@{ statuses = @([pscustomobject]@{ code = 'PowerState/deallocated' }) } } },
    [pscustomobject]@{ name = 'vm-running'; location = 'eastus'; properties = [pscustomobject]@{ instanceView = [pscustomobject]@{ statuses = @([pscustomobject]@{ code = 'PowerState/running' }) } } }
)

Invoke-Test -Name 'Only deallocated Azure VMs are reported' -Test {
    $r = @(ConvertFrom-AzureCostResource -Kind 'VirtualMachine' -InputObject $azureVms)
    Assert-Equal 1 $r.Count
    Assert-Equal 'vm-stopped' $r[0].Name
    Assert-Equal 'deallocated' $r[0].State
}

$azureLbs = @(
    [pscustomobject]@{ name = 'lb-empty'; location = 'eastus'; properties = [pscustomobject]@{ backendAddressPools = @([pscustomobject]@{ properties = [pscustomobject]@{ backendIPConfigurations = @() } }) } },
    [pscustomobject]@{ name = 'lb-used'; location = 'eastus'; properties = [pscustomobject]@{ backendAddressPools = @([pscustomobject]@{ properties = [pscustomobject]@{ backendIPConfigurations = @([pscustomobject]@{ id = '/nic/1' }) } }) } }
)

Invoke-Test -Name 'Only empty Azure load balancers are reported' -Test {
    $r = @(ConvertFrom-AzureCostResource -Kind 'LoadBalancer' -InputObject $azureLbs)
    Assert-Equal 1 $r.Count
    Assert-Equal 'lb-empty' $r[0].Name
}

Invoke-Test -Name 'Azure usage payload becomes quota records' -Test {
    $usages = @(
        [pscustomobject]@{ name = [pscustomobject]@{ localizedValue = 'Total Regional vCPUs'; value = 'cores' }; currentValue = 90; limit = 100 },
        [pscustomobject]@{ name = [pscustomobject]@{ localizedValue = 'Virtual Machines'; value = 'vm' }; currentValue = 5; limit = 25000 }
    )
    $r = @(ConvertFrom-AzureUsageQuota -InputObject $usages -Region 'eastus')
    Assert-Equal 2 $r.Count
    Assert-Equal 'Total Regional vCPUs' $r[0].Name
    Assert-Equal 'eastus' $r[0].Region
    Assert-Equal 'Fail' (Test-CloudQuotaUsage -Provider Azure -Scope 'Prod' -Name $r[0].Name -Current $r[0].Current -Limit $r[0].Limit).Status
}

Write-Host ''
Write-Host '--- AWS parsers ---' -ForegroundColor Cyan

Invoke-Test -Name 'Only available EBS volumes are reported' -Test {
    $volumes = @(
        [pscustomobject]@{ volumeId = 'vol-aaa'; status = 'available'; size = 500; volumeType = 'gp3' },
        [pscustomobject]@{ volumeId = 'vol-bbb'; status = 'in-use'; size = 100; volumeType = 'gp3' }
    )
    $r = @(ConvertFrom-AwsCostResource -Kind 'Volume' -InputObject $volumes -Region 'us-east-1')
    Assert-Equal 1 $r.Count
    Assert-Equal 'vol-aaa' $r[0].Name
    Assert-Equal 500 $r[0].SizeGB
}

Invoke-Test -Name 'Only unassociated Elastic IPs are reported' -Test {
    $addresses = @(
        [pscustomobject]@{ publicIp = '52.1.1.1'; instanceId = $null; associationId = $null; networkInterfaceId = $null },
        [pscustomobject]@{ publicIp = '52.1.1.2'; instanceId = 'i-123'; associationId = 'eipassoc-1'; networkInterfaceId = 'eni-1' }
    )
    $r = @(ConvertFrom-AwsCostResource -Kind 'Address' -InputObject $addresses -Region 'us-east-1')
    Assert-Equal 1 $r.Count
    Assert-Equal '52.1.1.1' $r[0].Name
}

Invoke-Test -Name 'Only stopped EC2 instances are reported' -Test {
    $instances = @(
        [pscustomobject]@{ instanceId = 'i-stopped'; instanceType = 't3.large'; instanceState = [pscustomobject]@{ name = 'stopped' } },
        [pscustomobject]@{ instanceId = 'i-running'; instanceType = 't3.large'; instanceState = [pscustomobject]@{ name = 'running' } }
    )
    $r = @(ConvertFrom-AwsCostResource -Kind 'Instance' -InputObject $instances -Region 'us-east-1')
    Assert-Equal 1 $r.Count
    Assert-Equal 'i-stopped' $r[0].Name
}

Invoke-Test -Name 'Only ELBs without instances are reported' -Test {
    $lbs = @(
        [pscustomobject]@{ loadBalancerName = 'elb-empty'; instances = @() },
        [pscustomobject]@{ loadBalancerName = 'elb-used'; instances = @([pscustomobject]@{ instanceId = 'i-1' }) }
    )
    $r = @(ConvertFrom-AwsCostResource -Kind 'LoadBalancer' -InputObject $lbs -Region 'us-east-1')
    Assert-Equal 1 $r.Count
    Assert-Equal 'elb-empty' $r[0].Name
}

Invoke-Test -Name 'Reserved instances carry expiry through to findings' -Test {
    $reserved = @([pscustomobject]@{ reservedInstancesId = 'ri-1'; instanceType = 'm5.large'; instanceCount = 4; end = $now.AddDays(20) })
    $r = @(ConvertFrom-AwsCostResource -Kind 'ReservedInstance' -InputObject $reserved -Region 'us-east-1')
    Assert-Equal 1 $r.Count
    $f = Get-CloudReservationStatus -Provider AWS -Scope 'Acct' -Name $r[0].Name -ExpiresOn $r[0].ExpiresOn -ReferenceTime $now
    Assert-Equal 'Fail' $f.Status
}

Write-Host ''
Write-Host '--- OCI parsers ---' -ForegroundColor Cyan

Invoke-Test -Name 'Attached OCI volumes are excluded' -Test {
    $volumes = @(
        [pscustomobject]@{ Id = 'ocid1.volume.1'; DisplayName = 'vol-free'; LifecycleState = 'AVAILABLE'; SizeInGBs = 50 },
        [pscustomobject]@{ Id = 'ocid1.volume.2'; DisplayName = 'vol-attached'; LifecycleState = 'AVAILABLE'; SizeInGBs = 50 }
    )
    $r = @(ConvertFrom-OciCostResource -Kind 'Volume' -InputObject $volumes -Region 'us-phoenix-1' -AttachedVolumeId @('ocid1.volume.2'))
    Assert-Equal 1 $r.Count
    Assert-Equal 'vol-free' $r[0].Name
}

Invoke-Test -Name 'Only unassigned OCI public IPs are reported' -Test {
    $ips = @(
        [pscustomobject]@{ DisplayName = 'ip-free'; IpAddress = '203.0.113.5'; PrivateIpId = $null },
        [pscustomobject]@{ DisplayName = 'ip-used'; IpAddress = '203.0.113.6'; PrivateIpId = 'ocid1.privateip.1' }
    )
    $r = @(ConvertFrom-OciCostResource -Kind 'PublicIP' -InputObject $ips -Region 'us-phoenix-1')
    Assert-Equal 1 $r.Count
    Assert-Equal 'ip-free' $r[0].Name
}

Invoke-Test -Name 'Only stopped OCI instances are reported' -Test {
    $instances = @(
        [pscustomobject]@{ DisplayName = 'inst-stopped'; LifecycleState = 'STOPPED'; Shape = 'VM.Standard.E4.Flex' },
        [pscustomobject]@{ DisplayName = 'inst-running'; LifecycleState = 'RUNNING'; Shape = 'VM.Standard.E4.Flex' }
    )
    $r = @(ConvertFrom-OciCostResource -Kind 'Instance' -InputObject $instances -Region 'us-phoenix-1')
    Assert-Equal 1 $r.Count
    Assert-Equal 'inst-stopped' $r[0].Name
}

Write-Host ''
Write-Host '--- Waste findings and costing ---' -ForegroundColor Cyan

$wasteInventory = @(
    [pscustomobject]@{ Category = 'UnattachedDisk'; Name = 'disk-1'; Region = 'eastus'; SizeGB = 100 },
    [pscustomobject]@{ Category = 'PublicIP'; Name = 'ip-1'; Region = 'eastus' },
    [pscustomobject]@{ Category = 'IdleResource'; Name = 'vm-1'; Region = 'eastus'; State = 'deallocated' },
    [pscustomobject]@{ Category = 'OrphanedLoadBalancer'; Name = 'lb-1'; Region = 'eastus' }
)

Invoke-Test -Name 'Waste inventory becomes warnings' -Test {
    $f = @(Get-CloudWasteFinding -Provider Azure -Scope 'Prod' -Resource $wasteInventory)
    Assert-Equal 4 $f.Count
    Assert-Equal 4 @($f | Where-Object { $_.Status -eq 'Warn' }).Count
}

Invoke-Test -Name 'No price table means no invented cost' -Test {
    $f = @(Get-CloudWasteFinding -Provider Azure -Scope 'Prod' -Resource $wasteInventory)
    Assert-Equal 0 @($f | Where-Object { $null -ne $_.EstimatedMonthlyCost }).Count
}

Invoke-Test -Name 'Supplied rates produce cost estimates' -Test {
    $f = @(Get-CloudWasteFinding -Provider Azure -Scope 'Prod' -Resource $wasteInventory -UnitPrice @{ DiskGBMonth = 0.10; PublicIPMonth = 3.60 })
    $disk = $f | Where-Object { $_.Resource -eq 'disk-1' }
    Assert-Equal 10 $disk.EstimatedMonthlyCost
    $ip = $f | Where-Object { $_.Resource -eq 'ip-1' }
    Assert-Equal 3.6 $ip.EstimatedMonthlyCost
    $vm = $f | Where-Object { $_.Resource -eq 'vm-1' }
    Assert-True ($null -eq $vm.EstimatedMonthlyCost) 'idle compute has no flat rate'
}

Invoke-Test -Name 'Summary aggregates counts and cost' -Test {
    $f = @(Get-CloudWasteFinding -Provider Azure -Scope 'Prod' -Resource $wasteInventory -UnitPrice @{ DiskGBMonth = 0.10; PublicIPMonth = 3.60 })
    $f += Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Monthly' -Limit 100 -CurrentSpend 150
    $summary = @(Get-CloudCostSummary -Finding $f)
    Assert-Equal 1 $summary.Count
    Assert-Equal 1 $summary[0].Fail
    Assert-Equal 4 $summary[0].Warn
    Assert-Equal 13.6 $summary[0].EstimatedMonthlyCost
}

Write-Host ''
Write-Host '--- Empty and null API results ---' -ForegroundColor Cyan

# An API that returns no rows yields $null, and @($null) collapses back to $null
# during parameter binding, so every parser must accept it.
Invoke-Test -Name 'Azure parsers accept null and empty input' -Test {
    foreach ($kind in @('Disk', 'PublicIP', 'VirtualMachine', 'LoadBalancer')) {
        Assert-Equal 0 (@(ConvertFrom-AzureCostResource -Kind $kind -InputObject $null)).Count
        Assert-Equal 0 (@(ConvertFrom-AzureCostResource -Kind $kind -InputObject @($null))).Count
        Assert-Equal 0 (@(ConvertFrom-AzureCostResource -Kind $kind -InputObject @())).Count
    }
}

Invoke-Test -Name 'AWS parsers accept null and empty input' -Test {
    foreach ($kind in @('Volume', 'Address', 'Instance', 'ReservedInstance', 'LoadBalancer')) {
        Assert-Equal 0 (@(ConvertFrom-AwsCostResource -Kind $kind -InputObject $null -Region 'us-east-1')).Count
        Assert-Equal 0 (@(ConvertFrom-AwsCostResource -Kind $kind -InputObject @($null) -Region 'us-east-1')).Count
        Assert-Equal 0 (@(ConvertFrom-AwsCostResource -Kind $kind -InputObject @() -Region 'us-east-1')).Count
    }
}

Invoke-Test -Name 'OCI parsers accept null and empty input' -Test {
    foreach ($kind in @('Volume', 'PublicIP', 'Instance', 'LoadBalancer')) {
        Assert-Equal 0 (@(ConvertFrom-OciCostResource -Kind $kind -InputObject $null)).Count
        Assert-Equal 0 (@(ConvertFrom-OciCostResource -Kind $kind -InputObject @($null))).Count
    }
}

Invoke-Test -Name 'Quota and waste helpers accept null input' -Test {
    Assert-Equal 0 (@(ConvertFrom-AzureUsageQuota -InputObject $null)).Count
    Assert-Equal 0 (@(ConvertFrom-AzureUsageQuota -InputObject @($null))).Count
    Assert-Equal 0 (@(Get-CloudWasteFinding -Provider AWS -Scope 'acct' -Resource $null)).Count
    Assert-Equal 0 (@(Get-CloudCostSummary -Finding $null)).Count
}

Write-Host ''
Write-Host '--- Monitor definitions ---' -ForegroundColor Cyan

Invoke-Test -Name 'Azure budget monitors are well formed' -Test {
    $items = @(New-CloudCostMonitorItem -Provider Azure -Scope 'Prod' -SubscriptionId 'sub-1' -BudgetName 'Monthly')
    Assert-Equal 3 $items.Count
    foreach ($item in $items) {
        Assert-Equal 'PerformanceMonitor' $item.ItemType
        Assert-Equal 'RestApi' $item.MonitorType
        Assert-True ($item.MonitorParams.RestApiUrl -like '*Microsoft.Consumption/budgets/Monthly*') 'budget URL wrong'
        Assert-True ($item.MonitorParams.RestApiJsonPath -like '$.properties.*') 'json path wrong'
    }
    Assert-True (@($items | Where-Object { $_.MonitorParams.RestApiJsonPath -eq '$.properties.currentSpend.amount' }).Count -eq 1) 'missing current spend'
}

Invoke-Test -Name 'AWS billing monitor targets us-east-1' -Test {
    $items = @(New-CloudCostMonitorItem -Provider AWS -Scope 'Acct')
    Assert-Equal 1 $items.Count
    Assert-Equal 'CloudWatch' $items[0].MonitorType
    Assert-Equal 'AWS/Billing' $items[0].MonitorParams.CloudWatchNamespace
    Assert-Equal 'us-east-1' $items[0].MonitorParams.CloudWatchRegion
    Assert-Equal 'Currency=USD' $items[0].MonitorParams.CloudWatchDimensions
}

Invoke-Test -Name 'Azure monitor requires subscription and budget' -Test {
    $threw = $false
    try { New-CloudCostMonitorItem -Provider Azure -Scope 'Prod' | Out-Null } catch { $threw = $true }
    Assert-True $threw 'expected a clear parameter error'
}

Write-Host ''
Write-Host '--- Collector guards ---' -ForegroundColor Cyan

Invoke-Test -Name 'Collectors exist' -Test {
    foreach ($name in @('Get-AzureCostQuotaFinding', 'Get-AWSCostQuotaFinding', 'Get-OCICostQuotaFinding')) {
        Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "missing collector: $name"
    }
}

Invoke-Test -Name 'Azure collector fails clearly without helpers' -Test {
    if (Get-Command Invoke-AzureREST -ErrorAction SilentlyContinue) { return }
    $threw = $false
    try { Get-AzureCostQuotaFinding -SubscriptionId 'sub-1' | Out-Null }
    catch { $threw = ($_.Exception.Message -like '*Invoke-AzureREST not available*') }
    Assert-True $threw 'expected a clear helper-missing error'
}

Invoke-Test -Name 'AWS collector fails clearly without helpers' -Test {
    if (Get-Command Invoke-AWSREST -ErrorAction SilentlyContinue) { return }
    $threw = $false
    try { Get-AWSCostQuotaFinding -Region 'us-east-1' | Out-Null }
    catch { $threw = ($_.Exception.Message -like '*Invoke-AWSREST not available*') }
    Assert-True $threw 'expected a clear helper-missing error'
}

Invoke-Test -Name 'OCI collector degrades when cmdlets are absent' -Test {
    if (Get-Command Get-OCIComputeInstancesList -ErrorAction SilentlyContinue) { return }
    $f = @(Get-OCICostQuotaFinding -CompartmentId 'ocid1.compartment.1' -CompartmentName 'Test')
    Assert-True ($f.Count -gt 0) 'expected Unknown findings, not an exception'
    Assert-True (@($f | Where-Object { $_.Status -eq 'Unknown' }).Count -gt 0) 'expected Unknown status'
}

Write-Host ''
Write-Host '--- Dashboard ---' -ForegroundColor Cyan

Invoke-Test -Name 'Dashboard renders with shared template' -Test {
    $out = Join-Path $env:TEMP "cloudcost-test-$([guid]::NewGuid().ToString('N').Substring(0,8)).html"
    try {
        $f = @(Get-CloudWasteFinding -Provider Azure -Scope 'Prod' -Resource $wasteInventory)
        $f += Test-CloudBudgetStatus -Provider Azure -Scope 'Prod' -Name 'Monthly' -Limit 100 -CurrentSpend 150
        Export-CloudCostDashboard -Finding $f -OutputPath $out -RepoRoot $repoRoot | Out-Null
        Assert-True (Test-Path -LiteralPath $out) 'dashboard not created'
        $html = Get-Content -LiteralPath $out -Raw
        Assert-True ($html -match 'WhatsUpGoldPS') 'branding missing'
        Assert-True ($html -match 'Cloud Cost and Quota') 'title missing'
        Assert-Equal 0 ([regex]::Matches($html, 'replace\w+Here')).Count 'unreplaced placeholders'
    }
    finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name 'Empty finding set fails clearly' -Test {
    $threw = $false
    try { Export-CloudCostDashboard -Finding @() | Out-Null } catch { $threw = $true }
    Assert-True $threw 'expected an error for empty input'
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed   Failed: $script:Failed" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host '============================================================' -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAtfe/yNmTX47zT
# yegDCzIb3ShiZL1ahPMUvSrXYdCB4aCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCBmezPO4VcPR153FStJwpUV/Y3i5FhWct18NYJ2l1b5jANBgkqhkiG9w0BAQEF
# AASCAgB0IrPfWsncVkkhbhwAI5XxKODXMfsuFnnB2FAdnhgvGjjqF/LrhnMQmYze
# ETzMGjiFR1m3CufkJpoCjvJGrz6oF/cNEuYJpVeXB19j76NAy0XVTsyoc4pRHz+i
# x3rYX97Vsp81FHzTwzfouc2xbEd1kLyzORxXQgifFHJRGAH3Qf/xbzu7P5Mp8RII
# qGE2TT5lVt/HkXoE7OwxAuy6Xg/ry8+WA2SGypf+qz6BWyNpZN7dAThtqX/Vtg/Y
# rmHK9qNsPjG/cGh5Nuvfen1JIjV8sz6E0JvsN5ART42EonBrT38aZxJOVtdVmzqE
# GXjD7Izo7hKakrmVd4wr/1nRniwL5n0ENc8ItKfHjSPYx7ZP29tPoIXLC0ugo+vD
# 5uK4VO2HI7JavmY6f6BeNu5i6TySt33dVH5sFhcjgoe510pnEIkxAQsOLYmR3pQa
# 2RiH7EoAT1ph+ASVWybhnQFgpY7ReJWOM/Ywyf0V7xhrF0qsqIVSNwv28Nu4b5+C
# iU8KVYT6HqX40N6ELE+2EMYSmRK6g4sny3S6nXili1FeXnN17ijwIrJ03m62DYWu
# RG6W7I+sPHwAN92idT16rEgJenvIa07K3Tc2MVPCkU5MujqT/7dp6kS93qy+kO8x
# 6ByinIPhQygtwkkV8wuGz5DPeAZIMdMaLKgXxVjMyBOkGaGV86GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkyMDExMzFaMC8GCSqGSIb3DQEJBDEiBCAvn5+3
# bdz3PIUv0/4sI4cTCaQnZgM39aIKvkzB8mXduTANBgkqhkiG9w0BAQEFAASCAgBj
# +i5nmwH1OdLaci+RU/T3z+MnKigtG1fYOvnqY1/eeyVkYOUsDPdaoi1WUCXagCBy
# uKaXFGNmLYxo/8YKr3N1QU8MwfJvC5bk51InBqqDQG9HI6ROOVn9hDS34qXOwvmb
# U9eIazYzlCUDEAMbzjrsmbNYtSfUMxslUIEHx7tWjnib046MFIaaP+qmxp9QuVP4
# zTsmOySUbfUzCSVXrzZ8x41vxXZb5iM2DnYRlxXrDqzqYmWevABAV9XhXx1+I1vl
# 7pEj1TvZ4tc3ZgT5OFRR7/lmUVLMFTSP7ikH2OdWIGq7Hpm8LwUBlh+BiK6uyEgV
# yGqlrZ7fmzj1xFPJDjXc8vZfhK7iZ0FKMC5a1o/a+gJ9Ytjl76HZqKQwjTyLLvGo
# Qr2h/0K0zmqI5EMYLv+ecyZEqY8OlTv6zvEtc1IAmANRS5hpMytH76Gf6WWUcMoc
# fLNn/FfVGNfNaRDjWwYWWQHJjJ0w7Atn3sRfVnkMLcWYJHd11c8RHSQnpAD5VS48
# hK0Z4m8x0ES50s633DbCjRDUOOgNYENviSFYOPScyB3rqeQFoCp+DPVqEZH74ote
# JFNl6YYe4vGBiDN3HXaGjQUA0DEQFSy9zRiNMGkNdKCtX9Tha1xIVCBF8di+NPu0
# kYYdZT2SrCWsvLYmBYXUyHJzGZJMLVevy2yW+QMbxQ==
# SIG # End signature block
