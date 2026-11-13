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

.PARAMETER Description
    Description stored on the library monitor. If omitted, a generic description
    based on Type is used.

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
        [string]$Description,

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
            "description"                = $(if ($Description) { $Description } else { "$Type performance monitor created via Add-WUGPerformanceMonitor" })
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
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCmhTU98wJjay4H
# kvH6t1cLDDmcU6PGykOjZsyJUs4SA6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCE
# +Nr5jXE1c39H8eIPppkrMYMRxh69YbK5vsddZXJHKjANBgkqhkiG9w0BAQEFAASC
# AgAG50r+vocMcyCNnl4Bx/ozSoswZZEUA0O6rN9MnTRZGRJ8JlrClw4H4KlFJ3c8
# ui9sFxRamevhdWIavBBl2RfLLrSdOWNhodsiihfrbP2BIUaS4hGLrV+ahTiUlvvH
# KdPt5O0fbDQKqJhEyUUQr/GJhoOlJrDNEvMo/LF+7sH+kq1pxqSa7qgDxNn7X6IF
# y51fliqULJmzn8o4Fm2T0BAKr26Kv7AzwvApVZ7FMYWs9UDYUeu4eyD8iiZb4BLK
# U6nA4jt67lPRXOAAcx6QEc//NzhxQaLrllzO+PHhe2x5sTVssNoKufpoR2HWha33
# m9JNlAyFDh7ktlO8AfcRB4/8FmaUYezFmIjqzVvpyuUBthvxRNR8zayraaC0pwM4
# Ab2Ln+t3hEZ69y11wYwzmih3GX2CIrRtPsdU6kMdWunByBKhejLV9jiPLl75jPGm
# H1LnUovPxCPsTtZJtR4j7HpMuqzqXvBbN1G5T7NXZRklMqWIyk4LfeDcfZv/U8Rl
# OY72Oyv/upTaRsdNO9GQ9TiM7z9KwxXid9Hbf+lf/TtP35G1fHnm+I6nguFsxKIS
# zRTNstWrTzpL00HTTDmSnilGpLJ35dfJctQXpvfUN/WOShVypo07877ilBT+VKgB
# ODEHSaz22AlGLEWUgr27THPgvZGrLU6sQvNpd/ZRmKIZ7KGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMwMjA4MDJaMC8GCSqGSIb3DQEJBDEiBCBwQoRNyF6H
# WUUiYz5WWqjKXy7Wpt4z46vP3OXXkpOPPjANBgkqhkiG9w0BAQEFAASCAgBWMp3X
# x7G8IzUa+SLP/0TjWG8YzZ20ZJ1/HTsxs0GsRndkPLWi5MVKpCMlTQ86a5rCGrhH
# dfnqjgSithERcJxsmTBoOwdTxOUB7iYga90kwDq8JVTfeDdJoDzMPJB8USOwezno
# FMTuaIaPJ2GdBFthVPOxaqzyjCTnpM27ywCotWStmW2rQRm+TxpiIXXTPGGn3czR
# j77sWpq0u+eVJqdQKyt8AMz+uPdAtRHp97BmBcfnqGSN6RrYIs+dGZST+zFMmpN9
# hrTuChiYhqE4Y0BggsDkhcVlCFnnaEea7LX6VInCSt3GvCAyxF/owf3f3cdbKwrw
# pcj3vP5lf95uFaL5Z4TJAhK8JFnsF4PhLo+FFgt/dfHPtVKrNU4dkX9V0iCkZaSO
# Y2Vcj5I59YGjLoZ8/y+EykmA2xhOQkZ8ZS5ney25UfVD63c4wKZa1f25FkeSbbNv
# EYpjEq/yYeDUrn1MQDwZsA6TKgdb5xDw+tjDc3rISvzhPHRW9aWXeHJpfrjFtMYz
# VOTWP8jb/WcInWLU+1HqDaUwabwwaYPwAE8kM/I9pHbSux2CNnqqw//38VuFjRkW
# BcqcEi972995i9ONQxsFAZu074a0Mezvd7HLt8wEd2VUeDORuN2s0hOKSENXYRmR
# iPA8gK5D1l7H+ftyL5hmaUjTGsjqmWRrZHLqoQ==
# SIG # End signature block
