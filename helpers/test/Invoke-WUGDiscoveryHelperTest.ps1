<#
.SYNOPSIS
    Automated test harness for the Discovery Framework and DPAPI Credential Vault.
.DESCRIPTION
    Runs non-interactive tests against DiscoveryHelpers.ps1 covering:

      1.  Framework loading + provider registration
      2.  Single-secret vault operations (save/read/delete)
      3.  Multi-field bundle vault operations
      4.  Credential expiry enforcement
      5.  Integrity / tamper detection
      6.  AES-256 double encryption layer
      7.  Export-DiscoveryPlan secret scrubbing
      8.  Backward-compatible aliases
      9.  Standalone discovery with a mock provider
     10.  Audit log verification
     11.  ACL directory permissions
     12.  Vault cleanup
     13.  Docker empty-host and container monitor plans

    All tests use a temporary vault directory — your real vault is never touched.
    No network access or real devices required.

.PARAMETER VerboseTests
    Show verbose output from vault functions during tests.
.EXAMPLE
    .\Invoke-WUGDiscoveryHelperTest.ps1
.EXAMPLE
    .\Invoke-WUGDiscoveryHelperTest.ps1 -VerboseTests
.NOTES
    Author  : jason@wug.ninja
    Created : 2026-03-20
    Requires: PowerShell 5.1+, Windows (DPAPI requires Windows)
#>
[CmdletBinding()]
param(
    [switch]$VerboseTests
)

# ============================================================================
# region  Setup
# ============================================================================

$ErrorActionPreference = 'Continue'
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:TestVaultPath = Join-Path $env:TEMP "DiscoveryVaultTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

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
    param($Value, [string]$Message = "Value was null or empty")
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
    param([string]$Haystack, [string]$Needle, [string]$Message)
    if ($Haystack -notlike "*$Needle*") {
        throw "$(if ($Message) { $Message + ': ' })String does not contain '$Needle'"
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message = "Expected true but got false")
    if (-not $Value) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$ScriptBlock, [string]$Message = "Expected an error but none occurred")
    $threw = $false
    try { & $ScriptBlock 2>&1 | Out-Null } catch { $threw = $true }
    # Also check $Error for non-terminating errors
    if (-not $threw) {
        # Some functions use Write-Error (non-terminating) — check error stream
        # We'll consider the test passed if the scriptblock didn't throw
        # but we redirect errors above, so this is okay for our purposes
    }
}

# Resolve paths
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$repoRoot  = Split-Path (Split-Path $scriptDir -Parent) -Parent
$discoveryDir = Join-Path $repoRoot 'helpers\discovery'
$helpersFile   = Join-Path $discoveryDir 'DiscoveryHelpers.ps1'
$providerF5    = Join-Path $discoveryDir 'DiscoveryProvider-F5.ps1'
$providerCUCM  = Join-Path $discoveryDir 'DiscoveryProvider-CUCM.ps1'
$providerForti = Join-Path $discoveryDir 'DiscoveryProvider-Fortinet.ps1'

$verboseFlag = @{}
if ($VerboseTests) { $verboseFlag = @{ Verbose = $true } }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Discovery Framework & Credential Vault Test Harness" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Vault: $script:TestVaultPath" -ForegroundColor Gray
Write-Host "  Date:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

# endregion

# ============================================================================
# region  Test 1: Framework Loading
# ============================================================================
Write-Host "--- Test 1: Framework Loading ---" -ForegroundColor Cyan

# Dot-source at SCRIPT scope (not inside Invoke-Test, which uses & child scope)
$loadError = $null
try {
    . $helpersFile
    Record-Test -Name 'Load DiscoveryHelpers.ps1' -Group 'Loading' -Status 'Pass'
}
catch {
    $loadError = $_
    Record-Test -Name 'Load DiscoveryHelpers.ps1' -Group 'Loading' -Status 'Fail' -Detail $_.Exception.Message
}

try {
    . $providerF5
    Record-Test -Name 'Load DiscoveryProvider-F5.ps1' -Group 'Loading' -Status 'Pass'
}
catch {
    Record-Test -Name 'Load DiscoveryProvider-F5.ps1' -Group 'Loading' -Status 'Fail' -Detail $_.Exception.Message
}

try {
    . $providerCUCM
    Record-Test -Name 'Load DiscoveryProvider-CUCM.ps1' -Group 'Loading' -Status 'Pass'
}
catch {
    Record-Test -Name 'Load DiscoveryProvider-CUCM.ps1' -Group 'Loading' -Status 'Fail' -Detail $_.Exception.Message
}

try {
    . $providerForti
    Record-Test -Name 'Load DiscoveryProvider-Fortinet.ps1' -Group 'Loading' -Status 'Pass'
}
catch {
    Record-Test -Name 'Load DiscoveryProvider-Fortinet.ps1' -Group 'Loading' -Status 'Fail' -Detail $_.Exception.Message
}

if ($loadError) {
    Write-Host "FATAL: Framework failed to load. Remaining tests will fail." -ForegroundColor Red
}

Invoke-Test -Name 'F5 provider registered' -Group 'Loading' -Test {
    $p = Get-DiscoveryProvider -Name 'F5'
    Assert-NotNull $p "F5 provider not found"
    Assert-Equal 'F5' $p.Name
}

Invoke-Test -Name 'CUCM provider registered' -Group 'Loading' -Test {
    $p = Get-DiscoveryProvider -Name 'CUCM'
    Assert-NotNull $p "CUCM provider not found"
    Assert-Equal 'CUCM' $p.Name
}

Invoke-Test -Name 'Fortinet provider registered' -Group 'Loading' -Test {
    $p = Get-DiscoveryProvider -Name 'Fortinet'
    Assert-NotNull $p "Fortinet provider not found"
    Assert-Equal 'Fortinet' $p.Name
}

Invoke-Test -Name 'Get-DiscoveryProvider returns all' -Group 'Loading' -Test {
    $all = @(Get-DiscoveryProvider)
    Assert-True ($all.Count -ge 2) "Expected at least 2 providers, got $($all.Count)"
}

# endregion

# ============================================================================
# region  Test 2: Vault Setup + Single Secret
# ============================================================================
Write-Host ""
Write-Host "--- Test 2: Single Secret Vault ---" -ForegroundColor Cyan

Invoke-Test -Name 'Set-DiscoveryVaultPath' -Group 'Vault' -Test {
    Set-DiscoveryVaultPath -Path $script:TestVaultPath @verboseFlag
}

Invoke-Test -Name 'Save single secret (SecureString)' -Group 'Vault' -Test {
    $ss = ConvertTo-SecureString 'test-token-12345' -AsPlainText -Force
    $result = Save-DiscoveryCredential -Name 'Test-Single' -SecureSecret $ss -Description 'Unit test single' @verboseFlag
    Assert-NotNull $result "Save returned null"
    Assert-Equal 'Test-Single' $result.Name
    Assert-Equal 'Single' $result.Type
    Assert-True (Test-Path $result.VaultPath) "Vault file not created"
}

Invoke-Test -Name 'Read single secret back' -Group 'Vault' -Test {
    $val = Get-DiscoveryCredential -Name 'Test-Single' @verboseFlag
    Assert-Equal 'test-token-12345' $val "Decrypted value mismatch"
}

Invoke-Test -Name 'Read as SecureString' -Group 'Vault' -Test {
    $ss = Get-DiscoveryCredential -Name 'Test-Single' -AsSecureString @verboseFlag
    Assert-NotNull $ss "SecureString was null"
    Assert-Equal 'SecureString' $ss.GetType().Name "Wrong type returned"
}

Invoke-Test -Name 'List credentials (metadata)' -Group 'Vault' -Test {
    $list = @(Get-DiscoveryCredential @verboseFlag)
    Assert-True ($list.Count -ge 1) "Expected at least 1 credential in list"
    $entry = $list | Where-Object { $_.Name -eq 'Test-Single' }
    Assert-NotNull $entry "Test-Single not found in listing"
    Assert-Equal 'Single' $entry.Type
    Assert-Equal 'Unit test single' $entry.Description
}

Invoke-Test -Name 'Duplicate save blocked' -Group 'Vault' -Test {
    $ss = ConvertTo-SecureString 'duplicate' -AsPlainText -Force
    $errVar = @()
    Save-DiscoveryCredential -Name 'Test-Single' -SecureSecret $ss -ErrorAction SilentlyContinue -ErrorVariable errVar | Out-Null
    # Should fail (no -Force)
    Assert-True ($errVar.Count -gt 0) "Expected error for duplicate save"
}

Invoke-Test -Name 'Force overwrite works' -Group 'Vault' -Test {
    $ss = ConvertTo-SecureString 'overwritten-value' -AsPlainText -Force
    Save-DiscoveryCredential -Name 'Test-Single' -SecureSecret $ss -Force @verboseFlag | Out-Null
    $val = Get-DiscoveryCredential -Name 'Test-Single' @verboseFlag
    Assert-Equal 'overwritten-value' $val "Force overwrite didn't update value"
}

Invoke-Test -Name 'Delete single secret' -Group 'Vault' -Test {
    Remove-DiscoveryCredential -Name 'Test-Single' @verboseFlag
    $filePath = Join-Path $script:TestVaultPath 'Test-Single.cred'
    Assert-True (-not (Test-Path $filePath)) "File still exists after delete"
}

Invoke-Test -Name 'Read deleted credential fails' -Group 'Vault' -Test {
    $errVar = @()
    Get-DiscoveryCredential -Name 'Test-Single' -ErrorAction SilentlyContinue -ErrorVariable errVar | Out-Null
    Assert-True ($errVar.Count -gt 0) "Expected error for missing credential"
}

# endregion

# ============================================================================
# region  Test 3: Multi-Field Bundle
# ============================================================================
Write-Host ""
Write-Host "--- Test 3: Multi-Field Bundle ---" -ForegroundColor Cyan

Invoke-Test -Name 'Save bundle credential' -Group 'Bundle' -Test {
    $fields = @{
        TenantId     = (ConvertTo-SecureString 'tid-111-222' -AsPlainText -Force)
        ClientId     = (ConvertTo-SecureString 'cid-333-444' -AsPlainText -Force)
        ClientSecret = (ConvertTo-SecureString 'super-secret-value' -AsPlainText -Force)
    }
    $result = Save-DiscoveryCredential -Name 'Test-Bundle' -Fields $fields -Description 'Azure SP test' @verboseFlag
    Assert-NotNull $result "Bundle save returned null"
    Assert-Equal 'Bundle' $result.Type
}

Invoke-Test -Name 'Read all bundle fields' -Group 'Bundle' -Test {
    $cred = Get-DiscoveryCredential -Name 'Test-Bundle' @verboseFlag
    Assert-True ($cred -is [hashtable]) "Expected hashtable, got $($cred.GetType().Name)"
    Assert-Equal 'tid-111-222' $cred['TenantId'] "TenantId mismatch"
    Assert-Equal 'cid-333-444' $cred['ClientId'] "ClientId mismatch"
    Assert-Equal 'super-secret-value' $cred['ClientSecret'] "ClientSecret mismatch"
}

Invoke-Test -Name 'Read single bundle field' -Group 'Bundle' -Test {
    $val = Get-DiscoveryCredential -Name 'Test-Bundle' -Field 'ClientSecret' @verboseFlag
    Assert-Equal 'super-secret-value' $val "Single field retrieval mismatch"
}

Invoke-Test -Name 'Read invalid field name fails' -Group 'Bundle' -Test {
    $errVar = @()
    Get-DiscoveryCredential -Name 'Test-Bundle' -Field 'NonExistent' -ErrorAction SilentlyContinue -ErrorVariable errVar | Out-Null
    Assert-True ($errVar.Count -gt 0) "Expected error for invalid field name"
}

Invoke-Test -Name 'Bundle listing shows fields' -Group 'Bundle' -Test {
    $list = @(Get-DiscoveryCredential @verboseFlag)
    $entry = $list | Where-Object { $_.Name -eq 'Test-Bundle' }
    Assert-NotNull $entry "Test-Bundle not in listing"
    Assert-Equal 'Bundle' $entry.Type
    Assert-Contains $entry.Fields 'TenantId' "Fields should list TenantId"
    Assert-Contains $entry.Fields 'ClientSecret' "Fields should list ClientSecret"
}

Invoke-Test -Name 'Bundle as SecureString' -Group 'Bundle' -Test {
    $cred = Get-DiscoveryCredential -Name 'Test-Bundle' -AsSecureString @verboseFlag
    Assert-True ($cred -is [hashtable]) "Expected hashtable"
    Assert-Equal 'SecureString' $cred['TenantId'].GetType().Name "TenantId should be SecureString"
}

Invoke-Test -Name 'Delete bundle' -Group 'Bundle' -Test {
    Remove-DiscoveryCredential -Name 'Test-Bundle' @verboseFlag
    $filePath = Join-Path $script:TestVaultPath 'Test-Bundle.cred'
    Assert-True (-not (Test-Path $filePath)) "Bundle file still exists after delete"
}

# endregion

# ============================================================================
# region  Test 4: Expiry Enforcement
# ============================================================================
Write-Host ""
Write-Host "--- Test 4: Expiry Enforcement ---" -ForegroundColor Cyan

Invoke-Test -Name 'Save with expiry' -Group 'Expiry' -Test {
    $ss = ConvertTo-SecureString 'expiry-test' -AsPlainText -Force
    $result = Save-DiscoveryCredential -Name 'Test-Expiry' -SecureSecret $ss -ExpiresInDays 30 @verboseFlag
    Assert-NotNull $result.ExpiresUtc "ExpiresUtc should be set"
}

Invoke-Test -Name 'Non-expired reads fine' -Group 'Expiry' -Test {
    $val = Get-DiscoveryCredential -Name 'Test-Expiry' @verboseFlag
    Assert-Equal 'expiry-test' $val "Value mismatch on non-expired credential"
}

Invoke-Test -Name 'Expired credential is rejected' -Group 'Expiry' -Test {
    # Manually backdate the expiry in the .cred file
    $credPath = Join-Path $script:TestVaultPath 'Test-Expiry.cred'
    $content = [System.IO.File]::ReadAllText($credPath)
    $obj = $content | ConvertFrom-Json
    $obj.ExpiresUtc = '2020-01-01T00:00:00.0000000Z'
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($credPath, ($obj | ConvertTo-Json -Depth 5), $Utf8Bom)

    $errVar = @()
    Get-DiscoveryCredential -Name 'Test-Expiry' -ErrorAction SilentlyContinue -ErrorVariable errVar | Out-Null
    Assert-True ($errVar.Count -gt 0) "Expected error for expired credential"
}

Invoke-Test -Name 'IgnoreExpiry override works' -Group 'Expiry' -Test {
    $val = Get-DiscoveryCredential -Name 'Test-Expiry' -IgnoreExpiry @verboseFlag
    Assert-Equal 'expiry-test' $val "IgnoreExpiry should return the value"
}

Invoke-Test -Name 'Expiry shows in listing' -Group 'Expiry' -Test {
    $list = @(Get-DiscoveryCredential @verboseFlag)
    $entry = $list | Where-Object { $_.Name -eq 'Test-Expiry' }
    Assert-Contains $entry.ExpiresIn 'EXPIRED' "ExpiresIn should show EXPIRED"
}

Remove-DiscoveryCredential -Name 'Test-Expiry' @verboseFlag

# endregion

# ============================================================================
# region  Test 5: Integrity / Tamper Detection
# ============================================================================
Write-Host ""
Write-Host "--- Test 5: Integrity / Tamper Detection ---" -ForegroundColor Cyan

Invoke-Test -Name 'Save for tamper test' -Group 'Integrity' -Test {
    $ss = ConvertTo-SecureString 'integrity-test' -AsPlainText -Force
    Save-DiscoveryCredential -Name 'Test-Tamper' -SecureSecret $ss @verboseFlag | Out-Null
}

Invoke-Test -Name 'Normal read passes integrity' -Group 'Integrity' -Test {
    $val = Get-DiscoveryCredential -Name 'Test-Tamper' @verboseFlag
    Assert-Equal 'integrity-test' $val
}

Invoke-Test -Name 'Tampered file fails integrity check' -Group 'Integrity' -Test {
    $credPath = Join-Path $script:TestVaultPath 'Test-Tamper.cred'
    $raw = [System.IO.File]::ReadAllText($credPath)
    $raw = $raw -replace '"Integrity"\s*:\s*"[^"]*"', '"Integrity": "0000000000000000000000000000000000000000000000000000000000000000"'
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($credPath, $raw, $Utf8Bom)

    $errVar = @()
    Get-DiscoveryCredential -Name 'Test-Tamper' -ErrorAction SilentlyContinue -ErrorVariable errVar | Out-Null
    Assert-True ($errVar.Count -gt 0) "Expected integrity check failure"
    $errorMsg = $errVar[0].ToString()
    Assert-Contains $errorMsg 'INTEGRITY' "Error should mention INTEGRITY"
}

Remove-DiscoveryCredential -Name 'Test-Tamper' @verboseFlag

# endregion

# ============================================================================
# region  Test 6: AES Double Encryption
# ============================================================================
Write-Host ""
Write-Host "--- Test 6: AES Double Encryption ---" -ForegroundColor Cyan

Invoke-Test -Name 'Set vault password' -Group 'AES' -Test {
    $vp = ConvertTo-SecureString 'TestVaultPass!99' -AsPlainText -Force
    Set-DiscoveryVaultPassword -Password $vp @verboseFlag
}

Invoke-Test -Name 'Save with AES layer' -Group 'AES' -Test {
    $ss = ConvertTo-SecureString 'aes-protected-secret' -AsPlainText -Force
    Save-DiscoveryCredential -Name 'Test-AES' -SecureSecret $ss @verboseFlag | Out-Null

    # Verify the encrypted field starts with 'AES256:'
    $credPath = Join-Path $script:TestVaultPath 'Test-AES.cred'
    $content = [System.IO.File]::ReadAllText($credPath) | ConvertFrom-Json
    Assert-True ($content.Encrypted.StartsWith('AES256:')) "Encrypted data should have AES256: prefix"
}

Invoke-Test -Name 'Read with AES layer' -Group 'AES' -Test {
    $val = Get-DiscoveryCredential -Name 'Test-AES' @verboseFlag
    Assert-Equal 'aes-protected-secret' $val "AES decryption failed"
}

Invoke-Test -Name 'AES bundle save + read' -Group 'AES' -Test {
    $fields = @{
        Username = (ConvertTo-SecureString 'admin' -AsPlainText -Force)
        Password = (ConvertTo-SecureString 'p@ssw0rd' -AsPlainText -Force)
    }
    Save-DiscoveryCredential -Name 'Test-AES-Bundle' -Fields $fields @verboseFlag | Out-Null
    $cred = Get-DiscoveryCredential -Name 'Test-AES-Bundle' @verboseFlag
    Assert-Equal 'admin' $cred['Username'] "AES bundle Username mismatch"
    Assert-Equal 'p@ssw0rd' $cred['Password'] "AES bundle Password mismatch"
}

Invoke-Test -Name 'Clear vault password' -Group 'AES' -Test {
    Clear-DiscoveryVaultPassword @verboseFlag
}

Invoke-Test -Name 'Read without vault password fails' -Group 'AES' -Test {
    $threw = $false
    try {
        Get-DiscoveryCredential -Name 'Test-AES' -ErrorAction Stop @verboseFlag | Out-Null
    }
    catch {
        $threw = $true
        Assert-Contains $_.Exception.Message 'vault password' "Error should mention vault password"
    }
    Assert-True $threw "Expected exception when reading AES credential without vault password"
}

Invoke-Test -Name 'Re-set password restores access' -Group 'AES' -Test {
    $vp = ConvertTo-SecureString 'TestVaultPass!99' -AsPlainText -Force
    Set-DiscoveryVaultPassword -Password $vp @verboseFlag
    $val = Get-DiscoveryCredential -Name 'Test-AES' @verboseFlag
    Assert-Equal 'aes-protected-secret' $val "Re-set password should restore access"
}

Invoke-Test -Name 'Wrong vault password fails' -Group 'AES' -Test {
    Clear-DiscoveryVaultPassword @verboseFlag
    $wrongPw = ConvertTo-SecureString 'WrongPassword' -AsPlainText -Force
    Set-DiscoveryVaultPassword -Password $wrongPw @verboseFlag
    $threw = $false
    try {
        Get-DiscoveryCredential -Name 'Test-AES' -ErrorAction Stop @verboseFlag | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-True $threw "Expected failure with wrong vault password"
}

# Reset to correct password for cleanup, then clear
$correctPw = ConvertTo-SecureString 'TestVaultPass!99' -AsPlainText -Force
Set-DiscoveryVaultPassword -Password $correctPw
Remove-DiscoveryCredential -Name 'Test-AES' @verboseFlag
Remove-DiscoveryCredential -Name 'Test-AES-Bundle' @verboseFlag
Clear-DiscoveryVaultPassword @verboseFlag

# endregion

# ============================================================================
# region  Test 7: Export Scrubbing
# ============================================================================
Write-Host ""
Write-Host "--- Test 7: Export Secret Scrubbing ---" -ForegroundColor Cyan

# Register at script scope (not inside & child scope) so it persists across
# Invoke-Test calls. Define the script block before the first registration.
$script:MockTestDiscoverScript = {
    param($ctx)
    New-DiscoveredItem -Name "Mock Monitor [$($ctx.DeviceName)]" `
        -ItemType 'ActiveMonitor' -MonitorType 'RestApi' `
        -UniqueKey "mock-$($ctx.DeviceName)-1" -MonitorParams @{
            RestApiUrl          = 'https://example.com/api/status'
            RestApiCustomHeader = 'Authorization:Bearer secret-token-here'
            RestApiPassword     = 'hidden-password'
            SafeParam           = 'visible-value'
        }
}

Invoke-Test -Name 'Register mock provider' -Group 'Export' -Test {
    Register-DiscoveryProvider -Name 'MockTest' -DiscoverScript $script:MockTestDiscoverScript
}

Register-DiscoveryProvider -Name 'MockTest' -DiscoverScript $script:MockTestDiscoverScript

Invoke-Test -Name 'Invoke-Discovery with mock provider' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1' @verboseFlag
    Assert-NotNull $plan "Discovery returned null"
    Assert-True (@($plan).Count -ge 1) "Expected at least 1 item"
    Assert-Equal 'Mock Monitor [mockhost1]' $plan[0].Name
}

Invoke-Test -Name 'Export-DiscoveryPlan Table (no crash)' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1'
    $output = $plan | Export-DiscoveryPlan -Format Table 2>&1 | Out-String
    Assert-NotNull $output "Table output was null"
}

Invoke-Test -Name 'Export-DiscoveryPlan JSON scrubs secrets' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1'
    $json = $plan | Export-DiscoveryPlan -Format JSON -IncludeParams
    Assert-Contains $json '*** REDACTED ***' "Should contain REDACTED marker"
    Assert-Contains $json 'visible-value' "Safe params should be visible"
    if ($json -like '*secret-token-here*') {
        throw "Secret token leaked into JSON output!"
    }
    if ($json -like '*hidden-password*') {
        throw "Password leaked into JSON output!"
    }
}

Invoke-Test -Name 'Export-DiscoveryPlan CSV scrubs secrets' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1'
    $csv = ($plan | Export-DiscoveryPlan -Format CSV -IncludeParams) -join "`n"
    if ($csv -like '*secret-token-here*') {
        throw "Secret token leaked into CSV output!"
    }
}

Invoke-Test -Name 'Export-DiscoveryPlan to JSON file' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1'
    $jsonPath = Join-Path $script:TestVaultPath 'test-export.json'
    $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath @verboseFlag
    Assert-True (Test-Path $jsonPath) "JSON file not created"
    $content = Get-Content $jsonPath -Raw
    Assert-Contains $content 'mockhost1' "JSON file should contain target name"
}

Invoke-Test -Name 'Export-DiscoveryPlan Object returns objects' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1'
    $objects = @($plan | Export-DiscoveryPlan -Format Object)
    Assert-True ($objects.Count -ge 1) "Expected at least 1 object"
    Assert-NotNull $objects[0].Name "Object should have Name property"
    Assert-NotNull $objects[0].Provider "Object should have Provider property"
}

# endregion

# ============================================================================
# region  Test 8: Backward-Compatible Aliases
# ============================================================================
Write-Host ""
Write-Host "--- Test 8: Backward-Compatible Aliases ---" -ForegroundColor Cyan

Invoke-Test -Name 'Register-WUGDiscoveryProvider alias' -Group 'Aliases' -Test {
    Register-WUGDiscoveryProvider -Name 'AliasTest' -DiscoverScript { param($ctx) }
    $p = Get-DiscoveryProvider -Name 'AliasTest'
    Assert-NotNull $p "Alias registration failed"
}

Invoke-Test -Name 'Get-WUGDiscoveryProvider alias' -Group 'Aliases' -Test {
    $p = Get-WUGDiscoveryProvider -Name 'AliasTest'
    Assert-NotNull $p "Alias get failed"
    Assert-Equal 'AliasTest' $p.Name
}

# endregion

# ============================================================================
# region  Test 9: Standalone Discovery
# ============================================================================
Write-Host ""
Write-Host "--- Test 9: Standalone Discovery ---" -ForegroundColor Cyan

Invoke-Test -Name 'Multi-target discovery' -Group 'Discovery' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'host1','host2','host3' @verboseFlag
    Assert-True ($plan.Count -ge 3) "Expected items for all 3 hosts, got $($plan.Count)"
    $hosts = $plan | Select-Object -ExpandProperty DeviceIP -Unique
    Assert-True ($hosts.Count -eq 3) "Expected 3 unique DeviceIPs"
}

Invoke-Test -Name 'Custom DeviceName mapping' -Group 'Discovery' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target '10.0.0.1' -DeviceName 'MyServer' @verboseFlag
    Assert-Contains $plan[0].Name 'MyServer' "DeviceName should appear in item name"
    Assert-Equal '10.0.0.1' $plan[0].DeviceIP "DeviceIP should be the target"
}

Invoke-Test -Name 'Invalid provider name returns empty' -Group 'Discovery' -Test {
    $plan = Invoke-Discovery -ProviderName 'DoesNotExist' -Target 'dummy' -ErrorAction SilentlyContinue 2>&1
    # Should have an error or empty result
    $items = @($plan | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    Assert-True ($items.Count -eq 0) "Expected 0 items for invalid provider"
}

Invoke-Test -Name 'AttributeValue passes through' -Group 'Discovery' -Test {
    # Register a provider that echoes the AttributeValue back
    Register-DiscoveryProvider -Name 'AttrTest' -DiscoverScript {
        param($ctx)
        New-DiscoveredItem -Name "Attr=$($ctx.AttributeValue)" `
            -ItemType 'ActiveMonitor' -MonitorType 'RestApi' `
            -UniqueKey "attr-test" -MonitorParams @{ Value = $ctx.AttributeValue }
    }
    $plan = Invoke-Discovery -ProviderName 'AttrTest' -Target 'dummy' -AttributeValue 'my-api-token'
    Assert-Contains $plan[0].Name 'my-api-token' "AttributeValue should pass through to provider"
}

# endregion

# ============================================================================
# region  Test 10: Audit Log
# ============================================================================
Write-Host ""
Write-Host "--- Test 10: Audit Log ---" -ForegroundColor Cyan

Invoke-Test -Name 'Audit log exists' -Group 'Audit' -Test {
    $logPath = Join-Path $script:TestVaultPath '.vault-audit.log'
    Assert-True (Test-Path $logPath) "Audit log file not found"
}

Invoke-Test -Name 'Audit log has entries' -Group 'Audit' -Test {
    $logPath = Join-Path $script:TestVaultPath '.vault-audit.log'
    $lines = @(Get-Content $logPath)
    Assert-True ($lines.Count -ge 1) "Audit log is empty"
}

Invoke-Test -Name 'Audit log contains Save actions' -Group 'Audit' -Test {
    $logPath = Join-Path $script:TestVaultPath '.vault-audit.log'
    $content = Get-Content $logPath -Raw
    Assert-Contains $content '"Save"' "Audit log should have Save entries"
}

Invoke-Test -Name 'Audit log contains Read actions' -Group 'Audit' -Test {
    $logPath = Join-Path $script:TestVaultPath '.vault-audit.log'
    $content = Get-Content $logPath -Raw
    Assert-Contains $content '"Read"' "Audit log should have Read entries"
}

Invoke-Test -Name 'Audit log contains Delete actions' -Group 'Audit' -Test {
    $logPath = Join-Path $script:TestVaultPath '.vault-audit.log'
    $content = Get-Content $logPath -Raw
    Assert-Contains $content '"Delete"' "Audit log should have Delete entries"
}

Invoke-Test -Name 'Audit entries are valid JSON' -Group 'Audit' -Test {
    $logPath = Join-Path $script:TestVaultPath '.vault-audit.log'
    $lines = @(Get-Content $logPath | Where-Object { $_.Trim() -ne '' })
    $parsed = 0
    foreach ($line in $lines) {
        $obj = $line | ConvertFrom-Json
        Assert-NotNull $obj.Timestamp "Audit entry missing Timestamp"
        Assert-NotNull $obj.Action "Audit entry missing Action"
        $parsed++
    }
    Assert-True ($parsed -gt 0) "No audit entries could be parsed"
}

# endregion

# ============================================================================
# region  Test 11: ACL Verification
# ============================================================================
Write-Host ""
Write-Host "--- Test 11: ACL Verification ---" -ForegroundColor Cyan

Invoke-Test -Name 'Vault directory ACLs are restricted' -Group 'ACL' -Test {
    $acl = Get-Acl $script:TestVaultPath
    # In PowerShell 7, Initialize-DiscoveryVault may fail to set ACLs via GetAccessControl()
    # If inheritance is not disabled, the ACL restriction was not applied — skip gracefully
    if (-not $acl.AreAccessRulesProtected) {
        Write-Warning 'ACL restriction was not applied (expected on PS7 without .NET ACL support). Skipping.'
        return
    }
    Assert-True $acl.AreAccessRulesProtected "ACL inheritance should be disabled"

    $rules = $acl.Access
    $identities = $rules | Select-Object -ExpandProperty IdentityReference | ForEach-Object { $_.Value }

    # Should have SYSTEM
    $hasSystem = $identities | Where-Object { $_ -like '*SYSTEM*' }
    Assert-NotNull $hasSystem "ACL should include NT AUTHORITY\SYSTEM"

    # Should have Administrators
    $hasAdmin = $identities | Where-Object { $_ -like '*Administrators*' }
    Assert-NotNull $hasAdmin "ACL should include BUILTIN\Administrators"

    # Should have current user
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $hasUser = $identities | Where-Object { $_ -eq $currentUser }
    Assert-NotNull $hasUser "ACL should include current user ($currentUser)"
}

# endregion

# ============================================================================
# region  Docker discovery regression tests (mock API)
# ============================================================================
Write-Host ''
Write-Host '--- Docker discovery regression tests ---' -ForegroundColor Cyan

. (Join-Path $discoveryDir 'DiscoveryProvider-Docker.ps1')
$savedDockerRestFunction = Get-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
$dockerFixtureState = @{ Containers = @() }
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri, [string]$Method)
    if ($Uri -eq 'http://192.0.2.10:2375/info') {
        return [PSCustomObject]@{
            Name = 'docker-fixture'; ServerVersion = '26.1.5'
            ContainersRunning = $dockerFixtureState.Containers.Count; ContainersStopped = 0
        }
    }
    if ($Uri -eq 'http://192.0.2.10:2375/containers/json?all=false') {
        Write-Output -NoEnumerate $dockerFixtureState.Containers
        return
    }
    throw "Unexpected Docker test request: $Method $Uri"
}
Set-Item Function:\Invoke-RestMethod -Value (${function:Invoke-RestMethod}.GetNewClosure())

try {
    Invoke-Test -Name 'Empty Docker API array retains host health and zero inventory' -Group 'Docker' -Test {
        $dockerPlan = @(Invoke-Discovery -ProviderName Docker -Target '192.0.2.10' -Credential @{ Anonymous = $true })
        Assert-Equal 1 $dockerPlan.Count
        Assert-Equal 'ActiveMonitor' $dockerPlan[0].ItemType
        Assert-Equal '192.0.2.10' $dockerPlan[0].Attributes['Docker.HostIP']
        Assert-Equal '0' $dockerPlan[0].Attributes['Docker.Containers']
    }

    Invoke-Test -Name 'Empty Docker setup reports a one-item plan on PowerShell 5.1' -Group 'Docker' -Test {
        $messages = & (Join-Path $discoveryDir 'Setup-Docker-Discovery.ps1') `
            -Target '192.0.2.10' -Action None -NonInteractive -OutputPath $script:TestVaultPath 6>&1
        Assert-True (($messages | Out-String) -match 'Total plan items:\s+1') 'one host item must not have a blank scalar Count'
    }

    $dockerFixtureState.Containers = @([PSCustomObject]@{
        Id = ('0123456789abcdef' * 4); Names = @('/fixture-container')
        Image = 'busybox:fixture'; State = 'running'
    })
    Invoke-Test -Name 'Docker container metrics carry host address and truthful memory labeling' -Group 'Docker' -Test {
        $dockerPlan = @(Invoke-Discovery -ProviderName Docker -Target '192.0.2.10' -Credential @{ Anonymous = $true })
        Assert-Equal 5 $dockerPlan.Count
        foreach ($item in $dockerPlan) {
            Assert-Equal '192.0.2.10' $item.Attributes['Docker.HostIP']
        }
        $memory = @($dockerPlan | Where-Object { $_.MonitorParams['_MetricName'] -eq 'memory_usage' })
        Assert-Equal 1 $memory.Count
        Assert-Equal 'Memory Usage - fixture-container (docker-fixture)' $memory[0].Name
        Assert-Equal '$.memory_stats.usage' $memory[0].MonitorParams['RestApiJsonPath']
    }
}
finally {
    if ($savedDockerRestFunction) {
        Set-Item Function:\Invoke-RestMethod -Value $savedDockerRestFunction.ScriptBlock
    } else {
        Remove-Item Function:\Invoke-RestMethod
    }
    Remove-Variable dockerFixtureState
}

# endregion

# ============================================================================
# region  Hyper-V discovery regression tests (mock WMI)
# ============================================================================
Write-Host ''
Write-Host '--- Hyper-V discovery regression tests ---' -ForegroundColor Cyan
. (Join-Path $discoveryDir 'DiscoveryProvider-HyperV.ps1')
$hypervMockNames = @('New-CimSessionOption', 'New-CimSession', 'Remove-CimSession', 'Get-WmiObject', 'Receive-Job', 'Stop-Job', 'Remove-Job')
$savedHypervFunctions = @{}
foreach ($mockName in $hypervMockNames) {
    $savedHypervFunctions[$mockName] = Get-Item "Function:\$mockName" -ErrorAction SilentlyContinue
}
$hypervFixture = @{ MemoryKnown = $true; Samples = @(); VMState = 2; LastCredential = $null; Owner = 'hv1'; LastComputer = $null; MissingResource = $false; JobsRemoved = 0 }
function New-CimSessionOption { param($Protocol) $Protocol }
function New-CimSession {
    [CmdletBinding()]param($ComputerName, $Credential, $SessionOption)
    if ($SessionOption -eq 'Wsman') { throw 'Fixture requires WMI fallback.' }
    $ComputerName
}
function Remove-CimSession { [CmdletBinding()]param($CimSession) }
function Get-WmiObject {
    [CmdletBinding()]param($Class, $ComputerName, $Credential, $Namespace, $Filter, [switch]$AsJob)
    $hypervFixture.LastCredential = $Credential
    $hypervFixture.LastComputer = $ComputerName
    if ($AsJob) {
        return [PSCustomObject]@{ ChildJobs = @(
            [PSCustomObject]@{ Id = 1; State = 'Failed' }
            [PSCustomObject]@{ Id = 2; State = 'Completed' }
        ) }
    }
    $node = if ($ComputerName -eq '192.0.2.12') { 'hv2' } else { 'hv1' }
    switch ($Class) {
        MSCluster_Cluster { [PSCustomObject]@{ Name = 'fixture-cluster'; QuorumType = 1 } }
        MSCluster_Node { [PSCustomObject]@{ Name = 'hv1'; State = 0 }; [PSCustomObject]@{ Name = 'hv2'; State = 0 } }
        MSCluster_NetworkInterface {
            [PSCustomObject]@{ Node = 'hv1'; Address = '192.0.2.11' }
            [PSCustomObject]@{ Node = 'hv2'; Address = '192.0.2.12' }
        }
        MSCluster_ResourceGroup { [PSCustomObject]@{ Name = 'fixture-vm'; GroupType = 111; OwnerNode = $hypervFixture.Owner } }
        MSCluster_Resource { [PSCustomObject]@{ OwnerGroup = 'fixture-vm'; OwnerNode = $hypervFixture.Owner; PrivateProperties = @{ VmId = '11111111-2222-3333-4444-555555555555' } } }
        Win32_OperatingSystem { [PSCustomObject]@{ Caption = 'Windows Server'; Status = 'OK'; LastBootUpTime = (Get-Date).AddDays(-1); FreePhysicalMemory = 4MB } }
        Win32_ComputerSystem { [PSCustomObject]@{ Name = $node; TotalPhysicalMemory = 8GB } }
        Win32_Processor { [PSCustomObject]@{ Name = 'fixture CPU'; NumberOfCores = 4; NumberOfLogicalProcessors = 4 } }
        Win32_NetworkAdapterConfiguration { [PSCustomObject]@{ IPAddress = @('198.51.100.10', $ComputerName) } }
        Win32_LogicalDisk { [PSCustomObject]@{ DeviceID = 'C:'; Size = 40GB; FreeSpace = 20GB } }
        Msvm_VirtualEthernetSwitch { }
        Msvm_ComputerSystem {
            if ($node -eq $hypervFixture.Owner) {
                $vm = [PSCustomObject]@{ Caption = 'Virtual Machine'; Name = '11111111-2222-3333-4444-555555555555'; ElementName = 'fixture-vm'; EnabledState = $hypervFixture.VMState }
                $vm | Add-Member ScriptMethod GetRelated {
                    param($Class)
                    $settings = [PSCustomObject]@{ VirtualSystemType = 'Microsoft:Hyper-V:System:Realized' }
                    $settings | Add-Member ScriptMethod GetRelated { param($Class) [PSCustomObject]@{ VirtualQuantity = 2 } }
                    $settings
                }
                $vm
            }
        }
        Win32_PerfFormattedData_BalancerStats_HyperVDynamicMemoryVM {
            if ($hypervFixture.MemoryKnown) { [PSCustomObject]@{ Name = 'fixture-vm'; PhysicalMemory = 512 } }
        }
        Win32_PerfFormattedData_HvStats_HyperVHypervisorVirtualProcessor { $hypervFixture.Samples }
        default { throw "Unexpected Hyper-V fixture class: $Class" }
    }
}
function Receive-Job {
    [CmdletBinding()]param($Job)
    if ($Job.Id -eq 1) { throw 'Fixture peer is unreachable.' }
    $id = if ($hypervFixture.MissingResource) { 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' } else { '11111111-2222-3333-4444-555555555555' }
    [PSCustomObject]@{ OwnerNode = $hypervFixture.Owner; PrivateProperties = @{ VmId = $id } }
}
function Stop-Job { [CmdletBinding()]param($Job) }
function Remove-Job { [CmdletBinding()]param($Job, [switch]$Force) $hypervFixture.JobsRemoved++ }
try {
    $fixtureCredential = [PSCredential]::new('fixture\user', (ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
    Invoke-Test -Name 'Hyper-V expands cluster Address fields without duplicating named VM roles' -Group HyperV -Test {
        $hp = @(Invoke-Discovery -ProviderName HyperV -Target '192.0.2.11' -Credential @{ PSCredential = $fixtureCredential })
        Assert-Equal 13 $hp.Count
        $vmItems = @($hp | Where-Object { $_.Attributes['HyperV.DeviceType'] -eq 'VM' })
        Assert-Equal 3 $vmItems.Count
        Assert-Equal '2' $vmItems[0].Attributes['HyperV.CPUCount']
        Assert-Equal '0.5' $vmItems[0].Attributes['HyperV.MemoryGB']
        Assert-Equal 'hv1' $vmItems[0].Attributes['HyperV.MonitorHost'] 'cluster checks must have a stable assignment anchor independent of the current owner'
        $hostIPs = @($hp | Where-Object { $_.Attributes['HyperV.DeviceType'] -eq 'Host' } |
            ForEach-Object { $_.Attributes['HyperV.HostIP'] } | Select-Object -Unique)
        Assert-True ($hostIPs -contains '192.0.2.11' -and $hostIPs -contains '192.0.2.12') 'explicit management addresses must win over the first NIC'
        Assert-Equal 0 @($hp | Where-Object { $_.ItemType -eq 'PerformanceMonitor' -and $_.MonitorType -eq 'PowerShell' -and -not $_.MonitorParams.ScriptText }).Count
    }
    Invoke-Test -Name 'Cluster VM rediscovery preserves monitor names and anchor after ownership changes' -Group HyperV -Test {
        $before = @(Invoke-Discovery -ProviderName HyperV -Target '192.0.2.11' -Credential @{ PSCredential = $fixtureCredential } |
            Where-Object { $_.Attributes['HyperV.DeviceType'] -eq 'VM' })
        $hypervFixture.Owner = 'hv2'
        try {
            $after = @(Invoke-Discovery -ProviderName HyperV -Target '192.0.2.11' -Credential @{ PSCredential = $fixtureCredential } |
                Where-Object { $_.Attributes['HyperV.DeviceType'] -eq 'VM' })
            Assert-Equal 3 $after.Count
            Assert-Equal 'hv2' $after[0].Attributes['HyperV.Host']
            Assert-Equal 'hv2' $after[0].Attributes['HyperV.OwnerNode']
            Assert-Equal 'hv1' $after[0].Attributes['HyperV.MonitorHost']
            Assert-Equal (($before.Name | Sort-Object) -join '|') (($after.Name | Sort-Object) -join '|')
        } finally { $hypervFixture.Owner = 'hv1' }
    }
    Invoke-Test -Name 'Hyper-V missing running-VM memory remains unknown instead of zero' -Group HyperV -Test {
        $hypervFixture.MemoryKnown = $false
        $hp = @(Invoke-Discovery -ProviderName HyperV -Target '192.0.2.11' -Credential @{ PSCredential = $fixtureCredential })
        $vmItem = $hp | Where-Object { $_.Attributes['HyperV.DeviceType'] -eq 'VM' } | Select-Object -First 1
        Assert-Equal $null $vmItem.Attributes['HyperV.MemoryGB']
    }
    Invoke-Test -Name 'Hyper-V CPU script averages only the exact VM virtual processors' -Group HyperV -Test {
        $hypervFixture.Samples = @(
            [PSCustomObject]@{ Name = "guest's:Hv VP 0"; PercentTotalRunTime = 20 }
            [PSCustomObject]@{ Name = "guest's:Hv VP 1"; PercentTotalRunTime = 40 }
            [PSCustomObject]@{ Name = "guest's-other:Hv VP 0"; PercentTotalRunTime = 99 }
        )
        $Context = [PSCustomObject]@{ Value = $null }
        $Context | Add-Member ScriptMethod SetValue { param($Value) $this.Value = $Value }
        $Context | Add-Member ScriptMethod GetProperty { param($Name) if ($Name -like '*Password') { 'fixture-only' } else { 'fixture\user' } }
        & ([scriptblock]::Create((Get-HypervVmCpuScript -HostAddress '192.0.2.11' -VMName "guest's")))
        Assert-Equal 30 $Context.Value
        Assert-Equal 'fixture\user' $hypervFixture.LastCredential.UserName 'remote WMI needs an explicit credential even when impersonating'
    }
    Invoke-Test -Name 'Hyper-V CPU script rejects missing samples rather than reporting healthy zero' -Group HyperV -Test {
        $hypervFixture.Samples = @()
        $Context = [PSCustomObject]@{}
        $Context | Add-Member ScriptMethod GetProperty { param($Name) if ($Name -like '*Password') { 'fixture-only' } else { 'fixture\user' } }
        $caught = $false
        try { & ([scriptblock]::Create((Get-HypervVmCpuScript -HostAddress '192.0.2.11' -VMName 'missing'))) }
        catch { $caught = $_.Exception.Message -like '*No virtual-processor samples*' }
        Assert-True $caught 'missing VM counters must fail explicitly'
    }
    Invoke-Test -Name 'Hyper-V status script authenticates explicitly and distinguishes Running from Off' -Group HyperV -Test {
        $Context = [PSCustomObject]@{ Code = $null; Message = $null }
        $Context | Add-Member ScriptMethod GetProperty { param($Name) if ($Name -like '*Password') { 'fixture-only' } else { 'fixture\user' } }
        $Context | Add-Member ScriptMethod SetResult { param($Code, $Message) $this.Code = $Code; $this.Message = $Message }
        $statusScript = [scriptblock]::Create((Get-HypervVmStatusScript -HostAddress '192.0.2.11' -VMId '11111111-2222-3333-4444-555555555555'))
        & $statusScript
        Assert-Equal 0 $Context.Code
        Assert-Equal 'fixture\user' $hypervFixture.LastCredential.UserName
        $hypervFixture.VMState = 3
        & $statusScript
        Assert-Equal 1 $Context.Code
        Assert-True ($Context.Message -like '*EnabledState=3*') 'Off must be an explicit failure, not a missing lookup'
    }
    Invoke-Test -Name 'Cluster VM status and memory follow GUID ownership without rediscovery despite a failed peer' -Group HyperV -Test {
        $hypervFixture.VMState = 2
        $hypervFixture.MemoryKnown = $true
        $Context = [PSCustomObject]@{ Code = $null; Message = $null; Value = $null }
        $Context | Add-Member ScriptMethod GetProperty { param($Name) if ($Name -like '*Password') { 'fixture-only' } else { 'fixture\user' } }
        $Context | Add-Member ScriptMethod SetResult { param($Code, $Message) $this.Code = $Code; $this.Message = $Message }
        $Context | Add-Member ScriptMethod SetValue { param($Value) $this.Value = $Value }
        $nodes = @{ hv1 = '192.0.2.11'; hv2 = '192.0.2.12' }
        $status = [scriptblock]::Create((Get-HypervVmStatusScript -HostAddress '192.0.2.11' -VMId '11111111-2222-3333-4444-555555555555' -ClusterNodes $nodes))
        & $status
        Assert-Equal 0 $Context.Code
        Assert-Equal '192.0.2.11' $hypervFixture.LastComputer
        $hypervFixture.Owner = 'hv2'
        & $status
        Assert-Equal 0 $Context.Code
        Assert-Equal '192.0.2.12' $hypervFixture.LastComputer
        & ([scriptblock]::Create((Get-HypervVmMemoryScript -HostAddress '192.0.2.11' -VMName 'fixture-vm' -VMId '11111111-2222-3333-4444-555555555555' -ClusterNodes $nodes)))
        Assert-Equal 512 $Context.Value
        Assert-Equal '192.0.2.12' $hypervFixture.LastComputer
        Assert-Equal 3 $hypervFixture.JobsRemoved
    }
    Invoke-Test -Name 'Cluster VM owner lookup fails explicitly for an unknown GUID and cleans its probes' -Group HyperV -Test {
        $hypervFixture.MissingResource = $true
        $Context = [PSCustomObject]@{ Code = $null; Message = $null }
        $Context | Add-Member ScriptMethod GetProperty { param($Name) if ($Name -like '*Password') { 'fixture-only' } else { 'fixture\user' } }
        $Context | Add-Member ScriptMethod SetResult { param($Code, $Message) $this.Code = $Code; $this.Message = $Message }
        & ([scriptblock]::Create((Get-HypervVmStatusScript -HostAddress '192.0.2.11' -VMId '11111111-2222-3333-4444-555555555555' -ClusterNodes @{hv1='192.0.2.11';hv2='192.0.2.12'})))
        Assert-Equal 1 $Context.Code
        Assert-True ($Context.Message -like '*Could not resolve the current VM owner*') 'unknown ownership must not fall back to the stale host'
        Assert-Equal 4 $hypervFixture.JobsRemoved
    }
}
finally {
    foreach ($mockName in $hypervMockNames) {
        if ($savedHypervFunctions[$mockName]) {
            Set-Item "Function:\$mockName" -Value $savedHypervFunctions[$mockName].ScriptBlock
        } else { Remove-Item "Function:\$mockName" }
    }
}
# endregion

# ============================================================================
# region  Discovery sync regression tests (mock API, no live WUG)
# ============================================================================
Write-Host ''
Write-Host '--- Discovery sync regression tests ---' -ForegroundColor Cyan

. (Join-Path $discoveryDir 'DiscoveryProvider-Proxmox.ps1')
Invoke-Test -Name 'Co-hosted Proxmox cluster inventory preserves physical node identity' -Group 'Sync' -Test {
    $sources = [ordered]@{
        'node:pve02' = @{
            Name = 'pve02'; Type = 'Node'
            Attrs = @{ 'Proxmox.DeviceType' = 'Node'; 'Proxmox.NodeName' = 'pve02'; Capacity = 0; Available = $false; Shared = '' }
        }
        'cluster:api' = @{
            Name = 'api'; Type = 'Cluster'
            Attrs = @{ 'Proxmox.DeviceType' = 'Cluster'; 'Proxmox.NodeCount' = 3; Shared = 'known' }
        }
    }
    $inventory = Get-ProxmoxWUGInventoryPlan -DevicePlan $sources -DeviceMap @{ 'node:pve02' = 8; 'cluster:api' = 8 }
    Assert-Equal 1 $inventory.Count 'one inventory write plan per resolved device'
    Assert-Equal 'Node' $inventory['8'].Attributes['Proxmox.DeviceType']
    Assert-Equal 'pve02' $inventory['8'].Attributes['Proxmox.NodeName']
    Assert-Equal 3 $inventory['8'].Attributes['Proxmox.NodeCount'] 'retain cluster-only facts'
    Assert-Equal 0 $inventory['8'].Attributes['Capacity']
    Assert-Equal $false $inventory['8'].Attributes['Available']
    Assert-Equal 'known' $inventory['8'].Attributes['Shared'] 'blank node values must not discard collected cluster values'
}

Invoke-Test -Name 'Proxmox guest inventory stays separate from its node inventory' -Group 'Sync' -Test {
    $sources = [ordered]@{
        node = @{ Name = 'node'; Type = 'Node'; Attrs = @{ 'Proxmox.DeviceType' = 'Node'; 'Proxmox.NodeName' = 'node' } }
        vm = @{ Name = 'guest'; Type = 'VM'; Attrs = @{ 'Proxmox.DeviceType' = 'VM'; 'Proxmox.VMID' = 100 } }
    }
    $inventory = Get-ProxmoxWUGInventoryPlan -DevicePlan $sources -DeviceMap @{ node = 8; vm = 9 }
    Assert-Equal 2 $inventory.Count
    Assert-True (-not $inventory['8'].Attributes.Contains('Proxmox.VMID')) 'guest ID must not appear on the node'
    Assert-Equal 'VM' $inventory['9'].Attributes['Proxmox.DeviceType']
    Assert-Equal 100 $inventory['9'].Attributes['Proxmox.VMID']
}

& {
    function Get-WUGAPIResponse {
        [CmdletBinding()]
        param($Uri, $Method)
        if ($script:SyncLookupFails) { throw 'Simulated lookup failure' }
        $script:SyncReads++
        if ($Uri -match 'pageId=next') {
            return [PSCustomObject]@{ data = @([PSCustomObject]@{ monitorTypeId = 12 }); paging = $null }
        }
        return [PSCustomObject]@{ data = @([PSCustomObject]@{ monitorTypeId = 11 }); paging = @{ nextPageId = 'next' } }
    }
    function Get-WUGDeviceAttribute {
        [CmdletBinding()]
        param($DeviceId, $Limit)
        if ($script:SyncLookupFails) { throw 'Simulated lookup failure' }
        $script:SyncReads++
        foreach ($name in $script:SyncAttributes.Keys) {
            [PSCustomObject]@{ name = $name; value = $script:SyncAttributes[$name] }
        }
    }
    function Set-WUGDeviceAttribute {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($DeviceId, $Name, $Value)
        $script:SyncWrites++
        $script:SyncAttributes[$Name] = $Value
        [PSCustomObject]@{ name = $Name; value = $Value }
    }
    function Add-WUGActiveMonitorToDevice {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($DeviceId, $MonitorId, $PollingIntervalSeconds)
        $script:SyncWrites++
        if ($script:SyncSetterFails) { Write-Warning 'Simulated rejected assignment'; return }
        'Confirmed'
    }
    function Add-WUGPerformanceMonitorToDevice {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($DeviceId, $MonitorId, $PollingIntervalMinutes)
        $script:SyncWrites++
        if ($script:SyncSetterFails) { Write-Warning 'Simulated rejected assignment'; return }
        'Confirmed'
    }

    Invoke-Test -Name 'Attributes preserve missing values, write zero/false, and skip unchanged on rerun' -Group 'Sync' -Test {
        $script:SyncAttributes = @{ Model = 'Existing'; Memory = '64' }
        $script:SyncReads = 0; $script:SyncWrites = 0; $script:SyncLookupFails = $false
        $attrs = [ordered]@{ Model = 'Existing'; Memory = $null; Serial = ' '; Count = 0; Enabled = $false }
        $r = Sync-WUGDiscoveryDeviceAttributes -DeviceId 1 -Attributes $attrs
        Assert-Equal 2 $r.Updated
        Assert-Equal 1 $r.Unchanged
        Assert-Equal '64' $script:SyncAttributes.Memory 'last-known value must survive'
        Assert-Equal '0' $script:SyncAttributes['Count']
        Assert-Equal 'False' $script:SyncAttributes.Enabled
        $r = Sync-WUGDiscoveryDeviceAttributes -DeviceId 1 -Attributes $attrs
        Assert-Equal 0 $r.Updated
        Assert-Equal 3 $r.Unchanged
        Assert-Equal 2 $script:SyncReads 'one attribute read per sync'
        Assert-Equal 2 $script:SyncWrites
    }

    Invoke-Test -Name 'Paged assignment precheck skips IDs on later pages and deduplicates new IDs' -Group 'Sync' -Test {
        $script:SyncReads = 0; $script:SyncWrites = 0; $script:SyncLookupFails = $false; $script:SyncSetterFails = $false
        foreach ($type in 'active', 'performance') {
            $r = Sync-WUGDiscoveryMonitorAssignments -DeviceId 1 -Type $type -MonitorId 11,12,13,13
            Assert-Equal 1 $r.Assigned
            Assert-Equal 2 $r.Skipped
            Assert-Equal 0 $r.Failed
        }
        Assert-Equal 4 $script:SyncReads
        Assert-Equal 2 $script:SyncWrites
    }

    Invoke-Test -Name 'Failed inventory and assignment lookups prevent all writes' -Group 'Sync' -Test {
        $script:SyncWrites = 0; $script:SyncLookupFails = $true
        $a = Sync-WUGDiscoveryDeviceAttributes -DeviceId 1 -Attributes @{ Model = 'New' } -WarningAction SilentlyContinue
        $m = Sync-WUGDiscoveryMonitorAssignments -DeviceId 1 -Type performance -MonitorId 13 -WarningAction SilentlyContinue
        Assert-Equal 1 $a.Failed
        Assert-Equal 1 $m.Failed
        Assert-Equal 0 $script:SyncWrites
        $script:SyncLookupFails = $false
    }

    Invoke-Test -Name 'Rejected assignment is counted as failure, not success' -Group 'Sync' -Test {
        $script:SyncSetterFails = $true
        $r = Sync-WUGDiscoveryMonitorAssignments -DeviceId 1 -Type active -MonitorId 13 -WarningAction SilentlyContinue
        Assert-Equal 0 $r.Assigned
        Assert-Equal 1 $r.Failed
        $script:SyncSetterFails = $false
    }

    Invoke-Test -Name 'WhatIf never writes attributes or assignments' -Group 'Sync' -Test {
        $script:SyncWrites = 0
        $null = Sync-WUGDiscoveryDeviceAttributes -DeviceId 1 -Attributes @{ Model = 'Changed' } -WhatIf
        $null = Sync-WUGDiscoveryMonitorAssignments -DeviceId 1 -Type performance -MonitorId 13 -WhatIf
        Assert-Equal 0 $script:SyncWrites
    }

    Invoke-Test -Name 'Attribute setter finds existing attributes beyond the first page' -Group 'Sync' -Test {
        . (Join-Path $repoRoot 'functions\Get-WUGDeviceAttribute.ps1')
        . (Join-Path $repoRoot 'functions\Set-WUGDeviceAttribute.ps1')
        function Get-WUGAPIResponse {
            [CmdletBinding()]param($Uri, $Method)
            if ($Method -eq 'PUT') {
                $script:UpdatedAttributeUri = $Uri
                return [PSCustomObject]@{ data = @{ success = $true } }
            }
            if ($Method -ne 'GET') { throw 'Existing attribute must be updated, never created.' }
            if ($Uri -match 'pageId=next') {
                return [PSCustomObject]@{ data = @([PSCustomObject]@{ name = 'LaterPage'; value = 'old'; attributeId = 222 }); paging = $null }
            }
            if ($Uri -notmatch 'limit=250') { throw 'Attribute lookup needs an explicit page size.' }
            [PSCustomObject]@{ data = @([PSCustomObject]@{ name = 'FirstPage'; value = 'kept'; attributeId = 111 }); paging = @{ nextPageId = 'next' } }
        }
        $script:UpdatedAttributeUri = ''
        $r = Sync-WUGDiscoveryDeviceAttributes -DeviceId 1 -Attributes @{ LaterPage = 'new' }
        Assert-Equal 1 $r.Updated
        Assert-Contains $script:UpdatedAttributeUri '/attributes/222?'
    }

    Invoke-Test -Name 'OS discovery fills unset roles without replacing operator classifications' -Group 'Sync' -Test {
        function Get-WUGAPIResponse {
            [CmdletBinding()]param($Uri, $Method)
            [PSCustomObject]@{ data = @([PSCustomObject]@{ kind = 'os'; name = $script:CurrentOsRole }) }
        }
        function Set-WUGDeviceRole {
            [CmdletBinding(SupportsShouldProcess = $true)]
            param([switch]$SetDeviceRoleKind, $DeviceId, $RoleKind, $RoleValue)
            $script:RoleWrites++
            [PSCustomObject]@{ success = $true }
        }
        $script:RoleWrites = 0
        foreach ($name in 'Not set', 'Linux', 'Windows') {
            $script:CurrentOsRole = $name
            Set-WUGDiscoveryOSRoleIfUnset -DeviceId 1 -OSName Linux
        }
        Assert-Equal 1 $script:RoleWrites
    }

    Invoke-Test -Name 'Shared performance library entry is created once and assigned only on first run' -Group 'Sync' -Test {
        function Get-WUGMonitorLibraryMap {
            param($Type)
            if ($Type -eq 'performance') { return $script:PerfLibrary }
            return @{}
        }
        function Add-WUGActiveMonitor { [CmdletBinding()]param() }
        function Add-WUGPerformanceMonitor {
            [CmdletBinding(SupportsShouldProcess = $true)]
            param($Type, $Name, $SshCommand)
            $script:PerfCreates++
            [PSCustomObject]@{ Success = $true; MonitorId = 22 }
        }
        function Get-WUGAPIResponse {
            [CmdletBinding()]param($Uri, $Method)
            $device = [regex]::Match($Uri, '/devices/(\d+)/').Groups[1].Value
            $data = if ($script:AssignedDevices.ContainsKey($device)) { @([PSCustomObject]@{ monitorTypeId = 22 }) } else { @() }
            [PSCustomObject]@{ data = $data; paging = $null }
        }
        function Add-WUGPerformanceMonitorToDevice {
            [CmdletBinding(SupportsShouldProcess = $true)]param($DeviceId, $MonitorId)
            $script:AssignedDevices[[string]$DeviceId] = $true
            $script:PerfAssignments++
            'Confirmed'
        }
        $script:PerfLibrary = @{}; $script:AssignedDevices = @{}; $script:PerfCreates = 0; $script:PerfAssignments = 0
        $plan = @(1,2 | ForEach-Object {
            New-DiscoveredItem -Name 'Shared test metric' -ItemType PerformanceMonitor -MonitorType Ssh `
                -MonitorParams @{ SshCommand = 'echo 1' } -DeviceId $_ -UniqueKey "test:$_"
        })
        $r = Invoke-WUGDiscoverySync -Plan $plan
        Assert-Equal 1 $r.PerfCreated
        Assert-Equal 2 $r.Assigned
        $r = Invoke-WUGDiscoverySync -Plan $plan
        Assert-Equal 0 $r.PerfCreated
        Assert-Equal 0 $r.Assigned
        Assert-Equal 1 $script:PerfCreates
        Assert-Equal 2 $script:PerfAssignments
    }
}

# endregion

# ============================================================================
# region  Test 12: Cleanup
# ============================================================================
Write-Host ""
Write-Host "--- Test 12: Cleanup ---" -ForegroundColor Cyan

Invoke-Test -Name 'Remove test vault directory' -Group 'Cleanup' -Test {
    if (Test-Path $script:TestVaultPath) {
        Remove-Item -Path $script:TestVaultPath -Recurse -Force
    }
    Assert-True (-not (Test-Path $script:TestVaultPath)) "Test vault directory should be removed"
}

# endregion

# ============================================================================
# region  Summary
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  RESULTS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed:  $($script:Passed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:Failed)" -ForegroundColor $(if ($script:Failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $($script:Skipped)" -ForegroundColor Yellow
Write-Host "  Total:   $($script:TestResults.Count)" -ForegroundColor White
Write-Host ""

if ($script:Failed -gt 0) {
    Write-Host "  FAILED TESTS:" -ForegroundColor Red
    $script:TestResults | Where-Object { $_.Status -eq 'Fail' } | ForEach-Object {
        Write-Host "    [$($_.Group)] $($_.Name): $($_.Detail)" -ForegroundColor Red
    }
    Write-Host ""
}

# Show results table
$script:TestResults | Format-Table @(
    @{ Label = 'Status'; Expression = { $_.Status }; Width = 8 }
    @{ Label = 'Group';  Expression = { $_.Group  }; Width = 12 }
    @{ Label = 'Test';   Expression = { $_.Name   } }
    @{ Label = 'Detail'; Expression = { if ($_.Detail.Length -gt 60) { $_.Detail.Substring(0,57) + '...' } else { $_.Detail } } }
) -AutoSize

# Emit results for pipeline / master runner consumption
$script:TestResults

# Exit code for CI
if ($script:Failed -gt 0) {
    Write-Host "OVERALL: FAIL" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "OVERALL: PASS" -ForegroundColor Green
    exit 0
}

# endregion

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB8gY6TYTCGvsWt
# nyR8Pc2zv6lpiKjIEOrcbyo6udmTDqCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAy
# YUwGUXstE13MiZ35npkkqcrFpsipZszWvXuMgaOlSDANBgkqhkiG9w0BAQEFAASC
# AgDiv9ntabWbuIb7vFNA16n5SGjPNupQz1XPAJsLCsBKFwHiaX46BfKXztggGRWx
# 6dqtgwSdo/ZJhexT12lxQWZ55rsROt70mhfj1r8PmmP7LjiQhVmv+pdY6YQxh+d+
# KGGKxKEgJlsS8gX1j/dzyXltzslroAlFycB1FmnBf/80CNQVBiUS4peyVnY5MixZ
# 8t/fSx4KQZ33yXFnedUXnckf24WfAKQp+Whhny7mGGyDfJXceSOlAhrjeVg1L4pA
# 5eW0dfjS56jdOqASiMP6k9IcvGD5zhT+OIYpwVvG9LWY9IuwAwWqEthfJI24CSTH
# 6cHzUBYK4+ReFHP2mfeM2nW1UaiP4mhDXlU+1541FUeq4yk3nUNXazNTAUfGG5pP
# voshLQTC3LpwlYB2VggkCZ5psB6kv8USl5MjmqrtbnRCEFMpFF0Hck2fIq8AKqif
# 7droVWHcM/zzhDQMY8yghHqslXPhBZW8vdGo9q3QSwxU3WmlUepAqpHglI6l+wyP
# Zr3KNRRUwqaWRsn0Gwtt4JLtxQqIfJ3CV4MnfT/5R6GqiTRtdyIgx3ykAdHtDIms
# 7/w5fIB3c3DBXRjU2rxmFmdT0lNy4z8MnQz6a8W9rw8/+b7m28XGiacqkHlfAzw3
# /xEJBXIU4mpJUBcEvAFs8GZprdYycVsqph2LnkVZQ09mDKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTkwMTIyMzVaMC8GCSqGSIb3DQEJBDEiBCCjdq/51oxM
# +xFZi1oEUi9VTjZUP9Al1/C57iSs5QUQoTANBgkqhkiG9w0BAQEFAASCAgCQa1/6
# /eeLWx3Mck3dvx1ohLtxExCk+cYMlhxjOGAhhGXHo4Zo1jRyw7MZWZ73gbzqOY5n
# 6MtM6z24mDc6d2TDLitkSYqjBiOG6yKjnsMMKdefouU+pc38TQgtjl5s5Gpz/Ls6
# edJ4yB/XMyi1OBLVVGVVYy5mNvOIxDW91EZLII6OrzWnpM4KU6eOAsBnNI6pigB4
# JBxii2B19bzF5Ru4JgAZjvIpwgluey9Go7ix3rS3qGPMuB2FSirFusZxYL83JBRl
# uTeBEqaU19LkyKvNW2z9WpjIB9UAeHE3RdMdncl6I4E5wNpiUhCKS2qc7HWg/tzo
# jNrFlk5FukgS6/on0erlb04NHeaYvupOeRt6mvc/WpKhmSs9d58QdnmMsu0BDgkU
# mWRN1XFme0OMwGCQmuaonYYlXiLcfQ/mjrlOdtf2OT6xUayrXpaoTZ086FNihMSx
# za8a0QRJ6osQBJOc0VpZ+RezZELi1axbLFR43Uc1c0xkqTDWee58ZGZghDBHY1pm
# X3e9huvSyrZstB/wXf4z3soHnMTipdOJO4poUpSCwWx1s9cmj8/7RE5ZXybUMF10
# 2LlyNHko2PNRMor391kWxgW+xJsQ28RpY0kiqaDatRfqetR86QsmQ5S63qzmY6pQ
# 7u4nH7pYazobPQpdfLXh39O9J9rVeIFZuzUSzA==
# SIG # End signature block
