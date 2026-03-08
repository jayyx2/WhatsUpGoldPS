# WhatsUpGoldPS

[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/WhatsUpGoldPS?label=PSGallery&color=blue)](https://www.powershellgallery.com/packages/WhatsUpGoldPS/)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/WhatsUpGoldPS?color=green)](https://www.powershellgallery.com/packages/WhatsUpGoldPS/)
[![License](https://img.shields.io/github/license/jayyx2/WhatsUpGoldPS)](LICENSE.md)

A PowerShell module for the **WhatsUp Gold REST API**. Manage devices, monitors, groups, reports, device roles, and more — directly from the command line.

> Works with PowerShell 5.1+ and every WhatsUp Gold license, including Free Edition.

---

## Quick Start

```powershell
# Install
Install-Module -Name WhatsUpGoldPS

# Connect
Connect-WUGServer -Hostname wug.example.com -Credential (Get-Credential)

# Get all devices
Get-WUGDevice

# Pull a CPU report for all devices
Get-WUGDeviceReport -ReportType Cpu

# Set maintenance mode
Set-WUGDeviceMaintenance -DeviceId 42 -Duration 60 -Reason "Patching"

# Disconnect
Disconnect-WUGServer
```

---

## Installing

The easiest way to get WhatsUpGoldPS is from the [PowerShell Gallery](https://www.powershellgallery.com/packages/WhatsUpGoldPS/):

```powershell
# Inspect before installing (recommended)
Save-Module -Name WhatsUpGoldPS -Path <path>

# Install
Install-Module -Name WhatsUpGoldPS

# Update
Update-Module -Name WhatsUpGoldPS

# Uninstall
Uninstall-Module -Name WhatsUpGoldPS
```

---

## Function Reference

Every exported function supports `Get-Help` with full documentation:

```powershell
Get-Help Connect-WUGServer -Full
```

### Connection

| Function | Description |
|---|---|
| `Connect-WUGServer` | Authenticate and establish a session to the WUG REST API |
| `Disconnect-WUGServer` | Close the current API session |

### Devices

| Function | Description |
|---|---|
| `Get-WUGDevice` | Retrieve devices (by ID, group, or all) |
| `Add-WUGDevice` | Add a new device via discovery scan |
| `Remove-WUGDevice` | Remove one or more devices by ID |
| `Remove-WUGDevices` | Bulk-remove devices |
| `Get-WUGDeviceStatus` | Get current device status |
| `Get-WUGDeviceScan` | Trigger a device scan and return results |
| `Invoke-WUGDeviceRefresh` | Trigger a configuration refresh (device or group) |
| `Invoke-WUGDevicePollNow` | Trigger an immediate poll (device, batch, or group) |

### Device Properties & Attributes

| Function | Description |
|---|---|
| `Get-WUGDeviceProperties` | Get device properties (name, type, wireless, etc.) |
| `Set-WUGDeviceProperties` | Set device properties |
| `Get-WUGDeviceAttribute` | Get custom device attributes |
| `Set-WUGDeviceAttribute` | Set custom device attributes (single or batch) |
| `Remove-WUGDeviceAttribute` | Remove one or all custom attributes from a device |

### Device Interfaces

| Function | Description |
|---|---|
| `Get-WUGDeviceInterface` | Get device network interfaces |
| `Set-WUGDeviceInterface` | Update device network interfaces (single or batch) |
| `Add-WUGDeviceInterface` | Add a network interface to a device |
| `Remove-WUGDeviceInterface` | Remove one or all interfaces from a device |

### Device Credentials

| Function | Description |
|---|---|
| `Get-WUGDeviceCredential` | Get device credential assignments |
| `Set-WUGDeviceCredential` | Update device credential assignments |

### Polling Configuration

| Function | Description |
|---|---|
| `Get-WUGDevicePollingConfig` | Get device polling configuration |
| `Set-WUGDevicePollingConfig` | Update device polling configuration (single or batch) |

### Device Templates

| Function | Description |
|---|---|
| `Get-WUGDeviceTemplate` | Read device templates |
| `Set-WUGDeviceTemplate` | Apply a device template |
| `Add-WUGDeviceTemplate` | Create a device from a template |
| `Add-WUGDeviceTemplates` | Bulk-create devices from templates |

### Device Roles

| Function | Description |
|---|---|
| `Get-WUGDeviceRole` | Get device roles, brand, OS, assignments, templates, and device-level role assignments |
| `Set-WUGDeviceRole` | Assign, export, import, delete, enable, disable, restore device roles; assign roles to devices and groups |

### Credentials

| Function | Description |
|---|---|
| `Get-WUGCredential` | Retrieve credential definitions, templates, helpers, and assignments |
| `Add-WUGCredential` | Create a new credential |
| `Set-WUGCredential` | Update a credential, unassign all device assignments, or apply credential templates |

### Device Groups

| Function | Description |
|---|---|
| `Get-WUGDeviceGroup` | Retrieve device groups (by ID, search, children, status, devices, credentials, templates, role) |
| `Set-WUGDeviceGroup` | Update device group properties |
| `Add-WUGDeviceGroup` | Create a child device group |
| `Remove-WUGDeviceGroup` | Delete a device group |
| `Get-WUGDeviceGroupMembership` | Get device group membership for a device |
| `Set-WUGDeviceGroupMembership` | Assign or batch-update group membership from the device side |
| `Add-WUGDeviceGroupMember` | Add devices to a device group |
| `Remove-WUGDeviceGroupMember` | Remove one or all devices from a device group |

### Monitors

| Function | Description |
|---|---|
| `Get-WUGActiveMonitor` | Get active monitor definitions and assignments |
| `Add-WUGActiveMonitor` | Create a new active monitor |
| `Add-WUGActiveMonitorToDevice` | Assign an active monitor to a device |
| `Set-WUGActiveMonitor` | Update active monitor properties (library, device, or batch device monitors) |
| `Remove-WUGActiveMonitor` | Remove an active monitor (by search, by ID, or remove all assignments) |
| `Remove-WUGDeviceMonitor` | Remove a monitor assignment (or all) from a device |
| `Get-WUGMonitorTemplate` | List monitor templates, supported types, or export templates |
| `Set-WUGMonitorTemplate` | Apply/import monitor templates, batch library ops, or remove all assignments |

### Maintenance

| Function | Description |
|---|---|
| `Set-WUGDeviceMaintenance` | Enable or disable maintenance mode |
| `Get-WUGDeviceMaintenanceSchedule` | Get maintenance schedules for devices |
| `Set-WUGDeviceMaintenanceSchedule` | Set maintenance schedules for devices |

### Device Reports

All device report functions accept date range, sort, group, threshold, and paging parameters.

| Function | Description |
|---|---|
| `Get-WUGDeviceReport` | Unified report function (`-ReportType` parameter) |
| `Get-WUGDeviceReportCPU` | CPU utilization report |
| `Get-WUGDeviceReportDisk` | Disk utilization report |
| `Get-WUGDeviceReportDiskSpaceFree` | Disk free space report |
| `Get-WUGDeviceReportInterface` | Interface utilization report |
| `Get-WUGDeviceReportInterfaceDiscards` | Interface discards report |
| `Get-WUGDeviceReportInterfaceErrors` | Interface errors report |
| `Get-WUGDeviceReportInterfaceTraffic` | Interface traffic report |
| `Get-WUGDeviceReportMemory` | Memory utilization report |
| `Get-WUGDeviceReportPingAvailability` | Ping availability report |
| `Get-WUGDeviceReportPingResponseTime` | Ping response time report |
| `Get-WUGDeviceReportStateChange` | State change timeline report |

### Device Group Reports

Same parameters as device reports, scoped to a device group.

| Function | Description |
|---|---|
| `Get-WUGDeviceGroupReport` | Unified group report function (`-ReportType` parameter) |
| `Get-WUGDeviceGroupReportCpu` | Group CPU utilization report |
| `Get-WUGDeviceGroupReportDisk` | Group disk utilization report |
| `Get-WUGDeviceGroupReportDiskSpaceFree` | Group disk free space report |
| `Get-WUGDeviceGroupReportInterface` | Group interface utilization report |
| `Get-WUGDeviceGroupReportInterfaceDiscards` | Group interface discards report |
| `Get-WUGDeviceGroupReportInterfaceErrors` | Group interface errors report |
| `Get-WUGDeviceGroupReportInterfaceTraffic` | Group interface traffic report |
| `Get-WUGDeviceGroupReportMaintenance` | Group maintenance mode report |
| `Get-WUGDeviceGroupReportMemory` | Group memory utilization report |
| `Get-WUGDeviceGroupReportPingAvailability` | Group ping availability report |
| `Get-WUGDeviceGroupReportPingResponseTime` | Group ping response time report |
| `Get-WUGDeviceGroupReportStateChange` | Group state change timeline report |

### System

| Function | Description |
|---|---|
| `Get-WUGProduct` | Get WUG product info: API version, installation ID, timezone, version, and whoAmI |

---

## Report Parameters

All report functions share a common set of parameters:

| Parameter | Description |
|---|---|
| `-Range` | Date range filter: `today`, `lastPolled`, `yesterday`, `lastWeek`, `lastMonth`, `lastQuarter`, `weekToDate`, `monthToDate`, `quarterToDate`, `lastNHours`, `lastNDays`, `lastNWeeks`, `lastNMonths`, `custom` |
| `-RangeN` | Multiplier for `lastN*` ranges (e.g., `-Range lastNHours -RangeN 4` = last 4 hours) |
| `-RangeStartUtc` / `-RangeEndUtc` | Custom date range boundaries |
| `-SortBy` / `-SortByDir` | Sort by column name, ascending or descending |
| `-GroupBy` / `-GroupByDir` | Group results by column name |
| `-ApplyThreshold` / `-OverThreshold` / `-ThresholdValue` | Threshold filtering |
| `-BusinessHoursId` | Filter by business hours schedule |
| `-PageId` / `-Limit` | Pagination controls |

---

## Examples

* [Clone a device](https://github.com/jayyx2/WhatsUpGoldPS/blob/main/examples/Clone_device.ps1) — Use another device as a template to create a new device
* [Create a new device](https://github.com/jayyx2/WhatsUpGoldPS/blob/main/examples/New_device.ps1) — Add a device with discovery options

```powershell
# Get CPU report for a specific device over the last 24 hours
Get-WUGDeviceReportCPU -DeviceId 42 -Range lastNHours -RangeN 24

# Enable maintenance on multiple devices
Set-WUGDeviceMaintenance -DeviceId 1,2,3 -Duration 120 -Reason "Scheduled update"

# Export all device attributes
Get-WUGDeviceAttribute | Export-Csv -Path attributes.csv

# Get group report for all devices
Get-WUGDeviceGroupReport -ReportType Memory -GroupId -2
```

---

## Helper Scripts

The `helpers/` directory contains ready-to-use automation scripts:

| Directory | Description |
|---|---|
| `helpers/vmware/` | VMware vSphere discovery — immediate add w/ attributes, discover-then-add |
| `helpers/proxmox/` | Proxmox VE discovery — immediate add w/ attributes, discover-then-add, rename/update |
| `helpers/hyperv/` | Hyper-V discovery — immediate add w/ attributes, discover-then-add (CIM/WinRM) |
| `helpers/nutanix/` | Nutanix Prism discovery — immediate add w/ attributes, discover-then-add (REST v2 API) |
| `helpers/azure/` | Azure resource discovery — immediate add w/ attributes, discover-then-add (Az PowerShell modules) |
| `helpers/aws/` | AWS resource discovery — EC2, RDS, ELB immediate add w/ attributes, discover-then-add (AWS.Tools modules) |
| `helpers/gcp/` | GCP resource discovery — Compute Engine, Cloud SQL, LB immediate add w/ attributes, discover-then-add (GoogleCloud module + gcloud CLI) |
| `helpers/oci/` | Oracle Cloud discovery — Compute, DB Systems, Autonomous DB, LB immediate add w/ attributes, discover-then-add (OCI.PSModules + OCI CLI) |
| `helpers/reports/` | Bootstrap-based HTML report templates |

---

## Support

This module comes with no warranty or support and is offered as-is.

## Contributing

Interested in contributing? Read how you can [contribute](contributing.md) to WhatsUpGoldPS.

This project maintains a [code of conduct](code-of-conduct.md) that establishes how the project is governed and how everyone involved is expected to behave. You can report unacceptable behavior to [jason@wug.ninja](mailto:jason@wug.ninja).

## Release History

A detailed release history is contained in the [Change Log](CHANGELOG.md).

## License

WhatsUpGoldPS is provided under the [Apache License 2.0](LICENSE.md).
