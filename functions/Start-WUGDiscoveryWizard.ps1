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
        [ValidateSet('AWS', 'Azure', 'Bigleaf', 'CiscoWLC', 'CUCM', 'Docker',
                     'F5', 'Fortinet', 'GCP', 'HyperV', 'LoadMaster', 'MSSQL',
                     'Nutanix', 'OCI', 'Proxmox', 'VMware', 'WindowsAttributes',
                     'WindowsDiskIO')]
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
        CiscoWLC           = 'Cisco Wireless LAN Controller'
        CUCM               = 'Cisco Unified Communications Manager'
        Docker             = 'Docker Container Hosts'
        F5                 = 'F5 BIG-IP Load Balancers'
        Fortinet           = 'FortiGate Firewalls'
        GCP                = 'Google Cloud Platform'
        HyperV             = 'Microsoft Hyper-V Virtual Machines'
        LoadMaster         = 'Kemp LoadMaster Load Balancers'
        MSSQL              = 'Microsoft SQL Server'
        Nutanix            = 'Nutanix AHV Virtual Machines'
        OCI                = 'Oracle Cloud Infrastructure'
        Proxmox            = 'Proxmox VE Virtual Machines'
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
    $targetProviders = @('CiscoWLC', 'CUCM', 'Docker', 'F5', 'Fortinet',
                         'HyperV', 'LoadMaster', 'Nutanix', 'Proxmox', 'VMware')
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

} # End of function Start-WUGDisco
# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB3Nmzh1SeD7Bom
# P+rxS2dhtI+XAw80/mWFaCTs8nkNZaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDD/q7U9aV+C2q6tnW9xVLve1dajlkjQsh2zhfQl1VEITANBgkqhkiG9w0BAQEF
# AASCAgAsa16lXJt8+DhI7v6a7W/XwVSne6LZx8V1z/gGXR0PZc83yJfkOYbuv9mE
# VDHKiaRZA/dCpjHvexaKiV0t+7JguCh/Bp5dplfJgqfbLDjw7HNyHtBLmf/Dq7OH
# U7LDUblR9OfXkpCfyhMjszk1a1CKlEiyDzr78q/L+qTakdub6LORakH+zjwIJvwK
# O2ZCtSnD8oKZINlwqRxkUAh9w/dA6AofU8OLmEGkMl5cvwbmmMRlZEXZbfwJ2bVC
# x5R80cc4yQOhwsBWwnWwi/jTkdFc2VQKJxkx4H4V/3YZ7z/5PuI7G6II+EvErL+V
# bfcPUN6EBIN1SLvPQutwyfKzjh7hGjbRjNLZcaN2hBw8+2RTdmtwDArrPvWQbABX
# JJaxrMMfi0REbgR4bk1RflBV87JPaMubap4+ZAeyPRf4jALfA0elg1You5e5g4bM
# y5oHmi5jHhRQu4dJaQDPLkksYVzRIAHgGL51oVVsBJMsLGA25xIRfw5UM//Uir5m
# j8dmgdaBsWyFkz+H0M/xeSoSphbMzC+k6Zc1boenAA4kv45rnA3ZTq+o6I6E9FXu
# 2vDTsbLPoxhi8EZ//51bpHCubPOFfdE7E0Z4FyIKcRml1euV4VIOHlmKcYgV5rTZ
# vAAOcgYkFqIh9lJUsgV36pBroNJv5eoDCfKsEsO7eDuvaoviQqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MTMyMzM3MTdaMC8GCSqGSIb3DQEJBDEiBCCBfXOU
# hIrmuag69KfNtc0ZsFS70Hh2qhBl4S8u1lRCKjANBgkqhkiG9w0BAQEFAASCAgBm
# u1HsAHTdx1HLi/rHSmLfCZ+kEKW0F79+47p4bZ0G2Nbt8SS3JJu9GIi9yWUYZCod
# AMRHeBlxYPyQM+EhtkW1GxjKoVVH6fJplPvrIDkULlul0aPgWcv9uZu8Mg8KdeCg
# 4pNb5NUPt6cY9T/uWolQCMpPaNS1xMIyKE7Bp8MjVLMmNTbmtHiGvkyGWC60bI52
# kwgwDRVV4h0xmnJ7xZZPUxchwIMMQ+yVV6KQoBHwin5XekNN8RVYanpjXditgj1X
# +nb1oWNEYRlyu/5RMdnMTyMcLfxScOWgeb9RiVqwzI9i2Fb5pgcb6SxRuRPfR507
# +4lvLt1RO+qdVGh4q2CXdjTRQt+f6otGSohHgNJOOKxFx1eQLHp9zgrF4AfWmwI7
# TQUfHZDvG0fQZmHPMmJan0MSBxLjhL1WVH3sapaoPyFFc0sgR9EZP+j1SYLi3otR
# Hw5OscGK7R/w9LJq/IpCQu8T/mJPY+XWfXNqwlJAWbjMHnKaatfQ9y5mznlFNGYy
# /zf1dX/BLDmIJXILDCZFrR/IXgXvge3OgWO4wCZhRH9pxg+yyk4p78k9Fd39jv7D
# tTPNNPcuJBGGPOGrIviZSzpJNV1d7Bg3b/n1LGBAtdcpWPyChhmqpplYiU0sZCjy
# YQ/d4PrtMZm2FwdpLggWswnYfdK96fbi/91PbtORfw==
# SIG # End signature block
