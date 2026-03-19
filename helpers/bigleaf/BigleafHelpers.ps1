# =============================================================================
# Bigleaf Cloud Connect API Helpers for WhatsUpGoldPS
# Provides functions to interact with the Bigleaf API (https://api.bigleaf.net/v2)
# and produce dashboard-ready data for site, circuit, and device status.
#
# Authentication: HTTP Basic (username + password or API token as password).
# Rate limit: 10 calls per minute per account.
#
# Typical workflow:
#   1. Connect-BigleafAPI       (authenticate and store session headers)
#   2. Get-BigleafSites         (retrieve site and circuit configuration)
#   3. Get-BigleafSiteStatus    (retrieve real-time status and risks)
#   4. Get-BigleafDashboard     (combine sites + status into dashboard data)
#   5. Export-BigleafDashboardHtml (render an interactive HTML report)
# =============================================================================

# ---------------------------------------------------------------------------
# Connect-BigleafAPI
# ---------------------------------------------------------------------------
function Connect-BigleafAPI {
    <#
    .SYNOPSIS
        Authenticates to the Bigleaf Cloud Connect API and stores session headers.
    .DESCRIPTION
        Uses HTTP Basic authentication to validate credentials against the
        Bigleaf API. On success, stores the Base64-encoded authorization header
        in $global:BigleafHeaders for use by subsequent helper functions.
    .PARAMETER Credential
        PSCredential object containing the Bigleaf username and password/token.
    .PARAMETER BaseUri
        Base URI of the Bigleaf API. Defaults to https://api.bigleaf.net/v2.
    .EXAMPLE
        Connect-BigleafAPI -Credential (Get-Credential)
    .EXAMPLE
        $cred = New-Object PSCredential("user@example.com", (ConvertTo-SecureString "token" -AsPlainText -Force))
        Connect-BigleafAPI -Credential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [Parameter()]
        [string]$BaseUri = "https://api.bigleaf.net/v2"
    )

    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password
    $pair = "${username}:${password}"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $encoded = [Convert]::ToBase64String($bytes)

    $headers = @{
        Authorization = "Basic $encoded"
        Accept        = "application/json"
    }

    # Validate credentials by calling the token introspection endpoint
    try {
        $uri = "$BaseUri/token"
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        Write-Host "Connected to Bigleaf API as $($response.login) ($($response.full_name))" -ForegroundColor Green
    }
    catch {
        throw "Failed to authenticate to Bigleaf API at $BaseUri - $($_.Exception.Message)"
    }

    $global:BigleafHeaders = $headers
    $global:BigleafBaseUri = $BaseUri.TrimEnd('/')
}

# ---------------------------------------------------------------------------
# Disconnect-BigleafAPI
# ---------------------------------------------------------------------------
function Disconnect-BigleafAPI {
    <#
    .SYNOPSIS
        Clears stored Bigleaf API session data.
    .EXAMPLE
        Disconnect-BigleafAPI
    #>
    [CmdletBinding()]
    param()

    $global:BigleafHeaders = $null
    $global:BigleafBaseUri = $null
    Write-Host "Disconnected from Bigleaf API." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Invoke-BigleafAPI (internal helper)
# ---------------------------------------------------------------------------
function Invoke-BigleafAPI {
    <#
    .SYNOPSIS
        Sends a request to the Bigleaf API with automatic pagination.
    .DESCRIPTION
        Handles paginated GET requests to the Bigleaf API, automatically
        fetching subsequent pages until all records are retrieved.
        Respects the 10 calls/minute rate limit with a configurable delay.
    .PARAMETER Endpoint
        API endpoint path (e.g. "/sites", "/status").
    .PARAMETER QueryParameters
        Optional hashtable of additional query parameters.
    .PARAMETER PageSize
        Number of records per page. Defaults to 100.
    .PARAMETER SingleObject
        If set, returns the first (non-array) response without pagination.
    .EXAMPLE
        Invoke-BigleafAPI -Endpoint "/sites"
    .EXAMPLE
        Invoke-BigleafAPI -Endpoint "/sites/123/risks" -SingleObject
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter()]
        [hashtable]$QueryParameters = @{},

        [Parameter()]
        [int]$PageSize = 100,

        [Parameter()]
        [switch]$SingleObject
    )

    if (-not $global:BigleafHeaders) {
        throw "Not connected to Bigleaf API. Run Connect-BigleafAPI first."
    }

    $baseUrl = "$($global:BigleafBaseUri)$Endpoint"

    if ($SingleObject) {
        $queryParts = @()
        foreach ($key in $QueryParameters.Keys) {
            $queryParts += "$key=$([uri]::EscapeDataString($QueryParameters[$key]))"
        }
        $url = if ($queryParts.Count -gt 0) { "$baseUrl`?$($queryParts -join '&')" } else { $baseUrl }

        try {
            return Invoke-RestMethod -Uri $url -Headers $global:BigleafHeaders -Method Get -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $retryAfter = 60
                try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                Write-Warning "Rate limited. Waiting ${retryAfter}s before retrying..."
                Start-Sleep -Seconds $retryAfter
                return Invoke-RestMethod -Uri $url -Headers $global:BigleafHeaders -Method Get -ErrorAction Stop
            }
            throw
        }
    }

    # Paginated retrieval
    $allResults = @()
    $page = 1

    do {
        $params = @{ page = $page; count = $PageSize }
        foreach ($key in $QueryParameters.Keys) {
            $params[$key] = $QueryParameters[$key]
        }
        $queryParts = @()
        foreach ($key in $params.Keys) {
            $queryParts += "$key=$([uri]::EscapeDataString($params[$key]))"
        }
        $url = "$baseUrl`?$($queryParts -join '&')"

        try {
            $response = Invoke-RestMethod -Uri $url -Headers $global:BigleafHeaders -Method Get -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $retryAfter = 60
                try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                Write-Warning "Rate limited on page $page. Waiting ${retryAfter}s before retrying..."
                Start-Sleep -Seconds $retryAfter
                $response = Invoke-RestMethod -Uri $url -Headers $global:BigleafHeaders -Method Get -ErrorAction Stop
            }
            else { throw }
        }

        if ($response -is [array]) {
            $allResults += $response
            if ($response.Count -lt $PageSize) { break }
        }
        else {
            $allResults += $response
            break
        }

        $page++
    } while ($true)

    return $allResults
}

# ---------------------------------------------------------------------------
# Get-BigleafSites
# ---------------------------------------------------------------------------
function Get-BigleafSites {
    <#
    .SYNOPSIS
        Retrieves all Bigleaf sites with circuit, CPE, and LAN network details.
    .DESCRIPTION
        Returns an array of site objects containing site configuration,
        circuit definitions, LAN networks, and CPE device information.
    .PARAMETER SiteId
        Optional site ID to retrieve a specific site.
    .EXAMPLE
        Get-BigleafSites
    .EXAMPLE
        Get-BigleafSites -SiteId 12345
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$SiteId
    )

    if ($SiteId) {
        return Invoke-BigleafAPI -Endpoint "/sites/$SiteId" -SingleObject
    }
    return Invoke-BigleafAPI -Endpoint "/sites"
}

# ---------------------------------------------------------------------------
# Get-BigleafSiteStatus
# ---------------------------------------------------------------------------
function Get-BigleafSiteStatus {
    <#
    .SYNOPSIS
        Retrieves real-time status for all sites or a specific site.
    .DESCRIPTION
        Returns site status including device status, circuit status overview,
        and risk overview for each site.
    .PARAMETER SiteId
        Optional site ID to filter status to a single site.
    .EXAMPLE
        Get-BigleafSiteStatus
    .EXAMPLE
        Get-BigleafSiteStatus -SiteId 12345
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$SiteId
    )

    $params = @{}
    if ($SiteId) { $params['site_id'] = $SiteId }
    return Invoke-BigleafAPI -Endpoint "/status" -QueryParameters $params
}

# ---------------------------------------------------------------------------
# Get-BigleafCircuitStatus
# ---------------------------------------------------------------------------
function Get-BigleafCircuitStatus {
    <#
    .SYNOPSIS
        Retrieves circuit status for a specific site.
    .DESCRIPTION
        Returns detailed circuit status (up, normal, degraded, down)
        for each WAN circuit configured on the specified site.
    .PARAMETER SiteId
        The site ID to retrieve circuit status for.
    .EXAMPLE
        Get-BigleafCircuitStatus -SiteId 12345
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$SiteId
    )

    return Invoke-BigleafAPI -Endpoint "/sites/$SiteId/circuit-status"
}

# ---------------------------------------------------------------------------
# Get-BigleafDeviceStatus
# ---------------------------------------------------------------------------
function Get-BigleafDeviceStatus {
    <#
    .SYNOPSIS
        Retrieves device status for a specific site.
    .DESCRIPTION
        Returns the current status (provision, pending, up, down) of CPE
        and switch devices at the specified site.
    .PARAMETER SiteId
        The site ID to retrieve device status for.
    .EXAMPLE
        Get-BigleafDeviceStatus -SiteId 12345
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$SiteId
    )

    return Invoke-BigleafAPI -Endpoint "/sites/$SiteId/device-status"
}

# ---------------------------------------------------------------------------
# Get-BigleafSiteRisks
# ---------------------------------------------------------------------------
function Get-BigleafSiteRisks {
    <#
    .SYNOPSIS
        Retrieves risks for a specific site.
    .DESCRIPTION
        Returns a list of all risks for the site, ordered by risk_level
        and last_at, including circuit-level risk details and recommended actions.
    .PARAMETER SiteId
        The site ID to retrieve risks for.
    .EXAMPLE
        Get-BigleafSiteRisks -SiteId 12345
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$SiteId
    )

    return Invoke-BigleafAPI -Endpoint "/sites/$SiteId/risks"
}

# ---------------------------------------------------------------------------
# Get-BigleafAccounts
# ---------------------------------------------------------------------------
function Get-BigleafAccounts {
    <#
    .SYNOPSIS
        Retrieves all Bigleaf user accounts.
    .DESCRIPTION
        Returns account details including login, email, name, timezone,
        and alert/report configuration settings.
    .EXAMPLE
        Get-BigleafAccounts
    #>
    [CmdletBinding()]
    param()

    return Invoke-BigleafAPI -Endpoint "/accounts"
}

# ---------------------------------------------------------------------------
# Get-BigleafCompanies
# ---------------------------------------------------------------------------
function Get-BigleafCompanies {
    <#
    .SYNOPSIS
        Retrieves all Bigleaf companies.
    .DESCRIPTION
        Returns company details including company name, role, provider
        relationships, and sensitivity configuration.
    .EXAMPLE
        Get-BigleafCompanies
    #>
    [CmdletBinding()]
    param()

    return Invoke-BigleafAPI -Endpoint "/companies"
}

# ---------------------------------------------------------------------------
# Get-BigleafMetadata
# ---------------------------------------------------------------------------
function Get-BigleafMetadata {
    <#
    .SYNOPSIS
        Retrieves Bigleaf API metadata for health checks.
    .DESCRIPTION
        Returns API service information including version, environment,
        and commit reference. Useful as a health check endpoint.
    .EXAMPLE
        Get-BigleafMetadata
    #>
    [CmdletBinding()]
    param()

    # Metadata endpoint does not require auth
    $uri = if ($global:BigleafBaseUri) { "$($global:BigleafBaseUri)/metadata" } else { "https://api.bigleaf.net/v2/metadata" }
    return Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Get-BigleafDashboard
# ---------------------------------------------------------------------------
function Get-BigleafDashboard {
    <#
    .SYNOPSIS
        Builds enriched dashboard data combining sites, status, and risks.
    .DESCRIPTION
        Retrieves all sites and their real-time status, then produces a flat
        array of dashboard rows. Each row represents a site with its circuits,
        devices, risk summary, and optional WhatsUp Gold device enrichment.
    .EXAMPLE
        Connect-BigleafAPI -Credential (Get-Credential)
        $dashboard = Get-BigleafDashboard
        $dashboard | Format-Table SiteName, SiteStatus, CircuitSummary, HighestRisk
    .EXAMPLE
        $dashboard = Get-BigleafDashboard
        $dashboard | Where-Object { $_.SiteStatus -ne 'healthy' }
    #>
    [CmdletBinding()]
    param()

    Write-Host "Retrieving Bigleaf sites..." -ForegroundColor Cyan
    $sites = Get-BigleafSites
    if (-not $sites) {
        Write-Warning "No sites found."
        return @()
    }
    Write-Host "  Found $($sites.Count) site(s)." -ForegroundColor Green

    Write-Host "Retrieving site status..." -ForegroundColor Cyan
    $statusList = Get-BigleafSiteStatus
    $statusIndex = @{}
    if ($statusList) {
        foreach ($s in $statusList) {
            $statusIndex[$s.site_id] = $s
        }
    }
    Write-Host "  Retrieved status for $($statusIndex.Count) site(s)." -ForegroundColor Green

    # Build a WUG device index if connected to WhatsUp Gold
    $wugDeviceIndex = @{}
    if ($global:WUGBearerHeaders) {
        try {
            $wugDevices = Get-WUGDevice -View overview
            foreach ($dev in $wugDevices) {
                if ($dev.networkAddress) { $wugDeviceIndex[$dev.networkAddress] = $dev }
                if ($dev.hostName) { $wugDeviceIndex[$dev.hostName] = $dev }
            }
            Write-Verbose "Indexed $($wugDeviceIndex.Count) WUG devices for enrichment."
        }
        catch {
            Write-Warning "Could not retrieve WUG devices for enrichment: $($_.Exception.Message)"
        }
    }

    $dashboard = @()

    foreach ($site in $sites) {
        $siteId = $site.site_id
        $status = if ($statusIndex.ContainsKey($siteId)) { $statusIndex[$siteId] } else { $null }

        # Circuit summary from site config
        $circuitNames = @()
        $circuitTypes = @()
        $totalDownBw = 0
        $totalUpBw = 0
        if ($site.circuits) {
            foreach ($c in $site.circuits) {
                $circuitNames += $c.circuit_name
                $circuitTypes += $c.circuit_type
                $totalDownBw += $c.download_bandwidth
                $totalUpBw += $c.upload_bandwidth
            }
        }
        $circuitCount = if ($site.circuits) { $site.circuits.Count } else { 0 }

        # Circuit status summary from status endpoint
        $circuitStatuses = @()
        if ($status -and $status.circuits) {
            foreach ($cs in $status.circuits) {
                $circuitStatuses += "$($cs.wan_index):$($cs.status)"
            }
        }

        # Device status summary
        $deviceStatuses = @()
        if ($status -and $status.devices) {
            foreach ($ds in $status.devices) {
                $role = if ($ds.cpe_role) { $ds.cpe_role } else { $ds.target_type }
                $deviceStatuses += "$role=$($ds.status)"
            }
        }

        # Risk summary from status endpoint
        $risks = if ($status -and $status.risks) { $status.risks } else { @() }
        $highestRisk = "healthy"
        $riskLevels = @("site-outage", "high", "medium", "low", "healthy")
        foreach ($r in $risks) {
            $rLevel = if ($r.risk_level) { $r.risk_level } else { "healthy" }
            if ($riskLevels.IndexOf($rLevel) -lt $riskLevels.IndexOf($highestRisk)) {
                $highestRisk = $rLevel
            }
        }
        $riskCount = $risks.Count

        # LAN network summary
        $lanNetworks = @()
        if ($site.lan_networks) {
            foreach ($ln in $site.lan_networks) {
                $lanNetworks += $ln.network
            }
        }

        # CPE info
        $cpeSerials = @()
        $cpeIPs = @()
        if ($site.cpe) {
            foreach ($cpe in $site.cpe) {
                $cpeSerials += $cpe.cpe_serial
                if ($cpe.config_ip) { $cpeIPs += $cpe.config_ip }
            }
        }

        # Site status
        $siteStatus = if ($status) { $status.site_status } else { "unknown" }

        $row = [ordered]@{
            SiteId                = $siteId
            SiteName              = $site.site_name
            CompanyId             = $site.company_id
            CompanyName           = $site.company_name
            SiteStatus            = $siteStatus
            HighestRisk           = $highestRisk
            RiskCount             = $riskCount
            ServiceName           = if ($site.service) { $site.service.service_name } else { "" }
            ServiceBandwidth      = if ($site.service) { $site.service.bandwidth } else { 0 }
            ServiceBandwidthUp    = if ($site.service) { $site.service.bandwidth_up } else { 0 }
            AvailabilityConfig    = $site.availability_config
            PrimaryPop            = $site.primary_pop
            SecondaryPop          = $site.secondary_pop
            CircuitCount          = $circuitCount
            CircuitNames          = ($circuitNames -join ", ")
            CircuitTypes          = ($circuitTypes -join ", ")
            TotalDownloadBW       = $totalDownBw
            TotalUploadBW         = $totalUpBw
            CircuitStatusSummary  = ($circuitStatuses -join ", ")
            DeviceStatusSummary   = ($deviceStatuses -join ", ")
            LANNetworks           = ($lanNetworks -join ", ")
            CPESerials            = ($cpeSerials -join ", ")
            CPEIPs                = ($cpeIPs -join ", ")
            ProvisionedOn         = if ($site.provisioned_on) { $site.provisioned_on } else { "" }
            ServiceIn             = if ($site.service_in) { $site.service_in } else { "" }
        }

        # Enrich with WUG device data if available (match on CPE IPs)
        $wugDev = $null
        foreach ($ip in $cpeIPs) {
            if ($wugDeviceIndex.ContainsKey($ip)) {
                $wugDev = $wugDeviceIndex[$ip]
                break
            }
        }
        if (-not $wugDev -and $wugDeviceIndex.ContainsKey($site.site_name)) {
            $wugDev = $wugDeviceIndex[$site.site_name]
        }

        if ($wugDev) {
            $row["WUGDeviceId"]       = $wugDev.id
            $row["WUGDeviceName"]     = $wugDev.name
            $row["WUGHostName"]       = $wugDev.hostName
            $row["WUGBestState"]      = $wugDev.bestState
            $row["WUGWorstState"]     = $wugDev.worstState
            $row["WUGActiveMonitors"] = $wugDev.totalActiveMonitors
            $row["WUGMonitorsDown"]   = $wugDev.totalActiveMonitorsDown
        }
        else {
            $row["WUGDeviceId"]       = ""
            $row["WUGDeviceName"]     = ""
            $row["WUGHostName"]       = ""
            $row["WUGBestState"]      = ""
            $row["WUGWorstState"]     = ""
            $row["WUGActiveMonitors"] = ""
            $row["WUGMonitorsDown"]   = ""
        }

        $dashboard += [PSCustomObject]$row
    }

    return $dashboard
}

# ---------------------------------------------------------------------------
# Export-BigleafDashboardHtml
# ---------------------------------------------------------------------------
function Export-BigleafDashboardHtml {
    <#
    .SYNOPSIS
        Renders Bigleaf dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-BigleafDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. Uses
        colour-coded status indicators for site and circuit health.
    .PARAMETER DashboardData
        Array of objects from Get-BigleafDashboard.
    .PARAMETER OutputPath
        File path for the output HTML file.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Bigleaf Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        built-in template at helpers/bigleaf/Bigleaf-Dashboard-Template.html.
    .EXAMPLE
        $dashboard = Get-BigleafDashboard
        Export-BigleafDashboardHtml -DashboardData $dashboard -OutputPath "$env:TEMP\Bigleaf-Dashboard.html"
    .EXAMPLE
        $dashboard = Get-BigleafDashboard
        Export-BigleafDashboardHtml -DashboardData $dashboard -OutputPath "C:\Reports\bigleaf.html" -ReportTitle "Bigleaf WAN Status"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Bigleaf Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Bigleaf-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    # Build column definitions for bootstrap-table
    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'SiteStatus') {
            $col.formatter = 'formatSiteStatus'
        }
        if ($prop.Name -eq 'HighestRisk') {
            $col.formatter = 'formatRiskLevel'
        }
        if ($prop.Name -match 'WUGBestState|WUGWorstState') {
            $col.formatter = 'formatWugState'
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
    Write-Verbose "Bigleaf Dashboard HTML written to $OutputPath"
}
