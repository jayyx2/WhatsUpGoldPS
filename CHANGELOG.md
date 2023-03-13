# WhatsUpGoldPS Release History

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
