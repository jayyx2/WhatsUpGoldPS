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

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCw64iCaQJq3LT0
# N0hx0ede4nqt30t6ybejtxyrEN04gKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgHTwwOMCygCBsQCUCg4iDxq5mzKK8nP3d
# TwgOdmwZ/MYwDQYJKoZIhvcNAQEBBQAEggIAbbOs84UWZiqeE4cRzpos1j8ctk+D
# wpn6mnmzZh3DMyRtxC4Ay/eOlwYxXsitxDe4hmYYQgMaGBOYjFvxoVM6cLv6BarI
# S2zWYqsvgMoKiXrgl10ulYZHF7qphaGPARpOWmPFFZKQoIVDL1cIJ/FfP1qn/zre
# JvJ5mXFHSZXDazvRw2TMjS9J3hYA0pNlV3CJqFgAjGla+H6P8lbwAN2VV9+o5kC4
# cZBvIgSfBZMLdioEZA0QM79bqgTwBV2z61LpSYsTzwJ5Bd1fvcnHvRepuHEizEDv
# J8aKPj9EEn1SKBbX7Suf0Jzze1pVBFK4oewVDseG2DZ/C5DeypontfsAvM/p/UzO
# svbEuaMyBKOL9RCzJzZEV5oL1szPNVKgXucMC2eTV43Y3hGvQ0/eMPONDfm/zoZy
# kStH5R+RbHKk/JrBQ+gMZDYAB+Fe8joCTuqFXZ4k6v2qXv6loajL4aUAZmrQBenn
# oxs4lzTQoHINITtyKBbj9Uk/otK1A3yzFOcRDIgyhGDrOeugzwS9A+ibx0Q1Q4IX
# 4lKCVFccGHlENCmQHdosPPzFOXSyeBMkaldK+5ia7z6xuz9tiw82uUhduHfvGhiJ
# h8se/R2Nyhi7kSIlx+G5eS8W8L/uoOGxGgBYLqO/9F0Ce5Mbb2vthQgAWGvwFQfU
# 1NYRwJF0eOBLig0=
# SIG # End signature block
