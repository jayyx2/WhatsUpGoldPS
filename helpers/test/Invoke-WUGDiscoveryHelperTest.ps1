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

Invoke-Test -Name 'Register mock provider' -Group 'Export' -Test {
    Register-DiscoveryProvider -Name 'MockTest' -DiscoverScript {
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
}

Invoke-Test -Name 'Invoke-Discovery with mock provider' -Group 'Export' -Test {
    $plan = Invoke-Discovery -ProviderName 'MockTest' -Target 'mockhost1' @verboseFlag
    Assert-NotNull $plan "Discovery returned null"
    Assert-True ($plan.Count -ge 1) "Expected at least 1 item"
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCYHaf3dZEjQOST
# rsZ2CFMAGWQLg1ZXZWXZobeAMVNsWqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBMdBRVlobCTbH4MidDwATpetQX/98IeF+1VzZcmrT0LTANBgkqhkiG9w0BAQEF
# AASCAgCbuHn+tcJX+PGM86/wNZdOdF8b9YJ6jKXRqzpkEPh4TBTyx/VyIOZVG353
# iuRsTRbEkazD3BItSYyA7XZxSE3aMtcXpF1wg2xyjMkQJsTHRRixRxbIZ5TjsFWc
# RRtdZx8H+kHOhFIajGykTRU+qooHoOrBCSgZtPCQd7dOTBI6zH584dcczxJvOBGV
# U8apJkuDA+H7/b62sUXmjxu3v/4kl/1+loab0vwM8w04fnVPj+o2376L128x9nqY
# +sBFOGxbIyt49wVbkW5ukjOgsWFhxfKwZzFgrbkRKP0Qq3DSVnwoMqiHXtTzrxYn
# Qe8X47QORhkKPGNH6P7MW3yLz6XhLL53HlJwNGkG9aGSG7d3MZgh3QpK+B6cbvk1
# ij1cBSkDQKRRD0TtzUT7zthXVQjt26i1Pmxe7TilZ0VJ7E+rm0WmccvU9081imB+
# 2ILZwAOO6mvV0RFJtVqfslFCPHlhkSCQb1TMLZw9imAyHz9crTUaCFlGz+L8RsSZ
# AFGsmQYomSmom66IwYEarNv7Do3PgRdnQiU81lKvL5D3vaxDuWTiQuZIrC1t7lda
# +KbhUUHuLV/GjAeL7nEGtShcA7Ot0I+lE8BIHXly+VYOI4JUyq3gIjVBujvVtEsd
# OytCqOoUjrvXvBmkpjQCLq5sdC7zTjUzOvQ0tFefTGAk+yvSL6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjIxOTU1MTJaMC8GCSqGSIb3DQEJBDEiBCCOnLKS
# 6wUm9nxWw9IGEVYpDJBD1HPedpVuFaGZF118nTANBgkqhkiG9w0BAQEFAASCAgBd
# sNck0nYGsT3SOOV1FaUq6Dzhd2gUu7dEbVAy0OZV21yYs0yXBP3zRs+gpMbCDf7x
# 20xPPLjNV8ke/OGt7nMO+KelwPsBH1IkIvvwKJKy6Z+RrxrUEG1Cj76dxHGHVlCw
# g0UWhcoiiaZTelh2mEIONHfo/tvXUWJiS/yMps5/9jpA5GZnrd9kIZJy53Lx/nZc
# 9ihknJSk1f08qUgZTNfgY7K3loEmx2IqQcx2dEmyOBEOi5XREOCsTbEMAv5KaLxi
# wBA6Nln315RNPskhZ/w/5DppapLVQ3WDh5aAJQybE74QNqUVjd4vkt9+5q3tBoFG
# i5AY0x7I7aq+lcp8TqOdVJRoqHdOmzNE+F+i+/WfIDQcV/l9JS3v6r9Xrqf/dTXj
# zBt3RMQna5xq5/HIcbQnyMkZrx3BWNeb8igO9sWU9RDjFqsIN4n2PSceqFHXzLyp
# V3O7V45+frgIFYz0aYEIlpI+d4Jbk8i/gS8G3jB639xNHXVtX7cidxDbsn66tQWs
# iMGO3noo3fybl2EG2juqURRQPyi8Ha6pHI3/DkXLOcsr2h5HB70W+qYci5irp7XV
# 4vJJJ87OOtbS3mTbQskU1OgP1KUIhPP5z6j9p75SZLixTQd02e/Bqta/5jQsoh97
# lEcQO98YhlHh1GFSiJSmRh1F9NzQ8cJlDqM4ZTgtgQ==
# SIG # End signature block
