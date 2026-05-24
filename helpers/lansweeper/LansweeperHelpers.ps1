# ---------------------------------------------------------------------------
# LansweeperHelpers.ps1 -- Lansweeper Data API helper functions for WhatsUpGoldPS
# ---------------------------------------------------------------------------
# Lansweeper Data API (GraphQL) -- https://developer.lansweeper.com/docs/data-api/
# Endpoint: https://api.lansweeper.com/api/v2/graphql
# Auth: Personal Access Token (PAT) or OAuth 2.0
# ---------------------------------------------------------------------------

# ---- Global session state ----
$script:LansweeperSession = @{
    BaseUri      = 'https://api.lansweeper.com/api/v2/graphql'
    TokenUri     = 'https://api.lansweeper.com/api/integrations/oauth/token'
    AuthType     = $null   # 'PAT' or 'OAuth'
    AccessToken  = $null
    RefreshToken = $null
    ClientId     = $null
    ClientSecret = $null
    ExpiresAt    = $null
    Connected    = $false
}

# ========================== Authentication ==========================

function Connect-LansweeperPAT {
    <#
    .SYNOPSIS
        Connects to the Lansweeper Data API using a Personal Access Token.
    .PARAMETER Token
        The Personal Access Token generated in Lansweeper developer tools.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token
    )
    try {
        $script:LansweeperSession.AuthType     = 'PAT'
        $script:LansweeperSession.AccessToken  = $Token
        $script:LansweeperSession.RefreshToken = $null
        $script:LansweeperSession.ClientId     = $null
        $script:LansweeperSession.ClientSecret = $null
        $script:LansweeperSession.ExpiresAt    = $null

        # Validate connectivity with a simple query
        $result = Invoke-LansweeperGraphQL -Query '{ me { id username email } }'
        if ($result.data.me) {
            $script:LansweeperSession.Connected = $true
            Write-Host "Connected to Lansweeper as $($result.data.me.username) ($($result.data.me.email))" -ForegroundColor Green
            return $result.data.me
        } else {
            throw "Authentication failed -- unable to retrieve user info."
        }
    }
    catch {
        $script:LansweeperSession.Connected = $false
        Write-Error "Failed to connect to Lansweeper with PAT: $_"
    }
}

function Connect-LansweeperOAuth {
    <#
    .SYNOPSIS
        Connects to the Lansweeper Data API using OAuth 2.0 client credentials.
    .PARAMETER ClientId
        OAuth client ID from the downloaded credentials file.
    .PARAMETER ClientSecret
        OAuth client secret from the downloaded credentials file.
    .PARAMETER AuthorizationCode
        The one-time authorization code received via callback URL redirect.
    .PARAMETER RedirectUri
        The allowed callback URL configured for the OAuth client.
    .PARAMETER RefreshToken
        An existing refresh token to skip the authorization code flow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [string]$AuthorizationCode,
        [string]$RedirectUri,
        [string]$RefreshToken
    )
    try {
        $script:LansweeperSession.ClientId     = $ClientId
        $script:LansweeperSession.ClientSecret = $ClientSecret
        $script:LansweeperSession.AuthType     = 'OAuth'

        if ($RefreshToken) {
            $script:LansweeperSession.RefreshToken = $RefreshToken
            Update-LansweeperOAuthToken
        }
        elseif ($AuthorizationCode -and $RedirectUri) {
            $body = @{
                client_id     = $ClientId
                client_secret = $ClientSecret
                grant_type    = 'authorization_code'
                code          = $AuthorizationCode
                redirect_uri  = $RedirectUri
            }
            $response = Invoke-RestMethod -Uri $script:LansweeperSession.TokenUri `
                -Method POST -ContentType 'application/json' `
                -Body ($body | ConvertTo-Json -Compress) -ErrorAction Stop

            $script:LansweeperSession.AccessToken  = $response.access_token
            $script:LansweeperSession.RefreshToken = $response.refresh_token
            $script:LansweeperSession.ExpiresAt    = (Get-Date).AddSeconds($response.expires_in - 60)
        }
        else {
            throw "Provide either -RefreshToken or both -AuthorizationCode and -RedirectUri."
        }

        # Validate connectivity
        $result = Invoke-LansweeperGraphQL -Query '{ me { id username email } }'
        if ($result.data.me) {
            $script:LansweeperSession.Connected = $true
            Write-Host "Connected to Lansweeper (OAuth) as $($result.data.me.username)" -ForegroundColor Green
            return $result.data.me
        } else {
            throw "OAuth authentication succeeded but user info query failed."
        }
    }
    catch {
        $script:LansweeperSession.Connected = $false
        Write-Error "Failed to connect to Lansweeper via OAuth: $_"
    }
}

function Update-LansweeperOAuthToken {
    <#
    .SYNOPSIS
        Refreshes the OAuth access token using the stored refresh token.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:LansweeperSession.RefreshToken) {
        throw "No refresh token available. Re-authenticate with Connect-LansweeperOAuth."
    }
    $body = @{
        client_id     = $script:LansweeperSession.ClientId
        client_secret = $script:LansweeperSession.ClientSecret
        grant_type    = 'refresh_token'
        refresh_token = $script:LansweeperSession.RefreshToken
    }
    $response = Invoke-RestMethod -Uri $script:LansweeperSession.TokenUri `
        -Method POST -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Compress) -ErrorAction Stop

    $script:LansweeperSession.AccessToken  = $response.access_token
    $script:LansweeperSession.RefreshToken = $response.refresh_token
    $script:LansweeperSession.ExpiresAt    = (Get-Date).AddSeconds($response.expires_in - 60)
    Write-Verbose "Lansweeper OAuth token refreshed. Expires at $($script:LansweeperSession.ExpiresAt)"
}

function Disconnect-Lansweeper {
    <#
    .SYNOPSIS
        Clears the Lansweeper session state.
    #>
    [CmdletBinding()]
    param()
    $script:LansweeperSession.AuthType     = $null
    $script:LansweeperSession.AccessToken  = $null
    $script:LansweeperSession.RefreshToken = $null
    $script:LansweeperSession.ClientId     = $null
    $script:LansweeperSession.ClientSecret = $null
    $script:LansweeperSession.ExpiresAt    = $null
    $script:LansweeperSession.Connected    = $false
    Write-Host "Disconnected from Lansweeper." -ForegroundColor Yellow
}

# ========================== Core GraphQL Executor ==========================

function Invoke-LansweeperGraphQL {
    <#
    .SYNOPSIS
        Executes a GraphQL query or mutation against the Lansweeper Data API.
    .PARAMETER Query
        The GraphQL query or mutation string.
    .PARAMETER Variables
        Optional hashtable of GraphQL variables.
    .PARAMETER OperationName
        Optional operation name when the query contains multiple operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Variables,
        [string]$OperationName
    )

    if (-not $script:LansweeperSession.AccessToken) {
        throw "Not connected to Lansweeper. Call Connect-LansweeperPAT or Connect-LansweeperOAuth first."
    }

    # Auto-refresh OAuth token if near expiry
    if ($script:LansweeperSession.AuthType -eq 'OAuth' -and $script:LansweeperSession.ExpiresAt) {
        if ((Get-Date) -ge $script:LansweeperSession.ExpiresAt) {
            Write-Verbose "Access token expired or near expiry -- refreshing..."
            Update-LansweeperOAuthToken
        }
    }

    # Build authorization header
    $authHeader = if ($script:LansweeperSession.AuthType -eq 'PAT') {
        "Token $($script:LansweeperSession.AccessToken)"
    } else {
        "Bearer $($script:LansweeperSession.AccessToken)"
    }

    $headers = @{
        'Content-Type'  = 'application/json'
        'Authorization' = $authHeader
    }

    $bodyObj = @{ query = $Query }
    if ($Variables)     { $bodyObj.variables     = $Variables }
    if ($OperationName) { $bodyObj.operationName = $OperationName }

    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    $response = Invoke-RestMethod -Uri $script:LansweeperSession.BaseUri `
        -Method POST -Headers $headers -Body $bodyJson -ErrorAction Stop

    if ($response.errors) {
        $errMsg = ($response.errors | ForEach-Object { $_.message }) -join '; '
        Write-Warning "Lansweeper API returned errors: $errMsg"
    }

    return $response
}

# ========================== Site & Account Queries ==========================

function Get-LansweeperCurrentUser {
    <#
    .SYNOPSIS
        Returns the currently authenticated user's profile info and site list.
    #>
    [CmdletBinding()]
    param()
    $query = @'
{
  me {
    id
    username
    email
    name
    surname
    fullName
    language
    profiles {
      id
      site {
        id
        name
      }
    }
  }
}
'@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.me
}

function Get-LansweeperSites {
    <#
    .SYNOPSIS
        Returns the sites the API client is authorized to access.
    #>
    [CmdletBinding()]
    param()
    $query = @'
{
  authorizedSites {
    sites {
      id
      name
    }
  }
}
'@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.authorizedSites.sites
}

function Get-LansweeperSiteInfo {
    <#
    .SYNOPSIS
        Returns basic information about a specific site.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId
    )
    $query = @"
{
  site(id: "$SiteId") {
    id
    name
    companyName
    logoUrl
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site
}

# ========================== Asset Type & Group Queries ==========================

function Get-LansweeperAssetTypes {
    <#
    .SYNOPSIS
        Returns all asset type names for a site.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId
    )
    $query = @"
query getAssetTypes {
  site(id: "$SiteId") {
    id
    assetTypes
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.assetTypes
}

function Get-LansweeperAssetGroups {
    <#
    .SYNOPSIS
        Returns all asset groups for a site.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId
    )
    $query = @"
query getAssetGroups {
  site(id: "$SiteId") {
    id
    assetGroups {
      name
      assetGroupKey
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.assetGroups
}

# ========================== Asset Queries ==========================

function Get-LansweeperAssets {
    <#
    .SYNOPSIS
        Queries assets from a Lansweeper site with pagination, field selection, and filtering.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER Fields
        Array of field paths to request (max 30). Defaults to common asset fields.
    .PARAMETER Limit
        Number of results per page (default 100, max 500).
    .PARAMETER Page
        Pagination page: FIRST, NEXT, PREV, LAST.
    .PARAMETER Cursor
        Pagination cursor from a previous response.
    .PARAMETER Filters
        Hashtable representing filter conditions.
    .PARAMETER All
        When set, auto-paginates to retrieve all assets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [string[]]$Fields = @(
            'assetBasicInfo.name',
            'assetBasicInfo.type',
            'assetBasicInfo.ipAddress',
            'assetBasicInfo.mac',
            'assetBasicInfo.domain',
            'assetBasicInfo.description',
            'assetBasicInfo.firstSeen',
            'assetBasicInfo.lastSeen',
            'assetCustom.manufacturer',
            'assetCustom.model',
            'assetCustom.serialNumber',
            'assetCustom.dnsName',
            'networks.ipAddressV4',
            'url'
        ),
        [ValidateRange(1, 500)][int]$Limit = 100,
        [ValidateSet('FIRST','NEXT','PREV','LAST')][string]$Page = 'FIRST',
        [string]$Cursor,
        [hashtable]$Filters,
        [switch]$All
    )

    $fieldsJson = ($Fields | ForEach-Object { "`"$_`"" }) -join ', '

    # Build pagination block
    $paginationParts = @("limit: $Limit", "page: $Page")
    if ($Cursor) { $paginationParts += "cursor: `"$Cursor`"" }
    $paginationBlock = $paginationParts -join ', '

    # Build filter block
    $filterBlock = ''
    if ($Filters) {
        $filterBlock = New-LansweeperFilterBlock -Filters $Filters
    }

    $query = @"
query getAssetResources {
  site(id: "$SiteId") {
    assetResources(
      assetPagination: { $paginationBlock }
      fields: [$fieldsJson]
      $filterBlock
    ) {
      total
      pagination {
        limit
        current
        next
        page
      }
      items
    }
  }
}
"@

    if ($All) {
        $allItems = @()
        $currentPage = 'FIRST'
        $currentCursor = $null
        $totalReported = $null

        do {
            $pagParts = @("limit: $Limit", "page: $currentPage")
            if ($currentCursor) { $pagParts += "cursor: `"$currentCursor`"" }
            $pagBlock = $pagParts -join ', '

            $iterQuery = @"
query getAssetResources {
  site(id: "$SiteId") {
    assetResources(
      assetPagination: { $pagBlock }
      fields: [$fieldsJson]
      $filterBlock
    ) {
      total
      pagination {
        limit
        current
        next
        page
      }
      items
    }
  }
}
"@
            $result = Invoke-LansweeperGraphQL -Query $iterQuery
            $assetData = $result.data.site.assetResources

            if ($null -eq $totalReported -and $null -ne $assetData.total) {
                $totalReported = $assetData.total
                Write-Verbose "Total assets reported: $totalReported"
            }

            if ($assetData.items) {
                $allItems += $assetData.items
                Write-Verbose "Retrieved $($allItems.Count) of $totalReported assets..."
            }

            $currentCursor = $assetData.pagination.next
            $currentPage = 'NEXT'

        } while ($assetData.items -and $assetData.items.Count -eq $Limit -and $currentCursor)

        return $allItems
    }
    else {
        $result = Invoke-LansweeperGraphQL -Query $query
        return $result.data.site.assetResources
    }
}

function Get-LansweeperAssetDetails {
    <#
    .SYNOPSIS
        Retrieves detailed information for a single asset by key.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER AssetKey
        The unique asset key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$AssetKey
    )
    $query = @"
{
  site(id: "$SiteId") {
    assetDetails(key: "$AssetKey") {
      key
      url
      siteId
      assetBasicInfo {
        name
        type
        subType
        typeGroup
        domain
        description
        ipAddress
        mac
        firstSeen
        lastSeen
        lastTried
        lastUpdated
        upTime
        userName
        userDomain
      }
      assetCustom {
        manufacturer
        model
        serialNumber
        dnsName
        stateName
        purchaseDate
        warrantyDate
      }
      operatingSystem {
        caption
        version
        buildNumber
        serialNumber
      }
      processors {
        name
        family
        manufacturer
        numberOfCores
        numberOfLogicalProcessors
        maxClockSpeed
      }
      memoryModules {
        caption
        size
      }
      logicalDisks {
        name
        size
        freeSpace
        fileSystem
      }
      networkAdapters {
        name
        macAddress
        speed
      }
      networks {
        ipAddressV4
        ipAddressV6
        macAddress
        subnetMask
        defaultGateway
        configuration {
          name
          state
        }
      }
      softwares {
        name
        version
        publisher
        type
      }
      warranties {
        purchaseCountry
        details {
          startDate
          endDate
        }
      }
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.assetDetails
}

# ========================== Sources & Accounts ==========================

function Get-LansweeperSources {
    <#
    .SYNOPSIS
        Lists discovery sources (installations) for a site.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId
    )
    $query = @"
{
  site(id: "$SiteId") {
    sources(pagination: { limit: 500, page: FIRST }) {
      total
      pagination { limit current next page }
      items {
        id
        type
        state { value unlinkedOnDate deletedOnDate firstSyncCompletedOn }
        createdAt
      }
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.sources
}

function Get-LansweeperAccounts {
    <#
    .SYNOPSIS
        Lists authorized accounts for a site.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId
    )
    $query = @"
{
  site(id: "$SiteId") {
    accounts {
      username
      email
      status
      createdAt
      joinedAt
      lastTimeAccess
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.accounts
}

# ========================== Vulnerabilities ==========================

function Get-LansweeperVulnerabilities {
    <#
    .SYNOPSIS
        Queries vulnerability data for a Lansweeper site. Requires Pro or Enterprise plan.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER Limit
        Results per page (default 100).
    .PARAMETER Severity
        Optional filter by severity (Critical, High, Medium, Low).
    .PARAMETER All
        Auto-paginate to retrieve all vulnerabilities.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [ValidateRange(1, 500)][int]$Limit = 100,
        [ValidateSet('Critical','High','Medium','Low')][string]$Severity,
        [switch]$All
    )

    $filterBlock = ''
    if ($Severity) {
        $filterBlock = @"
      filters: {
        conjunction: AND
        conditions: [
          { operator: EQUAL, path: "severity", value: "$Severity" }
        ]
      }
"@
    }

    if ($All) {
        $allItems = @()
        $currentPage = 'FIRST'
        $currentCursor = ''

        do {
            $query = @"
{
  site(id: "$SiteId") {
    vulnerabilities(
      pagination: { limit: $Limit, cursor: "$currentCursor", page: $currentPage }
      $filterBlock
    ) {
      total
      pagination { limit current next page }
      items {
        cve
        riskScore
        severity
        assetKeys
        attackVector
        attackComplexity
        source
        updatedOn
        publishedOn
        baseScore
        isActive
        cause {
          category
          affectedProduct
          vendor
        }
      }
    }
  }
}
"@
            $result = Invoke-LansweeperGraphQL -Query $query
            $vulnData = $result.data.site.vulnerabilities

            if ($vulnData.items) {
                $allItems += $vulnData.items
                Write-Verbose "Retrieved $($allItems.Count) vulnerabilities..."
            }

            $currentCursor = $vulnData.pagination.next
            $currentPage = 'NEXT'

        } while ($vulnData.items -and $vulnData.items.Count -eq $Limit -and $currentCursor)

        return $allItems
    }
    else {
        $query = @"
{
  site(id: "$SiteId") {
    vulnerabilities(
      pagination: { limit: $Limit, cursor: "", page: FIRST }
      $filterBlock
    ) {
      total
      pagination { limit current next page }
      items {
        cve
        riskScore
        severity
        assetKeys
        attackVector
        attackComplexity
        source
        updatedOn
        publishedOn
        baseScore
        isActive
        cause {
          category
          affectedProduct
          vendor
        }
      }
    }
  }
}
"@
        $result = Invoke-LansweeperGraphQL -Query $query
        return $result.data.site.vulnerabilities
    }
}

function Get-LansweeperPatches {
    <#
    .SYNOPSIS
        Returns Microsoft KB patch articles for a specific CVE.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER CVE
        The CVE identifier (e.g., CVE-2023-36397).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$CVE
    )
    $query = @"
{
  site(id: "$SiteId") {
    kbPatches(cve: "$CVE") {
      kb
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.kbPatches
}

# ========================== Bulk Export ==========================

function Start-LansweeperExport {
    <#
    .SYNOPSIS
        Initiates a bulk asset export (mutation) and returns the exportId.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER FilterName
        Optional filter by asset name (LIKE match).
    .PARAMETER FilterType
        Optional exact match filter by asset type.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [string]$FilterName,
        [string]$FilterType
    )

    $filterBlock = ''
    $conditions = @()
    if ($FilterName) {
        $conditions += "{ operator: LIKE, path: `"assetBasicInfo.name`", value: `"$FilterName`" }"
    }
    if ($FilterType) {
        $conditions += "{ operator: EQUAL, path: `"assetBasicInfo.type`", value: `"$FilterType`" }"
    }
    if ($conditions.Count -gt 0) {
        $condBlock = $conditions -join "`n          "
        $filterBlock = @"
      filters: {
        conjunction: AND
        conditions: [
          $condBlock
        ]
      }
"@
    }

    $mutation = @"
mutation export {
  site(id: "$SiteId") {
    exportFilteredAssets$(if ($filterBlock) { "(`n$filterBlock`n    )" } else { '' }) {
      assetBasicInfo {
        name
        type
        subType
        typeGroup
        domain
        description
        ipAddress
        mac
        firstSeen
        lastSeen
      }
      assetCustom {
        manufacturer
        model
        serialNumber
        dnsName
        stateName
      }
      operatingSystem {
        caption
        version
      }
      networks {
        ipAddressV4
        macAddress
        configuration { name state }
      }
      processors {
        name
        numberOfCores
      }
      memoryModules {
        size
      }
      exportId
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $mutation
    $exportId = $result.data.site.exportFilteredAssets.exportId
    Write-Verbose "Bulk export started with exportId: $exportId"
    return $exportId
}

function Get-LansweeperExportStatus {
    <#
    .SYNOPSIS
        Checks the status of a bulk export and returns the download URL when ready.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER ExportId
        The export ID returned by Start-LansweeperExport.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$ExportId
    )
    $query = @"
{
  site(id: "$SiteId") {
    exportStatus(exportId: "$ExportId") {
      exportId
      progress
      url
    }
  }
}
"@
    $result = Invoke-LansweeperGraphQL -Query $query
    return $result.data.site.exportStatus
}

function Wait-LansweeperExport {
    <#
    .SYNOPSIS
        Polls export status until complete, then returns the download URL.
    .PARAMETER SiteId
        The Lansweeper site GUID.
    .PARAMETER ExportId
        The export ID returned by Start-LansweeperExport.
    .PARAMETER PollIntervalSeconds
        Seconds between status checks (default 10).
    .PARAMETER TimeoutMinutes
        Maximum minutes to wait (default 30).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$ExportId,
        [int]$PollIntervalSeconds = 10,
        [int]$TimeoutMinutes = 30
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $status = Get-LansweeperExportStatus -SiteId $SiteId -ExportId $ExportId
        if ($status.url) {
            Write-Host "Export complete. Download URL available." -ForegroundColor Green
            return $status
        }
        Write-Verbose "Export progress: $($status.progress) -- polling again in ${PollIntervalSeconds}s..."
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ((Get-Date) -lt $deadline)

    Write-Warning "Export did not complete within $TimeoutMinutes minutes."
    return $status
}

# ========================== IP Resolution ==========================

function Resolve-LansweeperAssetIP {
    <#
    .SYNOPSIS
        Extracts the best available IP address from a Lansweeper asset object.
    .PARAMETER Asset
        A Lansweeper asset item (from Get-LansweeperAssets or Get-LansweeperAssetDetails).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Asset
    )
    try {
        # Priority 1: assetBasicInfo.ipAddress
        if ($Asset.assetBasicInfo -and $Asset.assetBasicInfo.ipAddress) {
            $ip = "$($Asset.assetBasicInfo.ipAddress)"
            if ($ip -and $ip -ne '' -and $ip -ne 'N/A') { return $ip }
        }

        # Priority 2: networks[].ipAddressV4 -- first non-link-local
        if ($Asset.networks) {
            foreach ($net in $Asset.networks) {
                $ipv4 = "$($net.ipAddressV4)"
                if ($ipv4 -and $ipv4 -ne '' -and -not $ipv4.StartsWith('169.254.') -and -not $ipv4.StartsWith('127.')) {
                    return $ipv4
                }
            }
        }

        # Priority 3: DNS resolution from dnsName or name
        $dnsName = $null
        if ($Asset.assetCustom -and $Asset.assetCustom.dnsName) {
            $dnsName = "$($Asset.assetCustom.dnsName)"
        }
        elseif ($Asset.assetBasicInfo -and $Asset.assetBasicInfo.name) {
            $dnsName = "$($Asset.assetBasicInfo.name)"
        }

        if ($dnsName) {
            $addresses = [System.Net.Dns]::GetHostAddresses($dnsName)
            $v4 = $addresses | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($v4) { return "$($v4.IPAddressToString)" }
        }
    }
    catch {
        Write-Verbose "Could not resolve IP for asset: $_"
    }

    return $null
}

# ========================== Filter Builder ==========================

function New-LansweeperFilterBlock {
    <#
    .SYNOPSIS
        Builds a GraphQL filter block from a hashtable.
    .PARAMETER Filters
        Hashtable with keys: conjunction (AND/OR), conditions (array of hashtables with operator, path, value).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Filters
    )
    $conjunction = if ($Filters.conjunction) { $Filters.conjunction } else { 'AND' }
    $condLines = @()
    foreach ($cond in $Filters.conditions) {
        $condLines += "{ operator: $($cond.operator), path: `"$($cond.path)`", value: `"$($cond.value)`" }"
    }
    $condBlock = $condLines -join "`n          "
    return @"
      filters: {
        conjunction: $conjunction
        conditions: [
          $condBlock
        ]
      }
"@
}

# ========================== Dashboard Aggregation ==========================

function Get-LansweeperDashboardData {
    <#
    .SYNOPSIS
        Aggregates Lansweeper asset data into a flat array for dashboard display.
    .PARAMETER SiteId
        The Lansweeper site GUID. If omitted, queries all authorized sites.
    .PARAMETER AssetTypeFilter
        Optional array of asset type names to include (e.g., 'Windows', 'Server', 'Linux').
    .PARAMETER IncludeVulnerabilities
        Include vulnerability summary counts per asset.
    #>
    [CmdletBinding()]
    param(
        [string]$SiteId,
        [string[]]$AssetTypeFilter,
        [switch]$IncludeVulnerabilities
    )

    # Determine sites to query
    $sites = @()
    if ($SiteId) {
        $siteInfo = Get-LansweeperSiteInfo -SiteId $SiteId
        $sites += [PSCustomObject]@{ id = $SiteId; name = $siteInfo.name }
    } else {
        $sites = Get-LansweeperSites
    }

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Warning "No authorized Lansweeper sites found."
        return @()
    }

    $dashboardData = @()

    foreach ($site in $sites) {
        Write-Host "Querying site: $($site.name) ($($site.id))..." -ForegroundColor Cyan

        # Build filter for asset types if specified
        $filters = $null
        if ($AssetTypeFilter -and $AssetTypeFilter.Count -gt 0) {
            # Use OR conjunction for multiple type filters
            $conditions = @()
            foreach ($typeName in $AssetTypeFilter) {
                $conditions += @{ operator = 'EQUAL'; path = 'assetBasicInfo.type'; value = $typeName }
            }
            $filters = @{ conjunction = 'OR'; conditions = $conditions }
        }

        try {
            $assets = Get-LansweeperAssets -SiteId $site.id -All -Filters $filters

            # Optionally get vulnerability data
            $vulnMap = @{}
            if ($IncludeVulnerabilities) {
                try {
                    $vulns = Get-LansweeperVulnerabilities -SiteId $site.id -All
                    foreach ($v in $vulns) {
                        foreach ($ak in $v.assetKeys) {
                            if (-not $vulnMap.ContainsKey($ak)) { $vulnMap[$ak] = @() }
                            $vulnMap[$ak] += $v
                        }
                    }
                }
                catch {
                    Write-Warning "Could not retrieve vulnerabilities for site $($site.name): $_"
                }
            }

            foreach ($asset in $assets) {
                $ip = Resolve-LansweeperAssetIP -Asset $asset

                $assetName = 'N/A'
                $assetType = 'N/A'
                $assetDomain = 'N/A'
                $assetDesc = 'N/A'
                $assetMac = 'N/A'
                $assetLastSeen = 'N/A'
                $assetManufacturer = 'N/A'
                $assetModel = 'N/A'
                $assetSerial = 'N/A'
                $assetDnsName = 'N/A'

                if ($asset.assetBasicInfo) {
                    $bi = $asset.assetBasicInfo
                    if ($bi.name)        { $assetName     = "$($bi.name)" }
                    if ($bi.type)        { $assetType     = "$($bi.type)" }
                    if ($bi.domain)      { $assetDomain   = "$($bi.domain)" }
                    if ($bi.description) { $assetDesc     = "$($bi.description)" }
                    if ($bi.mac)         { $assetMac      = "$($bi.mac)" }
                    if ($bi.lastSeen)    { $assetLastSeen = "$($bi.lastSeen)" }
                }
                if ($asset.assetCustom) {
                    $ac = $asset.assetCustom
                    if ($ac.manufacturer)  { $assetManufacturer = "$($ac.manufacturer)" }
                    if ($ac.model)         { $assetModel        = "$($ac.model)" }
                    if ($ac.serialNumber)  { $assetSerial       = "$($ac.serialNumber)" }
                    if ($ac.dnsName)       { $assetDnsName      = "$($ac.dnsName)" }
                }

                $assetKey = if ($asset.key) { "$($asset.key)" } else { 'N/A' }

                $vulnCount = 0
                $criticalCount = 0
                if ($IncludeVulnerabilities -and $vulnMap.ContainsKey($assetKey)) {
                    $assetVulns = $vulnMap[$assetKey]
                    $vulnCount = $assetVulns.Count
                    $criticalCount = ($assetVulns | Where-Object { $_.severity -eq 'Critical' }).Count
                }

                $obj = [PSCustomObject]@{
                    AssetName     = $assetName
                    AssetType     = $assetType
                    IPAddress     = if ($ip) { $ip } else { 'N/A' }
                    MACAddress    = $assetMac
                    Domain        = $assetDomain
                    Description   = $assetDesc
                    LastSeen      = $assetLastSeen
                    Manufacturer  = $assetManufacturer
                    Model         = $assetModel
                    SerialNumber  = $assetSerial
                    DnsName       = $assetDnsName
                    Site          = "$($site.name)"
                    AssetKey      = $assetKey
                    LansweeperUrl = if ($asset.url) { "$($asset.url)" } else { 'N/A' }
                }

                if ($IncludeVulnerabilities) {
                    $obj | Add-Member -NotePropertyName 'Vulnerabilities' -NotePropertyValue $vulnCount
                    $obj | Add-Member -NotePropertyName 'CriticalVulns' -NotePropertyValue $criticalCount
                }

                $dashboardData += $obj
            }

            Write-Host "  Retrieved $($assets.Count) assets from $($site.name)." -ForegroundColor Green
        }
        catch {
            Write-Warning "Error querying site $($site.name): $_"
        }
    }

    return $dashboardData
}

# ========================== HTML Dashboard Export ==========================

function Export-LansweeperDashboardHtml {
    <#
    .SYNOPSIS
        Exports Lansweeper dashboard data to an interactive HTML report.
    .PARAMETER DashboardData
        Array of dashboard PSCustomObjects from Get-LansweeperDashboardData.
    .PARAMETER OutputPath
        Path for the output HTML file.
    .PARAMETER ReportTitle
        Title displayed in the report header.
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. Defaults to Lansweeper-Dashboard-Template.html.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Lansweeper Asset Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot 'Lansweeper-Dashboard-Template.html'
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "Dashboard template not found at: $TemplatePath"
    }

    # Build column definitions from first object
    $columns = @()
    $firstObj = $DashboardData | Select-Object -First 1
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = [ordered]@{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = $DashboardData | ConvertTo-Json -Depth 5 -Compress
    $updateTime  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $template = Get-Content -Path $TemplatePath -Raw
    $html = $template `
        -replace 'replaceColumnsHere', $columnsJson `
        -replace 'replaceDataHere', $dataJson `
        -replace 'ReplaceYourReportNameHere', $ReportTitle `
        -replace 'ReplaceUpdateTimeHere', $updateTime

    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8Bom)
    Write-Host "Dashboard exported to: $OutputPath" -ForegroundColor Green
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDN1n8x8qTcFolC
# xyC4DqP8NiS6hLUTteKwSbNV9bjl16CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCg6KEtFiuF+ViTVjCEgwsuW7LjuGDFMvRBANFU2p8OljANBgkqhkiG9w0BAQEF
# AASCAgDs05KXRj6R3zte9iWq4vQ5ft+iXqbenbvUOe+dAYO/VzipKK26R5Esig0F
# mRCIXVWwpW1eT58M2b52Mk9U3rZO5lnK7SORs8gKsyPN8aJqoynCI/GAOp5eA9x+
# 5rj4sXRy6IL8FsqOxjvJ+GawnD7yd0yjqEILUoPXqik//GynzJuXqBKqTHeDweyq
# NNsHSrKBioRlIDu/EaJI9YhmKX/ZK+D/cy7zDnUXWL919zvsJXUN/nNF9+0Mqxhk
# 223/Oalxn9BkCRdMJrl1IOj+OqSQPQg1G4XNf2RadqmR/VEjVvcTOeMMMP/ExRiy
# uyYoQ2Xk8mqxgMShKQ5kuLfDirTTktNVGAKn/59sp3cEoc3+TZT9zvHb4jGP1Ogb
# oVXQByph3inETINsx8WmTaa+h9sjoQeIZc1GX8XR0yVo9S1MePWvzwtQO2HR08Ay
# Q6hJ+KP1eika87MWlWUVxCFQrob/333b8PD5qcYS/D3eek9rzC8IpbAsDIVzCY3u
# vkvslO+62PiO3J3jhaXuabuDB+4b/aUNQz/iPtv4zVrNe5/MLbUP3QKoY9CEk9cm
# Z0h6WCOXfgf3PV7GJQmoannkgJdxsQSCW2pRhiT3o30xNw3xL0eeOISglPtGiDHC
# dm+QJb0ypC2tHZfY1Tm/Xin/DRoVgjwsbwNgBLuljSJLRzj9mqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MjQxNzQxMTBaMC8GCSqGSIb3DQEJBDEiBCCdf1+3
# rDqLlm1wiqQpsTnRe7i9vg2jHAHSDWjKkVqBizANBgkqhkiG9w0BAQEFAASCAgBD
# jajgVfJb1PAEg3zbimLup2BoS/jYKLeudUIIFpMknxokfeFZO8fnBa8c4IxY3tZf
# ZSTmgAUKQvd/WGpdRGdrMQ75JUBW0SCO5qU7LBKYsd5gTtSEVOrgOOKhcUn58zz4
# gaCQDFr4hoY2h/HnLD26P13OGbeFbZ5fbg9UMKHhpB7XcQlCYpJNoezsMAw4dgJr
# etop0O+XA2P8u+ITXHZuzHii1DewszKyExZcnkVewPBz5KzrKYHBR/0g7pgC1LYW
# ttjd5yvTXWTSXiwv9vITeJOo2nNoA/VMVT+kyGfD1q0+kUWfE1NfEopQMuvuoKfj
# lsXw5WDyZBfok7trcKzgDsBuQKuS64iHm9xa78RdQGhmkPaDmEaZ0SsuFKEOVrLH
# cfHsNRrJhYJKnGueWdH/kv0bcssm7c5t6pCjq3QfVEdUa9Hb1qdIaQXy//+LXb0f
# oFv7cH7zEBzEqMvZAXqDRffjy7vMd4YExQld4eis1QEaPSFszYxS2hiBa/ZWthKO
# wzTCBF5zjS5mM0WVdZB/YZPQSfikq3AaonW4JsxMqzmH/6T01gdVbiY/orwJqeq3
# 5Rk9JmwOshLfrSl996h4cUGGNIjKZsjZCzgT53w5o4rJwC80v0VZrtvr0Qreq7HG
# +13uIs0/h7bUrAXGB+Zh4nW3+LO7GyArfn034ofqDQ==
# SIG # End signature block
