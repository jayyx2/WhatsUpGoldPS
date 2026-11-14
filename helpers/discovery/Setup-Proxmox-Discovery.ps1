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
    When omitted in interactive mode, prompts for input (default: 192.168.1.30).

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
    .\Setup-Proxmox-Discovery.ps1 -Target '192.168.1.30' -Action ExportJSON -NonInteractive
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
$DefaultHost   = '192.168.1.30'          # Default Proxmox host (interactive fallback)
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

# Build deterministic placeholder IPv4 addresses for no-IP guests so
# each guest can still become a distinct WUG device.
function Get-ProxmoxPlaceholderDeviceIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceKey
    )

    $idNum = $null
    if ($DeviceKey -match '^(vm|ct):(\d+)$') {
        $idNum = [int]$Matches[2]
    }
    else {
        $sum = 0
        foreach ($ch in $DeviceKey.ToCharArray()) { $sum += [int][char]$ch }
        $idNum = $sum
    }

    $idNum = [math]::Abs($idNum)
    $oct3 = [int](($idNum / 254) % 254) + 1
    $oct4 = [int]($idNum % 254) + 1
    return "100.64.${oct3}.${oct4}"
}

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
Write-Host "  Total WUG devices:      $($nodeDevices.Count + $guestDevices.Count + 1) (nodes + all guests + cluster)" -ForegroundColor White
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

if (-not $choice -and $NonInteractive) { $choice = '5' }

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
                catch {
                    Write-Warning "  Credential re-check failed for '$credName': $($_.Exception.Message)"
                }
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

        # One library read: per-name search returns device assignments, which never match by name.
        $existingActiveNames = @{}  # name -> library ID
        try {
            $activeLibrary = Get-WUGMonitorLibraryMap -Type active
            foreach ($actName in @($uniqueActiveMonitors.Keys)) {
                if ($activeLibrary.ContainsKey($actName)) { $existingActiveNames[$actName] = [int]$activeLibrary[$actName] }
            }
        }
        catch {
            Write-Warning "    Could not read the active monitor library: $($_.Exception.Message). Monitors may be created again."
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

        # Reconcile: re-read the library for any names still missing
        $reconciledAct = 0
        $missingAct = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        if ($missingAct.Count -gt 0) {
            try {
                $activeLibrary = Get-WUGMonitorLibraryMap -Type active
                foreach ($actName in $missingAct) {
                    if ($activeLibrary.ContainsKey($actName)) {
                        $existingActiveNames[$actName] = [int]$activeLibrary[$actName]
                        $reconciledAct++
                    }
                }
            }
            catch {
                Write-Warning "    Could not re-read the active monitor library: $($_.Exception.Message)."
            }
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
        try {
            $perfLibrary = Get-WUGMonitorLibraryMap -Type performance
            foreach ($monName in @($uniquePerfMonitors.Keys)) {
                if ($perfLibrary.ContainsKey($monName)) { $existingPerfNames[$monName] = "$($perfLibrary[$monName])" }
            }
        }
        catch {
            Write-Warning "    Could not read the performance monitor library: $($_.Exception.Message). Monitors may be created again."
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
        $missingPerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        if ($missingPerf.Count -gt 0) {
            try {
                $perfLibrary = Get-WUGMonitorLibraryMap -Type performance
                foreach ($monName in $missingPerf) {
                    if ($perfLibrary.ContainsKey($monName)) {
                        $existingPerfNames[$monName] = "$($perfLibrary[$monName])"
                        $reconciledPerf++
                    }
                }
            }
            catch {
                Write-Warning "    Could not re-read the performance monitor library: $($_.Exception.Message)."
            }
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
            # Every device gets created — no-IP guests get deterministic
            # placeholder IPs to avoid address collisions in WUG.
            $rawIP = $dev.IP
            $addIP = if ($rawIP -and $rawIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $rawIP } else { Get-ProxmoxPlaceholderDeviceIp -DeviceKey $key }
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
                if (-not $deviceId) {
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
                $addIP = if ($rawIP -and $rawIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $rawIP } else { Get-ProxmoxPlaceholderDeviceIp -DeviceKey $key }
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

                    # Detect error arrays: Add-WUGDeviceTemplate returns $result.data.errors
                    # (array of objects with .templateId/.messages) on failure, or
                    # $result.data (object with .idMap/.errors/.operations/.successful) on success.
                    $isErrorResult = $false
                    if ($devResult -is [array]) {
                        # Error array returned — each element has .templateId and .messages
                        $isErrorResult = $true
                    } elseif ($devResult -and $devResult.PSObject.Properties['messages']) {
                        # Single error object
                        $isErrorResult = $true
                    }

                    if ($devResult -and -not $isErrorResult) {
                        $newDeviceId = $null
                        if ($devResult.idMap) {
                            $newDeviceId = ($devResult.idMap | Select-Object -First 1).resultId
                        } elseif ($devResult.PSObject.Properties['resultId']) {
                            $newDeviceId = $devResult.resultId
                        }
                        if ($newDeviceId) {
                            $wugDeviceMap[$key] = $newDeviceId
                            $stats.DevicesCreated++
                            if (-not $dev.IP) { $stats.CloudDevices++ }
                            Write-Verbose "Created device '$displayName' (ID: $newDeviceId)"
                        } else {
                            Write-Warning "Device '$displayName' — API returned success but no device ID."
                        }
                    } else {
                        $errMsgs = @()
                        if ($devResult -is [array]) {
                            foreach ($e in $devResult) {
                                if ($e.PSObject.Properties['messages']) { $errMsgs += ($e.messages -join '; ') }
                            }
                        } elseif ($devResult -and $devResult.PSObject.Properties['messages']) {
                            $errMsgs += ($devResult.messages -join '; ')
                        }
                        $errText = if ($errMsgs.Count -gt 0) { $errMsgs -join ' | ' } else { 'Unknown error (no details returned)' }
                        Write-Warning "Failed to create device '$displayName': $errText"
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
                    $sync = Sync-WUGDiscoveryMonitorAssignments -DeviceId $deviceId -Type active -MonitorId $actMonitorIds
                    Write-Host "    $($dev.Name) active: $($sync.Assigned) assigned, $($sync.Skipped) existing, $($sync.Failed) failed" -ForegroundColor Gray
                }

                # Assign perf monitors by library ID
                $perfMonitorIds = @()
                foreach ($perfItem in @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' })) {
                    if ($perfItem.Name -and $existingPerfNames.ContainsKey($perfItem.Name)) {
                        $perfMonitorIds += [int]$existingPerfNames[$perfItem.Name]
                    }
                }
                if ($perfMonitorIds.Count -gt 0) {
                    $sync = Sync-WUGDiscoveryMonitorAssignments -DeviceId $deviceId -Type performance -MonitorId $perfMonitorIds -PerfPollingIntervalMinutes 5
                    Write-Host "    $($dev.Name) performance: $($sync.Assigned) assigned, $($sync.Skipped) existing, $($sync.Failed) failed" -ForegroundColor Gray
                }
            }
            Write-Progress -Activity 'Updating existing devices' -Completed
        }

        $inventoryPlan = Get-ProxmoxWUGInventoryPlan -DevicePlan $devicePlan -DeviceMap $wugDeviceMap
        foreach ($inventory in $inventoryPlan.Values) {
            $sync = Sync-WUGDiscoveryDeviceAttributes -DeviceId $inventory.DeviceId -Attributes $inventory.Attributes
            Write-Host "  $($inventory.Name) attributes: $($sync.Updated) written, $($sync.Unchanged) unchanged, $($sync.Failed) failed" -ForegroundColor Gray
        }

        # Group membership only; no rescan is queued, so existing monitoring is untouched.
        $proxmoxGroupName = 'Proxmox-WhatsUpGoldPS'
        $allProxmoxDeviceIds = @($wugDeviceMap.Values | Select-Object -Unique | ForEach-Object { [int]$_ })
        if ($allProxmoxDeviceIds.Count -gt 0) {
            $proxmoxGroup = Sync-WUGDiscoveryDeviceGroup -Name $proxmoxGroupName -DeviceId $allProxmoxDeviceIds `
                -Description 'Devices managed by WhatsUpGoldPS Proxmox discovery.' -Confirm:$false
            if ($proxmoxGroup.GroupId) {
                Write-Host "  Group '$proxmoxGroupName' (ID: $($proxmoxGroup.GroupId)): added $($proxmoxGroup.Added) device(s)." -ForegroundColor Gray
            }
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
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD3PeWhOQt+Wh+E
# rqU/YhuLougPZXYfGGb1mdGgnqUu3KCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCB0
# uyPUhkbMc71rg19lhwWuvHBOozfgFlcn4XFQHTX/9zANBgkqhkiG9w0BAQEFAASC
# AgDjX1LIgcRDQVkU2HksQhRcLVjQo4Wh0oztWtKFNcbQ/9yCaEcII4WzMnuvmpp1
# QpM8Qtmes9dfwUvsMJcfs7+LEzmtoAQMw4sQDLVvhqvRyoMAydQXQnYwLty6Gg/Q
# PZtlJ8CucKb8BY1psNCcwDxH43rb2MatY/hW14OHpPHw7BYXF7rk7OZ4Sh5XE6k6
# Hdx2xFV5Qg9XhF2RUzfLrpksF6Slh70Twsb9poTH4f17ITyYS5WH/bu3E8eKejNU
# J7oD6UgjNi0xAHbPdZkPy8MAK/OzGiX84384wr6TYnC7PmMUUAWPKIDBLPe+cmzx
# bTSise105/TPUSUnk6CTkewH4R0Q6RKK7u2rl6UMg8z+wPJutc+E3ymnWX8prOpT
# BS6Pb51NA8OcEJ5CBsnroLPTsHxNcK1Hsu2/fX0oKWAmIBz72k0Gavh8FEjKlNsh
# QLwZNXHXyMeeLau0jBHNHxAwTwJSWbGj/BtCymPxlgZgQtSgWVmeOl3Pue5xLEnt
# Ame81k99dtL0QNJb/QXCOg+kKwnyJAdt7iuvk8QYjA0Gp7fbKD6s0ssoLbSpGhmA
# ZEruhbTO17R5FpoeE7l4nhjB0nUY9ni1BItDREHKByZv7ToNv8E7Mv4ejAlcT8nn
# 2RVLY6h1FZ0+eG6NwQo6ybzNWfsXqzO6AITjvLXubht5oaGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMyMDIwMDRaMC8GCSqGSIb3DQEJBDEiBCD3f1hn5oy5
# 2DUxKUfm/JG5foB6z+OxQfzECl4u8IMYCTANBgkqhkiG9w0BAQEFAASCAgAjxMrn
# 4dvswVF2xsqzcJKUcMKeCP/86XJrIBTBjQUKMHEbzLUWWlFZW9l+NqPir0cQs6a9
# iMTO3gU/ApmHi3Jk1FGvJ8Di9ENlips5NswXXDETG0eJg1fMpnjCnDM5t/GLHByI
# uz+nwhjYyPfWqDquwO5Qflxl9HLrTTMKOAz6HxWNV8wB+psWmj/b6XaY4FRSeaQb
# FhoeeOAH3/6X4SOvMo/zPUinEjfqnS9a4KJJyBUvM8ck/B3DEYRBy0EuNRr+SFey
# yoJvBX3xVEMQonSES+tup1Ji4wk2kG3oPFesbUrlN2PQSTvp9yQ7DwQdXgIZan9b
# GfwlBYEXxCM5Jip71qtc0YEdC6Q6F0U7CNS7OJ/k5UzBBC1hkex5/aPHmPoxD0bi
# znM0kU+DYEHdb06ACUgId1k+P7v+wzmjYPeSIRFR6X3xE09HQfb0W8uOZEvAm7Cl
# Ljgs5lHbxzpmfYEdAfko7rxed8KDOr0k1pRvvvKkqiPNkAay0kmSJoLGwfKYfsM6
# 30kJJiclq8HruEh1Fh52b+qTMWuxcnlrRFxWPSf+ymRL4+4mXzH2UPrfwxoT+pKX
# b0m0mIrTqzD5VIZl7gf52UPe0lQCNdLlLgcKkPzpgGw2Yo5sPh8bdNUNxadigaaV
# eeGkLD8Dx731d0k2Nt3bXcaNEGZekNaPUt6BvA==
# SIG # End signature block
