<#
.SYNOPSIS
Retrieves device groups and their configuration from WhatsUp Gold.

.DESCRIPTION
The `Get-WUGDeviceGroup` function retrieves device groups and their configuration from WhatsUp Gold using the REST API. It allows you to:

- Retrieve specific device groups by their `GroupId` using the `/api/v1/device-groups/{groupId}` endpoint.
- Search for device groups based on criteria such as name (`SearchValue`), group type (`GroupType`), and view level (`View`) using the `/api/v1/device-groups/-` endpoint.
- Retrieve a device group definition using the `/api/v1/device-groups/{groupId}/definition` endpoint.
- Retrieve child groups using the `/api/v1/device-groups/{groupId}/children` endpoint.
- Retrieve group status using the `/api/v1/device-groups/{groupId}/status` endpoint.
- Retrieve devices in a group using the `/api/v1/device-groups/{groupId}/devices/-` endpoint.
- Retrieve device template config using the `/api/v1/device-groups/{groupId}/devices/-/config/template` endpoint.
- Retrieve device credentials using the `/api/v1/device-groups/{groupId}/devices/-/credentials` endpoint.

The function supports pagination and handles large result sets efficiently.

.PARAMETER GroupId
Specifies one or more GroupId(s) of the device groups to retrieve. When this parameter is used, the function retrieves the specified device groups using the `/api/v1/device-groups/{groupId}` endpoint. This parameter belongs to the 'ByGroupId' parameter set.

.PARAMETER SearchValue
Specifies a search value to filter device groups by name. The function uses the `/api/v1/device-groups/-` endpoint to search for device groups whose names contain the specified value. This parameter belongs to the 'BySearch' parameter set.

.PARAMETER View
Specifies the level of detail for the device group information returned. Valid options are:

- `summary`: Returns basic information about the device groups.
- `detail`: Returns detailed information, including group type, monitor state, and device counts.

Default value is `detail`. This parameter is available in both parameter sets.

.PARAMETER GroupType
Specifies the type of device groups to retrieve. Valid options are:

- `all`: Retrieves all types of device groups.
- `static_group`: Retrieves static device groups.
- `dynamic_group`: Retrieves dynamic device groups.
- `layer2`: Retrieves Layer 2 device groups.

Default value is `all`. This parameter belongs to the 'BySearch' parameter set.

.PARAMETER Limit
Specifies the maximum number of device groups to return per page. Valid range is 1 to 250. Default is 250. This parameter belongs to the 'BySearch' parameter set.

.PARAMETER Definition
Switch to retrieve the group definition for the specified device group(s). Returns groupType, dynamicDefinition, layer2Definition, parentGroupId, name, and description via the `/api/v1/device-groups/{groupId}/definition` endpoint.

.PARAMETER Children
Switch to retrieve child groups for the specified device group(s). Supports -SearchValue, -View, -GroupType, -Limit, and -ReturnHierarchy query parameters matching the swagger /children endpoint.

.PARAMETER ReturnHierarchy
When used with -Children, returns the full group hierarchy tree instead of only immediate children. Default is $false.

.PARAMETER GroupStatus
Switch to retrieve status information for the specified device group(s).

.PARAMETER GroupDevices
Switch to retrieve devices belonging to the specified device group(s).

.PARAMETER GroupDeviceTemplates
Switch to retrieve device template configuration for devices in the specified device group(s).

.PARAMETER GroupDeviceCredentials
Switch to retrieve device credentials for devices in the specified device group(s).

.EXAMPLE
# Example 1: Retrieve specific device groups by GroupId
$groups = Get-WUGDeviceGroup -GroupId 101, 102, 103 -View 'detail'

.EXAMPLE
# Example 2: Search for device groups with "Server" in the name
$groups = Get-WUGDeviceGroup -SearchValue "Server" -GroupType "static_group" -Limit 100

.EXAMPLE
# Example 3: Get the group definition
Get-WUGDeviceGroup -ConfigGroupId 101 -Definition

.EXAMPLE
# Example 4: Get child groups
Get-WUGDeviceGroup -ConfigGroupId 0 -Children

.EXAMPLE
# Example 4b: Get child groups with search, filtering, and hierarchy
Get-WUGDeviceGroup -ConfigGroupId 0 -Children -SearchValue "Server" -GroupType static_group -View detail -ReturnHierarchy

.EXAMPLE
# Example 5: Get group status
Get-WUGDeviceGroup -ConfigGroupId 101 -GroupStatus

.EXAMPLE
# Example 6: Get devices in a group
Get-WUGDeviceGroup -ConfigGroupId 101 -GroupDevices

.NOTES
Author: Jason Alberino (jason@wug.ninja)
Created: 2023-04-15
Last Modified: 2026-03-15
Reference: 
- [WhatsUp Gold REST API - Get Device Group by ID](https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/DeviceGroup_GetDeviceGroup)
- [WhatsUp Gold REST API - List Device Groups](https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#operation/DeviceGroup_ListGroups)

This function uses parameter sets to distinguish between retrieving device groups by `GroupId` and searching with other parameters:

- **ByGroupId Parameter Set**: Uses the `/api/v1/device-groups/{groupId}` endpoint to retrieve specific device groups.
- **BySearch Parameter Set**: Uses the `/api/v1/device-groups/-` endpoint to search for device groups based on criteria.
- **Definition Parameter Set**: Uses the `/api/v1/device-groups/{groupId}/definition` endpoint to retrieve the group definition (groupType, dynamic/layer2 filters).
- **Children Parameter Set**: Uses the `/api/v1/device-groups/{groupId}/children` endpoint with optional search, view, groupType, limit, returnHierarchy, and pageId query parameters. Supports pagination.

#>
function Get-WUGDeviceGroup {
    [CmdletBinding(DefaultParameterSetName = 'BySearch')]
    param (
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByGroupId')][int[]]$GroupId,
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Definition')][Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Children')][Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'GroupStatus')][Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'GroupDevices')][Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'GroupDeviceTemplates')][Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'GroupDeviceCredentials')][int[]]$ConfigGroupId,
        [Parameter(ParameterSetName = 'BySearch')][Parameter(ParameterSetName = 'Children')][Parameter(ParameterSetName = 'GroupDevices')][Parameter(ParameterSetName = 'GroupDeviceTemplates')][Parameter(ParameterSetName = 'GroupDeviceCredentials')][string]$SearchValue,
        [Parameter(ParameterSetName = 'ByGroupId')][Parameter(ParameterSetName = 'BySearch')][Parameter(ParameterSetName = 'Children')][ValidateSet("summary", "detail")][string]$View = 'detail',
        [Parameter(ParameterSetName = 'BySearch')][Parameter(ParameterSetName = 'Children')][ValidateSet("all", "static_group", "dynamic_group", "layer2")][string]$GroupType = 'all',
        [Parameter(ParameterSetName = 'BySearch')][Parameter(ParameterSetName = 'Children')][Parameter(ParameterSetName = 'GroupDevices')][Parameter(ParameterSetName = 'GroupDeviceTemplates')][Parameter(ParameterSetName = 'GroupDeviceCredentials')][ValidateRange(1, 250)][int]$Limit = 250,
        [Parameter(ParameterSetName = 'Children')][Parameter(ParameterSetName = 'GroupDevices')][Parameter(ParameterSetName = 'GroupDeviceCredentials')][switch]$ReturnHierarchy,
        [Parameter(Mandatory = $true, ParameterSetName = 'Definition')][switch]$Definition,
        [Parameter(Mandatory = $true, ParameterSetName = 'Children')][switch]$Children,
        [Parameter(Mandatory = $true, ParameterSetName = 'GroupStatus')][switch]$GroupStatus,
        [Parameter(Mandatory = $true, ParameterSetName = 'GroupDevices')][switch]$GroupDevices,
        [Parameter(ParameterSetName = 'GroupDevices')][ValidateSet("id", "basic", "card", "overview")][string]$GroupDevicesView = 'card',
        [Parameter(ParameterSetName = 'GroupDevices')][ValidateSet("Unknown", "Up", "Down", "Maintenance", "Any", "UpWithDownMonitors")][string]$State,
        [Parameter(Mandatory = $true, ParameterSetName = 'GroupDeviceTemplates')][switch]$GroupDeviceTemplates,
        [Parameter(ParameterSetName = 'GroupDeviceTemplates')][switch]$IncludeHierarchy,
        [Parameter(ParameterSetName = 'GroupDeviceTemplates')][ValidateSet("all", "clone", "transfer", "update")][string]$TemplateOptions,
        [Parameter(Mandatory = $true, ParameterSetName = 'GroupDeviceCredentials')][switch]$GroupDeviceCredentials,
        [Parameter(ParameterSetName = 'GroupDeviceCredentials')][ValidateSet("id", "basic", "summary", "details")][string]$DeviceView,
        [Parameter(ParameterSetName = 'GroupDeviceCredentials')][ValidateSet("id", "basic", "summary", "details")][string]$CredentialView,
        [Parameter(ParameterSetName = 'GroupDeviceCredentials')][ValidateSet("all", "snmpV1", "snmpV2", "snmpV3", "windows", "ado", "telnet", "ssh", "vmware", "jmx", "smis", "aws", "azure", "meraki", "restapi", "ubiquiti", "redfish")][string]$CredentialType
    )

    begin {
        Write-Debug "Initializing Get-WUGDeviceGroup function."
        Write-Debug "ParameterSetName: $($PSCmdlet.ParameterSetName)"
        Write-Debug "GroupId: $GroupId"
        Write-Debug "SearchValue: $SearchValue"
        Write-Debug "View: $View"
        Write-Debug "GroupType: $GroupType"
        Write-Debug "Limit: $Limit"
        # Initialize the output collection
        $allGroups = @()
        # Base URI
        $baseUri = "${global:WhatsUpServerBaseURI}/api/v1/device-groups"
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ByGroupId') {
            Write-Debug "ParameterSet: ByGroupId"

            $totalGroups = $GroupId.Count
            $currentGroupIndex = 0

            foreach ($id in $GroupId) {
                $currentGroupIndex++
                $percentComplete = [Math]::Round(($currentGroupIndex / $totalGroups) * 100)

                Write-Progress -Activity "Fetching group information" -Status "Processing Group ID $id ($currentGroupIndex of $totalGroups)" -PercentComplete $percentComplete

                # Construct the URI for each group ID
                $uri = "${baseUri}/${id}?view=${View}"
                Write-Debug "Fetching group info from URI: $uri"

                # Make the API request
                try {
                    $response = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    $deviceGroup = $response.data

                    # Format the output object based on the 'View' parameter
                    if ($View -eq 'detail') {
                        $groupObject = [PSCustomObject]@{
                            Id                    = $deviceGroup.id
                            ParentGroupId         = $deviceGroup.parentGroupId
                            Name                  = $deviceGroup.name
                            Description           = $deviceGroup.description
                            GroupType             = $deviceGroup.details.groupType
                            MonitorState          = $deviceGroup.details.monitorState
                            ChildrenCount         = $deviceGroup.details.childrenCount
                            DeviceChildrenCount   = $deviceGroup.details.deviceChildrenCount
                            DeviceDescendantCount = $deviceGroup.details.deviceDescendantCount
                        }
                    }
                    else {
                        $groupObject = [PSCustomObject]@{
                            Id            = $deviceGroup.id
                            ParentGroupId = $deviceGroup.parentGroupId
                            Name          = $deviceGroup.name
                        }
                    }

                    # Add the group object to the output collection
                    $allGroups += $groupObject
                }
                catch {
                    Write-Error "Error getting device group with ID ${id}: $_"
                }
            }

            # Clear progress
            Write-Progress -Activity "Fetching group information" -Completed
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'BySearch') {
            Write-Debug "ParameterSet: BySearch"

            # Build query parameters
            $queryParams = @{}
            if ($View) { $queryParams['view'] = $View }
            if ($SearchValue) { $queryParams['search'] = $SearchValue }
            if ($GroupType) { $queryParams['groupType'] = $GroupType }
            if ($Limit) { $queryParams['limit'] = $Limit }

            # Build the query string
            $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
            $searchUri = "${baseUri}/-?$queryString"
            Write-Debug "Search URI: $searchUri"

            $currentPageId = $null
            $pageNumber = 0

            do {
                # Check if there is a current page ID and modify the URI accordingly
                if ($null -ne $currentPageId) {
                    $currentUri = "$searchUri&pageId=$currentPageId"
                }
                else {
                    $currentUri = $searchUri
                }

                Write-Debug "Fetching groups from URI: $currentUri"

                try {
                    $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'
                    Write-Debug "Result from Get-WUGAPIResponse: $result"

                    if ($null -ne $result.data.groups) {
                        foreach ($group in $result.data.groups) {
                            if ($View -eq 'detail') {
                                $groupObject = [PSCustomObject]@{
                                    Id                    = $group.id
                                    ParentGroupId         = $group.parentGroupId
                                    Name                  = $group.name
                                    Description           = $group.description
                                    GroupType             = $group.details.groupType
                                    MonitorState          = $group.details.monitorState
                                    ChildrenCount         = $group.details.childrenCount
                                    DeviceChildrenCount   = $group.details.deviceChildrenCount
                                    DeviceDescendantCount = $group.details.deviceDescendantCount
                                }
                            }
                            else {
                                $groupObject = [PSCustomObject]@{
                                    Id            = $group.id
                                    ParentGroupId = $group.parentGroupId
                                    Name          = $group.name
                                }
                            }
                            $allGroups += $groupObject
                        }
                    }

                    $currentPageId = $result.paging.nextPageId
                    $pageNumber++

                    # Update progress
                    if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                        $percentComplete = ($pageNumber / $result.paging.totalPages) * 100
                        Write-Progress -Activity "Retrieving device groups" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete $percentComplete
                    } else {
                        Write-Progress -Activity "Retrieving device groups" -Status "Processing page $pageNumber" -PercentComplete (($pageNumber % 100))
                    }
                }
                catch {
                    Write-Error "Error fetching device groups: $_"
                    break # Ensure exit from loop on error
                }
            } while ($null -ne $currentPageId)

            # Clear progress
            Write-Progress -Activity "Retrieving device groups" -Completed
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Definition') {
            Write-Debug "ParameterSet: Definition"
            foreach ($gid in $ConfigGroupId) {
                $uri = "${baseUri}/${gid}/definition"
                Write-Debug "Fetching group definition from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) {
                        $result.data | Add-Member -NotePropertyName 'groupId' -NotePropertyValue $gid -Force
                        $allGroups += $result.data
                    }
                }
                catch {
                    Write-Error "Error fetching definition for group ${gid}: $_"
                }
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Children') {
            Write-Debug "ParameterSet: Children"
            foreach ($gid in $ConfigGroupId) {
                # Build query parameters matching swagger: search, view, returnHierarchy, groupType, limit, pageId
                $queryParams = @{}
                if ($View)        { $queryParams['view']      = $View }
                if ($SearchValue) { $queryParams['search']    = $SearchValue }
                if ($GroupType)   { $queryParams['groupType'] = $GroupType }
                if ($Limit)       { $queryParams['limit']     = $Limit }
                if ($ReturnHierarchy) { $queryParams['returnHierarchy'] = 'true' }

                $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
                $childrenBaseUri = "${baseUri}/${gid}/children"
                if ($queryString) { $childrenBaseUri += "?$queryString" }

                Write-Debug "Fetching children from URI: $childrenBaseUri"

                $currentPageId = $null
                $pageNumber = 0

                do {
                    $currentUri = if ($null -ne $currentPageId) {
                        $sep = if ($childrenBaseUri -match '\?') { '&' } else { '?' }
                        "${childrenBaseUri}${sep}pageId=$currentPageId"
                    } else { $childrenBaseUri }

                    try {
                        $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'

                        if ($null -ne $result.data.groups) {
                            foreach ($group in $result.data.groups) {
                                if ($View -eq 'detail') {
                                    $groupObject = [PSCustomObject]@{
                                        Id                    = $group.id
                                        ParentGroupId         = $group.parentGroupId
                                        Name                  = $group.name
                                        Description           = $group.description
                                        GroupType             = $group.details.groupType
                                        MonitorState          = $group.details.monitorState
                                        ChildrenCount         = $group.details.childrenCount
                                        DeviceChildrenCount   = $group.details.deviceChildrenCount
                                        DeviceDescendantCount = $group.details.deviceDescendantCount
                                    }
                                }
                                else {
                                    $groupObject = [PSCustomObject]@{
                                        Id            = $group.id
                                        ParentGroupId = $group.parentGroupId
                                        Name          = $group.name
                                    }
                                }
                                $allGroups += $groupObject
                            }
                        }
                        elseif ($result.data) {
                            $allGroups += $result.data
                        }

                        $currentPageId = $result.paging.nextPageId
                        $pageNumber++

                        if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                            Write-Progress -Activity "Retrieving children of group $gid" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete (($pageNumber / $result.paging.totalPages) * 100)
                        }
                    }
                    catch {
                        Write-Error "Error fetching children for group ${gid}: $_"
                        break
                    }
                } while ($null -ne $currentPageId)

                Write-Progress -Activity "Retrieving children of group $gid" -Completed
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'GroupStatus') {
            Write-Debug "ParameterSet: GroupStatus"
            foreach ($gid in $ConfigGroupId) {
                $uri = "${baseUri}/${gid}/status"
                Write-Debug "Fetching status from URI: $uri"
                try {
                    $result = Get-WUGAPIResponse -Uri $uri -Method 'GET'
                    if ($result.data) {
                        $result.data | Add-Member -NotePropertyName 'groupId' -NotePropertyValue $gid -Force
                        $allGroups += $result.data
                    }
                }
                catch {
                    Write-Error "Error fetching status for group ${gid}: $_"
                }
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'GroupDevices') {
            Write-Debug "ParameterSet: GroupDevices"
            foreach ($gid in $ConfigGroupId) {
                $queryParams = @{}
                if ($GroupDevicesView)  { $queryParams['view']            = $GroupDevicesView }
                if ($SearchValue)     { $queryParams['search']          = $SearchValue }
                if ($State)           { $queryParams['state']           = $State }
                if ($Limit)           { $queryParams['limit']           = $Limit }
                if ($ReturnHierarchy) { $queryParams['returnHierarchy'] = 'true' }

                $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
                $devicesBaseUri = "${baseUri}/${gid}/devices/-"
                if ($queryString) { $devicesBaseUri += "?$queryString" }

                Write-Debug "Fetching devices from URI: $devicesBaseUri"

                $currentPageId = $null
                $pageNumber = 0

                do {
                    $currentUri = if ($null -ne $currentPageId) {
                        $sep = if ($devicesBaseUri -match '\?') { '&' } else { '?' }
                        "${devicesBaseUri}${sep}pageId=$currentPageId"
                    } else { $devicesBaseUri }

                    try {
                        $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'
                        if ($result.data.devices) { $allGroups += $result.data.devices }
                        elseif ($result.data) { $allGroups += $result.data }

                        $currentPageId = $result.paging.nextPageId
                        $pageNumber++

                        if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                            Write-Progress -Activity "Retrieving devices in group $gid" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete (($pageNumber / $result.paging.totalPages) * 100)
                        }
                    }
                    catch {
                        Write-Error "Error fetching devices for group ${gid}: $_"
                        break
                    }
                } while ($null -ne $currentPageId)

                Write-Progress -Activity "Retrieving devices in group $gid" -Completed
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'GroupDeviceTemplates') {
            Write-Debug "ParameterSet: GroupDeviceTemplates"
            foreach ($gid in $ConfigGroupId) {
                $queryParams = @{}
                if ($SearchValue)      { $queryParams['search']           = $SearchValue }
                if ($TemplateOptions)  { $queryParams['options']          = $TemplateOptions }
                if ($Limit)            { $queryParams['limit']            = $Limit }
                if ($IncludeHierarchy) { $queryParams['includeHierarchy'] = 'true' }

                $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
                $templatesBaseUri = "${baseUri}/${gid}/devices/-/config/template"
                if ($queryString) { $templatesBaseUri += "?$queryString" }

                Write-Debug "Fetching device templates from URI: $templatesBaseUri"

                $currentPageId = $null
                $pageNumber = 0

                do {
                    $currentUri = if ($null -ne $currentPageId) {
                        $sep = if ($templatesBaseUri -match '\?') { '&' } else { '?' }
                        "${templatesBaseUri}${sep}pageId=$currentPageId"
                    } else { $templatesBaseUri }

                    try {
                        $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'
                        if ($result.data) { $allGroups += $result.data }

                        $currentPageId = $result.paging.nextPageId
                        $pageNumber++

                        if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                            Write-Progress -Activity "Retrieving device templates in group $gid" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete (($pageNumber / $result.paging.totalPages) * 100)
                        }
                    }
                    catch {
                        Write-Error "Error fetching device templates for group ${gid}: $_"
                        break
                    }
                } while ($null -ne $currentPageId)

                Write-Progress -Activity "Retrieving device templates in group $gid" -Completed
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'GroupDeviceCredentials') {
            Write-Debug "ParameterSet: GroupDeviceCredentials"
            foreach ($gid in $ConfigGroupId) {
                $queryParams = @{}
                if ($SearchValue)      { $queryParams['search']          = $SearchValue }
                if ($DeviceView)       { $queryParams['deviceView']      = $DeviceView }
                if ($CredentialView)   { $queryParams['credentialView']  = $CredentialView }
                if ($CredentialType)   { $queryParams['type']            = $CredentialType }
                if ($Limit)            { $queryParams['limit']           = $Limit }
                if ($ReturnHierarchy)  { $queryParams['returnHierarchy'] = 'true' }

                $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
                $credentialsBaseUri = "${baseUri}/${gid}/devices/-/credentials"
                if ($queryString) { $credentialsBaseUri += "?$queryString" }

                Write-Debug "Fetching device credentials from URI: $credentialsBaseUri"

                $currentPageId = $null
                $pageNumber = 0

                do {
                    $currentUri = if ($null -ne $currentPageId) {
                        $sep = if ($credentialsBaseUri -match '\?') { '&' } else { '?' }
                        "${credentialsBaseUri}${sep}pageId=$currentPageId"
                    } else { $credentialsBaseUri }

                    try {
                        $result = Get-WUGAPIResponse -Uri $currentUri -Method 'GET'
                        if ($result.data) { $allGroups += $result.data }

                        $currentPageId = $result.paging.nextPageId
                        $pageNumber++

                        if ($null -ne $result.paging.totalPages -and $result.paging.totalPages -gt 0) {
                            Write-Progress -Activity "Retrieving device credentials in group $gid" -Status "Page $pageNumber of $($result.paging.totalPages)" -PercentComplete (($pageNumber / $result.paging.totalPages) * 100)
                        }
                    }
                    catch {
                        Write-Error "Error fetching device credentials for group ${gid}: $_"
                        break
                    }
                } while ($null -ne $currentPageId)

                Write-Progress -Activity "Retrieving device credentials in group $gid" -Completed
            }
        }
        else {
            Write-Error "Invalid parameter set."
        }
    }

    end {
        Write-Debug "Completed Get-WUGDeviceGroup function"
        return $allGroups
    }
}
# End of Get-WUGDeviceGroup function
# End of script
#------------------------------------------------------------------
# This script is part of the WhatsUpGoldPS PowerShell module.
# It is designed to interact with the WhatsUp Gold API for network monitoring.
# The script is provided as-is and is not officially supported by WhatsUp Gold.
# Use at your own risk.
#------------------------------------------------------------------

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBchf617zk2uclk
# ikYDDzOUWZZi2PbeFnWk4WAq6YIBDqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgubMKaxc+Fvwqm17SFPMc/3CZmrjo/rsm
# ImEubvT1jaAwDQYJKoZIhvcNAQEBBQAEggIAnL/12Z4Fk3lCKCAsWZZXihKyj9Vr
# P6PNe+AOGtl55m9DtNjBZEg1wY2eAdAXtg7VUlRBW96yQRZ0NCC0XJFnfbs2dygd
# ad+N+iuKRBbvr2YRV1xIxIedqL5zZ5H8qwX1qSpiVmBgO2yuw8vh78z2vcsbTCQh
# FRyv0eYzzAd2Nx8ukUNCxhebyQJ6svdZMfOLxka3s8tdu5sjW5AoYoiipcb4uCZY
# bJYmf32PBPsjlEN61lSHFgLDRWQqw1HlTVx8Ld/3fS4QtfLVLDEa0vyF4gI2ZTGp
# nKaqBIIFWsGzlgixYG3JzbRtUja6Vqmf6WTPt1x5wNfolnNRL/D97xBbzzm0h2Ei
# s+TaySzhh/Ncb6+vFoAGmntMzXt+GKaMFxEHG/NldQcJ37za/PRzkHfcZL+fNB6a
# upTWbI0wW8WD9873/wEyqMc0g3vqG9m01Ii5eYLgQ8HJzsjJAjiXP2VioEehVZgs
# YVkO7d3Wf9+FPtU+ttBatuDtfTDR1FNZO8KXsIlVNbfUeR633u3XFSM2TJ+utfHF
# 4GH1omp6IEB3YZGXJ/IwWV8uT0XHxcQ28detwZuf2mTkxyijawGw46gxBIvn1o+1
# lCTeWdLu8wMRw3Z71FErgL1+q+r7x3nnWSWKW74LF5NTbJorKeIq1sidpgyJwYXH
# eg1nKkwydozhQ60=
# SIG # End signature block
