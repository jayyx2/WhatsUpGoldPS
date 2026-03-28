<#
.SYNOPSIS
Get performance monitors from the WhatsUp Gold library or device-specific assignments.

.DESCRIPTION
Without -DeviceId, queries the monitor library via GET /api/v1/monitors/-?type=performance.
With -DeviceId, queries device assignments via GET /api/v1/devices/{deviceId}/monitors/-.

Use -Search to filter by display name, description, or classId in either mode.

.PARAMETER DeviceId
The device ID(s) to retrieve performance monitor assignments for.
Accepts pipeline input by property name. When omitted, searches the monitor library.

.PARAMETER Search
Return only monitors containing this string in display name, description,
classId, argument, or comment. Case-insensitive.

.PARAMETER MonitorTypeId
Filter results by monitor type ID.

.PARAMETER EnabledOnly
[Device mode] Return only enabled monitors. Default is $false (return all).

.PARAMETER View
Level of detail returned. Device mode: 'id', 'minimum', 'basic', 'status' (default 'status').
Library mode: 'id', 'basic', 'info', 'summary', 'details'.

.PARAMETER PageId
Page to return (for paging).

.PARAMETER Limit
Maximum number of results per page (0-250).

.PARAMETER IncludeDeviceMonitors
[Library mode] Return device-specific monitors. Default = 'false'.

.PARAMETER IncludeSystemMonitors
[Library mode] Return system monitors that cannot be modified. Default = 'false'.

.PARAMETER IncludeCoreMonitors
[Library mode] Return core monitors. Default = 'false'.

.EXAMPLE
Get-WUGPerformanceMonitor -Search 'Azure'

Searches the performance monitor library for monitors matching 'Azure'.

.EXAMPLE
Get-WUGPerformanceMonitor -DeviceId 3409

Returns all performance monitors assigned to device 3409.

.EXAMPLE
Get-WUGPerformanceMonitor -DeviceId 3409 -Search 'Memory'

Returns performance monitors matching 'Memory' on device 3409.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: GET /api/v1/monitors/- (library) or GET /api/v1/devices/{deviceId}/monitors/- (device)
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS
#>
function Get-WUGPerformanceMonitor {
    [CmdletBinding(DefaultParameterSetName = 'Library')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Device', ValueFromPipelineByPropertyName = $true)]
        [Alias('id')]
        [int[]]$DeviceId,

        [string]$Search,

        [string]$MonitorTypeId,

        [Parameter(ParameterSetName = 'Device')]
        [bool]$EnabledOnly = $false,

        [string]$View,

        [string]$PageId,

        [ValidateRange(0, 250)]
        [int]$Limit,

        [Parameter(ParameterSetName = 'Library')]
        [ValidateSet('true', 'false')]
        [string]$IncludeDeviceMonitors = 'false',

        [Parameter(ParameterSetName = 'Library')]
        [ValidateSet('true', 'false')]
        [string]$IncludeSystemMonitors = 'false',

        [Parameter(ParameterSetName = 'Library')]
        [ValidateSet('true', 'false')]
        [string]$IncludeCoreMonitors = 'false'
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
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Library') {
            # Library search: GET /api/v1/monitors/-?type=performance
            $qs = "type=performance"
            if ($View)                  { $qs += "&view=$View" }
            if ($IncludeDeviceMonitors) { $qs += "&includeDeviceMonitors=$IncludeDeviceMonitors" }
            if ($IncludeSystemMonitors) { $qs += "&includeSystemMonitors=$IncludeSystemMonitors" }
            if ($IncludeCoreMonitors)   { $qs += "&includeCoreMonitors=$IncludeCoreMonitors" }
            if ($Search)                { $qs += "&search=$([uri]::EscapeDataString($Search))" }
            if ($PageId)                { $qs += "&pageId=$PageId" }
            if ($Limit)                 { $qs += "&limit=$Limit" }

            $uri = "${global:WhatsUpServerBaseURI}/api/v1/monitors/-?${qs}"
            Write-Debug "GET $uri"

            try {
                $response = Get-WUGAPIResponse -Uri $uri -Method GET
                if ($response.data -and $response.data.performanceMonitors) {
                    foreach ($mon in $response.data.performanceMonitors) {
                        [PSCustomObject]@{
                            Id              = $mon.id
                            MonitorId       = $mon.monitorId
                            Name            = $mon.name
                            Description     = $mon.description
                            ClassId         = if ($mon.monitorTypeInfo) { $mon.monitorTypeInfo.classId } else { $null }
                            BaseType        = if ($mon.monitorTypeInfo) { $mon.monitorTypeInfo.baseType } else { $null }
                            MonitorTypeName = if ($mon.monitorTypeInfo) { $mon.monitorTypeInfo.name } else { $null }
                            TemplateId      = $mon.templateId
                            PropertyBags    = $mon.propertyBags
                            HasSensitiveData = $mon.hasSensitiveData
                            OwnedByDevice   = $mon.ownedByDevice
                        }
                    }
                }
            }
            catch {
                Write-Error "Failed to retrieve performance monitor library: $_"
            }
        }
        else {
            # Device assignments: GET /api/v1/devices/{deviceId}/monitors/-?type=performance
            if (-not $View) { $View = 'status' }
            foreach ($devId in $DeviceId) {
                $qs = "type=performance"
                if ($View)          { $qs += "&view=$View" }
                if ($Search)        { $qs += "&search=$([uri]::EscapeDataString($Search))" }
                if ($MonitorTypeId) { $qs += "&monitorTypeId=$MonitorTypeId" }
                $qs += "&enabledOnly=$($EnabledOnly.ToString().ToLower())"
                if ($PageId)        { $qs += "&pageId=$PageId" }
                if ($Limit)         { $qs += "&limit=$Limit" }

                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/${devId}/monitors/-?${qs}"
                Write-Debug "GET $uri"

                try {
                    $response = Get-WUGAPIResponse -Uri $uri -Method GET
                    if ($response.data) {
                        foreach ($mon in $response.data) {
                            [PSCustomObject]@{
                                DeviceId            = $devId
                                AssignmentId        = $mon.id
                                Description         = $mon.description
                                Type                = $mon.type
                                MonitorTypeId       = $mon.monitorTypeId
                                MonitorTypeClassId  = $mon.monitorTypeClassId
                                MonitorTypeName     = $mon.monitorTypeName
                                Enabled             = $mon.enabled
                                IsGlobal            = $mon.isGlobal
                                Status              = $mon.status
                                PollingIntervalMin  = if ($mon.performance) { $mon.performance.pollingIntervalMinutes } else { $null }
                                ThresholdInfo       = $mon.thresholdInfo
                            }
                        }
                    }
                }
                catch {
                    Write-Error "Failed to retrieve performance monitors for device ${devId}: $_"
                }
            }
        }
    }
}
