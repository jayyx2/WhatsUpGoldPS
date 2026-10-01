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

function Add-WUGDeviceTemplate {
    [CmdletBinding(SupportsShouldProcess = $true)]
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
        [Parameter()] [ValidateRange(1, 1440)] [int] $PerformanceMonitorPollingIntervalMinutes,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $PassiveMonitors,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $Dependencies,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $NCMTasks,
        [Parameter()] [ValidateNotNullOrEmpty()] [array] $ApplicationProfiles,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $Layer2Data,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $GroupName,
        [Parameter()] [switch] $NoDefaultActiveMonitor
    )

    Write-Debug "Function: Add-WUGDeviceTemplate"
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
                name    = $ActiveMonitor
            }
            $ActiveMonitorObjects += $ActiveMonitorObject
        }
    }
    else {
        if (!$Template -and -not $NoDefaultActiveMonitor) {
            $ActiveMonitorObjects = @()
            $ActiveMonitorObject = New-Object -TypeName PSObject -Property @{
                classId = ''
                name    = 'Ping'
            }
            $ActiveMonitorObjects += $ActiveMonitorObject   
        }
    }

    ### Performance Monitors
    $PerformanceMonitorObjects = @()
    if ($PerformanceMonitors) {
        foreach ($PerformanceMonitor in $PerformanceMonitors) {
            $perfProps = @{
                classId = ''
                name    = $PerformanceMonitor
            }
            if ($PerformanceMonitorPollingIntervalMinutes -gt 0) {
                $perfProps['pollingIntervalMinutes'] = $PerformanceMonitorPollingIntervalMinutes
            }
            $PerformanceMonitorObject = New-Object -TypeName PSObject -Property $perfProps
            $PerformanceMonitorObjects += $PerformanceMonitorObject
        }
    }
    ### Passive Monitors
    $PassiveMonitorObjects = @()
    if ($PassiveMonitors) {
        foreach ($PassiveMonitor in $PassiveMonitors) {
            $PassiveMonitorObject = New-Object -TypeName PSObject -Property @{
                classId = ''
                name    = $PassiveMonitor
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
    if ($CredentialAzure){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'Azure'
        credential     = $CredentialAzure
        }
        $CredentialObjects += $CredentialObject
    }
    if ($CredentialMeraki){
        $CredentialObject = New-Object -TypeName PSObject -Property @{
        credentialType = 'Meraki'
        credential     = $CredentialMeraki
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

    #Attributes
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $AttributesObject = @([PSCustomObject]@{ name = 'Added by WhatsUpGoldPS'; value = $now })
    if ($Attributes) {
        if ($Attributes -is [System.Collections.IEnumerable] -and $Attributes -notlike '*String*') {
            foreach ($attr in $Attributes) {
                if ($attr -is [hashtable]) {
                    if ($attr.ContainsKey('name') -and $attr.ContainsKey('value')) {
                        $AttributesObject += [PSCustomObject]@{ name = $attr.name; value = $attr.value }
                    } else {
                        # Convert all properties to name/value pairs
                        foreach ($prop in $attr.PSObject.Properties) {
                            $AttributesObject += [PSCustomObject]@{ name = $prop.Name; value = $prop.Value }
                        }
                    }
                } elseif ($attr -is [PSCustomObject]) {
                    $nameProperty = $attr.PSObject.Properties['name']
                    $valueProperty = $attr.PSObject.Properties['value']
                    if ($nameProperty -and $valueProperty) {
                        $AttributesObject += [PSCustomObject]@{ name = $nameProperty.Value; value = $valueProperty.Value }
                    } else {
                        foreach ($prop in $attr.PSObject.Properties) {
                            $AttributesObject += [PSCustomObject]@{ name = $prop.Name; value = $prop.Value }
                        }
                    }
                }
            }
        } elseif ($Attributes -is [hashtable] -or $Attributes -is [PSCustomObject]) {
            foreach ($prop in $Attributes.PSObject.Properties) {
                $AttributesObject += [PSCustomObject]@{ name = $prop.Name; value = $prop.Value }
            }
        }
    }

    #Set note to always include the current date and time
    $note = "Added by WhatsUpGoldPS on ${now} ${note}"
    
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
            attributes          = @(${AttributesObject})
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
        if ($note){ 
            $Template.note = "${note}"
        }
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
        if ($AttributesObject) {
            $Template.attributes = @(${$AttributesObject})
        }
    }    
    #End template handling

    $jsonBody = $Template | ConvertTo-Json -Depth 5 -Compress

    $body = "{
        `"options`":[`"all`"],
        `"templates`":[${jsonBody}]
    }"

    if (-not $PSCmdlet.ShouldProcess("Device '${displayName}' (${DeviceAddress})", 'Add device from template')) { return }

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
        Write-Error "Error adding device: $($_.Exception.Message)"
        Write-Debug "Full exception: $($_.Exception | Format-List * | Out-String)"
    }
}
# End of Add-WUGDeviceTemplate function
# End of script
#------------------------------------------------------------------
# This script is part of the WhatsUpGoldPS PowerShell module.
# It is designed to interact with the WhatsUp Gold API for network monitoring.
# The script is provided as-is and is not officially supported by WhatsUp Gold.
# Use at your own risk.
#------------------------------------------------------------------


# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBa7FY6Jvot7h8s
# th7zNKAMztZBU6F3R6Qa4SD7Devcf6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
# jTanyYqJ1pQWMA0GCSqGSIb3DQEBDAUAMHsxCzAJBgNVBAYTAkdCMRswGQYDVQQI
# DBJHcmVhdGVyIE1hbmNoZXN0ZXIxEDAOBgNVBAcMB1NhbGZvcmQxGjAYBgNVBAoM
# EUNvbW9kbyBDQSBMaW1pdGVkMSEwHwYDVQQDDBhBQUEgQ2VydGlmaWNhdGUgU2Vy
# dmljZXMwHhcNMjEwNTI1MDAwMDAwWhcNMjgxMjMxMjM1OTU5WjBWMQswCQYDVQQG
# EwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0aWdv
# IFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCN55QSIgQkdC7/FiMCkoq2rjaFrEfUI5ErPtx94jGgUW+s
# hJHjUoq14pbe0IdjJImK/+8Skzt9u7aKvb0Ffyeba2XTpQxpsbxJOZrxbW6q5KCD
# J9qaDStQ6Utbs7hkNqR+Sj2pcaths3OzPAsM79szV+W+NDfjlxtd/R8SPYIDdub7
# P2bSlDFp+m2zNKzBenjcklDyZMeqLQSrw2rq4C+np9xu1+j/2iGrQL+57g2extme
# me/G3h+pDHazJyCh1rr9gOcB0u/rgimVcI3/uxXP/tEPNqIuTzKQdEZrRzUTdwUz
# T2MuuC3hv2WnBGsY2HH6zAjybYmZELGt2z4s5KoYsMYHAXVn3m3pY2MeNn9pib6q
# RT5uWl+PoVvLnTCGMOgDs0DGDQ84zWeoU4j6uDBl+m/H5x2xg3RpPqzEaDux5mcz
# mrYI4IAFSEDu9oJkRqj1c7AGlfJsZZ+/VVscnFcax3hGfHCqlBuCF6yH6bbJDoEc
# QNYWFyn8XJwYK+pF9e+91WdPKF4F7pBMeufG9ND8+s0+MkYTIDaKBOq3qgdGnA2T
# OglmmVhcKaO5DKYwODzQRjY1fJy67sPV+Qp2+n4FG0DKkjXp1XrRtX8ArqmQqsV/
# AZwQsRb8zG4Y3G9i/qZQp7h7uJ0VP/4gDHXIIloTlRmQAOka1cKG8eOO7F/05QID
# AQABo4IBEjCCAQ4wHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYD
# VR0OBBYEFDLrkpr/NZZILyhAQnAgNpFcF4XmMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMDMBsGA1UdIAQUMBIwBgYE
# VR0gADAIBgZngQwBBAEwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21v
# ZG9jYS5jb20vQUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEE
# KDAmMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZI
# hvcNAQEMBQADggEBABK/oe+LdJqYRLhpRrWrJAoMpIpnuDqBv0WKfVIHqI0fTiGF
# OaNrXi0ghr8QuK55O1PNtPvYRL4G2VxjZ9RAFodEhnIq1jIV9RKDwvnhXRFAZ/ZC
# J3LFI+ICOBpMIOLbAffNRk8monxmwFE2tokCVMf8WPtsAO7+mKYulaEMUykfb9gZ
# pk+e96wJ6l2CxouvgKe9gUhShDHaMuwV5KZMPWw5c9QLhTkg4IUaaOGnSDip0TYl
# d8GNGRbFiExmfS9jzpjoad+sPKhdnckcW67Y8y90z7h+9teDnRGWYpquRRPaf9xH
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCG+GJSPhs44I1544ykTd+QqKseTazBGsOp2E4FktuDxDANBgkqhkiG9w0BAQEF
# AASCAgCK3br4kg8So68LZLX3/hi30aQ0oVoGL7q8V8sN0YlPgkuVQt69AxV+d3Kk
# KxhXmb0b3EVmO/kOOZZjvZrm4T69dmqo+11t3SWiyG6Cb8lUnUdZnpkiGizC5/bv
# H9KEXRAP96gfzNeUpk71rzj3UgQiDMBwm3aWhW5lk62CRWOe1vpXoPsAR+Ieceoc
# wex0yaAOlZGG5JEhY6HX3V8oy5HYvBkO9EQYTSlDWTvCQQQD41+dSV6nn45CV8CQ
# w0R0T0rF+JFGcof5YZ196egJbG6XShsWl8VG5HncIaS5KyNhM8laHNl+WrEZtfdx
# N+S/PMNpdh+xAJSZDXWN+WCEZBSfybxGLvBEsGFZuk77caWa0bvjrqDLayTeAEyl
# +kMsjV7fGeoDJYVtsucu7sfQEIXXuQA614tbKHzXjNjvfQAByZhtz6CG9p+87TIF
# FRW9TGFm7a8do6h/jeGi79vJiIA72lSS5Ny1LOLUSoxleo0eVitNAvFSLg62bLko
# M6ToW3MiqJ5N3AzJFEBHS3YcNUj5DDRnLgBJoOt+u+q2rv8mQRBfgczSKyTDV2gc
# dDeZMNk8OHTfhSxBb3quokRirTY4CPzUWd7qn9bd0NPOZ3i+8WEHeUww7G9HeF4m
# BYqkZt7Jrzz45fVMLRPktWxblt7KWBqi3Jq9ra/jb40foUUKyKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MzAyMjA1MzJaMC8GCSqGSIb3DQEJBDEiBCAarOiJ
# nRtpfdu4dWXFqC37ZtSvIyw+2Sqm/d9c4XIv2zANBgkqhkiG9w0BAQEFAASCAgCz
# wZqE+mXrIkbGLNITAlj18eMDROnN97In5UqHiBm4RLIZ0WroGC0wtO6Uzeq1WdOg
# NPwTDOA6bWH8tLmxwgMzqYROBXVAV2E3T6uuyAVVmbo4d1fcjICnEkB8MviYXUke
# Dk8Md1fx9RYi6ReSyleA77A90kSF7zZl9qwpl3wnEAshhgjqy5EOf/S1mRhRObX0
# ysmAlvfcRSyJ1k66/pYNsvJ5pUEHUjkk1M1oVeipSiLt3gSzdEB2A5rmdoXkaWm8
# pK8VuK9Wcpuva7Ej7p3Lr/tzaW6pbF/OzLoQ2wzc/4Pj1NfwetXbdcN0eF8a6+G7
# 7w91rZTOLD2Tz8yF8Y7pvmluFcEHhYqfFuawJz8o9mbojBQaRcn8Hy9GtMMVBbRy
# F4pJKnO08M0X74lHxqDjPEkMLyK4DSYJv1CWi3oJIa2COY7IUX/KygXAU3f4GDVM
# TyGC4XdKcqMLWsk/WaQtnKxrvwweWIFR/EHRxlQQTixqehEUEYyEDP3KwXbLDhB/
# rmyNcPiOjAHB1HlKkDW5CjyThAlfLaJg1V4Sq4iMHpP0FX/EE7oIMVSPDNUi746Z
# bEEhwXP7rbNxQBgoAtxjKrtAdYwmtfacwvizAdRIZm4qOkYcNl3TBZIdMAFIQHeC
# mWtwnBMetLWF8HvhR1Q1VjYESunpazgsxUkMFZtFXw==
# SIG # End signature block
