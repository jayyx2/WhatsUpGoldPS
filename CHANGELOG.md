# WhatsUpGoldPS Release History
## 0.1.19 - 2026-03-08 [not going to PSGallery release yet, need more testing]
* Changed
  * Added SNMP Table property bags to Add-WUGActiveMonitor for /api/v1/monitors endpoints
  * Updated all signatures with new certificate
  * Reorganized helpers/ into subdirectories: reports/, vmware/, proxmox/
  * Moved examples/Custom_report.ps1, examples/Bootstrap-Table-Sample.html → helpers/reports/
  * Moved examples/Rename_and_update_devices_based_on_vCenter_data.ps1 → helpers/vmware/
  * Moved helpers/ConvertTo-BootstrapTable.ps1, helpers/ConvertTo-HTMLTemplate.ps1 → helpers/reports/
  * Fixed malformed comment-based help block in Add-WUGDeviceTemplates (corrected EXAMPLES → .EXAMPLE, moved Author into .NOTES)
  * Removed ghost exports `Add-WUGDevices`, `ConvertTo-BootstrapTable`, `Convert-HTMLTemplate` from psd1 FunctionsToExport and psm1 Export-ModuleMember
  * Usability: Get-WUGDeviceGroupReport now defaults GroupId to -2 (All Devices) when not specified
  * Usability: Get-WUGDeviceReport now defaults to all devices via Get-WUGDevice when DeviceId is not specified
  * Usability: Get-WUGDeviceAttribute DeviceId no longer mandatory; auto-fetches all device IDs when omitted
  * Usability: Get-WUGDeviceProperties DeviceId no longer mandatory; auto-fetches all device IDs when omitted
  * Usability: Get-WUGDeviceTemplate DeviceId no longer mandatory; auto-fetches all device IDs when omitted
  * Usability: Get-WUGDeviceMaintenanceSchedule DeviceId no longer mandatory; auto-fetches all device IDs when omitted
  * Usability: All 12 Get-WUGDeviceGroupReportXXXX variants now default GroupId to -2 (All Devices) when not specified
  * Usability: All 11 Get-WUGDeviceReportXXXX variants DeviceId no longer mandatory; auto-fetches all device IDs when omitted
  * Restructured Get-WUGDeviceReportMemory from process-block iteration to collect-then-iterate pattern (consistent with other report variants)

* Bugfixes
  * Fixed Remove-WUGDevice using undefined `$id` variable instead of `$DeviceId` in output/warning/error messages
  * Fixed Set-WUGActiveMonitor inverted boolean logic: `!$Enabled` and `!$UseInDiscovery` checks were only including API properties when values were falsy; replaced with `$PSBoundParameters.ContainsKey()` checks (4 locations)
  * Fixed Set-WUGDeviceProperties duplicate API call after batch loop that overwrote accumulated `$finalresult` with only last batch's data
  * Restored `AllMonitors` (deprecated API param) in Get-WUGActiveMonitor — added as a proper parameter with query string support
  * Fixed stray backtick in Set-WUGDeviceMaintenance API call
  * Fixed `$ReturnHierarchy` param declared but never appended to query string in all 12 Get-WUGDeviceGroupReport variants (Cpu, Disk, DiskSpaceFree, Interface, InterfaceDiscards, InterfaceErrors, InterfaceTraffic, Maintenance, Memory, PingAvailability, PingResponseTime, StateChange)
  * Fixed Get-WUGDeviceGroupReportPingAvailability SortBy/GroupBy ValidateSet using memory report fields instead of ping availability fields
  * Fixed Get-WUGDeviceGroupReportMaintenance query builder referencing `$ApplyThreshold`/`$OverThreshold`/`$ThresholdValue` not declared in param block (API does not support thresholds for maintenance) — removed ghost refs
  * Fixed Get-WUGDeviceGroupReportStateChange and Get-WUGDeviceReportStateChange query builders referencing threshold params not in param block — added `$ApplyThreshold`, `$OverThreshold`, `$ThresholdValue` to param blocks
  * Fixed Get-WUGDeviceReportInterfaceErrors `[bool]` types for `$ApplyThreshold`, `$OverThreshold`, `$RollupByDevice` (sends True/False not true/false) — changed to `[ValidateSet("true","false")][string]`; fixed `[int]$PageId` to `[string]$PageId`
  * Fixed Get-WUGDeviceGroupReportDisk abbreviated GroupBy values (`mi`, `ma`, `av`) — replaced with full field names (`minUsed`, `maxUsed`, `avgUsed`, etc.)
  * Fixed Get-WUGDeviceGroupReportMaintenance GroupBy ValidateSet starting with `defaultColumn` instead of `noGrouping`
  * Fixed Get-WUGDeviceGroupReportPingResponseTime and Get-WUGDeviceReportPingResponseTime lowercase threshold param names (`$applyThreshold` etc.) — renamed to PascalCase (`$ApplyThreshold` etc.)
  * Added missing `$Limit` parameter to Get-WUGActiveMonitor (API supports `limit` on templates, device assignments, and global assignments endpoints)
  * Added missing `$ReturnHierarchy` and `$State` parameters to Get-WUGDevice search query (GET /device-groups/{groupId}/devices/- endpoint)
  * Fixed Set-WUGDeviceProperties boolean params (`$isWireless`, `$collectWireless`, `$keepDetailsCurrent`) using `if ($var)` which fails when setting to `$false` — replaced with `$PSBoundParameters.ContainsKey()` (both single and batch code paths)
  * Fixed Add-WUGDeviceTemplates request body using hardcoded `@("all")` instead of the `$options` variable built from switch parameters (`ApplyL2`, `Update`, `UpdateInterfaceState`, `UpdateInterfaceNames`, `UpdateActiveMonitors`)
  * Fixed Disconnect-WUGServer `Write-Information` referencing `$global:WhatsUpServerBaseURI` after it was already set to `$null` — moved message before clearing globals, changed wording to "Disconnecting from"
  * Fixed Invoke-WUGDeviceRefresh `DropDataOlderThanHours` always being sent in the request body — `[int]` defaults to 0 which is `-ne $null`; replaced with `$PSBoundParameters.ContainsKey()` check
  * Fixed stray `#>` comment terminator after help block in Get-WUGDeviceMaintenanceSchedule
  * Fixed `!$null -eq $queryString` null-check logic in 13 report functions — expression parsed as `(!$null) -eq $queryString` (always `$true` for non-empty strings by accident); corrected to `$null -ne $queryString`
  * Changed Remove-WUGDevices `$DeleteDiscoveredDevices` from `[bool]` to `[switch]` for idiomatic PowerShell usage

* Enhancements
  * Remove-WUGDevice now accepts an array of DeviceIds (`[string[]]`) with pipeline support, loops through each device individually via DELETE endpoint

* Added
  * Get-WUGDeviceReport (-ReportType parameter) now can be used instead of individual Get-WUGDeviceReportXXXX functions for /api/v1/devices/{id}/reports endpoints (Cpu, Disk, DiskSpaceFree, Interface, InterfaceDiscards, InterfaceErrors, InterfaceTraffic, Memory, PingAvailability, PingResponseTime, StateChange)
  * Get-WUGDeviceGroupReport (-ReportType parameter) now can be used instead of Get-WUGDeviceGroupReportXXXX functions for /api/v1/device-groups/{id}/reports endpoints (Cpu, Disk, DiskSpaceFree, Interface, InterfaceDiscards, InterfaceErrors, InterfaceTraffic, Memory, PingAvailability, PingResponseTime, StateChange, Maintenance)
  * Get-WUGProduct for /api/v1/product endpoints
  * Get-WUGDeviceScan for /api/v1/device-scan endpoints
  * Get-WUGDeviceRole and Set-WUGDeviceRole for /api/v1/device-role endpoints
  * helpers/vmware/ - New VMware vSphere discovery and sync scripts (discover-vsphere-immediate-add-with-attributes.ps1, discover-vsphere-nodes-and-guests-discover-then-add.ps1)
  * helpers/proxmox/ - New Proxmox VE discovery and sync scripts (ProxmoxHelpers.ps1, discover-proxmox-nodes-and-guests scripts, Rename_and_update_devices_based_on_Proxmox_data.ps1)
  * helpers/hyperv/ - New Hyper-V discovery and sync scripts (HypervHelpers.ps1, discover-hyperv-immediate-add-with-attributes.ps1, discover-hyperv-hosts-and-guests-discover-then-add.ps1)
  * helpers/nutanix/ - New Nutanix Prism discovery and sync scripts (NutanixHelpers.ps1, discover-nutanix-immediate-add-with-attributes.ps1, discover-nutanix-hosts-and-guests-discover-then-add.ps1)
  * helpers/azure/ - New Azure discovery and sync scripts (AzureHelpers.ps1, discover-azure-immediate-add-with-attributes.ps1, discover-azure-resources-discover-then-add.ps1) — enumerates subscriptions, resource groups, resources, and metrics via Az modules; stores ResourceId and metric data as device attributes
  * helpers/aws/ - New AWS discovery and sync scripts (AWSHelpers.ps1, discover-aws-immediate-add-with-attributes.ps1, discover-aws-resources-discover-then-add.ps1) — enumerates EC2 instances, RDS databases, and ELBv2 load balancers across regions via AWS.Tools modules; stores instance IDs, ARNs, and CloudWatch metrics as device attributes
  * helpers/gcp/ - New GCP discovery and sync scripts (GCPHelpers.ps1, discover-gcp-immediate-add-with-attributes.ps1, discover-gcp-resources-discover-then-add.ps1) — enumerates Compute Engine VMs, Cloud SQL instances, and forwarding rules across projects via GoogleCloud module + gcloud CLI; stores instance IDs and Cloud Monitoring metrics as device attributes
  * helpers/oci/ - New Oracle Cloud Infrastructure discovery and sync scripts (OCIHelpers.ps1, discover-oci-immediate-add-with-attributes.ps1, discover-oci-resources-discover-then-add.ps1) — enumerates Compute instances, DB Systems, Autonomous Databases, and Load Balancers across compartments and regions via OCI.PSModules + OCI CLI; stores OCIDs and OCI Monitoring metrics as device attributes

* Documentation
  * Added full comment-based help (.SYNOPSIS, .DESCRIPTION, .PARAMETER, .EXAMPLE, .NOTES) to Add-WUGActiveMonitorToDevice, Get-WUGMonitorTemplate, Remove-WUGActiveMonitor, Get-WUGDeviceGroupReport
  * Added .EXAMPLE sections to Add-WUGDeviceTemplates, Set-WUGDeviceProperties
  * Added .NOTES to Get-WUGDevice, Get-WUGDeviceReport, Get-WUGDeviceScan
  * Added missing .PARAMETER help: Get-WUGDevice (ReturnHierarchy, State), Get-WUGDeviceReportPingAvailability (6 threshold params), Get-WUGDeviceReportPingResponseTime (ApplyThreshold, OverThreshold, ThresholdValue), Get-WUGActiveMonitor (AllMonitors, Limit, activeObj, active), Get-WUGDeviceRole (7 switch/kind params), Add-WUGActiveMonitor (UseInDiscovery + 15 SNMPTable params), Set-WUGDeviceProperties (actionPolicyName, actionPolicyId)
  * Fixed Add-WUGDeviceTemplates .PARAMETER name mismatch (`templates` → `deviceTemplates`)
  * Rewrote README.MD with full function reference table, quick start guide, report parameter reference, and helper script directory listing


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
