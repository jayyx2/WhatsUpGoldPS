<#
.SYNOPSIS
    Adds an active monitor to WhatsUp Gold (WUG) for various monitoring types including SNMP, SNMP Table, Ping, TCP/IP, Certificate, WMI, and more.

.DESCRIPTION
    This function allows the user to create different types of active monitors in WhatsUp Gold (WUG) by specifying the type of monitor and its relevant parameters.
    It supports various monitoring types such as Ping, TCP/IP, SNMP, Process, Certificate, Service, and WMIFormatted.
    The function handles the creation of the monitor by checking if it already exists and then making the appropriate API call to create the monitor with the specified settings.

.PARAMETER Type
    The type of the monitor to be created. Valid values are 'Ping', 'TcpIp', 'SNMP', 'SNMPTable', 'Process', 'Certificate', 'Service', 'WMIFormatted'.
    This parameter is mandatory and determines the set of additional parameters required.
    TBD: 

.PARAMETER Name
    The name of the monitor to be created. This parameter is mandatory.

.PARAMETER Timeout
    The timeout value for the monitor in seconds. Default is 5 seconds. This parameter is shared among all parameter sets.

.PARAMETER Retries
    The number of retries for the monitor. Default is 1. This parameter is shared among all parameter sets.

.PARAMETER PingPayloadSize
    The payload size for the Ping monitor. Valid values are between 1 and 65535. This parameter is specific to the 'Ping' parameter set.

.PARAMETER TcpIpPort
    The port number for the TCP/IP monitor. Valid values are between 1 and 65535. This parameter is specific to the 'TcpIp' parameter set.

.PARAMETER TcpIpProtocol
    The protocol to use for the TCP/IP monitor. Valid values are 'TCP', 'UDP', 'SSL'. This parameter is specific to the 'TcpIp' parameter set.

.PARAMETER TcpIpScript
    The script to use for the TCP/IP monitor. This parameter is specific to the 'TcpIp' parameter set.

.PARAMETER CertOption
    The option for the Certificate monitor. Valid values are 'url', 'file'. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertPath
    The path for the Certificate monitor. It can be a URL or a file path. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertExpiresDays
    The number of days before the certificate expires. Default is 5 days. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertCheckUsage
    A switch to check the usage of the certificate. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertCheckExpires
    A switch to check if the certificate expires. Default is $true. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertUseProxySettings
    A switch to use proxy settings for the Certificate monitor. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertProxyServer
    The proxy server for the Certificate monitor. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertProxyPort
    The proxy port for the Certificate monitor. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertProxyUser
    The proxy user for the Certificate monitor. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER CertProxyPwd
    The proxy password for the Certificate monitor. This parameter is specific to the 'Certificate' parameter set.

.PARAMETER SnmpOID
    The OID for the SNMP monitor. This parameter is specific to the 'ConstantOrRate' and 'Range' parameter sets.

.PARAMETER SnmpInstance
    The instance for the SNMP monitor. Default is an empty string. This parameter is specific to the 'ConstantOrRate' and 'Range' parameter sets.

.PARAMETER SnmpCheckType
    The check type for the SNMP monitor. Valid values are 'constant', 'range', 'rateofchange'. This parameter is specific to the 'ConstantOrRate' and 'Range' parameter sets.

.PARAMETER SnmpValue
    The value for the SNMP monitor with 'constant' or 'rateofchange' check type. This parameter is mandatory for the 'ConstantOrRate' parameter set.

.PARAMETER SnmpLowValue
    The low value for the SNMP monitor with 'range' check type. This parameter is mandatory for the 'Range' parameter set.

.PARAMETER SnmpHighValue
    The high value for the SNMP monitor with 'range' check type. This parameter is mandatory for the 'Range' parameter set.

.PARAMETER ProcessName
    The name of the process for the Process monitor. This parameter is specific to the 'Process' parameter set.

.PARAMETER ProcessDownIfRunning
    A switch to mark the process as down if it is running. Valid values are 'true' or 'false'. Default is 'false'. This parameter is specific to the 'Process' parameter set.

.PARAMETER ProcessUseWMI
    A switch to use WMI for the Process monitor. Default is $false. This parameter is specific to the 'Process' parameter set.

.PARAMETER ServiceDisplayName
    The display name of the service for the Service monitor. This parameter is specific to the 'Service' parameter set.

.PARAMETER ServiceInternalName
    The internal name of the service for the Service monitor. This parameter is specific to the 'Service' parameter set.

.PARAMETER ServiceUseSNMP
    A switch to use SNMP for the Service monitor. Default is $false. This parameter is specific to the 'Service' parameter set.

.PARAMETER ServiceSNMPRetries
    The number of retries for SNMP in the Service monitor. Default is 1. This parameter is specific to the 'Service' parameter set.

.PARAMETER ServiceSNMPTimeout
    The timeout value for SNMP in the Service monitor in seconds. Default is 3 seconds. This parameter is specific to the 'Service' parameter set.

.PARAMETER ServiceRestartOnFailure
    The number of times to restart the service on failure. Default is 0. This parameter is specific to the 'Service' parameter set.

.PARAMETER WMIFormattedRelativePath
    The relative path for the WMIFormatted monitor. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedPerformanceCounter
    The performance counter for the WMIFormatted monitor. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedPerformanceInstance
    The performance instance for the WMIFormatted monitor. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedCheckType
    The check type for the WMIFormatted monitor. Valid values are 'constant', 'range', 'rateofchange'. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedConstantValue
    The constant value for the WMIFormatted monitor with 'constant' check type. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedConstantUpIfMatch
    A switch to mark the monitor up if the constant value matches. Default is $true. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedRangeLowValue
    The low value for the WMIFormatted monitor with 'range' check type. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedRangeHighValue
    The high value for the WMIFormatted monitor with 'range' check type. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedROCValue
    The rate of change value for the WMIFormatted monitor with 'rateofchange' check type. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedROCUpIfAbove
    A switch to mark the monitor up if the rate of change value is above the specified value. Default is $true. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedPropertyName
    The property name for the WMIFormatted monitor. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER WMIFormattedComputerName
    The computer name for the WMIFormatted monitor. This parameter is specific to the 'WMIFormatted' parameter set.

.PARAMETER UseInDiscovery
    Whether the monitor should be used during device discovery. Valid values: 'true', 'false'. Default is 'false'.

.PARAMETER SnmpTableDiscOID
    The SNMP OID used for table discovery. Specific to the 'SNMPTable' parameter set.

.PARAMETER SnmpTableDiscOperator
    The operator for SNMP table discovery matching. Valid values: 'equals', 'range', 'rateofchange', 'gt', 'lt', 'oneof', 'contains'. Default is 'equals'.

.PARAMETER SnmpTableDiscValue
    The value to match for SNMP table discovery.

.PARAMETER SnmpTableDiscRangeLow
    The low range value for SNMP table discovery. Default is 0.

.PARAMETER SnmpTableDiscRangeHigh
    The high range value for SNMP table discovery. Default is 0.

.PARAMETER SnmpTableDiscCommentOID
    The SNMP OID used for table discovery comment. Default is empty.

.PARAMETER SnmpTableDiscIndexOID
    The SNMP OID used as the index for table discovery. Default is empty.

.PARAMETER SnmpTableDiscCreates
    Whether SNMP table discovery creates instances. Valid values: 'true', 'false'. Default is 'true'.

.PARAMETER SnmpTableMonitoredOID
    The SNMP OID to monitor in the table.

.PARAMETER SnmpTableMonitorOperator
    The operator for SNMP table monitoring. Valid values: 'constant', 'range', 'rateofchange', 'gt', 'lt', 'oneof', 'contains'. Default is 'constant'.

.PARAMETER SnmpTableMonitoredValue
    The value to compare against for SNMP table monitoring.

.PARAMETER SnmpTableMonitorRangeLow
    The low range value for SNMP table monitoring. Default is 0.

.PARAMETER SnmpTableMonitorRangeHigh
    The high range value for SNMP table monitoring. Default is 0.

.PARAMETER SnmpTableMonitorUpIfMatch
    Determines the monitor state when the value matches. Valid values: 'upifmatch', 'downifmatch'. Default is 'upifmatch'.

.NOTES
    Author: Jason Alberino
    Date: 2025-04-06

.EXAMPLE
    Add-WUGActiveMonitor -Type SNMP -Name 20241019-snmpmonitor-test-1-new -SnmpOID 1.3.6.1 -SnmpInstance 1 -SnmpCheckType constant -SnmpValue 9

Description
-----------
    This command adds an SNMP active monitor named "20241019-snmpmonitor-test-1-new" with the OID "1.3.6.1", instance "1", check type "constant",
    and value "9".

.EXAMPLE
    Add-WUGActiveMonitor -Type Ping -Name "9999 ping" -PingPayloadSize 9999 -Timeout 10 -Retries 1

Description
-----------
    This command adds a Ping active monitor named "9999 ping" with a payload size of 9999 bytes, timeout of 10 seconds, and 1 retry.

.EXAMPLE
    Add-WUGActiveMonitor -Type TcpIp -Name TestTCPIpMon-2024-10-19 -Timeout 5 -TcpIpPort 8443 -TcpIpProtocol SSL

Description
-----------
    This command adds a TCP/IP active monitor named "TestTCPIpMon-2024-10-19" with a timeout of 5 seconds, port 8443, and protocol SSL.

.EXAMPLE
    Add-WUGActiveMonitor -Type Certificate -Name Certmontest-byURL-test3 -CertOption url -CertCheckExpires $true -CertExpiresDays 30 -CertPath "https://192.168.1.250"

Description
-----------
    This command adds a Certificate active monitor named "Certmontest-byURL-test3" with the URL option, check expires set to true, expiration days set 
    to 30, and path "https://192.168.1.250".

.EXAMPLE
    Add-WUGActiveMonitor -Type WMIFormatted -Name "AD LDAP Bind Time RangeCheck" -WMIFormattedRelativePath "Win32_PerfFormattedData_NTDS_NTDS" -WMIFormattedPerformanceCounter "LDAP Bind Time (msec)" -WMIFormattedPerformanceInstance "NULL" -WMIFormattedCheckType "range" -WMIFormattedRangeLowValue 0 -WMIFormattedRangeHighValue 200 -WMIFormattedPropertyName "LDAPBindTime" -WMIFormattedComputerName "localhost"

Description
-----------
    This command adds a WMIFormatted active monitor named "AD LDAP Bind Time RangeCheck" with the relative path "Win32_PerfFormattedData_NTDS_NTDS",
    performance counter "LDAP Bind Time (msec)", performance instance "NULL", check type "range", low value "0", high value "200", property name 
    "LDAPBindTime", and computer name "localhost".
#>

function Add-WUGActiveMonitor {
    [CmdletBinding(DefaultParameterSetName = 'Ping', SupportsShouldProcess = $true)]
    param(
        # Common Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'Ping')]
        [Parameter(Mandatory = $true, ParameterSetName = 'TcpIp')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ConstantOrRate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Process')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Service')]
        [Parameter(Mandatory = $true, ParameterSetName = 'WMIFormatted')]
        [Parameter(Mandatory = $true, ParameterSetName = 'SNMPTable')]
        [ValidateSet('Ping', 'TcpIp', 'SNMP', 'SNMPTable', 'Process', 'Certificate', 'Service', 'WMIFormatted')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        # Shared Parameters
        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$Timeout = 5,

        [Parameter()]
        [ValidateRange(1, 5)]
        [int]$Retries = 1,

        [Parameter()]
        [ValidateSet("true", "false")]
        [string]$UseInDiscovery = "false",

        # Service Monitor Parameters
        [Parameter(ParameterSetName = 'Service')]
        [string]$ServiceDisplayName,
        [Parameter(ParameterSetName = 'Service')]
        [string]$ServiceInternalName,
        [Parameter(ParameterSetName = 'Service')]
        [ValidateSet("true", "false")][string]$ServiceUseSNMP = "false",
        [Parameter(ParameterSetName = 'Service')]
        [int]$ServiceSNMPRetries = 1,
        [Parameter(ParameterSetName = 'Service')]
        [int]$ServiceSNMPTimeout = 3,
        [Parameter(ParameterSetName = 'Service')]
        [int]$ServiceRestartOnFailure = 0,

        # Ping Monitor Parameters
        [Parameter(ParameterSetName = 'Ping')]
        [ValidateRange(1, 65535)]
        [int]$PingPayloadSize = 32,

        # TCP/IP Monitor Parameters
        [Parameter(ParameterSetName = 'TcpIp')]
        [ValidateRange(1, 65535)]
        [int]$TcpIpPort,
        [Parameter(ParameterSetName = 'TcpIp')]
        [ValidateSet('TCP', 'UDP', 'SSL')]
        [string]$TcpIpProtocol,
        [Parameter(ParameterSetName = 'TcpIp')]
        [string]$TcpIpScript = "",

        # Certificate Monitor Parameters
        [Parameter(ParameterSetName = 'Certificate')]
        [ValidateSet('url', 'file')]
        [string]$CertOption,
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertPath, # URL or File Path
        [Parameter(ParameterSetName = 'Certificate')]
        [int]$CertExpiresDays = 5,
        [Parameter(ParameterSetName = 'Certificate')]
        [ValidateSet("true", "false")][string]$CertCheckUsage = "false",
        [Parameter(ParameterSetName = 'Certificate')]
        [ValidateSet("true", "false")][string]$CertCheckExpires = "true",
        [Parameter(ParameterSetName = 'Certificate')]
        [ValidateSet("true", "false")][string]$CertUseProxySettings = "false",
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertProxyServer = "",
        [Parameter(ParameterSetName = 'Certificate')]
        [int]$CertProxyPort = 0,
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertProxyUser = "",
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertProxyPwd = "",

        # SNMP Monitor Parameters
        [Parameter(ParameterSetName = 'ConstantOrRate')]
        [Parameter(ParameterSetName = 'Range')]
        [string]$SnmpOID,
        [Parameter(ParameterSetName = 'ConstantOrRate')]
        [Parameter(ParameterSetName = 'Range')]
        [string]$SnmpInstance = "",
        [Parameter(ParameterSetName = 'ConstantOrRate')]
        [Parameter(ParameterSetName = 'Range')]
        [ValidateSet('constant', 'range', 'rateofchange')]
        [string]$SnmpCheckType,

        # Parameters for SNMP monitor constant or rateofchange
        [Parameter(ParameterSetName = 'ConstantOrRate', Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SnmpValue,
        # Parameters for SNMP monitor range check type
        [Parameter(ParameterSetName = 'Range', Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SnmpLowValue,
        [Parameter(ParameterSetName = 'Range', Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SnmpHighValue,

        # Process Monitor Parameters
        [Parameter(ParameterSetName = 'Process')]
        [string]$ProcessName,        
        [Parameter(ParameterSetName = 'Process')]
        [ValidateSet('true', 'false')][string]$ProcessDownIfRunning = 'false',        
        [Parameter(ParameterSetName = 'Process')]
        [ValidateSet("true", "false")][string]$ProcessUseWMI = "false",
        
        # WMIFormatted Monitor Parameters
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedRelativePath,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedPerformanceCounter,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedPerformanceInstance,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedCheckType, # 'constant', 'range', or 'rateofchange'
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedConstantValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [ValidateSet("true", "false")][string]$WMIFormattedConstantUpIfMatch = "true",
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedRangeLowValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedRangeHighValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedROCValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [ValidateSet("true", "false")][string]$WMIFormattedROCUpIfAbove = "true",
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedPropertyName,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedComputerName,

        # SNMPTable Monitor Parameters
        [Parameter(ParameterSetName = 'SNMPTable')]
        [string]$SnmpTableDiscOID,
        [Parameter(ParameterSetName = 'SNMPTable')]
        [ValidateSet('equals', 'range', 'rateofchange', 'gt', 'lt', 'oneof', 'contains')]
        [string]$SnmpTableDiscOperator = 'equals',
        [Parameter(ParameterSetName = 'SNMPTable')]
        [string]$SnmpTableDiscValue = "",
        [Parameter(ParameterSetName = 'SNMPTable')]
        [int]$SnmpTableDiscRangeLow = 0,
        [Parameter(ParameterSetName = 'SNMPTable')]
        [int]$SnmpTableDiscRangeHigh = 0,
        [Parameter(ParameterSetName = 'SNMPTable')]
        [string]$SnmpTableDiscCommentOID = "",
        [Parameter(ParameterSetName = 'SNMPTable')]
        [string]$SnmpTableDiscIndexOID = "",
        [Parameter(ParameterSetName = 'SNMPTable')]
        [ValidateSet('true', 'false')]
        [string]$SnmpTableDiscCreates = 'true',

        [Parameter(ParameterSetName = 'SNMPTable')]
        [string]$SnmpTableMonitoredOID,
        [Parameter(ParameterSetName = 'SNMPTable')]
        [ValidateSet('constant', 'range', 'rateofchange', 'gt', 'lt', 'oneof', 'contains')]
        [string]$SnmpTableMonitorOperator = 'constant',
        [Parameter(ParameterSetName = 'SNMPTable')]
        [string]$SnmpTableMonitoredValue = "",
        [Parameter(ParameterSetName = 'SNMPTable')]
        [int]$SnmpTableMonitorRangeLow = 0,
        [Parameter(ParameterSetName = 'SNMPTable')]
        [int]$SnmpTableMonitorRangeHigh = 0,
        [Parameter(ParameterSetName = 'SNMPTable')]
        [ValidateSet('upifmatch', 'downifmatch')]
        [string]$SnmpTableMonitorUpIfMatch = 'upifmatch'
    )

    begin {
        Write-Debug "Initializing Add-WUGActiveMonitor function with Type: $Type"
        $baseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"
        $ClassId = ""
        $PropertyBags = @()
        $skipCreation = $false

        # Check if the monitor already exists
        Write-Verbose "Checking if monitor with name '${Name}' already exists."
        $existingMonitorUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-?type=active&view=details&search=$([uri]::EscapeDataString(${Name}))"

        try {
            $existingMonitorResult = Get-WUGAPIResponse -Uri $existingMonitorUri -Method GET -ErrorAction Stop
            if ($existingMonitorResult.data.activeMonitors | Where-Object { $_.name -eq $Name }) {
                Write-Host "Monitor with the name '$Name' already exists. Skipping creation." -ForegroundColor Yellow
                $skipCreation = $true
                return
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Host "No existing monitor found with the name '$Name'. Proceeding with creation." -ForegroundColor Green
            }
            else {
                Write-Warning "Failed to check for existing monitors: $($_.Exception.Message)"
                return
            }
        }

        # Monitor-specific setup
        switch ($Type) {
            'Ping' {
                $ClassId = '2655476e-36b0-455f-9cce-940b6f8e07bf'
                $PropertyBags = @(
                    @{ "name" = "Timeout"; "value" = "$Timeout" },
                    @{ "name" = "Retries"; "value" = "$Retries" },
                    @{ "name" = "PayloadSize"; "value" = "$PingPayloadSize" }
                )
            }
            'TcpIp' {
                $ClassId = '1ee6ecd4-4c17-4ccc-8ff8-3147f445943f'
                $PropertyBags = @(
                    @{ "name" = "Timeout"; "value" = "$Timeout" },
                    @{ "name" = "Protocol"; "value" = "$TcpIpProtocol" },
                    @{ "name" = "Port"; "value" = "$TcpIpPort" },
                    @{ "name" = "Script"; "value" = "$TcpIpScript" }
                )
            }
            'SNMP' {
                $ClassId = 'd6d02d69-a418-483a-93ea-20dd2af2d135'
                $SnmpCheckTypeValue = switch ($SnmpCheckType) {
                    'constant' { 0 }
                    'range' { 1 }
                    'rateofchange' { 2 }
                }

                if ($SnmpCheckType -eq 'range') {
                    $PropertyBags = @(
                        @{ "name" = "SNMP:CheckType"; "value" = "$SnmpCheckTypeValue" },
                        @{ "name" = "SNMP:OID"; "value" = "$SnmpOID" },
                        @{ "name" = "SNMP:Instance"; "value" = "$SnmpInstance" },
                        @{ "name" = "SNMP:Range-LowValue"; "value" = "$SnmpLowValue" },
                        @{ "name" = "SNMP:Range-HighValue"; "value" = "$SnmpHighValue" }
                    )
                }
                else {
                    $PropertyBags = @(
                        @{ "name" = "SNMP:CheckType"; "value" = "$SnmpCheckTypeValue" },
                        @{ "name" = "SNMP:OID"; "value" = "$SnmpOID" },
                        @{ "name" = "SNMP:Instance"; "value" = "$SnmpInstance" },
                        @{ "name" = "SNMP:Constant-Value"; "value" = "$SnmpValue" }
                    )
                }
            }
                'Process' {
                $ClassId = '92c56b83-d6a7-43a4-a094-8fe5f8fa4b2c'
                $ProcessRunningStatus = if ($ProcessDownIfRunning -eq 'true') { 1 } else { 4 }
                $ProcessThresholdsXml = @"
<?xml version="1.0" encoding="utf-16"?>
<ProcessThresholds xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Name>ProcessThresholds</Name>
  <Thresholds>
    <Threshold xsi:type="StatusThreshold">
      <Checked>true</Checked>
      <Type>1</Type>
      <RunningStatus>$ProcessRunningStatus</RunningStatus>
    </Threshold>
  </Thresholds>
</ProcessThresholds>
"@
                $PropertyBags = @(
                    @{ "name" = "MonProcess:ProcessName"; "value" = "$ProcessName" },
                    @{ "name" = "MonProcess:UseWMI"; "value" = "$ProcessUseWMI" },
                    @{ "name" = "MonProcess:SnmpNumRetries"; "value" = "$Retries" },
                    @{ "name" = "MonProcess:SnmpTimeoutMs"; "value" = ($Timeout * 1000) },
                    @{ "name" = "MonProcess:ProcessThresholds"; "value" = $ProcessThresholdsXml.Trim() }
                )
                }
        
            'Certificate' {
                $ClassId = 'de27943b-b036-4b6d-ae4c-1093b210c233'
                $PropertyBags = @(
                    @{ "name" = "MonSSLCert:CertificateOption"; "value" = "$CertOption" },
                    @{ "name" = "MonSSLCert:Path"; "value" = "$CertPath" },
                    @{ "name" = "MonSSLCert:ExpiresDays"; "value" = "$CertExpiresDays" },
                    @{ "name" = "MonSSLCert:CheckUsage"; "value" = "$CertCheckUsage" },
                    @{ "name" = "MonSSLCert:CheckExpires"; "value" = "$CertCheckExpires" },                    
                    @{ "name" = "MonSSLCert:Timeout"; "value" = "$Timeout" }
                )
                if ($CertUseProxySettings -eq "true") {
                    $PropertyBags += @(
                        @{ "name" = "MonSSLCert:UseProxySettings"; "value" = "$CertUseProxySettings"},
                        @{ "name" = "MonSSLCert:ProxyServer"; "value" = "$CertProxyServer" },
                        @{ "name" = "MonSSLCert:ProxyPort"; "value" = "$CertProxyPort" },
                        @{ "name" = "MonSSLCert:ProxyUser"; "value" = "$CertProxyUser" },
                        @{ "name" = "MonSSLCert:ProxyPassword"; "value" = "$CertProxyPwd" }
                    )
                }
            }

            'Service' {
                $ClassId = '20816756-7dd5-4400-adb8-63d9c2147b97'
                $SNMPFlag = if ($ServiceUseSNMP -eq "true") { 1 } else { 0 }

                $PropertyBags = @(
                    @{ "name" = "Cred:Type"; "value" = "1,2,4,8" },
                    @{ "name" = "NTSERVICE:RestartOnFailure"; "value" = "$ServiceRestartOnFailure" },
                    @{ "name" = "NTSERVICE:ServiceDisplayName"; "value" = "$ServiceDisplayName" },
                    @{ "name" = "NTSERVICE:ServiceInternalName"; "value" = "$ServiceInternalName" },
                    @{ "name" = "NTSERVICE:SNMPRetries"; "value" = "$ServiceSNMPRetries" },
                    @{ "name" = "NTSERVICE:SNMPTimeout"; "value" = "$ServiceSNMPTimeout" },
                    @{ "name" = "NTSERVICE:UseSNMP"; "value" = "$SNMPFlag" }
                )
            }
            
            'WMIFormatted' {
                $ClassId = "67a03c83-7166-405d-b9e7-0433b8b81a61"  # CLSID for WMIFormatted Monitor
                # Derive a friendly object name for the display
                if ($WMIFormattedRelativePath -like "Win32_PerfFormattedData_*_*") {
                    $objectName = $WMIFormattedRelativePath.Substring($WMIFormattedRelativePath.LastIndexOf("_") + 1)
                }
                else { 
                    $objectName = $WMIFormattedRelativePath
                }
                
                # If no instance is specified (or if user wants "NULL"), we display NULL
                if (-not $WMIFormattedPerformanceInstance -or $WMIFormattedPerformanceInstance -eq 'NULL') {
                    $actualInstance = 'NULL'
                }
                else {
                    $actualInstance = $WMIFormattedPerformanceInstance
                }

                # Use a single backslash for Displayname (objectName \ counter)
                $WMIFormattedDisplayName = "$objectName \ $WMIFormattedPerformanceCounter"

                # Handle missing numeric parameters cleanly
                $RangeLowValue = if ($PSBoundParameters.ContainsKey('WMIFormattedRangeLowValue')) { $WMIFormattedRangeLowValue } else { "" }
                $RangeHighValue = if ($PSBoundParameters.ContainsKey('WMIFormattedRangeHighValue')) { $WMIFormattedRangeHighValue } else { "" }
                $ConstantValue = if ($PSBoundParameters.ContainsKey('WMIFormattedConstantValue')) { $WMIFormattedConstantValue }  else { "" }
                $ROCValue = if ($PSBoundParameters.ContainsKey('WMIFormattedROCValue')) { $WMIFormattedROCValue }       else { "" }

                # Set CheckType based on input
                $CheckTypeValue = switch ($WMIFormattedCheckType) {
                    'constant' { "0" }
                    'range' { "1" }
                    'rateofchange' { "2" }
                }

                # Determine the ROC-UpIfAboveValue only if using rate-of-change
                if ($WMIFormattedCheckType -eq 'rateofchange') {
                    # If user provided WMIFormattedROCUpIfAbove, respect it; otherwise default to '0'
                    $ROCUpIfAboveValue = if ($PSBoundParameters.ContainsKey('WMIFormattedROCUpIfAbove')) {if ($WMIFormattedROCUpIfAbove) { "0" } else { "1" }} else {"0"}}
                else {
                    $ROCUpIfAboveValue = ""
                }

                # Determine ConstantUpIfMatchValue (defaults to "0" if not specified)
                $ConstantUpIfMatchValue = if ($PSBoundParameters.ContainsKey('WMIFormattedConstantUpIfMatch')) {
                    if ($WMIFormattedConstantUpIfMatch) { "0" } else { "1" }
                }
                else {
                    "0"
                }

                $PropertyBags = @(
                    @{ "name" = "WMI:Formatted-Counter-Displayname"; "value" = $WMIFormattedDisplayName },
                    @{ "name" = "WMI:Formatted-Counter-InstanceName"; "value" = $actualInstance },
                    @{ "name" = "WMI:Formatted-Counter-RelativePath"; "value" = $WMIFormattedRelativePath },
                    @{ "name" = "WMI:Formatted-Credential-Type"; "value" = "8" },
                    @{ "name" = "WMI:Formatted-Counter-Username"; "value" = "" },
                    @{ "name" = "WMI:Formatted-Counter-Password"; "value" = "" },
                    @{ "name" = "WMI:Formatted-Counter-ComputerName"; "value" = $WMIFormattedComputerName },
                    @{ "name" = "WMI:Formatted-Counter-PropertyName"; "value" = $WMIFormattedPropertyName },
                    @{ "name" = "WMI:Formatted-Range-LowValue"; "value" = $RangeLowValue },
                    @{ "name" = "WMI:Formatted-Range-HighValue"; "value" = $RangeHighValue },
                    @{ "name" = "WMI:Formatted-Rescan-Usage"; "value" = "0" },
                    @{ "name" = "WMI:Formatted-Counter-CheckType"; "value" = $CheckTypeValue },
                    @{ "name" = "WMI:Formatted-Constant-Value"; "value" = $ConstantValue },
                    @{ "name" = "WMI:Formatted-Constant-UpIfMatchValue"; "value" = $ConstantUpIfMatchValue },
                    @{ "name" = "WMI:Formatted-ROC-Value"; "value" = $ROCValue },
                    @{ "name" = "WMI:Formatted-ROC-UpIfAboveValue"; "value" = $ROCUpIfAboveValue }
                )
            }

            'SNMPTable' {
                $ClassId = 'f14ef52e-b9da-4a2f-b48f-56c96a004cf2'

                $discCheckType = switch ($SnmpTableDiscOperator) {
                    'equals' { "0" }
                    'range' { "1" }
                    'rateofchange' { "2" }
                    'gt' { "3" }
                    'lt' { "4" }
                    'oneof' { "5" }
                    'contains' { "6" }
                    default { "0" }
                }

                $monitorCheckType = switch ($SnmpTableMonitorOperator) {
                    'constant' { "0" }
                    'range' { "1" }
                    'rateofchange' { "2" }
                    'gt' { "3" }
                    'lt' { "4" }
                    'oneof' { "5" }
                    'contains' { "6" }
                    default { "0" }
                }

                $discCreatesValue = if ($SnmpTableDiscCreates -eq 'true') { "1" } else { "0" }
                $monitorUpIfMatch = if ($SnmpTableMonitorUpIfMatch -eq 'upifmatch') { "1" } else { "0" }

                $PropertyBags = @(
                    @{ "name" = "SNMP:Table-DiscOID"; "value" = "$SnmpTableDiscOID" },
                    @{ "name" = "SNMP:Table-CheckType"; "value" = $discCheckType },
                    @{ "name" = "SNMP:Table-Constant-Value"; "value" = "$SnmpTableDiscValue" },
                    @{ "name" = "SNMP:Table-Range-LowValue"; "value" = "$SnmpTableDiscRangeLow" },
                    @{ "name" = "SNMP:Table-Range-HighValue"; "value" = "$SnmpTableDiscRangeHigh" },
                    @{ "name" = "SNMP:Table-CommentOID"; "value" = "$SnmpTableDiscCommentOID" },
                    @{ "name" = "SNMP:Table-IndexOID"; "value" = "$SnmpTableDiscIndexOID" },
                    @{ "name" = "SNMP:Table-Match-Creates"; "value" = $discCreatesValue },
                    @{ "name" = "SNMP:OID"; "value" = "$SnmpTableMonitoredOID" },
                    @{ "name" = "SNMP:CheckType"; "value" = $monitorCheckType },
                    @{ "name" = "SNMP:Constant-Value"; "value" = "$SnmpTableMonitoredValue" },
                    @{ "name" = "SNMP:Range-LowValue"; "value" = "$SnmpTableMonitorRangeLow" },
                    @{ "name" = "SNMP:Range-HighValue"; "value" = "$SnmpTableMonitorRangeHigh" },
                    @{ "name" = "SNMP:Constant-UpIfMatchValue"; "value" = $monitorUpIfMatch },
                    @{ "name" = "Cred:Type"; "value" = "1,2,4" },
                    @{ "name" = "SNMP:Retries"; "value" = "$Retries" },
                    @{ "name" = "SNMP:Timeout"; "value" = "$Timeout" }
                )
            }


        }

    }

            process {
                if ($skipCreation) {
                    Write-Host "Skipping monitor creation." -ForegroundColor Yellow
                    return
                }

                Write-Verbose "Creating monitor: $Name"
                $payload = @{
                    "allowSystemMonitorCreation" = $true
                    "name"                       = $Name
                    "description"                = "$Type Monitor created via Add-WUGActiveMonitor function"
                    "monitorTypeInfo"            = @{
                        "baseType" = "active"
                        "classId"  = $ClassId
                    }
                    "propertyBags"               = $PropertyBags
                    "useInDiscovery"             = $UseInDiscovery
                }

                $jsonPayload = $payload | ConvertTo-Json -Compress
                Write-Verbose "Posting payload: $jsonPayload"

                if (-not $PSCmdlet.ShouldProcess("$Type monitor '$Name'", 'Create active monitor')) { return }

                try {
                    $result = Get-WUGAPIResponse -Uri $baseUri -Method POST -Body $jsonPayload
                
                    if ($result.data.successful -eq 1) {
                        Write-Information "Successfully created $Type monitor: $Name"
                        
                        # Check if an ID or other helpful data was returned
                        if ($result.data.idMap) {
                            Write-Debug "New Monitor ID: $($result.data.idMap.resultId)"
                            Write-Output $result.data.idMap.resultId
                        }
                    }
                    else {
                        Write-Warning "Failed to create monitor template."
                        Write-Debug "Full result data: $(ConvertTo-Json $result -Depth 10)"
                    }
                }
                catch {
                    Write-Error "Error creating monitor template: $($_.Exception.Message)"
                    Write-Debug "Full exception: $($_.Exception | Format-List * | Out-String)"
                }
                
            }
        

            end {
                Write-Debug "Add-WUGActiveMonitor function completed."
            }
        }
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBj/ILSR4t0LK29
# 1oi5fXzlCK9X/vEhzqc0kKrEma3xSKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg8KqnvlClaFOlMJmWPARzbqkQYfhOdjwB
# k8MGS5pMxPEwDQYJKoZIhvcNAQEBBQAEggIAJzfagkJAjaCd+sgVeeKZOiozg0Ma
# eqbSSxnffY3zlvlT394wgeRjvfrcP2vHNFB5Cebf2eFhHVa8m4a4rnY03cZg1kr5
# kC4iH/qDvLOVztLA1C/vKSQWt/VMomwTINB9jSM0iZC6cj6A/78XaTv6ZmwjxEHA
# WinkZoWkDqE5idYjATwox+usKrS/G7rbPH4Swmi/QE5h6cr9LZWEdulhC+qwwHP6
# UTs5AsrZ0m417SdpsAQNeDN/lzj8qjQHJvbvIWhW9oiiE1/cdtrPIBGkFnNjK8bp
# x/vuBVbuNuv+LkXpTnY2CF+1xkvyYiuSOZUgIuGRZWUC15vZvE0woZ/BW01uK0tV
# nmbRG/jeDnzqQA4I/tMZ+SVlI287PO44dF7nXOWR06Mq0ESWXw1gSeetSXZi+8KV
# O57KHRQv44W4hbo/tPiE/O63cys248AL7JHKN0HHFky/fIY+S+YGwLwusGp8g0fv
# oUgEYSAbW0ZcFgfORrOmEty2AJfd7UQT30mHBeh6cGUVnVkH7PVwMkeu2rRDBtFR
# jE3wlU1W5h9jjCU9IN+taCw0Xg4weZnpC0WDItGBMf/meKVMoM184J19XtLnKDOY
# IiDp42GAZb0cxG+HzFPFSClDz3WJFfU6bqV0mQfuteoTB+hodqFXyX3I0Ao1n4/f
# /V5Bt91gpH055yc=
# SIG # End signature block
