<#
.SYNOPSIS
    Creates multiple monitors in the WhatsUp Gold library in a single bulk API call.

.DESCRIPTION
    Add-WUGMonitorTemplate uses the PATCH /api/v1/monitors/-/config/template endpoint
    to create active, passive, and/or performance monitors in the WUG monitor library
    in one request. Each monitor template includes its name, classId, monitorTypeInfo,
    and propertyBags. This is significantly faster than creating monitors one at a time
    when you have many monitors to create.

.PARAMETER ActiveMonitors
    An array of active monitor template objects. Each object should contain:
      - name            (string)  Monitor display name
      - templateId      (string)  Caller-provided unique ID for result mapping
      - monitorTypeInfo (object)  { name, classId, baseType = "active" }
      - propertyBags    (array)   [ { name, value }, ... ]
    Optional fields: description, useInDiscovery, hasSensitiveData.

.PARAMETER PerformanceMonitors
    An array of performance monitor template objects. Each object should contain:
      - name            (string)  Monitor display name
      - templateId      (string)  Caller-provided unique ID for result mapping
      - monitorTypeInfo (object)  { name, classId, baseType = "performance" }
      - propertyBags    (array)   [ { name, value }, ... ]
    Optional fields: description, hasSensitiveData.

.PARAMETER PassiveMonitors
    An array of passive monitor template objects. Each object should contain:
      - name            (string)  Monitor display name
      - templateId      (string)  Caller-provided unique ID for result mapping
      - monitorTypeInfo (object)  { name, classId }
      - propertyBags    (array)   [ { name, value }, ... ]
    Optional fields: description.

.EXAMPLE
    $activeTemplates = @(
        @{
            templateId      = 'health-1'
            name            = 'Azure Health - myvm'
            description     = 'REST API health check'
            useInDiscovery  = $false
            monitorTypeInfo = @{ classId = 'f0610672-d515-4268-bd21-ac5ebb1476ff'; baseType = 'active' }
            propertyBags    = @(
                @{ name = 'MonRestApi:RestUrl'; value = 'https://management.azure.com/...' },
                @{ name = 'MonRestApi:HttpMethod'; value = 'GET' }
            )
        }
    )
    Add-WUGMonitorTemplate -ActiveMonitors $activeTemplates

.EXAMPLE
    $perfTemplates = @(
        @{
            templateId      = 'perf-1'
            name            = 'Azure - vaults - myvault - Api Hits'
            monitorTypeInfo = @{ classId = '987bb6a4-70f4-4f46-97c6-1c9dd1766437'; baseType = 'performance' }
            propertyBags    = @(
                @{ name = 'RdcRestApi:RestUrl'; value = 'https://...' },
                @{ name = 'RdcRestApi:JsonPath'; value = '$.value[0].timeseries[0].data[-1:].total' }
            )
        }
    )
    Add-WUGMonitorTemplate -PerformanceMonitors $perfTemplates

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: PATCH /api/v1/monitors/-/config/template
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS

.LINK
    https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/#tag/Monitor-Config
#>
function Add-WUGMonitorTemplate {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter()]
        [array]$ActiveMonitors,

        [Parameter()]
        [array]$PerformanceMonitors,

        [Parameter()]
        [array]$PassiveMonitors
    )

    # Validate at least one monitor array is provided
    $totalCount = 0
    if ($ActiveMonitors) { $totalCount += $ActiveMonitors.Count }
    if ($PerformanceMonitors) { $totalCount += $PerformanceMonitors.Count }
    if ($PassiveMonitors) { $totalCount += $PassiveMonitors.Count }

    if ($totalCount -eq 0) {
        Write-Warning "No monitor templates provided. Specify at least one of -ActiveMonitors, -PerformanceMonitors, or -PassiveMonitors."
        return
    }

    # Global variables error checking
    if (-not $global:WUGBearerHeaders) {
        Write-Error -Message "Authorization header not set. Please run Connect-WUGServer first."
        return
    }
    if (-not $global:WhatsUpServerBaseURI) {
        Write-Error -Message "Base URI not found. Please run Connect-WUGServer first."
        return
    }

    # Build the request body
    $bodyObj = @{}
    if ($ActiveMonitors) { $bodyObj['activeMonitors'] = @($ActiveMonitors) }
    if ($PerformanceMonitors) { $bodyObj['performanceMonitors'] = @($PerformanceMonitors) }
    if ($PassiveMonitors) { $bodyObj['passiveMonitors'] = @($PassiveMonitors) }

    $body = $bodyObj | ConvertTo-Json -Depth 10

    Write-Debug "Bulk monitor template body: $body"

    $desc = @()
    if ($ActiveMonitors) { $desc += "$($ActiveMonitors.Count) active" }
    if ($PerformanceMonitors) { $desc += "$($PerformanceMonitors.Count) performance" }
    if ($PassiveMonitors) { $desc += "$($PassiveMonitors.Count) passive" }
    $descStr = $desc -join ', '

    if (-not $PSCmdlet.ShouldProcess("$descStr monitor template(s)", 'Create monitors from templates')) { return }

    try {
        $result = Get-WUGAPIResponse -Uri "${global:WhatsUpServerBaseURI}/api/v1/monitors/-/config/template" -Method "PATCH" -Body $body
        return $result.data
    }
    catch {
        Write-Error "Error creating monitor templates: $($_.Exception.Message)"
        Write-Debug "Full exception: $($_.Exception | Format-List * | Out-String)"
    }
}
# End of Add-WUGMonitorTemplate function
