<#
.SYNOPSIS
    Kemp LoadMaster Discovery - Discover appliance, virtual services,
    sub-VS, and real servers, then optionally push to WhatsUp Gold.

.DESCRIPTION
    Interactive script that discovers LoadMaster infrastructure via the
    RESTful APIv2, then lets you choose what to do with the results:

      [1] Push monitors to WhatsUp Gold (creates devices + monitors)
      [2] Export discovery plan to JSON
      [3] Export discovery plan to CSV
      [4] Show full plan table in console
      [5] Generate HTML dashboard (live metrics)
      [6] Exit
      [7] Dashboard + Push to WUG

    Architecture (when pushed to WUG):
      [LoadMaster Device]
          |-- "LM Health [hostname]"             (Active Monitor)
          |-- "LM CPU % [hostname]"              (Perf Monitor)
          |-- "LM Active Conns [hostname]"       (Perf Monitor)
          |-- "LM TPS [hostname]"                (Perf Monitor)
      [VS Device: WebApp]
          |-- "LM VS Health [WebApp]"            (Active Monitor)
          |-- "LM VS Active Conns [WebApp]"      (Perf Monitor)
          |-- "LM VS Conns/sec [WebApp]"         (Perf Monitor)
      [RS Device: 10.0.0.10:8080]
          |-- "LM RS Active Conns [10.0.0.10:8080 on WebApp]"  (Perf Monitor)
          |-- "LM RS Connections [10.0.0.10:8080 on WebApp]"   (Perf Monitor)

    Authentication:
      - API Key (recommended for WUG monitoring)
      - Basic Auth (bal:password) for standalone discovery

    First Run:
      1. Prompts for LoadMaster host, port, auth method
      2. Stores credentials in DPAPI vault
      3. Discovers appliance + VS + RS hierarchy
      4. Shows summary, then asks what to do

    Subsequent Runs:
      Loads credentials from vault automatically.

.PARAMETER Target
    LoadMaster host(s) - IP address or FQDN. Accepts multiple values.

.PARAMETER ApiPort
    LoadMaster API port. Default: 443.

.PARAMETER AuthMethod
    Authentication method: 'ApiKey' (default) or 'Password'.

.PARAMETER Action
    What to do with results. When specified, skips the interactive menu.
    Valid: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, None.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: 192.168.74.74.

.PARAMETER WUGCredential
    PSCredential for WhatsUp Gold admin login.

.PARAMETER OutputPath
    Directory for export files and dashboards.

.PARAMETER NonInteractive
    Suppress all prompts. Uses cached vault credentials.

.EXAMPLE
    .\Setup-LoadMaster-Discovery.ps1
    # Interactive mode.

.EXAMPLE
    .\Setup-LoadMaster-Discovery.ps1 -Target 10.0.0.5 -Action PushToWUG -WUGServer 192.168.74.74

.EXAMPLE
    .\Setup-LoadMaster-Discovery.ps1 -Target 10.0.0.5 -AuthMethod Password -Action Dashboard

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: LoadMaster firmware 7.2.50+ for APIv2 JSON support.
    Encoding: UTF-8 with BOM
#>
[CmdletBinding()]
param(
    [string[]]$Target,

    [int]$ApiPort = 443,

    [ValidateSet('ApiKey', 'Password')]
    [string]$AuthMethod = 'ApiKey',

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string]$WUGServer = '192.168.74.74',

    [PSCredential]$WUGCredential,

    [string]$OutputPath,

    [switch]$NonInteractive
)

# --- Output directory ---------------------------------------------------------
if (-not $OutputPath) {
    if ($NonInteractive) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    } else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutputDir = $OutputPath

# --- Load helpers -------------------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-LoadMaster.ps1')

# Load dynamic dashboard generator
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# ==============================================================================
# STEP 1: Gather target info
# ==============================================================================
Write-Host "=== Kemp LoadMaster Discovery ===" -ForegroundColor Cyan
Write-Host ""

# --- Resolve LoadMaster host(s) -----------------------------------------------
$DefaultHost = '10.0.0.1'
if ($Target) {
    $LMHosts = @($Target)
}
elseif ($NonInteractive) {
    Write-Error 'No -Target specified for non-interactive mode. Exiting.'
    return
}
else {
    Write-Host "Enter LoadMaster host(s) - IP address or FQDN." -ForegroundColor Cyan
    Write-Host "For multiple hosts, separate with commas." -ForegroundColor Gray
    $hostInput = Read-Host -Prompt "LoadMaster host(s)"
    if ([string]::IsNullOrWhiteSpace($hostInput)) {
        Write-Error 'No host provided. Exiting.'
        return
    }
    $LMHosts = @($hostInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($LMHosts.Count -eq 0) {
    Write-Error 'No valid host provided. Exiting.'
    return
}
Write-Host "Targets: $($LMHosts -join ', ')" -ForegroundColor Cyan
Write-Host ""

# --- Resolve port --------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('ApiPort') -and -not $NonInteractive) {
    $portInput = Read-Host -Prompt "LoadMaster API port [default: $ApiPort]"
    if ($portInput -and $portInput -match '^\d+$') {
        $ApiPort = [int]$portInput
    }
}

# ==============================================================================
# STEP 2: Authentication (API Key OR bal:password)
# ==============================================================================
$LMCredential = $null
$LMApiKey = $null

$authChoice = if ($AuthMethod -eq 'Password') { '2' } else { '1' }
if (-not $PSBoundParameters.ContainsKey('AuthMethod') -and -not $NonInteractive) {
    Write-Host ""
    Write-Host "Authentication method:" -ForegroundColor Cyan
    Write-Host "  [1] API Key (recommended for WUG monitoring)" -ForegroundColor White
    Write-Host "  [2] bal:password (standalone discovery or Basic Auth in WUG)" -ForegroundColor White
    Write-Host ""
    $authChoice = Read-Host -Prompt "Choice [1/2, default: 1]"
}

if ($authChoice -eq '2') {
    # Basic Auth (bal:password) - vault-backed
    $pwVaultName = "LoadMaster.$($LMHosts[0]).Credential"
    $credSplat = @{ Name = $pwVaultName; CredType = 'PSCredential'; ProviderLabel = 'LoadMaster' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    elseif ($Action) { $credSplat.AutoUse = $true }
    $psCred = Resolve-DiscoveryCredential @credSplat
    if (-not $psCred) {
        Write-Error 'No LoadMaster credentials available. Exiting.'
        return
    }
    $LMCredential = $psCred
    Write-Host "Using bal:password auth for discovery." -ForegroundColor Green
}
else {
    # API Key auth (default)
    $vaultName = "LoadMaster.$($LMHosts[0]).ApiKey"
    $credSplat = @{ Name = $vaultName; CredType = 'BearerToken'; ProviderLabel = 'LoadMaster' }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    elseif ($Action) { $credSplat.AutoUse = $true }
    $LMApiKey = Resolve-DiscoveryCredential @credSplat
    if (-not $LMApiKey) {
        Write-Error 'No LoadMaster API key. Exiting.'
        return
    }
}

# Build credential hashtable for Invoke-Discovery
$discoveryCred = @{}
if ($LMApiKey) {
    $discoveryCred['ApiKey'] = $LMApiKey
}
elseif ($LMCredential) {
    $discoveryCred['UserName'] = $LMCredential.UserName
    $discoveryCred['Password'] = $LMCredential.Password
}

# ==============================================================================
# STEP 3: Discover - query LoadMaster API
# ==============================================================================
Write-Host ""
Write-Host "Querying LoadMaster at $($LMHosts -join ', ')..." -ForegroundColor Cyan

$allPlan = @()
foreach ($lmHost in $LMHosts) {
    $plan = Invoke-Discovery -ProviderName 'LoadMaster' `
        -Target @($lmHost) `
        -ApiPort $ApiPort `
        -Credential $discoveryCred

    if ($plan -and $plan.Count -gt 0) {
        $allPlan += $plan
    }
}
$plan = $allPlan

if (-not $plan -or $plan.Count -eq 0) {
    Write-Warning "No items discovered. Check LoadMaster connectivity and credentials."
    return
}

# ==============================================================================
# STEP 4: Show the plan
# ==============================================================================

# Group items by device
$devicePlan = [ordered]@{}

foreach ($item in $plan) {
    $type = $item.Attributes['LoadMaster.DeviceType']
    switch ($type) {
        'Appliance' {
            $key  = "appliance:$($item.Attributes['LoadMaster.ApiHost'])"
            $name = $item.Attributes['LoadMaster.Hostname']
            $ip   = $item.Attributes['LoadMaster.ApiHost']
        }
        'VirtualService' {
            $vsIdx = $item.Attributes['LoadMaster.VSIndex']
            $key   = "vs:$($item.Attributes['LoadMaster.ApiHost']):${vsIdx}"
            $name  = if ($item.Attributes['LoadMaster.VSNickName']) {
                $item.Attributes['LoadMaster.VSNickName']
            } else {
                "$($item.Attributes['LoadMaster.VSAddress']):$($item.Attributes['LoadMaster.VSPort'])"
            }
            $ip = $item.Attributes['LoadMaster.VSAddress']
        }
        'SubVirtualService' {
            $subIdx = $item.Attributes['LoadMaster.VSIndex']
            $key    = "subvs:$($item.Attributes['LoadMaster.ApiHost']):${subIdx}"
            $name   = "SubVS-${subIdx}"
            $ip     = $item.Attributes['LoadMaster.ApiHost']
        }
        'RealServer' {
            $rsAddr = $item.Attributes['LoadMaster.RSAddress']
            $rsPort = $item.Attributes['LoadMaster.RSPort']
            $rsIdx  = $item.Attributes['LoadMaster.RSIndex']
            $parentVS = $item.Attributes['LoadMaster.ParentVSIndex']
            $key  = "rs:$($item.Attributes['LoadMaster.ApiHost']):vs${parentVS}:${rsIdx}"
            $name = "${rsAddr}:${rsPort}"
            $ip   = $rsAddr
        }
        default { continue }
    }
    if (-not $devicePlan.Contains($key)) {
        $devicePlan[$key] = @{
            Name  = $name
            IP    = $ip
            Type  = $type
            Attrs = $item.Attributes
            Items = [System.Collections.ArrayList]@()
        }
    }
    [void]$devicePlan[$key].Items.Add($item)
}

$appDevices  = @($devicePlan.Values | Where-Object { $_.Type -eq 'Appliance' })
$vsDevices   = @($devicePlan.Values | Where-Object { $_.Type -eq 'VirtualService' })
$subVSDevs   = @($devicePlan.Values | Where-Object { $_.Type -eq 'SubVirtualService' })
$rsDevices   = @($devicePlan.Values | Where-Object { $_.Type -eq 'RealServer' })

$activeTemplates = @($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)
$perfTemplates   = @($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } | Select-Object -ExpandProperty Name -Unique)

Write-Host ""
Write-Host "Discovery complete!" -ForegroundColor Green
Write-Host "  Appliances:             $($appDevices.Count)" -ForegroundColor White
Write-Host "  Virtual Services:       $($vsDevices.Count)" -ForegroundColor White
Write-Host "  Sub-Virtual Services:   $($subVSDevs.Count)" -ForegroundColor White
Write-Host "  Real Servers:           $($rsDevices.Count)" -ForegroundColor White
Write-Host "  Total WUG devices:      $($devicePlan.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  Active monitor templates:  $($activeTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'ActiveMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Perf monitor templates:    $($perfTemplates.Count)  ($(@($plan | Where-Object { $_.ItemType -eq 'PerformanceMonitor' }).Count) assignments)" -ForegroundColor White
Write-Host "  Total plan items:          $($plan.Count)" -ForegroundColor White
Write-Host ""

# Per-device summary
$devicePlan.Values | Sort-Object @{E={$_.Type}}, @{E={$_.Name}} |
    ForEach-Object { [PSCustomObject]@{
        Device   = $_.Name
        Type     = $_.Type
        IP       = if ($_.IP) { $_.IP } else { '0.0.0.0' }
        Monitors = $_.Items.Count
    }} |
    Format-Table -AutoSize

# ==============================================================================
# STEP 5: Export or push to WUG
# ==============================================================================

$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG'      { $choice = '1' }
        'ExportJSON'     { $choice = '2' }
        'ExportCSV'      { $choice = '3' }
        'ShowTable'      { $choice = '4' }
        'Dashboard'      { $choice = '5' }
        'None'           { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice) {
    Write-Host "What would you like to do?" -ForegroundColor Cyan
    Write-Host "  [1] Push monitors to WhatsUp Gold"
    Write-Host "  [2] Export plan to JSON file"
    Write-Host "  [3] Export plan to CSV file"
    Write-Host "  [4] Show full plan table"
    Write-Host "  [5] Generate HTML dashboard (live metrics)"
    Write-Host "  [6] Exit (do nothing)"
    Write-Host "  [7] Dashboard + Push to WUG"
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-7]"
}

# Handle DashboardAndPush
if ($choice -eq '7') {
    $actionsToRun = @('5', '1')
} else {
    $actionsToRun = @($choice)
}

foreach ($currentChoice in $actionsToRun) {
switch ($currentChoice) {
    '1' {
        # ==================================================================
        # PushToWUG
        # ==================================================================
        Write-Host "Loading WhatsUpGoldPS module..." -ForegroundColor Cyan
        try {
            $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
            if (Test-Path $repoPsd1) {
                Import-Module $repoPsd1 -Force -ErrorAction Stop
            } else {
                Import-Module WhatsUpGoldPS -ErrorAction Stop
            }
        }
        catch {
            Write-Error "Could not load WhatsUpGoldPS module: $_"
            return
        }
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }

        if ($WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors
        } else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors
        }

        $stats = @{
            HealthCreated = 0; HealthSkipped = 0; HealthFailed = 0
            PerfCreated   = 0; PerfSkipped   = 0; PerfFailed   = 0
            DevicesCreated = 0; DevicesFound = 0
            CredsAssigned = 0
        }
        $wugDeviceMap = @{}

        # ---- 1. Create/find REST API credential ----------------------------
        Write-Host ""
        Write-Host "Setting up LoadMaster REST API credential in WUG..." -ForegroundColor Cyan

        $credName = "LoadMaster REST API - $($LMHosts[0])"
        $lmCredId = $null

        # Search for existing
        try {
            $existingCreds = @(Get-WUGCredential -Type restapi -SearchValue $credName -View basic)
            if ($existingCreds.Count -eq 0) {
                $existingCreds = @(Get-WUGCredential -SearchValue $credName -View basic)
            }
            if ($existingCreds.Count -gt 0) {
                $matchCred = $existingCreds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                if ($matchCred) {
                    $lmCredId = $matchCred.id
                    Write-Host "  Found existing credential '$credName' (ID: $lmCredId)" -ForegroundColor Green
                }
            }
        }
        catch { Write-Verbose "Credential search error: $_" }

        if (-not $lmCredId) {
            Write-Host "  Creating credential '$credName'..." -ForegroundColor Yellow
            try {
                if ($LMApiKey) {
                    # API Key mode: store key as password, username is a placeholder
                    $credResult = Add-WUGCredential -Name $credName `
                        -Description "LoadMaster API Key (auto-created by discovery)" `
                        -Type restapi `
                        -RestApiUsername 'apikey' `
                        -RestApiPassword $LMApiKey `
                        -RestApiAuthType '0' `
                        -RestApiIgnoreCertErrors 'True'
                }
                else {
                    # Basic Auth mode: bal:password
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($LMCredential.Password)
                    $plainPw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    $credResult = Add-WUGCredential -Name $credName `
                        -Description "LoadMaster Basic Auth (auto-created by discovery)" `
                        -Type restapi `
                        -RestApiUsername $LMCredential.UserName `
                        -RestApiPassword $plainPw `
                        -RestApiAuthType '0' `
                        -RestApiIgnoreCertErrors 'True'
                }
                if ($credResult) {
                    if ($credResult.PSObject.Properties['data']) {
                        $lmCredId = $credResult.data.idMap.resultId
                    } elseif ($credResult.PSObject.Properties['resourceId']) {
                        $lmCredId = $credResult.resourceId
                    } elseif ($credResult.PSObject.Properties['id']) {
                        $lmCredId = $credResult.id
                    }
                    if ($lmCredId) {
                        Write-Host "  Created credential (ID: $lmCredId)" -ForegroundColor Green
                    }
                }
            }
            catch {
                Write-Verbose "Standard credential creation failed: $_"
            }

            # Fallback: PATCH template
            if (-not $lmCredId) {
                try {
                    $credUsername = if ($LMApiKey) { 'apikey' } else { $LMCredential.UserName }
                    $credPassword = if ($LMApiKey) { $LMApiKey } else {
                        $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($LMCredential.Password)
                        $p = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
                        $p
                    }
                    $credTpl = @{
                        templateId   = 'lm_restapi_1'
                        name         = $credName
                        description  = 'LoadMaster REST API (auto-created by discovery)'
                        type         = 'restapi'
                        propertyBags = @(
                            @{ name = 'CredRestAPI:Username'; value = $credUsername }
                            @{ name = 'CredRestAPI:Password'; value = $credPassword }
                            @{ name = 'CredRestAPI:Authtype'; value = '0' }
                            @{ name = 'CredRestAPI:IgnoreCertificateErrorsForOAuth2Token'; value = 'True' }
                        )
                    }
                    $credBody = @{ credentials = @($credTpl) } | ConvertTo-Json -Depth 5
                    $credUri  = "${global:WhatsUpServerBaseURI}/api/v1/credentials/-/config/template"
                    $tplResult = Get-WUGAPIResponse -Uri $credUri -Method 'PATCH' -Body $credBody
                    if ($tplResult.data -and $tplResult.data.idMap) {
                        $lmCredId = ($tplResult.data.idMap | Select-Object -First 1).resultId
                        Write-Host "  Created credential via template (ID: $lmCredId)" -ForegroundColor Green
                    }
                }
                catch { Write-Verbose "Template credential creation also failed: $_" }
            }

            # Re-search fallback
            if (-not $lmCredId) {
                try {
                    $recheck = @(Get-WUGCredential -SearchValue $credName -View basic)
                    $match = $recheck | Where-Object { $_.name -eq $credName } | Select-Object -First 1
                    if ($match) {
                        $lmCredId = $match.id
                        Write-Host "  Found credential '$credName' after creation (ID: $lmCredId)" -ForegroundColor Green
                    }
                }
                catch { }
            }

            if (-not $lmCredId) {
                Write-Warning "Could not create REST API credential. Create it manually in WUG."
            }
        }

        # ---- 2a. Create active monitors in library (bulk) ------------------
        Write-Host ""
        Write-Host "Creating active monitor templates in WUG library..." -ForegroundColor Cyan

        $uniqueActiveMonitors = @{}
        foreach ($item in $plan) {
            if ($item.ItemType -eq 'ActiveMonitor' -and -not $uniqueActiveMonitors.ContainsKey($item.Name)) {
                $uniqueActiveMonitors[$item.Name] = $item
            }
        }

        # Check existing active monitors
        $existingActiveNames = @{}
        try {
            foreach ($actName in $uniqueActiveMonitors.Keys) {
                $searchUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-?type=active&view=basic&search=$([uri]::EscapeDataString($actName))"
                $searchResult = Get-WUGAPIResponse -Uri $searchUri -Method GET -ErrorAction SilentlyContinue
                if ($searchResult.data.activeMonitors) {
                    $exact = $searchResult.data.activeMonitors | Where-Object { $_.name -eq $actName } | Select-Object -First 1
                    if ($exact) {
                        $existingActiveNames[$actName] = [int]$exact.id
                        $stats.HealthSkipped++
                    }
                }
            }
        }
        catch { Write-Verbose "Active monitor search error: $_" }

        $toCreateActive = @($uniqueActiveMonitors.Keys | Where-Object { -not $existingActiveNames.ContainsKey($_) })
        Write-Host "  Existing: $($existingActiveNames.Count) | New: $($toCreateActive.Count)" -ForegroundColor DarkGray

        if ($toCreateActive.Count -gt 0) {
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
                    description     = 'LoadMaster REST API active monitor (auto-created by discovery)'
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
                foreach ($actName in $toCreateActive) {
                    if ($existingActiveNames.ContainsKey($actName)) { continue }
                    $actItem = $uniqueActiveMonitors[$actName]
                    try {
                        $actParams = @{ Type = $actItem.MonitorType; Name = $actName; ErrorAction = 'Stop' }
                        foreach ($ak in $actItem.MonitorParams.Keys) {
                            if ($ak -ne 'Name' -and $ak -ne 'Description') { $actParams[$ak] = $actItem.MonitorParams[$ak] }
                        }
                        $monLibId = Add-WUGActiveMonitor @actParams
                        if ($monLibId) {
                            $existingActiveNames[$actName] = [int]$monLibId
                            $stats.HealthCreated++
                        }
                    }
                    catch {
                        Write-Warning "Failed to create active monitor '$actName': $_"
                        $stats.HealthFailed++
                    }
                }
            }
        }

        Write-Host "  Active monitors: $($stats.HealthCreated) created, $($stats.HealthSkipped) existing, $($stats.HealthFailed) failed" -ForegroundColor $(if ($stats.HealthFailed -gt 0) { 'Yellow' } else { 'Green' })

        # ---- 2b. Create performance monitors in library (bulk) -------------
        Write-Host ""
        Write-Host "Creating performance monitor templates in WUG library..." -ForegroundColor Cyan

        $uniquePerfMonitors = @{}
        foreach ($item in $plan) {
            if ($item.ItemType -eq 'PerformanceMonitor' -and -not $uniquePerfMonitors.ContainsKey($item.Name)) {
                $uniquePerfMonitors[$item.Name] = $item
            }
        }

        $existingPerfNames = @{}
        try {
            foreach ($perfName in $uniquePerfMonitors.Keys) {
                $searchUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-?type=performance&view=basic&search=$([uri]::EscapeDataString($perfName))"
                $searchResult = Get-WUGAPIResponse -Uri $searchUri -Method GET -ErrorAction SilentlyContinue
                if ($searchResult.data.performanceMonitors) {
                    $exact = $searchResult.data.performanceMonitors | Where-Object { $_.name -eq $perfName } | Select-Object -First 1
                    if ($exact) {
                        $existingPerfNames[$perfName] = [int]$exact.id
                        $stats.PerfSkipped++
                    }
                }
            }
        }
        catch { Write-Verbose "Perf monitor search error: $_" }

        $toCreatePerf = @($uniquePerfMonitors.Keys | Where-Object { -not $existingPerfNames.ContainsKey($_) })
        Write-Host "  Existing: $($existingPerfNames.Count) | New: $($toCreatePerf.Count)" -ForegroundColor DarkGray

        if ($toCreatePerf.Count -gt 0) {
            $perfTemplateArr = @()
            $perfTplIdMap = @{}
            $perfTplIdx = 0
            foreach ($perfName in $toCreatePerf) {
                $perfItem = $uniquePerfMonitors[$perfName]
                $mp = $perfItem.MonitorParams
                $tplId = "perf_$perfTplIdx"
                $perfTplIdMap[$tplId] = $perfName
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
                    name            = $perfName
                    description     = 'LoadMaster REST API perf monitor (auto-created by discovery)'
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
                    if ($perfTemplateArr.Count -gt $batchSize) {
                        $batchNum = [Math]::Floor($bi / $batchSize) + 1
                        $totalBatches = [Math]::Ceiling($perfTemplateArr.Count / $batchSize)
                        Write-Host "      Batch $batchNum/$totalBatches ($($perfBatch.Count) monitors)..." -ForegroundColor DarkGray
                    }

                    $bulkPerfResult = Add-WUGMonitorTemplate -PerformanceMonitors $perfBatch
                    if ($bulkPerfResult.idMap) {
                        foreach ($mapping in $bulkPerfResult.idMap) {
                            $tplId = $mapping.templateId
                            $resultId = $mapping.resultId
                            if ($perfTplIdMap.ContainsKey($tplId) -and $resultId) {
                                $perfName = $perfTplIdMap[$tplId]
                                $existingPerfNames[$perfName] = [int]$resultId
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
                foreach ($perfName in $toCreatePerf) {
                    if ($existingPerfNames.ContainsKey($perfName)) { continue }
                    $perfItem = $uniquePerfMonitors[$perfName]
                    try {
                        $perfParams = @{ Type = 'RestApi'; Name = $perfName; ErrorAction = 'Stop' }
                        foreach ($pk in $perfItem.MonitorParams.Keys) {
                            if ($pk -ne 'Name' -and $pk -ne 'Description') { $perfParams[$pk] = $perfItem.MonitorParams[$pk] }
                        }
                        $monLibId = Add-WUGPerformanceMonitor @perfParams
                        if ($monLibId) {
                            $existingPerfNames[$perfName] = [int]$monLibId
                            $stats.PerfCreated++
                        }
                    }
                    catch {
                        Write-Warning "Failed to create perf monitor '$perfName': $_"
                        $stats.PerfFailed++
                    }
                }
            }
        }

        Write-Host "  Perf monitors: $($stats.PerfCreated) created, $($stats.PerfSkipped) existing, $($stats.PerfFailed) failed" -ForegroundColor $(if ($stats.PerfFailed -gt 0) { 'Yellow' } else { 'Green' })

        # ---- 2c-e. Create/update devices -----------------------------------
        Write-Host ""
        Write-Host "Creating/updating devices in WUG..." -ForegroundColor Cyan

        $deviceKeys = @($devicePlan.Keys | Sort-Object)
        foreach ($key in $deviceKeys) {
            $dev = $devicePlan[$key]
            $devIP = if ($dev.IP) { $dev.IP } else { '0.0.0.0' }
            $devName = "$($dev.Name) ($($dev.Type))"

            # Check if device exists
            $existingDevId = $null
            try {
                $searchDevs = @(Get-WUGDevice -SearchValue $devName -Column DisplayName -View basic)
                if ($searchDevs.Count -gt 0) {
                    $existingDevId = $searchDevs[0].id
                }
            }
            catch { }

            # Try by IP if name search failed and IP is not 0.0.0.0
            if (-not $existingDevId -and $devIP -ne '0.0.0.0') {
                try {
                    $searchDevs = @(Get-WUGDevice -SearchValue $devIP -Column NetworkAddress -View basic)
                    if ($searchDevs.Count -gt 0) {
                        $existingDevId = $searchDevs[0].id
                    }
                }
                catch { }
            }

            if ($existingDevId) {
                Write-Host "    Found: $devName (ID: $existingDevId)" -ForegroundColor DarkGray
                $stats.DevicesFound++
                $wugDeviceMap[$key] = $existingDevId
            }
            else {
                # Create new device
                Write-Host "    Creating: $devName ($devIP)" -ForegroundColor Yellow
                try {
                    $devAttrs = @()
                    if ($dev.Attrs) {
                        foreach ($ak in $dev.Attrs.Keys) {
                            $devAttrs += @{ name = $ak; value = "$($dev.Attrs[$ak])" }
                        }
                    }

                    # Collect monitor names for this device
                    $devActiveNames = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)
                    $devPerfNames   = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } | Select-Object -ExpandProperty Name -Unique)

                    $splat = @{
                        displayName            = $devName
                        DeviceAddress          = $devIP
                        Hostname               = $dev.Name
                        Brand                  = 'LoadMaster'
                        Note                   = "LoadMaster $($dev.Type) (auto-created by discovery)"
                        Attributes             = $devAttrs
                        NoDefaultActiveMonitor = $true
                    }
                    if ($devActiveNames.Count -gt 0) { $splat['ActiveMonitors'] = $devActiveNames }
                    if ($devPerfNames.Count -gt 0)   { $splat['PerformanceMonitors'] = $devPerfNames }
                    if ($lmCredId) { $splat['CredentialRestApi'] = $credName }

                    $newDev = Add-WUGDeviceTemplate @splat
                    if ($newDev) {
                        $newDevId = $null
                        if ($newDev.PSObject.Properties['data']) { $newDevId = $newDev.data.idMap.resultId }
                        elseif ($newDev.PSObject.Properties['id']) { $newDevId = $newDev.id }
                        if ($newDevId) {
                            $wugDeviceMap[$key] = $newDevId
                            $stats.DevicesCreated++
                            Write-Host "    Created device (ID: $newDevId)" -ForegroundColor Green
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to create device '$devName': $_"
                }
            }

            # Assign credential and monitors to existing devices
            if ($existingDevId) {
                $wugDevId = $existingDevId

                # Assign credential
                if ($lmCredId) {
                    try {
                        Set-WUGDeviceCredential -DeviceId $wugDevId -CredentialId $lmCredId -Assign
                        $stats.CredsAssigned++
                    }
                    catch { Write-Verbose "Credential assignment error for device $wugDevId : $_" }
                }

                # Assign active monitors
                $devActiveNames = @($dev.Items | Where-Object { $_.ItemType -eq 'ActiveMonitor' } | Select-Object -ExpandProperty Name -Unique)
                $activeIds = @()
                foreach ($an in $devActiveNames) {
                    if ($existingActiveNames.ContainsKey($an)) { $activeIds += $existingActiveNames[$an] }
                }
                if ($activeIds.Count -gt 0) {
                    try { Add-WUGActiveMonitorToDevice -DeviceId $wugDevId -MonitorId $activeIds } catch { Write-Verbose "Active monitor assign error: $_" }
                }

                # Assign perf monitors
                $devPerfNames = @($dev.Items | Where-Object { $_.ItemType -eq 'PerformanceMonitor' } | Select-Object -ExpandProperty Name -Unique)
                $perfIds = @()
                foreach ($pn in $devPerfNames) {
                    if ($existingPerfNames.ContainsKey($pn)) { $perfIds += $existingPerfNames[$pn] }
                }
                if ($perfIds.Count -gt 0) {
                    try { Add-WUGPerformanceMonitorToDevice -DeviceId $wugDevId -MonitorId $perfIds -PollingIntervalMinutes 5 } catch { Write-Verbose "Perf monitor assign error: $_" }
                }
            }
        }

        Write-Host ""
        Write-Host "=== WUG Push Summary ===" -ForegroundColor Cyan
        Write-Host "  Devices created:     $($stats.DevicesCreated)" -ForegroundColor White
        Write-Host "  Devices found:       $($stats.DevicesFound)" -ForegroundColor White
        Write-Host "  Active monitors:     $($stats.HealthCreated) created, $($stats.HealthSkipped) existing" -ForegroundColor White
        Write-Host "  Perf monitors:       $($stats.PerfCreated) created, $($stats.PerfSkipped) existing" -ForegroundColor White
        Write-Host "  Credentials assigned: $($stats.CredsAssigned)" -ForegroundColor White
        Write-Host ""
    }

    '2' {
        # Export JSON
        $jsonPath = Join-Path $OutputDir "LoadMaster-Discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath
        Write-Host "  Exported: $jsonPath" -ForegroundColor Green
    }

    '3' {
        # Export CSV
        $csvPath = Join-Path $OutputDir "LoadMaster-Discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath
        Write-Host "  Exported: $csvPath" -ForegroundColor Green
    }

    '4' {
        # Show Table
        $plan | Export-DiscoveryPlan -Format Table
    }

    '5' {
        # Dashboard
        Write-Host "Generating LoadMaster dashboard..." -ForegroundColor Cyan
        $dashPath = Join-Path $OutputDir "LoadMaster-Dashboard-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

        # Build API params
        $dashSplat = @{
            LMHost           = $LMHosts[0]
            LMPort           = $ApiPort
            OutputPath       = $dashPath
            IgnoreCertErrors = $true
        }
        if ($LMApiKey)     { $dashSplat['ApiKey'] = $LMApiKey }
        if ($LMCredential) { $dashSplat['Credential'] = $LMCredential }

        Export-LoadMasterDashboardHtml @dashSplat

        # Copy to WUG NmConsole if available
        $wugHtmlDir = "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole\dashboards"
        if (Test-Path $wugHtmlDir) {
            $wugDashPath = Join-Path $wugHtmlDir 'LoadMaster-Dashboard.html'
            Copy-Item -Path $dashPath -Destination $wugDashPath -Force
            Write-Host "  Copied to WUG: $wugDashPath" -ForegroundColor Green
        }
        $wugHtmlDir86 = "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole\dashboards"
        if (Test-Path $wugHtmlDir86) {
            $wugDashPath = Join-Path $wugHtmlDir86 'LoadMaster-Dashboard.html'
            Copy-Item -Path $dashPath -Destination $wugDashPath -Force
            Write-Host "  Copied to WUG: $wugDashPath" -ForegroundColor Green
        }
    }

    default {
        Write-Host "No action taken." -ForegroundColor DarkGray
    }
}
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDYRQ7qTsi1Wr5E
# eu7FS2HlMtkgOfwzcufrRsZerVb+b6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDg7EKTFhsoJI6a6BL46iRgcK0PFs0ddWFyCBg9UiJYsTANBgkqhkiG9w0BAQEF
# AASCAgBZd40mp+PCZ4ZIWde0Rirm9JBsHmC/BZ+P190YVC7kVaNVe9rbMesuge/2
# oc2fzrc/un1wLwuKALtqlRK0NIxAQNsDVfRC3zEuKbG5lQVMHwY6YIA2U/ddY4Ke
# ZKQQ6HoHMrUBWZxowlQ9sJ7gopE7cHaD05NboDXyYke21hBDeA3le8TYT+8z2ytO
# 8lFYWedeLbHKoAyvNzyRcpW37v28QvYuhxzLNt52mCGNdk9XzhXnSfy+rD1pMtRh
# 6nIdVXBPgtGJ+6fQ5038CuILI17uvhxE8KIy4KgNVxjgommoT1181XRMf9NE+nXz
# InQm8kLZeCgug7++B6WzM4mGyNBkujtRjLnX9yWv4XmXBRls8bRJ989nkIkCQjgr
# W8O0ToYuCSw6q+7tbrldFrVL9Cc4LEShGNwc4c8T4AVdliKSvpqBT5CVWT/X5E/D
# iy9v+tp1Xbf2MG4X4p9IMrqBR7d7TYIWuMXugpPqc3ydzYsVLHzj5D1iooahPUvf
# PTircqd8r/EGtfBZlmqh5EEAqKIXHyJG9ufI7QsJRqxInDzGMCmYQKwv/R2eZJNN
# zzY4/vSEadZzJr73FW5BC2t85Wu4zoKNsduB1179m31MHLZymU1Xu+BShzC31SvH
# wSZfRx9LCLByexdxFOaCn5gBP764L9q2bp5cpY5muqc8IuNm6KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MjQxNzQwNTlaMC8GCSqGSIb3DQEJBDEiBCANx0DL
# qq481bfP2REC1ZsXG2ZCzxr6upTQo1r78RsG4DANBgkqhkiG9w0BAQEFAASCAgCO
# QKc/zKDtS9BljvDlSpdEY+EaXKI2r9A+dnwE55JUQpjn6GjvzV9yZwxL4gzVRbLx
# ygArt+B7cQ8HXwfB+L98z57PQWd+BkyX9sttOILcABlwT1nAfnTDx/DZl2TXl/yV
# hGgszh9gWm2SCofp4MDNhE9bbAlpLMyPBtvu2BlT4tgkuAahr4+hHXrP22sRxq1z
# 70N4Z6wSrKiwVukHgCms1WAqNaeAfbKfKrKvzi0HQ3ovwH2XeU7+GNAT3yUF+6hI
# e5as3XQ1GrGoo9TYeNbRffUeNU9wnYujgTWemIMsk7pqWomZGqVP+6eVlXMXdNUG
# GOWYrU9xSU/8/5hbRVjvZq0gkzh9hvTYCV8/VjIjcu/LrUE3xX6+Lj9y/aLurZTn
# aarcKK9SiVBy10t6LtV+DWcWp+M2R0GN50rNHVklUdXgiXfxJPCATGNWGI9XV1NZ
# AhibH9TWgukOaiDZmP92rhTxqPOYmZ9eUnLJhuows17h+USArBmjqzTkD74Sh0pK
# 6LxKn8yulcGm2/ZU7MImkR6OqqmyD1RO/4CJ4tJ/7ZAcr+NnLEL6dDPmchpAlkMS
# FzOEJ4SfiJfgl+cUTg0UHaZxCHdUHiR8Ygrhh/0Jqi9XYt9eF4aRc6IgoZZj6ijk
# 5cIbfAjC3l31Q6A1tpOCvqeW+8KZSvZt3cXPsQMhrA==
# SIG # End signature block
