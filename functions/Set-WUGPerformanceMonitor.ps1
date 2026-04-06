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

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCobRVHE4adGLWW
# n0vImO4adQGWpKS3yyNn0tez8vz3uKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg0ZHEJrk3R7BnWawBoHA6zzU+XGG0NUgM
# cQoI35VqGMswDQYJKoZIhvcNAQEBBQAEggIAelRUk9n3r8YFHrZRwQCV4YTrBQbQ
# OGQDNnoSjbaz3UOj/WDCIYYZHaw8RCOQctE70pF+ausrpo2+uvjFYn9w9RLva/gO
# y+zDZQCbLluum1Gs9lW60TxLzkeLqCSmJPXGmpbP7c+gUYZW0ze78f2MZJs9EYTX
# MAYi5S3JimeqgEHWxf5T9KA4HzInfXcEOwjSiQ4gcAy+RECefCe3FgqQ+bksgJDA
# lSJ1fREyjgkd2HHFX/9Dz5YUuvOj1lemJ5v8m4smI0JmVuZmAGXkBavAoYQmzxvB
# EJgvQW11KQUMLBQcEjn/HArS8aNDeqx7TNQ06KzSxiYBQU+25C0lVThbJLCvYDbn
# z8YyFxYA4c+zLLMrJhP6kUkaJZkP0cfDFQbCotG6kgiptBafjXOKWFRkRSh//KRx
# qSpy3xajoiUCbPJaoRVcc2KvTSczZw/S2Obf8u3h6hQX8+if1gRJRPBdlhohre27
# gON2FnRdoXE2shIAvmsgcR3+a+fcTz04CvbvpABQ/LEHPe52p5d3bLYRH3o50L6z
# mted7MfvAMVLYF0HuvyMm6Wjx0Nowq+yqolZ2wzyH2y3hnbp56lcB8F7zkqMGIZ3
# sUcbBJHn+6o35kX6lf0Jypd6jk9EBUSZAAfxjGuyBLnCItChtAWR/52GtS6kwr9Q
# AFODP5+FPtpfp04=
# SIG # End signature block
