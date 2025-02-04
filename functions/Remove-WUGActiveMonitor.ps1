# Broken API?
# Example: Delete all active monitors containing 'ROC-Mon' in their name
#Remove-WUGActiveMonitor -Search "ROC-Mon" -IncludeDeviceMonitors $true -IncludeSystemMonitors $false -FailIfInUse $false
function Remove-WUGActiveMonitor {
    [CmdletBinding()]
    param(
        # Mandatory search parameter to delete specific monitors
        [Parameter(Mandatory = $true)]
        [string]$Search,

        # Optional parameters for monitor deletion behavior
        [Parameter()]
        [bool]$IncludeDeviceMonitors = $false,

        [Parameter()]
        [bool]$IncludeSystemMonitors = $false,

        [Parameter()]
        [bool]$FailIfInUse = $true
    )

    begin {
        Write-Debug "Initializing Remove-WUGActiveMonitors function with search term: '$Search'"

        # Ensure the base URI is correctly set from the global configuration
        $baseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"

        # Build the query string using the provided parameters
        $queryString = "type=active&"  # Always set to 'active' monitor type
        $queryString += "search=$([uri]::EscapeDataString($Search))&"

        if ($IncludeDeviceMonitors) { 
            $queryString += "includeDeviceMonitors=true&" 
        }
        if ($IncludeSystemMonitors) { 
            $queryString += "includeSystemMonitors=true&" 
        }
        if (-not $FailIfInUse) { 
            $queryString += "failIfInUse=false&" 
        }

        # Trim the trailing '&' from the query string
        $queryString = $queryString.TrimEnd('&')

        # Construct the final URI with the base and query string
        $uri = "${baseUri}?${queryString}"
        Write-Verbose "Constructed URI: $uri"
    }

    process {
        Write-Host "Deleting monitors matching the search query: '$Search'" -ForegroundColor Cyan

        try {
            # Perform the DELETE request to the WUG API
            $result = Get-WUGAPIResponse -Uri $uri -Method DELETE

            # Handle the response
            if ($result.data.successful -gt 0) {
                Write-Host "Successfully deleted $($result.data.successful) monitor(s)." -ForegroundColor Green
            }
            elseif ($result.data.errors) {
                Write-Warning "Errors occurred while deleting monitors:"
                foreach ($error in $result.data.errors) {
                    Write-Warning "TemplateId: $($error.templateId) - Messages: $($error.messages -join ', ')"
                }
            }
            else {
                Write-Host "No monitors were deleted." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Error "Error deleting monitors: $($_.Exception.Message)"
        }
    }

    end {
        Write-Debug "Remove-WUGActiveMonitors function completed."
    }
}


