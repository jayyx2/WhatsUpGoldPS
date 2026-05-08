# Discovery Framework — Copilot Instructions

## Overview

The discovery framework lives in `helpers/discovery/`. It follows a **provider-based architecture** that scans external APIs (cloud, hypervisor, network), stores credentials securely in a DPAPI vault, discovers infrastructure resources and metrics, then either pushes them to WhatsUp Gold for monitoring or generates standalone HTML dashboards.

**Pipeline**: `Credential Vault → Provider Scan → Discovered Items → Plan Export → Action (WUG Push / Dashboard / Export)`

## File Layout

```
helpers/discovery/
  DiscoveryHelpers.ps1                   # Core framework (vault, registry, orchestration)
  DiscoveryProvider-{Name}.ps1           # Provider: registers itself + DiscoverScript
  Setup-{Name}-Discovery.ps1            # Interactive setup wizard for a provider
  Start-WUGDiscoverySetup.ps1            # Multi-provider launcher wizard
  Register-DiscoveryScheduledTask.ps1    # Windows Task Scheduler integration
  Copy-WUGDashboardReports.ps1           # Dashboard file management helper

helpers/reports/
  Export-DynamicDashboardHtml.ps1         # Dashboard HTML generation engine
  Dynamic-Dashboard-Template.html        # Generic Bootstrap Table template
  {Name}-Dashboard-Template.html         # Provider-specific dashboard templates
```

## Architecture: Three File Types per Provider

### 1. `DiscoveryProvider-{Name}.ps1` — The Provider

Registers a provider with `Register-DiscoveryProvider` and defines two key ScriptBlocks:

- **DiscoverScript**: Receives a context object `$ctx`, authenticates to the target API, enumerates resources, validates metrics, and returns `DiscoveredItem` objects.
- **Dashboard export function**: Named `Export-{Name}DashboardHtml`, generates provider-specific dashboard HTML.

```powershell
Register-DiscoveryProvider -Name 'ProviderName' `
    -MatchAttribute 'DiscoveryHelper.ProviderName' `
    -AuthType 'BearerToken'       # or 'BasicAuth'
    -CredentialType 'restapi'     # WUG credential type
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)
        # $ctx has: DeviceIP, Credential, Port, Protocol, BaseUri, ProviderName, Options
        # Returns: array of DiscoveredItem objects
    }
```

### 2. `Setup-{Name}-Discovery.ps1` — The Setup Script

Interactive wizard that:
1. Prompts for target host(s) and credentials (or loads from vault)
2. Calls `Invoke-Discovery` to run the provider
3. Shows a summary table
4. Executes the chosen `-Action` (PushToWUG, Dashboard, ExportJSON, etc.)

### 3. Dashboard export function (in provider or `helpers/reports/`)

Generates self-contained HTML with Bootstrap Table, summary cards, thresholds, and export buttons.

## Discovery Pipeline — Step by Step

### Step 1: Credential Resolution

```
Resolve-DiscoveryCredential -Name '{VaultKey}' -CredType '{Type}'
```

1. Check local DPAPI vault (`$env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Vault\`)
2. If found → show safe preview, prompt `[Y]es / [R]eset / [N]o skip`
3. If missing → prompt for values (masked input with confirmation)
4. Save to vault (DPAPI encrypted + optional AES-256 + HMAC integrity)
5. Return credential object (varies by CredType)

**Vault Key Naming Convention:**

| Provider | CredType | Vault Key | Stored Fields |
|----------|----------|-----------|---------------|
| Azure | `AzureSP` | `Azure.{TenantId}.ServicePrincipal` | TenantId, ApplicationId, ClientSecret |
| Proxmox | `BearerToken` | `Proxmox.{Host}.Token` | API token string |
| Proxmox | `PSCredential` | `Proxmox.{Host}.Credential` | Username, Password |
| AWS | `AWSKeys` | `AWS.{Identifier}` | AccessKeyId, SecretAccessKey |
| Docker | `BearerToken` | `Docker.{Host}.Token` | API token string |
| Generic | `PSCredential` | `{Provider}.{Host}.Credential` | Username, Password |
| WUG | `WUGServer` | `WUG.{Server}` | Server, Port, Protocol, Credential, IgnoreSSL |

**CredType Return Values:**

| CredType | Returns |
|----------|---------|
| `AzureSP` | `PSCredential` — UserName = `"TenantId\|AppId"`, Password = ClientSecret |
| `BearerToken` | Plain string (raw token) |
| `PSCredential` | `PSCredential` (Username + SecureString Password) |
| `AWSKeys` | `PSCredential` — UserName = AccessKey, Password = SecretKey |
| `WUGServer` | Hashtable: `@{ Server; Port; Protocol; Credential; IgnoreSSL }` |

### Step 2: Invoke Discovery (Provider Execution)

```powershell
$plan = Invoke-Discovery -ProviderName 'Azure' -Target $targets -Credential $cred
```

Invoke-Discovery:
1. Looks up the registered provider by name
2. Builds a context object (`$ctx`) with target, credential, port, protocol, options
3. Invokes the provider's `DiscoverScript` ScriptBlock
4. The script returns `DiscoveredItem` objects

### Step 3: DiscoverScript Phases (Inside Provider)

Every provider follows this phased approach:

**Phase 1 — Authenticate & Enumerate**:
- Authenticate to the target API (OAuth2, API token, session ticket, etc.)
- Enumerate resources (subscriptions, nodes, VMs, containers, etc.)
- Resolve IP addresses where possible

**Phase 2 — Metrics Discovery**:
- Query metric definitions/endpoints for each resource
- Collect available metric names, units, aggregation types

**Phase 2.5 — Metrics Validation** (data quality gate):
- Query actual metric data (last 24h or similar window)
- Drop metrics with no data points or all-null values
- Verify numeric values exist at the expected JSON paths

**Phase 2.6 — WUG Poll Pattern Validation** (optional, Azure does this):
- Query with the exact polling window WUG will use
- Verify the field exists in the response and contains a numeric value
- Only create monitors for metrics confirmed to return data

**Phase 3 — Build Plan**:
- Create `DiscoveredItem` objects for each monitor to add
- Active monitors → up/down status checks
- Performance monitors → numeric metric collection
- Attach device attributes and tags

### Step 4: DiscoveredItem Objects

```powershell
New-DiscoveredItem -Name 'Azure Health - RG/Type/Name' `
    -ItemType 'ActiveMonitor' `          # or 'PerformanceMonitor'
    -MonitorType 'RestApi' `             # Monitor class (RestApi, TcpIp, Ping, etc.)
    -MonitorParams @{                    # Type-specific parameters
        RestUrl      = 'https://management.azure.com/...'
        JsonPath     = '$.properties.availabilityState'
        HttpMethod   = 'GET'
        Comparison   = 'Contains'
        ExpectedValue = 'Available'
    } `
    -UniqueKey 'azure-health-resourceid' `  # Idempotency key
    -Attributes @{                        # Device attributes to set
        'Azure Subscription ID' = 'xxx'
        'Cloud Type'            = 'Microsoft.Compute/virtualMachines'
    } `
    -Tags @('Azure', 'Production')
```

### Step 5: Action Dispatch

The `-Action` parameter controls what happens after discovery:

| Action | What It Does |
|--------|-------------|
| `PushToWUG` | Create devices + credentials + monitors in WhatsUp Gold |
| `Dashboard` | Generate standalone HTML dashboard |
| `DashboardAndPush` | Generate dashboard, then push to WUG |
| `ExportJSON` | Save discovery plan as JSON file |
| `ExportCSV` | Save discovery plan as CSV file |
| `ShowTable` | Display plan as formatted console table |
| `TestCredential` | Test credential round-trip in WUG (create → verify → delete) |
| `None` | Skip action (dry run) |

## PushToWUG — How It Works

This is the most complex action. It creates everything needed in WUG to monitor the discovered infrastructure.

### Flow:

```
1. Create/Find WUG Credentials
   ├── Azure SP credential (type: azure)
   └── REST API credential (type: restapi, OAuth2)

2. Bulk Create Monitors in WUG Library
   ├── Deduplicate monitor names across all devices
   ├── Check WUG library for existing monitors (skip dupes)
   ├── Batch create via Add-WUGMonitorTemplate (50 per batch)
   └── Fallback: one-at-a-time if bulk fails

3. Create Devices in WUG
   ├── Check for existing devices (by name or IP)
   ├── Create new devices (0.0.0.0 for cloud resources with no IP)
   └── Set device attributes

4. Assign Credentials to Devices
   └── Link Azure/REST API credentials to each device

5. Attach Monitors to Devices
   ├── Active monitors → Add-WUGActiveMonitorToDevice
   └── Performance monitors → Add-WUGPerformanceMonitorToDevice
```

### WUG Monitor Property Bags

**Active Monitor (REST API health check):**
```powershell
@(
    @{ name = 'MonRestApi:RestUrl';                value = 'https://...' }
    @{ name = 'MonRestApi:HttpMethod';              value = 'GET' }
    @{ name = 'MonRestApi:HttpTimeoutMs';           value = '10000' }
    @{ name = 'MonRestApi:IgnoreCertErrors';        value = '0' }
    @{ name = 'MonRestApi:UseAnonymousAccess';      value = '0' }
    @{ name = 'MonRestApi:CustomHeader';            value = '' }
    @{ name = 'MonRestApi:DownIfResponseCodeIsIn';  value = '[]' }
    @{ name = 'MonRestApi:ComparisonList';          value = '[]' }
    @{ name = 'Cred:Type';                          value = '8192' }
)
```

**Performance Monitor (REST API metric):**
```powershell
@(
    @{ name = 'RdcRestApi:RestUrl';            value = 'https://...' }
    @{ name = 'RdcRestApi:JsonPath';           value = '$.value[0].timeseries[0].data[0].average' }
    @{ name = 'RdcRestApi:HttpMethod';         value = 'GET' }
    @{ name = 'RdcRestApi:HttpTimeoutMs';      value = '10000' }
    @{ name = 'RdcRestApi:IgnoreCertErrors';   value = '0' }
    @{ name = 'RdcRestApi:UseAnonymousAccess'; value = '0' }
    @{ name = 'RdcRestApi:CustomHeader';       value = '' }
)
```

**Key difference**: Active monitors use `MonRestApi:` prefix; performance monitors use `RdcRestApi:` prefix.

### WUG Credential Types Used

**Azure Service Principal:**
```powershell
Add-WUGCredential -Name "Azure SP - $TenantId" -Type azure `
    -AzureTenantID $TenantId -AzureClientID $AppId -AzureSecureKey $ClientSecret
```

**REST API (OAuth2 — for Azure metric polling):**
```powershell
Add-WUGCredential -Name "Azure REST API - $TenantId" -Type restapi `
    -RestApiAuthType '1' -RestApiGrantType '0' `
    -RestApiTokenUrl "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -RestApiClientId $AppId -RestApiClientSecret $ClientSecret `
    -RestApiScope 'https://management.azure.com/.default'
```

**REST API (Token header — for Proxmox monitoring):**
```powershell
Add-WUGCredential -Name "Proxmox API Token" -Type restapi `
    -RestApiUsername 'api-token' -RestApiPassword $Token `
    -RestApiAuthType '0' -RestApiIgnoreCertErrors 'True'
```

## Dashboard Generation

Dashboards are self-contained HTML files using Bootstrap 5 + Bootstrap Table.

```powershell
Export-DynamicDashboardHtml -Data $planObjects `
    -Title 'Azure Infrastructure Discovery' `
    -OutputPath 'C:\Reports\azure-dashboard.html' `
    -CardGroupField 'Subscription' `
    -StatusField 'State' `
    -ThresholdField 'MetricCount' `
    -ThresholdWarning 5 -ThresholdCritical 10
```

**Features:**
- Summary cards (total count + breakdown by grouping field)
- Sortable, searchable, paginated data grid
- Threshold coloring (normal and inverted)
- Export: CSV, XLSX, JSON, TXT, TSV, SQL, PNG
- Offline mode (rewrites CDN URLs to local paths)

## Creating a New Provider — Checklist

### 1. Create `DiscoveryProvider-{Name}.ps1`

```powershell
# Dot-source dependencies
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')

# Dot-source any provider-specific helpers
$helperPath = Join-Path (Split-Path $scriptDir -Parent) '{name}\{Name}Helpers.ps1'
if (Test-Path $helperPath) { . $helperPath }

Register-DiscoveryProvider -Name '{Name}' `
    -MatchAttribute 'DiscoveryHelper.{Name}' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)
        $items = @()

        # Phase 1: Authenticate & enumerate
        # Phase 2: Discover metrics
        # Phase 2.5: Validate metrics have data
        # Phase 3: Build DiscoveredItem objects

        return $items
    }

# Dashboard export function
function Export-{Name}DashboardHtml {
    param([array]$Data, [string]$OutputPath)
    # ...
}
```

### 2. Create `Setup-{Name}-Discovery.ps1`

```powershell
param(
    [string[]]$Target,
    [int]$ApiPort = 443,
    [ValidateSet('PushToWUG','ExportJSON','ExportCSV','ShowTable','Dashboard','DashboardAndPush','None')]
    [string]$Action,
    [string]$WUGServer,
    [switch]$NonInteractive
)

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
. (Join-Path $scriptDir 'DiscoveryProvider-{Name}.ps1')

$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# 1. Resolve credentials from vault
$vaultName = "{Name}.$($Target[0]).Token"
$cred = Resolve-DiscoveryCredential -Name $vaultName -CredType 'BearerToken'

# 2. Run discovery
$plan = Invoke-Discovery -ProviderName '{Name}' -Target $Target -Credential $cred -ApiPort $ApiPort

# 3. Show summary
$plan | Export-DiscoveryPlan -Format Table

# 4. Execute action
switch ($Action) {
    'PushToWUG'      { <# Create WUG creds, monitors, devices #> }
    'Dashboard'      { <# Generate HTML dashboard #> }
    'ExportJSON'     { $plan | Export-DiscoveryPlan -Format JSON -Path $jsonPath }
    'ExportCSV'      { $plan | Export-DiscoveryPlan -Format CSV -Path $csvPath }
    'ShowTable'      { $plan | Export-DiscoveryPlan -Format Table }
}
```

### 3. Add to `Start-WUGDiscoverySetup.ps1`

Add a provider definition to the `$providerDefs` hashtable with:
- `Label`: Display name
- `Script`: Filename of setup script
- `TargetLabel`: Prompt text (e.g., "Enter host(s)")
- `CredType`: Vault credential type
- `AuthChoices`: Array of auth methods (if multiple)

### 4. Required Conventions

- **Dot-source all dependencies** at the top of every file (never assume functions are loaded)
- **Follow PS 5.1 constraints** (no ternary, no null-coalescing, no pipeline chains)
- **UTF-8 with BOM** encoding on all `.ps1` files
- **Authenticode sign** every `.ps1` file after modification
- **TLS 1.2 enforcement** before any HTTPS API calls:
  ```powershell
  if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
  }
  ```
- **Hardcode full URLs in monitors** — WUG REST API monitors only support `%Device.Address%`, `%Device.Hostname%`, and `%Credential.*%` interpolation (no custom device attributes)
- **Batch API operations** — 50 items per WUG API batch, 20 metrics per Azure API request
- **Benefit of the doubt** — include metrics for stopped/idle resources (they'll collect data when running)
- **Bulk fallback** — if batch creation fails, retry one-at-a-time

## Scheduled Task Integration

```powershell
# Register a recurring discovery sync
.\Register-DiscoveryScheduledTask.ps1 `
    -Provider '{Name}' `
    -TriggerType 'Daily' `
    -TimeOfDay '02:00' `
    -Action 'PushToWUG'
```

**Constraints:**
- Task runs as the **same Windows user** who populated the vault (DPAPI is user+machine bound)
- Use `Set-DiscoveryVaultPassword` to add AES layer for cross-account portability
- Execution: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass`
- Transcript logged to `$OutputPath\logs\DiscoverySync-{provider}_{timestamp}.log`

## Key Functions Reference

| Function | File | Purpose |
|----------|------|---------|
| `Register-DiscoveryProvider` | DiscoveryHelpers.ps1 | Register a new provider with DiscoverScript |
| `Invoke-Discovery` | DiscoveryHelpers.ps1 | Run a provider's DiscoverScript against targets |
| `New-DiscoveredItem` | DiscoveryHelpers.ps1 | Create a DiscoveredItem (monitor definition) |
| `Export-DiscoveryPlan` | DiscoveryHelpers.ps1 | Export plan as JSON/CSV/Table/Object |
| `Resolve-DiscoveryCredential` | DiscoveryHelpers.ps1 | Load or prompt for credentials (vault-backed) |
| `Save-DiscoveryCredential` | DiscoveryHelpers.ps1 | Store credential in DPAPI vault |
| `Get-DiscoveryCredential` | DiscoveryHelpers.ps1 | Retrieve credential from vault |
| `Remove-DiscoveryCredential` | DiscoveryHelpers.ps1 | Delete credential from vault |
| `Invoke-WUGDiscoverySync` | DiscoveryHelpers.ps1 | Sync plan to WUG (create/update monitors) |
| `New-WUGDiscoveryCredential` | DiscoveryHelpers.ps1 | Create WUG credential for a provider |
| `Start-WUGDiscovery` | DiscoveryHelpers.ps1 | End-to-end: discover + sync to WUG |
| `Export-DynamicDashboardHtml` | helpers/reports/ | Generate HTML dashboard from plan data |

## Vault Security Model

- **Layer 1**: DPAPI (Windows Data Protection API) — user + machine scoped
- **Layer 2** (optional): AES-256 with PBKDF2 (600k iterations, OWASP 2023)
- **Layer 3**: HMAC-SHA256 integrity verification with chain hashing
- **Location**: `$env:LOCALAPPDATA\WhatsUpGoldPS\DiscoveryHelpers\Vault\`
- **ACL**: Restricted to CurrentUser + SYSTEM + Administrators
- **Audit**: Chain-hashed `.vault-audit.log` with timestamp, action, user, machine, PID

## Common Pitfalls

1. **Don't use `Invoke-RestMethod` without TLS 1.2** — PS 5.1 defaults to TLS 1.0/1.1; Azure/cloud APIs reject it
2. **Don't assume module is loaded in helpers** — helpers run standalone; dot-source all dependencies
3. **Don't use `%DeviceAttribute%` in monitor URLs** — WUG doesn't support custom attribute interpolation in REST monitors; hardcode full URLs at discovery time
4. **Don't skip metrics validation** — some Azure metrics exist in definitions but return no data; always validate before creating monitors
5. **Don't assume bulk APIs always succeed** — implement one-at-a-time fallback
6. **Don't run scheduled tasks as a different user** — DPAPI vault is user+machine bound; use `Set-DiscoveryVaultPassword` for portability

## Reference Implementations

- **Most complete cloud provider**: `DiscoveryProvider-Azure.ps1` + `Setup-Azure-Discovery.ps1` — 3-phase metrics validation, OAuth2, Resource Health, budgets
- **Most complete on-prem provider**: `DiscoveryProvider-Proxmox.ps1` + `Setup-Proxmox-Discovery.ps1` — dual auth modes, cluster/node/VM/CT hierarchy, guest agent IP resolution
