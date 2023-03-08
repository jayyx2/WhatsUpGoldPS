<#
.SYNOPSIS
Creates a new device in WhatsUp Gold using the specified parameters.

.PARAMETER displayName
The display name of the device.

.PARAMETER DeviceAddress
The IP address or hostname of the device.

.PARAMETER deviceType
The type of the device.

.PARAMETER PollInterval
The polling interval for the device, in seconds.

.PARAMETER PrimaryRole
The primary role of the device.

.PARAMETER SubRoles
An array of sub-roles for the device.

.PARAMETER snmpOid
The SNMP OID for the device.

.PARAMETER SNMPPort
The SNMP port for the device.

.PARAMETER OS
The operating system of the device.

.PARAMETER Brand
The brand of the device.

.PARAMETER ActionPolicy
The action policy for the device.

.PARAMETER Note
A note to add to the device.

.PARAMETER AutoRefresh
Whether to enable auto-refresh for the device.

.PARAMETER Credentials
An array of credentials for the device.

.PARAMETER Interfaces
An array of interfaces for the device.

.PARAMETER Attributes
An array of attributes for the device.

.PARAMETER CustomLinks
An array of custom links for the device.

.PARAMETER ActiveMonitors
An array of active monitors for the device.

.PARAMETER PerformanceMonitors
An array of performance monitors for the device.

.PARAMETER PassiveMonitors
An array of passive monitors for the device.

.PARAMETER Dependencies
An array of dependencies for the device.

.PARAMETER NCMTasks
An array of NCM tasks for the device.

.PARAMETER ApplicationProfiles
An array of application profiles for the device.

.PARAMETER Layer2Data
The Layer 2 data for the device.

.PARAMETER Groups
An array of groups to which the device should belong.

.EXAMPLE
$params = @{
    DeviceAddress = "192.168.1.1"
    displayName = "My Device"
}
New-WUGDevice @params

This example creates a new device with the specified IP address and display name.

.NOTES
Author: Jason Alberino
Date: 2023-03-07
#>

function New-WUGDevice {
    param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $displayName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [ValidatePattern('\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', ErrorMessage = 'You must input a valid IP address.')] [string] $DeviceAddress,
        [Parameter()] <#[ValidateSet("Workstation", "Server")]#> [string] $deviceType,
        [Parameter()] [ValidateRange(10,3600, ErrorMessage = 'You must specify a poll interval greater than 10 and less than 3600.')] [int] $PollInterval = 60,
        [Parameter()] <#[ValidateSet("Device", "Router", "Switch", "Firewall")]#> [string] $PrimaryRole = "Device",
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $SubRoles,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $snmpOid,
        [Parameter()] [ValidateRange(1,65535, ErrorMessage = 'You must input a valid TCPIP port.')] [int] $SNMPPort,
        [Parameter()] [ValidateNotNullOrEmpty()] <#[ValidateSet("Windows", "Linux", "Unix")]#> [string] $OS,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Brand,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $ActionPolicy,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Note,
        [Parameter()] [ValidateNotNullOrEmpty()] [bool] $AutoRefresh,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $Credentials,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $Interfaces,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $Attributes,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $CustomLinks,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $ActiveMonitors,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $PerformanceMonitors,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $PassiveMonitors,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $Dependencies,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $NCMTasks,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $ApplicationProfiles,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Layer2Data,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $Groups
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking

    $options = @("all")
    if ($ApplyL2) { $options += "l2" }
    if ($Update) { $options += "update" }
    if ($UpdateInterfaceState) { $options += "update-interface-state" }
    if ($UpdateInterfaceNames) { $options += "update-interface-names" }
    if ($UpdateActiveMonitors) { $options += "update-active-monitors" }

    $template = @{
        templateId = "WhatsUpGoldPS"
        displayName = "${displayName}"
        deviceType = "Workstation"
        snmpOid = ""
        snmpPort = ""
        pollInterval = "${PollInterval}"
        primaryRole = "Device"
        subRoles = @("Resource Attributes", "Resource Monitors")
        os = ""
        brand = ""
        actionPolicy = ""
        note = "${note}"
        autoRefresh = "True"
        credentials = @()
        interfaces = @(
            @{
              defaultInterface = "true"
              pollUsingNetworkName = "false"
              networkAddress = "0.0.0.0"
              networkName = "0.0.0.0"
            }
        )
        attributes = @()
        customLinks = @()
        activeMonitors = @()
        performanceMonitors = @()
        passiveMonitors = @()
        dependencies = @()
        ncmTasks = @()
        applicationProfiles = @()
        layer2Data = ""
        groups = @(@{
            name='My Network'
        })
    }

    $jsonBody = $template | ConvertTo-Json -Compress

    $body = "{
        `"options`":[`"all`"],
        `"templates`":[${jsonBody}]
    }"

    try {
        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/template" -method "PATCH" -body $body
        return $result.data
    }
    catch {
        Write-Error $_
    }
}