# ============================================================
# API Endpoint Reference
# Source: WhatsUpGold 2024 REST API Spec v0.3
#
# Update performance monitor library template:
#    PUT /api/v1/monitors/{MonitorId}?type=performance
#    Body schema: MonitorUpdate
#      - name            (string, optional)  Display name of monitor
#      - description     (string, optional)  Description of monitor
#      - propertyBags    (array,  optional)  [ { name: string, value: string }, ... ]
#      - useInDiscovery  (bool,   optional)  true/false
#      - enabled         (bool,   optional)  true/false
#    Success response: Result with updated monitor data
#
#    Tip from the API docs: "When you want to update a monitor configuration,
#    use the monitor ID to get a populated (or default) configuration properties
#    array. Then re-use it. Adjust property values as needed and include this
#    configuration properties array with the request body."
# ============================================================
<#
.SYNOPSIS
    Updates an existing performance monitor's library template in WhatsUp Gold.

.DESCRIPTION
    Set-WUGPerformanceMonitor sends a PUT request to update the PropertyBags,
    name, description, or enabled state of an existing performance monitor
    template in the WhatsUp Gold monitor library.

    This modifies the template in-place via:
      PUT /api/v1/monitors/{MonitorId}?type=performance

    All devices sharing that monitor template will pick up the new settings.

    Supports two usage patterns:

    1. Type-specific parameter sets (RestApi, PowerShell, WmiRaw, WmiFormatted,
       WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch) -- mirrors
       Add-WUGPerformanceMonitor with explicit named parameters that auto-build
       the correct PropertyBags array.

    2. Custom parameter set -- pass a raw -PropertyBags array of
       @{name='...'; value='...'} hashtables for monitors whose property bag
       schema is non-standard or not exposed by the public API (e.g. built-in
       Memory Utilization, CPU Utilization, Disk Utilization).

    Use Get-WUGPerformanceMonitor to discover MonitorTypeId values for the
    monitors assigned to a device.

.PARAMETER MonitorId
    The library ID of the performance monitor template to update. Required.
    This is the 'monitorTypeId' value returned by Get-WUGPerformanceMonitor.

.PARAMETER Type
    The type of performance monitor. Determines which PropertyBags are built
    from the type-specific named parameters.
    Valid values: RestApi, PowerShell, WmiRaw, WmiFormatted,
    WindowsPerformanceCounter, Ssh, Snmp, AzureMetrics, CloudWatch.

.PARAMETER PropertyBags
    (Custom parameter set) Raw array of property bags. Each element should be a
    hashtable with 'name' and 'value' keys.
    Example: @( @{name='Memory:UseWMI'; value='1'} )

.PARAMETER Name
    New display name for the monitor template. Optional.

.PARAMETER Description
    New description. Optional.

.PARAMETER Enabled
    Enable ("true") or disable ("false") the monitor template. Optional.

.PARAMETER UseInDiscovery
    Whether the monitor should be used during discovery. Optional.

.EXAMPLE
    # Update the built-in Memory Utilization monitor to use WMI / Physical Memory only
    $bags = @(
        @{ name = 'Memory:UseWMI';          value = '1' }
        @{ name = 'Memory:CollectionType';  value = '0' }
        @{ name = 'Memory:SelectedIndexes'; value = '1000|Physical Memory' }
    )
    Set-WUGPerformanceMonitor -MonitorId 5 -PropertyBags $bags

.EXAMPLE
    # Update a WMI Formatted performance monitor with named parameters
    Set-WUGPerformanceMonitor -MonitorId 12345 -Type WmiFormatted `
        -WmiFormattedRelativePath 'Win32_PerfFormattedData_PerfOS_Memory' `
        -WmiFormattedPropertyName 'AvailableBytes' `
        -WmiFormattedDisplayname 'Memory \\ Available Bytes (Physical)'

.EXAMPLE
    # Update a REST API performance monitor
    Set-WUGPerformanceMonitor -MonitorId 67890 -Type RestApi `
        -RestApiUrl 'https://api.example.com/health' `
        -RestApiJsonPath '$.status' `
        -Name 'Health Check v2'

.EXAMPLE
    # Disable a performance monitor template
    Set-WUGPerformanceMonitor -MonitorId 5 -Enabled 'false'

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: PUT /api/v1/monitors/{MonitorId}?type=performance
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS

    This function updates the library template. All devices using the template
    will inherit the new PropertyBags on their next poll cycle.
#>
function Set-WUGPerformanceMonitor {
    [CmdletBinding(DefaultParameterSetName = 'Custom', SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MonitorId,

        # -- Type-specific parameter sets -------------------------------------
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

        # -- Custom / raw PropertyBags (default parameter set) ----------------
        [Parameter(ParameterSetName = 'Custom')]
        [array]$PropertyBags,

        # -- Common optional fields -------------------------------------------
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [ValidateSet("true", "false")]
        [string]$Enabled,

        [Parameter()]
        [bool]$UseInDiscovery,

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
        if (-not $global:WUGBearerHeaders) {
            Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
            return
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error -Message "Base URI not found. Please run Connect-WUGServer first."
            return
        }

        # Build PropertyBags from type-specific parameters (if not using Custom set)
        if ($PSCmdlet.ParameterSetName -ne 'Custom') {
            $PropertyBags = @()
            switch ($Type) {
                'RestApi' {
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
                    $PropertyBags = @(
                        @{ "name" = "Script:ScriptText";               "value" = "$ScriptText" },
                        @{ "name" = "Script:ScriptType";               "value" = "$ScriptType" },
                        @{ "name" = "Script:ScriptTimeout";            "value" = "$ScriptTimeout" },
                        @{ "name" = "Script:ScriptImpersonateFlag";    "value" = "$ScriptImpersonateFlag" },
                        @{ "name" = "Script:ScriptReferenceVariables"; "value" = "$ScriptReferenceVariables" }
                    )
                }
                'WmiRaw' {
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
                    $PropertyBags = @(
                        @{ "name" = "RdcPerformanceCounter:Category";       "value" = "$PerfCounterCategory" },
                        @{ "name" = "RdcPerformanceCounter:Counter";        "value" = "$PerfCounterName" },
                        @{ "name" = "RdcPerformanceCounter:Instance";       "value" = "$PerfCounterInstance" },
                        @{ "name" = "RdcPerformanceCounter:SampleInterval"; "value" = "$PerfCounterSampleInterval" }
                    )
                }
                'Ssh' {
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
                    $PropertyBags = @(
                        @{ "name" = "SNMP:OID";          "value" = "$SnmpOID" },
                        @{ "name" = "SNMP:Instance";     "value" = "$SnmpInstance" },
                        @{ "name" = "SNMP:UseRawValues"; "value" = "$SnmpUseRawValues" },
                        @{ "name" = "SNMP:Retries";      "value" = "$SnmpRetries" },
                        @{ "name" = "SNMP:Timeout";      "value" = "$SnmpTimeout" }
                    )
                }
                'AzureMetrics' {
                    $PropertyBags = @(
                        @{ "name" = "AzureMetrics:ResourceId";       "value" = "$AzureResourceId" },
                        @{ "name" = "AzureMetrics:ResourceMetric";   "value" = "$AzureResourceMetric" },
                        @{ "name" = "AzureMetrics:ResourceType";     "value" = "$AzureResourceType" },
                        @{ "name" = "AzureMetrics:SubscriptionId";   "value" = "$AzureSubscriptionId" },
                        @{ "name" = "AzureMetrics:ResourceName";     "value" = "$AzureResourceName" },
                        @{ "name" = "AzureMetrics:ResourceGroup";    "value" = "$AzureResourceGroup" },
                        @{ "name" = "AzureMetrics:AggregationType";  "value" = "$AzureAggregationType" },
                        @{ "name" = "AzureMetrics:UseDeviceContext"; "value" = "$AzureUseDeviceContext" },
                        @{ "name" = "AzureMetrics:DeviceId";         "value" = "$AzureDeviceId" },
                        @{ "name" = "AzureMetrics:DeviceName";       "value" = "$AzureDeviceName" }
                    )
                }
                'CloudWatch' {
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
    }

    process {
        # Build the request body with only the fields that were specified
        $body = @{}
        if ($Name)          { $body.name = $Name }
        if ($Description)   { $body.description = $Description }
        if ($PropertyBags)  { $body.propertyBags = $PropertyBags }
        if ($PSBoundParameters.ContainsKey('UseInDiscovery')) { $body.useInDiscovery = $UseInDiscovery }
        if ($PSBoundParameters.ContainsKey('Enabled'))        { $body.enabled = [System.Convert]::ToBoolean($Enabled) }

        if ($body.Count -eq 0) {
            Write-Warning "No changes specified for monitor $MonitorId. Nothing to update."
            return
        }

        $uri = "${global:WhatsUpServerBaseURI}/api/v1/monitors/${MonitorId}?type=performance"
        $jsonBody = $body | ConvertTo-Json -Depth 10

        Write-Verbose "Updating performance monitor template $MonitorId"
        Write-Debug "PUT $uri"
        Write-Debug "Body: $jsonBody"

        if (-not $PSCmdlet.ShouldProcess("Performance monitor template $MonitorId", 'Update configuration')) { return }

        try {
            $response = Get-WUGAPIResponse -Uri $uri -Method PUT -Body $jsonBody
            Write-Verbose "Successfully updated performance monitor template $MonitorId."
            return $response
        }
        catch {
            Write-Error "Failed to update performance monitor template ${MonitorId}: $_"
        }
    }
}
