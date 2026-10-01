<#
.SYNOPSIS
    Config Drift Discovery - Baseline, diff, and policy-check device configurations; publish ConfigDrift.* attributes to WUG.

.DESCRIPTION
    Pulls each device's configuration over SSH, compares it with the local baseline
    store, evaluates policy packs, and lets you choose what to do with the results:

      [1] Push to WhatsUp Gold (ConfigDrift.* device attributes)
      [2] Export audit results to JSON (includes line-level diffs)
      [3] Export checks to CSV
      [4] Show drift summary and diffs
      [5] Generate configuration drift dashboard
      [6] Exit
      [7] Dashboard + Push to WUG

    The first run for a device stores its baseline (ConfigDrift.Status = Baselined).
    Later runs report Clean or Drift. Create a WUG dynamic group on
    ConfigDrift.Status = Drift to alert on configuration changes.

.PARAMETER Target
    Device host names or IPv4 addresses. Prompts when omitted in interactive mode.

.PARAMETER FromWUGGroup
    Audit every device in this WhatsUp Gold device group instead of -Target.

.PARAMETER Profile
    Vendor profile: cisco-ios, cisco-nxos, cisco-asa, linux, generic. Default: cisco-ios.

.PARAMETER Command
    Collection command(s). Required for linux and generic profiles.

.PARAMETER PolicyPack
    Policy packs to evaluate: cisco-hardening, cisco-snmp, linux-ssh.

.PARAMETER SshCredentialName
    Vault entry holding the SSH PSCredential. Default: ConfigDrift.Ssh.

.PARAMETER StorePath
    Baseline store directory. Default: helpers\config-drift\config-baselines (shared with Get-ConfigDriftDashboard.ps1).

.PARAMETER UseGolden
    Compare against the approved (golden) baseline instead of the latest revision.

.PARAMETER UpdateBaseline
    Store the current configuration as a new revision after auditing.

.PARAMETER ApproveBaseline
    Store and approve the current configuration as the golden revision.

.PARAMETER Action
    PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, or None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Omit to reuse the current session or the vault.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login.

.PARAMETER OutputPath
    Directory for dashboards and exports.

.PARAMETER NonInteractive
    Suppress prompts; targets and the vault credential must already exist.

.EXAMPLE
    .\Setup-ConfigDrift-Discovery.ps1 -Target 10.0.0.1,10.0.0.2 -Profile cisco-ios -PolicyPack cisco-hardening -Action Dashboard

.EXAMPLE
    .\Setup-ConfigDrift-Discovery.ps1 -FromWUGGroup 'Core Routers' -Action DashboardAndPush -NonInteractive
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [string]$FromWUGGroup,

    [ValidateSet('cisco-ios', 'cisco-nxos', 'cisco-asa', 'linux', 'generic')]
    [string]$Profile = 'cisco-ios',

    [string[]]$Command,

    [ValidateSet('cisco-hardening', 'cisco-snmp', 'linux-ssh')]
    [string[]]$PolicyPack,

    [string]$SshCredentialName = 'ConfigDrift.Ssh',

    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,

    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 60,

    [string[]]$IgnorePattern = @(),

    [string]$StorePath,

    [switch]$UseGolden,

    [switch]$UpdateBaseline,

    [switch]$ApproveBaseline,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer,

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

if (-not $OutputPath) {
    if ($NonInteractive) { $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output' }
    else { $OutputPath = $env:TEMP }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
if (-not $StorePath) { $StorePath = Join-Path (Split-Path $scriptDir -Parent) 'config-drift\config-baselines' }
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-ConfigDrift.ps1')
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

Write-Host '=== Configuration Drift Discovery ===' -ForegroundColor Cyan
if ($Profile -in @('linux', 'generic') -and -not $Command) { throw "Profile '$Profile' has no default command; pass -Command." }

$wugConnected = $false
if ($FromWUGGroup) {
    Import-Module (Join-Path $repoRoot 'WhatsUpGoldPS.psd1') -Force -ErrorAction Stop
    if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) { throw 'Could not connect to WhatsUp Gold.' }
    $wugConnected = $true
    $targets = @(Get-ConfigDriftTarget -GroupName $FromWUGGroup | ForEach-Object { $_.Target })
    Write-Host "  Resolved $($targets.Count) device(s) from WUG group '$FromWUGGroup'."
}
elseif ($Target) {
    $targets = @($Target | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })
}
elseif ($NonInteractive) {
    throw 'Target or -FromWUGGroup is required in non-interactive mode.'
}
else {
    $targetInput = Read-Host -Prompt 'Device host name(s) or IP address(es), comma-separated'
    $targets = @($targetInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($targets.Count -eq 0) { throw 'At least one target is required.' }
Write-Host "  Targets: $($targets.Count)  Profile: $Profile  Policy: $(if ($PolicyPack) { $PolicyPack -join ', ' } else { 'none' })"
Write-Host "  Baselines: $StorePath"

$credSplat = @{ Name = $SshCredentialName; CredType = 'PSCredential'; ProviderLabel = 'Config Drift SSH' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
Write-Host "Authentication: resolving SSH credential from vault entry '$SshCredentialName' ..." -ForegroundColor Cyan
$sshCredential = Resolve-DiscoveryCredential @credSplat
if (-not $sshCredential) { throw "No SSH credential available in '$SshCredentialName'." }
Write-Host "Authentication: using SSH account '$($sshCredential.UserName)'." -ForegroundColor Green

$options = @{
    Credential      = $sshCredential
    SshPort         = $SshPort
    TimeoutSeconds  = $TimeoutSeconds
    Profile         = $Profile
    StorePath       = $StorePath
    IgnorePattern   = $IgnorePattern
    UseGolden       = [bool]$UseGolden
    UpdateBaseline  = [bool]$UpdateBaseline
    ApproveBaseline = [bool]$ApproveBaseline
}
if ($Command) { $options['Command'] = $Command }
if ($PolicyPack) { $options['PolicyPack'] = $PolicyPack }

$plan = @(Invoke-Discovery -ProviderName 'ConfigDrift' -Target $targets -ApiPort $SshPort -Options $options)
$audits = @($plan | Where-Object { $_.PSObject.Properties['ConfigDriftAudit'] })
$checks = @($audits | ForEach-Object { @($_.ConfigDriftChecks) })
$audited = @($audits | ForEach-Object { $_.DeviceIP })
foreach ($missing in @($targets | Where-Object { $audited -notcontains $_ })) {
    $checks += [pscustomobject]@{ Target = $missing; Category = 'Collection'; Check = 'Configuration retrieval'; Status = 'Fail'; Value = 'error'; Detail = 'SSH collection failed; see warnings above.' }
}

Write-Host ''
Write-Host "Audit complete: $($audits.Count) of $($targets.Count) device(s) collected." -ForegroundColor Green
foreach ($group in @($audits | Group-Object { $_.Attributes['ConfigDrift.Status'] } | Sort-Object Name)) {
    Write-Host ('  {0,-10} {1,5}' -f $group.Name, $group.Count) -ForegroundColor $(if ($group.Name -eq 'Drift') { 'Yellow' } else { 'Gray' })
}

$choice = $null
if ($Action) {
    $choice = switch ($Action) {
        'PushToWUG' { '1' } 'ExportJSON' { '2' } 'ExportCSV' { '3' } 'ShowTable' { '4' }
        'Dashboard' { '5' } 'None' { '6' } 'DashboardAndPush' { '7' }
    }
}
if (-not $choice -and $NonInteractive) { $choice = '5' }
if (-not $choice) {
    Write-Host ''
    Write-Host 'What would you like to do?' -ForegroundColor Cyan
    Write-Host '  [1] Push ConfigDrift.* attributes to WhatsUp Gold'
    Write-Host '  [2] Export audit results (with diffs) to JSON'
    Write-Host '  [3] Export checks to CSV'
    Write-Host '  [4] Show drift summary and diffs'
    Write-Host '  [5] Generate configuration drift dashboard'
    Write-Host '  [6] Exit'
    Write-Host '  [7] Dashboard + Push to WUG'
    Write-Host ''
    $choice = Read-Host -Prompt 'Choice [1-7]'
}
$actionsToRun = if ($choice -eq '7') { @('5', '1') } else { @($choice) }

foreach ($currentChoice in $actionsToRun) {
    switch ($currentChoice) {
        '2' {
            $jsonPath = Join-Path $OutputPath 'ConfigDrift-Audit.json'
            $export = @($audits | ForEach-Object {
                $a = $_.ConfigDriftAudit
                [pscustomobject]@{ Target = $a.Target; Status = $_.Attributes['ConfigDrift.Status']; Hash = $a.Hash; BaselineHash = $a.BaselineHash; AddedLines = $a.AddedLines; RemovedLines = $a.RemovedLines; LineCount = $a.LineCount; Checks = $a.Checks; Diff = $a.Diff }
            })
            [System.IO.File]::WriteAllText($jsonPath, ($export | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "Exported to $jsonPath" -ForegroundColor Green
        }
        '3' {
            $checks | Export-Csv -Path (Join-Path $OutputPath 'ConfigDrift-Checks.csv') -NoTypeInformation -Encoding UTF8
            Write-Host "Exported checks to $OutputPath" -ForegroundColor Green
        }
        '4' {
            $checks | Select-Object Target, Category, Check, Status, Value | Format-Table -AutoSize
            foreach ($item in @($audits | Where-Object { $_.ConfigDriftAudit.DriftDetected })) {
                Write-Host "=== $($item.DeviceIP) ===" -ForegroundColor Cyan
                Write-Host (Format-ConfigDiff -Diff @($item.ConfigDriftAudit.Diff | Where-Object { $_.Operation -eq 'Added' -or $_.Operation -eq 'Removed' }))
            }
        }
        '5' {
            if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) { Write-Warning 'Dashboard generator not available.'; continue }
            if ($checks.Count -eq 0) { Write-Warning 'No checks to render.'; continue }
            $htmlPath = Join-Path $OutputPath 'Config-Drift-Dashboard.html'
            $checks | Export-DynamicDashboardHtml -OutputPath $htmlPath -ReportTitle 'Configuration Drift Audit' `
                -CardField @('Status', 'Category', 'Target') -StatusField 'Status' -ExportPrefix 'config_drift' | Out-Null
            Write-Host "Dashboard: $htmlPath" -ForegroundColor Green
        }
        '6' { Write-Host 'No action taken.' -ForegroundColor Gray }
        '1' {
            Write-Host ''
            Write-Host 'WUG push: publishing ConfigDrift.* attributes ...' -ForegroundColor Cyan
            if (-not $wugConnected) {
                Import-Module (Join-Path $repoRoot 'WhatsUpGoldPS.psd1') -Force -ErrorAction Stop
                if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) { throw 'Could not connect to WhatsUp Gold.' }
                $wugConnected = $true
            }
            $wugDeviceIds = New-Object 'System.Collections.Generic.List[int]'
            $pushPlan = New-Object 'System.Collections.Generic.List[object]'
            foreach ($item in $audits) {
                $wugDeviceId = Resolve-WUGDiscoveryTargetDevice -Target $item.DeviceIP -Note 'Added by WhatsUpGoldPS config drift discovery.'
                if (-not $wugDeviceId) { continue }
                $item.DeviceId = $wugDeviceId
                [void]$pushPlan.Add($item)
                if (-not $wugDeviceIds.Contains($wugDeviceId)) { [void]$wugDeviceIds.Add($wugDeviceId) }
            }
            if ($pushPlan.Count -eq 0) { Write-Warning 'Nothing to push.'; continue }
            $sync = Invoke-WUGDiscoverySync -Plan $pushPlan.ToArray()
            $group = Sync-WUGDiscoveryDeviceGroup -Name 'ConfigDrift-WhatsUpGoldPS' -DeviceId $wugDeviceIds.ToArray() `
                -Description 'Devices audited by WhatsUpGoldPS configuration drift discovery.' -Confirm:$false
            Write-Host ''
            Write-Host 'Push complete.' -ForegroundColor Green
            Write-Host "  Devices:        $($wugDeviceIds.Count)"
            Write-Host "  Attributes set: $($sync.AttrsUpdated)"
            if ($sync.Failed) { Write-Host "  Failed:         $($sync.Failed)" -ForegroundColor Red }
            if ($group.GroupId) { Write-Host "  Group: ConfigDrift-WhatsUpGoldPS (ID $($group.GroupId)); added $($group.Added)." -ForegroundColor Gray }
            Write-Host '  Tip: create a dynamic group on ConfigDrift.Status = Drift to alert on changes.' -ForegroundColor DarkGray
        }
        default { Write-Warning "Unrecognised choice '$currentChoice'." }
    }
}

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUx3+ZJybVFnOS6pAgEbB9oCa/
# Yz2ggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG
# 9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkw
# FwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1
# cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBi
# MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
# d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3Qg
# RzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAi
# MGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnny
# yhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE
# 5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm
# 7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5
# w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsD
# dV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1Z
# XUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS0
# 0mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hk
# pjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m8
# 00ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+i
# sX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB
# /zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReui
# r/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0w
# azAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUF
# BzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVk
# SURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAG
# BgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9
# mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxS
# A8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/
# 6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSM
# b++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt
# 9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGGjCC
# BAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG9w0BAQwFADBWMQswCQYD
# VQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0
# aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAw
# WhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcg
# Q0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAmyudU/o1P45g
# BkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxDeEDIArCS2VCoVk4Y/8j6
# stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk9vT0k2oWJMJjL9G//N52
# 3hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7XwiunD7mBxNtecM6ytIdUl
# h08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ0arWZVeffvMr/iiIROSC
# zKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZXnYvZQgWx/SXiJDRSAolR
# zZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+tAfiWu01TPhCr9VrkxsHC
# 5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvrn35XGf2RPaNTO2uSZ6n9
# otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn3UayWW9bAgMBAAGjggFk
# MIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaRXBeF5jAdBgNVHQ4EFgQU
# DyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYDVR0gBBQwEjAGBgRVHSAA
# MAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRwOi8vY3JsLnNlY3RpZ28u
# Y29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYuY3JsMHsGCCsGAQUF
# BwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0
# aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAjBggrBgEFBQcwAYYXaHR0
# cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBAAb/guF3YzZu
# e6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXKZDk8+Y1LoNqHrp22AKMG
# xQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWkvfPkKaAQsiqaT9DnMWBH
# VNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3dMapandPfYgoZ8iDL2OR3
# sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwFkvjFV3jS49ZSc4lShKK6
# BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZaPATHvNIzt+z1PHo35D/f
# 7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8bkinLrYrKpii+Tk7pwL7T
# jRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7EwoIJB0kak6pSzEu4I64U6
# gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TWSenLbjBQUGR96cFr6lEU
# fAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg51Tbnio1lB93079WPFnY
# aOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoUKD85gnJ+t0smrWrb8dee
# 2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGPjCCBKagAwIBAgIQB5zg5NEUf4XN
# OXPPdi036zANBgkqhkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP
# U2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNp
# Z25pbmcgQ0EgUjM2MB4XDTI2MDIwOTAwMDAwMFoXDTI5MDQyMTIzNTk1OVowVTEL
# MAkGA1UEBhMCVVMxFDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNv
# biBBbGJlcmlubzEXMBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDzemjeAdcmFpCOW+UwY9yNFVf6XhE6x2+hGOAR
# xsbfAKfnk/lqRKSchLUWD8RJjSS9wN/AZIO5sMzxN/9TSue9GQQrgY0gJ+JkgyIC
# Ll2Z78gTvVtTkLOXeuzJSS1ABLn5dfLTq90k9Q3jvYEo0EgBOTapdEA8T55vdzmQ
# aJ/hc9wphPs9zMAHtoeCnbUQJwqsDPv1e4gXW8PiTsaJacfu0VYxsj66ExDSBt6X
# v4Srz2+dNZX/LgQAAy3Y2a+YqfLyFm3/Oe2MNQbtdJ1SOx1t3hPApef/3da4mx5c
# 080C37bVvpPg2hbCmQQS+epeGAJSFUbKzohNZHR2GMeiBqxAPNPUe/k2QPQ8xqsh
# Yr/apiQGy+Hw8HrQ3siKvjs7c9S7xHcvEXHdCQWPieEtHgxBSAN19DfFXC3gMGmy
# m/QI7pSl8FHqgiS7ze/QifdFE2W9viPrWpo9HZ/iCjBLCeL+BoMe9rMRa/ful84q
# HbU4OS7n9sXevj4YWpjsRdqcfSzm4QSyxDMkbAh2SM1WThSrvQaR0B+7nxgfkmvN
# E5YtP+ixMp/fmzGFotrbZ+pSzj04VzIkGqKEVKuqtrt/heEmj5cVRSyOziVTIWq+
# p1uo6AbxC0yT5gDUjIw0kRQ3x0QnRm2bC/5HhCyTcvo2XLRelb8UBIxTPP22s7uq
# mIawOwIDAQABo4IBiTCCAYUwHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhek
# zQwwHQYDVR0OBBYEFOmBdKNA+QFYSh21aHK/BmkiAYmwMA4GA1UdDwEB/wQEAwIH
# gDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEw
# NQYMKwYBBAGyMQECAQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5j
# b20vQ1BTMAgGBmeBDAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNl
# Y3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5Bggr
# BgEFBQcBAQRtMGswRAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdo
# dHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAYEABCLJuMZz
# nf7WTFaysIt3aAF7wsDgP0WEJxSQ+0f20kEbt8FxCuKPUiHn8ntfAf6uH4QZITQC
# bhL00ABn6m26caMNNyeT6w06dVjwlm1yl/Ds/bxliRcicURn7ZHc2eeyRNNLMpxD
# EvFwsCzvT99jMkfWfVEa6Yizyfa0I3xzG9QVHb2jWsqJpu2liwJw/l+45uqPLDU+
# QJ9XMBAKG+6G1gzOrF/d8KYcCTQSQLLR/Ts7Oi8CEjl+rCkuwipvTdyqfITlLntG
# RwLWXRZeqObtdsMvs84nhhCOdHypze+xXzShTlipUujicJQK3GxXoAeSvPS3BOYj
# UpmjN1TAdgA1dRRHIxkh8OJU4NVsfljADHZf+5273xcSfbrubTYk+eAdLPpWTvx8
# 7cF2EFHM3bBaJ96Y7Da7JPWZWpQYuUh5CLvheoO7VohL967VQKZiUZy5FK9l6tmu
# J27JVAreIyrOVF+FdZ0l/DjPvgF6MlRjvok4+8/qZelxPRsP03eliiirMIIGtDCC
# BJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcN
# MjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQg
# RzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URed
# Ta2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW
# 2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH
# ++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7
# RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBY
# qHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk8
# 1coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqU
# JfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3h
# j0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW/
# /1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyO
# Di7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIsp
# zOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
# BBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8u
# Zz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3
# BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDov
# L2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4IC
# AQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXj
# DNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoa
# lhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQY
# K9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId
# +ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQC
# qjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yo
# sn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ
# 1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk
# 43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEd
# mcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjl
# gp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQIC
# EAhP3DNPfkVO28MPj/mSGDUwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0y
# NjA4MDUwMDAwMDBaFw0zNzExMDQyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJT
# QTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI2IDEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC2e6byyf7NSvjUm0xls/04xjD4fAkOkbnGQi7+Wpx8
# 1iYxfzViaxSIctuH3KSl5YEYpMuFgGsA31N2D9ATMbfZdw5uaAhuWevQKhDdZIB4
# NnqcfpfpWQXJiQnDdAElETC+bhSEvNLGbA8DtwUpFMQ4yyYQSPqomT92osQAv6hB
# i47ATZS6JfVWe6XxhF4jJZ3iSAuf2Cros1czRSmWRHqMv9AfGZvp8ygYElhudpQj
# tcPpwoOl6QrZJUyV3iINvN4cO05prGV0fkjG426xDr2d3z9lcSIHkdvGPdGUrXdx
# fVbgOUVcp2/8ISEzwKPW++Wa+E2ujI91EZtukGWDJ/xZ27k3oHKEXBRGfRTqjOU+
# jE3ba/5++JSE/7oNHnjs5mekExYN96LV/mxUbCKJb8pBNY4r3uD7hEmk/M81XhVg
# wDA7aMzYC3LZBg9WY5BMmbSay5ecmtJuXaB/0nKWmQmVZeqTVDgsmzHP5MQuhAJk
# iWNuC9MmCg9TZHXbJ2/yLVSov9p16UDTLtT0+aa1vN71fHeu1qMLlLNB3WOB/ADC
# xr3S/1hxI92Z6jKgEED/btwIvbfuXkNNhg8MtDg43c4tMZae9FvqMOt/9PvmAxF9
# TNIsIFB8G6yb36ZJZGUL8N/pL971DyLXcK6HM5PYnH5X+eVtczhCgHCVQCF6XDAl
# PQIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUFMljijAu1Er7
# bpTz5uNAfvXszeIwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYD
# VR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcB
# AQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0G
# CCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYD
# VR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAjcU6YR6dUgrfmawJgH59KECxa9Ji8sEi2g10CBDaMiqsaxWyW5cwlT/6ZF5s
# FznazqVsoC85U9dqLOYqQwst+UQQoNlDHgKRLa3xoc+OReFreFhnTXSG0Vrd2E2C
# ZqUfm+5a+He1MJ/h+tNLuA+0Zzhn/Fo+FDYAHWZHx4R79ZsfRFYe9UiXpXBDf6Dk
# Uo183Y38NYmR/XfDYf7YZ+oR9t3flbDwK+hgGMs0gNNp1w9Z2CyOyI5or/sSwomA
# uNQ0hWC9xoU4stD8aWsD7RkcmgVRs6vlIk3zPKQ+ylcheWkMlj+CoVRlFE55pv0Z
# WCaFt04lwP/rdGHE9qEVQZtyRE42ox7oNgC/r+Y4bSlZ3dw9K2x1xLtu6PkPKeLB
# FjzKigwfqm3Hm+k/+lnME8F5kPZTgiy2HLEHklpryqs6QHnPXrRNeIzkAMyylnRN
# 8P0wmirS0WkU+ywpEWFZ4QNg+9xS43tTuW9x0eXh7NDc1P/sV+zWxHXKH8tFt1nc
# HdVzqrZaYPyYMLSn2TOXajveJW1L3joiQSPsWRGxkbDDW15jERFE4LvjnGu2O9zD
# 1nLJSMdlYZEikl4w2w+q4IN/R+TIe0H4ngCI1moJCTbevGH4punIxM1Uoi0nmX3Z
# K+XbRT01uowE5ViXWHng0RgsmrX/EdYUo80r3TfMlkD0/YMxggYzMIIGLwIBATBo
# MFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNV
# BAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+F
# zTlzz3YtN+swCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFFXAFaFG3GW7xaJWCsnpYJppsbQnMA0G
# CSqGSIb3DQEBAQUABIICANOC8EtKlGsNIA3iQkEqwAE1xSSihjCKZeiwkliPmORz
# IFswKr5SzWOW5HvIwMEKtE0G9Wv29DecEeVSAgNcdL40sh9ZSV5lBRY3FiLksjPj
# +Iu5xvn25bmOilTw214voMKNic5zSVdgyR0As99aCXZq4HFrEcb61zYfgy2CZXuJ
# egu1kxzH7RNNsMR4dU7+T1o6JBQIrC+xu9LQG7Bj/CDV5oEHELCSKWtOhNRyaTso
# 3j1oec6fmQ9QY2Bo1J11jbbQeR1rauBAy2/mO/CMdvW8LVabaWA+AO7sbM+ZGxrQ
# 1qrBEP12f/Oiu9TK8pZgE0Zq6sEbI88Alcp4MqA/SyX1n3RIVF/N0Xe0HU4BIJC5
# YdNVEcagzjGq7HDhnU7FYzcVlHSgJ3oyUcbB4FYus2V6aYWrWStHB05/ms++ZqW3
# VwaSzApot0YXHUWhcLLvfi0l9p5PGdd7IlXgi8UhUl9z0V3dk1cpP6wowkwidk3x
# 7xs4uMx++oNGXkwyEZAUXRcq+R/Lv6CrrfICjv7sD4MxeejC6omvH6j4Go8wzN5Y
# gtwpc5oIst9uGFij6VqQ43g8QIllifwnR9UG2rci/4OrrPar5D9UoNeaSxGu17p7
# pvVnor55v+fkcP4w9sagqTAfV2PWdUPx62O6Ew0TDVjItgCb+soCScHf6oI+Touu
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDI0OFowLwYJKoZIhvcN
# AQkEMSIEIE+QeQeSRnqQsONYcKOusas2+1siQvpheLaI+DEoqzhZMA0GCSqGSIb3
# DQEBAQUABIICAGCyCcqOEaYFCi398VVEC+NqYR/rNgNBEkuqKLRKVMblJIX+M99T
# DHK+H/bKMKQ4OQsKcpSjFGzxDbN/RylgZ5/BaBW5jA6J6nxQYL1zZgF6FaJA2v6d
# lUDF0J94Ecs6CJH9eyWk0WFrsRGClzmGjNTEQ89vQRyA/pV7KP7dXxrVDOGXjrss
# SHmJ8zzOTYeUPKXSCC25AwrMx3bYIBTwnfMmQVXj0xUSrSMt0rcMaTOdRtREXZad
# e+ADFfW2fcVtio7mp+JjCoM5FCzUyiBZitPSYdylUyv+fDUSpKteyn9xhiEJ+FTM
# Z1WrjjTQMDWcf07X2I9yq5fZ+AYPQA1++a7MN8sR5aOcMOT2BZ04uau8qajDIAxU
# Ii8Jhqn2mnFsowjxFeTrnLRVWL1yh27qYWAAByPFfP/uvolr/61IB2zpXPHfRVo4
# ZlNtX3Sl6iT3BsI43HCjkZoMxZBIB7PsKUnC3Gr5DfcRVVFEoeP1t3cXzJXdAwP5
# +MjdGP6iYxvGVSgKUEfD0k91L22qZEVjOWUdnStCQ2cEbWSlQW5hTMNq1eIczheu
# yICAdwFmGxHX1VVJi6/hnddTFxzT0zc3rWZp4/rT7TSujxPeDoPnW0U7dTumjJqU
# qNquy/rhsBY0Dar6AJfuy0FX01tMRhUb3jf6k/rq/jvc6LrH35PlB5EY
# SIG # End signature block
