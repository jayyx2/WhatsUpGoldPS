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

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

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
        'CT' {
            $ctid = $item.Attributes['Proxmox.VMID']
            $key  = "ct:${ctid}"
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
$ctDevices   = @($devicePlan.Values | Where-Object { $_.Type -eq 'CT' })
$guestDevices = @($vmDevices) + @($ctDevices)
$guestWithIP  = @($guestDevices | Where-Object { $_.IP })
$guestNoIP    = @($guestDevices | Where-Object { -not $_.IP })

# Count unique monitor TEMPLATES (not total items)
$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } |
    Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } |
    Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Nodes:                  $($nodeDevices.Count)" -ForegroundColor White
Write-Host "  VMs:                    $($vmDevices.Count)" -ForegroundColor White
Write-Host "  Containers (LXC):       $($ctDevices.Count)" -ForegroundColor White
Write-Host "  Guests with IP:         $($guestWithIP.Count)" -ForegroundColor White
Write-Host "  Guests without IP:      $($guestNoIP.Count)" -ForegroundColor White
Write-Host "  Total WUG devices:      $($nodeDevices.Count + $guestWithIP.Count + 1) (nodes + guests w/ IP + cluster)" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

Write-Host "Monitor templates:" -ForegroundColor Cyan
foreach ($t in $activeTemplates) { Write-Host "  [Active] $t" -ForegroundColor White }
foreach ($t in $perfTemplates)   { Write-Host "  [Perf]   $t" -ForegroundColor White }
Write-Host ""

if ($guestNoIP.Count -gt 0) {
    Write-Host "Guests without IP (monitors attach to parent node):" -ForegroundColor Yellow
    foreach ($g in $guestNoIP) {
        Write-Host "    $($g.Name) [$($g.Type)] (on $($g.ParentNode))" -ForegroundColor DarkYellow
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
        'DashboardAndPush' { $choice = '7' }
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
        if (-not $ProxmoxToken) {
            Write-Warning "WUG push requires API token auth. Re-run and choose option [1] for authentication."
            return
        }
        # --- Multi-device push to WUG -----------------------------------------
        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            # Import from repo (not installed module) to get latest functions
            $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
            if (Test-Path $repoPsd1) {
                Import-Module $repoPsd1 -Force -ErrorAction Stop
            } else {
                Import-Module WhatsUpGoldPS -ErrorAction Stop
            }
        }
        catch {
            Write-Error "Could not load WhatsUpGoldPS module. Is it installed? $_"
            return
        }
        # Dot-source internal helper so scripts can call Get-WUGAPIResponse directly
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if ($WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
        }
        else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors
        }

        # ================================================================
        # PushToWUG — Azure-style flow:
        #   1. Create/find credential
        #   2a. Create active monitors in library (bulk)
        #   2b. Create perf monitors in library (bulk)
        #   2c. Check existing vs new devices
        #   2d. Create new devices via Add-WUGDeviceTemplate
        #   2e. Update existing devices (assign creds + monitors)
        # ================================================================
        $stats = @{
            HealthCreated = 0; HealthSkipped = 0; HealthFailed = 0
            PerfCreated   = 0; PerfSkipped   = 0; PerfFailed   = 0
            DevicesCreated = 0; DevicesFound = 0; CloudDevices = 0
            CredsAssigned = 0
        }
        $wugDeviceMap = @{}   # deviceKey -> WUG device ID
        $deviceKeys = @($devicePlan.Keys | Sort-Object)
        $devTotal   = $deviceKeys.Count

        # ---- 1. Create/find REST API credential ----------------------------
        Write-Host ""
        Write-Host "Setting up Proxmox REST API credential in WUG..." -ForegroundColor Cyan

        $credName   = "Proxmox API Token"
        $proxCredId = $null

        # Search by type + name first, then by name only as fallback
        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName -View basic)
            if ($existingCreds.Count -eq 0) {
                $existingCreds = @(Get-WUGCredential -SearchValue $credName -View basic)
            }
            if ($existingCreds.Count -gt 0) {
                $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                if ($matchCred) {
                    $proxCredId = $matchCred.id
                    Write-Host "  Found existing credential '$credName' (ID: $proxCredId)" -ForegroundColor Green
                }
            }
        }
        catch { Write-Verbose "Credential search error: $_" }

        if (-not $proxCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                $credResult = Add-WUGCredential -Name $credName `
                    -Description "Proxmox PVE API Token (auto-created by discovery)" `
                    -Type restapi `
                    -RestApiUsername 'api-token' `
                    -RestApiPassword $ProxmoxToken `
                    -RestApiAuthType '0' `
                    -RestApiIgnoreCertErrors 'True'
                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) {
                        $proxCredId = $credResult.data.idMap.resultId
                    } elseif ($credResult.PSObject.Properties['resourceId']) {
                        $proxCredId = $credResult.resourceId
                    } elseif ($credResult.PSObject.Properties['id']) {
                        $proxCredId = $credResult.id
                    }
                    if ($proxCredId) {
                        Write-Host "  Created credential (ID: $proxCredId)" -ForegroundColor Green
                    }
                }
            }
            catch {
                Write-Verbose "Standard credential creation failed: $_"
            }

            # Fallback: try PATCH config/template endpoint (like monitor templates)
            if (-not $proxCredId) {
                try {
                    $credTpl = @{
                        templateId   = 'proxmox_restapi_1'
                        name         = $credName
                        description  = 'Proxmox PVE API Token (auto-created by discovery)'
                        type         = 'restapi'
                        propertyBags = @(
                            @{ name = 'CredRestAPI:Username'; value = 'api-token' }
                            @{ name = 'CredRestAPI:Password'; value = $ProxmoxToken }
                            @{ name = 'CredRestAPI:Authtype'; value = '0' }
                            @{ name = 'CredRestAPI:IgnoreCertificateErrorsForOAuth2Token'; value = 'True' }
                        )
                    }
                    $credBody = @{ credentials = @($credTpl) } | ConvertTo-Json -Depth 5
                    $credUri  = "${global:WhatsUpServerBaseURI}/api/v1/credentials/-/config/template"
                    $tplResult = Get-WUGAPIResponse -Uri $credUri -Method 'PATCH' -Body $credBody
                    if ($tplResult.data -and $tplResult.data.idMap) {
                        $proxCredId = ($tplResult.data.idMap | Select-Object -First 1).resultId
                        Write-Host "  Created credential via template (ID: $proxCredId)" -ForegroundColor Green
                    }
                }
                catch {
                    Write-Verbose "Template credential creation also failed: $_"
                }
            }

            # Re-search in case creation succeeded but ID extraction failed
            if (-not $proxCredId) {
                try {
                    $recheck = @(Get-WUGCredential -SearchValue $credName -View basic)
                    $match = $recheck | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                    if ($match) {
                        $proxCredId = $match.id
                        Write-Host "  Found credential '$credName' after creation (ID: $proxCredId)" -ForegroundColor Green
                    }
                }
                catch { }
            }

            if (-not $proxCredId) {
                Write-Warning "Could not create REST API credential via API."
                Write-Warning "Create it manually in WUG: Credentials Library -> Add -> REST API"
                Write-Warning "  Name: $credName | Auth: None/Basic | Username: api-token | Password: <PVE token>"
                Write-Warning "Monitors will still work (auth is in CustomHeader), but devices won't have the credential assigned."
            }
        }

        # ---- 2a. Create active monitors in library (bulk) ------------------
        Write-Host ""
        Write-Host "  Creating active monitors in library..." -ForegroundColor Cyan

        # Deduplicate by monitor name across all devices
        $uniqueActiveMonitors = @{}
        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                $actName = $actItem.Name
                if (-not $actName -or $uniqueActiveMonitors.ContainsKey($actName)) { continue }
                if (-not $actItem.MonitorParams -or $actItem.MonitorParams.Count -eq 0) { continue }
                $uniqueActiveMonitors[$actName] = $actItem
            }
        }

        # Check which already exist in library (per-name search like Azure)
        $existingActiveNames = @{}  # name -> library ID
        foreach ($actName in @($uniqueActiveMonitors.Keys)) {
            try {
                $found = @(Get-WUGActiveMonitor -Search $actName)
                $exact = $found | Where-Object { $_.name -eq $actName } | Select-Object -First 1
                if ($exact) {
                    $existingActiveNames[$actName] = [int]$exact.id
                }
            }
            catch { }
        }

        $toCreateActive = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        $stats.HealthSkipped = $uniqueActiveMonitors.Count - $toCreateActive.Count

        if ($toCreateActive.Count -gt 0) {
            Write-Host "    Creating $($toCreateActive.Count) new active monitors (bulk)..." -ForegroundColor DarkGray

            $activeTemplateArr = @()
            $actTplIdMap = @{}
            $actTplIdx = 0
            foreach ($actName in $toCreateActive) {
                $actItem = $uniqueActiveMonitors[$actName]
                $mp = $actItem.MonitorParams
                $tplId = "act_$actTplIdx"
                $actTplIdMap[$tplId] = $actName
                $actTplIdx++

                $bags = @(
                    @{ name = 'MonRestApi:RestUrl';                value = "$($mp.RestApiUrl)" }
                    @{ name = 'MonRestApi:HttpMethod';             value = if ($mp.RestApiMethod) { "$($mp.RestApiMethod)" } else { 'GET' } }
                    @{ name = 'MonRestApi:HttpTimeoutMs';          value = if ($mp.RestApiTimeoutMs) { "$($mp.RestApiTimeoutMs)" } else { '10000' } }
                    @{ name = 'MonRestApi:IgnoreCertErrors';       value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '1' } }
                    @{ name = 'MonRestApi:UseAnonymousAccess';     value = if ($mp.RestApiUseAnonymous) { "$($mp.RestApiUseAnonymous)" } else { '1' } }
                    @{ name = 'MonRestApi:CustomHeader';           value = if ($mp.RestApiCustomHeader) { "$($mp.RestApiCustomHeader)" } else { '' } }
                    @{ name = 'MonRestApi:DownIfResponseCodeIsIn'; value = if ($mp.RestApiDownIfResponseCodeIsIn) { "$($mp.RestApiDownIfResponseCodeIsIn)" } else { '[]' } }
                    @{ name = 'MonRestApi:ComparisonList';         value = if ($mp.RestApiComparisonList) { "$($mp.RestApiComparisonList)" } else { '[]' } }
                    @{ name = 'Cred:Type';                        value = '8192' }
                )

                $activeTemplateArr += @{
                    templateId      = $tplId
                    name            = $actName
                    description     = 'Proxmox RestApi active monitor'
                    useInDiscovery  = $false
                    monitorTypeInfo = @{
                        baseType = 'active'
                        classId  = 'f0610672-d515-4268-bd21-ac5ebb1476ff'
                    }
                    propertyBags    = $bags
                }
            }

            try {
                $batchSize = 50
                for ($bi = 0; $bi -lt $activeTemplateArr.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $activeTemplateArr.Count - 1)
                    $actBatch = @($activeTemplateArr[$bi..$batchEnd])
                    if ($activeTemplateArr.Count -gt $batchSize) {
                        $batchNum = [Math]::Floor($bi / $batchSize) + 1
                        $totalBatches = [Math]::Ceiling($activeTemplateArr.Count / $batchSize)
                        Write-Host "      Batch $batchNum/$totalBatches ($($actBatch.Count) monitors)..." -ForegroundColor DarkGray
                    }

                    $bulkActResult = Add-WUGMonitorTemplate -ActiveMonitors $actBatch
                    if ($bulkActResult.idMap) {
                        foreach ($mapping in $bulkActResult.idMap) {
                            $tplId = $mapping.templateId
                            $resultId = $mapping.resultId
                            if ($actTplIdMap.ContainsKey($tplId) -and $resultId) {
                                $actName = $actTplIdMap[$tplId]
                                $existingActiveNames[$actName] = [int]$resultId
                                $stats.HealthCreated++
                            }
                        }
                    }
                    if ($bulkActResult.errors) {
                        foreach ($err in $bulkActResult.errors) {
                            $errName = if ($actTplIdMap.ContainsKey($err.templateId)) { $actTplIdMap[$err.templateId] } else { $err.templateId }
                            Write-Warning "Active monitor create error for '$errName': $($err.messages -join '; ')"
                            $stats.HealthFailed++
                        }
                    }
                    if ($batchEnd -lt $activeTemplateArr.Count - 1) { Start-Sleep -Seconds 2 }
                }
            }
            catch {
                Write-Warning "Bulk active monitor creation failed, falling back to one-at-a-time: $_"
                $actIdx = 0
                foreach ($actName in $toCreateActive) {
                    if ($existingActiveNames.ContainsKey($actName)) { continue }
                    $actIdx++
                    $actItem = $uniqueActiveMonitors[$actName]
                    Write-Progress -Activity 'Creating Active Monitors' `
                        -Status "$actIdx / $($toCreateActive.Count) - $actName" `
                        -PercentComplete ([Math]::Round(($actIdx / $toCreateActive.Count) * 100))
                    try {
                        $actParams = @{ Type = $actItem.MonitorType; Name = $actName; ErrorAction = 'Stop' }
                        foreach ($ak in $actItem.MonitorParams.Keys) {
                            if ($ak -ne 'Name' -and $ak -ne 'Description') { $actParams[$ak] = $actItem.MonitorParams[$ak] }
                        }
                        $monLibId = Add-WUGActiveMonitor @actParams
                        if ($monLibId) { $existingActiveNames[$actName] = [int]$monLibId; $stats.HealthCreated++ }
                    }
                    catch { Write-Warning "Failed to create active monitor '$actName': $_"; $stats.HealthFailed++ }
                }
                Write-Progress -Activity 'Creating Active Monitors' -Completed
            }
        }
        Write-Host "    Active monitors: $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor DarkGray

        # Reconcile: re-query library for any names still missing
        $reconciledAct = 0
        foreach ($actName in @($uniqueActiveMonitors.Keys)) {
            if ($existingActiveNames.ContainsKey($actName)) { continue }
            try {
                $found = @(Get-WUGActiveMonitor -Search $actName)
                $exact = $found | Where-Object { $_.name -eq $actName } | Select-Object -First 1
                if ($exact) {
                    $existingActiveNames[$actName] = [int]$exact.id
                    $reconciledAct++
                }
            }
            catch { }
        }
        if ($reconciledAct -gt 0) { Write-Host "    Reconciled $reconciledAct active monitors from library" -ForegroundColor DarkGray }

        # ---- 2b. Create perf monitors in library (bulk) --------------------
        Write-Host "  Creating performance monitors in library..." -ForegroundColor Cyan

        $uniquePerfMonitors = @{}
        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                $monName = $perfItem.Name
                if (-not $monName -or $uniquePerfMonitors.ContainsKey($monName)) { continue }
                $uniquePerfMonitors[$monName] = $perfItem
            }
        }

        $existingPerfNames = @{}  # name -> monitor library id
        foreach ($monName in @($uniquePerfMonitors.Keys)) {
            try {
                $found = @(Get-WUGPerformanceMonitor -Search $monName)
                $exact = $found | Where-Object { $_.name -eq $monName } | Select-Object -First 1
                if ($exact) {
                    $existingPerfNames[$monName] = "$($exact.id)"
                }
            }
            catch { }
        }

        $toCreatePerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        $stats.PerfSkipped = $uniquePerfMonitors.Count - $toCreatePerf.Count

        if ($toCreatePerf.Count -gt 0) {
            Write-Host "    Creating $($toCreatePerf.Count) new perf monitors (bulk)..." -ForegroundColor DarkGray

            $perfTemplateArr = @()
            $perfTplIdMap = @{}
            $perfTplIdx = 0
            foreach ($monName in $toCreatePerf) {
                $perfItem = $uniquePerfMonitors[$monName]
                $mp = $perfItem.MonitorParams
                $tplId = "perf_$perfTplIdx"
                $perfTplIdMap[$tplId] = $monName
                $perfTplIdx++

                $bags = @(
                    @{ name = 'RdcRestApi:RestUrl';            value = "$($mp.RestApiUrl)" }
                    @{ name = 'RdcRestApi:JsonPath';           value = "$($mp.RestApiJsonPath)" }
                    @{ name = 'RdcRestApi:HttpMethod';         value = if ($mp.RestApiHttpMethod) { "$($mp.RestApiHttpMethod)" } else { 'GET' } }
                    @{ name = 'RdcRestApi:HttpTimeoutMs';      value = if ($mp.RestApiHttpTimeoutMs) { "$($mp.RestApiHttpTimeoutMs)" } else { '10000' } }
                    @{ name = 'RdcRestApi:IgnoreCertErrors';   value = if ($mp.RestApiIgnoreCertErrors) { "$($mp.RestApiIgnoreCertErrors)" } else { '1' } }
                    @{ name = 'RdcRestApi:UseAnonymousAccess'; value = if ($mp.RestApiUseAnonymousAccess) { "$($mp.RestApiUseAnonymousAccess)" } else { '1' } }
                    @{ name = 'RdcRestApi:CustomHeader';       value = if ($mp.RestApiCustomHeader) { "$($mp.RestApiCustomHeader)" } else { '' } }
                )

                $perfTemplateArr += @{
                    templateId      = $tplId
                    name            = $monName
                    description     = 'Proxmox RestApi performance monitor'
                    monitorTypeInfo = @{
                        baseType = 'performance'
                        classId  = '987bb6a4-70f4-4f46-97c6-1c9dd1766437'
                    }
                    propertyBags    = $bags
                }
            }

            try {
                $batchSize = 50
                for ($bi = 0; $bi -lt $perfTemplateArr.Count; $bi += $batchSize) {
                    $batchEnd = [Math]::Min($bi + $batchSize - 1, $perfTemplateArr.Count - 1)
                    $perfBatch = @($perfTemplateArr[$bi..$batchEnd])
                    $batchNum = [Math]::Floor($bi / $batchSize) + 1
                    $totalBatches = [Math]::Ceiling($perfTemplateArr.Count / $batchSize)
                    Write-Host "      Batch $batchNum/$totalBatches ($($perfBatch.Count) monitors)..." -ForegroundColor DarkGray

                    $bulkPerfResult = Add-WUGMonitorTemplate -PerformanceMonitors $perfBatch
                    if ($bulkPerfResult.idMap) {
                        foreach ($mapping in $bulkPerfResult.idMap) {
                            $tplId = $mapping.templateId
                            $resultId = $mapping.resultId
                            if ($perfTplIdMap.ContainsKey($tplId) -and $resultId) {
                                $monName = $perfTplIdMap[$tplId]
                                $existingPerfNames[$monName] = "$resultId"
                                $stats.PerfCreated++
                            }
                        }
                    }
                    if ($bulkPerfResult.errors) {
                        foreach ($err in $bulkPerfResult.errors) {
                            $errName = if ($perfTplIdMap.ContainsKey($err.templateId)) { $perfTplIdMap[$err.templateId] } else { $err.templateId }
                            Write-Warning "Perf monitor create error for '$errName': $($err.messages -join '; ')"
                            $stats.PerfFailed++
                        }
                    }
                    if ($batchEnd -lt $perfTemplateArr.Count - 1) { Start-Sleep -Seconds 2 }
                }
            }
            catch {
                Write-Warning "Bulk perf monitor creation failed, falling back to one-at-a-time: $_"
                $perfIdx = 0
                foreach ($monName in $toCreatePerf) {
                    if ($existingPerfNames.ContainsKey($monName)) { continue }
                    $perfIdx++
                    $perfItem = $uniquePerfMonitors[$monName]
                    Write-Progress -Activity 'Creating Perf Monitors' `
                        -Status "$perfIdx / $($toCreatePerf.Count)" `
                        -PercentComplete ([Math]::Round(($perfIdx / $toCreatePerf.Count) * 100))
                    try {
                        $perfParams = @{ Type = $perfItem.MonitorType; Name = $monName; ErrorAction = 'Stop' }
                        foreach ($pk in $perfItem.MonitorParams.Keys) {
                            if ($pk -notin @('Name','Description','LastValue','LastTimestamp','MetricUnit') -and $pk -notlike '_*') {
                                $perfParams[$pk] = $perfItem.MonitorParams[$pk]
                            }
                        }
                        $result = Add-WUGPerformanceMonitor @perfParams
                        if ($result -and $result.MonitorId) {
                            $existingPerfNames[$monName] = "$($result.MonitorId)"
                            $stats.PerfCreated++
                        }
                    }
                    catch {
                        if ($_.Exception.Message -match 'already exists|duplicate') { $stats.PerfSkipped++ }
                        else { Write-Verbose "Failed to create perf monitor '$monName': $_"; $stats.PerfFailed++ }
                    }
                }
                Write-Progress -Activity 'Creating Perf Monitors' -Completed
            }
        }
        Write-Host "    Perf monitors: $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor DarkGray

        # Reconcile perf monitors
        $reconciledPerf = 0
        foreach ($monName in @($uniquePerfMonitors.Keys)) {
            if ($existingPerfNames.ContainsKey($monName)) { continue }
            try {
                $found = @(Get-WUGPerformanceMonitor -Search $monName)
                $exact = $found | Where-Object { $_.name -eq $monName } | Select-Object -First 1
                if ($exact) {
                    $existingPerfNames[$monName] = "$($exact.id)"
                    $reconciledPerf++
                }
            }
            catch { }
        }
        if ($reconciledPerf -gt 0) { Write-Host "    Reconciled $reconciledPerf perf monitors from library" -ForegroundColor DarkGray }

        # ---- 2c. Identify existing vs new devices --------------------------
        Write-Host "  Checking for existing devices..." -ForegroundColor Cyan
        $existingDevices = @{}   # key -> deviceId
        $newDeviceKeys   = [System.Collections.Generic.List[string]]::new()

        $devIdx = 0
        foreach ($key in $deviceKeys) {
            $devIdx++
            $dev = $devicePlan[$key]
            # Every device gets created — no-IP guests use 0.0.0.0
            $rawIP = $dev.IP
            $addIP = if ($rawIP -and $rawIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $rawIP } else { '0.0.0.0' }
            $displayName = "$($dev.Name) ($($dev.Type))"

            Write-Progress -Activity 'Checking existing devices' `
                -Status "$devIdx / $devTotal - $($dev.Name)" `
                -PercentComplete ([Math]::Round(($devIdx / $devTotal) * 100))

            $deviceId = $null
            try {
                $searchResults = @(Get-WUGDevice -SearchValue $dev.Name)
                if ($searchResults.Count -gt 0) {
                    $existingDevice = $searchResults | Where-Object {
                        $_.displayName -eq $dev.Name -or
                        $_.displayName -eq $displayName -or
                        $_.hostName -eq $dev.Name
                    } | Select-Object -First 1
                    if ($existingDevice) { $deviceId = $existingDevice.id }
                }
                if (-not $deviceId -and $dev.IP) {
                    $searchResults = @(Get-WUGDevice -SearchValue $addIP)
                    if ($searchResults.Count -gt 0) {
                        $match = $searchResults | Where-Object {
                            $_.networkAddress -eq $addIP -or $_.hostName -eq $addIP
                        } | Select-Object -First 1
                        if ($match) { $deviceId = $match.id }
                    }
                }
            }
            catch { Write-Verbose "Search for '$($dev.Name)' returned error: $_" }

            if ($deviceId) {
                $existingDevices[$key] = $deviceId
                $wugDeviceMap[$key] = $deviceId
                $stats.DevicesFound++
            }
            else {
                $newDeviceKeys.Add($key)
            }
        }
        Write-Progress -Activity 'Checking existing devices' -Completed
        Write-Host "    Found $($stats.DevicesFound) existing, $($newDeviceKeys.Count) new to create" -ForegroundColor DarkGray

        # ---- 2d. Create devices via Add-WUGDeviceTemplate ------------------
        if ($newDeviceKeys.Count -gt 0) {
            Write-Host "  Creating $($newDeviceKeys.Count) devices..." -ForegroundColor Yellow
            $devIdx = 0

            foreach ($key in $newDeviceKeys) {
                $devIdx++
                $dev = $devicePlan[$key]
                $rawIP = $dev.IP
                $addIP = if ($rawIP -and $rawIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $rawIP } else { '0.0.0.0' }
                $displayName = "$($dev.Name) ($($dev.Type))"

                Write-Progress -Activity 'Creating devices' `
                    -Status "$devIdx / $($newDeviceKeys.Count) - $displayName" `
                    -PercentComplete ([Math]::Round(($devIdx / $newDeviceKeys.Count) * 100))

                # Build attributes array
                $devAttrs = @()
                foreach ($attrName in $dev.Attrs.Keys) {
                    $attrVal = $dev.Attrs[$attrName]
                    if ($attrVal) { $devAttrs += @{ name = $attrName; value = "$attrVal" } }
                }

                # Collect unique active monitor names that exist in library
                $actNames = @()
                $seenActNames = @{}
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name) -and -not $seenActNames.ContainsKey($actItem.Name)) {
                        $actNames += $actItem.Name
                        $seenActNames[$actItem.Name] = $true
                    }
                }

                # Collect unique perf monitor names that exist in library
                $perfNames = @()
                $seenPerfNames = @{}
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name) -and -not $seenPerfNames.ContainsKey($perfItem.Name)) {
                        $perfNames += $perfItem.Name
                        $seenPerfNames[$perfItem.Name] = $true
                    }
                }

                # Skip devices with no monitors to assign
                if ($actNames.Count -eq 0 -and $perfNames.Count -eq 0) {
                    Write-Verbose "Skipping '$displayName' — no monitors to assign."
                    continue
                }

                $devNote = "Proxmox $($dev.Type) (auto-created by discovery)"

                $splat = @{
                    displayName   = $displayName
                    DeviceAddress = $addIP
                    Hostname      = $dev.Name
                    Brand         = 'Proxmox'
                    Note          = $devNote
                }

                if ($devAttrs.Count -gt 0) { $splat['Attributes'] = $devAttrs }
                if ($credName -and $proxCredId) { $splat['CredentialRestApi'] = $credName }

                if ($actNames.Count -gt 0) {
                    $splat['ActiveMonitors'] = $actNames
                }
                # Always suppress default Ping monitor — our REST API active monitors handle up/down
                $splat['NoDefaultActiveMonitor'] = $true

                if ($perfNames.Count -gt 0) {
                    $splat['PerformanceMonitors'] = $perfNames
                }

                try {
                    $devResult = Add-WUGDeviceTemplate @splat

                    if ($devResult -and -not $devResult.error) {
                        $newDeviceId = $null
                        if ($devResult.idMap) {
                            $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId
                        } elseif ($devResult.PSObject.Properties['resultId']) {
                            $newDeviceId = $devResult.resultId
                        }
                        if ($newDeviceId) { $wugDeviceMap[$key] = $newDeviceId }
                        $stats.DevicesCreated++
                        if (-not $dev.IP) { $stats.CloudDevices++ }
                        Write-Verbose "Created device '$displayName' (ID: $newDeviceId)"
                    } else {
                        $errMsg = if ($devResult.error) { $devResult.error } else { 'Unknown error' }
                        Write-Warning "Failed to create device '$displayName': $errMsg"
                    }
                }
                catch {
                    Write-Warning "Error creating device '$displayName': $_"
                }
            }

            Write-Progress -Activity 'Creating devices' -Completed
            Write-Host "    Devices: $($stats.DevicesCreated) created ($($stats.CloudDevices) no-IP)" -ForegroundColor Green
        }

        # ---- 2e. Handle existing devices (creds + monitor assignment) ------
        if ($existingDevices.Count -gt 0) {
            Write-Host "  Updating $($existingDevices.Count) existing devices (credentials + monitors)..." -ForegroundColor Cyan
            $existIdx = 0
            foreach ($key in $existingDevices.Keys) {
                $existIdx++
                $deviceId = [int]$existingDevices[$key]
                $dev = $devicePlan[$key]

                Write-Progress -Activity 'Updating existing devices' `
                    -Status "$existIdx / $($existingDevices.Count) - $($dev.Name)" `
                    -PercentComplete ([Math]::Round(($existIdx / $existingDevices.Count) * 100))

                # Assign credential
                if ($proxCredId) {
                    try {
                        $null = Set-WUGDeviceCredential -DeviceId $deviceId -CredentialId $proxCredId -Assign
                        $stats.CredsAssigned++
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Credential assign error for device $deviceId`: $_"
                        }
                    }
                }

                # Assign active monitors by library ID
                $actMonitorIds = @()
                foreach ($actItem in @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' })) {
                    if ($actItem.Name -and $existingActiveNames.ContainsKey($actItem.Name)) {
                        $actMonitorIds += $existingActiveNames[$actItem.Name]
                    }
                }
                if ($actMonitorIds.Count -gt 0) {
                    try {
                        Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId $actMonitorIds -ErrorAction Stop
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Active monitor assign error for device $deviceId`: $_"
                        }
                    }
                }

                # Assign perf monitors by library ID
                $perfMonitorIds = @()
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name)) {
                        $perfMonitorIds += [int]$existingPerfNames[$perfItem.Name]
                    }
                }
                if ($perfMonitorIds.Count -gt 0) {
                    try {
                        Add-WUGPerformanceMonitorToDevice -DeviceId $deviceId -MonitorId $perfMonitorIds -PollingIntervalMinutes 5 -ErrorAction Stop
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                            Write-Verbose "Perf monitor assign error for device $deviceId`: $_"
                        }
                    }
                }
            }
            Write-Progress -Activity 'Updating existing devices' -Completed
        }

        # ---- Summary -------------------------------------------------------
        Write-Host ""
        Write-Host "Push complete!" -ForegroundColor Green
        Write-Host "  Active monitors:  $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor White
        Write-Host "  Perf monitors:    $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor White
        Write-Host "  Devices:          $($stats.DevicesCreated) created ($($stats.CloudDevices) no-IP), $($stats.DevicesFound) existing" -ForegroundColor White
        Write-Host "  Creds assigned:   $($stats.CredsAssigned)" -ForegroundColor White
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
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
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
            $apiType = 'qemu'
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

        # --- Fetch live LXC container stats ---
        foreach ($key in $devicePlan.Keys) {
            $dev = $devicePlan[$key]
            if ($dev.Type -ne 'CT') { continue }
            $ctid   = $dev.Attrs['Proxmox.VMID']
            $ctNode = $dev.ParentNode
            try {
                $resp = & $dashInvokeApi "${dashBaseUri}/api2/json/nodes/${ctNode}/lxc/${ctid}/status/current" $dashHdrName $dashHdrVal '1'
                $d = $resp.data

                $cpuPct   = '{0:N1}%' -f ($d.cpu * 100)
                $cores    = if ($d.cpus) { $d.cpus } else { '1' }
                $ramUsed  = [math]::Round($d.mem / 1MB)
                $ramTotal = [math]::Round($d.maxmem / 1MB)
                $ramPct   = if ($ramTotal -gt 0) { '{0:N1}%' -f ($ramUsed / $ramTotal * 100) } else { '0.0%' }
                $diskTot  = '{0} MB' -f [math]::Round($d.maxdisk / 1MB)
                $netInKB  = '{0} KB' -f [math]::Round($d.netin / 1KB)
                $netOutKB = '{0} KB' -f [math]::Round($d.netout / 1KB)
                $tags     = if ($d.tags) { "$($d.tags)" } else { 'N/A' }
                $haState  = if ($d.ha -and $d.ha.managed) { "$($d.ha.managed)" } else { 'N/A' }

                $dashboardRows += [PSCustomObject]@{
                    Type       = "CT ($ctid)"
                    Name       = $dev.Name
                    Status     = $d.status
                    IPAddress  = if ($dev.IP) { $dev.IP } else { 'N/A' }
                    Node       = $ctNode
                    CPU        = "$cpuPct (${cores}c)"
                    RAM        = "$ramPct ($ramUsed MB / $ramTotal MB)"
                    Disk       = $diskTot
                    NetworkIn  = $netInKB
                    NetworkOut = $netOutKB
                    Uptime     = "$($d.uptime)"
                    Tags       = $tags
                    HAState    = $haState
                }
                Write-Host "  CT: $($dev.Name)" -ForegroundColor DarkGray
            }
            catch {
                $dashboardRows += [PSCustomObject]@{
                    Type = "CT ($ctid)"; Name = $dev.Name
                    Status = if ($dev.Attrs['Proxmox.VMStatus']) { $dev.Attrs['Proxmox.VMStatus'] } else { 'unknown' }
                    IPAddress = if ($dev.IP) { $dev.IP } else { 'N/A' }
                    Node = $ctNode; CPU = 'N/A'; RAM = 'N/A'; Disk = 'N/A'
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
            $dCTs     = @($dashboardRows | Where-Object { $_.Type -like 'CT*' }).Count
            $dRunning = @($dashboardRows | Where-Object { $_.Status -eq 'running' }).Count
            $dStopped = @($dashboardRows | Where-Object { $_.Status -eq 'stopped' }).Count
            Write-Host "  Hosts: $dHosts  |  VMs: $dVMs  |  CTs: $dCTs  |  Running: $dRunning  |  Stopped: $dStopped" -ForegroundColor White

            # Attempt to copy to WUG NmConsole directory
            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

            if ($nmConsolePath) {
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) { New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null }
                $wugDashPath = Join-Path $wugDashDir 'Proxmox-Dashboard.html'
                try {
                    Copy-Item -Path $dashTempPath -Destination $wugDashPath -Force
                    Write-Host "Copied to WUG: $wugDashPath" -ForegroundColor Green
                    Write-Host "  Access via WUG web UI: /NmConsole/dashboards/Proxmox-Dashboard.html" -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Could not copy to NmConsole (run as admin?): $_"
                    Write-Host "  Manual copy: Copy-Item '$dashTempPath' '$wugDashPath'" -ForegroundColor Yellow
                }
                Deploy-DashboardWebConfig -Path $wugDashDir
            }
            else {
                Write-Host ""
                Write-Host "WUG NmConsole directory not found locally." -ForegroundColor Yellow
                Write-Host "Copy the file to your WUG server:" -ForegroundColor Yellow
                Write-Host "  Copy-Item '$dashTempPath' '<WUG_Install>\Html\NmConsole\dashboards\Proxmox-Dashboard.html'" -ForegroundColor Cyan
            }
        }
    }
    default {
        Write-Host "No action taken." -ForegroundColor Gray
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "Re-run anytime to discover new Proxmox nodes/VMs." -ForegroundColor Cyan

# SIG # Begin signature block
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCZ8AxpUxrRvRfo
# 5arVeV4NKninNeMT1P+H1V6H1Qd+jKCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBDY41Q
# Spd6uL8iQfUcc5F2cTqwEqbF4gt6jjoy93F06DANBgkqhkiG9w0BAQEFAASCAgCQ
# i4O0w09AxFTk2wOct8Tc9APb+1gWFRWlMoMv5YVJ0dXCQPM5J5ztg/754n5vkOnt
# YVKMuh7m86PjOOleJO1TAVvToHcJkqTR9uRLmQ05BpbeoSs3WoDFs68h1MXjpoW7
# /DHNW9Krn0F7JV8XvFrsyXJSrQrTZMAK03zojbyIh0sPRFGnro1j0H9ioy7hT2K5
# wSSqvkpRhJ48Qgs2G+32qmUj2TRkIPIJNw2AkMkQPwrlLrB5pCIjttJxJ+UtIaxS
# WAki6dtUOVSuM0zpVTrnW/yygAmSc1uHP/dZyq90YXREexKrRFLeow/6IExiwo2D
# xbdVUl6JklXaVmDQZtls52lkaIWuo81dIIt11suBbcY3XD8gdvAUu+7rfZy2cKh9
# lJ7MlAKAOLVTuCELEfMjsFidhKporL/useT/IZR9J9bhdOLs0hGEaCfGH1FBV25E
# Q03CID4t9mH+hywkO8ANbXMRibSp0EsslHxKXHDWjK4SlROqTarHiAdALdik2A9S
# O/G+f25k1/+oLlMItnXUVAeHYsdmZhZ/7oiCfWji/a0XFW3EAxpSScgIKUFuDfqn
# ILiUBj1Zj6VFqXdoRxBE2kQpG0oXlc/ktUwTgYV8RySl7kFAa6wKmEG8mgG+rbYO
# Fagwd55gok7nR6UVGvSumAABAzW3cT6lK0pVsylWXKGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzExNTIx
# MFowPwYJKoZIhvcNAQkEMTIEMPIcJcSZri3Y2WdS+3ugHEyw60jb+u6i3ngLIORq
# OoAVA/z9uOnSrZdoFlZiAH9QiDANBgkqhkiG9w0BAQEFAASCAgChYrofQFAJpu9v
# p3os7Cy8RASsYBZmwIfeDYpwWquaPHMFZ1fFrk1Z5FX2mtcKTMQmKdPvE0KCn5eq
# 9pXp3UxS/HfnmhZx9rJwfFlNHaX9tyWEkRSWJm/HNfoQAN6d6A0jvutPS1vYz/J3
# ZHvw1HVICGTWxRi+LlAnwpXluc7ap1Op+nSqmunOsjRm9NxENTsy7bHpuK0RNSVI
# fxF859jNn1sveb04j40n2zbYeGV0BFpRiujzkZ2z/YFslvV9znOwMHSbTM4bzMR0
# ZFq4fIkEBStYe4d1H58HiYUeFT9IyioxdST4yS11t/4qZPGZ2r39gcAd0QWp58Xc
# FJVFVvLA/8Nex7QLMPo+r8pRb7hWsAGpeCyvBCT/QrVPbwgR6nTsiCbeWbEOdqir
# +WRuIj5r3a5SPV+yD0SIlY8ylbuoBKPsYgiUw1+61OydI5CLAzPLeM0/2zTsjcpX
# 3EJm6I5Hpv7sA6GBXL9fCeYIrC0bGUPEHID+KIKg7sy5xLmszxcrvhMYOuksA2px
# nkJ0prFhjwQuA6Djx/YJCfcHka6MU97i8I8fjuBBOVUlLYAHvXNCvyhXLHMZOybS
# lkDjQGZMLHVSJ5P0XE7sGz486Ph+LDzDRSNgr8000wHTCQ2zlPfoPPtQCnRPQ8cm
# lnoXaxbaR+selaLbTstrRe4cYTRtBw==
# SIG # End signature block
