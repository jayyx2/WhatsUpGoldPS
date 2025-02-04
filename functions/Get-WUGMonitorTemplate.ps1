function Get-WUGMonitorTemplate {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter()]
        [ValidateSet('all', 'active', 'performance', 'passive')]
        [string]$Type,

        [Parameter()]
        [string]$Search,

        [Parameter()]
        [ValidateSet('id', 'basic', 'info', 'summary', 'details')]
        [string]$View = 'info',

        [Parameter()]
        [string]$PageId,

        [Parameter()]
        [int]$Limit = 250,

        [Parameter()]
        [switch]$IncludeDeviceMonitors,

        [Parameter()]
        [switch]$IncludeSystemMonitors,

        [Parameter()]
        [switch]$IncludeCoreMonitors,

        [Parameter()]
        [switch]$AllMonitors
    )

    begin {
        Write-Debug "Initializing Get-WUGMonitorTemplate function."
        Write-Debug "ParameterSetName: $($PSCmdlet.ParameterSetName)"
        Write-Debug "Type: $Type"
        Write-Debug "Search: $Search"
        Write-Debug "View: $View"
        Write-Debug "PageId: $PageId"
        Write-Debug "Limit: $Limit"
        Write-Debug "IncludeDeviceMonitors: $IncludeDeviceMonitors"
        Write-Debug "IncludeSystemMonitors: $IncludeSystemMonitors"
        Write-Debug "IncludeCoreMonitors: $IncludeCoreMonitors"
        Write-Debug "AllMonitors: $AllMonitors"

        # Initialize the pipeline flag
        $bpipeline = $false
        # Initialize collection for final output
        $finalOutput = @()
        $baseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"
    }

    process {
        # Build the query string based on provided parameters
        $queryString = ""
        if ($PSBoundParameters.ContainsKey('Type') -and ![string]::IsNullOrWhiteSpace($Type)) {
            $queryString += "type=$([uri]::EscapeDataString($Type))&"
        }
        if ($PSBoundParameters.ContainsKey('Search') -and ![string]::IsNullOrWhiteSpace($Search)) {
            $queryString += "search=$([uri]::EscapeDataString($Search))&"
        }
        if ($PSBoundParameters.ContainsKey('View') -and ![string]::IsNullOrWhiteSpace($View)) {
            $queryString += "view=$([uri]::EscapeDataString($View))&"
        }
        if ($PSBoundParameters.ContainsKey('PageId') -and ![string]::IsNullOrWhiteSpace($PageId)) {
            $queryString += "pageId=$([uri]::EscapeDataString($PageId))&"
        }
        if ($PSBoundParameters.ContainsKey('Limit') -and $Limit -gt 0) {
            $queryString += "limit=$([uri]::EscapeDataString(${Limit}.ToString()))&"
        }
        if ($IncludeDeviceMonitors) {
            $queryString += "includeDeviceMonitors=true&"
        }
        if ($IncludeSystemMonitors) {
            $queryString += "includeSystemMonitors=true&"
        }
        if ($IncludeCoreMonitors) {
            $queryString += "includeCoreMonitors=true&"
        }
        if ($AllMonitors) {
            $queryString += "allMonitors=true&"
        }

        # Trim the trailing '&' if it exists
        $queryString = $queryString.TrimEnd('&')
        
        # Construct the URI
        $monitorsUri = $baseUri
        if (-not [string]::IsNullOrWhiteSpace($queryString)) {
            $monitorsUri += "?$queryString"
        }

        Write-Verbose "Requesting URI: $monitorsUri"

        try {
            # Make the API call and retrieve the response
            $result = Get-WUGAPIResponse -Uri $monitorsUri -Method GET
            if ($result.data) {
                if ($result.data.activeMonitors) {
                    foreach ($monitor in $result.data.activeMonitors) {
                        $finalOutput += $monitor
                    }
                }
                if ($result.data.passiveMonitors) {
                    foreach ($monitor in $result.data.passiveMonitors) {
                        $finalOutput += $monitor
                    }
                }
                if ($result.data.performanceMonitors) {
                    foreach ($monitor in $result.data.performanceMonitors) {
                        $finalOutput += $monitor
                    }
                }
            }
        }
        catch {
            Write-Error "Error fetching monitor templates: $($_.Exception.Message)"
        }
    }

    end {
        Write-Debug "Get-WUGMonitorTemplate function completed."
        # Output the final data
        return $finalOutput
    }
}