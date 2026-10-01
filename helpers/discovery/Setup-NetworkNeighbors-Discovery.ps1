<#
.SYNOPSIS
    Network Neighbors Discovery - BGP, EIGRP, CDP, and LLDP adjacency discovery for WhatsUp Gold.

.DESCRIPTION
    Walks the BGP4-MIB, CISCO-EIGRP-MIB, CISCO-CDP-MIB, and LLDP-MIB tables on each
    target router/switch over SNMP (optional SSH enrichment), then lets you choose
    what to do with the results:

      [1] Push to WhatsUp Gold (SNMP credential, neighbor-table and BGP peer monitors)
      [2] Export inventory and monitor plan to JSON
      [3] Export inventory and monitor plan to CSV
      [4] Show neighbor table in console
      [5] Generate network neighbor dashboard
      [6] Exit
      [7] Dashboard + Push to WUG

    Monitors created per device:
      - "Neighbors - <Protocol> Neighbor Table" SNMP Table active monitor (shared
        library entry; each WUG device discovers its own rows)
      - BGP: one SNMP active monitor per peer (state = established) plus state and
        established-time performance monitors
      - EIGRP: hold time, SRTT, RTO, retransmission, and retry performance monitors

    Protocols the device does not run produce no monitors, so no always-down
    table monitors are created.

.PARAMETER Target
    Router/switch address(es). Prompts when omitted in interactive mode.

.PARAMETER Protocols
    Protocols to walk. Default: BGP, EIGRP, CDP, LLDP.

.PARAMETER SnmpCredentialName
    Vault entry holding the SNMP v1/v2c community. Default: Cisco.Snmp (shared with helpers\neighbors).

.PARAMETER UseSsh
    Also collect SSH show-command output for the dashboard (not used for monitors).

.PARAMETER SshCredentialName
    Vault entry holding the SSH account. Default: Cisco.Ssh.

.PARAMETER SnmpPort
    SNMP port. Default: 161.

.PARAMETER Action
    PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, or None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Omit to reuse the current session or the vault.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login.

.PARAMETER OutputPath
    Directory for dashboards and exports.

.PARAMETER NonInteractive
    Suppress prompts; targets and vault credentials must already exist.

.EXAMPLE
    .\Setup-NetworkNeighbors-Discovery.ps1 -Target 10.0.0.1,10.0.0.2 -Action Dashboard

.EXAMPLE
    .\Setup-NetworkNeighbors-Discovery.ps1 -Target 10.0.0.1 -Protocols BGP -Action PushToWUG -NonInteractive
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [ValidateSet('BGP', 'EIGRP', 'CDP', 'LLDP')]
    [string[]]$Protocols = @('BGP', 'EIGRP', 'CDP', 'LLDP'),

    [string]$SnmpCredentialName = 'Cisco.Snmp',

    [switch]$UseSsh,

    [string]$SshCredentialName = 'Cisco.Ssh',

    [ValidateRange(1, 65535)]
    [int]$SnmpPort = 161,

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
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-NetworkNeighbors.ps1')
$neighborDashboardPath = Join-Path (Split-Path $scriptDir -Parent) 'neighbors\Export-NetworkNeighborDashboard.ps1'
if (Test-Path $neighborDashboardPath) { . $neighborDashboardPath }

Write-Host '=== Network Neighbors Discovery (BGP / EIGRP / CDP / LLDP) ===' -ForegroundColor Cyan

if ($Target) {
    $targets = @($Target | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })
}
elseif ($NonInteractive) {
    throw 'Target is required in non-interactive mode.'
}
else {
    $targetInput = Read-Host -Prompt 'Router/switch address(es), comma-separated'
    $targets = @($targetInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($targets.Count -eq 0) { throw 'At least one target is required.' }
Write-Host "  Targets:   $($targets -join ', ')"
Write-Host "  Protocols: $($Protocols -join ', ')"
Write-Host "  Output:    $OutputPath"

$snmpSplat = @{ Name = $SnmpCredentialName; CredType = 'SNMPv2'; ProviderLabel = 'Network Neighbors SNMP' }
if ($NonInteractive) { $snmpSplat.NonInteractive = $true }
elseif ($Action) { $snmpSplat.AutoUse = $true }
Write-Host "Authentication: resolving SNMP community from vault entry '$SnmpCredentialName' ..." -ForegroundColor Cyan
$snmp = Resolve-DiscoveryCredential @snmpSplat
if (-not $snmp -or -not $snmp.Community) { throw "No SNMP community available in vault entry '$SnmpCredentialName'." }
$snmpVersion = if ([int]$snmp.Version -eq 1) { 'V1' } else { 'V2' }
Write-Host "Authentication: SNMP $snmpVersion community resolved." -ForegroundColor Green

$sshCredential = $null
if ($UseSsh) {
    $sshSplat = @{ Name = $SshCredentialName; CredType = 'PSCredential'; ProviderLabel = 'Network Neighbors SSH' }
    if ($NonInteractive) { $sshSplat.NonInteractive = $true }
    elseif ($Action) { $sshSplat.AutoUse = $true }
    $sshCredential = Resolve-DiscoveryCredential @sshSplat
    if (-not $sshCredential) { Write-Warning "No SSH credential in '$SshCredentialName'; continuing with SNMP only." }
}

$options = @{
    Community     = [string]$snmp.Community
    SnmpVersion   = $snmpVersion
    SnmpPort      = $SnmpPort
    Protocols     = $Protocols
}
if ($sshCredential) { $options['SshCredential'] = $sshCredential }

$plan = @(Invoke-Discovery -ProviderName 'NetworkNeighbors' -Target $targets -ApiPort $SnmpPort -Options $options)
if ($plan.Count -eq 0) { throw 'Network neighbor discovery returned no results. Check SNMP reachability and community.' }

$rows = @($plan | Where-Object { $_.PSObject.Properties['NeighborRows'] } | ForEach-Object { @($_.NeighborRows) })
$monitorItems = @($plan | Where-Object { $_.ItemType -in @('ActiveMonitor', 'PerformanceMonitor') })
Write-Host ''
Write-Host 'Discovery complete.' -ForegroundColor Green
Write-Host "  Neighbor rows:        $($rows.Count)"
foreach ($group in @($rows | Group-Object -Property Protocol | Sort-Object Name)) {
    Write-Host ('    {0,-6} {1,5}' -f $group.Name, $group.Count) -ForegroundColor Gray
}
Write-Host "  Active monitors:      $(@($monitorItems | Where-Object ItemType -eq 'ActiveMonitor').Count)"
Write-Host "  Performance monitors: $(@($monitorItems | Where-Object ItemType -eq 'PerformanceMonitor').Count)"
$bgpDown = @($rows | Where-Object { $_.Protocol -eq 'BGP' -and $_.Source -eq 'SNMP' -and $_.State -ne 'Established' })
if ($bgpDown.Count) { Write-Warning "$($bgpDown.Count) BGP peer(s) not established: $(($bgpDown | ForEach-Object { "$($_.Target)->$($_.PeerAddress)" }) -join ', ')" }

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
    Write-Host '  [1] Push to WhatsUp Gold (SNMP credential + neighbor monitors)'
    Write-Host '  [2] Export inventory and monitor plan to JSON'
    Write-Host '  [3] Export inventory and monitor plan to CSV'
    Write-Host '  [4] Show neighbor table'
    Write-Host '  [5] Generate network neighbor dashboard'
    Write-Host '  [6] Exit'
    Write-Host '  [7] Dashboard + Push to WUG'
    Write-Host ''
    $choice = Read-Host -Prompt 'Choice [1-7]'
}
$actionsToRun = if ($choice -eq '7') { @('5', '1') } else { @($choice) }

foreach ($currentChoice in $actionsToRun) {
    switch ($currentChoice) {
        '2' {
            $jsonPath = Join-Path $OutputPath 'NetworkNeighbors-Inventory.json'
            $export = [ordered]@{ GeneratedAt = (Get-Date).ToString('o'); Targets = $targets; Neighbors = $rows; MonitorPlan = @($monitorItems | Export-DiscoveryPlan -Format Object) }
            [System.IO.File]::WriteAllText($jsonPath, ($export | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "Exported to $jsonPath" -ForegroundColor Green
        }
        '3' {
            $rows | Export-Csv -Path (Join-Path $OutputPath 'NetworkNeighbors-Inventory.csv') -NoTypeInformation -Encoding UTF8
            if ($monitorItems.Count) { $monitorItems | Export-DiscoveryPlan -Format CSV -Path (Join-Path $OutputPath 'NetworkNeighbors-Monitor-Plan.csv') }
            Write-Host "Exported neighbor inventory and monitor plan to $OutputPath" -ForegroundColor Green
        }
        '4' {
            $rows | Select-Object Target, Protocol, Source, PeerAddress, NeighborAddress, RemoteDeviceId, RemoteSystemName, LocalInterface, RemotePort, State, Status | Format-Table -AutoSize
        }
        '5' {
            if (-not (Get-Command -Name 'Export-NetworkNeighborDashboard' -ErrorAction SilentlyContinue)) {
                Write-Warning 'Export-NetworkNeighborDashboard.ps1 not found; skipping dashboard.'
            }
            elseif ($rows.Count -eq 0) {
                Write-Warning 'No neighbor rows were collected; skipping dashboard.'
            }
            else {
                $dashboard = Export-NetworkNeighborDashboard -Rows $rows -OutputDirectory $OutputPath
                Write-Host "Dashboard: $($dashboard.HtmlPath) ($($dashboard.RowCount) rows, $($dashboard.CorrelatedCount) correlated)" -ForegroundColor Green
            }
        }
        '6' { Write-Host 'No action taken.' -ForegroundColor Gray }
        '1' {
            Write-Host ''
            Write-Host 'WUG push: loading module and connecting ...' -ForegroundColor Cyan
            $repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
            Import-Module (Join-Path $repoRoot 'WhatsUpGoldPS.psd1') -Force -ErrorAction Stop
            if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) { throw 'Could not connect to WhatsUp Gold.' }

            $credentialType = if ($snmpVersion -eq 'V1') { 'snmpV1' } else { 'snmpV2' }
            $credentialName = "WhatsUpGoldPS Neighbors SNMP $snmpVersion ($SnmpCredentialName)"
            $wugCredential = @(Get-WUGCredential -SearchValue $credentialName -Type $credentialType -View basic) |
                Where-Object { $_.name -eq $credentialName } | Select-Object -First 1
            if (-not $wugCredential) {
                Write-Host "  Creating WUG credential '$credentialName' ..." -ForegroundColor Yellow
                $wugCredential = Add-WUGCredential -Name $credentialName -Type $credentialType -SnmpReadCommunity ([string]$snmp.Community) -Confirm:$false
            }
            $wugCredentialId = if ($wugCredential.PSObject.Properties['resourceId']) { [string]$wugCredential.resourceId } else { [string]$wugCredential.id }
            if (-not $wugCredentialId) { throw "Could not resolve WUG credential '$credentialName'." }
            Write-Host "  SNMP credential: $credentialName (ID $wugCredentialId)" -ForegroundColor Gray

            $wugDeviceIds = New-Object 'System.Collections.Generic.List[int]'
            $pushPlan = New-Object 'System.Collections.Generic.List[object]'
            foreach ($targetAddress in $targets) {
                $match = Find-WUGDiscoveryDeviceMatch -Name $targetAddress -Address $targetAddress
                if ($match.LookupFailed) { Write-Warning "Skipping $targetAddress; WUG lookup failed."; continue }
                $wugDeviceId = $null
                if ($match.Found) {
                    $wugDeviceId = [int]$match.Device.id
                    Write-Host "  [EXISTS] $targetAddress (WUG ID $wugDeviceId)" -ForegroundColor Gray
                }
                elseif ($targetAddress -match '^\d{1,3}(\.\d{1,3}){3}$') {
                    Write-Host "  [CREATE] $targetAddress" -ForegroundColor Yellow
                    $createSplat = @{
                        displayName   = $targetAddress
                        DeviceAddress = $targetAddress
                        Brand         = 'Cisco'
                        PrimaryRole   = 'Router'
                        Note          = 'Added by WhatsUpGoldPS network neighbor discovery.'
                    }
                    if ($snmpVersion -eq 'V1') { $createSplat['CredentialSnmpV1'] = $credentialName } else { $createSplat['CredentialSnmpV2'] = $credentialName }
                    $created = Add-WUGDeviceTemplate @createSplat -ErrorAction Stop
                    if ($created.idMap) { $wugDeviceId = [int]($created.idMap | Select-Object -First 1).resultId }
                    if (-not $wugDeviceId) { Write-Warning "  WUG did not return a device ID for $targetAddress."; continue }
                }
                else {
                    Write-Warning "  $targetAddress is not in WUG and is not an IPv4 address; add it to WUG first."
                    continue
                }

                try { Set-WUGDeviceCredential -DeviceId ([string]$wugDeviceId) -CredentialId $wugCredentialId -Assign -Confirm:$false -ErrorAction Stop | Out-Null }
                catch { if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') { Write-Warning "  Could not assign SNMP credential to ${targetAddress}: $_" } }
                if (-not $wugDeviceIds.Contains($wugDeviceId)) { [void]$wugDeviceIds.Add($wugDeviceId) }

                foreach ($item in @($plan | Where-Object { $_.DeviceIP -eq $targetAddress })) {
                    $item.DeviceId = $wugDeviceId
                    [void]$pushPlan.Add($item)
                }
            }

            if ($pushPlan.Count -eq 0) { Write-Warning 'Nothing to push.'; continue }
            Write-Host "WUG push: syncing $($pushPlan.Count) plan item(s) ..." -ForegroundColor Cyan
            $sync = Invoke-WUGDiscoverySync -Plan $pushPlan.ToArray() -PerfPollingIntervalMinutes 5
            $group = Sync-WUGDiscoveryDeviceGroup -Name 'NetworkNeighbors-WhatsUpGoldPS' -DeviceId $wugDeviceIds.ToArray() `
                -Description 'Routers and switches managed by WhatsUpGoldPS network neighbor discovery.' -Confirm:$false
            Write-Host ''
            Write-Host 'Push complete.' -ForegroundColor Green
            Write-Host "  Devices:              $($wugDeviceIds.Count)"
            Write-Host "  Active created:       $($sync.ActiveCreated)"
            Write-Host "  Performance created:  $($sync.PerfCreated)"
            Write-Host "  Assigned:             $($sync.Assigned)"
            Write-Host "  Skipped (existing):   $($sync.Skipped)"
            Write-Host "  Attributes set:       $($sync.AttrsUpdated)"
            if ($sync.Failed) { Write-Host "  Failed:               $($sync.Failed)" -ForegroundColor Red }
            if ($group.GroupId) { Write-Host "  Group: NetworkNeighbors-WhatsUpGoldPS (ID $($group.GroupId)); added $($group.Added)." -ForegroundColor Gray }
        }
        default { Write-Warning "Unrecognised choice '$currentChoice'." }
    }
}

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU7TOHaISYx9OjcPLWfPmH90oo
# oK+ggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFI3ybIInoxiZfd3h/vHtF6Hc5C37MA0G
# CSqGSIb3DQEBAQUABIICAOeFEw3AFquGT+qBOLe/yUVpAuutCgoWBEoDrGZbIgl3
# R2a/TeSAvnvxLem9sHb6zqeVAn+hTAcXkwQtgyvdpd4iDb03tFkaZpLP3lDiM/+1
# UFqLEz2HfnUJeBXF2LVYbAQt5BDXRO9GKt0R9HhwdNoQ0+/KWRkTIF6pGGRByJYe
# /0uUl7eo2v9RzOUUDRtUS3Bz5mxkPEvhVSa4wb/DfS9yMg2FLZy1ylSOnpPrNW0E
# lxjNWOf1RmsmvgG5YFJEIb8/yhqhdUorOics8vw3GHzW0Pi35G//gAe3/NdoQ/AS
# lXrTkieQ69BOiV5cWf9LjnskH2FdvwEi4P26X4GJWFLQ1NX9v0tsnuYpvdbhBMaz
# cJctk7/sPpuim4AdIxIGFIRYzAZMCMy9LJDhoWo9yjCrGZNy0Smx01WgxERndH8O
# J3bgjCtJCC8VaH8k6Xx58YDQazI3jhuS2/FJIAhtxz2vdRjOijI+NRc3VKZH+pUo
# nOtmXiH66Bfg88t+WTfLcBQpbZb1tVcjitmPhF8skBPOeejavVvkOe8mjK2FwRtW
# u65yh00+QVOAgOhMzNkmYApCA+gvoahCmek/pmaGaBvOQ1W1Tlv6ul/7wc1YK8sm
# 140rqylxagO397oTEbKAUkasPMyJs/s/yfGy76ZYiHxGXJiI2j59Lby0g8EliUTa
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDI1NVowLwYJKoZIhvcN
# AQkEMSIEIAnD78rSdOqfMupWMRjeEAdvuB+zNlWSF5DazNGGjHXpMA0GCSqGSIb3
# DQEBAQUABIICADsScqqxtyoOAo7c4WIGVktYl4DlPT8zO2Yf+UjgNUhSZR2q8XuR
# aYeG+JKAJOMIcbOyrmtqSDd9I8ojio0r0kFXNg6Z2C745QzxV3JzW1H3Xx5D102v
# elUq57EguP/Ln4SI1U1ZmwMKMJBQ84Ith/Z3RIPM4ZKaW5b/5cw4ceAMN7So+Xry
# T2YPcQ/eHvmbxMxJpc+mskUV/zj5Y+NGdELZj42o0n/PmkLuG0q+NuNNm5Chp4if
# bK2siRoUB4ZwO1s9HoZGnIaM51yD5VuJKwhSZStGY1VkItYPuFYv/afdseWAzN9f
# nVK+gCjXWk+1hvvP5mmkXortqVPWjgWGyiQi+SpUvhkw465TxzGu0HGxUE8/03Bn
# szWh+oPFMX3EfgoYm1qDEeeBELz4p6EEDr6vt8Jv61wKymEiIFQBRJv1lDZtYXkO
# 7ooWLgLw4pG7a91/7XRdTJxMiRP6nYpcMYmlnC5YoGOe/YYDIeO7tILDujBtBFGU
# YPrA0crUVuukAy5p1Vn9DfTSOTfmvdUbr7zF7k7qVSGncfw4YxOq7oDaMoQJ1Gpp
# JtEOURJ9Z0Fw8YdPJmlEEXGgcPP4KBu3s2aje1BG7lbRPaaJups0ek2kgvfzjqKa
# I878FfMRlG8Lu4f3F/0pKg8QstLeHD1xWPRBeL7Q1klDo70kau7dPPiE
# SIG # End signature block
