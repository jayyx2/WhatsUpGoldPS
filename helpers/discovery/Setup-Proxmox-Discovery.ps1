<#
.SYNOPSIS
    Proxmox VE Discovery — Discover nodes/VMs and optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers Proxmox cluster status, node health,
    VM metrics via the Proxmox VE REST API, then lets you choose what to
    do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + REST API monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Exit

    Architecture (when pushed to WUG):
      [Proxmox Device in WUG]
          |-- "Proxmox Cluster Status"         (REST API Active Monitor)
          |-- "Proxmox Node List"              (REST API Active Monitor)
          |-- "Proxmox Node pve1 Status"       (REST API Active Monitor)
          |-- "Proxmox Node pve1 CPU"          (REST API Perf Monitor)
          |-- "Proxmox Node pve1 Memory Used"  (REST API Perf Monitor)
          |-- "Proxmox VM webserver Status"    (REST API Active Monitor)
          |-- "Proxmox VM webserver CPU"       (REST API Perf Monitor)
          |-- "Proxmox VM webserver Memory"    (REST API Perf Monitor)
          '-- ... (Net In/Out, Disk Read/Write per VM)

    First Run:
      1. Prompts for Proxmox host, port, API token (masked input)
      2. Stores token in DPAPI vault (encrypted to user + machine)
      3. Discovers nodes + VMs from Proxmox API
      4. Shows summary, then asks what to do with the results

    Subsequent Runs:
      Loads token from vault automatically — skips token prompt.

    How to create a Proxmox API Token:
      1. Proxmox GUI -> Datacenter -> Permissions -> API Tokens -> Add
      2. Select user (e.g. root@pam or dedicated monitoring user)
      3. Set Token ID (e.g. 'monitoring')
      4. UNCHECK 'Privilege Separation' for full user permissions
         OR assign PVEAuditor role for read-only access
      5. Copy the secret value (shown only once)
      6. Full token format: user@realm!tokenid=secret-uuid
         Example: root@pam!monitoring=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

.PARAMETER Target
    Proxmox host(s) — IP address or FQDN. Accepts multiple values.
    When omitted in interactive mode, prompts for input (default: 192.168.1.39).

.PARAMETER ApiPort
    Proxmox API port. Default: 8006.

.PARAMETER AuthMethod
    Authentication method: 'Token' (default) or 'Password'.
    Token is required for WUG monitor push.

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login (non-interactive WUG push).

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials and parameter defaults.
    Ideal for scheduled task execution.

.NOTES
    WhatsUpGoldPS module is only needed if you choose option [1].
    Requires Proxmox VE 6.1+ for API token support.

.EXAMPLE
    .\Setup-Proxmox-Discovery.ps1
    # Interactive mode — prompts for everything.

.EXAMPLE
    .\Setup-Proxmox-Discovery.ps1 -Target '192.168.1.39' -Action ExportJSON -NonInteractive
    # Scheduled mode — uses vault credentials, exports JSON, no prompts.

.EXAMPLE
    .\Setup-Proxmox-Discovery.ps1 -Target 'pve1.lab','pve2.lab' -Action PushToWUG -WUGServer '10.0.0.1' -WUGCredential $cred -NonInteractive
    # Scheduled mode — discovers and pushes to WUG automatically.
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [int]$ApiPort = 8006,

    [ValidateSet('Token', 'Password')]
    [string]$AuthMethod = 'Token',

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

# --- Output directory (persistent default for scheduled runs) -----------------
if (-not $OutputPath) {
    if ($NonInteractive) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Configuration -----------------------------------------------------------
$DefaultHost   = '192.168.1.39'          # Default Proxmox host (interactive fallback)
$ProxmoxPort   = $ApiPort

# --- Load helpers (works from any directory) ----------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-Proxmox.ps1')

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Proxmox VE Discovery ===" -ForegroundColor Cyan
Write-Host ""

# --- Resolve Proxmox host(s) --------------------------------------------------
if ($Target) {
    $ProxmoxHosts = @($Target)
}
elseif ($NonInteractive) {
    $ProxmoxHosts = @($DefaultHost)
}
else {
    Write-Host "Enter Proxmox host(s) — IP address or FQDN." -ForegroundColor Cyan
    Write-Host "For multiple hosts, separate with commas." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt "Proxmox host(s) [default: $DefaultHost]"
    if ([string]::IsNullOrWhiteSpace($hostInput)) {
        $hostInput = $DefaultHost
    }
    $ProxmoxHosts = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($ProxmoxHosts.Count -eq 0) {
    Write-Error 'No valid host provided. Exiting.'
    return
}
Write-Host "Targets: $($ProxmoxHosts -join ', ')" -ForegroundColor Cyan
Write-Host ""

# --- Resolve port --------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt "Proxmox API port [default: $ProxmoxPort]"
    if ($portInput -and $portInput -match '^\d+$') {
        $ProxmoxPort = [int]$portInput
    }
}

# ==============================================================================
# STEP 2: Authentication (API token OR username+password)
# ==============================================================================
$ProxmoxCredential = $null
$ProxmoxToken = $null

# Resolve auth method
$authChoice = if ($AuthMethod -eq 'Password') { '2' } else { '1' }
if (-not $PSBoundParameters.ContainsKey('AuthMethod') -and -not $NonInteractive) {
    Write-Host ""
    Write-Host "Authentication method:" -ForegroundColor Cyan
    Write-Host "  [1] API Token (recommended for WUG monitoring)" -ForegroundColor White
    Write-Host "  [2] Username + Password (standalone discovery only)" -ForegroundColor White
    Write-Host ""
    $authChoice = Read-Host -Prompt "Choice [1/2, default: 1]"
}

if ($authChoice -eq '2') {
    # Username + Password auth — vault-backed for scheduled runs
    $pwVaultName = "Proxmox.$($ProxmoxHosts[0]).Credential"
    $credSplat = @{ Name = $pwVaultName; CredType = 'PSCredential'; ProviderLabel = 'Proxmox' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    elseif ($Action) { $credSplat.AutoUse = $true }
    $psCred = Resolve-DiscoveryCredential @credSplat
    if (-not $psCred) {
        Write-Error 'No Proxmox credentials available. Exiting.'
        return
    }
    $ProxmoxCredential = @{
        Username = $psCred.UserName
        Password = $psCred.GetNetworkCredential().Password
    }
    Write-Host "Using username+password auth for discovery." -ForegroundColor Green
    Write-Host "Note: WUG monitor push (option 1) requires an API token." -ForegroundColor Yellow
}
else {
    # API Token auth (default)
    $vaultName = "Proxmox.$($ProxmoxHosts[0]).Token"
    $credSplat = @{ Name = $vaultName; CredType = 'BearerToken'; ProviderLabel = 'Proxmox' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    elseif ($Action) { $credSplat.AutoUse = $true }
    $ProxmoxToken = Resolve-DiscoveryCredential @credSplat
    if (-not $ProxmoxToken) {
        Write-Error 'No Proxmox token. Exiting.'
        return
    }
    $ProxmoxCredential = @{ ApiToken = $ProxmoxToken }
}

# ==============================================================================
# STEP 3: Discover — query Proxmox API for nodes + VMs
# ==============================================================================
Write-Host ""
Write-Host "Querying Proxmox at $($ProxmoxHosts -join ', ')..." -ForegroundColor Cyan

$plan = Invoke-Discovery -ProviderName 'Proxmox' `
    -Target $ProxmoxHosts `
    -ApiPort $ProxmoxPort `
    -Credential $ProxmoxCredential

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check Proxmox connectivity and API token."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

# Group items by target device using item Attributes
$devicePlan = [ordered]@{}  # deviceKey -> @{ Name; IP; Type; ParentNode; Attrs; Items }

foreach ($item in $plan) {
    $type = $item.Attributes['Proxmox.DeviceType']
    switch ($type) {
        'Cluster' {
            $key  = "cluster:$($item.Attributes['Proxmox.ApiHost'])"
            $name = $item.Attributes['Proxmox.ApiHost']
            $ip   = $item.Attributes['Proxmox.ApiHost']
            $parentNode = $null
        }
        'Node' {
            $nodeName = $item.Attributes['Proxmox.NodeName']
            $key  = "node:${nodeName}"
            $name = $nodeName
            $ip   = $item.Attributes['Proxmox.NodeIP']
            $parentNode = $null
        }
        'VM' {
            $vmid = $item.Attributes['Proxmox.VMID']
            $key  = "vm:${vmid}"
            $name = $item.Attributes['Proxmox.VMName']
            $ip   = $item.Attributes['Proxmox.VMIP']
            $parentNode = $item.Attributes['Proxmox.ParentNode']
        }
        default { continue }
    }
    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name       = $name
            IP         = $ip
            Type       = $type
            ParentNode = $parentNode
            Attrs      = $item.Attributes
            Items      = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$nodeDevices = @($devicePlan.Values | Where-Object { $_.Type -eq 'Node' })
$vmDevices   = @($devicePlan.Values | Where-Object { $_.Type -eq 'VM' })
$vmWithIP    = @($vmDevices | Where-Object { $_.IP })
$vmNoIP      = @($vmDevices | Where-Object { -not $_.IP })

# Count unique monitor TEMPLATES (not total items)
$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } |
    Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
    Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Nodes:                 $($nodeDevices.Count)" -ForegroundColor White
Write-Host "  VMs (with IP):         $($vmWithIP.Count)" -ForegroundColor White
Write-Host "  VMs (no IP/no agent):  $($vmNoIP.Count)" -ForegroundColor White
Write-Host "  Total WUG devices:     $($nodeDevices.Count + $vmWithIP.Count + 1) (nodes + VMs w/ IP + cluster)" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

Write-Host "Monitor templates:" -ForegroundColor Cyan
foreach ($t in $activeTemplates) { Write-Host "  [Active] $t" -ForegroundColor White }
foreach ($t in $perfTemplates)   { Write-Host "  [Perf]   $t" -ForegroundColor White }
Write-Host ""

if ($vmNoIP.Count -gt 0) {
    Write-Host "VMs without IP (guest agent needed — monitors attach to parent node):" -ForegroundColor Yellow
    foreach ($vm in $vmNoIP) {
        Write-Host "    $($vm.Name) (on $($vm.ParentNode))" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# Per-device summary table
$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    ForEach-Object { [PSCustomObject]@{
        Device   = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { '(via node)' }
        Monitors = $_.Items.Count
        Attrs    = $_.Attrs.Count
    }} |
    Format-Table -AutoSize

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================

# --- Map Action parameter to menu choice number ---
$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG' { $choice = '1' }
        'ExportJSON' { $choice = '2' }
        'ExportCSV' { $choice = '3' }
        'ShowTable' { $choice = '4' }
        'Dashboard' { $choice = '5' }
        'None' { $choice = '6' }
    }
}

if (-not $choice) {
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    if ($ProxmoxToken) {
        Write-Host "  [1] Push monitors to WhatsUp Gold (creates devices + credential + monitors)"
    }
    else {
        Write-Host "  [1] Push monitors to WhatsUp Gold (requires API token auth)" -ForegroundColor DarkGray
    }
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate Proxmox HTML dashboard (live metrics)"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-6]"
}

switch ($choice) {
    '1' {
        if (-not $ProxmoxToken) {
            Write-Warning "WUG push requires API token auth. Re-run and choose option [1] for authentication."
            return
        }
        # --- Multi-device push to WUG -----------------------------------------
        if (-not $NonInteractive) {
            Write-Host ""
            $wugInput = Read-Host -Prompt "WhatsUp Gold server [default: $WUGServer]"
            if ($wugInput -and -not [string]::IsNullOrWhiteSpace($wugInput)) {
                $WUGServer = $wugInput.Trim()
            }
        }

        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            Import-Module WhatsUpGoldPS -ErrorAction Stop
        }
        catch {
            Write-Error "Could not load WhatsUpGoldPS module. Is it installed? $_"
            return
        }

        if ($WUGCredential) {
            $wugCred = $WUGCredential
        }
        elseif ($NonInteractive) {
            $wugResolved = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -NonInteractive
            if (-not $wugResolved) {
                Write-Error 'No WUG credentials in vault. Run interactively first to cache them, or pass -WUGCredential.'
                return
            }
            $wugCred = $wugResolved.Credential
            if ($wugResolved.Server) { $WUGServer = $wugResolved.Server }
        }
        else {
            $wugCred = Get-Credential -Message "WhatsUp Gold admin credentials for $WUGServer"
        }
        Connect-WUGServer -serverUri $WUGServer -Credential $wugCred -IgnoreSSLErrors

        # ----------------------------------------------------------------
        # 5a. Create or find one shared REST API credential for Proxmox
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Setting up Proxmox REST API credential in WUG..." -ForegroundColor Cyan

        $credName = "Proxmox API Token"
        $proxCredId = $null

        # Check if credential already exists
        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName)
            if ($existingCreds.Count -gt 0) {
                $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                if ($matchCred) {
                    $proxCredId = $matchCred.id
                    Write-Host "  Found existing credential '$credName' (ID: $proxCredId)" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Verbose "Credential search error: $_"
        }

        if (-not $proxCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                $credResult = Add-WUGCredential -Name $credName -Type restapi `
                    -RestApiUsername 'api-token' `
                    -RestApiPassword $ProxmoxToken `
                    -RestApiAuthType '0'
                if ($credResult) {
                    $proxCredId = if ($credResult.PSObject.Properties['resourceId']) { $credResult.resourceId } else { $credResult.id }
                    Write-Host "  Created credential (ID: $proxCredId)" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "Failed to create credential: $_"
            }
        }

        # ----------------------------------------------------------------
        # 5b. Create/find devices in WUG
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Creating devices in WUG..." -ForegroundColor Cyan

        $wugDeviceMap = @{}  # deviceKey -> WUG device ID
        $devicesCreated = 0
        $devicesFound   = 0

        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]

            # Determine IP/hostname to add to WUG
            $addIP = $null
            if ($dev.Type -eq 'Cluster') {
                $addIP = $dev.IP
            }
            elseif ($dev.Type -eq 'Node') {
                $addIP = $dev.IP
            }
            elseif ($dev.Type -eq 'VM' -and $dev.IP) {
                $addIP = $dev.IP
            }
            else {
                # VM without IP — map to parent node later
                continue
            }

            if (-not $addIP) { continue }

            # Search WUG for existing device
            $existingDevice = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.networkAddress -eq $addIP -or
                        $_.hostName -eq $addIP -or
                        $_.displayName -eq $addIP -or
                        $_.displayName -eq $dev.Name
                    } | Select-Object -First 1
                    if (-not $existingDevice -and $searchResults.Count -eq 1) {
                        $existingDevice = $searchResults[0]
                    }
                }
            }
            catch {
                Write-Verbose "Search for '$addIP' returned error: $_"
            }

            if ($existingDevice) {
                $wugDeviceMap[$key] = $existingDevice.id
                $devicesFound++
                Write-Host "  Found: $($existingDevice.displayName) (ID: $($existingDevice.id)) [$($dev.Type)]" -ForegroundColor Green
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
                    else {
                        Write-Warning "Added '$addIP' but could not find it in WUG."
                    }
                }
                catch {
                    Write-Warning "Failed to add device '$addIP': $_"
                }
            }
        }

        # Map no-IP VMs to parent node devices
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -eq 'VM' -and -not $dev.IP -and -not $wugDeviceMap.ContainsKey($key)) {
                $parentKey = "node:$($dev.ParentNode)"
                if ($wugDeviceMap.ContainsKey($parentKey)) {
                    $wugDeviceMap[$key] = $wugDeviceMap[$parentKey]
                    Write-Host "  $($dev.Name) (VM, no IP) -> node $($dev.ParentNode)" -ForegroundColor DarkGray
                }
                else {
                    Write-Warning "No WUG device for VM '$($dev.Name)' — parent node '$($dev.ParentNode)' not found."
                }
            }
        }

        Write-Host ""
        Write-Host "Devices: $devicesCreated created, $devicesFound existing" -ForegroundColor Cyan

        # ----------------------------------------------------------------
        # 5c. Assign credential + set device attributes
        # ----------------------------------------------------------------
        Write-Host "Assigning credential and setting attributes..." -ForegroundColor Cyan

        foreach ($key in @($wugDeviceMap.Keys)) {
            $devId = $wugDeviceMap[$key]
            $dev   = $devicePlan[$key]

            # Assign the shared credential
            if ($proxCredId) {
                try {
                    Set-WUGDeviceCredential -DeviceId $devId -CredentialId $proxCredId -Assign | Out-Null
                    Write-Verbose "Credential assigned to device $devId"
                }
                catch {
                    if ($_.Exception.Message -notmatch 'already|duplicate') {
                        Write-Warning "Credential assign error for device $devId`: $_"
                    }
                }
            }

            # Set device attributes from the plan
            foreach ($attrName in $dev.Attrs.Keys) {
                try {
                    Set-WUGDeviceAttribute -DeviceId $devId -Name $attrName -Value $dev.Attrs[$attrName] | Out-Null
                }
                catch {
                    Write-Verbose "Attribute set error for $attrName on device $devId`: $_"
                }
            }
        }

        # ----------------------------------------------------------------
        # 5d. Update plan items with actual WUG device IDs and sync
        # ----------------------------------------------------------------
        foreach ($key in $devicePlan.Keys) {
            if (-not $wugDeviceMap.ContainsKey($key)) { continue }
            $wugId = $wugDeviceMap[$key]
            foreach ($item in $devicePlan[$key].Items) {
                $item.DeviceId = $wugId
            }
        }

        Write-Host ""
        Write-Host "Syncing monitors: $($activeTemplates.Count) active templates + $($perfTemplates.Count) perf templates across $($wugDeviceMap.Count) devices..." -ForegroundColor Cyan

        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds 300 `
            -PerfPollingIntervalMinutes 5

        Write-Host ""
        Write-Host "Sync complete!" -ForegroundColor Green
        Write-Host "  Devices in WUG:              $($wugDeviceMap.Count)" -ForegroundColor White
        Write-Host "  Active monitors created:      $($result.ActiveCreated)  (templates — shared across devices)" -ForegroundColor White
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
        $jsonPath = Join-Path $OutputDir 'proxmox-discovery-plan.json'
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath -IncludeParams
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        $csvPath = Join-Path $OutputDir 'proxmox-discovery-plan.csv'
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        $plan | Export-DiscoveryPlan -Format Table
    }
    '5' {
        # ----------------------------------------------------------------
        # Generate Proxmox HTML Dashboard with live metrics
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "Fetching live metrics from Proxmox..." -ForegroundColor Cyan

        # Ensure TLS 1.2 for Proxmox API (PS 5.1 defaults to TLS 1.0)
        if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }

        # Cross-version API helper -- handles Cookie properly on PS 5.1
        $dashInvokeApi = {
            param([string]$Url, [string]$HdrName, [string]$HdrVal, [string]$SkipSsl)
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $p = @{
                    Uri                  = $Url
                    Method               = 'GET'
                    Headers              = @{ $HdrName = $HdrVal }
                    SkipHeaderValidation = $true
                }
                if ($SkipSsl -eq '1') { $p.SkipCertificateCheck = $true }
                Invoke-RestMethod @p -ErrorAction Stop
            }
            else {
                if ($SkipSsl -eq '1') {
                    if (([System.Management.Automation.PSTypeName]'SSLValidator').Type) {
                        [SSLValidator]::OverrideValidation()
                    }
                    else {
                        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                    }
                }
                if ($HdrName -eq 'Cookie') {
                    # Cookie is a restricted header on PS 5.1 -- must use
                    # WebSession.Cookies, same approach as Invoke-ProxmoxAPI
                    $ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                    $parsed = [System.Uri]$Url
                    $parts = $HdrVal -split '=', 2
                    $ws.Cookies.Add((New-Object System.Net.Cookie($parts[0], $parts[1], '/', $parsed.Host)))
                    Invoke-RestMethod -Uri $Url -Method GET -WebSession $ws -ErrorAction Stop
                }
                else {
                    Invoke-RestMethod -Uri $Url -Method GET -Headers @{ $HdrName = $HdrVal } -ErrorAction Stop
                }
            }
        }

        $dashApiHost = $ProxmoxHosts[0]
        $dashBaseUri = "https://${dashApiHost}:${ProxmoxPort}"

        # Determine auth header based on method used
        if ($ProxmoxToken) {
            $dashHdrName = 'Authorization'
            $dashHdrVal  = "PVEAPIToken=$ProxmoxToken"
        }
        elseif ($ProxmoxCredential -and $ProxmoxCredential.Username -and $ProxmoxCredential.Password) {
            # Obtain a session ticket via username+password
            Write-Host "  Authenticating to Proxmox with username+password..." -ForegroundColor DarkGray
            try {
                $ticketUri  = "${dashBaseUri}/api2/json/access/ticket"
                $ticketBody = "username=$([uri]::EscapeDataString($ProxmoxCredential.Username))&password=$([uri]::EscapeDataString($ProxmoxCredential.Password))"
                $ticketSplat = @{
                    Uri         = $ticketUri
                    Method      = 'POST'
                    Body        = $ticketBody
                    ContentType = 'application/x-www-form-urlencoded'
                    ErrorAction = 'Stop'
                }
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $ticketSplat.SkipCertificateCheck = $true
                }
                else {
                    # Use compiled C# callback -- scriptblock delegates get GC'd
                    # under PS 5.1, causing "connection was closed unexpectedly"
                    if (-not ([System.Management.Automation.PSTypeName]'SSLValidator').Type) {
                        Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SSLValidator {
    private static bool OnValidateCertificate(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) {
        return true;
    }
    public static void OverrideValidation() {
        ServicePointManager.ServerCertificateValidationCallback =
            new RemoteCertificateValidationCallback(OnValidateCertificate);
        ServicePointManager.Expect100Continue = false;
        ServicePointManager.DefaultConnectionLimit = 64;
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
    }
}
"@
                    }
                    [SSLValidator]::OverrideValidation()
                }
                $ticketResp = Invoke-RestMethod @ticketSplat
                if ($ticketResp.data.ticket) {
                    $dashHdrName = 'Cookie'
                    $dashHdrVal  = "PVEAuthCookie=$($ticketResp.data.ticket)"
                    Write-Host "  Session ticket obtained." -ForegroundColor Green
                }
                else {
                    Write-Warning "Proxmox ticket response did not contain a ticket. Cannot generate dashboard."
                    return
                }
            }
            catch {
                Write-Warning "Failed to authenticate to Proxmox: $($_.Exception.Message)"
                return
            }
        }
        else {
            Write-Warning "No Proxmox credentials available. Re-run and authenticate first."
            return
        }
        $dashboardRows = @()

        # --- Fetch live node stats ---
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -ne 'Node') { continue }
            $nodeName = $dev.Name
            try {
                $resp = & $dashInvokeApi "${dashBaseUri}/api2/json/nodes/${nodeName}/status" $dashHdrName $dashHdrVal '1'
                $d = $resp.data

                $cpuPct  = '{0:N1}%' -f ($d.cpu * 100)
                $cpuInfo = "$($d.cpuinfo.sockets)s/$($d.cpuinfo.cores)c/$($d.cpuinfo.cpus)t"
                $ramUsed = [math]::Round($d.memory.used / 1MB)
                $ramTotal= [math]::Round($d.memory.total / 1MB)
                $ramPct  = if ($ramTotal -gt 0) { '{0:N1}%' -f ($ramUsed / $ramTotal * 100) } else { '0.0%' }
                $fsUsed  = [math]::Round($d.rootfs.used / 1GB)
                $fsTotal = [math]::Round($d.rootfs.total / 1GB)

                $dashboardRows += [PSCustomObject]@{
                    Type       = 'Host'
                    Name       = $nodeName
                    Status     = if ($d.uptime -gt 0) { 'running' } else { 'offline' }
                    IPAddress  = if ($dev.IP) { $dev.IP } else { 'N/A' }
                    Node       = $nodeName
                    CPU        = "$cpuPct ($cpuInfo)"
                    RAM        = "$ramPct ($ramUsed MB / $ramTotal MB)"
                    Disk       = "$fsUsed GB / $fsTotal GB"
                    NetworkIn  = 'N/A'
                    NetworkOut = 'N/A'
                    Uptime     = "$($d.uptime)"
                    Tags       = 'N/A'
                    HAState    = 'N/A'
                }
                Write-Host "  Node: $nodeName" -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "Could not fetch status for node $nodeName"
                $dashboardRows += [PSCustomObject]@{
                    Type = 'Host'; Name = $nodeName; Status = 'unknown'
                    IPAddress = if ($dev.IP) { $dev.IP } else { 'N/A' }
                    Node = $nodeName; CPU = 'N/A'; RAM = 'N/A'; Disk = 'N/A'
                    NetworkIn = 'N/A'; NetworkOut = 'N/A'; Uptime = 'N/A'
                    Tags = 'N/A'; HAState = 'N/A'
                }
            }
        }

        # --- Fetch live VM stats ---
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -ne 'VM') { continue }
            $vmid   = $dev.Attrs['Proxmox.VMID']
            $vmNode = $dev.ParentNode
            try {
                $resp = & $dashInvokeApi "${dashBaseUri}/api2/json/nodes/${vmNode}/qemu/${vmid}/status/current" $dashHdrName $dashHdrVal '1'
                $d = $resp.data

                # Also fetch config for socket/core counts
                $cfgResp = $null
                try { $cfgResp = & $dashInvokeApi "${dashBaseUri}/api2/json/nodes/${vmNode}/qemu/${vmid}/config" $dashHdrName $dashHdrVal '1' } catch {}
                $sockets = if ($cfgResp -and $cfgResp.data.sockets) { $cfgResp.data.sockets } else { '1' }
                $cores   = if ($cfgResp -and $cfgResp.data.cores) { $cfgResp.data.cores } else { $d.cpus }

                $cpuPct   = '{0:N1}%' -f ($d.cpu * 100)
                $ramUsed  = [math]::Round($d.mem / 1MB)
                $ramTotal = [math]::Round($d.maxmem / 1MB)
                $ramPct   = if ($ramTotal -gt 0) { '{0:N1}%' -f ($ramUsed / $ramTotal * 100) } else { '0.0%' }
                $diskTot  = '{0} MB' -f [math]::Round($d.maxdisk / 1MB)
                $netInKB  = '{0} KB' -f [math]::Round($d.netin / 1KB)
                $netOutKB = '{0} KB' -f [math]::Round($d.netout / 1KB)
                $tags     = if ($d.tags) { "$($d.tags)" } else { 'N/A' }
                $haState  = if ($d.ha -and $d.ha.managed) { "$($d.ha.managed)" } else { 'N/A' }

                $dashboardRows += [PSCustomObject]@{
                    Type       = "VM ($vmid)"
                    Name       = $dev.Name
                    Status     = $d.status
                    IPAddress  = if ($dev.IP) { $dev.IP } else { 'N/A' }
                    Node       = $vmNode
                    CPU        = "$cpuPct (${sockets}s/${cores}c)"
                    RAM        = "$ramPct ($ramUsed MB / $ramTotal MB)"
                    Disk       = $diskTot
                    NetworkIn  = $netInKB
                    NetworkOut = $netOutKB
                    Uptime     = "$($d.uptime)"
                    Tags       = $tags
                    HAState    = $haState
                }
                Write-Host "  VM: $($dev.Name)" -ForegroundColor DarkGray
            }
            catch {
                $dashboardRows += [PSCustomObject]@{
                    Type = "VM ($vmid)"; Name = $dev.Name
                    Status = if ($dev.Attrs['Proxmox.VMStatus']) { $dev.Attrs['Proxmox.VMStatus'] } else { 'unknown' }
                    IPAddress = if ($dev.IP) { $dev.IP } else { 'N/A' }
                    Node = $vmNode; CPU = 'N/A'; RAM = 'N/A'; Disk = 'N/A'
                    NetworkIn = 'N/A'; NetworkOut = 'N/A'; Uptime = '0'
                    Tags = 'N/A'; HAState = 'N/A'
                }
            }
        }

        if ($dashboardRows.Count -eq 0) {
            Write-Warning "No data to generate dashboard."
        }
        else {
            $dashReportTitle = "Proxmox Dashboard"
            $dashTempPath = Join-Path $OutputDir 'Proxmox-Dashboard.html'

            $null = Export-ProxmoxDashboardHtml `
                -DashboardData $dashboardRows `
                -OutputPath $dashTempPath `
                -ReportTitle $dashReportTitle

            Write-Host ""
            Write-Host "Dashboard generated: $dashTempPath" -ForegroundColor Green
            $dHosts   = @($dashboardRows | Where-Object { $_.Type -eq 'Host' }).Count
            $dVMs     = @($dashboardRows | Where-Object { $_.Type -like 'VM*' }).Count
            $dRunning = @($dashboardRows | Where-Object { $_.Status -eq 'running' }).Count
            $dStopped = @($dashboardRows | Where-Object { $_.Status -eq 'stopped' }).Count
            Write-Host "  Hosts: $dHosts  |  VMs: $dVMs  |  Running: $dRunning  |  Stopped: $dStopped" -ForegroundColor White

            # Attempt to copy to WUG NmConsole directory
            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

            if ($nmConsolePath) {
                $wugDashPath = Join-Path $nmConsolePath 'Proxmox-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI (behind auth): /NmConsole/Proxmox-Dashboard.html" -ForegroundColor Cyan
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
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\Proxmox-Dashboard.html'" -ForegroundColor Cyan
            }
        }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "Re-run anytime to discover new Proxmox nodes/VMs." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBc9gg06bsUak7L
# 1X1QvVAWG9ImHcQOR1Fa/VdmCPwN6aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgNg/qRPZhNwKjFJPeULOqnGy1p9h1YUnT
# zdrQmi0Wdq8wDQYJKoZIhvcNAQEBBQAEggIAb29cFw/IZ1vcw11v0VvyZ2SNOeXa
# xh+40HvE2CRO4kw3jWgpbuI1kNtzzuEGtfXK61mfuyg9Xih9DtLJNnkS/HP2C5ON
# F9Kvs3DajU/FqaULSHglYbxlTPCzdJMzfNYXKurQM24WXdsbi705b9MevrvkDFEq
# 3eDTFRb0WVjnG6OYT8VTg3oJJw/6Sz5LtUL8qF8ZlGXgpb3JlLfzjydCLkPWVtK5
# byxOMb/RK2lXtmEhAI08R9uWThC0z69wATAOHDELHi1pYU5x1xz3IFbdo3KOIWvd
# Jn7mMEgqxN+JF+iXYB6YLs8oO+vPteEzavCl8Enx2MxXtiqHlq3BdMtApfsEue+w
# ivGihAlOz2kw2u+k3fy2c3w5kEbLSu/9Y7X6mUXBBfLdIev6MB3rcxK1QeHbuaxu
# RJ3iVRr3Rt4CET9PZ3LagHcq+ETRokcFMXixWnjP0gGb1dD+SlU7udBlxi4qT/Z8
# cYHaFSToMmAoDFriGxNjoZC0A5hra1DzTYqdXGWf5fU6ZlaeKNei0KJMvSuGPLCM
# guDAsHk5caYLfM35UWbMuhiaLQizfnIwPMtqLwv/k9L8NYVDBzh6metZg1g1WEmz
# rbUZinxeJBSJtew1XB3aeYImot0DiWUxwEUTydWFqecvJhDSgU+Mf0msPibEshiu
# qKLW4fRbQu49X0g=
# SIG # End signature block
