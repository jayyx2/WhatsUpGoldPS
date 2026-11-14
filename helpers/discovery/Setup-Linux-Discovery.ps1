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
      [8] Validate planned monitor commands over SSH (no WUG changes)

    WUG monitors run with the device's SSH credential, so a push needs a password
    credential. Key-file logins can still produce dashboards and exports.
    Pushes validate each exact command with password authentication first.
    Performance monitors are shared by command/mount point. Existing host-named
    monitors are not automatically deleted. Inventory writes only changed,
    nonempty values, and the Linux OS role is set only when WUG has none.

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
    PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, Validate, or None.

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
[CmdletBinding(SupportsShouldProcess = $true)]
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

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'Validate', 'None')]
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
        'Validate' { '8' }
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
    Write-Host '  [8] Validate monitor commands over SSH (no WUG changes)'
    Write-Host ''
    $choice = Read-Host -Prompt 'Choice [1-8]'
}
$actionsToRun = if ($choice -eq '7') { @('5', '1') } else { @($choice) }

$validatedPlan = New-Object 'System.Collections.Generic.List[object]'
if (@($actionsToRun | Where-Object { $_ -in @('1', '8') }).Count -gt 0) {
    if ($choice -ne '8' -and -not $sshCredential) { throw 'WUG pushes require a password credential for SSH validation.' }
    foreach ($targetAddress in $collected) {
        $hostPlan = @($plan | Where-Object DeviceIP -eq $targetAddress)
        try {
            $validation = @(Test-LinuxMonitorCommands -Target $targetAddress -Plan $hostPlan -Credential $sshCredential `
                -KeyFile $KeyFile -Port $SshPort -TimeoutSeconds $TimeoutSeconds)
            $validation | Select-Object Target, Monitor, Status, Output, Detail | Format-Table -AutoSize -Wrap
            foreach ($v in @($validation | Where-Object { $_.Status -in @('OK', 'Up', 'Down') })) { [void]$validatedPlan.Add($v.Item) }
            foreach ($item in $hostPlan) {
                if ($item.ItemType -eq 'Inventory') { [void]$validatedPlan.Add($item) }
                elseif ($item.Attributes.Count -gt 0 -and -not $validatedPlan.Contains($item)) {
                    $inventoryItem = $item.PSObject.Copy()
                    $inventoryItem.ItemType = 'Inventory'
                    $inventoryItem.MonitorParams = @{}
                    [void]$validatedPlan.Add($inventoryItem)
                }
            }
        }
        catch { Write-Warning "SSH validation failed for ${targetAddress}; this host will not be pushed: $_" }
    }
}

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
        '8' { Write-Host 'Validation complete; no WUG changes made.' -ForegroundColor Gray }
        '1' {
            if (-not $sshCredential) { Write-Warning 'WUG SSH monitors need a password credential; add one to the vault and rerun.'; continue }
            if ($validatedPlan.Count -eq 0) { Write-Warning 'No validated hosts to push.'; continue }
            if (-not $PSCmdlet.ShouldProcess(($collected -join ', '), 'Push validated Linux monitors and inventory to WUG')) { continue }
            Write-Host ''
            Write-Host 'WUG push: loading module and connecting ...' -ForegroundColor Cyan
            Import-Module (Join-Path $repoRoot 'WhatsUpGoldPS.psd1') -Force -ErrorAction Stop
            if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) { throw 'Could not connect to WhatsUp Gold.' }

            $credentialName = "WhatsUpGoldPS Linux SSH ($($sshCredential.UserName))"
            $wugSshCredential = @(Get-WUGCredential -SearchValue $credentialName -Type ssh -View basic) |
                Where-Object { $_.name -eq $credentialName } | Select-Object -First 1
            if (-not $wugSshCredential) {
                Write-Host "  Creating WUG SSH credential '$credentialName' ..." -ForegroundColor Yellow
                $wugSshCredential = Add-WUGCredential -Name $credentialName -Type ssh -SshUsername $sshCredential.UserName `
                    -SshPassword $sshCredential.GetNetworkCredential().Password -SshPort ([string]$SshPort) -Confirm:$false -ErrorAction Stop
            }
            $wugCredentialId = if ($wugSshCredential.PSObject.Properties['resourceId'] -and $wugSshCredential.resourceId) { [string]$wugSshCredential.resourceId }
                else { [string]$wugSshCredential.id }
            if (-not $wugCredentialId) { throw "Could not resolve WUG credential '$credentialName'." }
            Write-Host "  SSH credential: $credentialName (ID $wugCredentialId)" -ForegroundColor Gray

            $wugDeviceIds = New-Object 'System.Collections.Generic.List[int]'
            $pushPlan = New-Object 'System.Collections.Generic.List[object]'
            foreach ($targetAddress in @($validatedPlan | Select-Object -ExpandProperty DeviceIP -Unique)) {
                $wugDeviceId = Resolve-WUGDiscoveryTargetDevice -Target $targetAddress -PrimaryRole 'Server' -CredentialId $wugCredentialId `
                    -Note 'Added by WhatsUpGoldPS Linux discovery.'
                if (-not $wugDeviceId) { continue }
                if (-not $wugDeviceIds.Contains($wugDeviceId)) { [void]$wugDeviceIds.Add($wugDeviceId) }
                foreach ($item in @($validatedPlan | Where-Object { $_.DeviceIP -eq $targetAddress })) { $item.DeviceId = $wugDeviceId; [void]$pushPlan.Add($item) }
                $inventoryItem = $plan | Where-Object { $_.DeviceIP -eq $targetAddress -and $_.PSObject.Properties['LinuxFacts'] } | Select-Object -First 1
                if ($inventoryItem -and $inventoryItem.LinuxFacts.OsId) {
                    try { Set-WUGDiscoveryOSRoleIfUnset -DeviceId $wugDeviceId -OSName 'Linux' }
                    catch { Write-Warning "Could not set Linux OS role on device ${wugDeviceId}: $_" }
                }
            }
            if ($pushPlan.Count -eq 0) { Write-Warning 'Nothing to push.'; continue }

            Write-Host "WUG push: syncing $($pushPlan.Count) plan item(s) ..." -ForegroundColor Cyan
            Sync-LinuxActiveMonitorCommands -Plan $pushPlan.ToArray()
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
            Write-Host "  Attributes unchanged: $($sync.AttrsUnchanged); failed: $($sync.AttrsFailed)"
            if ($sync.Failed) { Write-Host "  Failed:              $($sync.Failed)" -ForegroundColor Red }
            if ($group.GroupId) { Write-Host "  Group: Linux-WhatsUpGoldPS (ID $($group.GroupId)); added $($group.Added)." -ForegroundColor Gray }
        }
        default { Write-Warning "Unrecognised choice '$currentChoice'." }
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAob2CfBDS+gPJr
# yIYEUr1zYeSume2TXq8hNMtUUtT9tKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDV
# Pxn2ObV4/LS6q2pQVpojD6hte39ks+TQbZrs/BJ2MDANBgkqhkiG9w0BAQEFAASC
# AgDgFuqjMKQBv6XSiS++hsz4+dO3bXWUYfZFJW3B1rk4WU5Xf58kTyUG0GXPTNjp
# BesDmXogwrdrCzPoukCQKOsaV/KkI6TIxNkEhG6UGAnJOemLdMe25DUG/YQfHS+l
# 8wBHuPFAu8K9cOfRa3bEGu/dTG2vnbkp5AbwwloUOJ8HFWYapd3zvoBU/TDvKtOo
# 13yR+JNdxiRMz7oq2AiywboAic4B499vF4qoYWxs4qTriLteADdfg4OJ9DBe56eS
# mqO/PAiw1cMOd3M9lawYxEEZhGzLminpYDLN2r8qt8wis+DNr6byXzhklPpOnGqY
# IDn0PAjYRdr/NQFRw7/a4y8BVAvXe9Jtx5NAsowhp9ralW52EoiOvvSY/En/6P1f
# y8z+aD6QvLmhwxxE9V4qeOF6mxwPT10Tzp2/5yU85Bmby05nB+lzJZ28eJaNYm6i
# /xZ/JuPT4p5bgL9dDv8tg1mcpibRFT2pmyiFnobpOijxisbu1LKlflnoa+N5a0f5
# LdlllN3xEhF7ES9yHzaRv2sP3VNK8rG4rTDYSHr1+nYA09GSPJFm2O8UzoWiAFDq
# Xu6FUOU0ZkM80+espMrM1Pc9tJBCAOUT43/BO7KMsxNvGYASesLjTa4rgVgAiks6
# AT9C7uC0plDfhvpeglipmcm29eF1TzBvFdxpuzFSCDmPyqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMxODMzMjBaMC8GCSqGSIb3DQEJBDEiBCDSYNwSk9aU
# LN3+fMB4JNFeovUiiDuqKsT6T4R9B8csmjANBgkqhkiG9w0BAQEFAASCAgAOHehA
# atvsLmjFhMwORBz6Qvcnw0FycUnGWlqLAshkydPeUkheYfoHj/xLazgelynCK6jS
# BoGT+H/KrVWGzqgFN1ZXIpKzBGn5yoGvGkf7KSwEA+LbbIP8UwqERKEj/OpQLtTT
# MAKpzZ5YTGG9RfoZ7qfMcwLyrYjt6MwMRHZWSriwbw6P/J+G6kn91KExMydr53+/
# baE+C2XqFsPiHyl5W+a5zivgT+CZTG65xFNkPHBKdOcGChlSKNcS8o0khH9pUA9y
# IAMGU7v5jU0JIAMZV7KkbtnNOpgK75ZCPPB8wsPB4QeGHNExwvLqok9NQmMHy0zM
# qgUZZqXsrGxOjGBbUEgxI0nGfzo7WbYDEODPMjPIe0DQaISnMMEhwgDAqOfrpY9z
# 84pqGuMVOO6T9cmBrEw/l7QQeui1dMC2YoOBMPA71AoGWhygV2NmfV1l2RM/ItYy
# M58iVOM9oViRMAHGtBe8Oz5iS33ekA6wjNH8Bk8M7QWW1uxW6lf/FMLwKRYGFE8A
# tmQe0Wn2fqYvLZo1k/EZLqy8BA+XAoCnMLoMgGJlbFsUoOMUu3GrFtHSQDDZLwZR
# xut86yHqVwpThxXuY4DD5Dow3uT0pM/jYA/gE1y0+e8MMOKCWBGv6lbfi43VTZZ4
# usIZMdPHE685hecexbm1nOYQC8fhwLagBLSnyg==
# SIG # End signature block
