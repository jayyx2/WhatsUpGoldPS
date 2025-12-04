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

    #Attributes
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $AttributesObject = @([PSCustomObject]@{ name = 'Added by WhatsUpGoldPS'; value = $now })
    if ($Attributes) {
        if ($Attributes -is [System.Collections.IEnumerable] -and $Attributes -notlike '*String*') {
            foreach ($attr in $Attributes) {
                if ($attr -is [hashtable] -or $attr -is [PSCustomObject]) {
                    if ($attr.ContainsKey('name') -and $attr.ContainsKey('value')) {
                        $AttributesObject += [PSCustomObject]@{ name = $attr.name; value = $attr.value }
                    } else {
                        # Convert all properties to name/value pairs
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
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDHR5RQjNC21W/P
# fHtK+ZJCTSKi3QHRLYtuUm1xJfMmlKCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggZkMIIEzKADAgECAhEA6IUbK/8zRw2NKvPg4jKHsTANBgkq
# hkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1p
# dGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgQ0EgUjM2
# MB4XDTIzMDQxOTAwMDAwMFoXDTI2MDcxODIzNTk1OVowVTELMAkGA1UEBhMCVVMx
# FDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNvbiBBbGJlcmlubzEX
# MBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQC2JA01BehqpO3INejKVsKScaS9sd0Hjoz1tceFig6Yyu2glTKimH9n
# r9l5438Cjpc1x+n42gMfnS5Cza4tZUWr1usOq3d0TljKFOOSW8Uve1J+PC0f/Hxp
# DbI8hE38ICDmgv8EozBOgo4lPm/rDHVTHgiRZvy1H8gPTuE13ck2sevVslku2E2F
# 8wst5Kb12OqngF96RXptEeM0iTipPhfNinWCa8e58+mbt1dHCbX46593DRd3yQv+
# rvPkIh9QkMGmumfjV5lv1S3iqf/Vg6XP9R3lTPMWNO2IEzIjk12t817rU3xYyf2Q
# 4dlA/i1bRpFfjEVcxQiZJdQKnQlqd3hOk0tr8bxTI3RZxgOLRgC8mA9hgcnJmreM
# WP4CwXZUKKX13pMqzrX/qiSUsB+Mvcn7LHGEo9pJIBgMItZW4zn4uPzGbf53EQUW
# nPfUOSBdgkRAdkb/c7Lkhhc1HNPWlUqzS/tdopI7+TzNsYr7qEckXpumBlUSONoJ
# n2V1zukFbgsBq0mRWSZf+ut3OVGo7zSYopsMXSIPFEaBcxNuvcZQXv6YdXEsDpvG
# mysbgVa/7uP3KwH9h79WeFU/TiGEISH5B59qTg26+GMRqhyZoYHj7wI36omwSNja
# tUo5cYz4AEYTO58gceMcztNO45BynLwPbZwZ0bxPN2wL1ruIYd+ewQIDAQABo4IB
# rjCCAaowHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhekzQwwHQYDVR0OBBYE
# FJHuVIzRubayI0tfw82Q7Q/47iu9MA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8E
# AjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEwNQYMKwYBBAGyMQEC
# AQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeB
# DAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNlY3RpZ28uY29tL1Nl
# Y3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5BggrBgEFBQcBAQRtMGsw
# RAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1Ymxp
# Y0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5z
# ZWN0aWdvLmNvbTAjBgNVHREEHDAagRhqYXNvbi5hbGJlcmlub0BnbWFpbC5jb20w
# DQYJKoZIhvcNAQEMBQADggGBAET0EFH0r+hqoQWr4Ha9UDuEv28rTgV2aao1nFRg
# GZ/5owM7x9lxappLUbgQFfeIzzAsp3gwTKMYf47njUjvOBZD9zV/3I/vaLmY2enm
# MXZ48Om9GW4pNmnvsef2Ub1/+dRzgs8UFX5wBJcfy4OWP3t0OaKJkn+ZltgFF1cu
# L/RPiWSRcZuhh7dIWgoPQrVx8BtC8pkh4F5ECxogQnlaDNBzGYf1UYNfEQOFec31
# UK8oENwWx5/EaKFrSi9Y4tu6rkpH0idmYds/1fvqApGxujhvCO4Se8Atfc98icX4
# DWkc1QILREHiVinmoO3smmjB5wumgP45p9OVJXhI0D0gUFQfOSappa5eO2lbnNVG
# 90rCsADmVpDDmNt2qPG01luBbX6VtWMP2thjP5/CWvUy6+xfrhlqvwZyZt3SKtuf
# FWkqnNWMnmgtBNSmBF5+q8w5SJW+24qrncKJWSIim/nRtC11XnoI9SXlaucS3Nlb
# crQVicXOtbhksEqMTn52i8NOfzGCAxswggMXAgEBMGkwVDELMAkGA1UEBhMCR0Ix
# GDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJs
# aWMgQ29kZSBTaWduaW5nIENBIFIzNgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJYIZI
# AWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAv
# BgkqhkiG9w0BCQQxIgQgJYCX+3T1BCgpxp83FeTVshitDZBmvu72mB90ccXSU48w
# DQYJKoZIhvcNAQEBBQAEggIAs1uA0fHM/09IlE/amGdRo4fzo30IMjiI26WAOWZ1
# yPH1lEB2kbw1+fXkeDhY0+P+ZklvAizCDNhs1Oe1KcZGjtEXI6qAV1eb8dJ1dTsC
# USAOBVxcoleBR9oS/MasYN+J7tTgSmiQVLKNm0OeYRV+UuNaoNLHYH+0zJQMBhSZ
# wQu2hroKUmrrrjblUxIc7GbjOr0sdNWha3n2OctIAoeTDXDDr/bWNIHmTK6d05om
# R0mxFhPRFdOlm0LHJCDP+5abuY4t2u2HVZQ/7G9nf+FtcIcOKSHFXouN6JmD22pL
# YVkY/ytaSLvTCb/PA69FfFLkL5twmbZ9QpbLgu/GE1Jycbo/TA+kY+WAcjnLzoaI
# lB0ekgQR1IbKO0hLffJWBeEV4d7nSl/KHs8AS/8dF75s9tZ0hQrJ27vP0JQJLw3R
# FjARA9WvhfFgKHx/9M/K42f+ZTzl6c4Wpukk8RLDIEuCXXPq3JGxI1crQvqH54bp
# aXXtf7UbbvEsQDrKM4m1DmGY9ejcbVx61YDvhY6HfUyVQlzUu8dVLObITe+JJXOU
# HV78wrMcJ9Y9Tyd0YlmtLhilLYtmj6YRIZyLBn2rVOr17BxX5gQN9jP52O40CT14
# Qzwi1WrGhBxEarC2ewHVjtNQs0qoQ4oWSkX31RekM7kY9hR6wZ2TM5DgL4Bu+r7z
# eK8=
# SIG # End signature block
