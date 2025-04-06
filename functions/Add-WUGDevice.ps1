<#
.SYNOPSIS
Adds a device to WhatsUp Gold using the WhatsUp Gold REST API.

.DESCRIPTION
The Add-WUGDevice function adds a device to WhatsUp Gold using the WhatsUp Gold REST API.
It allows configuring various aspects of the device such as display name, IP address, template,
hostname, device type, polling interval, credentials, monitors, and other attributes.

.PARAMETER displayName
The display name of the device.

.PARAMETER DeviceAddress
The IP address of the device.

.PARAMETER Template
The template to use for configuring the device (optional).

.PARAMETER Hostname
The hostname of the device (optional).

.PARAMETER deviceType
The type of the device (optional).

.PARAMETER PollInterval
The polling interval for monitoring the device (optional).

.PARAMETER PrimaryRole
The primary role of the device (optional).

.PARAMETER SubRoles
The sub-roles of the device (optional).

.PARAMETER snmpOid
The SNMP OID of the device (optional).

.PARAMETER SNMPPort
The SNMP port of the device (optional).

.PARAMETER OS
The operating system of the device (optional).

.PARAMETER Brand
The brand of the device (optional).

.PARAMETER ActionPolicy
The action policy for the device (optional).

.PARAMETER Note
Additional notes for the device (optional).

.PARAMETER AutoRefresh
Whether to enable auto-refresh for the device (optional).

.PARAMETER CredentialWindows
Windows credential for the device (optional).

.PARAMETER CredentialSnmpV3
SNMPv3 credential for the device (optional).

.PARAMETER CredentialSnmpV2
SNMPv2 credential for the device (optional).

.PARAMETER CredentialSnmpV1
SNMPv1 credential for the device (optional).

.PARAMETER CredentialAdo
ADO credential for the device (optional).

.PARAMETER CredentialTelnet
Telnet credential for the device (optional).

.PARAMETER CredentialSsh
SSH credential for the device (optional).

.PARAMETER CredentialVMware
VMware credential for the device (optional).

.PARAMETER CredentialAWS
AWS credential for the device (optional).

.PARAMETER CredentialAzure
Azure credential for the device (optional).

.PARAMETER CredentialMeraki
Meraki credential for the device (optional).

.PARAMETER CredentialRestApi
REST API credential for the device (optional).

.PARAMETER CredentialRedfish
Redfish credential for the device (optional).

.PARAMETER CredentialJmx
JMX credential for the device (optional).

.PARAMETER CredentialSmis
SMIS credential for the device (optional).

.PARAMETER Interfaces
Interfaces configuration for the device (optional).

.PARAMETER Attributes
Attributes configuration for the device (optional).

.PARAMETER CustomLinks
Custom links configuration for the device (optional).

.PARAMETER ActiveMonitors
Active monitors configuration for the device (optional).

.PARAMETER PerformanceMonitors
Performance monitors configuration for the device (optional).

.PARAMETER PassiveMonitors
Passive monitors configuration for the device (optional).

.PARAMETER Dependencies
Dependencies configuration for the device (optional).

.PARAMETER NCMTasks
NCM tasks configuration for the device (optional).

.PARAMETER ApplicationProfiles
Application profiles configuration for the device (optional).

.PARAMETER Layer2Data
Layer 2 data configuration for the device (optional).

.PARAMETER GroupName
Name of the static group to add the device to. "My Network" if not set.

.NOTES
Author: Jason Alberino
Date: 2023-03-07

.EXAMPLE
# Add a device with basic configuration
Add-WUGDevice -displayName "Server01" -DeviceAddress "192.168.1.100" -Hostname "server01.example.com" -PollInterval 300 -CredentialWindows "Existing-WUG-Cred-Name"

Description
-----------
This command adds a device named "Server01" with the IP address "192.168.1.100" and hostname "server01.example.com".
It specifies to use the Windows Credential named "Existing-WUG-Cred-Name" and sets the polling interval to 300 seconds.
The device is added with default settings for other parameters not specified in the command.
#All devices go to the 'My Network" top-level group
#>

function Add-WUGDevice {
    param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $displayName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [ValidatePattern('\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')] [string] $DeviceAddress,
        [Parameter()] $Template,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Hostname,       
        [Parameter()] <#[ValidateSet("Workstation", "Server")]#> [string] $deviceType,
        [Parameter()] [ValidateRange(10, 3600)] [int] $PollInterval = 60,
        [Parameter()] <#[ValidateSet("Device", "Router", "Switch", "Firewall")]#> [string] $PrimaryRole = "Device",
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $SubRoles,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $snmpOid,
        [Parameter()] [ValidateRange(1, 65535)] [int] $SNMPPort,
        [Parameter()] [ValidateNotNullOrEmpty()] <#[ValidateSet("Windows", "Linux", "Unix")]#> [string] $OS,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Brand,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $ActionPolicy,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Note,
        [Parameter()] [ValidateNotNullOrEmpty()] [bool] $AutoRefresh = $true,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialWindows,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialSnmpV3, 
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialSnmpV2,  
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialSnmpV1,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialAdo,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialTelnet,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialSsh,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialVMware,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialAWS,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialAzure,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialMeraki,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialRestApi,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialRedfish,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialJmx, 
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $CredentialSmis,                               
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
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $GroupName
    )

    Write-Debug "Function: Add-WUGDevice"
    Write-Debug "Displayname:       ${displayName}"
    Write-Debug "Device Address:    ${DeviceAddress}"
    Write-Debug "Hostname:          ${Hostname}"
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
    Write-Debug "WindowsCredential:${WindowsCredential}"
    Write-Debug "SnmpV3Credential:  ${SnmpV3Credential}"
    Write-Debug "SnmpV2Credential:  ${SnmpV2Credential}"
    Write-Debug "SnmpV1Credential:  ${SnmpV1Credential}"
    Write-Debug "AdoCredential:     ${AdoCredential}"
    Write-Debug "TelnetCredential:  ${TelnetCredential}"
    Write-Debug "SshCredential:     ${SshCredential}"
    Write-Debug "VMwareCredential:  ${VMwareCredential}"
    Write-Debug "JmxCredential:     ${JmxCredential}"
    Write-Debug "SmisCredential:    ${SmisCredential}"
    Write-Debug "AWSCredential:     ${AWSCredential}"
    Write-Debug "AzureCredential:   ${AzureCredential}"
    Write-Debug "MerakiCredential:  ${MerakiCredential}"
    Write-Debug "RestApiCredential: ${RestApiCredential}"
    Write-Debug "RedfishCredential: ${RedfishCredential}"
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
    Write-Debug "GroupName:         ${GroupName}"

    #Begin Input validation
    if ($SubRoles) { if ($SubRoles -is [array]) { foreach ($item in $SubRoles) { if ($item -isnot [string]) { throw "SubRoles parameter must be a one-dimensional array of strings." } } } else { throw "SubRoles parameter must be a one-dimensional array of strings." } }
    if ($ActiveMonitors) { if ($ActiveMonitors -is [array]) { foreach ($item in $ActiveMonitors) { if ($item -isnot [string]) { throw "ActiveMonitors parameter must be a one-dimensional array of strings." } } } else { throw "ActiveMonitors parameter must be a one-dimensional array of strings." } }
    if ($PerformanceMonitors) { if ($PerformanceMonitors -is [array]) { foreach ($item in $PerformanceMonitors) { if ($item -isnot [string]) { throw "PerformanceMonitors parameter must be a one-dimensional array of strings." } } } else { throw "PerformanceMonitors parameter must be a one-dimensional array of strings." } }
    if ($PassiveMonitors) { if ($PassiveMonitors -is [array]) { foreach ($item in $PassiveMonitors) { if ($item -isnot [string]) { throw "PassiveMonitors parameter must be a one-dimensional array of strings." } } } else { throw "PassiveMonitors parameter must be a one-dimensional array of strings." } }
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
        if (!$Template) {
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

    ### Credentials
    $CredentialObjects = @()
    if ($CredentialSnmpV1){
            $CredentialObject = New-Object -TypeName PSObject -Property @{
            credentialType = 'SNMP v1'
            credential     = $CredentialSnmpV1
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialSnmpV2){
            $CredentialObject = New-Object -TypeName PSObject -Property @{
            credentialType = 'SNMP v2'
            credential     = $CredentialSnmpV2
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialSnmpV3){
            $CredentialObject = New-Object -TypeName PSObject -Property @{
            credentialType = 'SNMP v3'
            credential     = $CredentialSnmpV3
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialWindows){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'Windows'
        credential     = $CredentialWindows
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialAdo){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'ADO'
        credential     = $CredentialAdo
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialAws){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'AWS'
        credential     = $CredentialAws
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialRedfish){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'Redfish'
        credential     = $CredentialRedfish
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialRestApi){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'REST API'
        credential     = $CredentialRestApi
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialSsh){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'SSH'
        credential     = $CredentialSsh
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialTelnet){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'Telnet'
        credential     = $CredentialTelnet
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialVmware){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'VMware'
        credential     = $CredentialVmware
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialJmx){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'jmx'
        credential     = $CredentialJmx
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialSmis){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'smis'
        credential     = $CredentialSmis
        }
        $CredentialObjects += $CredentialObject
    }

    #Groups
    $Groups = @()
    if ($GroupName) {
        $Groups += @{ name = $GroupName }
    }
    <# I can't seem to get GroupId to work from Swagger
    if ($GroupId) {
        $Groups += @{ id = $GroupId }
    }
    #>

    #End data formatting

    $options = @("all")
    if ($ApplyL2) { $options += "l2" }
    if ($Update) { $options += "update" }
    if ($UpdateInterfaceState) { $options += "update-interface-state" }
    if ($UpdateInterfaceNames) { $options += "update-interface-names" }
    if ($UpdateActiveMonitors) { $options += "update-active-monitors" }
    if (!$hostname) { $hostname = $DeviceAddress }
    if (!$Brand) { $Brand = "Not Set" }
    if (!$OS) { $OS = "Not Set" }
    if (!$SNMPPort) { $SNMPPort = 161 }
    if(!$SubRoles){ $SubRoles = @("Resource Attributes", "Resource Monitors")}
    if(!$Groups){ $Groups= @(@{name = 'My Network'})}
    
    #Handle null objects

    #Begin template handling
    if (!$Template) {
        $Template = @{
            templateId          = "WhatsUpGoldPS"
            displayName         = "${displayName}"
            deviceType          = "${deviceType}"
            snmpOid             = "${snmpOid}"
            snmpPort            = "${SNMPPort}"
            pollInterval        = "${PollInterval}"
            primaryRole         = "${PrimaryRole}"
            subRoles            = @(${SubRoles})
            os                  = "${OS}"
            brand               = "${Brand}"
            actionPolicy        = "${ActionPolicy}"
            note                = "${note}"
            autoRefresh         = "$true"
            credentials         = @(${CredentialObjects})
            interfaces          = @(
                @{
                    defaultInterface     = "true"
                    pollUsingNetworkName = "false"
                    networkAddress       = "${DeviceAddress}"
                    networkName          = "${Hostname}"
                }
            )
            attributes          = @(${Attributes})
            customLinks         = @()
            activeMonitors      = @(${ActiveMonitorObjects})
            performanceMonitors = @(${PerformanceMonitorObjects})
            passiveMonitors     = @(${PassiveMonitorObjects})
            dependencies        = @()
            ncmTasks            = @()
            applicationProfiles = @()
            layer2Data          = ""
            groups              = @(${Groups})
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
        $TempId = $Template.templateId
        $Template.templateId = "WhatsUpGoldPS(${TempId})"
        if ($displayName) { $Template.displayName = "${displayName}" }
        if ($deviceType) { $Template.deviceType = "${deviceType}" }
        if ($PollInterval) { $Template.pollInterval = "${PollInterval}" }
        if ($PrimaryRole) {
            if ($Template.PSObject.Properties['primaryRole']) {
                $Template.primaryRole = "${PrimaryRole}"
            }
            else {
                $Template | Add-Member -MemberType NoteProperty -Name 'primaryRole' -Value "${PrimaryRole}"
            }
        }
        if ($note) { $Template.note = "${note}" } else { $Template.note = "Added by WhatsUpGoldPS PowerShell module on $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz UTC"))" }
        if ($ActiveMonitorObjects) {
            if ($Template.activeMonitors) {
                $Template.activeMonitors += @(${ActiveMonitorObjects})
            }
            else {
                $Template.activeMonitors = @(${ActiveMonitorObjects})
            }
        }
        if ($PerformanceMonitorObjects) {
            if ($Template.performanceMonitors) {
                $Template.performanceMonitors += @(${PerformanceMonitorObjects})
            }
            else {
                $Template.performanceMonitors = @(${PerformanceMonitorObjects})
            }
        }
        if ($PassiveMonitorObjects) {
            if ($Template.passiveMonitors) {
                $Template.passiveMonitors += @(${PassiveMonitorObjects})
            }
            else {
                $Template.passiveMonitors = @(${PassiveMonitorObjects})
            }
        }
    }    
    #End template handling

    $jsonBody = $Template | ConvertTo-Json -Depth 5 -Compress

    $body = "{
        `"options`":[`"all`"],
        `"templates`":[${jsonBody}]
    }"

    try {
        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/template" -method "PATCH" -body $body
        if ($result.data.errors) {
            return $result.data.errors
        }
        else {
            return $result.data
        }
    }
    catch {
        Write-Error $_.
    }
}
# SIG # Begin signature block
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUYykEKKpDJ6K1Vfx9eWEhAmpd
# ahigghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIGGjCCBAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG
# 9w0BAQwFADBWMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk
# MS0wKwYDVQQDEyRTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYw
# HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1Ymxp
# YyBDb2RlIFNpZ25pbmcgQ0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIB
# igKCAYEAmyudU/o1P45gBkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxD
# eEDIArCS2VCoVk4Y/8j6stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk
# 9vT0k2oWJMJjL9G//N523hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7Xw
# iunD7mBxNtecM6ytIdUlh08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ
# 0arWZVeffvMr/iiIROSCzKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZX
# nYvZQgWx/SXiJDRSAolRzZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+t
# AfiWu01TPhCr9VrkxsHC5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvr
# n35XGf2RPaNTO2uSZ6n9otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn
# 3UayWW9bAgMBAAGjggFkMIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaR
# XBeF5jAdBgNVHQ4EFgQUDyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYD
# VR0gBBQwEjAGBgRVHSAAMAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRw
# Oi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RS
# NDYuY3JsMHsGCCsGAQUFBwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAj
# BggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEM
# BQADggIBAAb/guF3YzZue6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXK
# ZDk8+Y1LoNqHrp22AKMGxQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWk
# vfPkKaAQsiqaT9DnMWBHVNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3d
# MapandPfYgoZ8iDL2OR3sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwF
# kvjFV3jS49ZSc4lShKK6BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZa
# PATHvNIzt+z1PHo35D/f7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8b
# kinLrYrKpii+Tk7pwL7TjRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7Ew
# oIJB0kak6pSzEu4I64U6gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TW
# SenLbjBQUGR96cFr6lEUfAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg
# 51Tbnio1lB93079WPFnYaOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoU
# KD85gnJ+t0smrWrb8dee2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGZDCCBMyg
# AwIBAgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJKoZIhvcNAQEMBQAwVDELMAkGA1UE
# BhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGln
# byBQdWJsaWMgQ29kZSBTaWduaW5nIENBIFIzNjAeFw0yMzA0MTkwMDAwMDBaFw0y
# NjA3MTgyMzU5NTlaMFUxCzAJBgNVBAYTAlVTMRQwEgYDVQQIDAtDb25uZWN0aWN1
# dDEXMBUGA1UECgwOSmFzb24gQWxiZXJpbm8xFzAVBgNVBAMMDkphc29uIEFsYmVy
# aW5vMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtiQNNQXoaqTtyDXo
# ylbCknGkvbHdB46M9bXHhYoOmMrtoJUyoph/Z6/ZeeN/Ao6XNcfp+NoDH50uQs2u
# LWVFq9brDqt3dE5YyhTjklvFL3tSfjwtH/x8aQ2yPIRN/CAg5oL/BKMwToKOJT5v
# 6wx1Ux4IkWb8tR/ID07hNd3JNrHr1bJZLthNhfMLLeSm9djqp4BfekV6bRHjNIk4
# qT4XzYp1gmvHufPpm7dXRwm1+Oufdw0Xd8kL/q7z5CIfUJDBprpn41eZb9Ut4qn/
# 1YOlz/Ud5UzzFjTtiBMyI5NdrfNe61N8WMn9kOHZQP4tW0aRX4xFXMUImSXUCp0J
# and4TpNLa/G8UyN0WcYDi0YAvJgPYYHJyZq3jFj+AsF2VCil9d6TKs61/6oklLAf
# jL3J+yxxhKPaSSAYDCLWVuM5+Lj8xm3+dxEFFpz31DkgXYJEQHZG/3Oy5IYXNRzT
# 1pVKs0v7XaKSO/k8zbGK+6hHJF6bpgZVEjjaCZ9ldc7pBW4LAatJkVkmX/rrdzlR
# qO80mKKbDF0iDxRGgXMTbr3GUF7+mHVxLA6bxpsrG4FWv+7j9ysB/Ye/VnhVP04h
# hCEh+Qefak4NuvhjEaocmaGB4+8CN+qJsEjY2rVKOXGM+ABGEzufIHHjHM7TTuOQ
# cpy8D22cGdG8TzdsC9a7iGHfnsECAwEAAaOCAa4wggGqMB8GA1UdIwQYMBaAFA8q
# yyCHKLjsb0iuK1SmKaoXpM0MMB0GA1UdDgQWBBSR7lSM0bm2siNLX8PNkO0P+O4r
# vTAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEF
# BQcDAzBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDAjAlMCMGCCsGAQUFBwIBFhdo
# dHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAEwSQYDVR0fBEIwQDA+oDyg
# OoY4aHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25p
# bmdDQVIzNi5jcmwweQYIKwYBBQUHAQEEbTBrMEQGCCsGAQUFBzAChjhodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNy
# dDAjBggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wIwYDVR0RBBww
# GoEYamFzb24uYWxiZXJpbm9AZ21haWwuY29tMA0GCSqGSIb3DQEBDAUAA4IBgQBE
# 9BBR9K/oaqEFq+B2vVA7hL9vK04FdmmqNZxUYBmf+aMDO8fZcWqaS1G4EBX3iM8w
# LKd4MEyjGH+O541I7zgWQ/c1f9yP72i5mNnp5jF2ePDpvRluKTZp77Hn9lG9f/nU
# c4LPFBV+cASXH8uDlj97dDmiiZJ/mZbYBRdXLi/0T4lkkXGboYe3SFoKD0K1cfAb
# QvKZIeBeRAsaIEJ5WgzQcxmH9VGDXxEDhXnN9VCvKBDcFsefxGiha0ovWOLbuq5K
# R9InZmHbP9X76gKRsbo4bwjuEnvALX3PfInF+A1pHNUCC0RB4lYp5qDt7JpowecL
# poD+OafTlSV4SNA9IFBUHzkmqaWuXjtpW5zVRvdKwrAA5laQw5jbdqjxtNZbgW1+
# lbVjD9rYYz+fwlr1MuvsX64Zar8Gcmbd0irbnxVpKpzVjJ5oLQTUpgRefqvMOUiV
# vtuKq53CiVkiIpv50bQtdV56CPUl5WrnEtzZW3K0FYnFzrW4ZLBKjE5+dovDTn8x
# ggMCMIIC/gIBATBpMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBS
# MzYCEQDohRsr/zNHDY0q8+DiMoexMAkGBSsOAwIaBQCgcDAQBgorBgEEAYI3AgEM
# MQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUqQMaBVLeTJ0Txdsio3qVhF6X
# bdUwDQYJKoZIhvcNAQEBBQAEggIApb1VQJTbgkvUnkSXgLT7cghyQSXa4hhxgHlt
# iusVMSCtAhos65mlWUjlPUwSOltGKJ6xgDEY2CI2FYa6ZMq9uz9RcOtpoeZtOjVu
# /ZkU2CB3K5fJ93oYq3GRei+cO8PBM9GdQo33TBxHELnG3edg7FCbLzFkG/R54bWK
# c50/jOzC6+ldOhlIPmU3zRoIN5AR8+86cBYvtSyi+BY89vYacZloDhJ4kI1BswFS
# Mz/933tboqKZouxw4KaYagRdujOCzAt8lfT2jmUEk9YTNPAXwtipxSlNbGIY2ALx
# wSYwLMWbdAe/a+aS2Oe42HORaxyhxkz5NoM+NW4O9q1MJA344dpv4DNXu75SavZn
# WehffkrL7/nsJUZDppsNH3q9F0sdDF1c/auC+cp0tAi3A1CP8dUaNWWbyjpNLM77
# nShnHHKQtsjrI31VbKjoJeENB6yrPco8jxsekeQFSexV5Fsm7L20Ab6U6cinC/xd
# I8nPfMUYJs2Gm0BvenGXKWHNE+xCVRsjFEjs6Z5wuNLuwNsOJRcdsQwmdB9ECRi1
# 9Pi/AjeE3rSt4WJ4/1eRiq4z/t6JCr+5CTOo9ZEFOcsE/O4mT0DAgscqs34C1isN
# FToU/lPAXeCag1lV4w1gbIe4ANOA/HPN/0ZUSDl+JTDTKQZwqwRz9Vd01mo3H4/H
# wzofw3Y=
# SIG # End signature block
