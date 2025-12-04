# WhatsUpGoldPS Release History
## 0.1.17 - 2025-12-04
* Changed
  * Use new endpoint for Add-WUGDevice, allowing for discovery
  * Moved Add-WUGDevices to Add-WUGDeviceTemplates

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
