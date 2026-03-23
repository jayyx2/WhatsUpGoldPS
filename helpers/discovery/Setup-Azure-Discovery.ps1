<#
.SYNOPSIS
    Azure Discovery -- Discover resources and optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers Azure resources across subscriptions,
    then lets you choose what to do:

      [1] Push monitors to WhatsUp Gold (creates devices + monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Generate Azure HTML dashboard
      [6] Exit

    Two collection methods:
      [1] Az PowerShell modules -- uses Az.Accounts, Az.Resources, etc.
      [2] REST API (direct) -- zero external dependencies, uses Invoke-RestMethod

    First Run:
      1. Prompts for collection method and Tenant ID
      2. Prompts for Application ID, Client Secret
      3. Stores service principal in DPAPI vault (encrypted)
      4. Discovers resources across subscriptions
      5. Shows summary, then asks what to do

    Subsequent Runs:
      Loads service principal from vault automatically.

.NOTES
    WhatsUpGoldPS module is only needed if you choose option [1] (push to WUG).
    REST API mode has zero external module dependencies.
    Az module mode requires: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Monitor.
#>

# --- Configuration -----------------------------------------------------------
$WUGServer = '192.168.74.74'             # Default WhatsUp Gold server

# --- Collection method choice -------------------------------------------------
Write-Host ""
Write-Host "Azure data collection method:" -ForegroundColor Cyan
Write-Host "  [1] Az PowerShell modules (requires Az.Accounts, Az.Resources, etc.)" -ForegroundColor White
Write-Host "  [2] REST API direct (zero external dependencies)" -ForegroundColor White
Write-Host ""
$methodChoice = Read-Host -Prompt "Choice [1/2, default: 2]"
$UseRestApi = ($methodChoice -ne '1')

if ($UseRestApi) {
    Write-Host "Using REST API mode (no Az modules needed)." -ForegroundColor Green
}
else {
    Write-Host "Using Az PowerShell module mode." -ForegroundColor Green

    # --- Check for required Az sub-modules --------------------------------
    $requiredAzModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.Monitor')
    $missingModules = @($requiredAzModules | Where-Object { -not (Get-Module -ListAvailable -Name $_ -ErrorAction SilentlyContinue) })
    if ($missingModules.Count -gt 0) {
        Write-Warning "Required Az modules not found: $($missingModules -join ', ')"
        Write-Host "  Install with:" -ForegroundColor Yellow
        foreach ($mod in $missingModules) {
            Write-Host "    Install-Module -Name $mod -Scope CurrentUser -Force" -ForegroundColor Yellow
        }
        Write-Host ""
        $installChoice = Read-Host -Prompt "Attempt to install missing modules now? [y/N]"
        if ($installChoice -eq 'y' -or $installChoice -eq 'Y') {
            foreach ($mod in $missingModules) {
                try {
                    Write-Host "  Installing $mod..." -ForegroundColor Cyan
                    Install-Module -Name $mod -Scope CurrentUser -Force -ErrorAction Stop
                    Write-Host "  $mod installed." -ForegroundColor Green
                }
                catch {
                    Write-Error "Failed to install ${mod}: $_"
                    return
                }
            }
            Write-Host "All required Az modules installed successfully." -ForegroundColor Green
        }
        else {
            Write-Host "Cannot proceed without required Az modules. Exiting." -ForegroundColor Red
            return
        }
    }

    # --- Pre-load required Az sub-modules to avoid version mismatch -------
    # IMPORTANT: Never use 'Import-Module Az' -- it loads all ~70 sub-modules
    # and will fail on broken ones. Only import the specific ones we need.
    $loadedAccounts = Get-Module -Name Az.Accounts
    $latestAccounts = Get-Module -ListAvailable -Name Az.Accounts |
        Sort-Object Version -Descending | Select-Object -First 1

    if ($loadedAccounts -and $latestAccounts -and $loadedAccounts.Version -lt $latestAccounts.Version) {
        Write-Warning "Az.Accounts $($loadedAccounts.Version) is loaded but $($latestAccounts.Version) is available."
        Write-Warning "Stale Az module assemblies in this session may cause errors."
        Write-Warning "Please close this PowerShell window and re-run in a fresh session."
        return
    }

    foreach ($azMod in $requiredAzModules) {
        if (-not (Get-Module -Name $azMod)) {
            $latest = Get-Module -ListAvailable -Name $azMod |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($latest) {
                try {
                    Import-Module $azMod -RequiredVersion $latest.Version -ErrorAction Stop
                    Write-Verbose "Loaded $azMod $($latest.Version)"
                }
                catch {
                    Write-Warning "Could not load ${azMod}: $($_.Exception.Message)"
                }
            }
        }
    }
}

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Azure.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Azure Discovery ===" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 2: Service Principal Credentials (DPAPI vault)
# ==============================================================================
Write-Host ""
$tenantInput = Read-Host -Prompt "Azure Tenant ID"
if ([string]::IsNullOrWhiteSpace($tenantInput)) {
    Write-Error 'Tenant ID is required. Exiting.'
    return
}
$TenantId = $tenantInput.Trim()

$AzureCred = Resolve-DiscoveryCredential -Name "Azure.$TenantId.ServicePrincipal" -CredType AzureSP -ProviderLabel 'Azure'
if (-not $AzureCred) {
    Write-Error 'No Azure credentials. Exiting.'
    return
}

# --- Prompt for subscription filter (optional) --------------------------------
Write-Host ""
$subInput = Read-Host -Prompt "Filter to subscription ID or name? (blank = all subscriptions)"
$SubscriptionFilter = if ([string]::IsNullOrWhiteSpace($subInput)) { $TenantId } else { $subInput.Trim() }

# ==============================================================================
# STEP 3: Discover — authenticate and enumerate Azure resources
# ==============================================================================
Write-Host ""
Write-Host "Authenticating to Azure tenant $TenantId..." -ForegroundColor Cyan

$bstrAz = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzureCred.Password)
try { $plainAzSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrAz) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrAz) }
$azParts = $AzureCred.UserName -split '\|'
$plan = Invoke-Discovery -ProviderName 'Azure' `
    -Target @($SubscriptionFilter) `
    -Credential @{ TenantId = $azParts[0]; ApplicationId = $azParts[1]; ClientSecret = $plainAzSecret; UseRestApi = $UseRestApi }

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check service principal permissions and connectivity."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $resName = $item.Attributes['Azure.ResourceName']
    $key = "resource:$($item.Attributes['Azure.SubscriptionId']):$resName"

    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name     = $resName
            IP       = $item.Attributes['Azure.IPAddress']
            Type     = $item.Attributes['Azure.DeviceType']
            Location = $item.Attributes['Azure.Location']
            Sub      = $item.Attributes['Azure.Subscription']
            RG       = $item.Attributes['Azure.ResourceGroup']
            State    = $item.Attributes['Azure.State']
            Attrs    = $item.Attributes
            Items    = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$withIP    = @($devicePlan.Values | Where-Object { $_.IP })
$withoutIP = @($devicePlan.Values | Where-Object { -not $_.IP })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } |
    Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
    Select-Object -ExpandProperty Name -Unique)

$uniqueSubs = @($devicePlan.Values | ForEach-Object { $_.Sub } | Select-Object -Unique)
$uniqueRGs  = @($devicePlan.Values | ForEach-Object { $_.RG } | Select-Object -Unique)
$uniqueLocs = @($devicePlan.Values | ForEach-Object { $_.Location } | Select-Object -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Resources:             $($devicePlan.Count)" -ForegroundColor White
Write-Host "  Resources (with IP):   $($withIP.Count)" -ForegroundColor White
Write-Host "  Resources (no IP):     $($withoutIP.Count)" -ForegroundColor White
Write-Host "  Subscriptions:         $($uniqueSubs.Count)" -ForegroundColor White
Write-Host "  Resource Groups:       $($uniqueRGs.Count)" -ForegroundColor White
Write-Host "  Locations:             $($uniqueLocs.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    Select-Object -First 50 |
    ForEach-Object { [PSCustomObject]@{
        Resource = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { 'N/A' }
        Location = $_.Location
        State    = $_.State
        Monitors = $_.Items.Count
    }} |
    Format-Table -AutoSize

if ($devicePlan.Count -gt 50) {
    Write-Host "  ... and $($devicePlan.Count - 50) more resources (use option [4] to see all)" -ForegroundColor Gray
}

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================
Write-Host "What would you like to do?" -ForegroundColor Cyan
Write-Host "  [1] Push monitors to WhatsUp Gold (creates devices + monitors)"
Write-Host "  [2] Export plan to JSON file"
Write-Host "  [3] Export plan to CSV file"
Write-Host "  [4] Show full plan table"
Write-Host "  [5] Generate Azure HTML dashboard"
Write-Host "  [6] Exit (do nothing)"
Write-Host ""
$choice = Read-Host -Prompt "Choice [1-6]"

switch ($choice) {
    '1' {
        Write-Host ""
        $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
        if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
            $WUGServer = $wugInput.Trim()
        }

        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            Import-Module WhatsUpGoldPS -ErrorAction Stop
        }
        catch {
            Write-Error "Could not load WhatsUpGoldPS module. Is it installed? $_"
            return
        }

        $wugCred = Get-Credential -Message "WhatsUp Gold admin credentials for $WUGServer"
        Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors

        Write-Host ""
        Write-Host "Creating devices in WUG..." -ForegroundColor Cyan

        $wugDeviceMap = @{}
        $devicesCreated = 0
        $devicesFound   = 0

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            $addIP = $dev.IP
            if (-not $addIP) { continue }

            $existingDevice = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.networkAddress -eq $addIP -or $_.hostName -eq $addIP -or
                        $_.displayName -eq $addIP -or $_.displayName -eq $dev.Name
                    } | Select-Object -First 1
                    if (-not $existingDevice -and $searchResults.Count -eq 1) {
                        $existingDevice = $searchResults[0]
                    }
                }
            }
            catch { Write-Verbose "Search for '$addIP' returned error: $_" }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $devicesFound++
                Write-Host "  Found: $($existingDevice.displayName) (ID: $($existingDevice.id))" -ForegroundColor Green
            }
            else {
                Write-Host "  Adding $addIP ($($dev.Name)) [$($dev.Type)]..." -ForegroundColor Yellow
                try {
                    Add-WUGDevice -IpOrName $addIP -GroupId 0 | Out-Null
                    Start-Sleep -Seconds 2
                    $newDevice = @(Get-WUGDevice -SearchValue $addIP) | Select-Object -First 1
                    if ($newDevice) {
                        $wugDeviceMap[$key] = $newDevice.id
                        $devicesCreated++
                        Write-Host "  Added: $($newDevice.displayName) (ID: $($newDevice.id))" -ForegroundColor Green
                    }
                    else { Write-Warning "Added '$addIP' but could not find it in WUG." }
                }
                catch { Write-Warning "Failed to add device '$addIP': $_" }
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing" -ForegroundColor Cyan

        Write-Host "Setting device attributes..." -ForegroundColor Cyan
        foreach ($key in @($wugDeviceMap.Keys)) {
            $devId = $wugDeviceMap[$key]
            $dev   = $devicePlan[$key]
            foreach ($attrName in $dev.Attrs.Keys) {
                try {
                    Set-WUGDeviceAttribute -DeviceId $devId -Name $attrName -Value $dev.Attrs[$attrName] | Out-Null
                }
                catch { Write-Verbose "Attribute set error for $attrName on device $devId`: $_" }
            }
        }

        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
            }
        }

        Write-Host ""
        Write-Host "Syncing monitors..." -ForegroundColor Cyan

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        Write-Host ""
        Write-Host "Sync complete!" -ForegroundColor Green
        Write-Host "  Devices in WUG:              $($wugDeviceMap.Count)" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created: $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:          $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):      $($result.Skipped)" -ForegroundColor White
        Write-Host "  Attributes set:               $($result.AttrsUpdated)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            Write-Host "  Failed:                       $($result.Failed)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Done! Monitors pushed to WhatsUp Gold." -ForegroundColor Green
    }
    '2' {
        $jsonPath = Join-Path (Get-Location) 'azure-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path (Get-Location) 'azure-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate Azure HTML Dashboard from plan data (no re-fetch)
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Building dashboard from discovery data..." -ForegroundColor Cyan

        $dashboardRows = @()
        foreach ($key in $devicePlan.Keys) {
            $dp = $devicePlan[$key]
            $a  = $dp.Attrs

            # Build CloudResourceID for display
            $shortType = ($a['Azure.ResourceType'] -split '/')[-1]
            $cloudResId = "AzureRM/$($a['Azure.Location'])/$shortType/$($a['Azure.SubscriptionId'])/$($dp.Name)"
            $azureResId = if ($a['SYS:AzureResourceID']) { $a['SYS:AzureResourceID'] } else { '' }

            $dashboardRows += [PSCustomObject]@{
                ResourceName      = $dp.Name
                ResourceType      = $dp.Type
                ProvisioningState = $dp.State
                IPAddress         = if ($dp.IP) { $dp.IP } else { 'N/A' }
                Location          = $dp.Location
                Subscription      = $dp.Sub
                ResourceGroup     = $dp.RG
                Kind              = if ($a['Azure.Kind']) { $a['Azure.Kind'] } else { 'N/A' }
                Sku               = if ($a['Azure.Sku']) { $a['Azure.Sku'] } else { 'N/A' }
                Tags              = if ($a['Azure.Tags']) { $a['Azure.Tags'] } else { '' }
                CloudResourceID   = $cloudResId
                AzureResourceID   = $azureResId
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashReportTitle = "Azure Dashboard"
            $dashTempPath = Join-Path $env:TEMP 'Azure-Dashboard.html'

            $null = Export-AzureDiscoveryDashboardHtml `
                -DashboardData $dashboardRows `
                -OutputPath $dashTempPath `
                -ReportTitle $dashReportTitle

            Write-Host ""
            Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
            $dSucceeded = @($dashboardRows | Where-Object { $_.ProvisioningState -eq 'Succeeded' }).Count
            $dOther     = $dashboardRows.Count - $dSucceeded
            Write-Host "  Resources: $($dashboardRows.Count)  |  Succeeded: $dSucceeded  |  Other: $dOther" -ForegroundColor White

            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashPath = Join-Path $nmConsolePath 'Azure-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/Azure-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                    Write-Host "  Manual copy: Copy-Item '$dashTempPath' '$wugDashPath'" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host ""
                Write-Host "WUG NmConsole directory not found locally." -ForegroundColor Yellow
                Write-Host "Copy the file to your WUG server:" -ForegroundColor Yellow
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\Azure-Dashboard.html'" -ForegroundColor Cyan
            }
        }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "Re-run anytime to discover new Azure resources." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDZ7K9zl+Qbkk7A
# jQx0B2tOaTMykXqIRWoXhR9xvXr7e6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgLqJ+RW9PJsrmvb8M8HzIwPPX7vhGuJRK
# NwAS+eJ+VOkwDQYJKoZIhvcNAQEBBQAEggIAS3RdCz6qjOUxxJESo6HvCOGHO+8u
# WDx5OiS8kv7SY0zL+uRLImFotsZO1ZOKjizBfyrYjcwKHt8/YlBR5T5QZC7F3Dvk
# B79A2HyKRS6qE5DytCzdkTUWw3ySBRGg87O/5r0WOBS2L27tVWCtN3Ch7edHrOF8
# FwvH5DwGLwS0hhKDbb9X0KGy00EAjDPKhhDDx/8mPFKRuB6f/bIyTuGuGrsTFZ/6
# KX/R0CTKQkwIAK4J8qESCOJ3l0J7Qsu5X2jfIn7/2u4zH9yE+VT6kLepQrc7Sr/P
# jEydFub8KNsOpwwg9AxMwP4qmwm0IRtvLTyMItMvmwXNDVUeaZQ/uH7W/YeXmoG/
# doOB58+59UPDhbRun5i+XpypqtGMHVm1W9W9spsXXaN/rrVoOa728uJ0z560SwAA
# 8GpCTuiGfojXKLEpVevMUROWGMEMQ1CAOptXCs9bxOOR4ngLprg/STIQYM5iBj2P
# PlqCsoL8MEt5DcQNhnNUnu8CmibYinF+oyirNqA9SVCRY8ARrqctOkcWioGhTvN5
# A2CODc6fs2DRObrvbWsSwMNLtjXvhLxJwDIJO9PrdsIHoTQlR0xZmNn2iEx8guw5
# ZsprUUN6cnSZqfEVYhFHv6ato6QoZqPod+EnAJOvQgVNRWY1somyfs1VFPnfLMki
# utVazAERDzlpems=
# SIG # End signature block
