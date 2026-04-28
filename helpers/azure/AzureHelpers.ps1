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

    # Re-enforce TLS 1.2 before every request (PS 5.1 can lose the setting
    # when other code or .NET ServicePoints negotiate a different protocol).
    if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
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
    $maxRetries = 2
    do {
        $irmSplat['Uri'] = $currentUri
        $lastErr = $null
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                $resp = Invoke-RestMethod @irmSplat
                $lastErr = $null
                break
            }
            catch {
                $lastErr = $_
                $errMsg = "$($_.Exception.Message)"
                # Retry on transient connection errors (TLS reset, connection closed)
                if ($errMsg -match 'underlying connection was closed|unexpected error occurred on a send|unable to connect' -and $attempt -lt $maxRetries) {
                    Write-Verbose "Connection error on attempt $attempt, retrying: $errMsg"
                    # Force TLS 1.2 exclusively for the retry (remove TLS 1.0/1.1)
                    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                }
                else {
                    throw
                }
            }
        }
        if ($lastErr) { throw $lastErr }

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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDoni/fs1Cur9WS
# u++AVkT7j/dUt1EcORmLdVGcbpMu3qCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCPr+LYUnSwXfgWCxf5A+1Gdk/MOgzKt++2lu8S+oHyaDANBgkqhkiG9w0BAQEF
# AASCAgBE8dXFnqNrz8mRbtPV3l1p0UU3hQc/JX7zt3kmhpQQQVIwfnQ5qA1+bBt/
# DVgorlGzQjCNm434yU6uqpINr9xjBsYHC//Uvb9RiPxaFYJKNjpjztqV+9M9N5tV
# LvaJSMq7g0TJzIOYLfqHxMj/yGDscZjwFDp+GQBxsAtZXh1EGxqtjWvcx4PkMVH4
# 8t/QZVwoo4n6kcf10jzTHPDJ1O62GY1t2que/9gwhIfuUvVF8VoyTJLKlIS4p14n
# /fIiUgzmAblhDeXqrdNg5zjgOzJx61wF0hgqySpN5QVkLoOnoNvSpxcw66c/8jiS
# dlwDlNZnhQmUqE5pLxnS4v+WB48y6d4HsR9BldpnZoECJKWUR9xOgX5ar6ZNrimx
# 8ZbtuJjomrMZXoaoD+LYr/FPM7wSPkL1zaetqP8qvgcZZJLDXHlSG43+crsNYcJy
# ZjEWEqiFvc3mw+BhQwBsDdKnmDSLIl6aY8gs0LsusCh8QuCDkvW2+Y8dpSt99oDj
# VhGluTrL1moUPfxX18j8Wu6SwS+Gsd18h30NZymnPVKEKL0N9IWQ3y1O7tkcJtjB
# T73AOm+HCFC9nmHuVnujIka0ib1FNrydTRwyxx8iPHFZ4T94+xqGWd4hO6lRxRM0
# zFaxe/xr/CkpsPXcZgGeKMwFIk1olteSAcK05axb0AN4RCyj0aGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjYxNDQyMzZaMC8GCSqGSIb3DQEJBDEiBCBkQsGW
# /FMspp4O9nmsTCzC7JVcqAu4cnUGFxYHnzFxvzANBgkqhkiG9w0BAQEFAASCAgCC
# rrLfoCjwg+prIaAa3z6iY9FspNy5sisugaE1BWua/Wz/91iOnTl+vwPS+RRAiUKv
# +oz2uANlncMu02ZZi2FIb404pQaokYV9RxJsHs35MGNs9Flya635SS9rcCu8T18t
# Mwrzk1x89S1tH8ZgFivh2d7V+/rd+rVoqAtj4i758GLdSKcYEAO7Ctz12bG69r3/
# dlLne4gj0oXWC5PzwX+vyoRmp4Cb+0xR+ofLD/B2zTIfKcWZyF78zd7O9k/1jxBl
# at/HjgYzq6bPsIAPpOa1+i+zOzvngaRKUzeqkV02mOtPzzdMSsLt8XaWLmCF3PN8
# v4SKfPVQ/XMAzEmL9toFdKATKPpUKUJKOilwdKffRnCgVw5hHhhYA7iLSqWY4Y9T
# 4zrgNLPP1UfYVid/PfD5qEgjIocRWYuznGvhOiovsEgrhMCsD2jkTPWeJwTYqfFX
# nA4VE7e7GrCIWaikLjk4EhhFr12T2P0wagg+Hvvc6BgpA4ngkcDCzG/Kf7Mt1gqI
# oKGHx3L+vezzVOZ6eGLOa6a5dx3g5+zhr57ZgrHdS6oZf2Opo6so0MB9i6tRw0lu
# WlW/cXYup1aG0v3fLcWY25rAHEvs/3IqvQPbqejk/ku5+1DM3oYtw3UytJaCjal4
# YnA/PaxSnGJ9NTA9wyfyjx/8gChydVw/f3RTyKDuEQ==
# SIG # End signature block
