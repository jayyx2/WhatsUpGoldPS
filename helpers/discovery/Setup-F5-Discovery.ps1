<#
.SYNOPSIS
    F5 BIG-IP Discovery — Interactive dashboard, export, or WUG push.

.DESCRIPTION
    Discovers F5 BIG-IP virtual servers, pools, and system health
    endpoints via iControl REST API.

    Actions:
      PushToWUG   Full WUG automation — creates devices, credentials, monitors.
      ExportJSON  Export discovery plan to JSON.
      ExportCSV   Export discovery plan to CSV.
      ShowTable   Print full plan table to console.
      Dashboard   Generate an interactive HTML dashboard from discovery data.
      None        Discovery only — no output action.

    Architecture (WUG push):
      [F5 Device in WUG]
          |-- "F5 VS List [F5-LB1]"               (REST API Active, 5 min)
          |-- "F5 System Info [F5-LB1]"            (REST API Active, 5 min)
          |-- "F5 Pool Health [F5-LB1]"            (REST API Active, 5 min)
          |-- "F5 Total VS Connections [F5-LB1]"   (REST API Perf, 5 min)
          |-- "F5 System CPU [F5-LB1]"             (REST API Perf, 5 min)
          |-- "F5 System Memory [F5-LB1]"          (REST API Perf, 5 min)
          '-- "F5 Pool Active Members [F5-LB1]"    (REST API Perf, 5 min)

    First Run:
      1. Prompts for F5 iControl credentials (masked input, never plaintext)
      2. Stores creds in DPAPI vault (encrypted to user + machine)
      3. Discovers endpoints and presents action menu

    Subsequent Runs:
      Fully automatic — loads creds from vault, skips prompts.

    Security:
      - Credentials are DPAPI-encrypted at rest (tied to Windows user + machine)
      - WUG REST API credential is encrypted by WUG's credential store
      - Masked input — creds never appear in plaintext on screen, history, or logs
      - Optional AES-256 double encryption via -VaultPassword

.PARAMETER Target
    F5 BIG-IP management IPs or hostnames. Accepts multiple values.
    Default: lb1.corp.local, lb2.corp.local.

.PARAMETER Action
    What to do after discovery:
      PushToWUG  — Push monitors to WhatsUp Gold (creates devices + monitors)
      ExportJSON — Export plan to JSON file
      ExportCSV  — Export plan to CSV file
      ShowTable  — Show full plan table
      Dashboard  — Generate F5 HTML dashboard
      None       — Exit after discovery (do nothing)
    If omitted, shows interactive menu. If -NonInteractive and no Action,
    defaults to Dashboard.

.PARAMETER ApiPort
    F5 iControl REST API port. Default: 443.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.1.250.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER OutputPath
    Output directory for exports and dashboards.
    Non-interactive default: %LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Output.

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and parameter defaults.
    Ideal for scheduled task execution.

.EXAMPLE
    .\Setup-F5-Discovery.ps1 -Target 'lb1.corp.local' -Action Dashboard
    # Discovers F5 and generates an HTML dashboard.

.EXAMPLE
    .\Setup-F5-Discovery.ps1 -Target 'lb1.corp.local' -Action PushToWUG -NonInteractive
    # Scheduled mode — discovers F5, pushes to WUG, no prompts.

.NOTES
    No WUG module required for non-WUG actions.
    For PushToWUG: Import-Module WhatsUpGoldPS and Connect-WUGServer first.
#>
[CmdletBinding()]
param(
    [string[]]$Target = @('lb1.corp.local', 'lb2.corp.local'),

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [int]$ApiPort = 443,

    [string]$WUGServer = '192.168.1.250',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

# --- Output directory (persistent default for scheduled runs) -----------------
if (-not $OutputPath) {
    if ($NonInteractive) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Configuration (from parameters) -----------------------------------------
$F5Hosts = $Target
$F5Port  = $ApiPort

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-F5.ps1')

# Load dynamic dashboard generator
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# ==============================================================================
# STEP 1: Credential — resolve from vault or prompt
# ==============================================================================
Write-Host "=== F5 BIG-IP Discovery ===" -ForegroundColor Cyan
Write-Host "Targets: $($F5Hosts -join ', ')" -ForegroundColor Cyan
Write-Host ""

$credSplat = @{ Name = "F5.$($F5Hosts[0]).Credential"; CredType = 'PSCredential'; ProviderLabel = 'F5' }
if ($NonInteractive) { $credSplat.NonInteractive = $true }
elseif ($Action) { $credSplat.AutoUse = $true }
$F5Cred = Resolve-DiscoveryCredential @credSplat
if (-not $F5Cred) {
    Write-Error 'No F5 credentials available. Exiting.'
    return
}

# ==============================================================================
# STEP 2: Discover — query F5 iControl REST API
# ==============================================================================
Write-Host ""
Write-Host "Querying F5 at $($F5Hosts -join ', ')..." -ForegroundColor Cyan

$plan = Invoke-Discovery -ProviderName 'F5' `
    -Target $F5Hosts `
    -ApiPort $F5Port

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check F5 connectivity and credentials."
    return
}

Write-Host "Discovered $($plan.Count) items." -ForegroundColor Green

# ==============================================================================
# STEP 3: Show the plan summary
# ==============================================================================
$devicePlan = [ordered]@{}
foreach ($item in $plan) {
    $key = $item.DeviceName
    if (-not $devicePlan.ContainsKey($key)) {
        $devicePlan[$key] = @{ Name = $key; IP = $item.DeviceIP; Items = @() }
    }
    $devicePlan[$key].Items += $item
}

Write-Host ""
Write-Host "Device Plan:" -ForegroundColor White
foreach ($key in $devicePlan.Keys) {
    $dev = $devicePlan[$key]
    $activeCount = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count
    $perfCount   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count
    Write-Host "  $($dev.Name) ($($dev.IP))  Active=$activeCount  Perf=$perfCount" -ForegroundColor Cyan
}

# ==============================================================================
# STEP 4: Action menu
# ==============================================================================
$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG' { $choice = '1' }
        'ExportJSON' { $choice = '2' }
        'ExportCSV'  { $choice = '3' }
        'ShowTable'  { $choice = '4' }
        'Dashboard'  { $choice = '5' }
        'None'       { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice -and $NonInteractive) {
    $choice = '5'  # Default to Dashboard for non-interactive
}

if (-not $choice) {
    Write-Host ""
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push monitors to WhatsUp Gold (creates devices + monitors)"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate F5 HTML dashboard"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host "  [7] Dashboard + Push to WUG"
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-7]"
}

# Handle DashboardAndPush: run Dashboard then PushToWUG sequentially
if ($choice -eq '7') {
    $actionsToRun = @('5', '1')
} else {
    $actionsToRun = @($choice)
}

foreach ($currentChoice in $actionsToRun) {
switch ($currentChoice) {
    '1' {
        # ----------------------------------------------------------------
        # Push to WUG
        # ----------------------------------------------------------------
        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
            if (Test-Path $repoPsd1) { Import-Module $repoPsd1 -Force -ErrorAction Stop }
            else { Import-Module WhatsUpGoldPS -ErrorAction Stop }
        }
        catch { Write-Error "Could not load WhatsUpGoldPS module: $_"; return }
        # Dot-source internal helper so scripts can call Get-WUGAPIResponse directly
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if ($WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
        }
        else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors
        }

        Start-WUGDiscovery -ProviderName 'F5' `
            -Target $F5Hosts `
            -ApiPort $F5Port `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        Write-Host ""
        Write-Host "Done. Re-run anytime to discover new F5 items." -ForegroundColor Cyan
    }
    '2' {
        # ----------------------------------------------------------------
        # Export JSON
        # ----------------------------------------------------------------
        $jsonPath = Join-Path $OutputDir "F5-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).json"
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath
        Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
    }
    '3' {
        # ----------------------------------------------------------------
        # Export CSV
        # ----------------------------------------------------------------
        $csvPath = Join-Path $OutputDir "F5-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "CSV exported: $csvPath" -ForegroundColor Green
    }
    '4' {
        # ----------------------------------------------------------------
        # Show table
        # ----------------------------------------------------------------
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate F5 HTML Dashboard
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building F5 dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $activeItems = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })
            $perfItems   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })

            foreach ($item in ($activeItems + $perfItems)) {
                $monType = $item.Attributes['F5.MonitorType']
                if (-not $monType) { $monType = $item.Name -replace '\s*\[.*\]$', '' }

                $dashboardRows += [PSCustomObject]@{
                    Device         = $dev.Name
                    IP             = $dev.IP
                    Monitor        = $monType
                    Type           = $item.ItemType
                    Status         = 'Discovered'
                    LastDiscovery  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                }
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashPath = Join-Path $OutputDir 'F5-Dashboard.html'

            if (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
                Export-DynamicDashboardHtml -Data $dashboardRows `
                    -OutputPath $dashPath `
                    -ReportTitle 'F5 BIG-IP Discovery Dashboard' `
                    -CardField 'Device','Type' `
                    -StatusField 'Status'
            }
            elseif (Get-Command -Name 'Export-F5DashboardHtml' -ErrorAction SilentlyContinue) {
                Export-F5DashboardHtml -DashboardData $dashboardRows `
                    -OutputPath $dashPath `
                    -ReportTitle 'F5 BIG-IP Discovery Dashboard'
            }
            else {
                Write-Warning "No dashboard function available. Export as JSON instead."
                $jsonPath = Join-Path $OutputDir "F5-Plan-$(Get-Date -Format yyyyMMdd-HHmmss).json"
                $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath
                Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
                return
            }

            Write-Host ""
            Write-Host "Dashboard generated: $dashPath" -ForegroundColor Green
            Write-Host "  Devices: $($devicePlan.Count)  |  Monitors: $($dashboardRows.Count)" -ForegroundColor White

            # Try to copy to WUG NmConsole
            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugDashPath = Join-Path $wugDashDir 'F5-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/F5-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                }
                Deploy-DashboardWebConfig -Path $wugDashDir
            }
        }
    }
    '6' {
        Write-Host "Exiting — no action taken." -ForegroundColor Yellow
    }
    default {
        Write-Host "Invalid choice." -ForegroundColor Red
    }
}
} # end foreach actionsToRun

# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBVsMstnzSM4Brp
# FXe6NVkKkK61w9FrNpwz3C4djN6XsqCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAOk+Kn
# /La8iHcoDwQ/r1uaBT5447QbZN50HX2wBza5FTANBgkqhkiG9w0BAQEFAASCAgBK
# 0sW9obEbtF89ImZtrwjZXwu5CiN2yprHdx3g3VHKRuh1ThQlbmXCB4Uv98ga8+XS
# F1je/FFT3eB1ZHHBgg7N7wLqvpXBvV3eEa5l7vPd5iIW7z0hE0VWZzMzlR979DqZ
# vVsHKsmCYcSDJamSyF63/+Y4Q4yY9bRSoOs9unwzNmnHB5hMuK/5ai3eDTwfCYIo
# F0CJDaRLR2KhfqreYPoiKn3GnYVt2r6+j7z7pnJOXer/2lBIXBCJAFKp4SuiPMFN
# Ok3ePFje16XIY8NnfF2nShFOqdztXBe/J4u0eNbB85/mpGVcSo1mQQIinI4hVvJk
# fZ10IfU2uenWlIL9fmlEC/3mr74VNy4sw7sPR7usX2qpwhDqTVVEuRfaSGg3FCOG
# BCVf678AP1Ov51szTkgNv0/iEDqya7ur0cTJP3HXu2Qn5oecbe5EHqP0u21uSAi5
# 0rWj7230vWUnEn/DObc1j8kR8sGsJWtyyjSnyEzvID89xnb2wyoHWeCHeDSPsm+K
# 0a3AgCVyQA451Ns60S+xrRWRWuz7r7wdrgGzx0nx5QHNykX1ypJpNeOyCw5abcII
# G9SUtw9qXYJnQw6ePCQyqPJ9qYLVR+5m69mTNsgmfEIRvCr/JjTfePCz/UqQVJ44
# ZRc3B/RU+3xTJtczUYDaOef6u0WYVSHjA8syl6ex7aGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzExNTE0
# M1owPwYJKoZIhvcNAQkEMTIEMBZQ5puJHDKgruenKxgm3yjVSfFhqSZQfAdlj32c
# NnODiaKj8AsfCIj6H8j/hxhkpTANBgkqhkiG9w0BAQEFAASCAgAmh7lngbcqfWDN
# jWgCpxVn4C2mI5D6yGym6Dw3m7L1Ggk3tZprqnU1Ar3vKrxeExd0dzMqqcfWSgp9
# dMeukzztkCzaLjEJKAVr/q0WR5FG+VJDDIbIGTWTSbaAcd2r/vNVXSMHmYOfxlQZ
# OFxQ5X873WiuhGqr0aXkESgRDfWDy/tQoT8iXAGT5Rthl5zNY+eYY9zyMoVE9eup
# e6d8t5mLSGoEdLo3VP4dWtyOAwCul/wT5EGxvMg5CNz7D5M22DdfyKJ2v3bUSqhZ
# laNU8d+f9f0Zg/eV1sASBc7boCkiNq7pvldbvsLlTa2IIC7yF4nSbnC2CyDtLTLC
# PcBLurZlyfN5TKq4zBvu1CtvIlx1B14nPXM4PPwDyfRC6hGkRyzkE0kGwbhFiD0u
# up0ELgZRw4z6Yb7dpcuJ/koxqvMv3eTgoeaOr1zDZTdf/sbOnS83lPSGHaQMmlX6
# 2v79UOwcB7RVLHCLEhX6o7I43DdO5zM2eWsaXrm8UUDH2uvq4elSQH0AQ4GFlGTS
# mrNJZx2vHdvXmHyH3Gc+j87BvXo80vyAaUmneRn/HgleCWxfO/1D9NSCLIhKrl0u
# poYisEe/y5WzX9AgL6466ZytMWLTftw0L+h2+KSXaEoFwUOp4Q9DCrHstrMqu3pK
# VzDzDNkbZl+I2eFnWxvpE5bTV7ZxoA==
# SIG # End signature block
