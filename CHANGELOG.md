﻿# WhatsUpGoldPS Release History
## 0.1.21 - 2026-04-08 [Unreleased]
* Added -- New Functions (92 total exports; psm1 and psd1 in sync)
  * `Get-WUGPassiveMonitor` -- Retrieve passive monitor templates from the library (`GET /monitors/-?type=passive`), a single template by ID (`GET /monitors/{id}?type=passive`), or device assignments (`GET /devices/{id}/monitors/-?type=passive`); supports `-Search`, `-View`, `-DeviceId`, `-AssignmentView`, `-MonitorId`, pagination
  * `Set-WUGPassiveMonitor` -- Update passive monitor template definitions via `PUT /monitors/{id}?type=passive`; supports `-Name`, `-Description`, `-PropertyBags`, `-UseInDiscovery`
  * `Remove-WUGPassiveMonitor` -- Delete passive monitors from the library by search string (`DELETE /monitors/-?type=passive&search=...`) or by ID (`DELETE /monitors/{id}?type=passive`); supports `-FailIfInUse`
  * `Add-WUGMonitorTemplate` -- Bulk create multiple active, passive, and/or performance monitors in the WUG library in a single `PATCH /api/v1/monitors/-/config/template` request; accepts arrays of monitor templates with property bags
  * `Get-WUGPerformanceMonitor` -- Query performance monitors from the library (default) or from a specific device's assignments; supports `-Search`, `-MonitorTypeId`, `-DeviceId`, `-EnabledOnly`, `-View`
  * `Set-WUGPerformanceMonitor` -- Update an existing performance monitor template via `PUT /api/v1/monitors/{id}`; type-specific parameter sets (RestApi, PowerShell, WmiRaw, WmiFormatted, WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch) plus custom `-PropertyBag` for non-standard monitors

* Added -- Helpers
  * helpers/reports/ -- Dynamic Dashboard Generator (`Export-DynamicDashboardHtml`)
    * `Export-DynamicDashboardHtml.ps1` -- Universal HTML dashboard generator from any PowerShell object array
      * Pipeline support (`Begin`/`Process`/`End`) -- accepts piped objects or `-Data` array
      * Auto-flattening of nested objects and arrays to readable strings (picks Name/DisplayName, key=value pairs, comma-joined primitives)
      * `-CardField` accepts `[string[]]` -- one or more fields to group summary cards by; each field gets its own labelled row of clickable filter cards with auto-counts
      * `-StatusField` -- keyword-based colour coding (green/red/orange dots for ~40 status keywords: running, up, down, failed, warning, etc.)
      * `-ThresholdField` -- numeric threshold colouring via hashtable array; supports Warning/Critical levels with optional `Invert=$true` for "lower is worse" metrics (e.g. free disk space)
      * `-Offline` switch -- rewrites CDN URLs to local `file:///` paths from `helpers/reports/dependency/` folder for air-gapped environments
      * `-OutputPath` optional -- defaults to `$env:TEMP\WhatsUpGoldPS-Report-<datetime>.html`
      * `-ReportTitle`, `-ExportPrefix`, `-TemplatePath` customisation
      * Auto-detection of status and card fields when not specified (scans for Status/State/PowerState/Health/bestState, falls back to low-cardinality string columns)
      * Column title auto-humanisation: `camelCase` and `PascalCase` to spaced titles (`hostName` -> `Host Name`, `IPAddress` -> `IP Address`)
      * Case-insensitive field resolution (`Resolve-FieldName`) -- PowerShell property names mapped to exact JSON key casing for JavaScript compatibility
      * Template injection uses `[string].Replace()` instead of `-replace` to prevent regex `$` character corruption in JSON data
      * Independent single-item array wrapping for columns vs data (fixes edge case with 1-column or 1-row datasets)
    * `Dynamic-Dashboard-Template.html` -- Self-contained Bootstrap 5 + Bootstrap Table interactive report template
      * Multiple card group rows with labels -- each `-CardField` renders its own section with Total + per-value cards
      * Card click filtering -- click any card to filter the table to matching rows; click again to clear; cross-group independent
      * `formatStatusAuto()` -- automatic status keyword colour coding with coloured dots (green/red/orange/grey)
      * `formatThreshold()` -- numeric threshold formatter with configurable warning/critical levels and invert support
      * 8 export formats: CSV, TXT, XLSX, XLS, JSON, PNG, SQL, TSV (custom implementations via FileSaver + xlsx.js)
      * Row counter, pagination toggle, column toggle, search, sortable columns
      * Collapsible details section with chevron animation
      * Card highlight cleared on search input
    * `Resolve-DependencyPaths.ps1` -- Shared utility for rewriting CDN URLs to local file paths (supports version-pinned and unpinned CDN URLs)
    * `dependency/` -- Pre-downloaded offline copies of all CSS/JS dependencies
      * `bootstrap.min.css`, `bootstrap-table.min.css`, `bootstrap-icons.min.css` (+ `fonts/bootstrap-icons.woff2`, `fonts/bootstrap-icons.woff`)
      * `jquery.min.js`, `popper.min.js`, `bootstrap.min.js`, `bootstrap-table.min.js`
      * `FileSaver.min.js`, `xlsx.full.min.js`, `html2canvas.min.js`
  * helpers/lansweeper/ -- Lansweeper Data API (GraphQL) helper suite for IT asset discovery and vulnerability data
    * `LansweeperHelpers.ps1` -- 20+ functions for Lansweeper Data API integration
      * `Connect-LansweeperPAT` -- Authenticate via Personal Access Token (PAT); validates with `me` query
      * `Connect-LansweeperOAuth` -- Authenticate via OAuth 2.0 authorization code or refresh token flow
      * `Update-LansweeperOAuthToken` -- Refresh expired OAuth access tokens automatically
      * `Disconnect-Lansweeper` -- Clear session state
      * `Invoke-LansweeperGraphQL` -- Core GraphQL executor with auto-refresh, PAT/OAuth header switching, error handling
      * `Get-LansweeperCurrentUser` -- Retrieve authenticated user profile and site list (`me` query)
      * `Get-LansweeperSites` -- List API-client-authorized sites (`authorizedSites` query)
      * `Get-LansweeperSiteInfo` -- Site metadata (name, company, logo)
      * `Get-LansweeperAssetTypes` -- Enumerate all asset type names for a site
      * `Get-LansweeperAssetGroups` -- List asset groups with keys
      * `Get-LansweeperAssets` -- Paginated asset queries with field selection (max 30 paths), filtering, and `-All` auto-pagination
      * `Get-LansweeperAssetDetails` -- Full single-asset detail (OS, processors, memory, disks, network adapters, software, warranties)
      * `Get-LansweeperSources` -- List discovery sources/installations for a site
      * `Get-LansweeperAccounts` -- List authorized accounts for a site
      * `Get-LansweeperVulnerabilities` -- Query CVE data with severity filtering and auto-pagination (Pro/Enterprise plans)
      * `Get-LansweeperPatches` -- Microsoft KB patch articles for a specific CVE
      * `Start-LansweeperExport` -- Initiate bulk async asset export (mutation)
      * `Get-LansweeperExportStatus` -- Check export progress and download URL
      * `Wait-LansweeperExport` -- Poll export status until complete with configurable timeout
      * `Resolve-LansweeperAssetIP` -- IP resolution: assetBasicInfo.ipAddress -> networks[].ipAddressV4 -> DNS fallback
      * `New-LansweeperFilterBlock` -- Build GraphQL filter blocks from hashtable (conjunction + conditions)
      * `Get-LansweeperDashboardData` -- Aggregate assets across sites with optional vulnerability counts into flat dashboard objects
      * `Export-LansweeperDashboardHtml` -- Generate Bootstrap Table HTML report from dashboard data
    * `Lansweeper-Dashboard-Template.html` -- Bootstrap 5 + Bootstrap Table 1.22.1 interactive report template
      * Summary stat cards (Total Assets, Asset Types, Sites, With IP Address)
      * Filter control, column toggle, fullscreen, search, CSV/JSON/XLS export
      * Lansweeper URL deep-link column, vulnerability badge formatters (Critical/High/Medium)
    * `Get-LansweeperDashboard.ps1` -- Orchestration script: PAT auth, site selection, data collection, JSON + HTML export, browser open
    * `discover-lansweeper-immediate-add-with-attributes.ps1` -- WUG discovery script
      * Authenticates to Lansweeper (PAT) and WhatsUp Gold (Connect-WUGServer)
      * Retrieves assets with configurable type filter (Windows, Server, Linux, Network, etc.)
      * Resolves IP per asset, maps Lansweeper type to WUG brand (Microsoft, VMware, Network, AWS, Azure, etc.)
      * Adds devices via `Add-WUGDeviceTemplate` with Ping monitor and 14 custom Lansweeper attributes
      * Attributes: Lansweeper_Source, AssetKey, AssetType, Site, SiteId, Domain, MAC, Manufacturer, Model, Serial, FirstSeen, LastSeen, Url, LastSync
  * helpers/geolocation/ -- Geolocation map helper suite (replaces legacy ASP-based wug-geolocation with pure PowerShell + Leaflet)
    * `GeolocationHelpers.ps1` -- 8 functions for querying WUG devices/groups with lat/lng data and generating interactive Leaflet maps
      * `Initialize-GeoSSLBypass` -- SSL bypass for self-signed certs (compiled C# callback for PS 5.1)
      * `Invoke-GeoAPI` -- REST wrapper with automatic token refresh (5-minute expiry window) and PS 5.1 connection-pool retry
      * `Connect-GeoWUGServer` -- OAuth 2.0 password grant authentication; returns config hashtable with tokens/expiry
      * `Get-GeoDevicesWithLocation` -- Queries devices for `LatLong` attribute ("lat,lng") or separate `Latitude`/`Longitude` attributes (`-UseBuiltinCoords`); supports group filtering; uses `?view=overview` for inline monitor status (eliminates per-device API calls)
      * `Get-GeoGroupsWithLocation` -- Parses device group descriptions for "lat,lng" coordinate pairs with range validation
      * `Get-GeolocationData` -- Combined device + group dataset with `IncludeDevices`/`IncludeGroups` toggles
      * `Export-GeolocationMapHtml` -- Generates self-contained HTML with inline JSON data, configurable center/zoom, clickable WUG console links; new `-TileApiKeys` hashtable parameter injects provider API keys into `%%API_KEYS%%` placeholder
      * `Set-GeoDeviceLocations` -- CSV-based bulk import of lat/lng coordinates onto WUG devices; matches by DeviceName or IP (pre-fetches all devices for O(1) lookup); two attribute modes: combined `LatLong` (default) or separate `Latitude`/`Longitude`; `-WhatIf` support, coordinate validation, progress bar, per-row status reporting
    * `Setup-GeolocationConfig.ps1` -- Interactive one-time setup: prompts for WUG server/credentials, validates API connection, saves all config + API keys to DPAPI vault (`Geolocation.Config` bundle + `Geolocation.RefreshToken`); prompts for 8 tile provider API keys (Thunderforest, Stadia, MapTiler, HERE, Mapbox, Jawg, TomTom, OpenWeatherMap) with free-tier limit display; **migrated from repo-local JSON file to DPAPI vault** -- no sensitive data touches the repo directory
    * `Update-GeolocationMap.ps1` -- Scheduled-task script: reads config from DPAPI vault via `Import-GeolocationConfig`, authenticates via refresh grant, queries devices/groups, generates HTML map, rotates refresh token back to vault; tile API keys come pre-decrypted from vault
    * `Sync-GeolocationAttributes.ps1` -- CSV-to-WUG attribute sync script: reads config from DPAPI vault, authenticates via refresh grant, syncs lat/lng, rotates refresh token back to vault
    * `GeolocationHelpers.ps1` -- Added `Import-GeolocationConfig` function: reads `Geolocation.Config` bundle + `Geolocation.RefreshToken` from vault, converts typed fields (int/double/bool), extracts `TileApiKey.*` fields into hashtable; returns unified config hashtable for all geolocation scripts
    * `Geolocation-Map-Template.html` -- Leaflet 1.9.4 self-contained map template (removed leaflet-providers.js dependency; all tile URLs hardcoded inline)
      * Custom chip-based control panels replacing `L.control.layers`:
        * **Map Tiles** box (collapsible): grouped by provider with labelled rows, radio-button behavior (one active at a time), session persistence via `sessionStorage`
        * **Weather Overlays** box (collapsible, only visible when OpenWeatherMap key present): toggle behavior (multiple active simultaneously)
        * **Layers** box: Device/Group toggle chips with green active state
      * Tile registry system: `addTile(group, name, layer)` function with group/variant structure; `buildControls()` generates chip DOM from registry
      * 12 free tile providers (no API key needed): CartoDB (Voyager/Positron/Dark), Esri (Street/Imagery/Topo/Dark Gray/NatGeo/Ocean), USGS (Imagery/Topo), OpenTopoMap
      * 7 keyed tile provider families (33 variants, rendered only when API key present): Thunderforest (6), Stadia (6), MapTiler (4), HERE (5), Mapbox (5), Jawg (5), TomTom (2)
      * 6 weather overlays (OpenWeatherMap key): Clouds, Rain, Wind, Temperature, Pressure, Snow
      * Chip CSS: pill-shaped, color-coded active states (blue=tile, orange=overlay, green=marker layer), hover/active animations, responsive flexbox layout
      * Popup enhancements: monitor counts (total up / total down), collapsible `<details>` for down monitor list (up to 10), styled WUG deep-links with arrow icon
      * Device (circle) and Group (square) overlay layers with independent toggle
      * SVG status icons: green (Up), red (Down), orange (Maintenance), grey (Unknown)
      * Auto-fit bounds to all markers, legend, session-persisted pan/zoom/tile selection, info bar with generation timestamp
      * Favicon (wug.ninja), title: ninja emoji + "WhatsUpGoldPS Geolocation"
    * No ASP, no jQuery -- pure vanilla JavaScript with only Leaflet as external dependency
  * helpers/docker/ -- Docker Engine REST API helper suite (v1.45+, ports 2375/2376)
    * `DockerHelpers.ps1` -- 11 functions for Docker Engine API
      * `Initialize-SSLBypass` -- Compiled C# SSL bypass for TLS Docker hosts
      * `Invoke-DockerAPI` -- REST wrapper with PS 5.1 connection-pool retry
      * `Connect-DockerServer` -- Validates Docker Engine API reachability via `/version`
      * `Get-DockerSystemInfo` -- System-wide info (`/info`): hostname, version, containers, CPUs, memory, storage driver
      * `Get-DockerContainers` -- List all containers (`/containers/json?all=true`)
      * `Get-DockerContainerDetail` -- Container inspect (`/containers/{id}/json`)
      * `Get-DockerContainerStats` -- Live stats (`/containers/{id}/stats?stream=false`): CPU%, memory%, network I/O, block I/O
      * `Get-DockerNetworks` -- List networks (`/networks`)
      * `Get-DockerVolumes` -- List volumes (`/volumes`)
      * `Get-DockerImages` -- List images (`/images/json`)
      * `Get-DockerDashboard` -- Unified Host + Container dashboard dataset
      * `Export-DockerDashboardHtml` -- Bootstrap Table HTML report with summary cards
    * `Get-DockerDashboard.ps1` -- Multi-host orchestration script with TLS and SSL bypass options
    * `Docker-Dashboard-Template.html` -- Bootstrap Table dashboard with summary cards (Docker Hosts, Containers, Running, Stopped, Paused) and status badge formatters
  * helpers/test/Invoke-WUGHelperTest.ps1 -- Added Docker provider (auth prompt, Connect/SystemInfo/Containers/ContainerDetail/ContainerStats/Networks/Volumes/Images/Dashboard/Export tests, cleanup)
  * helpers/test/Invoke-WUGHelperTest.ps1 -- Added Geolocation provider (WUG auth prompt, Connect/DevicesWithLocation/GroupsWithLocation/GeolocationData/ExportMapHtml tests, cleanup)
  * helpers/test/Invoke-WUGHelperTest.ps1 -- Added Certificates and F5 providers to test harness (previously missing)
  * helpers/fortinet/ -- Fortinet FortiGate + FortiManager dashboard suite (107 functions in FortinetHelpers.ps1)
    * Core: `Connect-FortiGate`, `Disconnect-FortiGate`, `Invoke-FortiAPI`, `New-FortinetDashboardHtml`
    * System: `Get-FortiGateSystemStatus`, `Get-FortiGateSystemResources`, `Get-FortiGateHAStatus`, `Get-FortiGateHAChecksums`, `Get-FortiGateFirmware`, `Get-FortiGateLicenseStatus`, `Get-FortiGateGlobalSettings`, `Get-FortiGateAdmins`, `Get-FortiGateSystemDashboard`, `Export-FortiGateSystemDashboardHtml`
    * Network: `Get-FortiGateInterfaces`, `Get-FortiGateInterfaceConfig`, `Get-FortiGateZones`, `Get-FortiGateRoutes`, `Get-FortiGateIPv6Routes`, `Get-FortiGateStaticRoutes`, `Get-FortiGateARP`, `Get-FortiGateDHCPLeases`, `Get-FortiGateDHCPServers`, `Get-FortiGateDNS`, `Get-FortiGateNetworkDashboard`, `Export-FortiGateNetworkDashboardHtml`
    * Firewall: `Get-FortiGateFirewallPolicies`, `Get-FortiGateAddresses`, `Get-FortiGateAddressGroups`, `Get-FortiGateServices`, `Get-FortiGateServiceGroups`, `Get-FortiGateSchedules`, `Get-FortiGateIPPools`, `Get-FortiGateVIPs`, `Get-FortiGateShapingPolicies`, `Get-FortiGateFirewallDashboard`, `Export-FortiGateFirewallDashboardHtml`
    * VPN: `Get-FortiGateIPSecTunnels`, `Get-FortiGateIPSecPhase1`, `Get-FortiGateIPSecPhase2`, `Get-FortiGateSSLVPNSessions`, `Get-FortiGateSSLVPNSettings`, `Get-FortiGateVPNDashboard`, `Export-FortiGateVPNDashboardHtml`
    * SD-WAN: `Get-FortiGateSDWANMembers`, `Get-FortiGateSDWANHealthCheck`, `Get-FortiGateSDWANConfig`, `Get-FortiGateSDWANHealthCheckConfig`, `Get-FortiGateSDWANRules`, `Get-FortiGateSDWANZones`, `Get-FortiGateSDWANDashboard`, `Export-FortiGateSDWANDashboardHtml`
    * Security Profiles: `Get-FortiGateAntivirusProfiles`, `Get-FortiGateIPSSensors`, `Get-FortiGateWebFilterProfiles`, `Get-FortiGateAppControlProfiles`, `Get-FortiGateDLPSensors`, `Get-FortiGateDNSFilterProfiles`, `Get-FortiGateSSLSSHProfiles`, `Get-FortiGateSecurityDashboard`, `Export-FortiGateSecurityDashboardHtml`
    * User & Auth: `Get-FortiGateLocalUsers`, `Get-FortiGateUserGroups`, `Get-FortiGateLDAPServers`, `Get-FortiGateRADIUSServers`, `Get-FortiGateActiveAuthUsers`, `Get-FortiGateFortiTokens`, `Get-FortiGateSAMLSP`, `Get-FortiGateUserAuthDashboard`, `Export-FortiGateUserAuthDashboardHtml`
    * Wireless: `Get-FortiGateManagedAPs`, `Get-FortiGateWiFiClients`, `Get-FortiGateRogueAPs`, `Get-FortiGateSSIDs`, `Get-FortiGateWTPProfiles`, `Get-FortiGateWirelessDashboard`, `Export-FortiGateWirelessDashboardHtml`
    * Switch: `Get-FortiGateManagedSwitches`, `Get-FortiGateSwitchPorts`, `Get-FortiGateSwitchConfig`, `Get-FortiGateSwitchVLANs`, `Get-FortiGateSwitchLLDP`, `Get-FortiGateSwitchDashboard`, `Export-FortiGateSwitchDashboardHtml`
    * Endpoint: `Get-FortiGateEMSEndpoints`, `Get-FortiGateEMSConfig`, `Get-FortiGateSecurityRating`, `Get-FortiGateEndpointProfiles`, `Get-FortiGateEndpointDashboard`, `Export-FortiGateEndpointDashboardHtml`
    * Log: `Get-FortiGateTrafficLogs`, `Get-FortiGateEventLogs`, `Get-FortiGateUTMLogs`, `Get-FortiGateLogStats`, `Get-FortiGateFortiGuardStatus`, `Get-FortiGateAlertMessages`, `Get-FortiGateLogDashboard`, `Export-FortiGateLogDashboardHtml`
    * FortiManager: `Connect-FortiManager`, `Disconnect-FortiManager`, `Invoke-FortiManagerAPI`, `Get-FortiManagerSystemStatus`, `Get-FortiManagerADOMs`, `Get-FortiManagerDevices`, `Get-FortiManagerPolicyPackages`, `Get-FortiManagerDashboard`, `Export-FortiManagerDashboardHtml`
    * Universal HTML dashboard template (`Fortinet-Dashboard-Template.html`) with dynamic JSON config injection, dark theme, Bootstrap Table 1.22.1
  * helpers/test/Invoke-WUGHelperTest.ps1 -- Added Fortinet provider (12 category test sections + FortiManager, auth prompt, cleanup, per-category HTML report collection)
  * helpers/discovery/ -- Unified Discovery Framework with DPAPI Credential Vault and WUG REST API monitor provisioning
    * `DiscoveryHelpers.ps1` -- 24-function core framework operating in standalone (inventory/audit/CI) or WUG integration mode
      * Provider Registry: `Register-DiscoveryProvider`, `Get-DiscoveryProvider`, `Find-WUGDiscoveryDevices`, `New-DiscoveredItem`, `Invoke-Discovery`, `Export-DiscoveryPlan` (JSON/CSV/objects with automatic secret scrubbing)
      * DPAPI Credential Vault: `Set-DiscoveryVaultPath`, `Set-DiscoveryVaultPassword`, `Clear-DiscoveryVaultPassword`, `Initialize-DiscoveryVault` (ACL-locked directory), `Write-VaultAuditLog`, `Protect-VaultData` (DPAPI + optional AES-256 double encryption), `Unprotect-VaultData`
      * Vault Security Hardening: `Get-VaultHmacKey` / `Get-VaultHmac` -- HMAC-SHA256 integrity verification for vault files using a DPAPI-protected random 32-byte key (`.vault-hmac.key`); AES-256 PBKDF2 iteration count increased to 600,000 (OWASP 2023+ guidance); salt now uses deterministic (machine+user) + random component (`.vault-salt.bin`)
      * Credential Management: `Save-DiscoveryCredential` (AWSKeys/AzureSP/BearerToken/PSCredential bundles), `Get-DiscoveryCredential` (expiry/integrity checks), `Request-DiscoveryCredential` (interactive prompt), `Resolve-DiscoveryCredential` (vault -> prompt -> WUG attribute fallback), `ConvertFrom-VaultStored`, `Save-ResolvedCredential`, `Remove-DiscoveryCredential`
      * WUG Integration: `Invoke-WUGDiscovery`, `Invoke-WUGDiscoverySync` (REST API monitor creation), `New-WUGDiscoveryCredential` (WUG credential store), `Start-WUGDiscovery` (top-level orchestrator)
    * `DiscoveryProvider-AWS.ps1` -- AWS discovery provider (EC2 instances, CloudWatch metrics)
    * `DiscoveryProvider-Azure.ps1` -- Azure discovery provider with per-resource metric enumeration
      * Phase 2: Azure Monitor metric definition enumeration per resource (REST API `metricDefinitions` or `Get-AzMetricDefinition`)
      * Builds REST API Active Monitor per resource (provisioning state health check via ARM API)
      * Builds REST API Performance Monitor per metric definition per resource (Azure Metrics API with JSONPath)
      * `Azure.MetricCount` and `Azure.AvailableMetrics` device attributes for metric visibility
      * Numeric metrics (Average/Total/Count/Max/Min) -> Performance Monitor; string/unspecified -> Active Monitor
    * `DiscoveryProvider-F5.ps1` -- F5 BIG-IP discovery provider (virtual servers, pools, nodes)
    * `DiscoveryProvider-Fortinet.ps1` -- Fortinet FortiGate discovery provider (system, firewall, VPN)
    * `DiscoveryProvider-HyperV.ps1` -- Hyper-V discovery provider (hosts, VMs, health)
    * `DiscoveryProvider-Proxmox.ps1` -- Proxmox VE discovery provider (cluster nodes, QEMU VMs, LXC containers, CPU/memory/disk monitors; API Token auth)
      * LXC container support: queries `/nodes/{node}/lxc` for container list, `/lxc/{vmid}/status/current` + `/lxc/{vmid}/config` for IP resolution via `net\d+` config parsing; adds CT type with same metadata as VMs (Name, IP, Node, Status, Cpus, MaxMem, MaxDisk)
      * Phase 2 metric validation probes each node/VM/CT status endpoint
    * `DiscoveryProvider-VMware.ps1` -- VMware vSphere discovery provider (ESXi hosts, VMs, datastores)
    * `Setup-AWS-Discovery.ps1` -- Interactive AWS discovery script with vault-backed credential storage, menu-driven export/WUG push
    * `Setup-Azure-Discovery.ps1` -- Azure cloud resource discovery with full WUG integration
      * PushToWUG [1]: adds ALL resources as WUG devices (0.0.0.0 for IP-less cloud resources)
      * Creates Azure credential + REST API OAuth2 credential in WUG library from vault SP
      * Assigns both credentials to each device for REST API monitor authentication
      * Per-resource health Active Monitor + per-metric Performance Monitor via `Invoke-WUGDiscoverySync`
      * TestCredential [7]: create, verify, and delete Azure + REST API credentials in WUG (round-trip test)
      * Non-interactive defaults to Dashboard action (scheduled task friendly)
      * Dashboard includes MetricCount column; resources without IP shown as 0.0.0.0
      * Plan summary shows metric counts per resource and total metric-enabled resources
    * `Setup-F5-Discovery.ps1` -- Interactive F5 BIG-IP discovery script with token vault storage
    * `Setup-Fortinet-Discovery.ps1` -- Interactive Fortinet FortiGate discovery script with API key vault storage
    * `Setup-HyperV-Discovery.ps1` -- Interactive Hyper-V discovery script with PSCredential vault storage
    * `Setup-Proxmox-Discovery.ps1` -- Interactive Proxmox VE discovery script with API token vault storage; LXC container (`CT`) device type handling; unified "guest" terminology (VMs + CTs); guest-with-IP / guest-without-IP summary; new `DashboardAndPush` action; sequential Dashboard then PushToWUG execution; full PushToWUG pipeline (credential creation, bulk active/perf monitor creation, device template creation, credential assignment); WUG module auto-import; vault-based credential resolution
    * `Setup-VMware-Discovery.ps1` -- Interactive VMware vSphere discovery script with PSCredential vault storage
    * `Setup-WindowsAttributes-Discovery.ps1` -- Windows system attributes discovery helper; scans WUG devices via WMI (`Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_BIOS`, `Win32_Processor`) to collect OS version, CPU, RAM, serial number, domain, last boot time, and more; creates or updates device attributes in WUG via `Set-WUGDeviceAttribute`
      * 16 attribute keys: OSName, OSVersion, OSBuild, ServicePack, Architecture, Manufacturer, Model, SerialNumber, TotalMemoryGB, CPUName, CPUCores, CPULogical, Domain, LastBootTime, InstallDate, SystemType
      * `-IncludeAttribute` -- select specific attributes or `All` (default: all 16)
      * `-AttributePrefix` -- namespace prefix for attribute names (default: `Windows`)
      * Shared Windows WMI credential vault (`Windows.WMI.Credential.N`) -- same creds used by `Setup-WindowsDiskIO-Discovery.ps1`
      * Smart device group detection, multi-credential fallback, `-DryRun`, `-NonInteractive` -- same patterns as DiskIO helper
    * `Setup-WindowsDiskIO-Discovery.ps1` -- Windows disk IO discovery helper; scans WUG devices via WMI to enumerate physical or logical disk instances, creates WmiFormatted performance monitors in the WUG library (one per unique class+property+instance), and assigns them to applicable devices
      * `-DiskType` (Logical/Physical/All) -- queries `Win32_PerfFormattedData_PerfDisk_LogicalDisk` or `PhysicalDisk`; `All` runs both passes sequentially; default: Logical
      * `-IncludeCounter` with `All` option -- default: DiskTransfersPersec (total IOPS); `All` enables 8 counters (reads/writes/transfers, bytes read/write/total, avg queue length, % disk time)
      * `-DeviceGroupSearch 'Windows Infrastructure'` -- auto-finds WUG device group by name; `-WindowsOnly` filters non-Windows devices by role/description
      * Multi-credential support -- vault stores numbered `Windows.WMI.Credential.1`, `.2`, etc. (shared across all `Setup-Windows*` helpers); per-device fallback on access-denied errors (UnauthorizedAccessException, COM 0x80070005)
      * Pre-checks existing library monitors and device assignments to skip duplicates; `-DryRun` for preview without changes
      * DPAPI vault integration via `Resolve-DiscoveryCredential`; WUG server auto-connect from vault; fully non-interactive via `-NonInteractive`
  * helpers/bigleaf/ -- Bigleaf Cloud Connect SD-WAN dashboard suite (API v2)
    * `BigleafHelpers.ps1` -- 13 functions for Bigleaf API integration (HTTP Basic auth, 10 calls/min rate limit)
      * `Connect-BigleafAPI`, `Disconnect-BigleafAPI`, `Invoke-BigleafAPI` (internal wrapper)
      * `Get-BigleafSites`, `Get-BigleafSiteStatus`, `Get-BigleafCircuitStatus`, `Get-BigleafDeviceStatus`, `Get-BigleafSiteRisks`
      * `Get-BigleafAccounts`, `Get-BigleafCompanies`, `Get-BigleafMetadata`
      * `Get-BigleafDashboard` -- Combines sites + status into flat dashboard objects
      * `Export-BigleafDashboardHtml` -- Renders interactive Bootstrap Table HTML report
    * `Get-BigleafDashboard.ps1` -- Orchestration script: Bigleaf auth, data collection, optional WUG device enrichment, JSON + HTML export
    * `Bigleaf-Dashboard-Template.html` -- Bootstrap 5 + Bootstrap Table dashboard with site/circuit status cards
  * helpers/test/ -- Discovery framework test and management tools
    * `Invoke-WUGDiscoveryRunner.ps1` -- Master end-to-end orchestrator for all 7 discovery providers (AWS, Azure, F5, Fortinet, HyperV, Proxmox, VMware); `-Run*` switches for selective execution, vault credential loading, per-provider JSON/CSV plan export + HTML dashboard generation, pass/fail test recording
    * `Invoke-WUGDiscoveryVault.ps1` -- Interactive DPAPI vault manager (List/View/Add/Update/Delete credentials); supports AWSKeys, AzureSP, BearerToken, PSCredential types; `-Action`/`-Name`/`-CredType` parameters for non-interactive use
    * `Invoke-WUGDiscoveryHelperTest.ps1` -- Automated test harness for Discovery Framework and DPAPI Credential Vault (12 test areas: provider registration, single/multi-field vault ops, credential expiry, tamper detection, AES-256 double encryption, secret scrubbing, aliases, standalone discovery with mock provider, audit log, ACL permissions, cleanup); uses temp vault, no network access required
    * `Test-Dashboard-Template.html` -- Bootstrap Table HTML template for test result reports
    * `Register-DiscoveryScheduledTask.ps1` -- Register Windows Scheduled Tasks for recurring discovery runs; three modes: Provider (single provider), Runner (all providers via Invoke-WUGDiscoveryRunner), WUGAction (Setup script action); uses DPAPI vault for fully non-interactive execution; supports 14 providers (AWS, Azure, Bigleaf, Docker, F5, Fortinet, GCP, HyperV, Nutanix, OCI, Proxmox, VMware, WindowsAttributes, WindowsDiskIO); `DashboardAndPush` action; new `Set-RestrictedDirectoryAcl` function locks output/log directories to current user + SYSTEM + Administrators via explicit ACL
  * helpers/test/Invoke-WUGGeomapTest.ps1 -- Dedicated geolocation E2E integration test harness (21 tests)
    * `Connect-WUGServer` + `Connect-GeoWUGServer` authentication
    * `Add-WUGDeviceTemplate` (create geo test device), `Set-WUGDeviceAttribute` for LatLong (combined) and separate Latitude/Longitude, `Get-WUGDeviceAttribute` verification
    * `Add-WUGDeviceGroup` (create geo test group), `Get-GeoDevicesWithLocation` (LatLong + BuiltinCoords modes), `Get-GeoGroupsWithLocation`, `Get-GeolocationData` (all/devices-only/groups-only)
    * `Export-GeolocationMapHtml` (basic + verify markers + all tile providers with fake keys)
    * All-providers test: generates map with keys for all 8 providers, verifies provider blocks rendered, chip UI (`geo-controls`), Weather Overlays box present
    * Cleanup: `Remove-WUGDevice`, `Remove-WUGDeviceGroup`, `Disconnect-WUGServer`

* Test Coverage (this release)
  * `Invoke-WUGModuleTest.ps1`: 168 -> 207 tests (+39 new: Set-WUGRole, Add-WUGMonitorTemplate bulk, Set-WUGMonitorTemplate, Add/Set/Remove-WUGDeviceInterface, Set-WUGDevicePollingConfig, Set-WUGDeviceRole, Set-WUGDeviceMaintenanceSchedule, Get-WUGPassiveMonitor library/search/details/byId/device, Set-WUGPassiveMonitor update/rename/validation, Remove-WUGPassiveMonitor byId, passive monitor cleanup catch-all)
  * `Invoke-WUGHelperTest.ps1`: 222 -> 245 tests (+23 new: full Bigleaf helper suite, Lansweeper helper suite)
  * `Invoke-WUGGeomapTest.ps1`: 21 tests (new file)
  * **Total across all test files: 473** (was 390, +83)

* Changed
  * `DiscoveryProvider-Azure.ps1` -- Major rewrite of metric validation and monitor creation pipeline (end-to-end WUG integration now fully operational)
    * Phase 1: Live health-endpoint probing per resource type -- inspects actual ARM API response to determine correct JSONPath property in priority order: `availabilityState` -> `enabled` -> `state` -> `provisioningState` -> `dailyMaxActiveDevices`; stored in `$healthJsonProp` hashtable per resource type
    * Phase 2 metric enumeration discovers all available Azure Monitor metric definitions per resource; each metric becomes a dedicated REST API Performance Monitor with JSONPath extraction
    * Phase 2.5: P1D metric pre-filter eliminates dead metrics early (24-hour window check)
    * Phase 2.6: Strict single-aggregation validation at PT10M matching WUG's 10-minute poll cycle; groups metrics by aggregation type, probes with EXACT single aggregation (not all 5), uses `PSObject.Properties.Name -contains` for explicit field existence check -- prevents false positives where Azure returns fields when all 5 aggregations are requested but omits them when only one is requested
    * Phase 3: Plan item generation uses hardcoded `timespan=PT10M&interval=PT5M` matching WUG's actual performance monitor poll interval
    * Phase 4: Azure Billing monitors via Azure Consumption Budgets API (`GET /subscriptions/{id}/providers/Microsoft.Consumption/budgets?api-version=2024-08-01`); discovers budgets per subscription; creates 3 monitors per budget (Current Spend, Budget Limit, Forecast Spend) via JSONPath extraction; auto-creates "WUG-Discovery-Monitor" budget ($1000/month) when no budgets exist in a subscription
    * Configurable `-MetricsTimespan` (PT1H/PT6H/PT12H/P1D/P7D) for Azure Monitor metric polling window; P7D recommended for idle labs to prevent empty timeseries errors
    * Resource health check now uses ARM REST API GET with probed JSONPath property (was generic PowerShell stub with hardcoded `provisioningState`)
    * Progress bar during metric enumeration with resource count and name display
  * `Setup-Azure-Discovery.ps1` -- Major WUG push overhaul
    * Added `-MetricsTimespan` parameter with `ValidateSet` (PT1H, PT6H, PT12H, P1D, P7D; default P1D); interactive menu prompt for timespan selection; passed through credential context to DiscoveryProvider
    * PushToWUG now adds ALL resources (previously skipped resources without IP)
    * Cloud resources (no IP) added as 0.0.0.0 devices with Azure Cloud Resource attributes
    * Creates two WUG credentials per tenant: Azure SP for device identity + REST API OAuth2 for monitor auth
    * Credential assignment to every cloud resource device (Azure + REST API)
    * Step 2a/2b: Bulk monitor creation batched in groups of 50 with 2-second pauses between batches to prevent WUG API overload
    * Step 2a/2b: Post-creation reconciliation re-queries WUG monitor library (`Get-WUGActiveMonitor -Search`, `Get-WUGPerformanceMonitor -Search`) to backfill monitor IDs missed during bulk creation tracking
    * Step 2d: Device creation switched from bulk `Add-WUGDeviceTemplates` to one-by-one `Add-WUGDeviceTemplate` (bulk was returning 500 errors)
    * TestCredential option [7] for round-trip credential verification before committing
    * Non-interactive mode defaults to Dashboard (previously required explicit -Action)
    * Plan summary shows metric counts, cloud resource counts, and total plan items
    * ValidateSet for -Action now includes `TestCredential`
  * `Add-WUGDeviceTemplate.ps1` -- Added `-NoDefaultActiveMonitor` switch to suppress default Ping monitor for perf-only cloud resource devices; added `-GroupName` parameter; added Azure and Meraki credential type support in credential objects
  * `Connect-WUGServer.ps1` -- Integrated DPAPI credential vault; when called with no parameters, checks vault for saved WUG credentials and prompts to reuse/reset/new; successful connections auto-save to vault at `%LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault`; warns when plaintext `-Username`/`-Password` parameters used (PSReadLine history exposure); vault integrity now uses HMAC-SHA256 with DPAPI-protected key (was plain SHA-256); legacy SHA-256 fallback for pre-HMAC vault files; ACL restriction warning when directory permissions can't be set
  * `Disconnect-WUGServer.ps1` -- Restores SSL certificate validation on disconnect (PS Core: removes `SkipCertificateCheck` defaults; PS 5.1: nulls `ServerCertificateValidationCallback`); clears all credential-related globals (`WUGBearerHeaders`, `expiry`, `WhatsUpServerBaseURI`, `tokenUri`, `WUGRefreshToken`, `IgnoreSSLErrors`, `_WUGAllowedSSLHosts`)
  * `Get-WUGPerformanceMonitor.ps1` -- Major rewrite: auto-pagination in library mode (loops on `nextPageId` automatically); view validation with library vs device mode enforcing correct `ValidateSet` values with clear error messages; structured output objects with extracted `ClassId`, `BaseType`, `MonitorTypeName` from `monitorTypeInfo`
  * `Get-WUGActiveMonitor.ps1` -- Device mode now auto-paginates (loops on `nextPageId`); merges template metadata into output objects
  * `Set-WUGDeviceRole.ps1` -- `brand`/`os`/`primary` role kinds now use query parameters (not JSON body) per API spec; `sub-role` still uses JSON body; backward compat: extracts value from Body JSON if `-RoleValue` not specified
  * `Add-WUGDeviceInterface.ps1` -- New explicit parameters: `-Address`, `-HostName`, `-DefaultInterface`, `-PollUsingName`; retains `-Body` parameter set for raw JSON
  * `Add-WUGCredential.ps1` -- REST API credential now conditionally includes OAuth2 property bags only when `AuthType = '1'`; fixes 400 errors from sending empty OAuth2 bags with Basic auth
  * `Set-WUGDevicePollingConfig.ps1` -- New explicit `-PollingIntervalSeconds` parameter (was body-only)
  * `Get-WUGAPIResponse.ps1` -- Enhanced diagnostics: body length, UTC token expiry timestamps in debug logging; improved error messages include URI, Method, statusCode, responseBody context
  * `GeolocationHelpers.ps1` -- Eliminated per-device status API calls: uses `?view=overview` on device group endpoint to get `bestState`, `worstState`, `totalActiveMonitors`, `totalActiveMonitorsDown`, `downActiveMonitors` inline (was making N+1 API calls); fixed API response parsing (`$result.data.groups`/`$result.data.devices` instead of `$result.data`); device data now includes `TotalMonitors`, `DownMonitors`, `DownMonitorDetails` fields; `Write-Output` -> `Write-Verbose` for pipeline-clean output; template reading switched to `[System.IO.File]::ReadAllText()` (avoids BOM issues); TLS 1.0/1.1 removed from SSL bypass (TLS 1.2 only)
  * `Add-WUGPerformanceMonitor.ps1` -- Added type-specific parameter sets and auto-generated monitor names when omitted
  * `Add-WUGActiveMonitor.ps1` -- Minor refinements to property bag handling
  * `AzureHelpers.ps1` -- `Invoke-AzureREST` now supports `-Body` parameter for PUT/POST operations; hashtables auto-converted to JSON; Content-Type set to `application/json` when Body is provided
  * All 7 Setup scripts (AWS, Azure, F5, Fortinet, HyperV, Proxmox, VMware) -- Enhanced PushToWUG actions with vault credential integration and improved error handling
  * All 7 Discovery Providers -- Refined monitor template generation and plan item structures
  * Removed unused `tableexport.jquery.plugin` dependency from all 14 dashboard HTML templates -- custom `wireExport()` functions handle all exports via FileSaver + xlsx.js directly; plugin was loaded but never called
  * Standardized HTML dashboard toolbar across all 14 templates (AWS, Azure, Bigleaf, Certificate, Docker, F5, GCP, Hyper-V, Lansweeper, Nutanix, OCI, Proxmox, Test, VMware)
    * Unified `wireExport()`, `updateRowCounter()`, toolbar injection pattern (row counter span + pagination toggle + export dropdown into `.fixed-table-toolbar .columns`)
    * Consistent `data-show-export="false"` to suppress built-in export button in favour of custom dropdown
  * helpers/vmware/ -- Redesigned VMware dashboard data model
    * Hosts always included as own rows (Type="Host"), VMs get Type="VM" (matches Proxmox pattern)
    * Consolidated 4 host-only columns into 2: Version+Build -> "VersionBuild", Manufacturer+Model -> "Hardware"
    * Added VM datastore parsing from `Get-HardDisk .Filename` property (`[DatastoreName] path/to.vmdk`)
    * Added fallback from realtime to 5-minute interval stats for disk metrics (realtime requires vCenter stats level 2+)
    * Added `formatType` formatter, `titleMap` for clean column headers in `VMware-Dashboard-Template.html`
    * Updated `Get-VMwareDashboard.ps1` orchestration: removed `IncludeHostRows` switch, summary counts by Type field
    * Summary cards: ESXi Hosts (blue), VMs (dark), Powered On, Off, Suspended
  * Standardized SSL/TLS self-signed certificate bypass across all on-prem helpers
    * Fortinet, F5, Nutanix: Replaced fragile `delegate { return true; }` / scriptblock callbacks with Proxmox-style compiled `SSLValidator` C# class
    * Compiled callback avoids scriptblock delegate marshaling failures under rapid sequential requests in PS 5.1
    * Sets `SecurityProtocol` (TLS 1.0/1.1/1.2), `Expect100Continue = false`, `DefaultConnectionLimit = 64`
    * PS 7+/Core: Uses `PSDefaultParameterValues` for `SkipCertificateCheck`
  * Fortinet dashboard template: Replaced `{{DASHBOARD_CONFIG}}` placeholder (caused VS Code JS validation errors) with `<script type="application/json">` data block parsed via `JSON.parse()`
  * Standardized HTML dashboard export options across all 11 templates (Azure, AWS, GCP, OCI, Proxmox, Hyper-V, Nutanix, F5, Certificate, Test, Fortinet)
    * Added XLS, PNG, SQL, TSV exports to match existing CSV, TXT, XLSX, JSON -- all dashboards now offer 8 export formats
    * Fixed TXT export: replaced hardcoded WUG device field names (`id`, `name`, `networkAddress`, `hostName`, `downActiveMonitors`) with dynamic `Object.keys()` -- all templates and `Bootstrap-Table-Sample.html` now export actual column data instead of `undefined`
    * Added full export suite to Fortinet dark-theme dashboard (FileSaver, XLSX, html2canvas libraries + export dropdown in header)
  * Replaced all Unicode em-dash (U+2014) characters with ASCII dashes across entire project to prevent encoding corruption on Windows systems
  * `AzureHelpers.ps1` -- Removed Az PowerShell module dependency entirely; all Azure operations now use pure REST API calls (`Invoke-AzureREST`); `Connect-AzureREST` replaces `Connect-AzAccount`; `Get-AzureDashboard.ps1`, `discover-azure-*.ps1`, `DiscoveryProvider-Azure.ps1`, `Setup-Azure-Discovery.ps1` updated to REST-only
  * `ProxmoxHelpers.ps1` -- Added `-ApiToken` parameter to `Get-ProxmoxNodes`, `Get-ProxmoxVMs`, `Get-ProxmoxNodeDetail`, `Get-ProxmoxVMDetail`, `Get-ProxmoxDashboard`; all pass through to `Invoke-ProxmoxAPI -ApiToken`; `Get-ProxmoxDashboard -Cookie` no longer mandatory (token-only auth supported)
  * `ProxmoxHelpers.ps1` -- Fixed PS 5.1 header validation failure for `PVEAPIToken=user@realm!tokenid=secret` format; `Connect-ProxmoxServer` uses `HttpWebRequest.Headers.Add()` on PS 5.1 (bypasses `WebHeaderCollection` validation); `Invoke-ProxmoxAPI` uses `WebRequestSession.Headers` on PS 5.1; PS 7+ uses `-SkipHeaderValidation`
  * `Invoke-WUGHelperTest.ps1` -- Proxmox auth now offers `[1] Username + Password  [2] API Token  [S] Skip`; option 2 resolves `Proxmox.<host>.Token` from DPAPI vault with `BearerToken` CredType (matches `Setup-Proxmox-Discovery.ps1` pattern); vault save/clear on pass/fail for both auth methods
  * `Invoke-WUGHelperTest.ps1` -- Geolocation console URL auto-derived from `WUG.Server` vault data (`$protocol://$server:443`) instead of prompting via `Read-Host`
  * `Invoke-WUGHelperTest.ps1` -- AWS tests auto-expand across all enabled regions; EC2/RDS/ELB loop through `Get-AWSRegionList`; multi-region dashboard passes all discovered regions

* Fixed
  * Fixed HTML test report showing empty table when only one test result -- `ConvertTo-Json` pipeline with single item produces `{}` instead of `[{}]`; switched to `ConvertTo-Json -InputObject @($array)` in `Invoke-WUGHelperTest.ps1`
  * Fixed `Export-GeolocationMapHtml` using `-replace` (regex) for JSON data injection -- regex special chars (`$`, `(`, `)`) in JSON could corrupt output; switched to `.Replace()` (literal string matching)
  * Fixed Geolocation-Map-Template.html bare `%%DEFAULT_LAT%%` / `%%DEFAULT_LNG%%` / `%%DEFAULT_ZOOM%%` placeholders causing JS parse errors -- wrapped in `parseFloat()`/`parseInt()` so `%%` tokens sit inside valid string literals
  * UTF-8 BOM added to 22 files created in this release that were missing it (all .ps1 and .html files now consistent)

* Security
  * PBKDF2 iteration count increased to 600,000 in DiscoveryHelpers vault encryption (OWASP 2023+ compliance)
  * HMAC-SHA256 vault integrity verification with DPAPI-protected random key (prevents tampering by other local users)
  * ACL restriction on vault/output directories (SYSTEM + Administrators + current user only via `Set-RestrictedDirectoryAcl`)
  * Plaintext credential parameter warning in `Connect-WUGServer` (PSReadLine history exposure risk)
  * SSL/TLS state cleanup on `Disconnect-WUGServer` prevents leaking trust-all-certs to subsequent sessions
  * TLS 1.0/1.1 removed from geolocation SSL bypass (TLS 1.2 only)
  * Geolocation config migrated from repo-local JSON file to DPAPI vault -- refresh tokens, tile API keys, and server connection info now stored in `%LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault` with HMAC-SHA256 integrity; no sensitive data in the repo directory
  * All 10 dashboard scripts (AWS, Azure, Bigleaf, Certificate, F5, Hyper-V, Lansweeper, Nutanix, Proxmox, VMware) now use `Resolve-DiscoveryCredential` for vault-first credential resolution; if credentials exist in the vault (from a prior Setup run), they are reused automatically; if not, the user is prompted interactively and the credential is saved to the vault for next time
  * Lansweeper PAT prompt now uses `Resolve-DiscoveryCredential` with `-CredType BearerToken` (was plaintext `Read-Host` without `-AsSecureString`)
  * Proxmox dashboard vault fallback added before falling through to plaintext Username/Password prompts
  * AWS/Azure dashboards try vault before accepting plaintext parameter strings
  * All changed files re-signed (Authenticode code-signing certificate)

* Fixed
  * `Invoke-WUGModuleTest.ps1` -- Passive monitor tests were not cleaning up after themselves; `$script:PassiveMonitorNames` was never initialized causing cleanup loop to silently skip all monitor deletions; now initialized as `List[string]` alongside `$script:PassiveMonitorIds` and populated on each `Add-WUGPassiveMonitor` call; cleanup uses new `Remove-WUGPassiveMonitor` with a catch-all `WhatsUpGoldPS-Test-` search to also remove orphans from prior runs
  * `Invoke-WUGModuleTest.ps1` -- `Get-WUGActiveMonitor (templates)` test returned null because function without `-IncludeAssignments` falls through to global assignments endpoint which can be empty; added `-IncludeAssignments` to the test call
  * `Add-WUGActiveMonitor.ps1` -- SNMP Table discovery operator enum was incorrectly using monitor comparison values (0-6); fixed to use discovery-specific enum (0=IsOneOf, 1=Range, 2=LessThan, 3=GreaterThan, 4=ContainsOneOf)
  * NmConsole dashboard files were publicly accessible without authentication; added child `web.config` with `<deny users="?" />` to `NmConsole\dashboards\` subdirectory; centralized `Deploy-DashboardWebConfig` function in `DiscoveryHelpers.ps1`; all 12 Setup scripts and `Update-GeolocationMap.ps1` now deploy the web.config automatically after copying dashboards; added `<customErrors>` redirect to `/NmConsole` for unauthenticated users
  * Dashboard HTML files were being copied to the NmConsole root directory (risking filename collisions); moved all dashboards to `NmConsole\dashboards\` subdirectory; updated all 14 files (12 Setup scripts, `Copy-WUGDashboardReports.ps1`, `Update-GeolocationMap.ps1`, `Start-WUGDiscoverySetup.ps1`)
  * Data directory path `%LOCALAPPDATA%\DiscoveryHelpers\` was too generic; relocated to `%LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\` (Vault and Output subdirectories) across 19 files -- existing users must move or re-create their vault under the new path

## 0.1.19/20 - 2026-03-15 [Released to PowerShell Gallery]
* Added  -- New Functions (85 total exports; psm1 and psd1 in sync)
  * `Get-WUGRole`  -- Browse the device role library: by ID, list all, assignments, templates, percent variables (`/device-role/` endpoints)
  * `Set-WUGRole`  -- Manage the device role library: delete, enable, disable, restore roles; apply templates via PATCH
  * `Import-WUGRoleTemplate`  -- Import and verify device role packages (`POST /device-role/-/config/import[/verify]`)
  * `Export-WUGRoleTemplate`  -- Export device role packages and inventory (`POST /device-role/-/config/export[/content]`) *(disabled  -- API returns 400; not exported until upstream fix)*
  * `Import-WUGMonitorTemplate`  -- Import monitor templates via `PATCH /monitors/-/config/template` with `-Options` (all/clone/transfer/update)
  * `Get-WUGProduct`  -- Product info + API version (`/api/v1/product`, `/api/v1/product/api`)
  * `Get-WUGDeviceScan`  -- Device scan endpoints (`/api/v1/device-scan`)
  * `Get-WUGDeviceRole`  -- Device-level role assignment (`GET /devices/{id}/roles/-`)
  * `Set-WUGDeviceRole`  -- Device/group role assignment (set kind, assign, remove, batch, group)
  * `Get-WUGDeviceReport -ReportType`  -- Umbrella parameter for all `/devices/{id}/reports/` endpoints
  * `Get-WUGDeviceGroupReport -ReportType`  -- Umbrella parameter for all `/device-groups/{id}/reports/` endpoints
  * `Add-WUGPerformanceMonitor`  -- Create + assign performance monitors (9 types: RestApi, PowerShell, WmiRaw, WmiFormatted, WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch)
  * `Add-WUGPerformanceMonitorToDevice`  -- Assign existing performance monitor templates to devices (bulk support)
  * `Add-WUGPassiveMonitor`  -- Create passive monitors (SnmpTrap with full property bags, Syslog, WinEvent)
  * `Add-WUGPassiveMonitorToDevice`  -- Assign existing passive monitors to devices (bulk support)
  * `Get-WUGCredential`  -- Retrieve credentials, templates, assignments, helpers (`/credentials/` endpoints)
  * `Add-WUGCredential`  -- Create new credentials (`POST /credentials`)
  * `Set-WUGCredential`  -- Update credentials, apply templates, bulk unassign (`PUT/PATCH/DELETE /credentials/`)
  * `Get-WUGDeviceInterface`  -- Retrieve device network interfaces (`GET /devices/{id}/interfaces`)
  * `Set-WUGDeviceInterface`  -- Update device interfaces; `-Batch` for bulk (`PUT/PATCH /devices/{id}/interfaces`)
  * `Add-WUGDeviceInterface`  -- Add a network interface to a device (`POST /devices/{id}/interfaces/-`)
  * `Remove-WUGDeviceInterface`  -- Remove one or all interfaces (`DELETE /devices/{id}/interfaces`)
  * `Get-WUGDeviceStatus`  -- Retrieve device status (`GET /devices/{id}/status`)
  * `Get-WUGDeviceCredential`  -- Retrieve device credential assignments (`GET /devices/{id}/credentials`)
  * `Set-WUGDeviceCredential`  -- Update device credential assignments (`PUT /devices/{id}/credentials`)
  * `Get-WUGDevicePollingConfig`  -- Retrieve device polling config (`GET /devices/{id}/config/polling`)
  * `Set-WUGDevicePollingConfig`  -- Update polling config; `-Batch` for cross-device bulk (`PUT/PATCH /devices/.../config/polling`)
  * `Invoke-WUGDevicePollNow`  -- Trigger immediate poll: single, batch, and device group (`POST/PATCH/PUT /devices/.../poll-now`)
  * `Get-WUGDeviceGroupMembership`  -- Retrieve device group membership (`GET /devices/{id}/group-membership`)
  * `Set-WUGDeviceGroupMembership`  -- Assign/batch group membership (`PUT/PATCH /devices/{id}/group-membership`)
  * `Set-WUGDeviceGroup`  -- Update device group properties, refresh, poll-now (`PUT/PATCH /device-groups/{id}`)
  * `Add-WUGDeviceGroup`  -- Create a child device group (`POST /device-groups/{id}/child`)
  * `Remove-WUGDeviceGroup`  -- Delete a device group (`DELETE /device-groups/{id}`)
  * `Add-WUGDeviceGroupMember`  -- Add devices to a device group (`POST /device-groups/{id}/devices/-`)
  * `Remove-WUGDeviceGroupMember`  -- Remove one/all devices from a group; supports device-side removal
  * `Remove-WUGDeviceAttribute`  -- Remove one or all custom attributes (`DELETE /devices/{id}/attributes`)
  * `Remove-WUGDeviceMonitor`  -- Remove a monitor assignment; `-All` to remove all (`DELETE /devices/{id}/monitors/`)
  * `Set-WUGMonitorTemplate`  -- Apply/import monitor templates, batch library ops, remove all assignments (`PATCH/DELETE /monitors/-/`)
  * `SupportsShouldProcess` / `ShouldProcess` gates on all state-modifying functions for `-WhatIf` and `-Confirm` support
  * `Remove-WUGDevice` now accepts `[string[]]` DeviceId with pipeline support

* Added  -- Helpers
  * helpers/templates/  -- Community device role template importer from progress/WhatsUp-Gold-Device-Templates GitHub repo
  * helpers/vmware/  -- VMware vSphere discovery/sync + dashboard (Get-VsphereDashboard, Export-VsphereDashboardHtml)
  * helpers/proxmox/  -- Proxmox VE discovery/sync + dashboard (Get-ProxmoxDashboard, Export-ProxmoxDashboardHtml)
  * helpers/hyperv/  -- Hyper-V discovery/sync + dashboard (Get-HypervDashboard, Export-HypervDashboardHtml)
  * helpers/nutanix/  -- Nutanix Prism discovery/sync + dashboard (Get-NutanixDashboard, Export-NutanixDashboardHtml)
  * helpers/azure/  -- Azure discovery/sync + dashboard (Get-AzureDashboard, Export-AzureDashboardHtml)
  * helpers/aws/  -- AWS discovery/sync + dashboard (Get-AWSDashboard, Export-AWSDashboardHtml)
  * helpers/gcp/  -- GCP discovery/sync + dashboard (Get-GCPDashboard, Export-GCPDashboardHtml)
  * helpers/oci/  -- OCI discovery/sync + dashboard (Get-OCIDashboard, Export-OCIDashboardHtml)
  * helpers/f5/  -- F5 BIG-IP dashboard suite (Connect-F5Server, Get-F5VirtualServers/Stats, Get-F5Pools/Members/Stats, Get-F5Nodes, Get-F5Dashboard, Export-F5DashboardHtml)
  * helpers/certificates/  -- SSL/TLS certificate scanner + dashboard (Get-CertificateInfo, Get-CertificateDashboard, Export-CertificateDashboardHtml) with expiry countdown highlighting
  * helpers/test/Invoke-WUGModuleTest.ps1  -- End-to-end integration test harness for all exported cmdlets
  * helpers/test/Invoke-WUGHelperTest.ps1  -- End-to-end integration test harness for cloud/infra provider helpers

* Changed  -- Existing Functions Enhanced
  * Split former `Get-WUGDeviceRole` mega-function: role library queries moved to `Get-WUGRole`; `Get-WUGDeviceRole` now only handles `GET /devices/{id}/roles/-`
  * Split former `Set-WUGDeviceRole` mega-function: library management moved to `Set-WUGRole`, import/export to `Import-WUGRoleTemplate` / `Export-WUGRoleTemplate`; `Set-WUGDeviceRole` now only handles device/group role assignments
  * `Add-WUGActiveMonitor`  -- 11 new PropertyBag monitor types: Dns, FileContent, FileProperties, Folder, Ftp, HttpContent, NetworkStatistics, PingJitter, PowerShell, RestApi, Ssh; plus SNMP Table property bags. Sensible defaults; override via `-PropertyBag` hashtable. Added `-DnsRecordType` convenience parameter.
  * `Add-WUGActiveMonitorToDevice`  -- Now supports `[string[]]` for both DeviceId and MonitorId for bulk assignment
  * `Get-WUGActiveMonitor`  -- Added `-MonitorId` (GET /monitors/{id}), `-MonitorAssignments` (GET /monitors/{id}/assignments/-), `-AllMonitors` (deprecated API param), `-Limit`
  * `Remove-WUGActiveMonitor`  -- Added `ById` (DELETE /monitors/{id}) and `RemoveAssignments` (DELETE /monitors/{id}/assignments/-) parameter sets; added `-Type` and `-FailIfInUse` query params
  * `Set-WUGActiveMonitor`  -- Added `BatchDeviceMonitors` mode (PATCH /devices/{id}/monitors/-)
  * `Get-WUGDeviceGroup`  -- Added `-Children`, `-GroupStatus`, `-GroupDevices`, `-GroupDeviceTemplates`, `-GroupDeviceCredentials`, `-Definition` parameter sets with full query params and pagination
  * `Get-WUGDeviceGroupMembership`  -- Added `-IsMember` / `-TargetGroupId` for `GET /devices/{id}/group/{gid}/is-member`
  * `Remove-WUGDeviceGroupMember`  -- Added `-FromDeviceId` / `-FromGroupId` for device-side removal
  * `Get-WUGMonitorTemplate`  -- Added `-SupportedTypes`, `-MonitorTemplate`, `-AllMonitorTemplates` parameter sets
  * `Get-WUGCredential`  -- Added `-CredentialTemplate`, `-AllCredentialTemplates`, `-Helpers`, `-AllAssignments` parameter sets; query params `-DeviceView`, `-Limit`, `-Key`, `-Type`, `-SearchValue`, `-Input` with pagination
  * `Get-WUGDevice`  -- Added `-ReturnHierarchy` and `-State` to search query
  * `Set-WUGDeviceAttribute`  -- Added `-Batch` parameter set (PATCH /devices/{id}/attributes/-)
  * `Set-WUGDeviceGroup -Refresh`  -- Added `-RefreshOptions`, `-DropDataOlderThanHours`, `-RefreshLimit`, `-ImmediateChildren`, `-Search`, `-UpdateNamesForInterfaceActiveMonitor`
  * `Set-WUGDeviceGroup -PollNow`  -- Added `-ImmediateChildren`, `-Search`, `-PollNowLimit`
  * `Set-WUGDeviceMaintenance`  -- Auto-routes single-device calls to `PUT /devices/{id}/config/maintenance` instead of batch
  * `Invoke-WUGDeviceRefresh`  -- Auto-routes single-device calls; added `-GroupId` for group refresh
  * `Invoke-WUGDevicePollNow`  -- Added `-GroupId` for device group poll-now
  * `Get-WUGProduct`  -- Added `/api/v1/product/api` endpoint (`apiVersion` property)
  * Replaced all `Write-Host` calls with `Write-Verbose` (success), `Write-Warning` (skip/caution), or `Write-Debug` (diagnostic)  -- 34 replacements across 18 files
  * Usability: `Get-WUGDeviceGroupReport` defaults GroupId to -2 (All Devices); all 12 report variants follow suit
  * Usability: `Get-WUGDeviceReport` and all 11 report variants auto-fetch all device IDs when DeviceId omitted
  * Usability: `Get-WUGDeviceAttribute`, `Get-WUGDeviceProperties`, `Get-WUGDeviceTemplate`, `Get-WUGDeviceMaintenanceSchedule` auto-fetch all devices when DeviceId omitted
  * Restructured `Get-WUGDeviceReportMemory` to collect-then-iterate pattern
  * Reorganized helpers/ into subdirectories: reports/, vmware/, proxmox/, etc.
  * Removed ghost exports `Add-WUGDevices`, `ConvertTo-BootstrapTable`, `Convert-HTMLTemplate`
  * Changed `Remove-WUGDevices -DeleteDiscoveredDevices` from `[bool]` to `[switch]`

* Bugfixes
  * UTF-8 BOM added to all files for max compatibility
  * Fixed `Set-WUGActiveMonitor` using `/api/v1/monitor/{id}` (singular)  -- changed to `/api/v1/monitors/{id}` (plural)
  * Fixed `Invoke-WUGDevicePollNow` using incorrect paths  -- changed to `PUT /poll-now` (single) and `PATCH /-/poll-now` (batch)
  * Fixed `Invoke-WUGDeviceRefresh` batch path `PATCH /devices/refresh`  -- changed to `PATCH /devices/-/refresh`
  * Fixed `Add-WUGCredential` sending mixed-case `type` values causing 400  -- API requires lowercase; also fixed SSH requiring ConfirmPassword/ConfirmEnablePassword bags, and body always including `description`/`propertyBags`
  * Fixed `Add-WUGActiveMonitor -Type Ftp`  -- wrong classId and property bag prefix
  * Fixed `Add-WUGPassiveMonitor -Type Syslog` and `-Type WinEvent`  -- were stubbed out; fully implemented
  * Fixed `Remove-WUGDevice` using undefined `$id` variable instead of `$DeviceId`
  * Fixed `Set-WUGActiveMonitor` inverted boolean logic  -- replaced `!$Enabled`/`!$UseInDiscovery` with `$PSBoundParameters.ContainsKey()`
  * Fixed `Set-WUGDeviceProperties` duplicate API call overwriting accumulated results; also fixed boolean params using `if ($var)` instead of `$PSBoundParameters.ContainsKey()`
  * Fixed `$ReturnHierarchy` never appended to query string in all 12 `Get-WUGDeviceGroupReport` variants
  * Fixed `Get-WUGDeviceGroupReportPingAvailability` ValidateSet using memory report fields
  * Fixed `Get-WUGDeviceGroupReportMaintenance` referencing undeclared threshold params
  * Fixed `Get-WUGDeviceGroupReportStateChange` and `Get-WUGDeviceReportStateChange` missing threshold params in param block
  * Fixed `Get-WUGDeviceReportInterfaceErrors` `[bool]` types and `[int]$PageId`  -- changed to `[ValidateSet][string]`
  * Fixed `Get-WUGDeviceGroupReportDisk` abbreviated GroupBy values
  * Fixed `Get-WUGDeviceGroupReportMaintenance` GroupBy starting with `defaultColumn` instead of `noGrouping`
  * Fixed `Get-WUGDeviceGroupReportPingResponseTime` and `Get-WUGDeviceReportPingResponseTime` lowercase threshold params
  * Fixed `Add-WUGDeviceTemplates` request body using hardcoded `@("all")` instead of `$options` variable
  * Fixed `Disconnect-WUGServer` referencing `$global:WhatsUpServerBaseURI` after clearing it
  * Fixed `Invoke-WUGDeviceRefresh` `DropDataOlderThanHours` always being sent  -- `[int]` defaults to 0
  * Fixed `!$null -eq $queryString` null-check in 13 report functions  -- corrected to `$null -ne $queryString`
  * Fixed stray backtick in `Set-WUGDeviceMaintenance`, stray `#>` in `Get-WUGDeviceMaintenanceSchedule`
  * Fixed malformed help block in `Add-WUGDeviceTemplates`
  * Restored `AllMonitors` (deprecated) in `Get-WUGActiveMonitor`
  * Added missing `Set-WUGMonitorTemplate`/`Set-WUGDeviceGroupMembership` exports to psm1

* Documentation
  * Rewrote README.MD with full function reference table, quick start guide, report parameter reference, and helper script directory listing
  * Added full CBH (.SYNOPSIS, .DESCRIPTION, .PARAMETER, .EXAMPLE, .NOTES) to all new and enhanced functions
  * Added .EXAMPLE sections to all 63+ existing helper functions across all subdirectories
  * Added comprehensive CBH to all dashboard helper functions and orchestration scripts across all platforms


## 0.1.17/18 - 2025-12-08
* Changed
  * Use new endpoint for Add-WUGDevice, allowing for discovery
  * Moved Add-WUGDevices to Add-WUGDeviceTemplates and added them to the psd1

* Added
  * Add-WUGDeviceTemplate replaces old Add-WUGDevice functionality


## 0.1.15/16 - 2025-12-03
* Changed
  * Copilot suggested improvements to error handling [14 files suggested]
  * Fixed issue with Add-WUGDevice and attribute handling
  * Removed action policy from New_device.ps1 example so it will work when run
  
* Added
  * Invoke-WUGDeviceRefresh (WIP)
  * Set-WUGActiveMontior and Get-WUGActiveMonitor (WIP)
  * Get-WUGDeviceReport (WIP)
* Removed
  * Soon plan to remove Get-WUGDeviceReportXXXX and replace with -ReportType parameter on Get-WUGDeviceReport
  * Soon plan to remove Get-WUGDeviceGroupReportXXXX and replace with -ReportType parameter on Get-WUGDeviceGroupReport

## 0.1.14 - 2025-04-06
* Changed
  * Try to fix problems with Set-WUGDeviceMaintenanceSchedule -EffectiveExpirationDate parameter
  * Fixed Add-WUGDevice not handling device attributes
  * Resigned everything with recovered certificate
  * Updated example Custom_report.ps1
* Added
  * Get-WUGMonitorTemplate
  * Add-WUGActiveMonitor (WIP, use at own risk)
  * Remove-WUGActiveMonitor
  * Add-WUGActiveMonitorToDevice (WIP, use at own risk)
  
## 0.1.13 - 2024-09-28
* Changed
   * Refactor many functions to accept value from pipeline, example: Get-WUGDevice | Get-WUGDeviceCPUReport
   * Moved  global variable checking into Get-WUGAPIRequest, which attempts to auto refresh existing tokens
   * Learning parameter sets

* Added
   * Get-WUGDeviceMaintenanceSchedule, Set-WUGDeviceMaintenanceSchedule

* Removed
   * Request-WUGAuthToken, built into Get-WUGAPIResponse
   * Get-WUGDeviceAttributes, built into Get-WUGDeviceAttribute
   * Set-WUGDeviceAttributes, built into Set-WUGDeviceAttribute
   * Get-WUGDevices, built into Get-WUGDevice.
   * Get-WUGDeviceGroups, built into Get-WUGDeviceGroup

## 0.1.12 - 2024-08-23
### Changed
* Changed
  * Connect-WUGServer -IgnoreSSLErrors parameter now tries to force ignoring certificate errors
  * Refactor Connnect-WUGServer, Disconnect-WUGServer, Get-WUGAPIResponse, Get-WUGDevice, Get-WUGDeviceAttribute Get-WUGDeviceAttributes, Get-WUGDeviceGroup, Get-WUGDeviceGroups, Get-WUGDevices, Get-WUGDeviceTemplate, Remove-WUGDevice, Remove-WUGDevices, Set-WUGDeviceAttribute, Set-WUGDeviceAttributes, Set-WUGDeviceMaintenance, Set-WUGDeviceProperties

## 0.1.11 - 2024-04-01
### Changed
* Functions
  * Added
   * Get-WUGDeviceGroupReportCpu
   * Get-WUGDeviceGroupReportDiskSpaceFree
   * Get-WUGDeviceGroupReportDisk
   * Get-WUGDeviceGroupReportinterfaceDiscards
   * Get-WUGDeviceGroupReportinterfaceErrors
   * Get-WUGDeviceGroupReportinterfaceTraffic
   * Get-WUGDeviceGroupReportinterface
   * Get-WUGDeviceGroupReportMaintenance
   * Get-WUGDeviceGroupReportMemory
   * Get-WUGDeviceGroupReportPingAvailability
   * Get-WUGDeviceGroupReportPingResponseTime
   * Get-WUGDeviceGroupReportStateChange

 
  * Changed
   * -Limit parameter was set to a default value on some fuctions
   * -Limit parameter now has input validation on all functions
   * Fixed empty query string problems caused by the above change
  
## 0.1.10 - 2024-03-29
### Changed
* Functions
  * Get-WUGDeviceReportCpu added
  * Get-WUGDeviceReportDisk added
  * Get-WUGDeviceReportDiskSpaceFree added
  * Get-WUGDeviceReportInterface added
  * Get-WUGDeviceReportInterfaceDiscards added
  * Get-WUGDeviceReportInterfaceErrors added
  * Get-WUGDeviceReportInterfaceTraffic added
  * Get-WUGDeviceReportMemory added
  * Get-WUGDeviceReportPingAvailability added
  * Get-WUGDeviceReportPingResponseTime added
  * Get-WUGDeviceReportStateChange added
  * Small formatting changes on Get-WUGDeviceGroup, Get-WUGDeviceGroups, and Get-WUGDeviceAttributes

## 0.1.9 - ??
### I forgot to document, sorry!

## 0.1.8 - 2024-03-02
### Changed
* Functions
  * Add-WUGDevice - Parameters for credentials and subroles
 
## 0.1.1-0.1.7 - Release Date
### I forgot to document, sorry!

## Version Number - Release Date
0.1 - 2023-03-14

### Fixed
* Nothing, I dunno what's broken yet.

### Added
* Functions
  * Connect-WUGServer - Obtain authorization token for future API calls
  * Get-WUGAPIResponse - Handles all WhatsUp Gold API calls
  * Get-WUGDevice - Returns information from a single device using the DeviceID
  * Get-WUGDevices - Returns information for multiple devices using 
  * Get-WUGDeviceTemplate - Returns information for a single device template (for use with New-WUGDevices -Template $template)
  * New-WUGDevice - Add a single new device to be monitored using your own device template, or use pieces of other templates returned by Get-WUGDeviceTemplate.
  * New-WUGDevices - Add multiple new devices to be monitored
  * Remove-WUGDevice - Remove a single device from monitoring
  * Remove-WUGDevices - Remove multiple devices from monitoring
  * Set-WUGDeviceMaintenance - Enable or disable maintenance mode any amount devices
  * Set-WUGDeviceProperties - Set device properties for any amount of devices

### Changed
