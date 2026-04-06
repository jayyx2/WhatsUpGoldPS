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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDVmD9zgn/zz7xN
# ScMi8dFc309AZGewlWMsaRAJZZ9M2aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgcj76LZXdjyqCNEzPeOEHOQCjuJnhA0Lm
# X3dPn7O7sA4wDQYJKoZIhvcNAQEBBQAEggIAEob0WgtUgYZCsKmd4LOrcK8oJVV+
# md7ImroSTRGoraRQew+74ZXLy1zZWoV79BAzKLbjKo2HGLhOmTh30/2u8XAeiKwQ
# f3oYDJX1gI2bRMOcjqtRmY4OFjWNQir6KHesPS6RllAbkF3F4vm0q5oI475fDQiC
# ad2lUC1eU+LxtxPTI5hLwfcwqDJDKmGs5KRn8tMH6buCF6E2cZwwBMFO18Dbu9DD
# fFmdl4YggtAfJEJzri/fyw9vGLCSKm432QmxylecoO/iMqL0z7QA6y+Yw+2PpDdE
# zY0ZrZbb9waIahPocIGRxCoWs/VtKh0PxW5s31S1qfIae+bxtw1/avBdfngf1KtR
# SdFGH36wOsnwCaTWvdnDGIzkfVahQbkb2Usg+UYcJwD/ryuD6cYbNu8TJEMiUQhX
# mTgxMkQQhH5KQHv4xJX0R59hkU0H2ZZNuREdxM3odmUqnhtyq0iYpkTCHgDVkLMi
# vQMuKAj3tZ1efnccH2bfQ/OTNXJxtsd6jedrwiaxELZrjxqA7z2hAQzUVGr8O89c
# LIwinF1YGzEgpOt3qhyXTr65vjQQ8cfVPsGXnGigrPWDv6IroR2+CmuAvSry77jr
# nzNhmDx9XUsp+oodKct5fO2FSS2K+x56D7BOzP4OpUAPZivXlpGpjQFSbIV1k2/c
# 6bRFz8eOgcafn5g=
# SIG # End signature block
