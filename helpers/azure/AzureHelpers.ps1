# =============================================================================
# Azure Helpers for WhatsUpGoldPS
#
# Uses the Azure Resource Manager REST API via Invoke-RestMethod (built into PS 5.1).
# Zero external module dependencies.
# =============================================================================

# Enforce TLS 1.2 for Azure management API calls (PS 5.1 defaults to TLS 1.0/1.1)
if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

# --- REMOVED: Az PowerShell module functions ---
# Previously this file contained wrapper functions that required Az.Accounts,
# Az.Resources, Az.Compute, Az.Network, and Az.Monitor. Those have been
# removed in favour of the REST API functions below which have zero external
# dependencies and work identically on any machine with PowerShell 5.1+.

function Get-AzureResourceDetail {
    <#
    .SYNOPSIS
        Builds a detailed summary object for an Azure resource including metrics.
    .DESCRIPTION
        Combines resource metadata with metric data from the REST API into a single
        object suitable for display and attribute creation.
    .PARAMETER Resource
        A resource object from Get-AzureSubscriptionResourcesREST or Get-AzureResourcesREST.
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
        Get-AzureResourceDetail -Resource $resource -SubscriptionName "MySub" -SubscriptionId "xxxx" -ResourceGroupName "myRG"
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
        $metricsData = @(Get-AzureResourceMetricsREST -ResourceId $Resource.ResourceId -MaxMetrics $MaxMetrics)
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

function Get-AzureDashboard {
    <#
    .SYNOPSIS
        Builds a unified dashboard view of Azure resources across subscriptions.
    .DESCRIPTION
        Enumerates accessible subscriptions via REST API, pre-fetches resources
        and network data at the subscription level for speed, and returns a flat
        collection of resources with metadata suitable for Bootstrap Table display.
    .PARAMETER SubscriptionIds
        Optional array of subscription IDs to limit scope. If omitted, scans all
        enabled subscriptions accessible to the current authenticated session.
    .PARAMETER IncludeMetrics
        Whether to fetch Azure Monitor metrics for each resource. Defaults to $false
        to avoid excessive API calls on large environments.
    .EXAMPLE
        Connect-AzureServicePrincipalREST -TenantId $tid -ApplicationId $aid -ClientSecret $secret
        $data = Get-AzureDashboard -SubscriptionIds $subId
        Export-AzureDashboardHtml -DashboardData $data -OutputPath "C:\Reports\azure.html"
    .OUTPUTS
        PSCustomObject[]
    .NOTES
        Author  : jason@wug.ninja
        Version : 2.0.0
        Date    : 2026-04-07
        Requires: PowerShell 5.1+. Zero external module dependencies.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [string[]]$SubscriptionIds,
        [bool]$IncludeMetrics = $false
    )

    $subscriptions = Get-AzureSubscriptionsREST | Where-Object { $_.State -eq 'Enabled' }
    if ($SubscriptionIds) {
        $subscriptions = $subscriptions | Where-Object { $_.SubscriptionId -in $SubscriptionIds }
    }

    $results = @()
    foreach ($sub in $subscriptions) {
        Write-Verbose "Processing subscription: $($sub.SubscriptionName)"

        # Bulk pre-fetch resources and network data per subscription
        try {
            $subResources = @(Get-AzureSubscriptionResourcesREST -SubscriptionId $sub.SubscriptionId)
        }
        catch {
            Write-Warning "Failed to list resources for $($sub.SubscriptionName): $($_.Exception.Message)"
            continue
        }

        $netData = $null
        try {
            $netData = Get-AzureNetworkDataREST -SubscriptionId $sub.SubscriptionId
        }
        catch {
            Write-Verbose "Network pre-fetch failed for $($sub.SubscriptionName): $($_.Exception.Message)"
        }

        foreach ($r in $subResources) {
            $rgName = ''
            if ($r.ResourceId -match '/resourceGroups/([^/]+)/') { $rgName = $Matches[1] }

            $ip = "N/A"
            if ($netData) {
                switch -Wildcard ($r.ResourceType) {
                    'Microsoft.Compute/virtualMachines' {
                        if ($netData.VMIPs.ContainsKey($r.ResourceId)) { $ip = $netData.VMIPs[$r.ResourceId] }
                    }
                    'Microsoft.Network/publicIPAddresses' {
                        if ($netData.PIPs.ContainsKey($r.ResourceId)) { $ip = $netData.PIPs[$r.ResourceId] }
                    }
                    'Microsoft.Network/loadBalancers' {
                        if ($netData.LBIPs.ContainsKey($r.ResourceId)) { $ip = $netData.LBIPs[$r.ResourceId] }
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
            } else {
                try { $ip = Resolve-AzureResourceIPREST -Resource $r -SubscriptionId $sub.SubscriptionId; if (-not $ip) { $ip = "N/A" } } catch {}
            }

            $metricsSummary = "N/A"
            if ($IncludeMetrics) {
                try {
                    $metrics = @(Get-AzureResourceMetricsREST -ResourceId $r.ResourceId -MaxMetrics 5)
                    if ($metrics.Count -gt 0) {
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
                ResourceGroup     = $rgName
                Kind              = $r.Kind
                Sku               = $r.Sku
                Tags              = $r.Tags
                Metrics           = $metricsSummary
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
        Connect-AzureServicePrincipalREST -TenantId $tid -ApplicationId $aid -ClientSecret $secret
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
# REST API Functions
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
    .PARAMETER Body
        Request body (string or hashtable). Hashtables are auto-converted to JSON.
        Content-Type is set to application/json when Body is provided.
    .PARAMETER ApiVersion
        Appended as ?api-version= query parameter if the Uri does not already contain one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        $Body,
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

    # Build Invoke-RestMethod splat
    $irmSplat = @{
        Uri     = $null
        Method  = $Method
        Headers = $headers
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $jsonBody = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
        $irmSplat['Body'] = $jsonBody
        $irmSplat['ContentType'] = 'application/json'
    }

    # Handle pagination (nextLink)
    $allValues = @()
    $currentUri = $Uri
    do {
        $irmSplat['Uri'] = $currentUri
        $resp = Invoke-RestMethod @irmSplat
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

function Get-AzureSubscriptionResourcesREST {
    <#
    .SYNOPSIS
        Returns all resources across all resource groups in a subscription via
        a single REST call (faster than per-RG enumeration).
    .PARAMETER SubscriptionId
        The subscription ID.
    .EXAMPLE
        Get-AzureSubscriptionResourcesREST -SubscriptionId "xxxx"
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resources"
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

function Get-AzureNetworkDataREST {
    <#
    .SYNOPSIS
        Pre-fetches all NICs, public IPs, and load balancers in a subscription
        and returns IP lookup hashtables for fast resolution without per-resource
        API calls.
    .PARAMETER SubscriptionId
        The subscription ID.
    .OUTPUTS
        Hashtable with keys: VMIPs, PIPs, LBIPs
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $baseUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Network"
    $apiVer  = '2024-01-01'

    # 1) Public IP addresses
    $pipLookup = @{}
    try {
        $pips = @(Invoke-AzureREST -Uri "$baseUri/publicIPAddresses" -ApiVersion $apiVer)
        foreach ($pip in $pips) {
            if ($pip.properties.ipAddress -and $pip.properties.ipAddress -ne 'Not Assigned') {
                $pipLookup[$pip.id] = "$($pip.properties.ipAddress)"
            }
        }
    }
    catch { Write-Verbose "Could not pre-fetch public IPs: $_" }

    # 2) Network interfaces -> VM IP mapping
    $vmIpLookup = @{}
    try {
        $nics = @(Invoke-AzureREST -Uri "$baseUri/networkInterfaces" -ApiVersion $apiVer)
        foreach ($nic in $nics) {
            $vmId = $null
            if ($nic.properties.virtualMachine -and $nic.properties.virtualMachine.id) {
                $vmId = $nic.properties.virtualMachine.id
            }
            if (-not $vmId) { continue }

            $privateIp = $null
            $publicIp  = $null
            if ($nic.properties.ipConfigurations) {
                foreach ($ipConfig in $nic.properties.ipConfigurations) {
                    if (-not $privateIp -and $ipConfig.properties.privateIPAddress) {
                        $privateIp = "$($ipConfig.properties.privateIPAddress)"
                    }
                    if (-not $publicIp -and $ipConfig.properties.publicIPAddress -and $ipConfig.properties.publicIPAddress.id) {
                        $pipId = $ipConfig.properties.publicIPAddress.id
                        if ($pipLookup.ContainsKey($pipId)) {
                            $publicIp = $pipLookup[$pipId]
                        }
                    }
                }
            }
            if (-not $vmIpLookup.ContainsKey($vmId)) {
                $vmIpLookup[$vmId] = if ($publicIp) { $publicIp } else { $privateIp }
            }
        }
    }
    catch { Write-Verbose "Could not pre-fetch NICs: $_" }

    # 3) Load balancers
    $lbIpLookup = @{}
    try {
        $lbs = @(Invoke-AzureREST -Uri "$baseUri/loadBalancers" -ApiVersion $apiVer)
        foreach ($lb in $lbs) {
            if ($lb.properties.frontendIPConfigurations) {
                foreach ($feConfig in $lb.properties.frontendIPConfigurations) {
                    if ($feConfig.properties.publicIPAddress -and $feConfig.properties.publicIPAddress.id) {
                        $pipId = $feConfig.properties.publicIPAddress.id
                        if ($pipLookup.ContainsKey($pipId)) {
                            $lbIpLookup[$lb.id] = $pipLookup[$pipId]
                            break
                        }
                    }
                    if (-not $lbIpLookup.ContainsKey($lb.id) -and $feConfig.properties.privateIPAddress) {
                        $lbIpLookup[$lb.id] = "$($feConfig.properties.privateIPAddress)"
                    }
                }
            }
        }
    }
    catch { Write-Verbose "Could not pre-fetch load balancers: $_" }

    return @{
        VMIPs = $vmIpLookup
        PIPs  = $pipLookup
        LBIPs = $lbIpLookup
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
        "Microsoft.Network/loadBalancers" {
            try {
                $lbUri = "https://management.azure.com$($Resource.ResourceId)"
                $lb = Invoke-AzureREST -Uri $lbUri -ApiVersion '2024-01-01'
                if ($lb.properties.frontendIPConfigurations) {
                    foreach ($feConfig in $lb.properties.frontendIPConfigurations) {
                        # Prefer public IP
                        if ($feConfig.properties.publicIPAddress) {
                            try {
                                $pubUri = "https://management.azure.com$($feConfig.properties.publicIPAddress.id)"
                                $pubIp = Invoke-AzureREST -Uri $pubUri -ApiVersion '2024-01-01'
                                if ($pubIp.properties.ipAddress -and $pubIp.properties.ipAddress -ne 'Not Assigned') {
                                    $ip = $pubIp.properties.ipAddress
                                    break
                                }
                            }
                            catch { }
                        }
                        # Fall back to private IP
                        if (-not $ip -and $feConfig.properties.privateIPAddress) {
                            $ip = $feConfig.properties.privateIPAddress
                        }
                        if ($ip) { break }
                    }
                }
            }
            catch {
                Write-Verbose "Could not resolve Load Balancer IP via REST for $($Resource.ResourceName): $($_.Exception.Message)"
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
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQ6yqsz2d1Y4yC
# 4kVfymw4WeS+1+YHSZyqMPjasSGIoaCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCnzR74
# Ah7Pt3ZmY25Zk/WF2tkNmijXC/P1Stl/O39jOzANBgkqhkiG9w0BAQEFAASCAgDw
# lkD1WtulhFgjMT/ntnrvYYYTzrs/enfUitxDVfkOLbBqVsyBtzjbX0XPTD6y9e5Z
# oz+R0zTrc2TlJWY0QeNDhLWTjCgcOyqoti1j3mjuBZtbEF+ZNbPi++z//yADuIwJ
# QCN/GqdZudgueTJibtezunCF+fmJUc0+57EI3nI7v2K9gpaoebFoS4t9zgZr30aU
# +JhsPjTNYb5fwGGkOkFk+Y13p2hSufD7GZ3c3lqTcBo1v5DgAwx5OAh5tN1bIfhC
# goDgFas6ncjaeSQBHIR3I21uWwnr85WWaJkvBcOPSuVKXCZWewkZnLSiX+uO4JVf
# eMtYQP+EjtycZMFfFocIhMgUaOxWUiuDdPFoh6reoTfb/Q9Q+pmUtbpMx+rj+8eT
# 3WaXTWmzeRKPEmTHd/dfZmCrEc+v3/p1PfTNkW9K0o79WbzHrdweP8PXgY1jeJW2
# kZSVbMtoUQg7bLxIwJ+JFd1V+BPYZ+YKTxgNP8ehzipYVRaMBF8TXINeEyioNV7S
# t9HfG/UOUk5GC3yuaCQp7lJiO1bbhdP6Jdr0Huy3NxDjx3PTEoPrHhLJNSF6TVSz
# vk/lVf1m5OEWLlupRQYJlBIHHhjaj7ohpzt+AKtepQxVFE3HfrkI6nV0GGnF+k2g
# /psOSYsBaA2UVnsvxyen4rcA1q09cLsNd9C/J9pf9KGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzE5NTg0
# NlowPwYJKoZIhvcNAQkEMTIEMNlqcUSqQmFVHkxhHps0ZyVMgjupsI+E/uSomHnm
# u5T2j+uS3r8oaNi72fuuA4f9nzANBgkqhkiG9w0BAQEFAASCAgBK34Qx7oI7EZj3
# TskJeTWKz+YfNf6DIBiT7mKaCinp9CY0512VTsdMnafUKL92fX3BYjKgCn88s/P8
# +eS/aGRDkTMa51zJBSyfb28WMlNnjD0nTN3mbkv5cd2F9COJY7w6CcE8Ht5KXYYh
# MQ9Wkz9Go1sFnrhWydtbSvKGgVDj3xtTJ3jeNXuYln+528Ef61ASwZtWeJAa34QM
# qOsJgny4SC5hQlk7pTQO7wm5L//JXB1SVWxFhvbErNEJA5nAPd8yi1MANhxAey7A
# mIvL4gKHUV17qj6Rg83TobCkUVdoWFenGUyFvA6zqxgZ2h2SK2Ib8hIQu2ZXnHjN
# B9vCzQhh33tJ41kpDvk3QEOIuX46v3t2AChnl6jmk00PryLLbjZJdnEKZE3JQ7Y8
# Xalv99G6cP48QOOCcMI23IpbU72seD9i508bGaUDW8EutR+owkzr/KtojuxEbXMp
# DCaxPHSZWKTeVxllTnEhEVk/ID2JEleE+HkCsBm2La8dd/es9aLU5Fcra1vHEeXN
# k0OSzzt0P0uXpqvfISb7Bg8r2NERBlaU6qRL0zVSYQDNeKInnHCIvIPF/ZlojbCG
# AaCtftyTu8PVAFdpzG1q71Ex85VF2RqwVoGHdA8k5o2fFA/BKot1OatTCZ1w91Fu
# AbBtW0LEisYclmzeIJqLvkx2uOXx0A==
# SIG # End signature block
