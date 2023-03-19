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
    Hostname = "my-device.example.com"
    deviceType = "Server"
    PollInterval = 120
    PrimaryRole = "Switch"
    SubRoles = @("Role1", "Role2")
    snmpOid = "1.3.6.1.4.1.9.1.2417"
    SNMPPort = 161
    OS = "Linux"
    Brand = "Cisco"
    ActionPolicy = "MyActionPolicy"
    Note = "This is a test device"
    AutoRefresh = $true
    Credentials = @("Credential1", "Credential2")
    Interfaces = @("Interface1", "Interface2")
    Attributes = @("Attribute1", "Attribute2")
    CustomLinks = @("Link1", "Link2")
    ActiveMonitors = @("Ping", "SNMP")
    PerformanceMonitors = @("PerfMonitor1", "PerfMonitor2")
    PassiveMonitors = @("PassiveMonitor1", "PassiveMonitor2")
    Groups = @("Group1", "Group2")
}
Add-WUGDevice @params

This example creates a new device with all the specified parameters, including the IP address, display name, active monitors, and more.

.NOTES
Author: Jason Alberino
Date: 2023-03-07
#>

function Add-WUGDevice {
    param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $displayName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [ValidatePattern('\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')] [string] $DeviceAddress,
        [Parameter()] $Template,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Hostname,       
        [Parameter()] <#[ValidateSet("Workstation", "Server")]#> [string] $deviceType,
        [Parameter()] [ValidateRange(10,3600)] [int] $PollInterval = 60,
        [Parameter()] <#[ValidateSet("Device", "Router", "Switch", "Firewall")]#> [string] $PrimaryRole = "Device",
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $SubRoles,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $snmpOid,
        [Parameter()] [ValidateRange(1,65535)] [int] $SNMPPort,
        [Parameter()] [ValidateNotNullOrEmpty()] <#[ValidateSet("Windows", "Linux", "Unix")]#> [string] $OS,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Brand,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $ActionPolicy,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Note,
        [Parameter()] [ValidateNotNullOrEmpty()] [bool] $AutoRefresh = $true,
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
    Write-Debug "Function: New-WUGDevice"
    Write-Debug "Displayname:       ${displayName}"
    Write-Debug "Device Address:    ${DeviceAddress}"
    Write-Debug "Device Type:       ${deviceType}"
    Write-Debug "PollInterval:      ${PollInterval}"
    Write-Debug "PrimaryRole:       ${PrimaryRole}"
    Write-Debug "SubRoles:          ${SubRoles}"
    Write-Debug "snmpOid:           ${snmpOid}"
    Write-Debug "SNMPPort:          ${SNMPPort}"   
    Write-Debug "OS:                ${OS}"
    Write-Debug "Brand:             ${Brand}"
    Write-Debug "ActionPolicy:      ${ActionPolicy}"
    Write-Debug "Note:              ${Note}"
    Write-Debug "AutoRefresh:       ${AutoRefresh}"
    Write-Debug "Credentials:       ${Credentials}"
    Write-Debug "Interfaces:        ${Interfaces}"
    Write-Debug "Attributes:        ${Attributes}"
    Write-Debug "CustomLinks:       ${CustomLinks}"
    Write-Debug "ActiveMonitors:    ${ActiveMonitors}"
    Write-Debug "PerforMonitors:    ${PerformanceMonitors}"
    Write-Debug "PassiveMonitors:   ${PassiveMonitors}"
    Write-Debug "Dependencies:      ${Dependencies}"
    Write-Debug "NCMTasks:          ${NCMTasks}"
    Write-Debug "AppProfiles:       ${ApplicationProfiles}"
    Write-Debug "Layer2Data:        ${Layer2Data}"
    Write-Debug "Layer2Data:        ${Groups}"

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) {Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer;}
    if ((Get-Date) -ge $global:expiry) {Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer;} else {Request-WUGAuthToken}
    if (-not $global:WhatsUpServerBaseURI) {Write-Error "Base URI not found. running Connect-WUGServer";Connect-WUGServer;}
    #End global variables error checking

    #Begin Input validation
    if ($SubRoles) {if ($SubRoles -isnot [string[]]) {throw "SubRoles parameter must be an array of strings."}}
    if ($ActiveMonitors) {if ($ActiveMonitors -is [array]) {foreach ($item in $ActiveMonitors) {if ($item -isnot [string]) {throw "ActiveMonitors parameter must be a one-dimensional array of strings."}}} else {throw "ActiveMonitors parameter must be a one-dimensional array of strings."}}
    if ($PerformanceMonitors) {if ($PerformanceMonitors -is [array]) {foreach ($item in $PerformanceMonitors) {if ($item -isnot [string]) {throw "PerformanceMonitors parameter must be a one-dimensional array of strings."}}} else {throw "PerformanceMonitors parameter must be a one-dimensional array of strings."}}
    if ($PassiveMonitors) {if ($PassiveMonitors -is [array]) {foreach ($item in $PassiveMonitors) {if ($item -isnot [string]) {throw "PassiveMonitors parameter must be a one-dimensional array of strings."}}} else {throw "PassiveMonitors parameter must be a one-dimensional array of strings."}}   
    #End input validation

    #Begin data formatting
    ### Active Monitors
    $ActiveMonitorObjects = @()
    if ($ActiveMonitors) {
        foreach ($ActiveMonitor in $ActiveMonitors) {
            $ActiveMonitorObject = New-Object -TypeName PSObject -Property @{
                classId = ''
                Name    = $ActiveMonitor
            }
            $ActiveMonitorObjects += $ActiveMonitorObject
        }
    }
    else {
        if(!$Template){
            $ActiveMonitorObjects = @()
            $ActiveMonitorObject = New-Object -TypeName PSObject -Property @{
                classId = ''
                Name    = 'Ping'
            }
            $ActiveMonitorObjects += $ActiveMonitorObject   
        }
    }

    ### Performance Monitors
    $PerformanceMonitorObjects = @()
    if ($PerformanceMonitors) {
        foreach ($PerformanceMonitor in $PerformanceMonitors) {
            $PerformanceMonitorObject = New-Object -TypeName PSObject -Property @{
                classId = ''
                Name    = $PerformanceMonitor
            }
            $PerformanceMonitorObjects += $PerformanceMonitorObject
        }
    }
    ### Passive Monitors
    $PassiveMonitorObjects = @()
    if ($PassiveMonitors) {
        foreach ($PassiveMonitor in $PassiveMonitors) {
            $PassiveMonitorObject = New-Object -TypeName PSObject -Property @{
                classId = ''
                Name    = $PassiveMonitor
                #actions = ''
            }
            $PassiveMonitorObjects += $PassiveMonitorObject
        }
    }
    #End data formatting

    $options = @("all")
    if ($ApplyL2) { $options += "l2" }
    if ($Update) { $options += "update" }
    if ($UpdateInterfaceState) { $options += "update-interface-state" }
    if ($UpdateInterfaceNames) { $options += "update-interface-names" }
    if ($UpdateActiveMonitors) { $options += "update-active-monitors" }
    if (!$hostname) { $hostname = $DeviceAddress }

    #Handle null objects

    #Begin template handling
    if (!$Template) {
        $Template = @{
            templateId          = "WhatsUpGoldPS"
            displayName         = "${displayName}"
            deviceType          = "${deviceType}"
            snmpOid             = ""
            snmpPort            = ""
            pollInterval        = "${PollInterval}"
            primaryRole         = "${PrimaryRole}"
            subRoles            = @("Resource Attributes", "Resource Monitors")
            os                  = ""
            brand               = ""
            actionPolicy        = ""
            note                = "${note}"
            autoRefresh         = "$true"
            credentials         = @()
            interfaces          = @(
                @{
                    defaultInterface     = "true"
                    pollUsingNetworkName = "false"
                    networkAddress       = "${DeviceAddress}"
                    networkName          = "${Hostname}"
                }
            )
            attributes          = @()
            customLinks         = @()
            activeMonitors      = @(${ActiveMonitorObjects})
            performanceMonitors = @(${PerformanceMonitorObjects})
            passiveMonitors     = @(${PassiveMonitorObjects})
            dependencies        = @()
            ncmTasks            = @()
            applicationProfiles = @()
            layer2Data          = ""
            groups              = @(
                @{
                    name = 'My Network'
                }
            )
        }
    }
    else {
        if ($DeviceAddress -and $Hostname) {
            $Template.interfaces = @(
                @{
                    defaultInterface     = "true"
                    pollUsingNetworkName = "false"
                    networkAddress       = "${DeviceAddress}"
                    networkName          = "${Hostname}"
                }
            )
        }
        $TempId = ""
        $TempId = $Template.templateId
        $Template.templateId = "WhatsUpGoldPS $($TempId)"
        if ($displayName) { $Template.displayName = "${displayName}" }
        if ($deviceType) { $Template.deviceType = "${deviceType}" }
        if ($PollInterval) { $Template.pollInterval = "${PollInterval}" }
        if ($PrimaryRole) {
            if ($Template.PSObject.Properties['primaryRole']) {
                $Template.primaryRole = "${PrimaryRole}"
            } else {
                $Template | Add-Member -MemberType NoteProperty -Name 'primaryRole' -Value "${PrimaryRole}"
            }
        }
        if ($note) { $Template.note = "${note}" } else { $Template.note = "Added by WhatsUpGoldPS PowerShell module on $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz UTC"))"}
        if ($ActiveMonitorObjects) {
            if ($Template.activeMonitors) {
                $Template.activeMonitors += @(${ActiveMonitorObjects})
            } else {
                $Template.activeMonitors = @(${ActiveMonitorObjects})
            }
        }
        if ($PerformanceMonitorObjects) {
            if ($Template.performanceMonitors) {
                $Template.performanceMonitors += @(${PerformanceMonitorObjects})
            } else {
                $Template.performanceMonitors = @(${PerformanceMonitorObjects})
            }
        }
        if ($PassiveMonitorObjects) {
            if ($Template.passiveMonitors) {
                $Template.passiveMonitors += @(${PassiveMonitorObjects})
            } else {
                $Template.passiveMonitors = @(${PassiveMonitorObjects})
            }
        }
    }    
    #End template handling

    $jsonBody = $Template | ConvertTo-Json -Depth 5 -Compress

    $jsonBody

    $body = "{
        `"options`":[`"all`"],
        `"templates`":[${jsonBody}]
    }"

    try {
        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/template" -method "PATCH" -body $body
        if($result.data.errors){
            return $result.data.errors
        } else {
        return $result.data
        }
    }
    catch {
        Write-Error $_.
    }
}