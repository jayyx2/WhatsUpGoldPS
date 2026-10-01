<#
.SYNOPSIS
    Start-WUGDiscoveryWizard

.DESCRIPTION
    One-shot interactive setup wizard for WhatsUpGoldPS discovery providers.

    Guides you through selecting a provider, configuring targets and credentials,
    running the initial discovery, and optionally scheduling it to run
    automatically via Windows Task Scheduler.

    This is the single entry point for discovery. Install the module, run this
    command, and you are guided through everything:

      1. Select a provider (Azure, AWS, Proxmox, CiscoWLC, etc.)
      2. The provider collects targets and credentials (saved to DPAPI vault)
      3. Discovery runs and you choose an action (Dashboard, PushToWUG, etc.)
      4. Optionally schedule the provider to run daily at 2 AM (or custom)

    Credentials are saved to the DPAPI vault so scheduled runs work
    non-interactively without storing secrets in plain text.

.PARAMETER Provider
    Provider name to launch directly (skips menu).

.PARAMETER VaultScope
    Scope for DPAPI vault storage (LocalMachine or CurrentUser).
    LocalMachine allows scheduled tasks to run as SYSTEM.

.PARAMETER NonInteractive
    Run in non-interactive mode. Requires -Provider.
    Uses saved vault credentials, defaults action to Dashboard.

.EXAMPLE
    Start-WUGDiscoveryWizard

    Interactive menu: pick a provider, configure, run, and schedule.

.EXAMPLE
    Start-WUGDiscoveryWizard -Provider Azure

    Launches Azure discovery setup directly.

.EXAMPLE
    Start-WUGDiscoveryWizard -Provider CiscoWLC -VaultScope LocalMachine

    Launches CiscoWLC with LocalMachine vault for SYSTEM task support.

.NOTES
    Author  : jason@wug.ninja
    Created : 2026-07-07
    Requires: PowerShell 5.1+, WhatsUpGoldPS module
    See also: Get-WUGDiscoveryProvider

.LINK
    https://github.com/jayyx2/WhatsUpGoldPS
#>
[CmdletBinding()]
param()

function Start-WUGDiscoveryWizard {
    [CmdletBinding()]
    param(
        [ValidateSet('AWS', 'Azure', 'Bigleaf', 'Certificates', 'CiscoWLC', 'ConfigDrift', 'CUCM', 'Docker',
                     'F5', 'Fortinet', 'GCP', 'HyperV', 'Linux', 'LoadMaster', 'MSCluster', 'MSSQL',
                     'NetworkNeighbors', 'Nutanix', 'NvidiaSmi', 'OCI', 'Proxmox', 'Redfish', 'UniFi', 'VMware',
                     'WindowsAttributes', 'WindowsDiskIO')]
        [string]$Provider,

        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$VaultScope,

        [switch]$NonInteractive
    )

    $ErrorActionPreference = 'Stop'
    $scriptDir = Split-Path $PSScriptRoot -Parent
    $discoveryDir = Join-Path $scriptDir 'helpers\discovery'

    if (-not (Test-Path $discoveryDir)) {
        throw "Discovery helpers directory not found: $discoveryDir"
    }

    $providerDescriptions = @{
        AWS                = 'Amazon Web Services (EC2, RDS, ELB)'
        Azure              = 'Microsoft Azure (VMs, App Services, Databases)'
        Bigleaf            = 'Bigleaf Networks SD-WAN'
        Certificates       = 'TLS certificate expiry and trust'
        CiscoWLC           = 'Cisco Wireless LAN Controller'
        ConfigDrift        = 'Configuration drift and policy audit (SSH)'
        CUCM               = 'Cisco Unified Communications Manager'
        Docker             = 'Docker Container Hosts'
        F5                 = 'F5 BIG-IP Load Balancers'
        Fortinet           = 'FortiGate Firewalls'
        GCP                = 'Google Cloud Platform'
        HyperV             = 'Microsoft Hyper-V Virtual Machines'
        Linux              = 'Linux host compliance (SSH)'
        LoadMaster         = 'Kemp LoadMaster Load Balancers'
        NetworkNeighbors   = 'BGP, EIGRP, CDP and LLDP neighbors (SNMP)'
        MSCluster          = 'Microsoft Failover Cluster (nodes, roles, virtual IPs)'
        MSSQL              = 'Microsoft SQL Server'
        Nutanix            = 'Nutanix AHV Virtual Machines'
        NvidiaSmi          = 'NVIDIA GPU Monitoring (nvidia-smi via SSH)'
        OCI                = 'Oracle Cloud Infrastructure'
        Proxmox            = 'Proxmox VE Virtual Machines'
        Redfish            = 'Redfish BMC hardware (iLO, iDRAC, XCC, Supermicro)'
        UniFi              = 'Local UniFi Network controller'
        VMware             = 'VMware vSphere / ESXi'
        WindowsAttributes  = 'Windows Server Attributes (OS, Hardware, BIOS)'
        WindowsDiskIO      = 'Windows Disk I/O Performance Monitors'
    }

    # Scan for available providers
    $providers = @()
    $setupFiles = @(Get-ChildItem -Path $discoveryDir -Filter 'Setup-*-Discovery.ps1' -ErrorAction SilentlyContinue)
    foreach ($file in $setupFiles) {
        if ($file.BaseName -match '^Setup-(.+)-Discovery$') {
            $providers += @{
                Name     = $Matches[1]
                FileName = $file.BaseName
                FullPath = $file.FullName
            }
        }
    }
    $providers = @($providers | Sort-Object -Property Name)

    if (-not $providers -or $providers.Count -eq 0) {
        Write-Error "No discovery providers found in $discoveryDir"
        return
    }

    # ── Step 1: Select provider ──────────────────────────────────────────────
    $selectedProvider = $null

    if ($Provider) {
        $selectedProvider = $providers | Where-Object { $_.Name -eq $Provider }
        if (-not $selectedProvider) {
            Write-Error "Provider '$Provider' not found"
            return
        }
    }
    else {
        Write-Host "`n" -ForegroundColor Cyan
        Write-Host "  +================================================================+" -ForegroundColor Cyan
        Write-Host "  |  WhatsUpGoldPS Discovery Wizard                                |" -ForegroundColor Cyan
        Write-Host "  +================================================================+" -ForegroundColor Cyan
        Write-Host "`n  Select a discovery provider to configure:`n" -ForegroundColor White

        $index = 1
        foreach ($prov in $providers) {
            $desc = $providerDescriptions[$prov.Name]
            if (-not $desc) { $desc = $prov.Name }
            Write-Host "  [$($index.ToString().PadLeft(2))] $($prov.Name.PadRight(18)) - $desc" -ForegroundColor Green
            $index++
        }

        Write-Host "`n  [ 0] Exit" -ForegroundColor Yellow
        Write-Host ""

        $choice = Read-Host "  Selection"

        $choiceNum = 0
        if (-not [int]::TryParse($choice, [ref]$choiceNum) -or $choiceNum -lt 0 -or $choiceNum -ge $index) {
            Write-Host "`n  Invalid selection.`n" -ForegroundColor Red
            return
        }
        if ($choiceNum -eq 0) {
            Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow
            return
        }

        $selectedProvider = $providers[$choiceNum - 1]
    }

    $provName = $selectedProvider.Name

    # Providers that need a target (IP/hostname) for discovery
    $targetProviders = @('Certificates', 'CiscoWLC', 'ConfigDrift', 'CUCM', 'Docker', 'F5', 'Fortinet',
                         'HyperV', 'Linux', 'LoadMaster', 'MSCluster', 'MSSQL', 'NetworkNeighbors', 'Nutanix', 'NvidiaSmi',
                         'Proxmox', 'Redfish', 'UniFi', 'VMware')
    $collectedTarget = $null
    if ($provName -in $targetProviders -and -not $NonInteractive) {
        Write-Host "  Enter target IP/hostname for $provName discovery." -ForegroundColor Yellow
        Write-Host "  Separate multiple with commas (e.g. 10.0.0.1, 10.0.0.2)" -ForegroundColor DarkGray
        $targetInput = Read-Host "  Target"
        if ($targetInput) {
            $collectedTarget = @($targetInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }

    # SNMP-based providers: ask for SNMP version before running the script
    $snmpProviders = @('CUCM', 'CiscoWLC')
    $collectedSnmpVersion = $null
    if ($provName -in $snmpProviders -and -not $NonInteractive) {
        Write-Host ''
        Write-Host '  SNMP version:' -ForegroundColor Yellow
        Write-Host '    [1] SNMP v2c (community string)' -ForegroundColor Green
        Write-Host '    [2] SNMP v3  (user/auth/privacy)' -ForegroundColor Green
        Write-Host ''
        $snmpChoice = Read-Host '  Choice (default: 1)'
        if ($snmpChoice -eq '2') {
            $collectedSnmpVersion = 3
        }
        else {
            $collectedSnmpVersion = 2
        }
    }

    # ── Step 2: Run the provider ─────────────────────────────────────────────
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "  +================================================================+" -ForegroundColor Cyan
    Write-Host "  |  Setting up: $($provName.PadRight(46))|" -ForegroundColor Cyan
    Write-Host "  +================================================================+" -ForegroundColor Cyan
    Write-Host ""

    $splat = @{}
    if ($VaultScope) { $splat['VaultScope'] = $VaultScope }
    if ($NonInteractive) { $splat['NonInteractive'] = $true }
    if ($collectedTarget) { $splat['Target'] = $collectedTarget }
    if ($collectedSnmpVersion) { $splat['SnmpVersion'] = $collectedSnmpVersion }

    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $selectedProvider.FullPath @splat }
    catch { Write-Warning "Provider error: $_" }
    finally { $ErrorActionPreference = $savedEAP }

    if ($NonInteractive) { return }

    # ── Step 3: Offer to schedule ────────────────────────────────────────────
    Write-Host ""
    Write-Host "  +================================================================+" -ForegroundColor Cyan
    Write-Host "  |  Schedule Recurring Discovery                                  |" -ForegroundColor Cyan
    Write-Host "  +================================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Schedule $provName to run automatically?" -ForegroundColor White
    Write-Host "  Uses your saved vault credentials so discovery runs unattended." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1] Yes - daily at 2:00 AM (recommended)" -ForegroundColor Green
    Write-Host "  [2] Yes - custom time and frequency" -ForegroundColor Green
    Write-Host "  [3] No  - run manually when needed" -ForegroundColor Yellow
    Write-Host ""

    $schedChoice = Read-Host "  Choice (default: 3)"

    if ($schedChoice -ne '1' -and $schedChoice -ne '2') {
        Write-Host ""
        Write-Host "  No scheduled task created. Run the wizard again anytime." -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    $registerScript = Join-Path $discoveryDir 'Register-DiscoveryScheduledTask.ps1'
    if (-not (Test-Path $registerScript)) {
        Write-Warning "Register-DiscoveryScheduledTask.ps1 not found at: $registerScript"
        return
    }

    $taskSplat = @{
        Mode     = 'Provider'
        Provider = $provName
        Action   = 'Dashboard'
    }

    # Reuse target collected earlier for scheduling
    if ($collectedTarget -and $collectedTarget.Count -gt 0) {
        $taskSplat['Target'] = $collectedTarget
    }

    # Pass SNMP version as AuthMethod for SNMP-based providers
    # Register-DiscoveryScheduledTask maps SnmpV2/SnmpV3 to -SnmpVersion for CUCM/CiscoWLC
    if ($collectedSnmpVersion) {
        $taskSplat['AuthMethod'] = if ($collectedSnmpVersion -eq 3) { 'SnmpV3' } else { 'SnmpV2' }
    }

    if ($schedChoice -eq '2') {
        Write-Host ""
        Write-Host "  Frequency:" -ForegroundColor White
        Write-Host "    [1] Daily  (default)" -ForegroundColor Green
        Write-Host "    [2] Hourly" -ForegroundColor Green
        Write-Host "    [3] At startup" -ForegroundColor Green
        $freqChoice = Read-Host "    Choice (default: 1)"
        switch ($freqChoice) {
            '2' {
                $taskSplat['TriggerType'] = 'Hourly'
                $intervalInput = Read-Host "    Repeat every N minutes (default: 60)"
                if ($intervalInput -match '^\d+$') {
                    $taskSplat['RepeatIntervalMinutes'] = [int]$intervalInput
                }
            }
            '3' { $taskSplat['TriggerType'] = 'AtStartup' }
            default { $taskSplat['TriggerType'] = 'Daily' }
        }

        if (-not $taskSplat.ContainsKey('TriggerType') -or $taskSplat['TriggerType'] -ne 'AtStartup') {
            $timeInput = Read-Host "    Time of day HH:mm (default: 02:00)"
            if ($timeInput -match '^\d{1,2}:\d{2}$') {
                $taskSplat['TimeOfDay'] = $timeInput
            }
        }

        Write-Host ""
        Write-Host "  Action on each run:" -ForegroundColor White
        Write-Host "    [1] Dashboard        - generate HTML dashboard (default)" -ForegroundColor Green
        Write-Host "    [2] PushToWUG        - push devices/monitors to WhatsUp Gold" -ForegroundColor Green
        Write-Host "    [3] DashboardAndPush - both" -ForegroundColor Green
        Write-Host "    [4] ExportJSON       - export plan to JSON" -ForegroundColor Green
        $actChoice = Read-Host "    Choice (default: 1)"
        switch ($actChoice) {
            '2' { $taskSplat['Action'] = 'PushToWUG' }
            '3' { $taskSplat['Action'] = 'DashboardAndPush' }
            '4' { $taskSplat['Action'] = 'ExportJSON' }
            default { $taskSplat['Action'] = 'Dashboard' }
        }
    }

    $taskSplat['SkipVaultPopulate'] = $true
    $taskSplat['ExecutionPolicy'] = 'RemoteSigned'
    # Note: we do NOT set UseSystemVault. The task runs as the current user
    # so it can access the same CurrentUser DPAPI vault where credentials
    # were just saved during the interactive provider run above.

    # Build the manual command string with full absolute path
    $registerScriptFull = (Resolve-Path $registerScript -ErrorAction SilentlyContinue).Path
    if (-not $registerScriptFull) { $registerScriptFull = $registerScript }
    $manualCmd = "& '$registerScriptFull' -Mode Provider -Provider $provName -Action $($taskSplat['Action']) -ExecutionPolicy RemoteSigned -SkipVaultPopulate"
    if ($collectedTarget -and $collectedTarget.Count -gt 0) {
        $targetStr = ($collectedTarget | ForEach-Object { "'$_'" }) -join ','
        $manualCmd += " -Target $targetStr"
    }
    if ($taskSplat.ContainsKey('TriggerType'))     { $manualCmd += " -TriggerType $($taskSplat['TriggerType'])" }
    if ($taskSplat.ContainsKey('TimeOfDay'))        { $manualCmd += " -TimeOfDay '$($taskSplat['TimeOfDay'])'" }

    Write-Host ""
    Write-Host "  Registering scheduled task..." -ForegroundColor Cyan

    $savedEAP2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $registerScript @taskSplat
    $ErrorActionPreference = $savedEAP2

    # Verify the task actually exists
    $taskName = "DiscoverySync-$provName"
    $taskExists = $false
    try {
        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\WhatsUpGoldPS\' -ErrorAction SilentlyContinue
        if ($existingTask) { $taskExists = $true }
    }
    catch { }

    Write-Host ""
    if ($taskExists) {
        Write-Host "  $provName discovery is now scheduled." -ForegroundColor Green
        Write-Host "  View tasks:   Get-ScheduledTask -TaskPath '\WhatsUpGoldPS\'" -ForegroundColor DarkGray
        Write-Host "  Remove task:  & '$registerScriptFull' -Remove '$taskName'" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Re-register (elevated):" -ForegroundColor DarkGray
        Write-Host "  $manualCmd" -ForegroundColor White
    }
    else {
        Write-Host "  Task registration failed (may require Administrator)." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Run this command in an elevated (Administrator) PowerShell:" -ForegroundColor Yellow
        Write-Host "  $manualCmd" -ForegroundColor White
    }

    Write-Host ""

} # End of function Start-WUGDiscoveryWizard
# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUJ7nl977UIOwPjPfiBfjPV4np
# nVyggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFMSjpIv7CoYHt1AXnb1e923SVOsaMA0G
# CSqGSIb3DQEBAQUABIICAFTAqc3X/+2rDom6wDDWunowF66k+xWfURE0sdRJhlTp
# K98tAaNBbq1H1wtUDnoxUrTxCeYb9Td5aB5LTmieJx6CJF6HY8lZUgsFVVuf6M4x
# ZljmJ0+x4WxXJ1o51nN98SwtPFxyI3cKjezB4r2NUBB6OjYRg+fZZTYbuwKWQtMh
# wnqhPWo0ikmbUCSMsb8tIT+r71R+DW28cf02RbYzlWiqpGwBJ6Txo5NTGiMjThiG
# DuNyFx1Nt2FnLK8q5u/RQnhVHlRhPb1yIPmK4fy9NdcyHCbALfYse7aS2iTqP5gF
# Ax0I+FrBaCnyWvtAk5SoyNZlNRXjw7jHidLMEnOc7VLvqdDYVvJfjiE0OaKUaE9j
# bjKznMiuI0ihX+uQlPi85q1xXy3rgqxMPHdWV1oiaB85Yw5lHc9EJy9bx5DpwR0A
# hICnadW+R0GahSycZHc2vSlSGBgKf3YpAyXKLf5PxILIgmCvVq1cbwtUqZNtEpTZ
# cQbW/i5jN2FzYvqCujxQlKa7BNqjJCnzkqsKp1PVvEiM1rJK3aQqY7JHJcMgW5I8
# 87dOppA647vXKOsoCNcZXRYd+0QGrM911ynSOX8o/8+nSix4cqkslpQODN8N48Mc
# K0XtqlNgTt3alYxaHqCLROXn/xW/Gv91mpC0AdplZub62TBwMQoSmRHeDCPTCYp0
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDE0NlowLwYJKoZIhvcN
# AQkEMSIEIAZu7jdP+2bHIoVsoTtiWadXKqCVtzcn7iEh32MoCnekMA0GCSqGSIb3
# DQEBAQUABIICAJUPTVWOYbJV01qHMVyumscTBiYpHQIUDe8kDJozkGQxl52WHsBx
# TT8oQEzmJI5fvPjRJELoZ5PbbgajQLYruvB5ZeCscqL2lfLJ3PBphADEUq0kxkz7
# aAmosRc+ayDU73ZtR0++iCm+jy4gTbQRVIP0KqSk2U0McehYfcuMdeTIYVIrWPPg
# UEdb5EHMKYlBUvnGIyj1K3R2SS32dO7i/H5pnk0k5e0mnSo9H3VU9lEFbzrIN8iZ
# oea0XAL5FQ/D+B/Uu6EVcz0Jb8BETsiybKdJ6qCiLWvRISkqxVrQ+RHO+mOPFIoi
# dJU5yTNZ8DyYJElzcpf/81h+4DCHZ3Mmba5qm1sk6ii1D31DbDqrgTtWYvlGZckk
# BgvRF3xLqZeZ714aZ+bHqhvITwovepPikN0tzSygW/4s0OLfW2nlUrM+J+zX6pNL
# JQbmLb/lbFJRxsN6NnA+oDozfQVoMaCV7CibRoNnmSdOikbmFTEw1nH6f/cg/jH0
# ZSndwUB2uKpM9GdV/N5QmJwNpN+Kcep9Ev/7ge9FLtq+oa0WjpPjxrciqB66qRAZ
# sjAbXDQUOCoj5X6esrk29B+GgndbjmtNtoRr8Q+qkG6Mzfupqq/yVULwA2vGo0nc
# WhKby12bb6j7ypuJ1h95O7ygk/ytsKi7HZETslRPBlRGQNK9zpm4+L88
# SIG # End signature block
