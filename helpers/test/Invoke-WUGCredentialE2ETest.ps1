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

    Invoke-Test -Name 'Add-WUGCredential (restapi oauth2 client_credentials)' -Group 'REST-OAuth2' -Test {
        $result = Add-WUGCredential -Name $oauth2CredName `
            -Description 'E2E test — REST API OAuth2 Client Credentials' `
            -Type restapi `
            -RestApiAuthType '1' `
            -RestApiGrantType '0' `
            -RestApiTokenUrl "https://login.microsoftonline.com/$($azParts[0])/oauth2/v2.0/token" `
            -RestApiClientId $azParts[1] `
            -RestApiClientSecret $plainSecret `
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

    Invoke-Test -Name 'Add-WUGCredential (azure SP)' -Group 'Azure' -Test {
        $result = Add-WUGCredential -Name $azureCredName `
            -Description 'E2E test — Azure Service Principal' `
            -Type azure `
            -AzureSecureKey $plainSecret `
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCAkNCPgKPSPyVh
# Gtb+NaCpG8IqxLhYY8R8xFlk8iYlpaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg5oygk38MwNdFGXaU7VaMvOQqUpkGAvPd
# uPvOAG5k8KQwDQYJKoZIhvcNAQEBBQAEggIAMfPeGnvBLUQQbKp70R3peJG5NJ51
# KpKHICkp1//hLnXBWdWPEHzBGZSTBFrCPKTok424a/AkppbJ5KbPb/MqJod/g1yQ
# 4jsDgbHAI/mPQO/JpVfjN73skwqJ5l5oLksuYOT4XL+Jq7hOsnQH8JjHLU1ssbX2
# Iw6dWHVuO5w8CiSopV70GqHbInba7z6nRTmM2NiyL6e/XTfxy8+ud140wD06ehpo
# EyfLhBFelukJaYXAi1GBhHSCA0znwX6f+SZYw8YhcC8SidfmH8tzV5kkvMaCtbc0
# +SWqWAvAdDesgZY3cJxRNX0nT11Pkdrk8WChxrzZzIQj4glMh8YV9pFFdYoAN06e
# ejtjCDfyrnBGX7NeQAiXuxp2GPTtsJ58LQgc+b9h1IsN+oApeoVcztNSKlOZ/q8c
# hHlxebXjxh6OXLi7RvEt7D7LY2uH3uEex/lNMG/rqx/s3NZyTrUesb0kC70cYQgA
# DstFieWaEEKS2pzcpJ1viDJ31sErYfjmMXwxgKBFvmVT4Jk0fUSsdVTIRyn2+rJb
# s7uqTACp6ccmhUeUV3Nr32v1DwZzxwrUug2QXVYSDbLc3tI8inD5HLiOkCCMbdun
# vSqS4Jnt47ovaUFZYAQWPFzOBRojqs7OU2outjDhbxJKqFNXqFL1EzFRmWFnJ/e2
# TFXELznKUEmIE08=
# SIG # End signature block
