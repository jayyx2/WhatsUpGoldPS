# WhatsUpGoldPS Release History
## 0.1.19/20 - 2026-03-15 [Released to PowerShell Gallery]
* Added — New Functions (85 total exports; psm1 and psd1 in sync)
  * `Get-WUGRole` — Browse the device role library: by ID, list all, assignments, templates, percent variables (`/device-role/` endpoints)
  * `Set-WUGRole` — Manage the device role library: delete, enable, disable, restore roles; apply templates via PATCH
  * `Import-WUGRoleTemplate` — Import and verify device role packages (`POST /device-role/-/config/import[/verify]`)
  * `Export-WUGRoleTemplate` — Export device role packages and inventory (`POST /device-role/-/config/export[/content]`) *(disabled — API returns 400; not exported until upstream fix)*
  * `Import-WUGMonitorTemplate` — Import monitor templates via `PATCH /monitors/-/config/template` with `-Options` (all/clone/transfer/update)
  * `Get-WUGProduct` — Product info + API version (`/api/v1/product`, `/api/v1/product/api`)
  * `Get-WUGDeviceScan` — Device scan endpoints (`/api/v1/device-scan`)
  * `Get-WUGDeviceRole` — Device-level role assignment (`GET /devices/{id}/roles/-`)
  * `Set-WUGDeviceRole` — Device/group role assignment (set kind, assign, remove, batch, group)
  * `Get-WUGDeviceReport -ReportType` — Umbrella parameter for all `/devices/{id}/reports/` endpoints
  * `Get-WUGDeviceGroupReport -ReportType` — Umbrella parameter for all `/device-groups/{id}/reports/` endpoints
  * `Add-WUGPerformanceMonitor` — Create + assign performance monitors (9 types: RestApi, PowerShell, WmiRaw, WmiFormatted, WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch)
  * `Add-WUGPerformanceMonitorToDevice` — Assign existing performance monitor templates to devices (bulk support)
  * `Add-WUGPassiveMonitor` — Create passive monitors (SnmpTrap with full property bags, Syslog, WinEvent)
  * `Add-WUGPassiveMonitorToDevice` — Assign existing passive monitors to devices (bulk support)
  * `Get-WUGCredential` — Retrieve credentials, templates, assignments, helpers (`/credentials/` endpoints)
  * `Add-WUGCredential` — Create new credentials (`POST /credentials`)
  * `Set-WUGCredential` — Update credentials, apply templates, bulk unassign (`PUT/PATCH/DELETE /credentials/`)
  * `Get-WUGDeviceInterface` — Retrieve device network interfaces (`GET /devices/{id}/interfaces`)
  * `Set-WUGDeviceInterface` — Update device interfaces; `-Batch` for bulk (`PUT/PATCH /devices/{id}/interfaces`)
  * `Add-WUGDeviceInterface` — Add a network interface to a device (`POST /devices/{id}/interfaces/-`)
  * `Remove-WUGDeviceInterface` — Remove one or all interfaces (`DELETE /devices/{id}/interfaces`)
  * `Get-WUGDeviceStatus` — Retrieve device status (`GET /devices/{id}/status`)
  * `Get-WUGDeviceCredential` — Retrieve device credential assignments (`GET /devices/{id}/credentials`)
  * `Set-WUGDeviceCredential` — Update device credential assignments (`PUT /devices/{id}/credentials`)
  * `Get-WUGDevicePollingConfig` — Retrieve device polling config (`GET /devices/{id}/config/polling`)
  * `Set-WUGDevicePollingConfig` — Update polling config; `-Batch` for cross-device bulk (`PUT/PATCH /devices/.../config/polling`)
  * `Invoke-WUGDevicePollNow` — Trigger immediate poll: single, batch, and device group (`POST/PATCH/PUT /devices/.../poll-now`)
  * `Get-WUGDeviceGroupMembership` — Retrieve device group membership (`GET /devices/{id}/group-membership`)
  * `Set-WUGDeviceGroupMembership` — Assign/batch group membership (`PUT/PATCH /devices/{id}/group-membership`)
  * `Set-WUGDeviceGroup` — Update device group properties, refresh, poll-now (`PUT/PATCH /device-groups/{id}`)
  * `Add-WUGDeviceGroup` — Create a child device group (`POST /device-groups/{id}/child`)
  * `Remove-WUGDeviceGroup` — Delete a device group (`DELETE /device-groups/{id}`)
  * `Add-WUGDeviceGroupMember` — Add devices to a device group (`POST /device-groups/{id}/devices/-`)
  * `Remove-WUGDeviceGroupMember` — Remove one/all devices from a group; supports device-side removal
  * `Remove-WUGDeviceAttribute` — Remove one or all custom attributes (`DELETE /devices/{id}/attributes`)
  * `Remove-WUGDeviceMonitor` — Remove a monitor assignment; `-All` to remove all (`DELETE /devices/{id}/monitors/`)
  * `Set-WUGMonitorTemplate` — Apply/import monitor templates, batch library ops, remove all assignments (`PATCH/DELETE /monitors/-/`)
  * `SupportsShouldProcess` / `ShouldProcess` gates on all state-modifying functions for `-WhatIf` and `-Confirm` support
  * `Remove-WUGDevice` now accepts `[string[]]` DeviceId with pipeline support

* Added — Helpers
  * helpers/templates/ — Community device role template importer from progress/WhatsUp-Gold-Device-Templates GitHub repo
  * helpers/vmware/ — VMware vSphere discovery/sync + dashboard (Get-VsphereDashboard, Export-VsphereDashboardHtml)
  * helpers/proxmox/ — Proxmox VE discovery/sync + dashboard (Get-ProxmoxDashboard, Export-ProxmoxDashboardHtml)
  * helpers/hyperv/ — Hyper-V discovery/sync + dashboard (Get-HypervDashboard, Export-HypervDashboardHtml)
  * helpers/nutanix/ — Nutanix Prism discovery/sync + dashboard (Get-NutanixDashboard, Export-NutanixDashboardHtml)
  * helpers/azure/ — Azure discovery/sync + dashboard (Get-AzureDashboard, Export-AzureDashboardHtml)
  * helpers/aws/ — AWS discovery/sync + dashboard (Get-AWSDashboard, Export-AWSDashboardHtml)
  * helpers/gcp/ — GCP discovery/sync + dashboard (Get-GCPDashboard, Export-GCPDashboardHtml)
  * helpers/oci/ — OCI discovery/sync + dashboard (Get-OCIDashboard, Export-OCIDashboardHtml)
  * helpers/f5/ — F5 BIG-IP dashboard suite (Connect-F5Server, Get-F5VirtualServers/Stats, Get-F5Pools/Members/Stats, Get-F5Nodes, Get-F5Dashboard, Export-F5DashboardHtml)
  * helpers/certificates/ — SSL/TLS certificate scanner + dashboard (Get-CertificateInfo, Get-CertificateDashboard, Export-CertificateDashboardHtml) with expiry countdown highlighting
  * helpers/test/Invoke-WUGModuleTest.ps1 — End-to-end integration test harness for all exported cmdlets
  * helpers/test/Invoke-WUGHelperTest.ps1 — End-to-end integration test harness for cloud/infra provider helpers

* Changed — Existing Functions Enhanced
  * Split former `Get-WUGDeviceRole` mega-function: role library queries moved to `Get-WUGRole`; `Get-WUGDeviceRole` now only handles `GET /devices/{id}/roles/-`
  * Split former `Set-WUGDeviceRole` mega-function: library management moved to `Set-WUGRole`, import/export to `Import-WUGRoleTemplate` / `Export-WUGRoleTemplate`; `Set-WUGDeviceRole` now only handles device/group role assignments
  * `Add-WUGActiveMonitor` — 11 new PropertyBag monitor types: Dns, FileContent, FileProperties, Folder, Ftp, HttpContent, NetworkStatistics, PingJitter, PowerShell, RestApi, Ssh; plus SNMP Table property bags. Sensible defaults; override via `-PropertyBag` hashtable. Added `-DnsRecordType` convenience parameter.
  * `Add-WUGActiveMonitorToDevice` — Now supports `[string[]]` for both DeviceId and MonitorId for bulk assignment
  * `Get-WUGActiveMonitor` — Added `-MonitorId` (GET /monitors/{id}), `-MonitorAssignments` (GET /monitors/{id}/assignments/-), `-AllMonitors` (deprecated API param), `-Limit`
  * `Remove-WUGActiveMonitor` — Added `ById` (DELETE /monitors/{id}) and `RemoveAssignments` (DELETE /monitors/{id}/assignments/-) parameter sets; added `-Type` and `-FailIfInUse` query params
  * `Set-WUGActiveMonitor` — Added `BatchDeviceMonitors` mode (PATCH /devices/{id}/monitors/-)
  * `Get-WUGDeviceGroup` — Added `-Children`, `-GroupStatus`, `-GroupDevices`, `-GroupDeviceTemplates`, `-GroupDeviceCredentials`, `-Definition` parameter sets with full query params and pagination
  * `Get-WUGDeviceGroupMembership` — Added `-IsMember` / `-TargetGroupId` for `GET /devices/{id}/group/{gid}/is-member`
  * `Remove-WUGDeviceGroupMember` — Added `-FromDeviceId` / `-FromGroupId` for device-side removal
  * `Get-WUGMonitorTemplate` — Added `-SupportedTypes`, `-MonitorTemplate`, `-AllMonitorTemplates` parameter sets
  * `Get-WUGCredential` — Added `-CredentialTemplate`, `-AllCredentialTemplates`, `-Helpers`, `-AllAssignments` parameter sets; query params `-DeviceView`, `-Limit`, `-Key`, `-Type`, `-SearchValue`, `-Input` with pagination
  * `Get-WUGDevice` — Added `-ReturnHierarchy` and `-State` to search query
  * `Set-WUGDeviceAttribute` — Added `-Batch` parameter set (PATCH /devices/{id}/attributes/-)
  * `Set-WUGDeviceGroup -Refresh` — Added `-RefreshOptions`, `-DropDataOlderThanHours`, `-RefreshLimit`, `-ImmediateChildren`, `-Search`, `-UpdateNamesForInterfaceActiveMonitor`
  * `Set-WUGDeviceGroup -PollNow` — Added `-ImmediateChildren`, `-Search`, `-PollNowLimit`
  * `Set-WUGDeviceMaintenance` — Auto-routes single-device calls to `PUT /devices/{id}/config/maintenance` instead of batch
  * `Invoke-WUGDeviceRefresh` — Auto-routes single-device calls; added `-GroupId` for group refresh
  * `Invoke-WUGDevicePollNow` — Added `-GroupId` for device group poll-now
  * `Get-WUGProduct` — Added `/api/v1/product/api` endpoint (`apiVersion` property)
  * Replaced all `Write-Host` calls with `Write-Verbose` (success), `Write-Warning` (skip/caution), or `Write-Debug` (diagnostic) — 34 replacements across 18 files
  * Usability: `Get-WUGDeviceGroupReport` defaults GroupId to -2 (All Devices); all 12 report variants follow suit
  * Usability: `Get-WUGDeviceReport` and all 11 report variants auto-fetch all device IDs when DeviceId omitted
  * Usability: `Get-WUGDeviceAttribute`, `Get-WUGDeviceProperties`, `Get-WUGDeviceTemplate`, `Get-WUGDeviceMaintenanceSchedule` auto-fetch all devices when DeviceId omitted
  * Restructured `Get-WUGDeviceReportMemory` to collect-then-iterate pattern
  * Reorganized helpers/ into subdirectories: reports/, vmware/, proxmox/, etc.
  * Removed ghost exports `Add-WUGDevices`, `ConvertTo-BootstrapTable`, `Convert-HTMLTemplate`
  * Changed `Remove-WUGDevices -DeleteDiscoveredDevices` from `[bool]` to `[switch]`

* Bugfixes
  * UTF-8 BOM added to all files for max compatibility
  * Fixed `Set-WUGActiveMonitor` using `/api/v1/monitor/{id}` (singular) — changed to `/api/v1/monitors/{id}` (plural)
  * Fixed `Invoke-WUGDevicePollNow` using incorrect paths — changed to `PUT /poll-now` (single) and `PATCH /-/poll-now` (batch)
  * Fixed `Invoke-WUGDeviceRefresh` batch path `PATCH /devices/refresh` — changed to `PATCH /devices/-/refresh`
  * Fixed `Add-WUGCredential` sending mixed-case `type` values causing 400 — API requires lowercase; also fixed SSH requiring ConfirmPassword/ConfirmEnablePassword bags, and body always including `description`/`propertyBags`
  * Fixed `Add-WUGActiveMonitor -Type Ftp` — wrong classId and property bag prefix
  * Fixed `Add-WUGPassiveMonitor -Type Syslog` and `-Type WinEvent` — were stubbed out; fully implemented
  * Fixed `Remove-WUGDevice` using undefined `$id` variable instead of `$DeviceId`
  * Fixed `Set-WUGActiveMonitor` inverted boolean logic — replaced `!$Enabled`/`!$UseInDiscovery` with `$PSBoundParameters.ContainsKey()`
  * Fixed `Set-WUGDeviceProperties` duplicate API call overwriting accumulated results; also fixed boolean params using `if ($var)` instead of `$PSBoundParameters.ContainsKey()`
  * Fixed `$ReturnHierarchy` never appended to query string in all 12 `Get-WUGDeviceGroupReport` variants
  * Fixed `Get-WUGDeviceGroupReportPingAvailability` ValidateSet using memory report fields
  * Fixed `Get-WUGDeviceGroupReportMaintenance` referencing undeclared threshold params
  * Fixed `Get-WUGDeviceGroupReportStateChange` and `Get-WUGDeviceReportStateChange` missing threshold params in param block
  * Fixed `Get-WUGDeviceReportInterfaceErrors` `[bool]` types and `[int]$PageId` — changed to `[ValidateSet][string]`
  * Fixed `Get-WUGDeviceGroupReportDisk` abbreviated GroupBy values
  * Fixed `Get-WUGDeviceGroupReportMaintenance` GroupBy starting with `defaultColumn` instead of `noGrouping`
  * Fixed `Get-WUGDeviceGroupReportPingResponseTime` and `Get-WUGDeviceReportPingResponseTime` lowercase threshold params
  * Fixed `Add-WUGDeviceTemplates` request body using hardcoded `@("all")` instead of `$options` variable
  * Fixed `Disconnect-WUGServer` referencing `$global:WhatsUpServerBaseURI` after clearing it
  * Fixed `Invoke-WUGDeviceRefresh` `DropDataOlderThanHours` always being sent — `[int]` defaults to 0
  * Fixed `!$null -eq $queryString` null-check in 13 report functions — corrected to `$null -ne $queryString`
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
