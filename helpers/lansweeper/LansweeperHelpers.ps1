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
