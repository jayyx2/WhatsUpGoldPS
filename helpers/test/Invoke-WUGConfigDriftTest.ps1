#requires -Version 5.1
<#
.SYNOPSIS
    Offline test harness for the configuration drift auditing helpers.
.DESCRIPTION
    Exercises normalization, the diff engine, the baseline store, policy rules
    and peer-group comparison in helpers/config-drift/ConfigDriftHelpers.ps1.
    Uses a temporary baseline store and requires no network or devices.
.EXAMPLE
    .\Invoke-WUGConfigDriftTest.ps1
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+
#>
[CmdletBinding()]
param()

$script:Passed = 0
$script:Failed = 0

function Record-Test {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    if ($Status -eq 'Pass') { $script:Passed++; $color = 'Green' } else { $script:Failed++; $color = 'Red' }
    Write-Host "  [$Status] $Name  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    try {
        $null = & $Test
        Record-Test -Name $Name -Status 'Pass'
    }
    catch {
        Record-Test -Name $Name -Status 'Fail' -Detail $_.Exception.Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$(if ($Message) { $Message + ': ' })Expected '$Expected' but got '$Actual'"
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message = 'Expected true but got false')
    if (-not $Value) { throw $Message }
}

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
$helpersFile = Join-Path $repoRoot 'helpers\config-drift\ConfigDriftHelpers.ps1'
$testStore = Join-Path $env:TEMP "ConfigDriftTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Configuration Drift Test Harness' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  Store: $testStore" -ForegroundColor Gray

try {
    . $helpersFile
    Record-Test -Name 'Load ConfigDriftHelpers.ps1' -Status 'Pass'
}
catch {
    Record-Test -Name 'Load ConfigDriftHelpers.ps1' -Status 'Fail' -Detail $_.Exception.Message
    Write-Host 'FATAL: helpers failed to load.' -ForegroundColor Red
    return
}

Write-Host ''
Write-Host '--- Normalization ---' -ForegroundColor Cyan

$iosConfig = @'
Building configuration...

Current configuration : 4231 bytes
!
! Last configuration change at 10:32:11 UTC Mon Sep 28 2026
!
version 15.2
hostname CORE-SW1
!
ntp clock-period 17179860
ntp server 10.0.0.1
!
line vty 0 4
 transport input ssh
!
end
'@

Invoke-Test -Name 'Volatile IOS lines removed' -Test {
    $vendor = Get-ConfigVendorProfile -Name 'cisco-ios'
    $lines = @(ConvertTo-NormalizedConfig -Config $iosConfig -IgnorePattern $vendor.IgnorePattern -CommentPrefix $vendor.CommentPrefix)
    Assert-True (@($lines | Where-Object { $_ -like 'Building configuration*' }).Count -eq 0) 'Building configuration should be dropped'
    Assert-True (@($lines | Where-Object { $_ -like 'Current configuration*' }).Count -eq 0) 'Current configuration should be dropped'
    Assert-True (@($lines | Where-Object { $_ -like '*Last configuration change*' }).Count -eq 0) 'change timestamp should be dropped'
    Assert-True (@($lines | Where-Object { $_ -like 'ntp clock-period*' }).Count -eq 0) 'ntp clock-period should be dropped'
    Assert-True (@($lines | Where-Object { $_ -eq 'hostname CORE-SW1' }).Count -eq 1) 'hostname should survive'
    Assert-True (@($lines | Where-Object { $_ -eq 'ntp server 10.0.0.1' }).Count -eq 1) 'ntp server should survive'
}

Invoke-Test -Name 'Comment and blank lines removed' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config "alpha`n`n# note`nbravo" -CommentPrefix '#')
    Assert-Equal 2 $lines.Count
    Assert-Equal 'alpha' $lines[0]
    Assert-Equal 'bravo' $lines[1]
}

Invoke-Test -Name 'Trailing whitespace ignored' -Test {
    $a = @(ConvertTo-NormalizedConfig -Config "hostname R1   ")
    $b = @(ConvertTo-NormalizedConfig -Config "hostname R1")
    Assert-Equal (Get-ConfigHash -Lines $a) (Get-ConfigHash -Lines $b)
}

Write-Host ''
Write-Host '--- Volatile blocks ---' -ForegroundColor Cyan

$certConfigA = @'
hostname CORE-SW1
crypto pki certificate chain TP-self-signed-4294967295
 certificate self-signed 01
  30820330 30820218 A0030201 02020101 300D0609 2A864886
  05050030 31312F30 2D060355 04031326 494F532D 53656C66
  	quit
ntp server 10.0.0.1
'@

$certConfigB = @'
hostname CORE-SW1
crypto pki certificate chain TP-self-signed-4294967295
 certificate self-signed 01
  AF91C220 7B3D1188 C0030201 02020101 300D0609 2A864886
  6611BE04 91220F30 2D060355 04031326 494F532D 53656C66
  	quit
ntp server 10.0.0.1
'@

Invoke-Test -Name 'Regenerated certificate body is not drift' -Test {
    $vendor = Get-ConfigVendorProfile -Name 'cisco-ios'
    $a = @(ConvertTo-NormalizedConfig -Config $certConfigA -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $b = @(ConvertTo-NormalizedConfig -Config $certConfigB -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $diff = @(Get-ConfigDiff -Reference $a -Difference $b)
    Assert-Equal 0 $diff.Count "unexpected drift: $(Format-ConfigDiff -Diff $diff)"
}

Invoke-Test -Name 'Certificate anchor line is retained' -Test {
    $vendor = Get-ConfigVendorProfile -Name 'cisco-ios'
    $lines = @(ConvertTo-NormalizedConfig -Config $certConfigA -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    Assert-Equal 1 @($lines | Where-Object { $_ -like 'crypto pki certificate chain*' }).Count
    Assert-Equal 0 @($lines | Where-Object { $_ -like '*30820330*' }).Count
    Assert-Equal 1 @($lines | Where-Object { $_ -eq 'ntp server 10.0.0.1' }).Count
}

Invoke-Test -Name 'Removing the whole certificate chain is still drift' -Test {
    $vendor = Get-ConfigVendorProfile -Name 'cisco-ios'
    $without = "hostname CORE-SW1`nntp server 10.0.0.1"
    $a = @(ConvertTo-NormalizedConfig -Config $certConfigA -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $b = @(ConvertTo-NormalizedConfig -Config $without -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $diff = @(Get-ConfigDiff -Reference $a -Difference $b)
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Removed' -and $_.Text -like 'crypto pki certificate chain*' }).Count
}

Invoke-Test -Name 'Config after a block resumes normally' -Test {
    $vendor = Get-ConfigVendorProfile -Name 'cisco-ios'
    $changed = $certConfigB -replace 'ntp server 10.0.0.1', 'ntp server 10.0.0.9'
    $a = @(ConvertTo-NormalizedConfig -Config $certConfigA -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $b = @(ConvertTo-NormalizedConfig -Config $changed -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $diff = @(Get-ConfigDiff -Reference $a -Difference $b)
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Added' -and $_.Text -eq 'ntp server 10.0.0.9' }).Count
}

Invoke-Test -Name 'Linux PEM blocks are suppressed' -Test {
    $vendor = Get-ConfigVendorProfile -Name 'linux'
    $pemA = "listen 443`n-----BEGIN CERTIFICATE-----`nAAAA`nBBBB`n-----END CERTIFICATE-----`nserver_name x"
    $pemB = "listen 443`n-----BEGIN CERTIFICATE-----`nZZZZ`nYYYY`n-----END CERTIFICATE-----`nserver_name x"
    $a = @(ConvertTo-NormalizedConfig -Config $pemA -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    $b = @(ConvertTo-NormalizedConfig -Config $pemB -IgnorePattern $vendor.IgnorePattern -IgnoreBlock $vendor.IgnoreBlock -CommentPrefix $vendor.CommentPrefix)
    Assert-Equal 0 (@(Get-ConfigDiff -Reference $a -Difference $b)).Count
}

Invoke-Test -Name 'Custom IgnoreBlock is honoured by the audit' -Test {
    $blockStore = Join-Path $testStore 'blocks'
    $v1 = "device A`nbanner motd ^`nrandom 111`n^`nend"
    $v2 = "device A`nbanner motd ^`nrandom 999`n^`nend"
    $block = @(@{ Start = '^banner motd'; End = '^\^$' })
    Invoke-ConfigDriftAudit -Target 'B1' -Config $v1 -StorePath $blockStore -IgnoreBlock $block -UpdateBaseline | Out-Null
    $result = Invoke-ConfigDriftAudit -Target 'B1' -Config $v2 -StorePath $blockStore -IgnoreBlock $block
    Assert-Equal $false $result.DriftDetected
}

Invoke-Test -Name 'IgnorePattern is per-line, not multi-line' -Test {
    $text = "alpha`nbravo`ncharlie"
    $lines = @(ConvertTo-NormalizedConfig -Config $text -IgnorePattern '(?s)alpha.*charlie')
    Assert-Equal 3 $lines.Count 'a regex cannot span lines; use IgnoreBlock instead'
}

Invoke-Test -Name 'IgnoreBlock spans an arbitrary number of lines' -Test {
    $body = 1..200 | ForEach-Object { "  noise$_" }
    $text = @('keep me', 'BLOCKSTART') + $body + @('BLOCKEND', 'keep me too')
    $lines = @(ConvertTo-NormalizedConfig -Config $text -IgnoreBlock @(@{ Start = '^BLOCKSTART$'; End = '^BLOCKEND$' }))
    Assert-Equal 3 $lines.Count
    Assert-Equal 'keep me' $lines[0]
    Assert-Equal 'BLOCKSTART' $lines[1]
    Assert-Equal 'keep me too' $lines[2]
}

Write-Host ''
Write-Host '--- Include (allowlist) mode ---' -ForegroundColor Cyan

$sectionConfig = @'
hostname CORE-SW1
ntp server 10.0.0.1
interface GigabitEthernet0/1
 description UPLINK
 switchport mode trunk
!
interface GigabitEthernet0/2
 description USER
 switchport access vlan 10
!
logging host 10.0.0.5
'@

Invoke-Test -Name 'IncludePattern keeps only matching lines' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config $sectionConfig -IncludePattern '^interface ')
    Assert-Equal 2 $lines.Count
    Assert-Equal 'interface GigabitEthernet0/1' $lines[0]
}

Invoke-Test -Name 'IncludeBlock keeps whole sections' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config $sectionConfig -IncludeBlock @(@{ Start = '^interface '; End = '^!$' }) -CommentPrefix '!')
    Assert-Equal 6 $lines.Count "got: $($lines -join ' | ')"
    Assert-True (@($lines | Where-Object { $_ -eq ' switchport mode trunk' }).Count -eq 1) 'section body should be kept'
    Assert-Equal 0 @($lines | Where-Object { $_ -like 'hostname*' }).Count 'lines outside blocks should be dropped'
    Assert-Equal 0 @($lines | Where-Object { $_ -like 'logging*' }).Count 'trailing lines should be dropped'
}

Invoke-Test -Name 'IncludeBlock and IncludePattern combine' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config $sectionConfig -IncludeBlock @(@{ Start = '^interface '; End = '^!$' }) -IncludePattern '^hostname' -CommentPrefix '!')
    Assert-Equal 1 @($lines | Where-Object { $_ -like 'hostname*' }).Count
    Assert-Equal 2 @($lines | Where-Object { $_ -like 'interface *' }).Count
}

Invoke-Test -Name 'Change outside the included block is not drift' -Test {
    $includeStore = Join-Path $testStore 'include'
    $include = @(@{ Start = '^interface '; End = '^!$' })
    Invoke-ConfigDriftAudit -Target 'I1' -Config $sectionConfig -StorePath $includeStore -Profile 'cisco-ios' -IncludeBlock $include -UpdateBaseline | Out-Null
    $changed = $sectionConfig -replace 'logging host 10.0.0.5', 'logging host 10.0.0.77'
    $result = Invoke-ConfigDriftAudit -Target 'I1' -Config $changed -StorePath $includeStore -Profile 'cisco-ios' -IncludeBlock $include
    Assert-Equal $false $result.DriftDetected
}

Invoke-Test -Name 'Change inside the included block is drift' -Test {
    $includeStore = Join-Path $testStore 'include2'
    $include = @(@{ Start = '^interface '; End = '^!$' })
    Invoke-ConfigDriftAudit -Target 'I2' -Config $sectionConfig -StorePath $includeStore -Profile 'cisco-ios' -IncludeBlock $include -UpdateBaseline | Out-Null
    $changed = $sectionConfig -replace ' switchport access vlan 10', ' switchport access vlan 999'
    $result = Invoke-ConfigDriftAudit -Target 'I2' -Config $changed -StorePath $includeStore -Profile 'cisco-ios' -IncludeBlock $include
    Assert-Equal $true $result.DriftDetected
    Assert-Equal 1 @($result.Diff | Where-Object { $_.Text -like '*vlan 999*' }).Count
}

Invoke-Test -Name 'Include runs before ignore filters' -Test {
    $text = "interface Gi0/1`n description KEEP`n secret token 111`n!`nhostname X"
    $lines = @(ConvertTo-NormalizedConfig -Config $text -IncludeBlock @(@{ Start = '^interface '; End = '^!$' }) -IgnorePattern '^\s*secret token' -CommentPrefix '!')
    Assert-Equal 2 $lines.Count
    Assert-Equal 0 @($lines | Where-Object { $_ -like '*secret token*' }).Count
}

Write-Host ''
Write-Host '--- Section filters (wildcards) ---' -ForegroundColor Cyan

Invoke-Test -Name 'Sections are detected by indentation' -Test {
    $sections = @(Get-ConfigSection -Config $sectionConfig -CommentPrefix '!')
    Assert-Equal 5 $sections.Count "got: $(($sections | ForEach-Object { $_.Header }) -join ' | ')"
    $gi1 = $sections | Where-Object { $_.Header -eq 'interface GigabitEthernet0/1' }
    Assert-Equal 3 $gi1.Lines.Count
}

Invoke-Test -Name 'IncludeSection works without regex' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config $sectionConfig -IncludeSection 'interface *' -CommentPrefix '!')
    Assert-Equal 6 $lines.Count
    Assert-Equal 0 @($lines | Where-Object { $_ -like 'hostname*' }).Count
}

Invoke-Test -Name 'IncludeSection matches single-line globals' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config $sectionConfig -IncludeSection 'hostname *', 'ntp server *' -CommentPrefix '!')
    Assert-Equal 2 $lines.Count
}

Invoke-Test -Name 'IgnoreSection keeps header and drops body' -Test {
    $lines = @(ConvertTo-NormalizedConfig -Config $sectionConfig -IgnoreSection 'interface GigabitEthernet0/2' -CommentPrefix '!')
    Assert-Equal 1 @($lines | Where-Object { $_ -eq 'interface GigabitEthernet0/2' }).Count
    Assert-Equal 0 @($lines | Where-Object { $_ -like '*vlan 10*' }).Count
    Assert-Equal 1 @($lines | Where-Object { $_ -eq ' switchport mode trunk' }).Count
}

Invoke-Test -Name 'IncludeSection drift is scoped correctly' -Test {
    $sectionStore = Join-Path $testStore 'sections'
    Invoke-ConfigDriftAudit -Target 'S1' -Config $sectionConfig -StorePath $sectionStore -Profile 'cisco-ios' -IncludeSection 'interface *' -UpdateBaseline | Out-Null
    $outside = $sectionConfig -replace 'logging host 10.0.0.5', 'logging host 10.0.0.88'
    Assert-Equal $false (Invoke-ConfigDriftAudit -Target 'S1' -Config $outside -StorePath $sectionStore -Profile 'cisco-ios' -IncludeSection 'interface *').DriftDetected
    $inside = $sectionConfig -replace ' description USER', ' description PRINTER'
    Assert-Equal $true (Invoke-ConfigDriftAudit -Target 'S1' -Config $inside -StorePath $sectionStore -Profile 'cisco-ios' -IncludeSection 'interface *').DriftDetected
}

Write-Host ''
Write-Host '--- Policy packs ---' -ForegroundColor Cyan

Invoke-Test -Name 'Packs return usable rules' -Test {
    foreach ($packName in @('cisco-hardening', 'cisco-snmp', 'linux-ssh')) {
        $pack = @(Get-ConfigPolicyPack -Name $packName)
        Assert-True ($pack.Count -gt 0) "pack $packName is empty"
        foreach ($rule in $pack) {
            Assert-True ($rule.ContainsKey('Id')) "rule missing Id in $packName"
            Assert-True ($rule.ContainsKey('MustMatch') -or $rule.ContainsKey('MustNotMatch')) "rule $($rule.Id) has no matcher"
        }
    }
}

Invoke-Test -Name 'Hardening pack flags a weak config' -Test {
    $weak = @('hostname R1', 'enable password cisco123', 'line vty 0 4', ' transport input telnet')
    $checks = @(Test-ConfigPolicy -Config $weak -Target 'R1' -Rule (Get-ConfigPolicyPack cisco-hardening))
    Assert-Equal 'Fail' ($checks | Where-Object { $_.Check -eq 'Telnet disabled' }).Status
    Assert-Equal 'Fail' ($checks | Where-Object { $_.Check -eq 'No cleartext enable password' }).Status
    Assert-Equal 'Fail' ($checks | Where-Object { $_.Check -eq 'AAA enabled' }).Status
}

Invoke-Test -Name 'Hardening pack passes a good config' -Test {
    $good = @('hostname R1', 'aaa new-model', 'no ip http server', 'service password-encryption', 'ip ssh version 2', 'logging host 10.0.0.5', 'line vty 0 4', ' exec-timeout 5 0', ' transport input ssh')
    $checks = @(Test-ConfigPolicy -Config $good -Target 'R1' -Rule (Get-ConfigPolicyPack cisco-hardening))
    Assert-Equal 0 @($checks | Where-Object { $_.Status -ne 'Pass' }).Count "unexpected: $(($checks | Where-Object { $_.Status -ne 'Pass' } | ForEach-Object { $_.Check }) -join ', ')"
}

Invoke-Test -Name 'SNMP pack catches read-write community' -Test {
    $checks = @(Test-ConfigPolicy -Config @('snmp-server community Secr3t RW') -Target 'R1' -Rule (Get-ConfigPolicyPack cisco-snmp))
    Assert-Equal 'Fail' ($checks | Where-Object { $_.Check -eq 'No read-write SNMP' }).Status
}

Write-Host ''
Write-Host '--- Revision comparison ---' -ForegroundColor Cyan

Invoke-Test -Name 'Compare golden against latest' -Test {
    $revStore = Join-Path $testStore 'revisions'
    Save-ConfigBaseline -StorePath $revStore -DeviceKey 'R1' -Config @('hostname R1', 'ntp server 10.0.0.1') -Approve | Out-Null
    Save-ConfigBaseline -StorePath $revStore -DeviceKey 'R1' -Config @('hostname R1', 'ntp server 10.0.0.2') | Out-Null
    Save-ConfigBaseline -StorePath $revStore -DeviceKey 'R1' -Config @('hostname R1', 'ntp server 10.0.0.3') | Out-Null
    $result = Compare-ConfigRevision -StorePath $revStore -DeviceKey 'R1' -From golden -To latest
    Assert-Equal 1 $result.AddedLines
    Assert-Equal 1 $result.RemovedLines
    Assert-Equal 1 @($result.Diff | Where-Object { $_.Text -eq 'ntp server 10.0.0.3' }).Count
}

Invoke-Test -Name 'Compare by revision number and offset' -Test {
    $revStore = Join-Path $testStore 'revisions'
    $byNumber = Compare-ConfigRevision -StorePath $revStore -DeviceKey 'R1' -From 1 -To 2
    Assert-Equal 1 @($byNumber.Diff | Where-Object { $_.Text -eq 'ntp server 10.0.0.2' }).Count
    $byOffset = Compare-ConfigRevision -StorePath $revStore -DeviceKey 'R1' -From -1 -To latest
    Assert-Equal 1 @($byOffset.Diff | Where-Object { $_.Text -eq 'ntp server 10.0.0.3' }).Count
}

Invoke-Test -Name 'Invalid revision selector fails clearly' -Test {
    $revStore = Join-Path $testStore 'revisions'
    $threw = $false
    try { Compare-ConfigRevision -StorePath $revStore -DeviceKey 'R1' -From 99 -To latest | Out-Null }
    catch { $threw = $true }
    Assert-True $threw 'expected an out-of-range error'
}

Write-Host ''
Write-Host '--- Profiles and collection options ---' -ForegroundColor Cyan

Invoke-Test -Name 'Profiles expose command arrays' -Test {
    foreach ($name in @('cisco-ios', 'cisco-nxos', 'cisco-asa', 'linux', 'generic')) {
        $vendor = Get-ConfigVendorProfile -Name $name
        Assert-True ($vendor.Command -is [array]) "$name Command should be an array"
        Assert-True ($vendor.SetupCommand -is [array]) "$name SetupCommand should be an array"
        Assert-True ([bool]$vendor.PromptPattern) "$name should define a prompt pattern"
    }
}

Invoke-Test -Name 'Pager suppression moved to SetupCommand' -Test {
    $ios = Get-ConfigVendorProfile -Name 'cisco-ios'
    Assert-Equal 'show running-config' $ios.Command[0]
    Assert-Equal 'terminal length 0' $ios.SetupCommand[0]
    $asa = Get-ConfigVendorProfile -Name 'cisco-asa'
    Assert-Equal 'terminal pager 0' $asa.SetupCommand[0]
}

Invoke-Test -Name 'Prompt pattern matches a device prompt' -Test {
    $pattern = (Get-ConfigVendorProfile -Name 'cisco-ios').PromptPattern
    Assert-True ([regex]::IsMatch("show run`r`nCORE-SW1#", $pattern)) 'enable prompt should match'
    Assert-True ([regex]::IsMatch("text`r`nCORE-SW1>", $pattern)) 'user prompt should match'
    Assert-True (-not [regex]::IsMatch("hostname CORE-SW1", $pattern)) 'config line should not match'
}

Invoke-Test -Name 'Multi-command output is audited as one config' -Test {
    $multiStore = Join-Path $testStore 'multi'
    $combined = "hostname SW1`ninterface Gi0/1`n switchport mode trunk`nvlan 10`n name USERS"
    Invoke-ConfigDriftAudit -Target 'M1' -Config $combined -StorePath $multiStore -Profile 'cisco-ios' -UpdateBaseline | Out-Null
    $changed = $combined -replace ' name USERS', ' name GUESTS'
    $result = Invoke-ConfigDriftAudit -Target 'M1' -Config $changed -StorePath $multiStore -Profile 'cisco-ios'
    Assert-Equal $true $result.DriftDetected
    Assert-Equal 1 $result.AddedLines
}

Invoke-Test -Name 'SSH shell function is exported' -Test {
    $sshModule = Join-Path $repoRoot 'helpers\ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psm1'
    Assert-True (Test-Path -LiteralPath $sshModule) 'SSH module missing'
    $content = Get-Content -LiteralPath $sshModule -Raw
    Assert-True ($content -match 'function Invoke-SshShellCommand') 'shell function not defined'
    Assert-True ($content -match "'Invoke-SshShellCommand'") 'shell function not exported'
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'helpers\ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psd1') -Raw
    Assert-True ($manifest -match "'Invoke-SshShellCommand'") 'shell function missing from manifest'
}

Write-Host ''
Write-Host '--- WUG integration guards ---' -ForegroundColor Cyan

Invoke-Test -Name 'WUG functions exist' -Test {
    foreach ($name in @('Get-ConfigDriftTarget', 'Publish-ConfigDriftToWUG', 'Get-ConfigDriftVaultCredential')) {
        Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "missing function: $name"
    }
}

Invoke-Test -Name 'Publish supports WhatIf' -Test {
    $command = Get-Command Publish-ConfigDriftToWUG
    Assert-True ($command.Parameters.ContainsKey('WhatIf')) 'Publish-ConfigDriftToWUG should support -WhatIf'
}

Invoke-Test -Name 'WUG helpers fail clearly without a session' -Test {
    # Skip when the module is loaded; the guard only fires without it.
    if (Get-Command Get-WUGDevice -ErrorAction SilentlyContinue) { return }
    $threw = $false
    try { Get-ConfigDriftTarget -GroupName 'Routers' | Out-Null }
    catch { $threw = ($_.Exception.Message -like '*WhatsUpGoldPS module is not loaded*') }
    Assert-True $threw 'expected a clear module-not-loaded error'
}

Invoke-Test -Name 'Scheduled task script requires a vault credential' -Test {
    $taskScript = Join-Path $repoRoot 'helpers\config-drift\Register-ConfigDriftScheduledTask.ps1'
    Assert-True (Test-Path -LiteralPath $taskScript) 'task script missing'
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($taskScript, [ref]$null, [ref]$errors) | Out-Null
    Assert-Equal 0 $errors.Count 'task script should parse cleanly'
    $content = Get-Content -LiteralPath $taskScript -Raw
    Assert-True ($content -match 'Specify -VaultCredential') 'should require a vault credential'
}

Write-Host ''
Write-Host '--- Diff engine ---' -ForegroundColor Cyan

Invoke-Test -Name 'Identical configs produce no diff' -Test {
    $lines = @('a', 'b', 'c')
    $diff = @(Get-ConfigDiff -Reference $lines -Difference $lines)
    Assert-Equal 0 $diff.Count
}

Invoke-Test -Name 'Added line detected with line number' -Test {
    $diff = @(Get-ConfigDiff -Reference @('a', 'b', 'c') -Difference @('a', 'b', 'x', 'c'))
    Assert-Equal 1 $diff.Count
    Assert-Equal 'Added' $diff[0].Operation
    Assert-Equal 'x' $diff[0].Text
    Assert-Equal 3 $diff[0].DifferenceLine
}

Invoke-Test -Name 'Removed line detected with line number' -Test {
    $diff = @(Get-ConfigDiff -Reference @('a', 'b', 'c') -Difference @('a', 'c'))
    Assert-Equal 1 $diff.Count
    Assert-Equal 'Removed' $diff[0].Operation
    Assert-Equal 'b' $diff[0].Text
    Assert-Equal 2 $diff[0].ReferenceLine
}

Invoke-Test -Name 'Changed line reports add and remove' -Test {
    $diff = @(Get-ConfigDiff -Reference @('a', 'old', 'c') -Difference @('a', 'new', 'c'))
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Added' -and $_.Text -eq 'new' }).Count
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Removed' -and $_.Text -eq 'old' }).Count
}

Invoke-Test -Name 'Diff is case sensitive' -Test {
    $diff = @(Get-ConfigDiff -Reference @('Hostname R1') -Difference @('hostname R1'))
    Assert-Equal 2 $diff.Count
}

Invoke-Test -Name 'Empty baseline reports all lines added' -Test {
    $diff = @(Get-ConfigDiff -Reference @() -Difference @('a', 'b'))
    Assert-Equal 2 $diff.Count
    Assert-Equal 2 @($diff | Where-Object { $_.Operation -eq 'Added' }).Count
}

Invoke-Test -Name 'Empty current reports all lines removed' -Test {
    $diff = @(Get-ConfigDiff -Reference @('a', 'b') -Difference @())
    Assert-Equal 2 @($diff | Where-Object { $_.Operation -eq 'Removed' }).Count
}

Invoke-Test -Name 'IncludeUnchanged returns context lines' -Test {
    $diff = @(Get-ConfigDiff -Reference @('a', 'b') -Difference @('a', 'c') -IncludeUnchanged)
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Unchanged' -and $_.Text -eq 'a' }).Count
}

Invoke-Test -Name 'Fallback path handles oversized diff' -Test {
    $ref = 1..60 | ForEach-Object { "line$_" }
    $dif = 1..60 | ForEach-Object { "line$_" }
    $dif[30] = 'changed'
    $diff = @(Get-ConfigDiff -Reference $ref -Difference $dif -MaxMatrixCells 10)
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Added' -and $_.Text -eq 'changed' }).Count
    Assert-Equal 1 @($diff | Where-Object { $_.Operation -eq 'Removed' -and $_.Text -eq 'line31' }).Count
}

Invoke-Test -Name 'Format-ConfigDiff renders unified markers' -Test {
    $diff = @(Get-ConfigDiff -Reference @('a', 'old') -Difference @('a', 'new'))
    $text = Format-ConfigDiff -Diff $diff
    Assert-True ($text -like '*- old*') 'removed marker missing'
    Assert-True ($text -like '*+ new*') 'added marker missing'
}

Write-Host ''
Write-Host '--- Baseline store ---' -ForegroundColor Cyan

Invoke-Test -Name 'Store initializes with index' -Test {
    Initialize-ConfigBaselineStore -StorePath $testStore | Out-Null
    Assert-True (Test-Path (Join-Path $testStore 'index.json')) 'index.json missing'
    Assert-True (Test-Path (Join-Path $testStore 'configs')) 'configs folder missing'
}

Invoke-Test -Name 'First baseline is created' -Test {
    $rev = Save-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1' -Config @('hostname CORE-SW1', 'ntp server 10.0.0.1')
    Assert-True $rev.Created 'revision should be created'
    Assert-True (Test-Path $rev.Path) 'revision file missing'
}

Invoke-Test -Name 'Unchanged config does not create a revision' -Test {
    $rev = Save-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1' -Config @('hostname CORE-SW1', 'ntp server 10.0.0.1')
    Assert-Equal $false $rev.Created
    Assert-Equal 1 (@(Get-ConfigBaselineHistory -StorePath $testStore -DeviceKey 'CORE-SW1')).Count
}

Invoke-Test -Name 'Changed config creates a new revision' -Test {
    $rev = Save-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1' -Config @('hostname CORE-SW1', 'ntp server 10.0.0.2')
    Assert-True $rev.Created 'expected a new revision'
    Assert-Equal 2 (@(Get-ConfigBaselineHistory -StorePath $testStore -DeviceKey 'CORE-SW1')).Count
}

Invoke-Test -Name 'Baseline round-trips exactly' -Test {
    $baseline = Get-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1'
    Assert-Equal 2 $baseline.Lines.Count
    Assert-Equal 'ntp server 10.0.0.2' $baseline.Lines[1]
}

Invoke-Test -Name 'Golden revision is tracked separately' -Test {
    Save-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1' -Config @('hostname CORE-SW1', 'golden line') -Approve | Out-Null
    Save-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1' -Config @('hostname CORE-SW1', 'drifted line') | Out-Null
    $latest = Get-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1'
    $golden = Get-ConfigBaseline -StorePath $testStore -DeviceKey 'CORE-SW1' -Golden
    Assert-Equal 'drifted line' $latest.Lines[1]
    Assert-Equal 'golden line' $golden.Lines[1]
}

Invoke-Test -Name 'Unknown device returns null baseline' -Test {
    Assert-True ($null -eq (Get-ConfigBaseline -StorePath $testStore -DeviceKey 'DOES-NOT-EXIST')) 'expected null'
}

Invoke-Test -Name 'Device keys cannot escape the store path' -Test {
    $safe = ConvertTo-SafeDeviceKey -DeviceKey '../../etc/passwd'
    Assert-True ($safe -notmatch '[\\/]') "path separators survived: $safe"
    Assert-True ($safe -notlike '*..*') "traversal survived: $safe"
}

Write-Host ''
Write-Host '--- Policy rules ---' -ForegroundColor Cyan

$policyLines = @('hostname R1', 'no ip http server', 'line vty 0 4', ' transport input ssh', 'snmp-server community public RO')

Invoke-Test -Name 'MustNotMatch passes when absent' -Test {
    $checks = @(Test-ConfigPolicy -Config $policyLines -Target 'R1' -Rule @{ Id = 'NO-TELNET'; MustNotMatch = 'transport input .*telnet' })
    Assert-Equal 'Pass' $checks[0].Status
}

Invoke-Test -Name 'MustNotMatch fails when present' -Test {
    $checks = @(Test-ConfigPolicy -Config $policyLines -Target 'R1' -Rule @{ Id = 'NO-PUBLIC-SNMP'; MustNotMatch = 'snmp-server community (public|private)' })
    Assert-Equal 'Fail' $checks[0].Status
    Assert-True ($checks[0].Detail -like '*public*') 'offending line should be reported'
}

Invoke-Test -Name 'MustMatch passes when present' -Test {
    $checks = @(Test-ConfigPolicy -Config $policyLines -Target 'R1' -Rule @{ Id = 'HTTP-OFF'; MustMatch = '^no ip http server' })
    Assert-Equal 'Pass' $checks[0].Status
}

Invoke-Test -Name 'MustMatch fails when missing' -Test {
    $checks = @(Test-ConfigPolicy -Config $policyLines -Target 'R1' -Rule @{ Id = 'AAA'; MustMatch = '^aaa new-model' })
    Assert-Equal 'Fail' $checks[0].Status
}

Invoke-Test -Name 'Severity Warn is honoured' -Test {
    $checks = @(Test-ConfigPolicy -Config $policyLines -Target 'R1' -Rule @{ Id = 'BANNER'; MustMatch = '^banner login'; Severity = 'Warn' })
    Assert-Equal 'Warn' $checks[0].Status
}

Invoke-Test -Name 'Multiple rules evaluated in order' -Test {
    $checks = @(Test-ConfigPolicy -Config $policyLines -Target 'R1' -Rule @(
        @{ Id = 'R1'; MustMatch = '^hostname' },
        @{ Id = 'R2'; MustNotMatch = '^snmp-server community public' }
    ))
    Assert-Equal 2 $checks.Count
    Assert-Equal 'Pass' $checks[0].Status
    Assert-Equal 'Fail' $checks[1].Status
}

Write-Host ''
Write-Host '--- Peer group comparison ---' -ForegroundColor Cyan

Invoke-Test -Name 'Outlier missing a consensus line is flagged' -Test {
    $map = @{
        'SW1' = @('aaa new-model', 'logging host 10.0.0.5', 'ntp server 10.0.0.1')
        'SW2' = @('aaa new-model', 'logging host 10.0.0.5', 'ntp server 10.0.0.1')
        'SW3' = @('aaa new-model', 'logging host 10.0.0.5', 'ntp server 10.0.0.1')
        'SW4' = @('aaa new-model', 'ntp server 10.0.0.1')
    }
    $checks = @(Compare-ConfigPeerGroup -ConfigMap $map -ConsensusPercent 70)
    $outlier = $checks | Where-Object { $_.Target -eq 'SW4' }
    Assert-Equal 'Warn' $outlier.Status
    Assert-True ($outlier.Detail -like '*logging host*') 'missing line should be named'
    Assert-Equal 'Pass' ($checks | Where-Object { $_.Target -eq 'SW1' }).Status
}

Invoke-Test -Name 'Single device yields no peer findings' -Test {
    $checks = @(Compare-ConfigPeerGroup -ConfigMap @{ 'SW1' = @('a') })
    Assert-Equal 0 $checks.Count
}

Write-Host ''
Write-Host '--- End-to-end audit ---' -ForegroundColor Cyan

$auditStore = Join-Path $testStore 'audit'
$rules = @(
    @{ Id = 'No telnet'; MustNotMatch = 'transport input .*telnet' },
    @{ Id = 'NTP configured'; MustMatch = '^ntp server' }
)

Invoke-Test -Name 'First audit establishes a baseline' -Test {
    $result = Invoke-ConfigDriftAudit -Target 'CORE-SW1' -Config $iosConfig -StorePath $auditStore -Profile 'cisco-ios' -Rule $rules -UpdateBaseline
    Assert-Equal $false $result.DriftDetected
    $driftCheck = $result.Checks | Where-Object { $_.Category -eq 'Drift' }
    Assert-Equal 'Unknown' $driftCheck.Status
    Assert-True ($null -ne $result.Revision) 'baseline should be stored'
}

Invoke-Test -Name 'Unchanged rerun reports no drift' -Test {
    $result = Invoke-ConfigDriftAudit -Target 'CORE-SW1' -Config $iosConfig -StorePath $auditStore -Profile 'cisco-ios'
    Assert-Equal $false $result.DriftDetected
    Assert-Equal 'Pass' ($result.Checks | Where-Object { $_.Category -eq 'Drift' }).Status
}

Invoke-Test -Name 'Volatile change alone is not drift' -Test {
    $noisy = $iosConfig -replace 'Last configuration change at 10:32:11', 'Last configuration change at 22:15:44'
    $noisy = $noisy -replace 'ntp clock-period 17179860', 'ntp clock-period 17179999'
    $result = Invoke-ConfigDriftAudit -Target 'CORE-SW1' -Config $noisy -StorePath $auditStore -Profile 'cisco-ios'
    Assert-Equal $false $result.DriftDetected
}

Invoke-Test -Name 'Real change is detected as drift' -Test {
    $changed = $iosConfig -replace ' transport input ssh', ' transport input telnet'
    $result = Invoke-ConfigDriftAudit -Target 'CORE-SW1' -Config $changed -StorePath $auditStore -Profile 'cisco-ios' -Rule $rules
    Assert-Equal $true $result.DriftDetected
    Assert-Equal 'Fail' ($result.Checks | Where-Object { $_.Category -eq 'Drift' }).Status
    Assert-Equal 1 $result.AddedLines
    Assert-Equal 1 $result.RemovedLines
    Assert-Equal 'Fail' ($result.Checks | Where-Object { $_.Check -eq 'No telnet' }).Status
    Assert-Equal 'Pass' ($result.Checks | Where-Object { $_.Check -eq 'NTP configured' }).Status
}

Invoke-Test -Name 'Diff names the changed lines' -Test {
    $changed = $iosConfig -replace 'hostname CORE-SW1', 'hostname CORE-SW1-RENAMED'
    $result = Invoke-ConfigDriftAudit -Target 'CORE-SW1' -Config $changed -StorePath $auditStore -Profile 'cisco-ios'
    $text = Format-ConfigDiff -Diff $result.Diff
    Assert-True ($text -like '*+ hostname CORE-SW1-RENAMED*') 'new hostname missing from diff'
    Assert-True ($text -like '*- hostname CORE-SW1*') 'old hostname missing from diff'
}

Invoke-Test -Name 'Golden comparison ignores later revisions' -Test {
    $goldenStore = Join-Path $testStore 'golden'
    Invoke-ConfigDriftAudit -Target 'R9' -Config "hostname R9`nfeature good" -StorePath $goldenStore -ApproveBaseline | Out-Null
    Invoke-ConfigDriftAudit -Target 'R9' -Config "hostname R9`nfeature bad" -StorePath $goldenStore -UpdateBaseline | Out-Null
    $result = Invoke-ConfigDriftAudit -Target 'R9' -Config "hostname R9`nfeature bad" -StorePath $goldenStore -UseGolden
    Assert-Equal $true $result.DriftDetected
}

Write-Host ''
if (Test-Path -LiteralPath $testStore) {
    Remove-Item -LiteralPath $testStore -Recurse -Force -ErrorAction SilentlyContinue
    Record-Test -Name 'Temporary store cleaned up' -Status 'Pass'
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed   Failed: $script:Failed" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host '============================================================' -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBKSwZ8cy1JYl+R
# 31pIaQ6pKB1HxLY+/iWRIn+eGH6iZ6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCMdRMSEmaBTuat9bP8x/wQadwbTqXw+ni2GgF9mliJNTANBgkqhkiG9w0BAQEF
# AASCAgCI/qzq0bIrhchvmqa45/pzGDxy8eHbPN6IgJLS3D5NguIiFat1W8ReaJld
# uKbcu1IJ3QlnqA+Vq3uiQgLjm7lqzVzTh7E18YrzDrgd4dsQFuTCpXrbSJJyQEla
# uSJaa23qYmIHIH9EPRFZeaM35k8lnpwXoBPt1C8VZYk6jd8zCOYSurp6rSe+0qEI
# q+7v7BQwcG+M9lBWM+99sHi81aB4cBFQPXWT/c3XjBIj1MQKZU1HNtUa2C/HXi+K
# jWwVAQEbzWCZm4oqtcO3V6amf522eV38PlYR7XLAK9NVPFFfMqGuPeWbu8N1+woQ
# eAoHEm0efebZzjOLxPqxoQYdxwWaOy0ump8oW7JX338Di0GrMjTGGEPuC4whsfM0
# CnNa6YiuB/nZX786qgw8OIKR+F+noXuS4yNVstTrcrErE9k4r88EznH1h0lEo9Hk
# UgMBCcuxu5UB/UQiyWHV6x+Y9af8zJnbTlpbqlcV8dWdOzRcR5EhKQlq/AITkeiX
# HCWHhF2G8XCwIGY9T0te37X/m2fimT8GkqcGgN6WCWZQyKXOxnIl8dKsV8Au+KCw
# eEGwSQXhZTS6Gz2z4vlDHBH6+utzJpf4gY/feuLtyEWu5G36wvLAGIhQlrdR9kfs
# /8nfN5jkAssdOjyBW1LYJrNos3x/oyISLsSpjpuKizF51mEXwaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkxOTM3NDNaMC8GCSqGSIb3DQEJBDEiBCASun9V
# yKfWrmAZ1voEvHJSA7CFaoEE4fVHGC1MQQA/0jANBgkqhkiG9w0BAQEFAASCAgA3
# XW2nH+CpGZHme/ZA7hBDml0HmJt/Bit0OBmWhMcLAA/vT0Y39Yz5MS3s067FQNxz
# 8ghIDwW57+2Q7uAwdjkExsWQdMkycLY510FjGzhYeQVZf/iwzNkqIZNZbAzufwMz
# Vdiqdj4v4tD0Uq6qwCSFd0ak4o2YdWI9s5ifDiMsyggEb/CTPXkF8EKKX7xGSBVa
# +RRs1PifhMJXx3qOADT9KjqaeCk37xOyQ11JNVcWYZgobknPr0ojrkqBP5x4FPjH
# hKD94gYdgyOmDrzwAu3w6mBelAUa6QSQuzkylVhWMbOKeHbW/DvKRchE/xzF4ncR
# 3c0EOcspJn6IgTjb0YKIq1oqB8Xk5JbePrlXvapSVjM+wRacgY8e7GXvJ6l23sXk
# QZsY/+qxBnxjU8zzpHprG716js3ALWKXu3p3/vTbD7ARZ0ADuBINNw3LNmLo2F9q
# 8JpJG0VxSfLPKJbW6cfRh6Bcw6HKFkJ7f01q+E4rre/uVhpfFipnJq0KRztQ5epl
# Wz9Z3a+0xrkYWhiRq6+LdFdLSNQCZG6xrrexEZF96Rl95MRrRoD+kVZljB2Cakun
# 4EaVtNlD3IU+3RYmdHCrDVbkxiZ98wvZ2IZNXsDF8x2jNtKA9cYik9lLQmrYti+/
# NB2uI1kpmAMDuzXGEQ0nMZtlcn60seuBupzYBvds7Q==
# SIG # End signature block
