<#
.SYNOPSIS
    Discovers BGP, EIGRP, CDP, and LLDP neighbors over SNMP and plans WUG monitors.

.DESCRIPTION
    Wraps the protocol helpers in helpers\bgp, helpers\eigrp, helpers\cdp, and
    helpers\lldp. Each target is walked once per enabled protocol; the results are
    returned as discovery items plus inventory rows for the neighbor dashboard.

    Monitor plan:
      - One shared SNMP Table active monitor per protocol (adjacency/neighbor rows).
      - BGP: per-peer SNMP active monitor (state = established) plus state and
        established-time performance monitors.
      - EIGRP: per-neighbor hold time, SRTT, RTO, retransmission, and retry
        performance monitors.

    Context options (ctx.Options):
      Community, SnmpVersion (V1|V2), SnmpPort, SnmpTimeoutMs,
      Protocols (subset of BGP, EIGRP, CDP, LLDP),
      SshCredential (PSCredential, optional), SshPort, SshTimeoutSeconds
#>

$script:NeighborProviderRoot = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent

foreach ($neighborHelper in @(
        'bgp\Get-BgpPeerInventory.ps1', 'bgp\New-BgpMonitorPlan.ps1',
        'eigrp\Get-EigrpNeighborInventory.ps1', 'eigrp\New-EigrpMonitorPlan.ps1',
        'cdp\Get-CdpNeighborInventory.ps1', 'cdp\New-CdpMonitorPlan.ps1',
        'lldp\Get-LldpNeighborInventory.ps1', 'lldp\New-LldpMonitorPlan.ps1')) {
    $neighborHelperPath = Join-Path $script:NeighborProviderRoot $neighborHelper
    if (-not (Test-Path -LiteralPath $neighborHelperPath)) { throw "Network neighbor helper not found: $neighborHelperPath" }
    . $neighborHelperPath
}

if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $helpersPath = Join-Path $PSScriptRoot 'DiscoveryHelpers.ps1'
    if (-not (Test-Path $helpersPath)) { throw 'DiscoveryHelpers.ps1 is required.' }
    . $helpersPath
}

function ConvertTo-NeighborDiscoveredItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$PlanEntry,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][string]$TargetAddress,
        [Parameter(Mandatory = $true)][int]$DeviceId
    )

    $tags = @($PlanEntry.Tags)
    if ($PlanEntry.Type -eq 'SNMPTable') {
        # Shared name: the SNMP table monitor discovers rows per device, so one library entry serves all devices.
        $name = "Neighbors - $Protocol Neighbor Table"
        return (New-DiscoveredItem -Name $name -ItemType 'ActiveMonitor' -MonitorType 'SNMPTable' `
            -MonitorParams $PlanEntry.Parameters -UniqueKey "Neighbors:${Protocol}:table" `
            -DeviceId $DeviceId -Tags $tags)
    }

    $metric = (($PlanEntry.Name -replace '\s*\[[^\]]*\]', '') -replace "^$Protocol\s+", '').Trim()
    $peerLabel = if ($PlanEntry.Name -match '\[([^\]]+)\]') { $Matches[1] } else { $PlanEntry.Instance }
    return (New-DiscoveredItem -Name "Neighbors - $Protocol $metric - $peerLabel - $TargetAddress" `
        -ItemType 'PerformanceMonitor' -MonitorType 'Snmp' `
        -MonitorParams @{ SnmpOID = [string]$PlanEntry.Oid; SnmpInstance = [string]$PlanEntry.Instance } `
        -UniqueKey "Neighbors:${TargetAddress}:${Protocol}:$($PlanEntry.Instance):$metric" `
        -DeviceId $DeviceId -Tags $tags)
}

Register-DiscoveryProvider -Name 'NetworkNeighbors' `
    -MatchAttribute 'DiscoveryHelper.NetworkNeighbors' `
    -AuthType 'BasicAuth' `
    -DefaultPort 161 `
    -DefaultProtocol 'snmp' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $options = if ($ctx.Options) { $ctx.Options } else { @{} }
        $community = if ($options.Community) { [string]$options.Community } else { 'public' }
        $snmpVersion = if ($options.SnmpVersion -eq 'V1') { 'V1' } else { 'V2' }
        $snmpPort = if ($options.SnmpPort) { [int]$options.SnmpPort } else { 161 }
        $timeoutMs = if ($options.SnmpTimeoutMs) { [int]$options.SnmpTimeoutMs } else { 5000 }
        $protocols = if ($options.Protocols) { @($options.Protocols) } else { @('BGP', 'EIGRP', 'CDP', 'LLDP') }
        $target = [string]$ctx.DeviceIP
        $deviceId = [int]$ctx.DeviceId
        $snmpSplat = @{ Target = $target; Community = $community; SnmpVersion = $snmpVersion; Port = $snmpPort; Timeout = $timeoutMs }

        $items = New-Object 'System.Collections.Generic.List[object]'
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $counts = [ordered]@{}

        foreach ($protocol in $protocols) {
            Write-Host "Neighbors: walking $protocol on $target ..." -ForegroundColor Cyan
            $inventory = @()
            $plan = @()
            try {
                switch ($protocol) {
                    'BGP' {
                        $inventory = @(Get-BgpPeerInventory @snmpSplat)
                        $plan = @(New-BgpMonitorPlan -DeviceId $deviceId -DeviceName $target -Peers $inventory)
                    }
                    'EIGRP' {
                        $inventory = @(Get-EigrpNeighborInventory @snmpSplat)
                        $plan = @(New-EigrpMonitorPlan -DeviceId $deviceId -DeviceName $target -Neighbors $inventory)
                    }
                    'CDP' {
                        $inventory = @(Get-CdpNeighborInventory @snmpSplat)
                        $plan = @(New-CdpMonitorPlan -DeviceId $deviceId -DeviceName $target)
                    }
                    'LLDP' {
                        $inventory = @(Get-LldpNeighborInventory @snmpSplat)
                        $plan = @(New-LldpMonitorPlan -DeviceId $deviceId -DeviceName $target)
                    }
                    default { Write-Warning "Unknown neighbor protocol '$protocol'; skipping."; continue }
                }
            }
            catch {
                Write-Warning "Neighbors: $protocol walk failed on ${target}: $($_.Exception.Message)"
                $counts[$protocol] = 'error'
                continue
            }

            $counts[$protocol] = $inventory.Count
            Write-Host "  $protocol rows: $($inventory.Count)" -ForegroundColor Gray
            foreach ($row in $inventory) {
                $row | Add-Member -NotePropertyName Protocol -NotePropertyValue $protocol -Force
                $row | Add-Member -NotePropertyName Target -NotePropertyValue $target -Force
                [void]$rows.Add($row)
            }

            # Skip monitors for protocols the device does not run; an empty table monitor would always be down.
            if ($inventory.Count -eq 0) { continue }

            foreach ($entry in $plan) {
                [void]$items.Add((ConvertTo-NeighborDiscoveredItem -PlanEntry $entry -Protocol $protocol -TargetAddress $target -DeviceId $deviceId))
            }

            if ($protocol -eq 'BGP') {
                $oidMap = Get-BgpOidMap
                foreach ($peer in $inventory) {
                    [void]$items.Add((New-DiscoveredItem -Name "Neighbors - BGP Peer Established - $($peer.PeerAddress) - $target" `
                        -ItemType 'ActiveMonitor' -MonitorType 'SNMP' `
                        -MonitorParams @{ SnmpOID = "$($oidMap.PeerTable).$($oidMap.State)"; SnmpInstance = [string]$peer.Index; SnmpCheckType = 'constant'; SnmpValue = 6 } `
                        -UniqueKey "Neighbors:${target}:BGP:$($peer.Index):established" `
                        -DeviceId $deviceId -Tags @('bgp', 'snmp', 'peer', 'availability')))
                }
            }
        }

        $sshCredential = $options.SshCredential
        if ($sshCredential) {
            $sshSplat = @{ Target = $target; Username = $sshCredential.UserName; SecurePassword = $sshCredential.Password }
            if ($options.SshPort) { $sshSplat['Port'] = [int]$options.SshPort }
            if ($options.SshTimeoutSeconds) { $sshSplat['TimeoutSeconds'] = [int]$options.SshTimeoutSeconds }
            foreach ($protocol in $protocols) {
                $sshScript = switch ($protocol) {
                    'BGP' { 'bgp\Get-BgpSshInventory.ps1' }
                    'EIGRP' { 'eigrp\Get-EigrpSshInventory.ps1' }
                    'CDP' { 'cdp\Get-CdpSshInventory.ps1' }
                    'LLDP' { 'lldp\Get-LldpSshInventory.ps1' }
                }
                if (-not $sshScript) { continue }
                try {
                    . (Join-Path $script:NeighborProviderRoot $sshScript)
                    $sshRows = switch ($protocol) {
                        'BGP' { @(Get-BgpSshInventory @sshSplat) }
                        'EIGRP' { @(Get-EigrpSshInventory @sshSplat) }
                        'CDP' { @(Get-CdpSshInventory @sshSplat) }
                        'LLDP' { @(Get-LldpSshInventory @sshSplat) }
                    }
                    foreach ($row in $sshRows) {
                        $row | Add-Member -NotePropertyName Protocol -NotePropertyValue $protocol -Force
                        [void]$rows.Add($row)
                    }
                    Write-Host "  $protocol SSH rows: $(@($sshRows).Count)" -ForegroundColor Gray
                }
                catch {
                    Write-Warning "Neighbors: $protocol SSH collection failed on ${target}: $($_.Exception.Message)"
                }
            }
        }

        $summary = ($counts.Keys | ForEach-Object { "$_=$($counts[$_])" }) -join '; '
        $attributes = @{
            'Neighbors.LastScan'  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            'Neighbors.Protocols' = $summary
        }
        foreach ($protocol in $counts.Keys) {
            if ($counts[$protocol] -is [int]) { $attributes["Neighbors.$($protocol)Count"] = [string]$counts[$protocol] }
        }
        $bgpDown = @($rows | Where-Object { $_.Protocol -eq 'BGP' -and $_.Source -eq 'SNMP' -and $_.State -ne 'Established' }).Count
        if ($counts.Contains('BGP') -and $counts['BGP'] -is [int]) { $attributes['Neighbors.BGPNotEstablished'] = [string]$bgpDown }

        # Carry inventory on the first item so the setup script can build dashboards and attributes.
        if ($items.Count -eq 0) {
            $carrier = [PSCustomObject]@{ Name = "Neighbors - inventory - $target"; ItemType = 'Inventory'; MonitorType = ''; MonitorParams = @{}; UniqueKey = "Neighbors:${target}:inventory"; DeviceId = $deviceId; Attributes = $attributes; Tags = @('inventory') }
            [void]$items.Add($carrier)
        }
        else {
            $items[0].Attributes = $attributes
        }
        $items[0] | Add-Member -NotePropertyName 'NeighborRows' -NotePropertyValue $rows.ToArray() -Force
        $items[0] | Add-Member -NotePropertyName 'NeighborCounts' -NotePropertyValue $counts -Force

        Write-Host "Neighbors: $target -> $summary; $(@($items | Where-Object ItemType -ne 'Inventory').Count) monitor item(s)." -ForegroundColor Green
        return $items.ToArray()
    }

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUylSu9vOozMfGDjxVf7V6J+u6
# 1x+ggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFOBkQqka768k2OoPDhLaHynCJ8iEMA0G
# CSqGSIb3DQEBAQUABIICAGkPVp0EaNm2Xj3473MUFCxcXvaE7QUWioF7jj8ZUnOm
# IaP2M0OsMl19LyYDKPdg1dJ84g81EQNn3xsT6/FYHOMA6IJO7/XfSkFv+kaURAlp
# 6nvJfW8DTNk/LE+b64dl8Zg6HvK/p2G20NlyVUZ2CNR8XHxOpXAOpfa879ueIwcL
# Cg/mn/43tUVaXWOfydeZ9KvlwzqyBhRdIJKzuPFatbFVP6IEXOLHQX4FwEdSFuQS
# PWntQnJ8oxx0GtE6lL437oMjxVYcT0PUCmpnLMJj/HkwgieRxaWNNG8WExJ+Lq8X
# wZnHq7hHHanZ6xg+ImJ1gisICt51kbQl5l1dc3zPxIS+kLpy8BKzmXMUh8Ituj13
# rSlnvdT8Ng9EuhPNVvVtF02ZjqcRKjW7eRqVnqtdVsPd480ELmsMAj89sDlGlRqC
# e40bxUp1UdlhCwnBbuzwZngLvjkBusC5UY86ZtHoRcGfQsIw/rpAjxQylTNYE5M4
# I4BS8OpiBAvrP+EKrREF3LO1npDIiynuNcDvO71fa1+F3rOD0pZqRMNAdHKfR0v5
# FETon+rSN9EYJVNnssEJzPy1hY1SaVSDh8BRsgIU41g9UJXQV856tQRC6Gf8k0Dy
# oCFX8lM08dbDl2MMygFiFos+r5xmwfq3v40gcxyI3/NxUJbsFw920UCqIaYrX57A
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDI0MVowLwYJKoZIhvcN
# AQkEMSIEIPxpbdZErzJb6meU+k8mdlJzDkleIue0Dd6Q/Ud9L6h/MA0GCSqGSIb3
# DQEBAQUABIICADXsvoTJ2PCWI24ffpThBISrVeHmHof3i4toUO2P7c64ZzgFurTJ
# NYh6nNT6XWHNKMIcnqsORz4qS9RezKxsB1WkXETY72eDrKehDvWRC7ZIeg6l6p8n
# e41UgEagPM2K05gdUwlvOHjtywSIaxaoDJ0C9A8tGe0wD0Il4b+5EO4Hd7lywx4l
# IdraH9M24Xi47ALfOl+4yfkBp6z9/MSaVh0yhapRoXGL4tDqXfqGfE6oT49+HLK1
# Mk6avMaQ1LGqD4MZxE/913rdh6hRrIrc50vyYEMQvTjwx/SZygtv1j78ROScxB8A
# JATtaUEztHhm0s4kXAtdCU9RxM/i1MSnxio86A4COhpIdDSPGRjoNT9Eeg3f4kWE
# 2PL1S0fUuvwFGk0fe+wIaycjlXxawNRem0t41lqWKSiC5z1SWqlMLgh975L5m4QZ
# ESlDry2p9prrXZ2+Ff/M8XJhjSWIIa9QfMDWWCvoo9HJoV4lrhxlRRPrc63xZbjZ
# Sag0rsOYrIkYpcjb+7sa3n1wuZ153MOMjqM/1u6cnCOEJMZM3OKpDePDNR1Z7uQQ
# euhzsO0RmfG9X1qIfdbMTAlkkKW85knyQ1YXvNB1SXoBRy9x8htTCFvnL5IzehcV
# Y3zU36F2kk9iLGlF8TTG39Na2oA/KtkBucSV8gzXCibmI3VZfGMh2de5
# SIG # End signature block
