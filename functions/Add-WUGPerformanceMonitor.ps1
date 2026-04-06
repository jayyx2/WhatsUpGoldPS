# ============================================================
# API Endpoint Reference
# Source: WhatsUpGold 2024 REST API Spec v0.3
#
# 1. Create performance monitor in library:
#    POST /api/v1/monitors/-
#    Body schema: MonitorAdd
#      - name            (string, required)  Display name of monitor
#      - description     (string, optional)  Description of monitor
#      - monitorTypeInfo (object, required)  { baseType: "performance", classId: "<GUID>" }
#      - propertyBags    (array,  optional)  [ { name: string, value: string }, ... ]
#      - useInDiscovery  (bool,   optional)  Default false
#    Success response: Result[ApplyTemplateResults]
#      - data.successful = 1
#      - data.idMap.resultId = new monitor library ID
#
# 2. Assign monitor to device:
#    POST /api/v1/devices/{deviceId}/monitors/-
#    Body schema: SimpleAssignMonitor
#      - type              (string)  "performance"
#      - monitorTypeId     (string)  Library monitor ID from step 1
#      - enabled           (bool)    true/false
#      - isGlobal          (bool)    true
#      - performance       (object)  { pollingIntervalMinutes: int }
#    Success response: Result[ApplyTemplateResults]
#      - data.successful = 1
#
# 3. Remove monitor assignment from device:
#    DELETE /api/v1/devices/{deviceId}/monitors/{assignmentId}
#    (See Remove-WUGDeviceMonitor)
#
# 4. Remove monitor from library:
#    DELETE /api/v1/monitors/{monitorId}?type=performance
#    (See Remove-WUGActiveMonitor -Type performance)
# ============================================================
<#
.SYNOPSIS
    Creates a performance monitor in the WhatsUp Gold library, and optionally assigns it to a device.

.DESCRIPTION
    Add-WUGPerformanceMonitor creates a performance monitor of the specified type in the
    WhatsUp Gold monitor library. When DeviceId is provided, the monitor is also assigned
    to the target device. When DeviceId is omitted, the monitor is created in the library
    only. Each monitor type has its own parameter set with explicit named parameters for
    each property bag field. Required fields are mandatory parameters; optional fields
    have sensible defaults.

.PARAMETER DeviceId
    The ID of the device to assign the performance monitor to. When omitted, the monitor
    is created in the library only without device assignment. Accepts pipeline input
    by property name.

.PARAMETER Type
    The type of performance monitor to create. Valid values: RestApi, PowerShell, WmiRaw,
    WmiFormatted, WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch.

.PARAMETER Name
    Display name for the monitor in the WUG library. If omitted, a name is
    auto-generated from Type and DeviceId.

.PARAMETER PollingIntervalMinutes
    The polling interval in minutes for the performance monitor assignment. Default is 5.

.PARAMETER Enabled
    Whether the monitor assignment should be enabled. Default is 'true'.

.PARAMETER RestApiUrl
    (RestApi) URL to poll. Required.

.PARAMETER RestApiJsonPath
    (RestApi) JSONPath expression to extract the metric value. Required.

.PARAMETER RestApiHttpMethod
    (RestApi) HTTP method. Default is 'GET'.

.PARAMETER RestApiHttpTimeoutMs
    (RestApi) HTTP timeout in milliseconds. Default is 10000.

.PARAMETER RestApiIgnoreCertErrors
    (RestApi) Set to '1' to ignore SSL certificate errors. Default is '0'.

.PARAMETER RestApiUseAnonymousAccess
    (RestApi) Set to '0' to use device credentials. Default is '1'.

.PARAMETER RestApiCustomHeader
    (RestApi) Custom HTTP header (e.g. 'Accept:application/json'). Default is empty.

.PARAMETER ScriptText
    (PowerShell) PowerShell script text. Use $Context.SetValue() to report the metric. Required.

.PARAMETER ScriptType
    (PowerShell) Script type identifier. Default is '2'.

.PARAMETER ScriptTimeout
    (PowerShell) Script execution timeout in seconds. Default is 60.

.PARAMETER ScriptImpersonateFlag
    (PowerShell) Set to '1' to run under device credentials. Default is '1'.

.PARAMETER ScriptReferenceVariables
    (PowerShell) Reference variables. Default is empty.

.PARAMETER WmiRawRelativePath
    (WmiRaw) WMI class name (e.g. Win32_PerfRawData_PerfOS_Memory). Required.

.PARAMETER WmiRawPropertyName
    (WmiRaw) Property to collect (e.g. AvailableBytes). Required.

.PARAMETER WmiRawDisplayname
    (WmiRaw) Display name (e.g. 'Memory \\ Available Bytes'). Required.

.PARAMETER WmiRawInstanceName
    (WmiRaw) Instance filter. Default is empty.

.PARAMETER WmiRawTimeout
    (WmiRaw) WMI query timeout in seconds. Default is 5.

.PARAMETER WmiRawDeviceAddress
    (WmiRaw) Override target address. Default is empty.

.PARAMETER WmiFormattedRelativePath
    (WmiFormatted) WMI class name (e.g. Win32_PerfFormattedData_PerfOS_Memory). Required.

.PARAMETER WmiFormattedPropertyName
    (WmiFormatted) Property to collect. Required.

.PARAMETER WmiFormattedDisplayname
    (WmiFormatted) Display name. Required.

.PARAMETER WmiFormattedInstanceName
    (WmiFormatted) Instance filter. Default is empty.

.PARAMETER WmiFormattedTimeout
    (WmiFormatted) WMI query timeout in seconds. Default is 5.

.PARAMETER WmiFormattedDeviceAddress
    (WmiFormatted) Override target address. Default is empty.

.PARAMETER PerfCounterCategory
    (WindowsPerformanceCounter) Performance counter category (e.g. 'Processor'). Required.

.PARAMETER PerfCounterName
    (WindowsPerformanceCounter) Counter name (e.g. '% Processor Time'). Required.

.PARAMETER PerfCounterInstance
    (WindowsPerformanceCounter) Counter instance (e.g. '_Total'). Default is empty.

.PARAMETER PerfCounterSampleInterval
    (WindowsPerformanceCounter) Sample interval in milliseconds. Default is 1000.

.PARAMETER SshCommand
    (Ssh) SSH command to execute. Required.

.PARAMETER SshCommandType
    (Ssh) Command type. Default is 'SingleCommand'.

.PARAMETER SshUseCustomRegex
    (Ssh) Set to '1' to enable custom regex extraction. Default is '0'.

.PARAMETER SshCustomRegexValue
    (Ssh) Regex pattern for value extraction. Default is 'Result=([0-9.,]+)'.

.PARAMETER SshEOLChars
    (Ssh) End-of-line characters. Default is 'None'.

.PARAMETER SshCredentialID
    (Ssh) Credential ID. -1 for device default. Default is '-1'.

.PARAMETER SnmpOID
    (Snmp) SNMP OID to poll. Required.

.PARAMETER SnmpInstance
    (Snmp) SNMP instance. Default is '0'.

.PARAMETER SnmpUseRawValues
    (Snmp) '1' for raw values, '0' for cooked. Default is '1'.

.PARAMETER SnmpRetries
    (Snmp) Number of retries. Default is 1.

.PARAMETER SnmpTimeout
    (Snmp) Timeout in seconds. Default is 3.

.PARAMETER AzureResourceId
    (AzureMetrics) Full Azure resource ID. Required.

.PARAMETER AzureResourceMetric
    (AzureMetrics) Azure metric name. Required.

.PARAMETER AzureResourceType
    (AzureMetrics) Azure resource type (e.g. Microsoft.Network/virtualNetworks). Required.

.PARAMETER AzureSubscriptionId
    (AzureMetrics) Azure subscription GUID. Required.

.PARAMETER AzureResourceName
    (AzureMetrics) Resource display name. Required.

.PARAMETER AzureResourceGroup
    (AzureMetrics) Resource group name. Required.

.PARAMETER AzureAggregationType
    (AzureMetrics) Aggregation type. Default is 'Maximum'.

.PARAMETER AzureUseDeviceContext
    (AzureMetrics) Set to '1' to use device context. Default is '0'.

.PARAMETER AzureDeviceId
    (AzureMetrics) Device ID override. Default is '-1'.

.PARAMETER AzureDeviceName
    (AzureMetrics) Device name override. Default is empty.

.PARAMETER CloudWatchNamespace
    (CloudWatch) CloudWatch namespace (e.g. 'AWS/Usage'). Required.

.PARAMETER CloudWatchMetric
    (CloudWatch) CloudWatch metric name. Required.

.PARAMETER CloudWatchRegion
    (CloudWatch) AWS region (e.g. 'us-east-1'). Required.

.PARAMETER CloudWatchStatistic
    (CloudWatch) Statistic type. Default is 'Sum'.

.PARAMETER CloudWatchDimensions
    (CloudWatch) Dimension filters. Default is empty.

.PARAMETER CloudWatchGrouping
    (CloudWatch) Grouping expression. Default is empty.

.PARAMETER CloudWatchUnit
    (CloudWatch) Unit filter. Default is empty.

.EXAMPLE
    Add-WUGPerformanceMonitor -DeviceId 42 -Type RestApi -RestApiUrl 'https://myhost.example.com/api/health' -RestApiJsonPath '$.status'

    Assigns a REST API performance monitor to device 42, polling the given URL and
    extracting the $.status field from the JSON response.

.EXAMPLE
    Add-WUGPerformanceMonitor -DeviceId 42 -Type RestApi -RestApiUrl 'https://myhost.example.com/api/health' -RestApiJsonPath '$.status' -RestApiCustomHeader 'Accept:application/json' -RestApiHttpTimeoutMs 5000

    Same as above with a custom Accept header and a 5-second timeout.

.EXAMPLE
    Add-WUGPerformanceMonitor -DeviceId 42 -Type PowerShell -ScriptText '$Context.SetValue((Get-Process | Measure-Object -Property WorkingSet -Sum).Sum / 1MB)' -ScriptTimeout 30

    Assigns a PowerShell performance monitor that reports total process working set in MB.

.EXAMPLE
    Add-WUGPerformanceMonitor -DeviceId 42 -Type Snmp -SnmpOID '1.3.6.1.4.1.9.9.13.1.4.1.3'

    Assigns an SNMP performance monitor polling the specified OID.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: POST /api/v1/monitors/- (create) + POST /api/v1/devices/{deviceId}/monitors/- (assign)
    Spec: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/whatsupgold2024-0-3.json
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS

    Supported Types: RestApi, PowerShell, WmiRaw, WmiFormatted, WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch

    Removal: Use Remove-WUGDeviceMonitor to remove the assignment, or Remove-WUGActiveMonitor -Type performance to remove from library.
#>
function Add-WUGPerformanceMonitor {
    [CmdletBinding(DefaultParameterSetName = 'Snmp', SupportsShouldProcess = $true)]
    param(
        # -- Common parameters (all parameter sets) ---------------------------
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int]$DeviceId,

        [Parameter(Mandatory = $true, ParameterSetName = 'RestApi')]
        [Parameter(Mandatory = $true, ParameterSetName = 'PowerShell')]
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiRaw')]
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiFormatted')]
        [Parameter(Mandatory = $true, ParameterSetName = 'WindowsPerformanceCounter')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Snmp')]
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [Parameter(Mandatory = $true, ParameterSetName = 'CloudWatch')]
        [ValidateSet('RestApi', 'PowerShell', 'WmiRaw', 'WmiFormatted', 'WindowsPerformanceCounter', 'Ssh', 'Snmp', 'AzureMetrics', 'CloudWatch')]
        [string]$Type,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$PollingIntervalMinutes = 5,

        [Parameter()]
        [ValidateSet("true", "false")]
        [string]$Enabled = "true",

        # -- RestApi parameters -----------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'RestApi')]
        [string]$RestApiUrl,
        [Parameter(Mandatory = $true, ParameterSetName = 'RestApi')]
        [string]$RestApiJsonPath,
        [Parameter(ParameterSetName = 'RestApi')]
        [string]$RestApiHttpMethod = 'GET',
        [Parameter(ParameterSetName = 'RestApi')]
        [int]$RestApiHttpTimeoutMs = 10000,
        [Parameter(ParameterSetName = 'RestApi')]
        [ValidateSet('0', '1')]
        [string]$RestApiIgnoreCertErrors = '0',
        [Parameter(ParameterSetName = 'RestApi')]
        [ValidateSet('0', '1')]
        [string]$RestApiUseAnonymousAccess = '1',
        [Parameter(ParameterSetName = 'RestApi')]
        [string]$RestApiCustomHeader = '',

        # -- PowerShell parameters --------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'PowerShell')]
        [string]$ScriptText,
        [Parameter(ParameterSetName = 'PowerShell')]
        [string]$ScriptType = '2',
        [Parameter(ParameterSetName = 'PowerShell')]
        [int]$ScriptTimeout = 60,
        [Parameter(ParameterSetName = 'PowerShell')]
        [ValidateSet('0', '1')]
        [string]$ScriptImpersonateFlag = '1',
        [Parameter(ParameterSetName = 'PowerShell')]
        [string]$ScriptReferenceVariables = '',

        # -- WmiRaw parameters ------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiRaw')]
        [string]$WmiRawRelativePath,
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiRaw')]
        [string]$WmiRawPropertyName,
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiRaw')]
        [string]$WmiRawDisplayname,
        [Parameter(ParameterSetName = 'WmiRaw')]
        [string]$WmiRawInstanceName = '',
        [Parameter(ParameterSetName = 'WmiRaw')]
        [int]$WmiRawTimeout = 5,
        [Parameter(ParameterSetName = 'WmiRaw')]
        [string]$WmiRawDeviceAddress = '',

        # -- WmiFormatted parameters ------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiFormatted')]
        [string]$WmiFormattedRelativePath,
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiFormatted')]
        [string]$WmiFormattedPropertyName,
        [Parameter(Mandatory = $true, ParameterSetName = 'WmiFormatted')]
        [string]$WmiFormattedDisplayname,
        [Parameter(ParameterSetName = 'WmiFormatted')]
        [string]$WmiFormattedInstanceName = '',
        [Parameter(ParameterSetName = 'WmiFormatted')]
        [int]$WmiFormattedTimeout = 5,
        [Parameter(ParameterSetName = 'WmiFormatted')]
        [string]$WmiFormattedDeviceAddress = '',

        # -- WindowsPerformanceCounter parameters -----------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'WindowsPerformanceCounter')]
        [string]$PerfCounterCategory,
        [Parameter(Mandatory = $true, ParameterSetName = 'WindowsPerformanceCounter')]
        [string]$PerfCounterName,
        [Parameter(ParameterSetName = 'WindowsPerformanceCounter')]
        [string]$PerfCounterInstance = '',
        [Parameter(ParameterSetName = 'WindowsPerformanceCounter')]
        [int]$PerfCounterSampleInterval = 1000,

        # -- Ssh parameters ---------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
        [string]$SshCommand,
        [Parameter(ParameterSetName = 'Ssh')]
        [string]$SshCommandType = 'SingleCommand',
        [Parameter(ParameterSetName = 'Ssh')]
        [ValidateSet('0', '1')]
        [string]$SshUseCustomRegex = '0',
        [Parameter(ParameterSetName = 'Ssh')]
        [string]$SshCustomRegexValue = 'Result=([0-9.,]+)',
        [Parameter(ParameterSetName = 'Ssh')]
        [string]$SshEOLChars = 'None',
        [Parameter(ParameterSetName = 'Ssh')]
        [string]$SshCredentialID = '-1',

        # -- Snmp parameters --------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'Snmp')]
        [string]$SnmpOID,
        [Parameter(ParameterSetName = 'Snmp')]
        [string]$SnmpInstance = '0',
        [Parameter(ParameterSetName = 'Snmp')]
        [ValidateSet('0', '1')]
        [string]$SnmpUseRawValues = '1',
        [Parameter(ParameterSetName = 'Snmp')]
        [int]$SnmpRetries = 1,
        [Parameter(ParameterSetName = 'Snmp')]
        [int]$SnmpTimeout = 3,

        # -- AzureMetrics parameters ------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [string]$AzureResourceId,
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [string]$AzureResourceMetric,
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [string]$AzureResourceType,
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [string]$AzureSubscriptionId,
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [string]$AzureResourceName,
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureMetrics')]
        [string]$AzureResourceGroup,
        [Parameter(ParameterSetName = 'AzureMetrics')]
        [string]$AzureAggregationType = 'Maximum',
        [Parameter(ParameterSetName = 'AzureMetrics')]
        [ValidateSet('0', '1')]
        [string]$AzureUseDeviceContext = '0',
        [Parameter(ParameterSetName = 'AzureMetrics')]
        [string]$AzureDeviceId = '-1',
        [Parameter(ParameterSetName = 'AzureMetrics')]
        [string]$AzureDeviceName = '',

        # -- CloudWatch parameters --------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchNamespace,
        [Parameter(Mandatory = $true, ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchMetric,
        [Parameter(Mandatory = $true, ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchRegion,
        [Parameter(ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchStatistic = 'Sum',
        [Parameter(ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchDimensions = '',
        [Parameter(ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchGrouping = '',
        [Parameter(ParameterSetName = 'CloudWatch')]
        [string]$CloudWatchUnit = ''
    )

    begin {
        Write-Debug "Initializing Add-WUGPerformanceMonitor function with Type: $Type"
        $baseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"
        $ClassId = ""
        $PropertyBags = @()

        # Global variables error checking
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            return
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Please run Connect-WUGServer first."
            return
        }

        # Monitor-specific setup
        switch ($Type) {

            'RestApi' {
                $ClassId = '987bb6a4-70f4-4f46-97c6-1c9dd1766437'
                $PropertyBags = @(
                    @{ "name" = "RdcRestApi:RestUrl";            "value" = "$RestApiUrl" },
                    @{ "name" = "RdcRestApi:JsonPath";           "value" = "$RestApiJsonPath" },
                    @{ "name" = "RdcRestApi:HttpMethod";         "value" = "$RestApiHttpMethod" },
                    @{ "name" = "RdcRestApi:HttpTimeoutMs";      "value" = "$RestApiHttpTimeoutMs" },
                    @{ "name" = "RdcRestApi:IgnoreCertErrors";   "value" = "$RestApiIgnoreCertErrors" },
                    @{ "name" = "RdcRestApi:UseAnonymousAccess"; "value" = "$RestApiUseAnonymousAccess" },
                    @{ "name" = "RdcRestApi:CustomHeader";       "value" = "$RestApiCustomHeader" }
                )
            }

            'PowerShell' {
                $ClassId = '8ea99cce-805f-4dc6-88a6-e83cd59b2353'
                $PropertyBags = @(
                    @{ "name" = "Script:ScriptText";               "value" = "$ScriptText" },
                    @{ "name" = "Script:ScriptType";               "value" = "$ScriptType" },
                    @{ "name" = "Script:ScriptTimeout";            "value" = "$ScriptTimeout" },
                    @{ "name" = "Script:ScriptImpersonateFlag";    "value" = "$ScriptImpersonateFlag" },
                    @{ "name" = "Script:ScriptReferenceVariables"; "value" = "$ScriptReferenceVariables" }
                )
            }

            'WmiRaw' {
                $ClassId = '3392abfe-cc36-47e1-9b53-bd1d2b9e060e'
                $PropertyBags = @(
                    @{ "name" = "WMI:Counter-RelativePath"; "value" = "$WmiRawRelativePath" },
                    @{ "name" = "WMI:Counter-PropertyName"; "value" = "$WmiRawPropertyName" },
                    @{ "name" = "WMI:Counter-Displayname";  "value" = "$WmiRawDisplayname" },
                    @{ "name" = "WMI:Counter-InstanceName"; "value" = "$WmiRawInstanceName" },
                    @{ "name" = "WMI:Counter-Timeout";      "value" = "$WmiRawTimeout" },
                    @{ "name" = "Device:Address";           "value" = "$WmiRawDeviceAddress" }
                )
            }

            'WmiFormatted' {
                $ClassId = 'fa070b5c-9a2b-4f60-ade7-c2200e102033'
                $PropertyBags = @(
                    @{ "name" = "WMI:Counter-RelativePath"; "value" = "$WmiFormattedRelativePath" },
                    @{ "name" = "WMI:Counter-PropertyName"; "value" = "$WmiFormattedPropertyName" },
                    @{ "name" = "WMI:Counter-Displayname";  "value" = "$WmiFormattedDisplayname" },
                    @{ "name" = "WMI:Counter-InstanceName"; "value" = "$WmiFormattedInstanceName" },
                    @{ "name" = "WMI:Counter-Timeout";      "value" = "$WmiFormattedTimeout" },
                    @{ "name" = "Device:Address";           "value" = "$WmiFormattedDeviceAddress" }
                )
            }

            'WindowsPerformanceCounter' {
                $ClassId = '0236a3db-8f63-4668-92b2-53628b6f2486'
                $PropertyBags = @(
                    @{ "name" = "RdcPerformanceCounter:Category";       "value" = "$PerfCounterCategory" },
                    @{ "name" = "RdcPerformanceCounter:Counter";        "value" = "$PerfCounterName" },
                    @{ "name" = "RdcPerformanceCounter:Instance";       "value" = "$PerfCounterInstance" },
                    @{ "name" = "RdcPerformanceCounter:SampleInterval"; "value" = "$PerfCounterSampleInterval" }
                )
            }

            'Ssh' {
                $ClassId = '2eebb205-d2bc-4f39-80af-e0dab1f8f32a'
                $PropertyBags = @(
                    @{ "name" = "RdcSSH:Command";          "value" = "$SshCommand" },
                    @{ "name" = "RdcSSH:CommandType";      "value" = "$SshCommandType" },
                    @{ "name" = "RdcSSH:UseCustomRegex";   "value" = "$SshUseCustomRegex" },
                    @{ "name" = "RdcSSH:CustomRegexValue"; "value" = "$SshCustomRegexValue" },
                    @{ "name" = "RdcSSH:EOLChars";         "value" = "$SshEOLChars" },
                    @{ "name" = "RdcSSH:CredentialID";     "value" = "$SshCredentialID" }
                )
            }

            'Snmp' {
                $ClassId = '2f300544-cba3-4341-9b05-2d1786f68e07'
                $PropertyBags = @(
                    @{ "name" = "SNMP:OID";          "value" = "$SnmpOID" },
                    @{ "name" = "SNMP:Instance";     "value" = "$SnmpInstance" },
                    @{ "name" = "SNMP:UseRawValues"; "value" = "$SnmpUseRawValues" },
                    @{ "name" = "SNMP:Retries";      "value" = "$SnmpRetries" },
                    @{ "name" = "SNMP:Timeout";      "value" = "$SnmpTimeout" }
                )
            }

            'AzureMetrics' {
                $ClassId = '23f1cc8c-97d0-4dae-927f-1d14f9dbb05d'
                $PropertyBags = @(
                    @{ "name" = "AzureMetrics:ResourceId";      "value" = "$AzureResourceId" },
                    @{ "name" = "AzureMetrics:ResourceMetric";  "value" = "$AzureResourceMetric" },
                    @{ "name" = "AzureMetrics:ResourceType";    "value" = "$AzureResourceType" },
                    @{ "name" = "AzureMetrics:SubscriptionId";  "value" = "$AzureSubscriptionId" },
                    @{ "name" = "AzureMetrics:ResourceName";    "value" = "$AzureResourceName" },
                    @{ "name" = "AzureMetrics:ResourceGroup";   "value" = "$AzureResourceGroup" },
                    @{ "name" = "AzureMetrics:AggregationType"; "value" = "$AzureAggregationType" },
                    @{ "name" = "AzureMetrics:UseDeviceContext"; "value" = "$AzureUseDeviceContext" },
                    @{ "name" = "AzureMetrics:DeviceId";        "value" = "$AzureDeviceId" },
                    @{ "name" = "AzureMetrics:DeviceName";      "value" = "$AzureDeviceName" }
                )
            }

            'CloudWatch' {
                $ClassId = 'ae48dda4-1e0b-4bf5-bf01-18eb70f0db40'
                $PropertyBags = @(
                    @{ "name" = "CloudWatch:Namespace";  "value" = "$CloudWatchNamespace" },
                    @{ "name" = "CloudWatch:Metric";     "value" = "$CloudWatchMetric" },
                    @{ "name" = "CloudWatch:Region";     "value" = "$CloudWatchRegion" },
                    @{ "name" = "CloudWatch:Statistic";  "value" = "$CloudWatchStatistic" },
                    @{ "name" = "CloudWatch:Dimensions"; "value" = "$CloudWatchDimensions" },
                    @{ "name" = "CloudWatch:Grouping";   "value" = "$CloudWatchGrouping" },
                    @{ "name" = "CloudWatch:Unit";       "value" = "$CloudWatchUnit" }
                )
            }
        }
    }

    process {
        # Auto-generate name if not supplied
        if (-not $Name) {
            $suffix = if ($DeviceId) { "Device${DeviceId}" } else { 'Library' }
            $Name = "PerfMon-${Type}-${suffix}-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }

        Write-Verbose "Creating $Type performance monitor: $Name"

        $payload = @{
            "allowSystemMonitorCreation" = $true
            "name"                       = $Name
            "description"                = "$Type performance monitor created via Add-WUGPerformanceMonitor"
            "monitorTypeInfo"            = @{
                "baseType" = "performance"
                "classId"  = $ClassId
            }
            "propertyBags"               = $PropertyBags
            "useInDiscovery"             = $false
        }

        $jsonPayload = $payload | ConvertTo-Json -Compress -Depth 5
        Write-Debug "Create payload: $jsonPayload"

        $targetDesc = if ($DeviceId) { "$Type performance monitor '$Name' on device $DeviceId" } else { "$Type performance monitor '$Name' in library" }
        if (-not $PSCmdlet.ShouldProcess($targetDesc, 'Create performance monitor')) { return }

        # Step 1: Create the performance monitor in the library
        $newMonitorId = $null

        try {
            $createResult = Get-WUGAPIResponse -Uri $baseUri -Method "POST" -Body $jsonPayload

            if ($createResult.data.successful -eq 1) {
                $newMonitorId = $createResult.data.idMap.resultId
                Write-Verbose "Successfully created performance monitor '$Name' (library ID: $newMonitorId)."
                Write-Debug "Create result: $(ConvertTo-Json $createResult -Depth 10)"
            }
            else {
                Write-Warning "Failed to create performance monitor '$Name' in library."
                Write-Debug "Create result: $(ConvertTo-Json $createResult -Depth 10)"
                return
            }
        }
        catch {
            Write-Error "Error creating performance monitor '$Name': $($_.Exception.Message)"
            return
        }

        # Step 2: Assign the monitor to the device (if DeviceId was provided)
        if (-not $DeviceId) {
            Write-Verbose "No DeviceId specified — monitor '$Name' created in library only (ID: $newMonitorId)."
            Write-Output ([PSCustomObject]@{
                DeviceId    = $null
                MonitorType = $Type
                MonitorName = $Name
                MonitorId   = $newMonitorId
                Success     = $true
            })
            return
        }

        $assignUri  = "$($global:WhatsUpServerBaseURI)/api/v1/devices/${DeviceId}/monitors/-"
        $assignBody = @{
            type          = "performance"
            monitorTypeId = $newMonitorId
            enabled       = $Enabled
            isGlobal      = "true"
            performance   = @{
                pollingIntervalMinutes = $PollingIntervalMinutes
            }
        } | ConvertTo-Json -Depth 5

        Write-Debug "Assign payload: $assignBody"

        try {
            Write-Verbose "Assigning performance monitor '$Name' (ID: $newMonitorId) to device $DeviceId."
            $assignResult = Get-WUGAPIResponse -Uri $assignUri -Method "POST" -Body $assignBody

            if ($assignResult.data.successful -eq 1) {
                Write-Verbose "Successfully assigned performance monitor '$Name' to device $DeviceId."
                Write-Output ([PSCustomObject]@{
                    DeviceId    = $DeviceId
                    MonitorType = $Type
                    MonitorName = $Name
                    MonitorId   = $newMonitorId
                    Success     = $true
                })
            }
            else {
                Write-Warning "Created monitor '$Name' (ID: $newMonitorId) but failed to assign to device $DeviceId."
                Write-Debug "Assign result: $(ConvertTo-Json $assignResult -Depth 10)"
                Write-Output ([PSCustomObject]@{
                    DeviceId    = $DeviceId
                    MonitorType = $Type
                    MonitorName = $Name
                    MonitorId   = $newMonitorId
                    Success     = $false
                })
            }
        }
        catch {
            Write-Error "Error assigning monitor '$Name' to device ${DeviceId}: $($_.Exception.Message)"
            Write-Warning "Monitor '$Name' was created in library (ID: $newMonitorId) but not assigned. Clean up manually if needed."
        }
    }

    end {
        Write-Debug "Completed Add-WUGPerformanceMonitor function."
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAKQBgKX5gx+I1i
# gNHkVVjqfb5XxQE286GDT1jLSrmn0aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgMUbdf/w7ORIMAQbP1vbeB3qz8d9wCcb2
# Z+UNmSAhaxgwDQYJKoZIhvcNAQEBBQAEggIA3rxZNAELtJF5ZwBaVsItFgA6o9l0
# j5l10O5xyGXezeQuEpYbUMEAD7rtb2JkfihG/uxHQUoUMYiXOELktw5R7sDeTfDW
# jpqMLdI1YCbL0br3BJspF1iKExfT9lmsFKuhLLLKpz0ZBXxY8DlkmO3h0NrlnQkE
# UOsBYFsFpucMixGhBzdV3YJUwfYfJ010Tmlj6UjxdJeH61HUnirfJyvaNLVivBS1
# i/cYEstfFDO94HwOGotDl0OoL2CdE5wvySH+s86iDJWQWcxAsV5PdG2WaJH7S6mL
# uZGQkhLcauDPMJ2pPvndGUCfqauOmBjHyLFRH102pTT1nheKyJufqClJEy9K/23U
# 1V79tedqoqFeM1tFAYRhyyBarxcakrdssztwW5vkeS4BPmAFzEFDn0+HDcSmJzxN
# iI+M2dzIwUdtlNtjPSp/ku/knXITS81l7b9BXjXMzgC717dDt1r+8V9gxtT/05oC
# WCbB0TQhS8xlk84tMNXsoQFIwTECZ112JJ3d+FLcK8iCdQA9tMscoYgp27t0LmUx
# zXCZFfMHimGqknGSSROCVJcBkLuxgFv88bCnr5HvO+BFNy7Eyw7AHs6lWXfkv+Z0
# 2otkK9pEZtrhArLV4o4sBQV4Vjjrv3JKh5/rJZGiQelFI1w7iNVRHMd/2hAeZois
# Na96PbXqKyaiY1I=
# SIG # End signature block
