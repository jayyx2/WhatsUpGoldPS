<#
.SYNOPSIS
    Adds an active monitor to WhatsUp Gold (WUG) for various monitoring types including SNMP, SNMP Table, Ping, TCP/IP, Certificate, WMI, and more.

.DESCRIPTION
    This function allows the user to create different types of active monitors in WhatsUp Gold (WUG) by specifying the type of monitor and its relevant parameters.
    It supports various monitoring types such as Ping, TCP/IP, SNMP, Process, Certificate, Service, and WMIFormatted.
    The function handles the creation of the monitor by checking if it already exists and then making the appropriate API call to create the monitor with the specified settings.

.PARAMETER Type
    The type of the monitor to be created. This parameter is mandatory and determines the set of additional parameters required.
    Supported types: Ping, TcpIp, SNMP, SNMPTable, Process, Certificate, Service, WMIFormatted,
    Dns, FileContent, FileProperties, Folder, Ftp, HttpContent, NetworkStatistics, PingJitter, PowerShell, RestApi, Ssh.

.PARAMETER DnsDomain
    The domain name to resolve. Required for the Dns monitor type.

.PARAMETER DnsRecordType
    The DNS record type to query. Valid values: ptr, a, ns, cname, soa, mx, txt, aaaa. Default is 'a'. Specific to the 'Dns' parameter set.

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

.EXAMPLE
    Add-WUGActiveMonitor -Type Dns -Name "DNS A-Record Check" -DnsDomain 'example.com' -DnsRecordType a

Description
-----------
    Creates a DNS active monitor that resolves example.com with an A-record lookup.

.EXAMPLE
    Add-WUGActiveMonitor -Type HttpContent -Name "Homepage Health" -HttpContentUrl 'https://intranet.corp.local' -HttpContentContent 'Welcome'

Description
-----------
    Creates an HTTP Content monitor that checks https://intranet.corp.local for the text "Welcome".

.EXAMPLE
    Add-WUGActiveMonitor -Type Ssh -Name "Disk Check via SSH" -SshCommand 'df -h /' -SshExpectedOutput '/dev/sda1'

Description
-----------
    Creates an SSH active monitor that runs 'df -h /' and expects '/dev/sda1' in the output.

.EXAMPLE
    Add-WUGActiveMonitor -Type PowerShell -Name "PS Script Monitor" -PowerShellScriptText 'if (Test-Connection 8.8.8.8 -Count 1 -Quiet) { $context.SetResult(0, "OK") } else { $context.SetResult(1, "Fail") }'

Description
-----------
    Creates a PowerShell script active monitor that pings 8.8.8.8.

.EXAMPLE
    Add-WUGActiveMonitor -Type RestApi -Name "API Health Check" -RestApiUrl 'https://api.example.com/health'

Description
-----------
    Creates a REST API active monitor that GETs the specified health endpoint.
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
        [Parameter(Mandatory = $true, ParameterSetName = 'Dns')]
        [Parameter(Mandatory = $true, ParameterSetName = 'FileContent')]
        [Parameter(Mandatory = $true, ParameterSetName = 'FileProperties')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Folder')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Ftp')]
        [Parameter(Mandatory = $true, ParameterSetName = 'HttpContent')]
        [Parameter(Mandatory = $true, ParameterSetName = 'NetworkStatistics')]
        [Parameter(Mandatory = $true, ParameterSetName = 'PingJitter')]
        [Parameter(Mandatory = $true, ParameterSetName = 'PowerShell')]
        [Parameter(Mandatory = $true, ParameterSetName = 'RestApi')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
        [ValidateSet('Ping', 'TcpIp', 'SNMP', 'SNMPTable', 'Process', 'Certificate', 'Service', 'WMIFormatted',
                     'Dns', 'FileContent', 'FileProperties', 'Folder', 'Ftp', 'HttpContent',
                     'NetworkStatistics', 'PingJitter', 'PowerShell', 'RestApi', 'Ssh')]
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
        [string]$SnmpTableMonitorUpIfMatch = 'upifmatch',

        # DNS Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'Dns')]
        [string]$DnsDomain,
        [Parameter(ParameterSetName = 'Dns')]
        [ValidateSet('ptr', 'a', 'ns', 'cname', 'soa', 'mx', 'txt', 'aaaa')]
        [string]$DnsRecordType = 'a',
        [Parameter(ParameterSetName = 'Dns')]
        [string]$DnsServer = '',
        [Parameter(ParameterSetName = 'Dns')]
        [string]$DnsTimeout = '2',
        [Parameter(ParameterSetName = 'Dns')]
        [string]$DnsValidation = 'name',

        # FileContent Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'FileContent')]
        [string]$FileContentFolderPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'FileContent')]
        [string]$FileContentPattern,
        [Parameter(ParameterSetName = 'FileContent')]
        [string]$FileContentResultState = 'up',
        [Parameter(ParameterSetName = 'FileContent')]
        [string]$FileContentFileFilter = '',
        [Parameter(ParameterSetName = 'FileContent')]
        [string]$FileContentFilterType = 'wildcard',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentIncludeAllFiles = 'False',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentIncludeFilteredFiles = 'True',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentCheckSubFolders = 'False',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentLiteralPattern = 'True',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentCaseSensitive = 'False',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentScanEntireFile = 'True',
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentScanOnlyNew = 'False',
        [Parameter(ParameterSetName = 'FileContent')]
        [int]$FileContentOccurrences = 1,
        [Parameter(ParameterSetName = 'FileContent')]
        [ValidateSet("True", "False")][string]$FileContentIgnoreTimeout = 'False',
        [Parameter(ParameterSetName = 'FileContent')]
        [int]$FileContentTimeout = 3,

        # FileProperties Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesPath,
        [Parameter(ParameterSetName = 'FileProperties')]
        [ValidateSet("True", "False")][string]$FilePropertiesFailIfExists = 'True',
        [Parameter(ParameterSetName = 'FileProperties')]
        [ValidateSet("True", "False")][string]$FilePropertiesCheckSize = 'False',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesSizeOperator = 'less than',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesSizeThreshold = '0',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesSizeUnit = 'bytes',
        [Parameter(ParameterSetName = 'FileProperties')]
        [ValidateSet("True", "False")][string]$FilePropertiesCheckModDate = 'False',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesModDateOperator = 'exactly on',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesModDateThreshold = '',
        [Parameter(ParameterSetName = 'FileProperties')]
        [ValidateSet("True", "False")][string]$FilePropertiesCheckRelModDate = 'False',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesRelModDateQuantity = '1',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesRelModDateUnit = '0',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesModStateIndicator = '0',
        [Parameter(ParameterSetName = 'FileProperties')]
        [ValidateSet("True", "False")][string]$FilePropertiesCheckChecksum = 'False',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesChecksumAlgorithm = 'SHA1',
        [Parameter(ParameterSetName = 'FileProperties')]
        [string]$FilePropertiesChecksumThreshold = '',

        # Folder Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'Folder')]
        [string]$FolderPath,
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderFailIfExists = 'False',
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderCheckSubFolders = 'True',
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderIncludeAllFiles = 'True',
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderIncludeFilteredFiles = 'False',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderFileFilter = '',
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderCheckActualSize = 'True',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderActualSizeOperator = 'less than',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderActualSizeThreshold = '0',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderActualSizeUnit = 'bytes',
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderCheckSizeOnDisk = 'True',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderSizeOnDiskOperator = 'less than',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderSizeOnDiskThreshold = '0',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderSizeOnDiskUnit = 'bytes',
        [Parameter(ParameterSetName = 'Folder')]
        [ValidateSet("True", "False")][string]$FolderCheckFileCount = 'True',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderFileCountOperator = 'less than',
        [Parameter(ParameterSetName = 'Folder')]
        [string]$FolderFileCountThreshold = '0',

        # Ftp Monitor Parameters
        [Parameter(ParameterSetName = 'Ftp')]
        [string]$FtpServer = '%Device.Address',
        [Parameter(ParameterSetName = 'Ftp')]
        [int]$FtpPort = 21,
        [Parameter(Mandatory = $true, ParameterSetName = 'Ftp')]
        [string]$FtpUsername,
        [Parameter(Mandatory = $true, ParameterSetName = 'Ftp')]
        [string]$FtpPassword,
        [Parameter(ParameterSetName = 'Ftp')]
        [ValidateSet("True", "False")][string]$FtpPassiveMode = 'True',
        [Parameter(ParameterSetName = 'Ftp')]
        [int]$FtpTimeout = 3,
        [Parameter(ParameterSetName = 'Ftp')]
        [ValidateSet("True", "False")][string]$FtpTestUpload = 'True',
        [Parameter(ParameterSetName = 'Ftp')]
        [ValidateSet("True", "False")][string]$FtpTestDownload = 'True',
        [Parameter(ParameterSetName = 'Ftp')]
        [ValidateSet("True", "False")][string]$FtpTestDelete = 'True',

        # HttpContent Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'HttpContent')]
        [string]$HttpContentUrl,
        [Parameter(ParameterSetName = 'HttpContent')]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'HEAD')]
        [string]$HttpContentMethod = 'GET',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentContent = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [ValidateSet("True", "False")][string]$HttpContentUseRegex = 'False',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentStateIfNotFound = 'Up',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentAuthMechanism = 'None',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentUsername = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentPassword = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [ValidateSet("True", "False")][string]$HttpContentIgnoreCertErrors = 'False',
        [Parameter(ParameterSetName = 'HttpContent')]
        [int]$HttpContentTimeoutMs = 10000,
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentProxyServer = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [int]$HttpContentProxyPort = 80,
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentCustomHeader = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentCustomHeader2 = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentCustomHeader3 = '',
        [Parameter(ParameterSetName = 'HttpContent')]
        [string]$HttpContentUserAgent = 'Mozilla/5.0 (compatible; MSIE 10.6; Windows NT 6.1; Trident/5.0; InfoPath.2; SLCC1; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30729; .NET CLR 2.0.50727) 3gpp-gba UNTRUSTED/1.0',

        # NetworkStatistics Monitor Parameters
        [Parameter(ParameterSetName = 'NetworkStatistics')]
        [int]$NetStatSnmpRetries = 1,
        [Parameter(ParameterSetName = 'NetworkStatistics')]
        [int]$NetStatSnmpTimeoutMs = 3000,

        # PingJitter Monitor Parameters
        [Parameter(ParameterSetName = 'PingJitter')]
        [string]$PingJitterHostAddress = '%Device.Address',
        [Parameter(ParameterSetName = 'PingJitter')]
        [ValidateSet("True", "False")][string]$PingJitterCheckJitter = 'True',
        [Parameter(ParameterSetName = 'PingJitter')]
        [int]$PingJitterThresholdMs = 50,
        [Parameter(ParameterSetName = 'PingJitter')]
        [ValidateSet("True", "False")][string]$PingJitterCheckIAJitter = 'True',
        [Parameter(ParameterSetName = 'PingJitter')]
        [int]$PingJitterIAThresholdMs = 50,
        [Parameter(ParameterSetName = 'PingJitter')]
        [ValidateSet("True", "False")][string]$PingJitterIgnoreConnError = 'False',
        [Parameter(ParameterSetName = 'PingJitter')]
        [int]$PingJitterPayloadSize = 32,
        [Parameter(ParameterSetName = 'PingJitter')]
        [int]$PingJitterRetries = 1,
        [Parameter(ParameterSetName = 'PingJitter')]
        [int]$PingJitterTimeoutSec = 1,
        [Parameter(ParameterSetName = 'PingJitter')]
        [int]$PingJitterTTL = 128,

        # PowerShell Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'PowerShell')]
        [string]$PowerShellScriptText,
        [Parameter(ParameterSetName = 'PowerShell')]
        [int]$PowerShellScriptTimeout = 60,

        # RestApi Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'RestApi')]
        [string]$RestApiUrl,
        [Parameter(ParameterSetName = 'RestApi')]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [Alias('RestApiHttpMethod')]
        [string]$RestApiMethod = 'GET',
        [Parameter(ParameterSetName = 'RestApi')]
        [Alias('RestApiHttpTimeoutMs')]
        [int]$RestApiTimeoutMs = 10000,
        [Parameter(ParameterSetName = 'RestApi')]
        [ValidateSet('0', '1')][string]$RestApiIgnoreCertErrors = '0',
        [Parameter(ParameterSetName = 'RestApi')]
        [ValidateSet('0', '1')]
        [Alias('RestApiUseAnonymousAccess')]
        [string]$RestApiUseAnonymous = '0',
        [Parameter(ParameterSetName = 'RestApi')]
        [string]$RestApiCustomHeader = '',
        [Parameter(ParameterSetName = 'RestApi')]
        [string]$RestApiDownIfResponseCodeIsIn = '[]',
        [Parameter(ParameterSetName = 'RestApi')]
        [string]$RestApiComparisonList = '[]',

        # Ssh Monitor Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
        [string]$SshCommand,
        [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
        [string]$SshExpectedOutput,
        [Parameter(ParameterSetName = 'Ssh')]
        [ValidateSet('1', '0')][string]$SshContains = '1',
        [Parameter(ParameterSetName = 'Ssh')]
        [ValidateSet("True", "False")][string]$SshUseRegex = 'False',
        [Parameter(ParameterSetName = 'Ssh')]
        [ValidateSet('None', 'Linefeed', 'Carriage return', 'Carriage return linefeed')][string]$SshEOLChars = 'None',
        [Parameter(ParameterSetName = 'Ssh')]
        [int]$SshCredentialID = -1
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
                Write-Warning "Monitor with the name '$Name' already exists. Skipping creation."
                $skipCreation = $true
                return
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Verbose "No existing monitor found with the name '$Name'. Proceeding with creation."
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

                # Discovery Value Types: 0=IsOneOf, 1=Range, 2=LessThan, 3=GreaterThan, 4=ContainsOneOf
                $discCheckType = switch ($SnmpTableDiscOperator) {
                    'equals'   { "0" }
                    'oneof'    { "0" }
                    'range'    { "1" }
                    'lt'       { "2" }
                    'gt'       { "3" }
                    'contains' { "4" }
                    default    { "0" }
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

            'Dns' {
                $ClassId = 'b5b564ee-08a9-4126-8653-89d82e52b3fc'
                $PropertyBags = @(
                    @{ "name" = "Domain"; "value" = "$DnsDomain" },
                    @{ "name" = "Type"; "value" = "$DnsRecordType" },
                    @{ "name" = "Server"; "value" = "$DnsServer" },
                    @{ "name" = "Timeout"; "value" = "$DnsTimeout" },
                    @{ "name" = "Validation"; "value" = "$DnsValidation" }
                )
            }

            'FileContent' {
                $ClassId = '61fcda9a-b08d-4556-8f68-b05313eff04b'
                $PropertyBags = @(
                    @{ "name" = "MonFileContent:FolderPath"; "value" = "$FileContentFolderPath" },
                    @{ "name" = "MonFileContent:PatternToScan"; "value" = "$FileContentPattern" },
                    @{ "name" = "MonFileContent:ResultingMonitorState"; "value" = "$FileContentResultState" },
                    @{ "name" = "MonFileContent:FileFilter"; "value" = "$FileContentFileFilter" },
                    @{ "name" = "MonFileContent:FileFilterType"; "value" = "$FileContentFilterType" },
                    @{ "name" = "MonFileContent:IncludeAllFiles"; "value" = "$FileContentIncludeAllFiles" },
                    @{ "name" = "MonFileContent:IncludeFilteredFiles"; "value" = "$FileContentIncludeFilteredFiles" },
                    @{ "name" = "MonFileContent:CheckSubFolders"; "value" = "$FileContentCheckSubFolders" },
                    @{ "name" = "MonFileContent:PatternIsLiteral"; "value" = "$FileContentLiteralPattern" },
                    @{ "name" = "MonFileContent:CaseSensitiveComparison"; "value" = "$FileContentCaseSensitive" },
                    @{ "name" = "MonFileContent:ScanEntireFile"; "value" = "$FileContentScanEntireFile" },
                    @{ "name" = "MonFileContent:ScanOnlyNewContent"; "value" = "$FileContentScanOnlyNew" },
                    @{ "name" = "MonFileContent:NumOccurences"; "value" = "$FileContentOccurrences" },
                    @{ "name" = "MonFileContent:IgnoreTimeoutError"; "value" = "$FileContentIgnoreTimeout" },
                    @{ "name" = "MonFileContent:TimeOut"; "value" = "$FileContentTimeout" },
                    @{ "name" = "Cred:Type"; "value" = "8" }
                )
            }

            'FileProperties' {
                $ClassId = '75e3521f-bc87-4f96-8dd0-d2e888d04d86'
                $PropertyBags = @(
                    @{ "name" = "MonFileProperties:FilePath"; "value" = "$FilePropertiesPath" },
                    @{ "name" = "MonFileProperties:FailIfFileExists"; "value" = "$FilePropertiesFailIfExists" },
                    @{ "name" = "MonFileProperties:CheckFileSize"; "value" = "$FilePropertiesCheckSize" },
                    @{ "name" = "MonFileProperties:FileSizeOperator"; "value" = "$FilePropertiesSizeOperator" },
                    @{ "name" = "MonFileProperties:FileSizeThreshold"; "value" = "$FilePropertiesSizeThreshold" },
                    @{ "name" = "MonFileProperties:FileSizeUnit"; "value" = "$FilePropertiesSizeUnit" },
                    @{ "name" = "MonFileProperties:CheckLastModifiedDate"; "value" = "$FilePropertiesCheckModDate" },
                    @{ "name" = "MonFileProperties:LastModifiedDateOperator"; "value" = "$FilePropertiesModDateOperator" },
                    @{ "name" = "MonFileProperties:LastModifiedDateThreshold"; "value" = "$FilePropertiesModDateThreshold" },
                    @{ "name" = "MonFileProperties:CheckLastRelativeModifiedDate"; "value" = "$FilePropertiesCheckRelModDate" },
                    @{ "name" = "MonFileProperties:LastRelativeModifiedDateTimeQuantity"; "value" = "$FilePropertiesRelModDateQuantity" },
                    @{ "name" = "MonFileProperties:LastRelativeModifiedDateTimeUnit"; "value" = "$FilePropertiesRelModDateUnit" },
                    @{ "name" = "MonFileProperties:FileModificationStateIndicator"; "value" = "$FilePropertiesModStateIndicator" },
                    @{ "name" = "MonFileProperties:CheckFileChecksum"; "value" = "$FilePropertiesCheckChecksum" },
                    @{ "name" = "MonFileProperties:ChecksumAlgorithm"; "value" = "$FilePropertiesChecksumAlgorithm" },
                    @{ "name" = "MonFileProperties:ChecksumThreshold"; "value" = "$FilePropertiesChecksumThreshold" },
                    @{ "name" = "Cred:Type"; "value" = "8" }
                )
            }

            'Folder' {
                $ClassId = '2dd54720-7579-4d76-bad0-e9d9f34c916d'
                $PropertyBags = @(
                    @{ "name" = "MonFolder:FolderPath"; "value" = "$FolderPath" },
                    @{ "name" = "MonFolder:FailIfFolderExists"; "value" = "$FolderFailIfExists" },
                    @{ "name" = "MonFolder:CheckSubFolders"; "value" = "$FolderCheckSubFolders" },
                    @{ "name" = "MonFolder:IncludeAllFiles"; "value" = "$FolderIncludeAllFiles" },
                    @{ "name" = "MonFolder:IncludeFilteredFiles"; "value" = "$FolderIncludeFilteredFiles" },
                    @{ "name" = "MonFolder:FileFilter"; "value" = "$FolderFileFilter" },
                    @{ "name" = "MonFolder:CheckActualFolderSize"; "value" = "$FolderCheckActualSize" },
                    @{ "name" = "MonFolder:ActualFolderSizeOperator"; "value" = "$FolderActualSizeOperator" },
                    @{ "name" = "MonFolder:ActualFolderSizeThreshold"; "value" = "$FolderActualSizeThreshold" },
                    @{ "name" = "MonFolder:ActualFolderSizeUnit"; "value" = "$FolderActualSizeUnit" },
                    @{ "name" = "MonFolder:CheckFolderSizeOnDisk"; "value" = "$FolderCheckSizeOnDisk" },
                    @{ "name" = "MonFolder:FolderSizeOnDiskOperator"; "value" = "$FolderSizeOnDiskOperator" },
                    @{ "name" = "MonFolder:FolderSizeOnDiskThreshold"; "value" = "$FolderSizeOnDiskThreshold" },
                    @{ "name" = "MonFolder:FolderSizeOnDiskUnit"; "value" = "$FolderSizeOnDiskUnit" },
                    @{ "name" = "MonFolder:CheckFileCount"; "value" = "$FolderCheckFileCount" },
                    @{ "name" = "MonFolder:FileCountOperator"; "value" = "$FolderFileCountOperator" },
                    @{ "name" = "MonFolder:FileCountThreshold"; "value" = "$FolderFileCountThreshold" },
                    @{ "name" = "Cred:Type"; "value" = "8" }
                )
            }

            'Ftp' {
                $ClassId = '7e796b86-ba62-4c32-9ff8-6750677115f9'
                $timeoutMs = $FtpTimeout * 1000
                $PropertyBags = @(
                    @{ "name" = "MonFTP:ServerName"; "value" = "$FtpServer" },
                    @{ "name" = "MonFTP:Port"; "value" = "$FtpPort" },
                    @{ "name" = "MonFTP:Username"; "value" = "$FtpUsername" },
                    @{ "name" = "MonFTP:Password"; "value" = "$FtpPassword" },
                    @{ "name" = "MonFTP:UsePASV"; "value" = "$FtpPassiveMode" },
                    @{ "name" = "MonFTP:TimeoutMs"; "value" = "$timeoutMs" },
                    @{ "name" = "MonFTP:Upload"; "value" = "$FtpTestUpload" },
                    @{ "name" = "MonFTP:Download"; "value" = "$FtpTestDownload" },
                    @{ "name" = "MonFTP:Delete"; "value" = "$FtpTestDelete" }
                )
            }

            'HttpContent' {
                $ClassId = '7536f6bc-a6c1-4c67-af3e-4d10599e3d4d'
                $PropertyBags = @(
                    @{ "name" = "MonHTTP:URL"; "value" = "$HttpContentUrl" },
                    @{ "name" = "MonHTTP:Method"; "value" = "$HttpContentMethod" },
                    @{ "name" = "MonHTTP:Content"; "value" = "$HttpContentContent" },
                    @{ "name" = "MonHTTP:UseRegularExpression"; "value" = "$HttpContentUseRegex" },
                    @{ "name" = "MonHTTP:MonitorStateIfContentNotFound"; "value" = "$HttpContentStateIfNotFound" },
                    @{ "name" = "MonHTTP:AuthMechanism"; "value" = "$HttpContentAuthMechanism" },
                    @{ "name" = "MonHTTP:Username"; "value" = "$HttpContentUsername" },
                    @{ "name" = "MonHTTP:Password"; "value" = "$HttpContentPassword" },
                    @{ "name" = "MonHTTP:IgnoreCertErrors"; "value" = "$HttpContentIgnoreCertErrors" },
                    @{ "name" = "MonHTTP:TimeoutMs"; "value" = "$HttpContentTimeoutMs" },
                    @{ "name" = "MonHTTP:ProxyServer"; "value" = "$HttpContentProxyServer" },
                    @{ "name" = "MonHTTP:ProxyPort"; "value" = "$HttpContentProxyPort" },
                    @{ "name" = "MonHTTP:CustomHeader"; "value" = "$HttpContentCustomHeader" },
                    @{ "name" = "MonHTTP:CustomHeader2"; "value" = "$HttpContentCustomHeader2" },
                    @{ "name" = "MonHTTP:CustomHeader3"; "value" = "$HttpContentCustomHeader3" },
                    @{ "name" = "MonHTTP:UserAgent"; "value" = "$HttpContentUserAgent" }
                )
            }

            'NetworkStatistics' {
                $ClassId = '24c8fa8a-437e-4e3b-9b92-054592a3c3c9'
                $netStatThresholdsXml = @'
<?xml version="1.0" encoding="utf-16"?>
<StatisticalThresholds xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Thresholds>
    <NetstatThreshold><Name>IP received</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.4.3</OID><Type>Counter</Type><NetStatType>IP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>IP receive errors</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.4.5</OID><Type>Counter</Type><NetStatType>IP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>IP received discarded</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.4.8</OID><Type>Counter</Type><NetStatType>IP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>IP deliveries</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.4.9</OID><Type>Counter</Type><NetStatType>IP</NetStatType><Checked>true</Checked></NetstatThreshold>
    <NetstatThreshold><Name>IP requests</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.4.10</OID><Type>Counter</Type><NetStatType>IP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>IP transmits discarded</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.4.11</OID><Type>Counter</Type><NetStatType>IP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>TCP connect failures</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.6.7</OID><Type>Counter</Type><NetStatType>TCP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>TCP established</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.6.9</OID><Type>Gauge</Type><NetStatType>TCP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>TCP received Segments</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.6.10</OID><Type>Counter</Type><NetStatType>TCP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>TCP transmitted Segments</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.6.11</OID><Type>Counter</Type><NetStatType>TCP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>UDP deliveries</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.7.1</OID><Type>Counter</Type><NetStatType>UDP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>UDP no ports</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.7.2</OID><Type>Counter</Type><NetStatType>UDP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>UDP errors</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.7.3</OID><Type>Counter</Type><NetStatType>UDP</NetStatType><Checked>false</Checked></NetstatThreshold>
    <NetstatThreshold><Name>UDP transmitted</Name><Threshold>0</Threshold><OID>1.3.6.1.2.1.7.4</OID><Type>Counter</Type><NetStatType>UDP</NetStatType><Checked>false</Checked></NetstatThreshold>
  </Thresholds>
</StatisticalThresholds>
'@
                $PropertyBags = @(
                    @{ "name" = "MonNetstat:Thresholds"; "value" = $netStatThresholdsXml },
                    @{ "name" = "MonNetstat:SnmpNumRetries"; "value" = "$NetStatSnmpRetries" },
                    @{ "name" = "MonNetstat:SnmpTimeoutMs"; "value" = "$NetStatSnmpTimeoutMs" },
                    @{ "name" = "Cred:Type"; "value" = "1,2,4" }
                )
            }

            'PingJitter' {
                $ClassId = '5e8a926e-05f6-492c-b997-2d9bce068a5c'
                $PropertyBags = @(
                    @{ "name" = "MonPingIAJitter:HostAddress"; "value" = "$PingJitterHostAddress" },
                    @{ "name" = "MonPingIAJitter:CheckJitterThreshold"; "value" = "$PingJitterCheckJitter" },
                    @{ "name" = "MonPingIAJitter:JitterThresholdMSec"; "value" = "$PingJitterThresholdMs" },
                    @{ "name" = "MonPingIAJitter:CheckIAJitterThreshold"; "value" = "$PingJitterCheckIAJitter" },
                    @{ "name" = "MonPingIAJitter:IAJitterThresholdMSec"; "value" = "$PingJitterIAThresholdMs" },
                    @{ "name" = "MonPingIAJitter:IgnoreConnectionError"; "value" = "$PingJitterIgnoreConnError" },
                    @{ "name" = "MonPingIAJitter:PayloadSize"; "value" = "$PingJitterPayloadSize" },
                    @{ "name" = "MonPingIAJitter:Retries"; "value" = "$PingJitterRetries" },
                    @{ "name" = "MonPingIAJitter:TimeoutSec"; "value" = "$PingJitterTimeoutSec" },
                    @{ "name" = "MonPingIAJitter:TTL"; "value" = "$PingJitterTTL" }
                )
            }

            'PowerShell' {
                $ClassId = 'e4378c13-ba30-43bf-a3aa-8e25d5c8dd87'
                $PropertyBags = @(
                    @{ "name" = "PowerShell:ScriptType"; "value" = "2" },
                    @{ "name" = "PowerShell:ScriptTimeout"; "value" = "$PowerShellScriptTimeout" },
                    @{ "name" = "PowerShell:ScriptImpersonateFlag"; "value" = "0" },
                    @{ "name" = "PowerShell:ScriptText"; "value" = "$PowerShellScriptText" },
                    @{ "name" = "Cred:Type"; "value" = "1,2,4,8,16,32,64,128,32768" }
                )
            }

            'RestApi' {
                $ClassId = 'f0610672-d515-4268-bd21-ac5ebb1476ff'
                $PropertyBags = @(
                    @{ "name" = "MonRestApi:RestUrl"; "value" = "$RestApiUrl" },
                    @{ "name" = "MonRestApi:HttpMethod"; "value" = "$RestApiMethod" },
                    @{ "name" = "MonRestApi:HttpTimeoutMs"; "value" = "$RestApiTimeoutMs" },
                    @{ "name" = "MonRestApi:IgnoreCertErrors"; "value" = "$RestApiIgnoreCertErrors" },
                    @{ "name" = "MonRestApi:UseAnonymousAccess"; "value" = "$RestApiUseAnonymous" },
                    @{ "name" = "MonRestApi:CustomHeader"; "value" = "$RestApiCustomHeader" },
                    @{ "name" = "MonRestApi:DownIfResponseCodeIsIn"; "value" = "$RestApiDownIfResponseCodeIsIn" },
                    @{ "name" = "MonRestApi:ComparisonList"; "value" = "$RestApiComparisonList" },
                    @{ "name" = "Cred:Type"; "value" = "8192" }
                )
            }

            'Ssh' {
                $ClassId = '02c4e1a2-6ff0-41d8-b1c6-b7d8f5aa5379'
                $PropertyBags = @(
                    @{ "name" = "MonSSH:Command"; "value" = "$SshCommand" },
                    @{ "name" = "MonSSH:Output"; "value" = "$SshExpectedOutput" },
                    @{ "name" = "MonSSH:Contains"; "value" = "$SshContains" },
                    @{ "name" = "MonSSH:Regex"; "value" = "$SshUseRegex" },
                    @{ "name" = "MonSSH:EOLChars"; "value" = "$SshEOLChars" },
                    @{ "name" = "MonSSH:CredentialID"; "value" = "$SshCredentialID" },
                    @{ "name" = "Cred:Type"; "value" = "64" }
                )
            }
        }

    }

            process {
                if ($skipCreation) {
                    Write-Warning "Skipping monitor creation."
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
                            return $result.data.idMap.resultId
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBjiM7GALZ01W9t
# IsVIwXRg94G6pKdH8Mb6egjDOL27k6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCHwuMyl4xmSVibq1lxfFEpsLkW0O8q3VP9pWCuq/fa5DANBgkqhkiG9w0BAQEF
# AASCAgBLF5w9G6JCM2+40+lSEIFejHq2SIRj0Opq8u9Nk0Exo2C7jDBMW4fnq0oH
# 6FE2Fa3oOLO+WSbmGNkVkNS+RzRnrolhKc1iZEMlg+rxk9VKe5Gi5o9tciRMtazN
# EpYY6gnh9/vAM05JYT5cOZMHz1zKdC7c5NGJs5Ap/X64Arrd+hGa4/X3Sb+pjNz2
# 2fZuPUtDJed4Zb89ws8lLZlSQUzdMXkAJ1zTW/KN4DYmqyXFnPFFtc4eU35MtNH1
# CxskaUj4PzDXBz3QETnJgUHHKrRnZGajho+OlZbFP0WxcjOVVW6be4rLDk652U/Y
# pUiRJm6qMYmLT4Yv5UVff/NuOYKxPksCrJHISUV2stYoXm4PEpI+lbFgxLoNwqo1
# zks/1Yc3P+aPTxZxtJ3aDka2mgNJxpMr872MmNz6DP1CxDNUxG2/ZJfeWpSrRHPm
# b09kTfLRv3jECCCF/7ylOZu14d+AP99l0Urrw8TbH7uDKi+362XBwJeb8yFXLCwc
# 70wyS8Z4vaPMkhPGoXJ5b+ufmbw0piMn6D5Wsv+n5eGEWO6LLygO/+fZAJ7dUF6l
# xnvoITrO0pgOBGjla5aYyYIItNRCuTyVvwlwlCIjdR1nONEH+NgI8vP/fCSpsaR3
# XtR2HNo2DLVuAp2FJWoPPUKWzh91JymNyTWx8CLdzX7dIegjq6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MDYxNjM4MThaMC8GCSqGSIb3DQEJBDEiBCBCM5ep
# ppxV6h3OoxlH+s3sfPyg6id4WSDIXapDW8CPTTANBgkqhkiG9w0BAQEFAASCAgB3
# kstvf6awXambqg5RZFSm+8B0TMpH93YIcIZPNYesCGcVBXL8pHMSJdv5mxIgvAtq
# yDYLTiIdGJyyCmQhYWKMbsogApRo57VjirhTZ8zE+DKhX/OzC46XObjRhRYja1PV
# 8IhNqtJK82YpF0XjBs4eL65ZK+n9X6oMVVZ385iWN3sgy4saWbtLkRaeIqXb3Nm1
# /W0bU9z0Zz6X98sFcZmbvTSrS3J0XhZkKiu0T6mWSQDjHpXcfN/SYgajiFGwOUDF
# vUDM7JP0Axqqed5NfqqeHMK8SXWY3RlUpIqFgT0gZBoCZ2hx4VbNQMIEDuVfxiHh
# RTfxUP2VWnd0GetHq7uXzKOLujK4XzUyXhlOcW8Y8QY3r02qc2MmimovBBfEKpcv
# KAwyqcQ8sd8rJR/kXdbTHUUoBFQfdFAf1AcJay59b4MXKOYsBn3A7paLQOZoWSrZ
# mgVA0AZ18e+3Rlp2m4sTUJWXI7epxyeBteFJWLkDps0D3+U0o4Rtcp3y87o2cdYZ
# KvErcTXr7MJVydF83SrN80nfYbTzEOXpZQyKBN/gwldn3pn0Kt3le0/IC31wP36b
# Omzr19+zi5eu+JTCdzz7G4eoDlY9yIUFHC+W6KlTJ0C/OL8U87duEcZs2f1j8p+1
# SMdeM2n0uerfzBCws3F13XyqXANFkgyMSHygjFWTTA==
# SIG # End signature block
