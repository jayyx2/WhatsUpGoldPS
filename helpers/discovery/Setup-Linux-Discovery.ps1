<#
.SYNOPSIS
    Linux Discovery - SSH compliance inventory with WhatsUp Gold SSH monitors and attributes.

.DESCRIPTION
    Connects to each Linux host over SSH, collects OS, patch, systemd, disk, inode,
    NTP, listening-port, reboot and sshd facts, evaluates them, and lets you choose
    what to do with the results:

      [1] Push to WhatsUp Gold (SSH credential, SSH monitors, Linux.* attributes)
      [2] Export facts, checks and monitor plan to JSON
      [3] Export checks and monitor plan to CSV
      [4] Show compliance summary
      [5] Generate Linux compliance dashboard
      [6] Exit
      [7] Dashboard + Push to WUG

    WUG monitors run with the device's SSH credential, so a push needs a password
    credential. Key-file logins can still produce dashboards and exports.

.PARAMETER Target
    Linux host names or IPv4 addresses. Prompts when omitted in interactive mode.

.PARAMETER SshCredentialName
    Vault entry holding the SSH PSCredential. Default: Linux.Ssh.

.PARAMETER KeyFile
    Private key for discovery-only runs. Pushes still require the vault password credential.

.PARAMETER SshPort
    SSH port. Default: 22.

.PARAMETER AllowedPort
    Expected listening ports; anything else is flagged as a warning.

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
    .\Setup-Linux-Discovery.ps1 -Target web01,10.0.0.20 -Action Dashboard

.EXAMPLE
    .\Setup-Linux-Discovery.ps1 -Target 10.0.0.20 -AllowedPort 22,443 -Action DashboardAndPush -NonInteractive
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [string]$SshCredentialName = 'Linux.Ssh',

    [string]$KeyFile,

    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,

    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 60,

    [ValidateRange(1, 100)]
    [int]$DiskWarnPercent = 85,

    [ValidateRange(1, 100)]
    [int]$DiskFailPercent = 95,

    [ValidateRange(1, 3650)]
    [int]$PatchWarnDays = 30,

    [ValidateRange(1, 3650)]
    [int]$PatchFailDays = 90,

    [int[]]$AllowedPort,

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
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Linux.ps1')
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

Write-Host '=== Linux Discovery (SSH compliance) ===' -ForegroundColor Cyan

if ($Target) {
    $targets = @($Target | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })
}
elseif ($NonInteractive) {
    throw 'Target is required in non-interactive mode.'
}
else {
    $targetInput = Read-Host -Prompt 'Linux host name(s) or IP address(es), comma-separated'
    $targets = @($targetInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($targets.Count -eq 0) { throw 'At least one target is required.' }
Write-Host "  Targets: $($targets -join ', ')  SSH port: $SshPort"

$credSplat = @{ Name = $SshCredentialName; CredType = 'PSCredential'; ProviderLabel = 'Linux SSH' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
$sshCredential = $null
if (-not $KeyFile -or -not $NonInteractive) {
    Write-Host "Authentication: resolving SSH credential from vault entry '$SshCredentialName' ..." -ForegroundColor Cyan
    $sshCredential = Resolve-DiscoveryCredential @credSplat
}
if (-not $sshCredential -and -not $KeyFile) { throw "No SSH credential available in '$SshCredentialName'." }
if ($sshCredential) { Write-Host "Authentication: using SSH account '$($sshCredential.UserName)'." -ForegroundColor Green }

$options = @{
    SshPort         = $SshPort
    TimeoutSeconds  = $TimeoutSeconds
    DiskWarnPercent = $DiskWarnPercent
    DiskFailPercent = $DiskFailPercent
    PatchWarnDays   = $PatchWarnDays
    PatchFailDays   = $PatchFailDays
}
if ($sshCredential) { $options['Credential'] = $sshCredential }
if ($KeyFile) { $options['KeyFile'] = $KeyFile; if ($sshCredential) { $options['Username'] = $sshCredential.UserName } }
if ($AllowedPort) { $options['AllowedPort'] = $AllowedPort }

$plan = @(Invoke-Discovery -ProviderName 'Linux' -Target $targets -ApiPort $SshPort -Options $options)
$checks = @($plan | Where-Object { $_.PSObject.Properties['LinuxChecks'] } | ForEach-Object { @($_.LinuxChecks) })
$collected = @($plan | Where-Object { $_.PSObject.Properties['LinuxChecks'] } | Select-Object -ExpandProperty DeviceIP -Unique)
foreach ($missing in @($targets | Where-Object { $collected -notcontains $_ })) {
    $checks += New-LinuxComplianceCheck -Target $missing -Category 'Collection' -Check 'SSH collection' -Status 'Fail' -Value 'error' -Detail 'SSH collection failed; see warnings above.'
}
$monitorItems = @($plan | Where-Object { $_.ItemType -in @('ActiveMonitor', 'PerformanceMonitor') })
$summary = @(Get-LinuxComplianceSummary -Checks $checks)

Write-Host ''
Write-Host "Discovery complete: $($collected.Count) of $($targets.Count) host(s) collected." -ForegroundColor Green
foreach ($row in $summary) {
    $color = switch ($row.Status) { 'Fail' { 'Red' } 'Warn' { 'Yellow' } default { 'Gray' } }
    Write-Host ('  {0,-24} {1,-7} pass={2} warn={3} fail={4} unknown={5}' -f $row.Target, $row.Status, $row.Pass, $row.Warn, $row.Fail, $row.Unknown) -ForegroundColor $color
}
Write-Host "  Active monitors:      $(@($monitorItems | Where-Object ItemType -eq 'ActiveMonitor' | Select-Object -ExpandProperty Name -Unique).Count) unique"
Write-Host "  Performance monitors: $(@($monitorItems | Where-Object ItemType -eq 'PerformanceMonitor').Count)"

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
    Write-Host '  [1] Push SSH monitors and attributes to WhatsUp Gold'
    Write-Host '  [2] Export facts, checks and monitor plan to JSON'
    Write-Host '  [3] Export checks and monitor plan to CSV'
    Write-Host '  [4] Show compliance checks'
    Write-Host '  [5] Generate Linux compliance dashboard'
    Write-Host '  [6] Exit'
    Write-Host '  [7] Dashboard + Push to WUG'
    Write-Host ''
    $choice = Read-Host -Prompt 'Choice [1-7]'
}
$actionsToRun = if ($choice -eq '7') { @('5', '1') } else { @($choice) }

foreach ($currentChoice in $actionsToRun) {
    switch ($currentChoice) {
        '2' {
            $jsonPath = Join-Path $OutputPath 'Linux-Compliance.json'
            $facts = @($plan | Where-Object { $_.PSObject.Properties['LinuxFacts'] } | ForEach-Object { $_.LinuxFacts })
            $export = [ordered]@{ GeneratedAt = (Get-Date).ToString('o'); Summary = $summary; Facts = $facts; Checks = $checks; MonitorPlan = @($monitorItems | Export-DiscoveryPlan -Format Object) }
            [System.IO.File]::WriteAllText($jsonPath, ($export | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "Exported to $jsonPath" -ForegroundColor Green
        }
        '3' {
            $checks | Export-Csv -Path (Join-Path $OutputPath 'Linux-Compliance-Checks.csv') -NoTypeInformation -Encoding UTF8
            if ($monitorItems.Count) { $monitorItems | Export-DiscoveryPlan -Format CSV -Path (Join-Path $OutputPath 'Linux-Monitor-Plan.csv') }
            Write-Host "Exported compliance checks and monitor plan to $OutputPath" -ForegroundColor Green
        }
        '4' { $checks | Select-Object Target, Category, Check, Status, Value, Detail | Format-Table -AutoSize -Wrap }
        '5' {
            if (-not (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue)) { Write-Warning 'Dashboard generator not available.'; continue }
            if ($checks.Count -eq 0) { Write-Warning 'No checks to render.'; continue }
            $htmlPath = Join-Path $OutputPath 'Linux-Compliance-Dashboard.html'
            $checks | Export-DynamicDashboardHtml -OutputPath $htmlPath -ReportTitle 'Linux Fleet Compliance' `
                -CardField @('Status', 'Category', 'Target') -StatusField 'Status' -ExportPrefix 'linux_compliance' | Out-Null
            Write-Host "Dashboard: $htmlPath" -ForegroundColor Green
        }
        '6' { Write-Host 'No action taken.' -ForegroundColor Gray }
        '1' {
            if (-not $sshCredential) { Write-Warning 'WUG SSH monitors need a password credential; add one to the vault and rerun.'; continue }
            Write-Host ''
            Write-Host 'WUG push: loading module and connecting ...' -ForegroundColor Cyan
            Import-Module (Join-Path $repoRoot 'WhatsUpGoldPS.psd1') -Force -ErrorAction Stop
            if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) { throw 'Could not connect to WhatsUp Gold.' }

            $credentialName = "WhatsUpGoldPS Linux SSH ($($sshCredential.UserName))"
            $wugCredential = @(Get-WUGCredential -SearchValue $credentialName -Type ssh -View basic) |
                Where-Object { $_.name -eq $credentialName } | Select-Object -First 1
            if (-not $wugCredential) {
                Write-Host "  Creating WUG SSH credential '$credentialName' ..." -ForegroundColor Yellow
                $wugCredential = Add-WUGCredential -Name $credentialName -Type ssh -SshUsername $sshCredential.UserName `
                    -SshPassword $sshCredential.GetNetworkCredential().Password -SshPort ([string]$SshPort) -Confirm:$false
            }
            $wugCredentialId = if ($wugCredential.PSObject.Properties['resourceId']) { [string]$wugCredential.resourceId } else { [string]$wugCredential.id }
            if (-not $wugCredentialId) { throw "Could not resolve WUG credential '$credentialName'." }
            Write-Host "  SSH credential: $credentialName (ID $wugCredentialId)" -ForegroundColor Gray

            $wugDeviceIds = New-Object 'System.Collections.Generic.List[int]'
            $pushPlan = New-Object 'System.Collections.Generic.List[object]'
            foreach ($targetAddress in $collected) {
                $wugDeviceId = Resolve-WUGDiscoveryTargetDevice -Target $targetAddress -PrimaryRole 'Server' -CredentialId $wugCredentialId `
                    -Note 'Added by WhatsUpGoldPS Linux discovery.'
                if (-not $wugDeviceId) { continue }
                if (-not $wugDeviceIds.Contains($wugDeviceId)) { [void]$wugDeviceIds.Add($wugDeviceId) }
                foreach ($item in @($plan | Where-Object { $_.DeviceIP -eq $targetAddress })) { $item.DeviceId = $wugDeviceId; [void]$pushPlan.Add($item) }
            }
            if ($pushPlan.Count -eq 0) { Write-Warning 'Nothing to push.'; continue }

            Write-Host "WUG push: syncing $($pushPlan.Count) plan item(s) ..." -ForegroundColor Cyan
            $sync = Invoke-WUGDiscoverySync -Plan $pushPlan.ToArray() -PerfPollingIntervalMinutes 15
            $group = Sync-WUGDiscoveryDeviceGroup -Name 'Linux-WhatsUpGoldPS' -DeviceId $wugDeviceIds.ToArray() `
                -Description 'Linux hosts managed by WhatsUpGoldPS Linux discovery.' -Confirm:$false
            Write-Host ''
            Write-Host 'Push complete.' -ForegroundColor Green
            Write-Host "  Devices:             $($wugDeviceIds.Count)"
            Write-Host "  Active created:      $($sync.ActiveCreated)"
            Write-Host "  Performance created: $($sync.PerfCreated)"
            Write-Host "  Assigned:            $($sync.Assigned)"
            Write-Host "  Skipped (existing):  $($sync.Skipped)"
            Write-Host "  Attributes set:      $($sync.AttrsUpdated)"
            if ($sync.Failed) { Write-Host "  Failed:              $($sync.Failed)" -ForegroundColor Red }
            if ($group.GroupId) { Write-Host "  Group: Linux-WhatsUpGoldPS (ID $($group.GroupId)); added $($group.Added)." -ForegroundColor Gray }
        }
        default { Write-Warning "Unrecognised choice '$currentChoice'." }
    }
}

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUC1B92HqNlHirQUHid+jZmYVq
# gDCggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFCfjKCibfNq2rFMvRN+KI6sUAy04MA0G
# CSqGSIb3DQEBAQUABIICAKsh4yGYKtBlEas/2e6ISXp5DStWso4jaGN38FuTtafG
# 7oW3H3XfG40wl96nVoiSLF8wSmaaZtWEFPtEOd5YawOHuWhV4SDC6+kT7FiaH6y1
# L+AjZVPNg3k1y9rAYhz5pdFcqft9Ci1v6gji4tHAt8qD16f0kDqlyj2uRfdTRWSn
# LV6xn/8uWsOvFIDtbztL1W0uHERM/SataX3DfkoFch6ZkMemeoJM/K6HlJZ8PB+l
# Wwi5cXfZsiWoZ1SPtmQez914i6HijpqR1LEAldgIdj5eIc4ibD4U8FrBU4i0vYil
# ybv3toZxm6Tqlj4w5kkc3SSkLCsCFe8BvHrcczwqW9TMq59EpviDkt4XDXfC8eKT
# 5WI//bKMs2jP9glbamSTKmFB/I/8/k5O8nQ+oiZROiU3JCGRaPf/vCfB1dhPuTGf
# n/afU/hA/48ng8Z29bVES97qr61+T/CYNVcfyT4WCzcOFnPG6FlRxC2AThFHVbEb
# 8a5KoO2OAcpHQ7tzEqd5l4yf/GvQGhlbCaUwiEDYO3FDN2yny2q/tjCe5EcqMLj5
# 1kWKaPyw8ZRfZPwenNYDHTA/v3pGT3QwZ++zYft5co6VxDQ3uN2dPuskPunJBgcR
# 5OfPQIEk4bhbHIZT+OJJCFx5/n9j3JDrAQpQJVSY4Ehq0sbpBdVVQzcn6ylc8Lu1
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDI1MVowLwYJKoZIhvcN
# AQkEMSIEIHLVFN1wtsY8qg6F/8N+lDgZ5xFzQImKDdV1TQvhmxAzMA0GCSqGSIb3
# DQEBAQUABIICAFLg1zguuC8asZ6kAzVhl0lJkNtn7owHIMNJzXcks8sRQaPWv6bQ
# CBXcuwJqMl3xuRIc0muLOH/qA1+dUK6fUAAJTgYPDaUrNC+6UcfAy+86dMMnWi9Y
# 5fbd2TqsqIxOZm2YxuicWMob9Qx4oPo/bMqvV+CZU1rVx/dG2gz5xyplLg+UADgE
# M3ZBCm7bg8jDthD7+DTjtCPjf3Z0cWx/Z2fh+P7pvxOxkWM0eS60deAPkUS3S7DW
# mi3XITUEd5/ZTAWaAjJPaabUspL46Z3sUJ4/qgX/tuI/aSQzGx+mGSbkd/dQi9rQ
# d1Xjz0nyAAaSnONwqksHMi4+S4CiLRCfSvjda+OkINRvaKMhqSDgi6CKyFzzsEvj
# ZuEs1m+ovFZnx8znI/YtkuwMq5l3dLFkeW7oe/WTA2AH86LpHlXk2Be/oza84BEz
# NEPXfT6LhmbdjnnVNucxg2+TfWDzT+qMIUZwZc5zNJNwQ3oi9lWJ2wL8Ek/EA4F+
# DHlwh4bAcoCgIouQo7cfiPNA1bSuuaOSuII8WeQmDq16PQCJEmwjEMReBFPTzAmt
# 1Y6h3xpMfW4r2F7D0tVyGbqqB335W7IH4M7jHyKJhJ0EVVH7Cr2wUikoUeJzzzkH
# mYDjVs0h1V6wYYCyK0oACuWLHvQZvW0p36YMIiz7WnB6QuJT3IpZQpaP
# SIG # End signature block
