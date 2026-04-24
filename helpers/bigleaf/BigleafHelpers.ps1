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
    $password = $null; $pair = $null

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

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBGpNJOvKYhNYZP
# LK5BmLq/Pz1NA+ECB6gHUAkQdf0iK6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDEVMS0ltDsdZ1dY+/Fy/Kn970ZEGHyO8V8qJTgOdj2+DANBgkqhkiG9w0BAQEF
# AASCAgCw8jfC3rQF27GOS2ob+zMxE15uaW5nSFW0a6hdfEFUWNPvTbfUvXFrMO5O
# mOMq6ZIl+35fU9Z0TWHLyax+IpExhvPiuuqrFW/uDnKBNIDcCjwMbUzpNUpEFU43
# 9sbGiWLOe7lXVuk+EGKQZK7X916BA4/zGXnf3NfaqLBURuI6ETNz493xnPtU/LwW
# wB/20IOn5Qph9/jnisOtj07FtSdy2iwYdGBwoRxLhDuAR+4B1vo4DingGBFrYMGL
# T/VkQqfUjwUImVK8eaV49q73XfR471NvACSROil2RiVkIePHZfqUCD1nbu7LbAWm
# a9wyifjFDY71oVJo0y1l2s7k3moCngygKM72vz0Ore5xgSeKgRpdHeUIBLKSQjKJ
# emO9Is2Bpae18ZWtSvE4IhMQH4467X0O6WCbCkU2YDlgE/OlrOh+GCC9o3H9ofsh
# aG5tPzMzBhcj6tdRXmB9VPhVyNELpPsTynb0btvsWRutPaaLux3gqDK3Gmqo49mF
# WcBvkDVEbG+9I03o3khx4vxp0jpse760R5+HAmgRJBruOSfMFCBqKNAQnOWgYOfa
# Lon9tWseyt0gubIU7vYaG+UI2EqsP4+FNviSrDFP1MtrNBAt6fAcBtqhf459SBfk
# 0C6FsgGv8Lls72PD6/PHkQWL4fUHCU3uM7kXbvn7gLLhRqke3aGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDE2MzRaMC8GCSqGSIb3DQEJBDEiBCDnV6LG
# GTWIVxWCBvHIebJwN6By1Xtb0fRKPzRpeLlFbjANBgkqhkiG9w0BAQEFAASCAgA9
# tszn6Bi095/O5PZsC91wi5PNrQ5bFRmP3XH0jajeY2+rJR3rA/4RFYpU/mHwFtyc
# hBYuPdM5Lr/AZyJq635NYw5tuNldonR01+F+AacS7d0XqfsmO9bKs45xrrF84Pm1
# bipwwf8YHVYTZ7UcoSthIQR2wIWZopFJ4jQsMEeaMr1B6kR138C8cov6yEJev1Ub
# R4dHNJUD+JJYJTK3XOianyiZRgbSzXmJgMF1ENWugCi18/IFXBXDIjPTL/nhU1G3
# Sc8Ykj22cyo2HTucpE3mseEXQUzd+F/9CFcDdeQqWYpMFdxrYSFngCw8YlN0S+e0
# /9HyE45xRkljSQ9C3IEEpkao9E2iy8p2yTIj7XxxZehtFLi7A1craX05VxtrTe0z
# hnlvjQTzO+Ru9DFcvLyxDT397V/o9s9xeCCXJ06fiNjiARYdB5fikrxtPvqnkFnQ
# gqf609uZlEA4WsUI4zDlzn8kO25NtdNEx1zWVJB21U5ZK02E2yVwDSh5IG+s3CpI
# pv4zlMp72i5lRuJksOvc0h+2MTwVE5/nqXt558P/EhMmlreGQe2auAwVolnSU1Ub
# 8WF6GYEg+5+hGJ424nKPL3nO2qnZ+ZqYFt38ssJEnGKYredsN0Bi7jFAmnCwzsNY
# 0pk5mgBg6BuQROq4KlVDB9P/LCNExL7fYodFCuXp+g==
# SIG # End signature block
