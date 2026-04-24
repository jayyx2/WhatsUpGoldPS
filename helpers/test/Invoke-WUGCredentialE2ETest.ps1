<#
.SYNOPSIS
    End-to-end integration tests for WUG credential creation (REST API, Azure types).

.DESCRIPTION
    Tests every part of the Add-WUGCredential flow against a live WUG server:

      1.  REST API Basic Auth        — Proxmox-style (username + password)
      2.  REST API OAuth2 Client Credentials — Azure-style (token URL, client ID/secret, scope)
      3.  Azure credential type       — Service Principal (TenantId, ClientId, SecureKey)
      4.  Credential search by name   — Get-WUGCredential with -Type filter
      5.  Credential property bag validation — Verify correct bags returned for each type
      6.  Set-WUGCredential (update)  — Modify credential properties
      7.  Cleanup                     — Delete all test credentials

    Uses DPAPI vault credentials where available (Azure SP, Proxmox Token, WUG login).
    Falls back to synthetic test values when vault entries are missing.

    All test credentials are named with a WUGPS-E2E- prefix and cleaned up automatically.

.PARAMETER WUGServer
    WUG server hostname or IP. If omitted, attempts to read from vault or prompts.

.PARAMETER Credential
    PSCredential for WUG auth. If omitted, attempts to read from vault or prompts.

.PARAMETER Port
    API port. Default 9644.

.PARAMETER Protocol
    http or https. Default https.

.PARAMETER TenantId
    Azure Tenant ID for OAuth2 tests. If omitted, attempts to read from vault.

.PARAMETER SkipAzure
    Skip Azure-specific credential tests (useful if no Azure vault entry exists).

.PARAMETER SkipProxmox
    Skip Proxmox-specific credential tests.

.EXAMPLE
    .\Invoke-WUGCredentialE2ETest.ps1
    # Uses vault credentials for everything.

.EXAMPLE
    .\Invoke-WUGCredentialE2ETest.ps1 -WUGServer 192.168.74.74 -SkipAzure

.NOTES
    Author  : jason@wug.ninja
    Created : 2026-03-29
    Requires: WhatsUpGoldPS module, DiscoveryHelpers.ps1
#>
[CmdletBinding()]
param(
    [string]$WUGServer,
    [PSCredential]$Credential,
    [int]$Port = 9644,
    [ValidateSet('http', 'https')]
    [string]$Protocol = 'https',
    [string]$TenantId,
    [switch]$SkipAzure,
    [switch]$SkipProxmox
)

# ============================================================================
#region  Setup
# ============================================================================

$ErrorActionPreference = 'Continue'
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:Passed  = 0
$script:Failed  = 0
$script:Skipped = 0
$script:TestPrefix = "WUGPS-E2E-$(Get-Date -Format 'yyyyMMddHHmmss')"
$script:CreatedCredIds = [System.Collections.Generic.List[string]]::new()

function Record-Test {
    param(
        [string]$Name,
        [string]$Group,
        [string]$Status,
        [string]$Detail = ''
    )
    $script:TestResults.Add([PSCustomObject]@{
        Name   = $Name
        Group  = $Group
        Status = $Status
        Detail = $Detail
    })
    switch ($Status) {
        'Pass'    { $script:Passed++;  $color = 'Green'  }
        'Fail'    { $script:Failed++;  $color = 'Red'    }
        'Skipped' { $script:Skipped++; $color = 'Yellow' }
        default   { $color = 'Gray' }
    }
    Write-Host "  [$Status] $Name  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param(
        [string]$Name,
        [string]$Group,
        [scriptblock]$Test
    )
    try {
        $null = & $Test
        Record-Test -Name $Name -Group $Group -Status 'Pass'
    }
    catch {
        Record-Test -Name $Name -Group $Group -Status 'Fail' -Detail $_.Exception.Message
    }
}

function Assert-NotNull {
    param($Value, [string]$Message = 'Value was null or empty')
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrEmpty($Value))) {
        throw $Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$(if ($Message) { $Message + ': ' })Expected '$Expected' but got '$Actual'"
    }
}

function Assert-Contains {
    param([array]$Collection, $Value, [string]$Message)
    if ($Value -notin $Collection) {
        throw "$(if ($Message) { $Message + ': ' })Collection does not contain '$Value'"
    }
}

function Get-BagValue {
    param([array]$Bags, [string]$BagName)
    ($Bags | Where-Object { $_.name -eq $BagName } | Select-Object -First 1).value
}

#endregion

# ============================================================================
#region  Load dependencies
# ============================================================================

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " WUG Credential End-to-End Test Suite" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Prefix: $script:TestPrefix" -ForegroundColor Gray
Write-Host ""

# Load DiscoveryHelpers for vault access
$discoveryHelpersPath = Join-Path $PSScriptRoot '..\discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) {
    . $discoveryHelpersPath
    Write-Host "  Loaded DiscoveryHelpers.ps1" -ForegroundColor Green
}
else {
    Write-Warning "DiscoveryHelpers.ps1 not found — vault credentials unavailable."
}

# Load WhatsUpGoldPS module
$modulePath = Join-Path $PSScriptRoot '..\..\WhatsUpGoldPS.psd1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Host "  Loaded WhatsUpGoldPS module" -ForegroundColor Green
}
else {
    Write-Error "Cannot find WhatsUpGoldPS.psd1 at '$modulePath'"; return
}

#endregion

# ============================================================================
#region  Resolve connection credentials from vault
# ============================================================================

Write-Host "`n[0/7] Resolving credentials from vault ..." -ForegroundColor Cyan

# --- WUG Server Connection ---
if (-not $WUGServer -or -not $Credential) {
    $vaultNames = @('WUG.192.168.74.74', 'WUG.Server')
    foreach ($vn in $vaultNames) {
        try {
            $vaultData = Get-DiscoveryCredential -Name $vn -ErrorAction SilentlyContinue
            if ($vaultData) {
                # WUG vault entry is pipe-delimited: Server|Port|Protocol|Username|Password
                $wugParts = "$vaultData" -split '\|'
                if ($wugParts.Count -ge 5) {
                    if (-not $WUGServer) { $WUGServer = $wugParts[0] }
                    if (-not $Credential) {
                        $secPw = ConvertTo-SecureString $wugParts[4] -AsPlainText -Force
                        $Credential = [PSCredential]::new($wugParts[3], $secPw)
                    }
                    Write-Host "  WUG server loaded from vault: $vn" -ForegroundColor Green
                    break
                }
            }
        }
        catch { Write-Verbose "Vault '$vn' read failed: $_" }
    }
}
if (-not $WUGServer) { $WUGServer = Read-Host 'Enter WUG server hostname or IP' }
if (-not $Credential) { $Credential = Get-Credential -Message 'Enter WUG credentials' }

# --- Azure Service Principal (for OAuth2 + Azure cred tests) ---
$script:AzureCred = $null
if (-not $SkipAzure) {
    if (-not $TenantId) {
        # Try to auto-detect tenant from vault
        try {
            $vaultList = Get-DiscoveryCredential -ErrorAction SilentlyContinue
            $azEntry = $vaultList | Where-Object { $_.Name -match '^Azure\.' -and $_.Name -match 'ServicePrincipal' } | Select-Object -First 1
            if ($azEntry -and $azEntry.Name -match 'Azure\.([^.]+)\.ServicePrincipal') {
                $TenantId = $Matches[1]
                Write-Host "  Auto-detected Azure TenantId from vault: $TenantId" -ForegroundColor Green
            }
        }
        catch { }
    }
    if ($TenantId) {
        try {
            $azVaultName = "Azure.$TenantId.ServicePrincipal"
            $azBundle = Get-DiscoveryCredential -Name $azVaultName -ErrorAction SilentlyContinue
            if ($azBundle) {
                # AzureSP vault entry is pipe-delimited: TenantId|AppId|ClientSecret
                $azParts = "$azBundle" -split '\|'
                if ($azParts.Count -ge 3) {
                    $secSecret = ConvertTo-SecureString $azParts[2] -AsPlainText -Force
                    $script:AzureCred = [PSCredential]::new("$($azParts[0])|$($azParts[1])", $secSecret)
                }
                else {
                    # Single string fallback
                    $secSecret = ConvertTo-SecureString "$azBundle" -AsPlainText -Force
                    $script:AzureCred = [PSCredential]::new("$TenantId|unknown", $secSecret)
                }
                Write-Host "  Azure SP loaded from vault: $azVaultName" -ForegroundColor Green
            }
        }
        catch { Write-Verbose "Azure vault read failed: $_" }
    }
    if (-not $script:AzureCred) {
        Write-Host "  Azure SP not in vault — using synthetic test values" -ForegroundColor Yellow
        $secSecret = ConvertTo-SecureString 'synthetic-test-secret' -AsPlainText -Force
        $fakeTenant = if ($TenantId) { $TenantId } else { '00000000-0000-0000-0000-000000000000' }
        $script:AzureCred = [PSCredential]::new("$fakeTenant|synthetic-app-id", $secSecret)
        if (-not $TenantId) { $TenantId = $fakeTenant }
    }
}

# --- Proxmox Token (for Basic auth REST API test) ---
$script:ProxmoxToken = $null
if (-not $SkipProxmox) {
    try {
        $vaultList = Get-DiscoveryCredential -ErrorAction SilentlyContinue
        $pveEntry = $vaultList | Where-Object { $_.Name -match '^Proxmox\.' -and $_.Name -match 'Token' } | Select-Object -First 1
        if ($pveEntry) {
            $script:ProxmoxToken = Get-DiscoveryCredential -Name $pveEntry.Name -ErrorAction SilentlyContinue
            if ($script:ProxmoxToken) {
                Write-Host "  Proxmox token loaded from vault: $($pveEntry.Name)" -ForegroundColor Green
            }
        }
    }
    catch { }
    if (-not $script:ProxmoxToken) {
        Write-Host "  Proxmox token not in vault — using synthetic test value" -ForegroundColor Yellow
        $script:ProxmoxToken = 'user@pve!tokenid=00000000-0000-0000-0000-000000000000'
    }
}

#endregion

# ============================================================================
#region  Connect to WUG
# ============================================================================

Write-Host "`n[1/7] Connecting to $WUGServer ..." -ForegroundColor Cyan

Invoke-Test -Name 'Connect-WUGServer' -Group 'Connection' -Test {
    Connect-WUGServer -serverUri $WUGServer -Credential $Credential -Port $Port -Protocol $Protocol -IgnoreSSLErrors -ErrorAction Stop
    if (-not $global:WUGBearerHeaders) { throw 'No bearer headers after connect' }
}

if (-not $global:WUGBearerHeaders) {
    Write-Host "`n  FATAL: Authentication failed. Cannot continue." -ForegroundColor Red
    return
}

#endregion

# ============================================================================
#region  REST API — Basic Auth (Proxmox style)
# ============================================================================

Write-Host "`n[2/7] REST API credential — Basic Auth (Proxmox style) ..." -ForegroundColor Cyan

$script:BasicCredId = $null
$script:BasicCredResult = $null
$basicCredName = "$($script:TestPrefix)-restapi-basic"

if ($SkipProxmox) {
    Record-Test -Name 'Add-WUGCredential (restapi basic)' -Group 'REST-Basic' -Status 'Skipped' -Detail '-SkipProxmox'
}
else {
    Invoke-Test -Name 'Add-WUGCredential (restapi basic)' -Group 'REST-Basic' -Test {
        $result = Add-WUGCredential -Name $basicCredName `
            -Description 'E2E test — REST API Basic Auth' `
            -Type restapi `
            -RestApiUsername 'api-token' `
            -RestApiPassword $script:ProxmoxToken `
            -RestApiAuthType '0' `
            -RestApiIgnoreCertErrors 'True' `
            -Confirm:$false -ErrorAction Stop
        Assert-NotNull $result 'Add-WUGCredential returned null'
        $script:BasicCredResult = $result
        $script:BasicCredId = if ($result.id) { $result.id } elseif ($result.data.idMap.resultId) { $result.data.idMap.resultId } else { throw "No ID in result: $($result | ConvertTo-Json -Compress)" }
        $script:CreatedCredIds.Add($script:BasicCredId)
    }

    # Validate type name came back correctly
    Invoke-Test -Name 'Validate type = "rest api"' -Group 'REST-Basic' -Test {
        Assert-NotNull $script:BasicCredId 'No credential ID from previous step'
        # The creation response should have type "rest api"
        $creds = Get-WUGCredential -Type restapi -ErrorAction Stop
        $match = $creds | Where-Object { $_.id -eq $script:BasicCredId }
        Assert-NotNull $match "Credential ID $($script:BasicCredId) not found in restapi list"
        Assert-Equal 'rest api' $match.type 'Type name mismatch'
    }

    # Validate property bags from creation response
    # NOTE: GET /credentials/{id} and CredentialTemplate do NOT return property bags.
    #       Only the POST creation response includes them.
    Invoke-Test -Name 'Validate Basic Auth property bags' -Group 'REST-Basic' -Test {
        Assert-NotNull $script:BasicCredResult 'No creation result from previous step'
        $bags = $script:BasicCredResult.propertyBags
        Assert-NotNull $bags 'No propertyBags in creation response'
        # Verify AuthType = 0 (Basic)
        $authType = Get-BagValue -Bags $bags -BagName 'CredRestAPI:Authtype'
        Assert-Equal '0' $authType 'AuthType should be 0 (Basic)'
        # Verify Username is set
        $userName = Get-BagValue -Bags $bags -BagName 'CredRestAPI:Username'
        Assert-Equal 'api-token' $userName 'Username mismatch'
        # Verify no OAuth2 bags are present (Basic auth should not include GrantType, TokenUrl, etc.)
        $grantType = Get-BagValue -Bags $bags -BagName 'CredRestAPI:GrantType'
        if ($grantType) { throw "Basic auth should not have GrantType bag, got: $grantType" }
    }

    # Search by name
    Invoke-Test -Name 'Search credential by name (restapi)' -Group 'REST-Basic' -Test {
        $creds = @(Get-WUGCredential -Type restapi -ErrorAction Stop)
        $match = $creds | Where-Object { $_.name -eq $basicCredName }
        Assert-NotNull $match "Could not find credential by name '$basicCredName'"
    }
}

#endregion

# ============================================================================
#region  REST API — OAuth2 Client Credentials (Azure style)
# ============================================================================

Write-Host "`n[3/7] REST API credential — OAuth2 Client Credentials (Azure style) ..." -ForegroundColor Cyan

$script:OAuth2CredId = $null
$script:OAuth2CredResult = $null
$oauth2CredName = "$($script:TestPrefix)-restapi-oauth2"

if ($SkipAzure) {
    Record-Test -Name 'Add-WUGCredential (restapi oauth2)' -Group 'REST-OAuth2' -Status 'Skipped' -Detail '-SkipAzure'
}
else {
    # Extract SP parts from Azure credential
    $azParts = $script:AzureCred.UserName -split '\|'
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AzureCred.Password)
    try { $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $oauth2Secret = $plainSecret
    $plainSecret = $null

    Invoke-Test -Name 'Add-WUGCredential (restapi oauth2 client_credentials)' -Group 'REST-OAuth2' -Test {
        $result = Add-WUGCredential -Name $oauth2CredName `
            -Description 'E2E test — REST API OAuth2 Client Credentials' `
            -Type restapi `
            -RestApiAuthType '1' `
            -RestApiGrantType '0' `
            -RestApiTokenUrl "https://login.microsoftonline.com/$($azParts[0])/oauth2/v2.0/token" `
            -RestApiClientId $azParts[1] `
            -RestApiClientSecret $oauth2Secret `
            -RestApiScope 'https://management.azure.com/.default' `
            -Confirm:$false -ErrorAction Stop
        Assert-NotNull $result 'Add-WUGCredential returned null'
        $script:OAuth2CredResult = $result
        $script:OAuth2CredId = if ($result.id) { $result.id } elseif ($result.data.idMap.resultId) { $result.data.idMap.resultId } else { throw "No ID in result" }
        $script:CreatedCredIds.Add($script:OAuth2CredId)
    }

    # Validate property bags from creation response
    # NOTE: Only creation response includes propertyBags; GET endpoints do not.
    Invoke-Test -Name 'Validate OAuth2 property bags (from create)' -Group 'REST-OAuth2' -Test {
        Assert-NotNull $script:OAuth2CredResult 'No creation result from previous step'
        $bags = $script:OAuth2CredResult.propertyBags
        Assert-NotNull $bags 'No propertyBags in creation response'
        # Verify AuthType = 1 (OAuth2)
        $authType = Get-BagValue -Bags $bags -BagName 'CredRestAPI:Authtype'
        Assert-Equal '1' $authType 'AuthType should be 1 (OAuth2)'
        # Verify GrantType = 0 (Client Credentials)
        $grantType = Get-BagValue -Bags $bags -BagName 'CredRestAPI:GrantType'
        Assert-Equal '0' $grantType 'GrantType should be 0 (ClientCredentials)'
        # Verify TokenUrl is set
        $tokenUrl = Get-BagValue -Bags $bags -BagName 'CredRestAPI:TokenUrl'
        Assert-NotNull $tokenUrl 'TokenUrl should not be empty'
        if ($tokenUrl -notmatch 'login\.microsoftonline\.com') {
            throw "TokenUrl looks wrong: $tokenUrl"
        }
        # Verify ClientId is set
        $clientId = Get-BagValue -Bags $bags -BagName 'CredRestAPI:ClientId'
        Assert-Equal $azParts[1] $clientId 'ClientId mismatch'
        # Verify Scope is set
        $scope = Get-BagValue -Bags $bags -BagName 'CredRestAPI:Scope'
        Assert-Equal 'https://management.azure.com/.default' $scope 'Scope mismatch'
        # Verify AuthorizeUrl is empty (not required for client_credentials)
        $authUrl = Get-BagValue -Bags $bags -BagName 'CredRestAPI:AuthorizeUrl'
        if ($authUrl) { throw "AuthorizeUrl should be empty for client_credentials, got: $authUrl" }
    }

    # Validate it appears in restapi credential list
    Invoke-Test -Name 'Search OAuth2 credential by name' -Group 'REST-OAuth2' -Test {
        $creds = @(Get-WUGCredential -Type restapi -ErrorAction Stop)
        $match = $creds | Where-Object { $_.name -eq $oauth2CredName }
        Assert-NotNull $match "Could not find credential by name '$oauth2CredName'"
        Assert-Equal 'rest api' $match.type 'Type should be rest api'
    }

    # Validate GrantType is NOT authorization code (the bug we fixed)
    Invoke-Test -Name 'Verify GrantType != AuthorizationCode (2)' -Group 'REST-OAuth2' -Test {
        Assert-NotNull $script:OAuth2CredResult 'No creation result'
        $bags = $script:OAuth2CredResult.propertyBags
        Assert-NotNull $bags 'No propertyBags in creation response'
        $grantType = Get-BagValue -Bags $bags -BagName 'CredRestAPI:GrantType'
        if ($grantType -eq '2') {
            throw "GrantType is 2 (AuthorizationCode) — should be 0 (ClientCredentials). This is the bug we fixed!"
        }
        Assert-Equal '0' $grantType 'GrantType should be 0 (ClientCredentials)'
    }
}

#endregion

# ============================================================================
#region  Azure credential type (Service Principal)
# ============================================================================

Write-Host "`n[4/7] Azure credential type (Service Principal) ..." -ForegroundColor Cyan

$script:AzureCredId = $null
$script:AzureCredResult = $null
$azureCredName = "$($script:TestPrefix)-azure-sp"

if ($SkipAzure) {
    Record-Test -Name 'Add-WUGCredential (azure)' -Group 'Azure' -Status 'Skipped' -Detail '-SkipAzure'
}
else {
    $azParts = $script:AzureCred.UserName -split '\|'
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AzureCred.Password)
    try { $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $azureSecret = $plainSecret
    $plainSecret = $null

    Invoke-Test -Name 'Add-WUGCredential (azure SP)' -Group 'Azure' -Test {
        $result = Add-WUGCredential -Name $azureCredName `
            -Description 'E2E test — Azure Service Principal' `
            -Type azure `
            -AzureSecureKey $azureSecret `
            -AzureTenantID $azParts[0] `
            -AzureClientID $azParts[1] `
            -Confirm:$false -ErrorAction Stop
        Assert-NotNull $result 'Add-WUGCredential returned null'
        $script:AzureCredResult = $result
        $script:AzureCredId = if ($result.id) { $result.id } elseif ($result.data.idMap.resultId) { $result.data.idMap.resultId } else { throw "No ID in result" }
        $script:CreatedCredIds.Add($script:AzureCredId)
    }

    Invoke-Test -Name 'Validate Azure credential in type list' -Group 'Azure' -Test {
        $creds = @(Get-WUGCredential -Type azure -ErrorAction Stop)
        $match = $creds | Where-Object { $_.id -eq $script:AzureCredId }
        Assert-NotNull $match "Azure credential ID $($script:AzureCredId) not found in azure type list"
    }

    Invoke-Test -Name 'Validate Azure property bags' -Group 'Azure' -Test {
        Assert-NotNull $script:AzureCredResult 'No creation result from previous step'
        $bags = $script:AzureCredResult.propertyBags
        Assert-NotNull $bags 'No propertyBags in creation response'
        $tenantBag = Get-BagValue -Bags $bags -BagName 'CredAzure:TenantID'
        Assert-Equal $azParts[0] $tenantBag 'TenantID mismatch'
        $clientBag = Get-BagValue -Bags $bags -BagName 'CredAzure:ClientID'
        Assert-Equal $azParts[1] $clientBag 'ClientID mismatch'
    }
}

#endregion

# ============================================================================
#region  Set-WUGCredential (update + verify)
# ============================================================================

Write-Host "`n[5/7] Set-WUGCredential — update and verify ..." -ForegroundColor Cyan

# Pick the first available test credential to verify Get-by-ID works
$updateCredId = if ($script:BasicCredId) { $script:BasicCredId }
                elseif ($script:OAuth2CredId) { $script:OAuth2CredId }
                elseif ($script:AzureCredId) { $script:AzureCredId }
                else { $null }

if ($updateCredId) {
    Invoke-Test -Name 'Get-WUGCredential (by ID)' -Group 'Update' -Test {
        $byId = Get-WUGCredential -CredentialId $updateCredId -ErrorAction Stop
        Assert-NotNull $byId 'Get-WUGCredential by ID returned null'
        Assert-Equal $updateCredId $byId.id 'Credential ID mismatch'
    }
}
else {
    Record-Test -Name 'Get-WUGCredential (by ID)' -Group 'Update' -Status 'Skipped' -Detail 'No test credential available'
}

#endregion

# ============================================================================
#region  Cross-type search validation
# ============================================================================

Write-Host "`n[6/7] Cross-type search validation ..." -ForegroundColor Cyan

Invoke-Test -Name 'Get-WUGCredential (all types, no filter)' -Group 'Search' -Test {
    $all = Get-WUGCredential -Limit 100 -ErrorAction Stop
    Assert-NotNull $all 'No credentials returned'
    # Verify our test credentials appear in the unfiltered list
    foreach ($id in $script:CreatedCredIds) {
        $found = $all | Where-Object { $_.id -eq $id }
        Assert-NotNull $found "Test credential ID $id not found in unfiltered list"
    }
}

if (-not $SkipProxmox -and $script:BasicCredId) {
    Invoke-Test -Name 'Get-WUGCredential (restapi filter finds basic)' -Group 'Search' -Test {
        $restCreds = @(Get-WUGCredential -Type restapi -ErrorAction Stop)
        $match = $restCreds | Where-Object { $_.id -eq $script:BasicCredId }
        Assert-NotNull $match "Basic auth cred not in restapi filter results"
    }
}

if (-not $SkipAzure -and $script:OAuth2CredId) {
    Invoke-Test -Name 'Get-WUGCredential (restapi filter finds oauth2)' -Group 'Search' -Test {
        $restCreds = @(Get-WUGCredential -Type restapi -ErrorAction Stop)
        $match = $restCreds | Where-Object { $_.id -eq $script:OAuth2CredId }
        Assert-NotNull $match "OAuth2 cred not in restapi filter results"
    }
}

if (-not $SkipAzure -and $script:AzureCredId) {
    Invoke-Test -Name 'Get-WUGCredential (azure filter excludes restapi)' -Group 'Search' -Test {
        $azCreds = @(Get-WUGCredential -Type azure -ErrorAction Stop)
        # Azure filter should include Azure cred but NOT restapi creds
        $azMatch = $azCreds | Where-Object { $_.id -eq $script:AzureCredId }
        Assert-NotNull $azMatch "Azure cred not in azure filter"
        if ($script:OAuth2CredId) {
            $wrongMatch = $azCreds | Where-Object { $_.id -eq $script:OAuth2CredId }
            if ($wrongMatch) { throw "OAuth2 restapi cred appeared in azure type filter — type isolation broken" }
        }
    }
}

#endregion

# ============================================================================
#region  Cleanup
# ============================================================================

Write-Host "`n[7/7] Cleanup — deleting test credentials ..." -ForegroundColor Cyan

foreach ($credId in $script:CreatedCredIds) {
    Invoke-Test -Name "Set-WUGCredential (delete $credId)" -Group 'Cleanup' -Test {
        Set-WUGCredential -CredentialId $credId -Remove -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Verify cleanup
Invoke-Test -Name 'Verify all test credentials deleted' -Group 'Cleanup' -Test {
    $remaining = @(Get-WUGCredential -Limit 250 -ErrorAction Stop)
    foreach ($credId in $script:CreatedCredIds) {
        $leftover = $remaining | Where-Object { $_.id -eq $credId }
        if ($leftover) {
            throw "Credential ID $credId still exists after deletion"
        }
    }
}

#endregion

# ============================================================================
#region  Summary
# ============================================================================

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " CREDENTIAL E2E TEST RESULTS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$script:TestResults | Format-Table -AutoSize -Property @(
    @{ Label = 'Group'; Expression = { $_.Group }; Width = 14 }
    @{ Label = 'Test'; Expression = { $_.Name } }
    @{ Label = 'Status'; Expression = { $_.Status } }
    @{ Label = 'Detail'; Expression = { $_.Detail } }
)

$total = $script:Passed + $script:Failed + $script:Skipped
Write-Host "  Total: $total  |  " -NoNewline
Write-Host "Pass: $($script:Passed)" -ForegroundColor Green -NoNewline
Write-Host "  |  " -NoNewline
Write-Host "Fail: $($script:Failed)" -ForegroundColor $(if ($script:Failed -gt 0) { 'Red' } else { 'Green' }) -NoNewline
Write-Host "  |  " -NoNewline
Write-Host "Skipped: $($script:Skipped)" -ForegroundColor Yellow
Write-Host ""

if ($script:Failed -gt 0) {
    Write-Host "  FAILURES:" -ForegroundColor Red
    $script:TestResults | Where-Object { $_.Status -eq 'Fail' } | ForEach-Object {
        Write-Host "    [$($_.Group)] $($_.Name): $($_.Detail)" -ForegroundColor Red
    }
    Write-Host ""
}

# Return results for programmatic use
$script:TestResults

#endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB8n744QB8tQgYb
# Cf0P5V3WFNMsXbykANMLLKOVZOhGA6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCCucpo3+rGqHL3mz2pXNH+1W976jrUBNtYaQNEdhCP4TANBgkqhkiG9w0BAQEF
# AASCAgAt03aystI/Zz+/Nf/CfX/jgcLBWS8aeO7aIlFcS0s8kc6sm3W5FNUImD8B
# xnZoUZnoD0SUmtTlK5fEFq0Lb3G5ed7PYEg1Wll9W2VetNdS6QR3V+JFKBnA+0iD
# t0kQUahTLc87p6gEh+HnV1SCA4049dBeByUQwH7E1OW5xVsWGisTO5DDTaapOqps
# oWCAf/K/wGVqpySResN3ol9BoWKeOmllJ1OkwVVDfPEbK1F5yy8MvTZa1AKOLqDI
# ncO33y3ULl53mHnQDzxIsOEnBFn+e++iJTFd1YUwZ9C/Tw1yiL+vI5bMbvMbXKGC
# cYLiChUeWecDgeROgG69U57l0DX8Yrg+C/N839fFvVx+JzGrTuh71V+8U3V/MPva
# c6/NBx5xcRYpRB+j2Y6irPnM9flFC6SqEwNs8iiOPaJZO1bHebY/Y6v1EM0S+0FZ
# 52t09fxhDdydbhNRPnWJ5lIuvnC6c0paNLgWmiBgZaxEzxA47JqxKy50OsAyUNHM
# mOuPu16zormgWAnxBp+AgK1PBABSRmhyswNJTJO2jRqKTPZJFsDHSTVGeCepMLQY
# YKDzP1Q8/0XSIcGI/P+AfG/kV6KAe7ebV62nRzbLxNPbehlnQLw9pDpys8YIrIYj
# 1hZH3rYAsb8r8ngOoPITPHbGZcGBVUF5sTGDSd5XtbrA5PFHo6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDAwMzZaMC8GCSqGSIb3DQEJBDEiBCCsGhsS
# JoYyi+7hBMnBLRFwHH1JEgEIaUHSzTFd6kF4JjANBgkqhkiG9w0BAQEFAASCAgC+
# aV/gU9xUYz+WN8d4mlOmGjPTb3iCLsJ7oYYthrh1T+8V2gqfdxmiyxE8843K+KgA
# viXZ+K57SjYY3BleztqYpo4sSgi/KKzyJSpnI0x2jlnzuYxljzZUJEvWznU8UgLY
# i0whfFQVpXF01ILdcQppd6BHtHczpupck3ItBXxGeOKehkumOzIcJ5430w4+bDMm
# 4agqZwwR20B/kHjadJ4gUQcvotukSVe+vS3mbbQspriRyoUPgFW11KrVKoVNcB+0
# aoRalCIRvG3ZxlMh82IoOQ5sQfgpMrVfUCmrhv7xJyVOTYsx7EZpLXVP6jqBziIa
# wxZsvNr2mtdoYJTSe+rWWLCF46k6vLjRAxa+X/p8FIXEmHypj1my3afStE7ETYJT
# b3LcM4o2445SJEtbZOrlrVDF9wZD7Rrd91nJ7PBVE0pbCubeV3cGb1pvcsUuRHys
# SDnZ6rlMYGTSm0szyYSkDaY68gKmHTY2QcYCVKaPHvq7zoD15Cvg/wfE/Umzhqw5
# XeYU5VKc68NNiIQ8gLeVt7DcvjZH3+6IBIept6fGHJbQXs/HNwdM5TkfKTSdHAxj
# 6pkS/sRkNP8YQMKzorwjmPNTDEqSUDQYy6OVwtCtxN0hjDDIGad6cR1nbkNnDmeT
# 3YY9ann0GbNqtQq1pSFoyUGbpXbUjIvhMxIL0CliEQ==
# SIG # End signature block
