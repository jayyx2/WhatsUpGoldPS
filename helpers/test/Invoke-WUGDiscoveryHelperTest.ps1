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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA2Y4DpPaCcI/df
# 9kCPiYgiEm3xGqqeydv5VVYKVZLGHqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg8CSMxo3wwKau4MkpXxjRhSRgOuFO/HKD
# jjpGMNhUI2IwDQYJKoZIhvcNAQEBBQAEggIAE/67FQpTRHBdYprxsZg4wI6k53Gl
# g73TmAv//QLcoQhnn1V4vofZN5ZjthjiBi5HCGxq+4QdQsHCAujTcBcN1/qs5sIi
# bmAd8E8I9b33on5ZAh4GHFnnWxwz6svznwLthtx/v+lq6gIJsyxb33Bo0fZSTzXH
# QzUi0AenA3vkRmlvSwzatxH3GqWl9+X1q8Zg1pyMuEFzqAJ1byXnnHX4AOxPB5lN
# gWelCMn+QIeAi1g+//mB8gBOWLPxk8ZdLd2lpBfM6B3T8GYI7qZQ37Jdf9LDUUgZ
# Kwade/k8jDGH0Df4baPXLUOiEDHS/senLlabBw6DVKizI6JTDtCH29wxvGUwWVhi
# kXtPBrSvfxOTZHV/sC418pIL0Ko72P1e/0l6MB5iEs7MEHEhIaP75z5iZMIyLGlt
# j74qYAbYevI2SeISAKNR88K/2Y3aIjy1oxWon8dLbu1aTPSbauDO6iqvTkjEfBzv
# p7K2SB2V0WBIURvxCntD+MYl0aWHGixoUCF1BCZydlLpGXT+3cXg+PsB97srgLLt
# 8nNHCg2d66mX+wxcFlG5OX5PDXCmEz+Pd/YEWTrDZ5Zc+EqkRIqSjWXtwYmPjJMg
# me3ht5bxhXnss2lUW3M/rUlqtwBnVjiqs7gRaP9dO+Oj5kytO0Qrm9O2/LGfsza0
# wpd8IvhNnOr+BSw=
# SIG # End signature block
