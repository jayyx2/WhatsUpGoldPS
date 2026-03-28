# =============================================================================
# Azure Helpers for WhatsUpGoldPS
#
# Two collection methods supported:
#   [1] Az PowerShell modules (Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Monitor)
#   [2] Direct REST API calls (zero external dependencies -- uses Invoke-RestMethod)
#
# Functions prefixed with "REST" use the Azure Resource Manager REST API directly.
# Functions without the prefix use the Az PowerShell cmdlets.
# =============================================================================

function Connect-AzureServicePrincipal {
    <#
    .SYNOPSIS
        Authenticates to Azure using a service principal (App Registration).
    .DESCRIPTION
        Takes a TenantId, ApplicationId, and client secret, creates a PSCredential,
        and calls Connect-AzAccount with the service principal identity.
        Returns the context object on success.
    .PARAMETER TenantId
        The Azure AD tenant (directory) ID.
    .PARAMETER ApplicationId
        The Application (client) ID of the service principal.
    .PARAMETER ClientSecret
        The client secret string for the service principal.
    .EXAMPLE
        Connect-AzureServicePrincipal -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -ApplicationId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -ClientSecret "MySecretValue"
        Authenticates to Azure using a service principal with a client secret.
    .EXAMPLE
        $ctx = Connect-AzureServicePrincipal -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret
        Authenticates and stores the Azure context in a variable for later use.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = [PSCredential]::new($ApplicationId, $secureSecret)

    # Pre-load latest Az.Accounts to avoid version mismatch when multiple
    # versions are installed (prevents 'get_SerializationSettings' errors)
    if (-not (Get-Module -Name Az.Accounts)) {
        $latest = Get-Module -ListAvailable -Name Az.Accounts |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($latest) {
            Import-Module Az.Accounts -RequiredVersion $latest.Version -ErrorAction SilentlyContinue
        }
    }

    try {
        $context = Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $credential -ErrorAction Stop
        Write-Verbose "Authenticated to Azure tenant $TenantId as $ApplicationId"
        return $context
    }
    catch {
        throw "Failed to authenticate to Azure: $($_.Exception.Message)"
    }
}

function Get-AzureSubscriptions {
    <#
    .SYNOPSIS
        Returns all accessible Azure subscriptions.
    .DESCRIPTION
        Wraps Get-AzSubscription and returns a simplified collection of
        subscription objects with Id, Name, State, and TenantId.
    .EXAMPLE
        Get-AzureSubscriptions
        Returns all Azure subscriptions accessible to the current identity.
    .EXAMPLE
        Get-AzureSubscriptions | Where-Object { $_.State -eq "Enabled" }
        Returns only enabled subscriptions.
    #>

    $subs = Get-AzSubscription -ErrorAction Stop
    foreach ($sub in $subs) {
        [PSCustomObject]@{
            SubscriptionId   = "$($sub.Id)"
            SubscriptionName = "$($sub.Name)"
            State            = "$($sub.State)"
            TenantId         = "$($sub.TenantId)"
        }
    }
}

function Get-AzureResourceGroups {
    <#
    .SYNOPSIS
        Returns all resource groups in the current subscription.
    .DESCRIPTION
        Wraps Get-AzResourceGroup and returns a simplified collection.
    .EXAMPLE
        Get-AzureResourceGroups
        Returns all resource groups in the current subscription.
    .EXAMPLE
        Get-AzureResourceGroups | Where-Object { $_.Location -eq "eastus" }
        Returns only resource groups located in East US.
    #>

    $rgs = Get-AzResourceGroup -ErrorAction Stop
    foreach ($rg in $rgs) {
        [PSCustomObject]@{
            ResourceGroupName = "$($rg.ResourceGroupName)"
            Location          = "$($rg.Location)"
            ProvisioningState = "$($rg.ProvisioningState)"
            Tags              = if ($rg.Tags -and $rg.Tags -is [hashtable]) { ($rg.Tags.GetEnumerator() | Where-Object { $_.Key -ne '' -and $null -ne $_.Key } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; " } else { "" }
        }
    }
}

function Get-AzureResources {
    <#
    .SYNOPSIS
        Returns all resources within a resource group.
    .DESCRIPTION
        Wraps Get-AzResource for a given resource group and returns
        a simplified collection with key properties.
    .PARAMETER ResourceGroupName
        The name of the resource group to enumerate.
    .EXAMPLE
        Get-AzureResources -ResourceGroupName "Production-RG"
        Returns all resources within the Production-RG resource group.
    .EXAMPLE
        Get-AzureResources -ResourceGroupName "Production-RG" | Where-Object { $_.ResourceType -like "*virtualMachines*" }
        Returns only virtual machine resources from the specified resource group.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $resources = Get-AzResource -ResourceGroupName $ResourceGroupName -ExpandProperties -ErrorAction Stop
    foreach ($r in $resources) {
        $provState = if ($r.Properties -and $r.Properties.provisioningState) {
            "$($r.Properties.provisioningState)"
        } elseif ($r.ProvisioningState) {
            "$($r.ProvisioningState)"
        } else { "N/A" }
        [PSCustomObject]@{
            ResourceName      = "$($r.Name)"
            ResourceId        = "$($r.ResourceId)"
            ResourceType      = "$($r.ResourceType)"
            Location          = "$($r.Location)"
            Kind              = if ($r.Kind) { "$($r.Kind)" } else { "N/A" }
            Sku               = if ($r.Sku -and $r.Sku.Name) { "$($r.Sku.Name)" } else { "N/A" }
            ProvisioningState = $provState
            Tags              = if ($r.Tags -and $r.Tags -is [hashtable]) { ($r.Tags.GetEnumerator() | Where-Object { $_.Key -ne '' -and $null -ne $_.Key } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; " } else { "" }
        }
    }
}

function Get-AzureResourceMetrics {
    <#
    .SYNOPSIS
        Returns available metric definitions and recent values for an Azure resource.
    .DESCRIPTION
        Queries Azure Monitor for the specified resource's metric definitions,
        then retrieves the latest data point for each metric over the past hour.
        Returns a collection of metric objects suitable for storing as attributes.
    .PARAMETER ResourceId
        The full Azure resource ID.
    .PARAMETER MaxMetrics
        Maximum number of metrics to retrieve values for. Defaults to 20
        to prevent excessive API calls on resources with many metrics.
    .EXAMPLE
        Get-AzureResourceMetrics -ResourceId "/subscriptions/xxxx/resourceGroups/myRG/providers/Microsoft.Compute/virtualMachines/myVM"
        Returns up to 20 recent metric values for the specified Azure VM.
    .EXAMPLE
        Get-AzureResourceMetrics -ResourceId $resource.ResourceId -MaxMetrics 5
        Returns only the first 5 metric definitions and their latest values.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [int]$MaxMetrics = 20
    )

    $metrics = @()
    try {
        $definitions = Get-AzMetricDefinition -ResourceId $ResourceId -ErrorAction Stop |
            Select-Object -First $MaxMetrics

        foreach ($def in $definitions) {
            $metricName = $def.Name.Value
            $metricUnit = "$($def.Unit)"
            $primaryAgg = if ($def.PrimaryAggregationType) { "$($def.PrimaryAggregationType)" } else { "Average" }

            try {
                $metricData = Get-AzMetric -ResourceId $ResourceId -MetricName $metricName `
                    -TimeGrain ([TimeSpan]::FromMinutes(5)) -StartTime (Get-Date).AddHours(-1) `
                    -EndTime (Get-Date) -AggregationType $primaryAgg -ErrorAction Stop

                $lastValue = "N/A"
                if ($metricData.Data) {
                    $latest = $metricData.Data | Where-Object { $null -ne $_.$primaryAgg } | Select-Object -Last 1
                    if ($latest) {
                        $lastValue = "$([math]::Round($latest.$primaryAgg, 4))"
                    }
                }

                $metrics += [PSCustomObject]@{
                    MetricName  = $metricName
                    DisplayName = "$($def.Name.LocalizedValue)"
                    Unit        = $metricUnit
                    Aggregation = $primaryAgg
                    LastValue   = $lastValue
                }
            }
            catch {
                Write-Verbose "Could not retrieve metric $metricName for resource: $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Verbose "Could not retrieve metric definitions for $ResourceId : $($_.Exception.Message)"
    }

    return $metrics
}

function Get-AzureResourceDetail {
    <#
    .SYNOPSIS
        Builds a detailed summary object for an Azure resource including metrics.
    .DESCRIPTION
        Combines resource metadata with metric data into a single object
        suitable for display and attribute creation.
    .PARAMETER Resource
        A resource object from Get-AzureResources.
    .PARAMETER SubscriptionName
        The name of the subscription the resource belongs to.
    .PARAMETER SubscriptionId
        The subscription ID the resource belongs to.
    .PARAMETER ResourceGroupName
        The resource group name.
    .PARAMETER IncludeMetrics
        Whether to fetch metric data. Defaults to $true.
    .PARAMETER MaxMetrics
        Maximum number of metrics to retrieve. Defaults to 20.
    .EXAMPLE
        $resources = Get-AzureResources -ResourceGroupName "Production-RG"
        Get-AzureResourceDetail -Resource $resources[0] -SubscriptionName "MySub" -SubscriptionId "xxxx" -ResourceGroupName "Production-RG"
        Returns a detailed summary of the first resource including up to 20 metric values.
    .EXAMPLE
        Get-AzureResourceDetail -Resource $resource -SubscriptionName "MySub" -SubscriptionId "xxxx" -ResourceGroupName "myRG" -IncludeMetrics $false
        Returns resource details without fetching Azure Monitor metrics.
    #>
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string]$SubscriptionName,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [bool]$IncludeMetrics = $true,
        [int]$MaxMetrics = 20
    )

    $metricsData = @()
    if ($IncludeMetrics) {
        $metricsData = Get-AzureResourceMetrics -ResourceId $Resource.ResourceId -MaxMetrics $MaxMetrics
    }

    $metricsSummary = if ($metricsData.Count -gt 0) {
        ($metricsData | ForEach-Object { "$($_.DisplayName): $($_.LastValue) $($_.Unit)" }) -join "; "
    } else { "No metrics available" }

    [PSCustomObject]@{
        ResourceName      = $Resource.ResourceName
        ResourceId        = $Resource.ResourceId
        ResourceType      = $Resource.ResourceType
        Location          = $Resource.Location
        Kind              = $Resource.Kind
        Sku               = $Resource.Sku
        ProvisioningState = $Resource.ProvisioningState
        Tags              = $Resource.Tags
        SubscriptionName  = $SubscriptionName
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        MetricCount       = $metricsData.Count
        MetricsSummary    = $metricsSummary
        Metrics           = $metricsData
    }
}

function Resolve-AzureResourceIP {
    <#
    .SYNOPSIS
        Attempts to resolve an IP address for an Azure resource.
    .DESCRIPTION
        Tries to find a public or private IP associated with the resource.
        For VMs it checks network interfaces; for App Services / SQL / etc.
        it attempts DNS resolution of the FQDN. Returns $null if no IP found.
    .PARAMETER Resource
        A resource object from Get-AzureResources (needs ResourceId, ResourceType, ResourceName).
    .EXAMPLE
        $resources = Get-AzureResources -ResourceGroupName "Production-RG"
        $ip = Resolve-AzureResourceIP -Resource ($resources | Where-Object { $_.ResourceType -like "*virtualMachines*" } | Select-Object -First 1)
        Resolves the public or private IP of the first VM in the resource group.
    .EXAMPLE
        $resources | ForEach-Object { Resolve-AzureResourceIP -Resource $_ }
        Attempts IP resolution for every resource in the collection.
    #>
    param(
        [Parameter(Mandatory)]$Resource
    )

    $ip = $null

    switch -Wildcard ($Resource.ResourceType) {
        "Microsoft.Compute/virtualMachines" {
            try {
                $vm = Get-AzVM -ResourceId $Resource.ResourceId -Status -ErrorAction Stop
                $nicIds = $vm.NetworkProfile.NetworkInterfaces | Select-Object -ExpandProperty Id
                foreach ($nicId in $nicIds) {
                    $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
                    if ($nic) {
                        # Prefer public IP
                        foreach ($ipConfig in $nic.IpConfigurations) {
                            if ($ipConfig.PublicIpAddress) {
                                $pubIp = Get-AzPublicIpAddress -ResourceId $ipConfig.PublicIpAddress.Id -ErrorAction SilentlyContinue
                                if ($pubIp.IpAddress -and $pubIp.IpAddress -ne "Not Assigned") {
                                    $ip = $pubIp.IpAddress
                                    break
                                }
                            }
                        }
                        # Fall back to private IP
                        if (-not $ip) {
                            $privateIp = ($nic.IpConfigurations | Select-Object -First 1).PrivateIpAddress
                            if ($privateIp) { $ip = $privateIp }
                        }
                    }
                    if ($ip) { break }
                }
            }
            catch {
                Write-Verbose "Could not resolve VM IP for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        "Microsoft.Network/publicIPAddresses" {
            try {
                $pubIp = Get-AzPublicIpAddress -Name $Resource.ResourceName -ResourceGroupName (($Resource.ResourceId -split '/')[4]) -ErrorAction Stop
                if ($pubIp.IpAddress -and $pubIp.IpAddress -ne "Not Assigned") {
                    $ip = $pubIp.IpAddress
                }
            }
            catch {
                Write-Verbose "Could not resolve public IP for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        "Microsoft.Sql/servers" {
            try {
                $fqdn = "$($Resource.ResourceName).database.windows.net"
                $resolved = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "Could not resolve SQL server FQDN for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        "Microsoft.Web/sites" {
            try {
                $fqdn = "$($Resource.ResourceName).azurewebsites.net"
                $resolved = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "Could not resolve App Service FQDN for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        default {
            # Generic DNS attempt using resource name
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($Resource.ResourceName) | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "No IP resolution available for $($Resource.ResourceType) : $($Resource.ResourceName)"
            }
        }
    }

    return $ip
}

function Get-AzureDashboard {
    <#
    .SYNOPSIS
        Builds a unified dashboard view of Azure resources across subscriptions.
    .DESCRIPTION
        Enumerates accessible subscriptions, iterates through their resource groups,
        and returns a flat collection of resources with metadata suitable for
        Bootstrap Table display. Each row contains resource name, type, provisioning
        state, resolved IP, location, subscription, resource group, SKU, tags, and
        optional Azure Monitor metrics.
    .PARAMETER SubscriptionIds
        Optional array of subscription IDs to limit scope. If omitted, scans all
        enabled subscriptions accessible to the current authenticated session.
    .PARAMETER IncludeMetrics
        Whether to fetch Azure Monitor metrics for each resource. Defaults to $false
        to avoid excessive API calls on large environments.
    .EXAMPLE
        Get-AzureDashboard

        Returns all resources across all accessible Azure subscriptions.
    .EXAMPLE
        Get-AzureDashboard -SubscriptionIds "xxxx-yyyy" -IncludeMetrics $true

        Returns resources from one subscription with metric data.
    .EXAMPLE
        Connect-AzureServicePrincipal -TenantId $tid -ApplicationId $aid -ClientSecret $secret
        $data = Get-AzureDashboard -SubscriptionIds $subId
        Export-AzureDashboardHtml -DashboardData $data -OutputPath "C:\Reports\azure.html"
        Start-Process "C:\Reports\azure.html"

        End-to-end: authenticate via service principal, gather data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains: ResourceName, ResourceType, ProvisioningState, IPAddress,
        Location, Subscription, ResourceGroup, Kind, Sku, Tags, Metrics.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+. Az modules needed only for Az mode; REST mode has no dependencies.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [string[]]$SubscriptionIds,
        [bool]$IncludeMetrics = $false
    )

    $subscriptions = Get-AzureSubscriptions | Where-Object { $_.State -eq 'Enabled' }
    if ($SubscriptionIds) {
        $subscriptions = $subscriptions | Where-Object { $_.SubscriptionId -in $SubscriptionIds }
    }

    $results = @()
    foreach ($sub in $subscriptions) {
        Set-AzContext -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue | Out-Null

        try {
            $rgs = Get-AzureResourceGroups
        }
        catch {
            Write-Warning "Failed to list RGs for $($sub.SubscriptionName): $($_.Exception.Message)"
            continue
        }

        foreach ($rg in $rgs) {
            try {
                $resources = Get-AzureResources -ResourceGroupName $rg.ResourceGroupName
            }
            catch {
                Write-Warning "Failed to list resources in $($rg.ResourceGroupName): $($_.Exception.Message)"
                continue
            }

            foreach ($r in $resources) {
                $ip = "N/A"
                try { $ip = Resolve-AzureResourceIP -Resource $r; if (-not $ip) { $ip = "N/A" } } catch {}

                $metricsSummary = "N/A"
                if ($IncludeMetrics) {
                    try {
                        $metrics = Get-AzureResourceMetrics -ResourceId $r.ResourceId -MaxMetrics 5
                        if ($metrics) {
                            $metricsSummary = ($metrics | ForEach-Object { "$($_.DisplayName): $($_.LastValue)" }) -join "; "
                        }
                    }
                    catch {}
                }

                $results += [PSCustomObject]@{
                    ResourceName      = $r.ResourceName
                    ResourceType      = ($r.ResourceType -split '/')[-1]
                    ProvisioningState = $r.ProvisioningState
                    IPAddress         = $ip
                    Location          = $r.Location
                    Subscription      = $sub.SubscriptionName
                    ResourceGroup     = $rg.ResourceGroupName
                    Kind              = $r.Kind
                    Sku               = $r.Sku
                    Tags              = $r.Tags
                    Metrics           = $metricsSummary
                }
            }
        }
    }

    return $results
}

function Export-AzureDashboardHtml {
    <#
    .SYNOPSIS
        Renders Azure dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-AzureDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-AzureDashboard containing Azure resource details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Azure Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        Azure-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-AzureDashboard
        Export-AzureDashboardHtml -DashboardData $data -OutputPath "C:\Reports\azure.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-AzureDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\azure.html" -ReportTitle "Prod Azure"

        Exports with a custom report title.
    .EXAMPLE
        Connect-AzAccount
        $data = Get-AzureDashboard -SubscriptionIds $subId -IncludeMetrics $true
        Export-AzureDashboardHtml -DashboardData $data -OutputPath "C:\Reports\azure.html"
        Start-Process "C:\Reports\azure.html"

        Full pipeline: authenticate, gather with metrics, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Azure-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Azure Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Azure-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'ProvisioningState') {
            $col.formatter = 'formatState'
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = $DashboardData | ConvertTo-Json -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Azure Dashboard HTML written to $OutputPath"
}

# =============================================================================
# REST API Collection Method (zero external dependencies)
# Uses Azure Resource Manager REST API via Invoke-RestMethod (built into PS 5.1)
# =============================================================================

# Script-scoped token cache for REST API calls
if (-not (Get-Variable -Name '_AzureRESTToken' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:_AzureRESTToken = $null
    $script:_AzureRESTTokenExpiry = [datetime]::MinValue
}

function Connect-AzureServicePrincipalREST {
    <#
    .SYNOPSIS
        Authenticates to Azure via OAuth2 client_credentials and caches the token.
    .DESCRIPTION
        Posts to the Azure AD token endpoint using a service principal's
        Application ID and Client Secret. Caches the bearer token in script
        scope so subsequent REST helper calls can reuse it.
    .PARAMETER TenantId
        The Azure AD tenant (directory) ID.
    .PARAMETER ApplicationId
        The Application (client) ID of the service principal.
    .PARAMETER ClientSecret
        The client secret string for the service principal.
    .EXAMPLE
        Connect-AzureServicePrincipalREST -TenantId $tid -ApplicationId $aid -ClientSecret $secret
    #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ApplicationId
        client_secret = $ClientSecret
        scope         = 'https://management.azure.com/.default'
    }

    try {
        $resp = Invoke-RestMethod -Uri $tokenUri -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        $script:_AzureRESTToken = $resp.access_token
        $script:_AzureRESTTokenExpiry = (Get-Date).AddSeconds($resp.expires_in - 60)
        Write-Verbose "Authenticated to Azure tenant $TenantId via REST (token valid for $($resp.expires_in)s)"
        return @{ TenantId = $TenantId; ApplicationId = $ApplicationId }
    }
    catch {
        throw "Failed to authenticate to Azure via REST: $($_.Exception.Message)"
    }
}

function Invoke-AzureREST {
    <#
    .SYNOPSIS
        Internal helper -- calls an Azure ARM REST endpoint with the cached token.
    .PARAMETER Uri
        Full URI to call.
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER ApiVersion
        Appended as ?api-version= query parameter if the Uri does not already contain one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [string]$ApiVersion
    )

    if (-not $script:_AzureRESTToken -or (Get-Date) -ge $script:_AzureRESTTokenExpiry) {
        throw "Azure REST token is not set or expired. Call Connect-AzureServicePrincipalREST first."
    }

    if ($ApiVersion -and $Uri -notmatch 'api-version=') {
        $sep = if ($Uri.Contains('?')) { '&' } else { '?' }
        $Uri = "${Uri}${sep}api-version=${ApiVersion}"
    }

    $headers = @{ Authorization = "Bearer $($script:_AzureRESTToken)" }

    # Handle pagination (nextLink)
    $allValues = @()
    $currentUri = $Uri
    do {
        $resp = Invoke-RestMethod -Uri $currentUri -Method $Method -Headers $headers -ErrorAction Stop
        if ($resp.value) {
            $allValues += $resp.value
        }
        else {
            # Single-object response (not a list)
            return $resp
        }
        $currentUri = $resp.nextLink
    } while ($currentUri)

    return $allValues
}

function Get-AzureSubscriptionsREST {
    <#
    .SYNOPSIS
        Returns all accessible Azure subscriptions via REST API.
    .EXAMPLE
        Get-AzureSubscriptionsREST
    .EXAMPLE
        Get-AzureSubscriptionsREST | Where-Object { $_.State -eq "Enabled" }
    #>

    $subs = Invoke-AzureREST -Uri 'https://management.azure.com/subscriptions' -ApiVersion '2022-12-01'
    foreach ($sub in $subs) {
        [PSCustomObject]@{
            SubscriptionId   = "$($sub.subscriptionId)"
            SubscriptionName = "$($sub.displayName)"
            State            = "$($sub.state)"
            TenantId         = "$($sub.tenantId)"
        }
    }
}

function Get-AzureResourceGroupsREST {
    <#
    .SYNOPSIS
        Returns all resource groups in a subscription via REST API.
    .PARAMETER SubscriptionId
        The subscription ID to query.
    .EXAMPLE
        Get-AzureResourceGroupsREST -SubscriptionId "xxxx-yyyy"
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $rgs = Invoke-AzureREST -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourcegroups" -ApiVersion '2024-03-01'
    foreach ($rg in $rgs) {
        $tags = ''
        if ($rg.tags -and $rg.tags -is [PSCustomObject]) {
            $tags = ($rg.tags.PSObject.Properties | Where-Object { $_.Name -ne '' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
        }
        [PSCustomObject]@{
            ResourceGroupName = "$($rg.name)"
            Location          = "$($rg.location)"
            ProvisioningState = "$($rg.properties.provisioningState)"
            Tags              = $tags
        }
    }
}

function Get-AzureResourcesREST {
    <#
    .SYNOPSIS
        Returns all resources within a resource group via REST API.
    .PARAMETER SubscriptionId
        The subscription ID.
    .PARAMETER ResourceGroupName
        The name of the resource group to enumerate.
    .EXAMPLE
        Get-AzureResourcesREST -SubscriptionId "xxxx" -ResourceGroupName "Production-RG"
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/resources"
    $resources = Invoke-AzureREST -Uri $uri -ApiVersion '2024-03-01'
    foreach ($r in $resources) {
        $provState = 'N/A'
        if ($r.properties -and $r.properties.provisioningState) {
            $provState = "$($r.properties.provisioningState)"
        }
        $tags = ''
        if ($r.tags -and $r.tags -is [PSCustomObject]) {
            $tags = ($r.tags.PSObject.Properties | Where-Object { $_.Name -ne '' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
        }
        [PSCustomObject]@{
            ResourceName      = "$($r.name)"
            ResourceId        = "$($r.id)"
            ResourceType      = "$($r.type)"
            Location          = "$($r.location)"
            Kind              = if ($r.kind) { "$($r.kind)" } else { 'N/A' }
            Sku               = if ($r.sku -and $r.sku.name) { "$($r.sku.name)" } else { 'N/A' }
            ProvisioningState = $provState
            Tags              = $tags
        }
    }
}

function Resolve-AzureResourceIPREST {
    <#
    .SYNOPSIS
        Attempts to resolve an IP address for an Azure resource via REST API.
    .DESCRIPTION
        For VMs, queries the network interface REST endpoints. For App Services,
        SQL, and other resources, attempts DNS resolution.
    .PARAMETER Resource
        A resource object from Get-AzureResourcesREST.
    .PARAMETER SubscriptionId
        The subscription ID (needed for VM NIC lookups).
    .EXAMPLE
        Resolve-AzureResourceIPREST -Resource $resource -SubscriptionId "xxxx"
    #>
    param(
        [Parameter(Mandatory)]$Resource,
        [string]$SubscriptionId
    )

    $ip = $null

    switch -Wildcard ($Resource.ResourceType) {
        "Microsoft.Compute/virtualMachines" {
            try {
                # Get VM details to find NIC references
                $vmUri = "https://management.azure.com$($Resource.ResourceId)"
                $vm = Invoke-AzureREST -Uri $vmUri -ApiVersion '2024-03-01'
                if ($vm.properties.networkProfile.networkInterfaces) {
                    foreach ($nicRef in $vm.properties.networkProfile.networkInterfaces) {
                        $nicUri = "https://management.azure.com$($nicRef.id)"
                        $nic = Invoke-AzureREST -Uri $nicUri -ApiVersion '2024-01-01'
                        if ($nic.properties.ipConfigurations) {
                            foreach ($ipConfig in $nic.properties.ipConfigurations) {
                                # Prefer public IP
                                if ($ipConfig.properties.publicIPAddress) {
                                    $pubUri = "https://management.azure.com$($ipConfig.properties.publicIPAddress.id)"
                                    try {
                                        $pubIp = Invoke-AzureREST -Uri $pubUri -ApiVersion '2024-01-01'
                                        if ($pubIp.properties.ipAddress -and $pubIp.properties.ipAddress -ne 'Not Assigned') {
                                            $ip = $pubIp.properties.ipAddress
                                            break
                                        }
                                    }
                                    catch { }
                                }
                                # Fall back to private IP
                                if (-not $ip -and $ipConfig.properties.privateIPAddress) {
                                    $ip = $ipConfig.properties.privateIPAddress
                                }
                            }
                        }
                        if ($ip) { break }
                    }
                }
            }
            catch {
                Write-Verbose "Could not resolve VM IP via REST for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        "Microsoft.Network/publicIPAddresses" {
            try {
                $pubUri = "https://management.azure.com$($Resource.ResourceId)"
                $pubIp = Invoke-AzureREST -Uri $pubUri -ApiVersion '2024-01-01'
                if ($pubIp.properties.ipAddress -and $pubIp.properties.ipAddress -ne 'Not Assigned') {
                    $ip = $pubIp.properties.ipAddress
                }
            }
            catch {
                Write-Verbose "Could not resolve public IP via REST for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        "Microsoft.Sql/servers" {
            try {
                $fqdn = "$($Resource.ResourceName).database.windows.net"
                $resolved = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "Could not resolve SQL server FQDN for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        "Microsoft.Web/sites" {
            try {
                $fqdn = "$($Resource.ResourceName).azurewebsites.net"
                $resolved = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "Could not resolve App Service FQDN for $($Resource.ResourceName): $($_.Exception.Message)"
            }
        }
        default {
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($Resource.ResourceName) | Select-Object -First 1
                if ($resolved) { $ip = $resolved.IPAddressToString }
            }
            catch {
                Write-Verbose "No IP resolution available for $($Resource.ResourceType) : $($Resource.ResourceName)"
            }
        }
    }

    return $ip
}

function Get-AzureResourceMetricsREST {
    <#
    .SYNOPSIS
        Returns metric definitions and recent values for an Azure resource via REST API.
    .PARAMETER ResourceId
        The full Azure resource ID.
    .PARAMETER MaxMetrics
        Maximum number of metrics to retrieve. Defaults to 20.
    .EXAMPLE
        Get-AzureResourceMetricsREST -ResourceId "/subscriptions/xxxx/resourceGroups/myRG/providers/Microsoft.Compute/virtualMachines/myVM"
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [int]$MaxMetrics = 20
    )

    $metrics = @()
    try {
        # Get metric definitions
        $defUri = "https://management.azure.com${ResourceId}/providers/Microsoft.Insights/metricDefinitions"
        $definitions = Invoke-AzureREST -Uri $defUri -ApiVersion '2024-02-01'
        if (-not $definitions) { return $metrics }

        $definitions = @($definitions) | Select-Object -First $MaxMetrics

        foreach ($def in $definitions) {
            $metricName = $def.name.value
            $displayName = $def.name.localizedValue
            $metricUnit = "$($def.unit)"
            $primaryAgg = if ($def.primaryAggregationType) { "$($def.primaryAggregationType)" } else { "Average" }

            try {
                $endTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $startTime = (Get-Date).AddHours(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $metricUri = "https://management.azure.com${ResourceId}/providers/Microsoft.Insights/metrics"
                $metricUri += "?api-version=2024-02-01&metricnames=$([uri]::EscapeDataString($metricName))"
                $metricUri += "&timespan=${startTime}/${endTime}&interval=PT5M&aggregation=$primaryAgg"

                $metricResp = Invoke-AzureREST -Uri $metricUri
                $lastValue = 'N/A'
                if ($metricResp.value -and $metricResp.value[0].timeseries) {
                    $dataPoints = $metricResp.value[0].timeseries[0].data
                    if ($dataPoints) {
                        $aggLower = $primaryAgg.Substring(0,1).ToLower() + $primaryAgg.Substring(1)
                        $latest = $dataPoints | Where-Object { $null -ne $_.$aggLower } | Select-Object -Last 1
                        if ($latest) {
                            $lastValue = "$([math]::Round($latest.$aggLower, 4))"
                        }
                    }
                }

                $metrics += [PSCustomObject]@{
                    MetricName  = $metricName
                    DisplayName = $displayName
                    Unit        = $metricUnit
                    Aggregation = $primaryAgg
                    LastValue   = $lastValue
                }
            }
            catch {
                Write-Verbose "Could not retrieve metric $metricName via REST: $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Verbose "Could not retrieve metric definitions via REST for $ResourceId : $($_.Exception.Message)"
    }

    return $metrics
}

function Get-AzureResourceHealthREST {
    <#
    .SYNOPSIS
        Returns the health/availability status for one or more Azure resources.
    .DESCRIPTION
        Queries the Azure Resource Health API to get the current availability
        status of each resource. Works for any resource type that supports
        Microsoft.ResourceHealth.

        Returns: Available, Unavailable, Degraded, or Unknown.

        For VMs, also queries the instance view to get the power state
        (Running, Stopped, Deallocated, etc.).
    .PARAMETER ResourceId
        One or more full Azure resource IDs.
    .EXAMPLE
        Get-AzureResourceHealthREST -ResourceId '/subscriptions/.../providers/Microsoft.Compute/virtualMachines/myvm'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$ResourceId
    )

    process {
        foreach ($resId in $ResourceId) {
            $healthStatus = 'Unknown'
            $healthReason = ''
            $powerState   = ''

            # Resource Health API
            try {
                $healthUri = "https://management.azure.com${resId}/providers/Microsoft.ResourceHealth/availabilityStatuses/current"
                $healthResp = Invoke-AzureREST -Uri $healthUri -ApiVersion '2023-07-01-preview'
                if ($healthResp.properties) {
                    $healthStatus = "$($healthResp.properties.availabilityState)"
                    $healthReason = "$($healthResp.properties.summary)"
                }
            }
            catch {
                Write-Verbose "Resource Health not available for ${resId}: $_"
            }

            # VM instance view for power state
            if ($resId -match 'Microsoft\.Compute/virtualMachines') {
                try {
                    $ivUri = "https://management.azure.com${resId}/instanceView"
                    $ivResp = Invoke-AzureREST -Uri $ivUri -ApiVersion '2024-03-01'
                    if ($ivResp.statuses) {
                        $pwStatus = $ivResp.statuses | Where-Object { $_.code -match '^PowerState/' } | Select-Object -First 1
                        if ($pwStatus) {
                            $powerState = ($pwStatus.code -replace 'PowerState/', '')
                        }
                    }
                }
                catch {
                    Write-Verbose "VM instanceView not available for ${resId}: $_"
                }
            }

            [PSCustomObject]@{
                ResourceId   = $resId
                ResourceName = ($resId -split '/')[-1]
                Health       = $healthStatus
                Reason       = $healthReason
                PowerState   = $powerState
            }
        }
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA1KvUDosierU+6
# 35T6zL4G4ENKODQqz+f4glWB/gKQpaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg7l1RB1yLsZGng/8wdLQCNIZm7onfR70x
# U7PM+zv82RgwDQYJKoZIhvcNAQEBBQAEggIAyi29nCkAKe/e82Ll9ehQl1bmfo6E
# ILdQKihEvDO2owmNd/AW2R5b+xF3LG5Muy/NAX+YzmZvN0GypJKg8c3yGx00uKeE
# TM6NdWanLApyRvjDbyfpTx7le9DZFMWVmrlCuO3MwYIWbP7LN9IR1vf/ojduUeLG
# qm/wO7RdWZdqMtpZEbRbhsffEPB4zqk5Vj3a9TWEM+EgUerwZkTLEaYWPCYpgNm5
# YwecRbBubWPzuvyeiZOoHc55FMalsiZ6IMXjFAQHaGf5rRDwb9YWkr7tDyt/HA2h
# ybl3jE3+lK8Lr4hzF80+0FglbwJXBvCLFOTjovQuWIUPdzuMf2MfNXp8Gi2uskaw
# 4sj6YQPvDz7ndef/JLItRL4Rq2FjJ3aGHnAA2qVs0DueANk0Nk4qz88otv6o+mRH
# RDy4YOJAxv/Y5BKpXan8tdIYNaisLUwXFU3xs7BS+yz6aI3XgNjwdxuFuasdgbVA
# Anz7hXLBIC2pRG0nqe5Dm+URxsMO6oMcItLO+ajY//0TvjIG7yIqa6Xs4Q44MDkq
# mjNZrDyYzIsd8yO2a2eOaLLL50lsrLABFVvETBnnv4+SJLxlQm8vXkaLa9ngclKv
# KjZQiQ+N0FS/dsxc3Lq36dKtDg1pyA2O5/OHgOIg9QwAHC9Wh19jpkFhKT1kz1jn
# MVD8M8OddyJJuRw=
# SIG # End signature block
