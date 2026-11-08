<#
.SYNOPSIS
    Redfish discovery provider for WhatsUpGoldPS.

.DESCRIPTION
    Discovers server hardware through the DMTF Redfish API exposed by BMCs such as
    HPE iLO, Dell iDRAC, and Lenovo XCC, and builds a WhatsUp Gold monitor plan from
    what the board reports: system, chassis and component health, power state,
    power draw, temperature sensors, and fans.

    Everything is expressed as WhatsUp Gold REST API monitors rather than the native
    Redfish monitor type. That choice is measured, not stylistic: the native type
    resolved only four subsystems on iLO 4 (system, chassis, temperature, fan) and
    returned Unknown for processors, memory, disks and power supplies regardless of
    the assignment argument, because iLO 4 publishes those as vendor types such as
    HpMemory and HpSmartStorageDiskDrive rather than the standard Redfish schema.
    REST API monitors read the JSON directly and so cover every component.

    Monitor URLs use the %Device.Address percent variable, so one library monitor
    serves every BMC of the same model instead of one set per host. Note there is no
    closing percent: %Device.Address% does not expand and the monitor fails.

    Authentication comes from a REST API credential assigned to the device, so no
    Authorization header is stored in the monitor definition.

    Schema differences are handled rather than assumed. iLO 4 reports Redfish 1.0.0,
    where a fan is `FanName`/`CurrentReading` instead of `Name`/`Reading`, component
    roll-ups are `Status.HealthRollUp` while leaf resources use `Status.Health`, and
    a DIMM reports `DIMMStatus` rather than a Status block.

    Sensor counts are capped. A single Gen9 chassis exposes 37 temperature sensors,
    which would otherwise turn into 37 monitors per server.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Verified against: HPE ProLiant DL360 Gen9, iLO 4 v2.82, Redfish 1.0.0
#>

# Caps applied per chassis so a large sensor list cannot flood the monitor library.
$script:RedfishMaxTempSensors = 12
$script:RedfishMaxFans = 8
$script:RedfishMaxDisks = 12
$script:RedfishMaxPsus = 4

# WUG expands this at poll time; the absence of a closing percent is deliberate.
$script:RedfishAddressToken = '%Device.Address'

# A comparison entry is a DOWN condition. ComparisonType 3 is "does not contain",
# so this reads: report down when the value is not the expected one.
function New-RedfishDownIfNot {
    <#
    .SYNOPSIS
        Builds a WUG ComparisonList that trips when a JSON value is not as expected.
    .DESCRIPTION
        The property is CompareValue; ComparisonValue and Value are both silently
        ignored by the API and leave the monitor permanently down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $entry = '{"JsonPathQuery":"' + $JsonPath + '","AttributeType":1,"ComparisonType":3,"CompareValue":"' + $Expected + '"}'
    return "[$entry]"
}


function Get-RedfishValue {
    <#
    .SYNOPSIS
        Reads the first property that exists from a list of candidate names.
    .DESCRIPTION
        Redfish property names moved between schema versions, so each value is
        looked up through the names used by both the current and legacy shapes.
    #>
    [CmdletBinding()]
    param(
        # Not mandatory: most walked resources legitimately lack the parent object.
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        $prop = $InputObject.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { return $prop.Value }
    }
    return $Default
}

function Get-RedfishHealth {
    <#
    .SYNOPSIS
        Returns a Status block's health, tolerating the legacy HealthRollUp spelling.
    #>
    [CmdletBinding()]
    param($Status)

    return [string](Get-RedfishValue -InputObject $Status -Names @('Health', 'HealthRollUp', 'HealthRollup') -Default '')
}

function Invoke-RedfishRequest {
    <#
    .SYNOPSIS
        Performs a GET against a Redfish endpoint using Basic authentication.
    .PARAMETER BaseUri
        Scheme and host of the BMC, for example https://10.0.0.5.
    .PARAMETER Path
        Absolute Redfish path or a full URL.
    .PARAMETER AuthHeader
        Pre-built Basic authorization header value.
    .PARAMETER TimeoutSec
        Per-request timeout. BMCs are slow, so this defaults generously.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AuthHeader,
        [int]$TimeoutSec = 30
    )

    $uri = if ($Path -like 'http*') { $Path } else { "$BaseUri$Path" }
    # OData-Version suppresses iLO 4's case-colliding legacy properties in JSON responses.
    $headers = @{ Authorization = $AuthHeader; Accept = 'application/json'; 'OData-Version' = '4.0' }
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
}

function Get-RedfishVendorProfile {
    <#
    .SYNOPSIS
        Returns the quirks for a BMC vendor.

    .DESCRIPTION
        Vendors diverge in where they hang sub-resources and what they call fields.
        Rather than special-casing vendors throughout the provider, the differences are
        collected here and the rest of the code reads the profile.

    .PARAMETER ServiceRoot
        The parsed /redfish/v1/ document.

    .EXAMPLE
        $vp = Get-RedfishVendorProfile -ServiceRoot $root
        $vp.Vendor
    #>
    [CmdletBinding()]
    param($ServiceRoot)

    $oemKeys = @()
    if ($ServiceRoot -and $ServiceRoot.Oem) { $oemKeys = @($ServiceRoot.Oem.PSObject.Properties.Name) }
    $vendorKey = ($oemKeys | Select-Object -First 1)

    $vp = [ordered]@{
        Vendor       = if ($vendorKey) { [string]$vendorKey } else { 'Unknown' }
        Family       = 'Generic'
        # Paths worth probing directly because some firmware does not link them.
        ExtraPaths   = @()
        # Branches that are large and carry no monitoring value.
        SkipPattern  = '/JsonSchemas|/Registries|/LogServices/[^/]+/Entries|/SessionService/Sessions|/AccountService|/Tasks|/UpdateService|\$metadata|/Schemas|/Sessions'
        # Type names for the same component differ per vendor, so each concept lists its aliases.
        ProcessorType = @('Processor')
        MemoryType    = @('Memory', 'HpMemory', 'DellMemory')
        DriveType     = @('Drive', 'HpSmartStorageDiskDrive', 'PhysicalDrive')
        VolumeType    = @('Volume', 'HpSmartStorageLogicalDrive', 'LogicalDrive')
        ControllerType = @('Storage', 'StorageController', 'HpSmartStorageArrayController')
        PsuType       = @('PowerSupply', 'HpPowerSupply')
    }

    switch -Regex ($vp.Vendor) {
        '^Hp' {
            $vp.Family = 'HPE'
            # iLO hides the interesting collections behind Oem.Hp.links rather than @odata.id.
            $vp.ExtraPaths = @(
                '/redfish/v1/Systems/1/Processors/'
                '/redfish/v1/Systems/1/Memory/'
                '/redfish/v1/Systems/1/SmartStorage/ArrayControllers/'
                '/redfish/v1/Systems/1/NetworkAdapters/'
                '/redfish/v1/Systems/1/PCIDevices/'
            )
        }
        '^Dell' {
            $vp.Family = 'Dell'
            # iDRAC links Storage conventionally but buries the per-controller drives.
            $vp.ExtraPaths = @('/redfish/v1/Systems/System.Embedded.1/Storage/')
        }
        '^Lenovo' { $vp.Family = 'Lenovo' }
        '^Supermicro' { $vp.Family = 'Supermicro' }
        default { $vp.Family = 'Generic' }
    }

    return [PSCustomObject]$vp
}

function Invoke-RedfishWalk {
    <#
    .SYNOPSIS
        Walks a Redfish service and returns every resource it can reach.

    .DESCRIPTION
        Equivalent in spirit to an SNMP walk: start at the service root and follow every
        reference until the tree is exhausted.

        Redfish 1.0 firmware such as iLO 4 links most of its tree through legacy
        "href" entries rather than "@odata.id", so both styles are followed. Without that,
        a walk of a DL360 Gen9 reaches 30 resources and misses processors, memory and
        storage entirely.

        Paths are compared case-insensitively because the same resource is published with
        different casing on some firmware.

    .PARAMETER BaseUri
        Scheme and host of the BMC.

    .PARAMETER AuthHeader
        Basic authorization header value.

    .PARAMETER VendorProfile
        Vendor profile from Get-RedfishVendorProfile, supplying skip patterns and extra paths.

    .PARAMETER MaxDepth
        How far to follow references. Default 8.

    .PARAMETER MaxResources
        Safety ceiling on the number of resources fetched. Default 400.

    .EXAMPLE
        $walk = Invoke-RedfishWalk -BaseUri 'https://10.0.0.5' -AuthHeader $h -VendorProfile $vp
        $walk | Where-Object { $_.Health -and $_.Health -ne 'OK' }

    .OUTPUTS
        One object per resource with Path, Type, Id, Name, Health, State and the raw document.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][string]$AuthHeader,
        [Parameter()]$VendorProfile,
        [int]$MaxDepth = 8,
        [int]$MaxResources = 400
    )

    if (-not $VendorProfile) { $VendorProfile = [PSCustomObject]@{ SkipPattern = '/JsonSchemas|/Registries'; ExtraPaths = @() } }

    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resources = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[object]'

    $queue.Enqueue(@{ Path = '/redfish/v1/'; Depth = 0 })
    foreach ($extra in @($VendorProfile.ExtraPaths)) { $queue.Enqueue(@{ Path = $extra; Depth = 1 }) }

    while ($queue.Count -gt 0 -and $resources.Count -lt $MaxResources) {
        $node = $queue.Dequeue()
        $path = [string]$node.Path
        if (-not $path) { continue }
        # Firmware publishes the same resource with and without a trailing slash; one fetch is enough.
        $key = $path.TrimEnd('/')
        if ($visited.Contains($key)) { continue }
        [void]$visited.Add($key)
        if ($node.Depth -gt $MaxDepth) { continue }
        if ($VendorProfile.SkipPattern -and $path -match $VendorProfile.SkipPattern) { continue }

        try { $doc = Invoke-RedfishRequest -BaseUri $BaseUri -Path $path -AuthHeader $AuthHeader -TimeoutSec 20 }
        catch { Write-Verbose "Redfish walk: $path unreachable"; continue }

        $odataType = [string](Get-RedfishValue -InputObject $doc -Names @('@odata.type') -Default '')
        $shortType = ($odataType -replace '^#', '') -replace '\..*$', ''

        $resources.Add([PSCustomObject]@{
                Path     = $path
                Type     = $shortType
                Id       = [string](Get-RedfishValue -InputObject $doc -Names @('Id') -Default '')
                Name     = [string](Get-RedfishValue -InputObject $doc -Names @('Name', 'FanName') -Default '')
                Health   = Get-RedfishHealth -Status $doc.Status
                State    = [string](Get-RedfishValue -InputObject $doc.Status -Names @('State') -Default '')
                Depth    = $node.Depth
                Document = $doc
            })

        # Follow modern and legacy references alike.
        $json = $doc | ConvertTo-Json -Depth 12 -Compress
        foreach ($pattern in @('"@odata\.id"\s*:\s*"([^"]+)"', '"href"\s*:\s*"([^"]+)"')) {
            foreach ($match in [regex]::Matches($json, $pattern)) {
                $child = $match.Groups[1].Value
                if (-not $child -or $child -notlike '/redfish/*') { continue }
                if ($visited.Contains($child.TrimEnd('/'))) { continue }
                $queue.Enqueue(@{ Path = $child; Depth = $node.Depth + 1 })
            }
        }
    }

    Write-Verbose "Redfish walk reached $($resources.Count) resource(s)."
    return $resources
}

function Select-RedfishWalkType {
    <#
    .SYNOPSIS
        Picks walked resources whose @odata.type matches any of a set of vendor aliases.
    .DESCRIPTION
        Collections are excluded, because a collection carries no component of its own and
        would otherwise be counted alongside its members.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Walk,
        [Parameter(Mandatory = $true)][string[]]$TypeNames
    )

    $matched = @()
    foreach ($resource in @($Walk)) {
        $type = [string]$resource.Type
        if (-not $type -or $type -like '*Collection') { continue }
        foreach ($name in $TypeNames) {
            if ($type -eq $name) { $matched += $resource; break }
        }
    }
    return $matched
}

function Get-RedfishInventory {
    <#
    .SYNOPSIS
        Reads systems, chassis, and managers from a Redfish service root.

    .DESCRIPTION
        By default the whole service is walked, which reaches components that firmware does
        not link through the standard collections. On an iLO 4 DL360 Gen9 the walk returns
        129 resources against the 30 a conventional traversal finds, picking up processors,
        DIMMs, drives and the array controller that would otherwise be invisible.

        The walk is the only fetch: systems, chassis, managers and component counts are all
        derived from what it returned, so nothing is requested twice.

        Pass -NoDeepWalk to fall back to targeted requests for the standard collections.
        That is roughly four times faster but sees only what the firmware links conventionally.

    .PARAMETER TargetAddress
        BMC address or hostname.

    .PARAMETER Credential
        BMC account with read access.

    .PARAMETER Protocol
        http or https. Default https.

    .PARAMETER Port
        API port. Default 443.

    .PARAMETER NoDeepWalk
        Skip the full walk and probe only the standard collections.

    .PARAMETER WalkMaxResources
        Ceiling on resources fetched during the walk. Default 400.

    .PARAMETER WalkMaxDepth
        How far the walk follows references. Default 8.

    .EXAMPLE
        Get-RedfishInventory -TargetAddress 192.168.1.99 -Credential $cred

    .EXAMPLE
        # Faster, shallower: standard collections only.
        Get-RedfishInventory -TargetAddress 192.168.1.99 -Credential $cred -NoDeepWalk
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetAddress,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [string]$Protocol = 'https',
        [int]$Port = 443,
        [switch]$NoDeepWalk,
        [int]$WalkMaxResources = 400,
        [int]$WalkMaxDepth = 8
    )

    if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }

    $baseUri = if ($Port -in @(80, 443)) { "${Protocol}://${TargetAddress}" } else { "${Protocol}://${TargetAddress}:${Port}" }

    $plain = $Credential.GetNetworkCredential().Password
    $pair = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$plain"))
    $authHeader = "Basic $pair"

    $root = Invoke-RedfishRequest -BaseUri $baseUri -Path '/redfish/v1/' -AuthHeader $authHeader
    $vendorProfile = Get-RedfishVendorProfile -ServiceRoot $root

    $walk = @()
    if (-not $NoDeepWalk) {
        $walk = @(Invoke-RedfishWalk -BaseUri $baseUri -AuthHeader $authHeader -VendorProfile $vendorProfile `
                -MaxDepth $WalkMaxDepth -MaxResources $WalkMaxResources)
    }

    $inventory = [PSCustomObject]@{
        BaseUri        = $baseUri
        AuthHeader     = $authHeader
        RedfishVersion = [string](Get-RedfishValue -InputObject $root -Names @('RedfishVersion') -Default 'unknown')
        Vendor         = $vendorProfile.Vendor
        VendorProfile  = $vendorProfile
        Walk           = $walk
        Systems        = @()
        Chassis        = @()
        Managers       = @()
    }

    if ($walk.Count -gt 0) {
        foreach ($pair in @(
                @{ Name = 'Systems'; Type = 'ComputerSystem' }
                @{ Name = 'Chassis'; Type = 'Chassis' }
                @{ Name = 'Managers'; Type = 'Manager' }
            )) {
            $inventory.($pair.Name) = @(Select-RedfishWalkType -Walk $walk -TypeNames @($pair.Type) |
                    ForEach-Object { $_.Document })
        }
    }

    # Either the walk was declined, or firmware published no @odata.type to match on.
    foreach ($collectionName in @('Systems', 'Chassis', 'Managers')) {
        if (@($inventory.$collectionName).Count -gt 0) { continue }

        $collection = $root.PSObject.Properties[$collectionName]
        if (-not $collection -or -not $collection.Value) { continue }

        $odataId = Get-RedfishValue -InputObject $collection.Value -Names @('@odata.id') -Default $null
        if (-not $odataId) { continue }

        try { $list = Invoke-RedfishRequest -BaseUri $baseUri -Path $odataId -AuthHeader $authHeader }
        catch {
            Write-Warning "Redfish: could not read $collectionName from ${TargetAddress}: $($_.Exception.Message)"
            continue
        }

        $members = @()
        foreach ($member in @($list.Members)) {
            $memberId = Get-RedfishValue -InputObject $member -Names @('@odata.id') -Default $null
            if (-not $memberId) { continue }
            try { $members += (Invoke-RedfishRequest -BaseUri $baseUri -Path $memberId -AuthHeader $authHeader) }
            catch { Write-Warning "Redfish: could not read ${memberId}: $($_.Exception.Message)" }
        }
        $inventory.$collectionName = $members
    }

    if (@($inventory.Systems).Count -eq 0 -and @($inventory.Chassis).Count -eq 0) {
        throw "Redfish service at $TargetAddress returned no systems or chassis."
    }

    $facts = [ordered]@{
        Processors         = @()
        MemoryCount        = 0
        StorageControllers = @()
        DriveCount         = 0
        VolumeCount        = 0
        EthernetCount      = 0
        ManagerHostName    = ''
        ManagerFqdn        = ''
        ManagerMac         = ''
        WalkResourceCount  = $walk.Count
        Unhealthy          = @()
    }

    $firstSystem = @($inventory.Systems) | Select-Object -First 1

    if ($walk.Count -gt 0) {
        foreach ($proc in (Select-RedfishWalkType -Walk $walk -TypeNames $vendorProfile.ProcessorType)) {
            $doc = $proc.Document
            $facts.Processors += [PSCustomObject]@{
                Id      = [string](Get-RedfishValue -InputObject $doc -Names @('Id') -Default '')
                Model   = [string](Get-RedfishValue -InputObject $doc -Names @('Model') -Default '')
                Cores   = [string](Get-RedfishValue -InputObject $doc -Names @('TotalCores') -Default '')
                Threads = [string](Get-RedfishValue -InputObject $doc -Names @('TotalThreads') -Default '')
                Socket  = [string](Get-RedfishValue -InputObject $doc -Names @('Socket') -Default '')
            }
        }

        # Empty DIMM slots are published as resources too, so only populated ones are counted.
        $facts.MemoryCount = @(Select-RedfishWalkType -Walk $walk -TypeNames $vendorProfile.MemoryType | Where-Object {
                $size = Get-RedfishValue -InputObject $_.Document -Names @('CapacityMiB', 'SizeMB', 'SizeMiB') -Default 0
                $status = [string](Get-RedfishValue -InputObject $_.Document -Names @('DIMMStatus', 'MemoryDeviceType') -Default '')
                ([double]$size -gt 0) -and ($status -ne 'NotPresent') -and ($status -ne 'Absent')
            }).Count

        $facts.DriveCount = @(Select-RedfishWalkType -Walk $walk -TypeNames $vendorProfile.DriveType).Count
        $facts.VolumeCount = @(Select-RedfishWalkType -Walk $walk -TypeNames $vendorProfile.VolumeType).Count

        # Manager NICs live in the same collection type as host NICs; only host NICs are counted.
        $facts.EthernetCount = @(Select-RedfishWalkType -Walk $walk -TypeNames @('EthernetInterface') |
                Where-Object { $_.Path -notmatch '/Managers/' }).Count

        foreach ($ctrl in (Select-RedfishWalkType -Walk $walk -TypeNames $vendorProfile.ControllerType)) {
            $doc = $ctrl.Document
            # HPE nests the controller firmware as Current.VersionString.
            $firmware = Get-RedfishValue -InputObject $doc -Names @('FirmwareVersion') -Default ''
            if ($firmware -and $firmware -isnot [string]) {
                $current = Get-RedfishValue -InputObject $firmware -Names @('Current') -Default $null
                $firmware = [string](Get-RedfishValue -InputObject $current -Names @('VersionString', 'Version') -Default '')
            }
            $facts.StorageControllers += [PSCustomObject]@{
                Model    = [string](Get-RedfishValue -InputObject $doc -Names @('Model') -Default '')
                Firmware = [string]$firmware
                Health   = Get-RedfishHealth -Status $doc.Status
            }
        }

        $facts.Unhealthy = @($walk | Where-Object {
                $_.Health -and $_.Health -ne 'OK' -and $_.Health -ne 'Enabled'
            } | ForEach-Object {
                $who = if ($_.Name) { $_.Name } else { $_.Type }
                "$who=$($_.Health)"
            })
    }
    elseif ($firstSystem) {
        $systemPath = [string](Get-RedfishValue -InputObject $firstSystem -Names @('@odata.id') -Default '/redfish/v1/Systems/1/')
        $systemPath = $systemPath.TrimEnd('/')

        foreach ($proc in (Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path "$systemPath/Processors/")) {
            $facts.Processors += [PSCustomObject]@{
                Id      = [string](Get-RedfishValue -InputObject $proc -Names @('Id') -Default '')
                Model   = [string](Get-RedfishValue -InputObject $proc -Names @('Model') -Default '')
                Cores   = [string](Get-RedfishValue -InputObject $proc -Names @('TotalCores') -Default '')
                Threads = [string](Get-RedfishValue -InputObject $proc -Names @('TotalThreads') -Default '')
                Socket  = [string](Get-RedfishValue -InputObject $proc -Names @('Socket') -Default '')
            }
        }

        $facts.MemoryCount = @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path "$systemPath/Memory/" -IdsOnly).Count
        $facts.EthernetCount = @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path "$systemPath/EthernetInterfaces/" -IdsOnly).Count

        # HPE exposes array controllers under SmartStorage; others use the standard Storage collection.
        foreach ($path in @("$systemPath/SmartStorage/ArrayControllers/", "$systemPath/Storage/")) {
            $controllers = @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path $path)
            if ($controllers.Count -eq 0) { continue }
            foreach ($ctrl in $controllers) {
                $firmware = Get-RedfishValue -InputObject $ctrl -Names @('FirmwareVersion') -Default ''
                if ($firmware -and $firmware -isnot [string]) {
                    $current = Get-RedfishValue -InputObject $firmware -Names @('Current') -Default $null
                    $firmware = [string](Get-RedfishValue -InputObject $current -Names @('VersionString', 'Version') -Default '')
                }
                $facts.StorageControllers += [PSCustomObject]@{
                    Model    = [string](Get-RedfishValue -InputObject $ctrl -Names @('Model') -Default '')
                    Firmware = [string]$firmware
                    Health   = Get-RedfishHealth -Status $ctrl.Status
                }
                $ctrlPath = [string](Get-RedfishValue -InputObject $ctrl -Names @('@odata.id') -Default '')
                if ($ctrlPath) {
                    $facts.DriveCount += @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path "$($ctrlPath.TrimEnd('/'))/DiskDrives/" -IdsOnly).Count
                    $facts.VolumeCount += @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path "$($ctrlPath.TrimEnd('/'))/LogicalDrives/" -IdsOnly).Count
                }
            }
            break
        }
    }

    $firstManager = @($inventory.Managers) | Select-Object -First 1
    if ($firstManager) {
        $mgrPath = [string](Get-RedfishValue -InputObject $firstManager -Names @('@odata.id') -Default '/redfish/v1/Managers/1/')
        foreach ($nic in (Get-RedfishMembers -BaseUri $baseUri -AuthHeader $authHeader -Path "$($mgrPath.TrimEnd('/'))/EthernetInterfaces/")) {
            $hostName = [string](Get-RedfishValue -InputObject $nic -Names @('HostName') -Default '')
            if (-not $hostName) { continue }
            $facts.ManagerHostName = $hostName
            $facts.ManagerFqdn = [string](Get-RedfishValue -InputObject $nic -Names @('FQDN') -Default '')
            $facts.ManagerMac = [string](Get-RedfishValue -InputObject $nic -Names @('MacAddress', 'PermanentMACAddress') -Default '')
            break
        }
    }

    $inventory | Add-Member -NotePropertyName 'Facts' -NotePropertyValue ([PSCustomObject]$facts) -Force
    return $inventory
}

function Get-RedfishMembers {
    <#
    .SYNOPSIS
        Expands a Redfish collection into its member resources.
    .DESCRIPTION
        Returns an empty array when the collection is absent, because sub-collections
        vary by vendor and a missing one is normal rather than an error.
    .PARAMETER IdsOnly
        Skip fetching each member; useful when only the count is needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][string]$AuthHeader,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$IdsOnly
    )

    try { $list = Invoke-RedfishRequest -BaseUri $BaseUri -Path $Path -AuthHeader $AuthHeader }
    catch { return @() }

    # An absent Members property must not count as one member: @($null).Count is 1.
    $members = @($list.Members | Where-Object { $null -ne $_ })
    if ($IdsOnly) { return $members }

    $expanded = @()
    foreach ($member in $members) {
        $id = Get-RedfishValue -InputObject $member -Names @('@odata.id') -Default $null
        if (-not $id) { continue }
        try { $expanded += (Invoke-RedfishRequest -BaseUri $BaseUri -Path $id -AuthHeader $AuthHeader) }
        catch { Write-Verbose "Redfish: could not read $id" }
    }
    return $expanded
}

Register-DiscoveryProvider -Name 'Redfish' `
    -MatchAttribute 'DiscoveryHelper.Redfish' `
    -AuthType 'BasicAuth' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -DiscoverScript {
    param($ctx)

    $items = @()
    $targetAddress = $ctx.DeviceIP

    # Invoke-Discovery types -Credential as a hashtable, so accept the wrapped forms too.
    $credential = $null
    if ($ctx.Credential -is [System.Management.Automation.PSCredential]) {
        $credential = $ctx.Credential
    }
    elseif ($ctx.Credential -and $ctx.Credential.PSCredential -is [System.Management.Automation.PSCredential]) {
        $credential = $ctx.Credential.PSCredential
    }
    elseif ($ctx.Credential -and $ctx.Credential.Username -and $ctx.Credential.Password) {
        $secPwd = ConvertTo-SecureString "$($ctx.Credential.Password)" -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($ctx.Credential.Username, $secPwd)
    }

    if (-not $credential) {
        Write-Warning "Redfish: no usable credential supplied for $targetAddress."
        return $items
    }

    $protocol = if ($ctx.Protocol) { $ctx.Protocol } else { 'https' }
    $port = if ($ctx.Port) { [int]$ctx.Port } else { 443 }

    # Deep walk is the default; Options.NoDeepWalk trades component coverage for speed.
    $invSplat = @{
        TargetAddress = $targetAddress
        Credential    = $credential
        Protocol      = $protocol
        Port          = $port
    }
    if ($ctx.Options -and $ctx.Options['NoDeepWalk']) { $invSplat['NoDeepWalk'] = $true }
    if ($ctx.Options -and $ctx.Options['WalkMaxResources']) { $invSplat['WalkMaxResources'] = [int]$ctx.Options['WalkMaxResources'] }

    $inventory = Get-RedfishInventory @invSplat
    $ignoreCert = if ($ctx.IgnoreCertErrors -eq $false) { '0' } else { '1' }

    # Poll-time URLs are templated on the device address so one monitor serves every
    # BMC of a model. Auth comes from the device's REST API credential, which is why
    # there is no CustomHeader and UseAnonymousAccess is off.
    $urlBase = "https://$script:RedfishAddressToken"
    $activeBase = @{
        RestApiMethod                 = 'GET'
        RestApiTimeoutMs              = 30000
        RestApiIgnoreCertErrors       = $ignoreCert
        RestApiUseAnonymous           = '0'
        RestApiCustomHeader           = ''
        RestApiDownIfResponseCodeIsIn = '[400,401,403,404,500,502,503]'
    }
    $perfBase = @{
        RestApiHttpMethod         = 'GET'
        RestApiHttpTimeoutMs      = 30000
        RestApiIgnoreCertErrors   = $ignoreCert
        RestApiUseAnonymousAccess = '0'
        RestApiCustomHeader       = ''
    }

    $firstSystem = @($inventory.Systems) | Select-Object -First 1
    $firstChassis = @($inventory.Chassis) | Select-Object -First 1
    $firstManager = @($inventory.Managers) | Select-Object -First 1

    $model = [string](Get-RedfishValue -InputObject $firstSystem -Names @('Model') -Default '')
    $serial = [string](Get-RedfishValue -InputObject $firstSystem -Names @('SerialNumber') -Default '')
    $label = if ($model) { $model } else { $targetAddress }

    $baseAttrs = @{
        'DiscoveryHelper.Redfish' = 'true'
        'Redfish.Version'         = $inventory.RedfishVersion
        'Redfish.Vendor'          = [string]$inventory.Vendor
        'Redfish.Model'           = $model
        'Redfish.SerialNumber'    = $serial
    }

    function Add-Attr {
        param([hashtable]$Target, [string]$Key, $Value)
        $text = [string]$Value
        if ($text) { $Target[$Key] = $text }
    }

    Add-Attr $baseAttrs 'Redfish.BiosVersion'      (Get-RedfishValue -InputObject $firstSystem -Names @('BiosVersion') -Default '')
    Add-Attr $baseAttrs 'Redfish.SKU'              (Get-RedfishValue -InputObject $firstSystem -Names @('SKU') -Default '')
    Add-Attr $baseAttrs 'Redfish.UUID'             (Get-RedfishValue -InputObject $firstSystem -Names @('UUID') -Default '')
    Add-Attr $baseAttrs 'Redfish.AssetTag'         (Get-RedfishValue -InputObject $firstSystem -Names @('AssetTag') -Default '')
    Add-Attr $baseAttrs 'Redfish.PowerState'       (Get-RedfishValue -InputObject $firstSystem -Names @('PowerState') -Default '')
    Add-Attr $baseAttrs 'Redfish.SystemHealth'     (Get-RedfishHealth -Status $firstSystem.Status)
    Add-Attr $baseAttrs 'Redfish.Manufacturer'     (Get-RedfishValue -InputObject $firstChassis -Names @('Manufacturer') -Default '')
    Add-Attr $baseAttrs 'Redfish.ChassisType'      (Get-RedfishValue -InputObject $firstChassis -Names @('ChassisType') -Default '')
    Add-Attr $baseAttrs 'Redfish.ManagerFirmware'  (Get-RedfishValue -InputObject $firstManager -Names @('FirmwareVersion') -Default '')
    Add-Attr $baseAttrs 'Redfish.ManagerType'      (Get-RedfishValue -InputObject $firstManager -Names @('ManagerType') -Default '')

    $facts = $inventory.Facts
    if ($facts) {
        Add-Attr $baseAttrs 'Redfish.ManagerHostName' $facts.ManagerHostName
        Add-Attr $baseAttrs 'Redfish.ManagerFQDN'     $facts.ManagerFqdn
        Add-Attr $baseAttrs 'Redfish.ManagerMAC'      $facts.ManagerMac
        Add-Attr $baseAttrs 'Redfish.DimmCount'       $facts.MemoryCount
        Add-Attr $baseAttrs 'Redfish.NicCount'        $facts.EthernetCount
        Add-Attr $baseAttrs 'Redfish.DriveCount'      $facts.DriveCount
        Add-Attr $baseAttrs 'Redfish.VolumeCount'     $facts.VolumeCount

        $procs = @($facts.Processors)
        if ($procs.Count -gt 0) {
            Add-Attr $baseAttrs 'Redfish.CpuCount'   $procs.Count
            Add-Attr $baseAttrs 'Redfish.CpuModel'   $procs[0].Model
            Add-Attr $baseAttrs 'Redfish.CpuCores'   $procs[0].Cores
            Add-Attr $baseAttrs 'Redfish.CpuThreads' $procs[0].Threads
        }
        $ctrls = @($facts.StorageControllers)
        if ($ctrls.Count -gt 0) {
            Add-Attr $baseAttrs 'Redfish.StorageController'         $ctrls[0].Model
            Add-Attr $baseAttrs 'Redfish.StorageControllerFirmware' $ctrls[0].Firmware
            Add-Attr $baseAttrs 'Redfish.StorageControllerCount'    $ctrls.Count
        }

        if ([int]$facts.WalkResourceCount -gt 0) {
            Add-Attr $baseAttrs 'Redfish.WalkResourceCount' $facts.WalkResourceCount
            $unhealthy = @($facts.Unhealthy)
            Add-Attr $baseAttrs 'Redfish.UnhealthyCount' $unhealthy.Count
            if ($unhealthy.Count -gt 0) {
                # WUG attribute values are length-limited, so the list is capped.
                $summary = ($unhealthy | Select-Object -First 10) -join '; '
                if ($summary.Length -gt 400) { $summary = $summary.Substring(0, 400) }
                Add-Attr $baseAttrs 'Redfish.Unhealthy' $summary
            }
        }
    }

    Add-Attr $baseAttrs 'Redfish.MemoryGiB' (Get-RedfishValue -InputObject $firstSystem.MemorySummary -Names @('TotalSystemMemoryGiB') -Default '')

    # ---- System-level health and state -------------------------------------
    # Discovery reads the live BMC address; the emitted monitors use the token instead.
    $baseUri = $inventory.BaseUri

    foreach ($system in @($inventory.Systems)) {
        $systemId = [string](Get-RedfishValue -InputObject $system -Names @('Id') -Default '1')
        $systemPath = [string](Get-RedfishValue -InputObject $system -Names @('@odata.id') -Default "/redfish/v1/Systems/$systemId/")
        $systemUrl = "$urlBase$systemPath"

        $sysChecks = @(
            @{ Suffix = 'System Health'; Path = "['Status']['Health']"; Expect = 'OK'; Key = 'health'; Tag = 'health' }
            @{ Suffix = 'Power State'; Path = "['PowerState']"; Expect = 'On'; Key = 'powerstate'; Tag = 'power' }
        )
        # Processor and memory roll-ups live on the system document, so aggregate CPU and
        # DIMM health costs no extra request and needs no per-instance addressing.
        if ($system.PSObject.Properties['Processors'] -and $system.Processors.Status) {
            $sysChecks += @{ Suffix = 'CPU Health'; Path = "['Processors']['Status']['HealthRollUp']"; Expect = 'OK'; Key = 'cpu'; Tag = 'cpu' }
        }
        if ($system.PSObject.Properties['Memory'] -and $system.Memory.Status) {
            $sysChecks += @{ Suffix = 'Memory Health'; Path = "['Memory']['Status']['HealthRollUp']"; Expect = 'OK'; Key = 'memory'; Tag = 'memory' }
        }

        foreach ($chk in $sysChecks) {
            $aParams = $activeBase.Clone()
            $aParams['RestApiUrl'] = $systemUrl
            $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath $chk.Path -Expected $chk.Expect
            $items += New-DiscoveredItem `
                -Name "Redfish - $label $($chk.Suffix)" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $aParams `
                -UniqueKey "Redfish:${targetAddress}:system:${systemId}:$($chk.Key)" `
                -Attributes $baseAttrs `
                -Tags @('redfish', 'hardware', $chk.Tag)
        }
    }

    # ---- Manager (BMC) -----------------------------------------------------
    # A Manager reports State but no Health, so this checks the BMC is enabled.
    if ($firstManager) {
        $mgrPath = [string](Get-RedfishValue -InputObject $firstManager -Names @('@odata.id') -Default '/redfish/v1/Managers/1/')
        $aParams = $activeBase.Clone()
        $aParams['RestApiUrl'] = "$urlBase$mgrPath"
        $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath "['Status']['State']" -Expected 'Enabled'
        $items += New-DiscoveredItem `
            -Name "Redfish - $label BMC State" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams $aParams `
            -UniqueKey "Redfish:${targetAddress}:manager:state" `
            -Attributes $baseAttrs `
            -Tags @('redfish', 'bmc')
    }

    # ---- Storage: one health monitor per physical drive ---------------------
    $drivePaths = @()
    if ($inventory.Walk -and @($inventory.Walk).Count -gt 0) {
        $drivePaths = @(Select-RedfishWalkType -Walk $inventory.Walk -TypeNames $inventory.VendorProfile.DriveType |
                ForEach-Object { $_.Path })
    }
    elseif ($firstSystem) {
        # Shallow mode has no walk to mine, so the drive collections are read directly.
        $sysPathForDisks = [string](Get-RedfishValue -InputObject $firstSystem -Names @('@odata.id') -Default '/redfish/v1/Systems/1/')
        $sysPathForDisks = $sysPathForDisks.TrimEnd('/')
        foreach ($ctrl in @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $inventory.AuthHeader -Path "$sysPathForDisks/SmartStorage/ArrayControllers/")) {
            $cPath = [string](Get-RedfishValue -InputObject $ctrl -Names @('@odata.id') -Default '')
            if (-not $cPath) { continue }
            foreach ($d in @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $inventory.AuthHeader -Path "$($cPath.TrimEnd('/'))/DiskDrives/" -IdsOnly)) {
                $dPath = [string](Get-RedfishValue -InputObject $d -Names @('@odata.id') -Default '')
                if ($dPath) { $drivePaths += $dPath }
            }
        }
        if ($drivePaths.Count -eq 0) {
            foreach ($st in @(Get-RedfishMembers -BaseUri $baseUri -AuthHeader $inventory.AuthHeader -Path "$sysPathForDisks/Storage/")) {
                foreach ($d in @($st.Drives)) {
                    $dPath = [string](Get-RedfishValue -InputObject $d -Names @('@odata.id') -Default '')
                    if ($dPath) { $drivePaths += $dPath }
                }
            }
        }
    }
    $diskIndex = 0
    foreach ($dp in $drivePaths) {
        if ($diskIndex -ge $script:RedfishMaxDisks) { break }
        $aParams = $activeBase.Clone()
        $aParams['RestApiUrl'] = "$urlBase$dp"
        $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath "['Status']['Health']" -Expected 'OK'
        $items += New-DiscoveredItem `
            -Name "Redfish - $label Disk $diskIndex Health" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams $aParams `
            -UniqueKey "Redfish:${targetAddress}:disk:${diskIndex}:health" `
            -Attributes $baseAttrs `
            -Tags @('redfish', 'storage', 'disk')
        $diskIndex++
    }

    # ---- Chassis: health, power supplies, power draw, temperatures, fans ----
    foreach ($chassis in @($inventory.Chassis)) {
        $chassisId = [string](Get-RedfishValue -InputObject $chassis -Names @('Id') -Default '1')
        $chassisPath = [string](Get-RedfishValue -InputObject $chassis -Names @('@odata.id') -Default "/redfish/v1/Chassis/$chassisId/")

        $aParams = $activeBase.Clone()
        $aParams['RestApiUrl'] = "$urlBase$chassisPath"
        $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath "['Status']['Health']" -Expected 'OK'
        $items += New-DiscoveredItem `
            -Name "Redfish - $label Chassis Health" `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'RestApi' `
            -MonitorParams $aParams `
            -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:health" `
            -Attributes $baseAttrs `
            -Tags @('redfish', 'chassis')

        $powerPath = Get-RedfishValue -InputObject $chassis.Power -Names @('@odata.id') -Default "$chassisPath/Power/"
        $thermalPath = Get-RedfishValue -InputObject $chassis.Thermal -Names @('@odata.id') -Default "$chassisPath/Thermal/"
        $powerUrl = "$urlBase$powerPath"
        $thermalUrl = "$urlBase$thermalPath"

        $power = $null
        try { $power = Invoke-RedfishRequest -BaseUri $baseUri -Path $powerPath -AuthHeader $inventory.AuthHeader }
        catch { Write-Warning "Redfish: could not read power for chassis ${chassisId}: $($_.Exception.Message)" }

        if ($power) {
            # iLO 4 reports consumption at the top level; newer boards nest it in PowerControl.
            $hasTopLevel = $null -ne (Get-RedfishValue -InputObject $power -Names @('PowerConsumedWatts') -Default $null)
            $consumedPath = if ($hasTopLevel) { '$.PowerConsumedWatts' } else { '$.PowerControl[0].PowerConsumedWatts' }

            $pParams = $perfBase.Clone()
            $pParams['RestApiUrl'] = $powerUrl
            $pParams['RestApiJsonPath'] = $consumedPath
            $items += New-DiscoveredItem `
                -Name "Redfish - $label Power Consumed (W)" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams $pParams `
                -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:power:consumed" `
                -Attributes $baseAttrs `
                -Tags @('redfish', 'power')

            foreach ($metric in @(
                    @{ Suffix = 'Power Capacity (W)'; Probe = @('PowerCapacityWatts'); Path = '$.PowerCapacityWatts'; Key = 'capacity' }
                    @{ Suffix = 'Power Average (W)'; Probe = @('PowerMetrics', 'AverageConsumedWatts'); Path = '$.PowerMetrics.AverageConsumedWatts'; Key = 'average' }
                    @{ Suffix = 'Power Peak (W)'; Probe = @('PowerMetrics', 'MaxConsumedWatts'); Path = '$.PowerMetrics.MaxConsumedWatts'; Key = 'peak' }
                )) {
                $probe = $power
                foreach ($seg in $metric.Probe) {
                    if ($null -eq $probe) { break }
                    $probe = $probe.$seg
                }
                if ($null -eq $probe) { continue }

                $pParams = $perfBase.Clone()
                $pParams['RestApiUrl'] = $powerUrl
                $pParams['RestApiJsonPath'] = $metric.Path
                $items += New-DiscoveredItem `
                    -Name "Redfish - $label $($metric.Suffix)" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $pParams `
                    -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:power:$($metric.Key)" `
                    -Attributes $baseAttrs `
                    -Tags @('redfish', 'power')
            }

            # Power supplies carry no @odata.id, so they are addressed by array index.
            $psus = @($power.PowerSupplies)
            for ($p = 0; $p -lt $psus.Count; $p++) {
                if ($p -ge $script:RedfishMaxPsus) { break }
                if (-not $psus[$p].Status) { continue }
                $aParams = $activeBase.Clone()
                $aParams['RestApiUrl'] = $powerUrl
                $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath "['PowerSupplies'][$p]['Status']['Health']" -Expected 'OK'
                $items += New-DiscoveredItem `
                    -Name "Redfish - $label PSU $($p + 1) Health" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $aParams `
                    -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:psu:${p}:health" `
                    -Attributes $baseAttrs `
                    -Tags @('redfish', 'power', 'psu')
            }
        }

        $thermal = $null
        try { $thermal = Invoke-RedfishRequest -BaseUri $baseUri -Path $thermalPath -AuthHeader $inventory.AuthHeader }
        catch { Write-Warning "Redfish: could not read thermal for chassis ${chassisId}: $($_.Exception.Message)" }

        if ($thermal) {
            # Sensors reporting zero are absent, not cold.
            $allTemps = @($thermal.Temperatures) | Where-Object {
                $reading = Get-RedfishValue -InputObject $_ -Names @('ReadingCelsius', 'CurrentReading') -Default 0
                [double]$reading -gt 0
            }
            $rankedTemps = @($allTemps | Sort-Object -Property @{
                    Expression = {
                        $crit = [double](Get-RedfishValue -InputObject $_ -Names @('UpperThresholdCritical') -Default 0)
                        if ($crit -gt 0) { 0 } else { 1 }
                    }
                }, @{ Expression = { [string](Get-RedfishValue -InputObject $_ -Names @('Name') -Default '') } })

            $emitted = 0
            foreach ($temp in $rankedTemps) {
                if ($emitted -ge $script:RedfishMaxTempSensors) { break }
                $tempIndex = [array]::IndexOf(@($thermal.Temperatures), $temp)
                $sensorName = [string](Get-RedfishValue -InputObject $temp -Names @('Name') -Default "Sensor $tempIndex")
                $readingField = if ($temp.PSObject.Properties['ReadingCelsius']) { 'ReadingCelsius' } else { 'CurrentReading' }

                $pParams = $perfBase.Clone()
                $pParams['RestApiUrl'] = $thermalUrl
                $pParams['RestApiJsonPath'] = "`$.Temperatures[$tempIndex].$readingField"
                $items += New-DiscoveredItem `
                    -Name "Redfish - $label Temp $sensorName" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $pParams `
                    -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:temp:${tempIndex}" `
                    -Attributes $baseAttrs `
                    -Tags @('redfish', 'thermal')

                if ($temp.Status) {
                    $aParams = $activeBase.Clone()
                    $aParams['RestApiUrl'] = $thermalUrl
                    $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath "['Temperatures'][$tempIndex]['Status']['Health']" -Expected 'OK'
                    $items += New-DiscoveredItem `
                        -Name "Redfish - $label Temp $sensorName Health" `
                        -ItemType 'ActiveMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams $aParams `
                        -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:temp:${tempIndex}:health" `
                        -Attributes $baseAttrs `
                        -Tags @('redfish', 'thermal')
                }
                $emitted++
            }

            $fanEmitted = 0
            $fans = @($thermal.Fans)
            for ($i = 0; $i -lt $fans.Count; $i++) {
                if ($fanEmitted -ge $script:RedfishMaxFans) { break }
                $fan = $fans[$i]
                # iLO 4 uses FanName/CurrentReading; current schema uses Name/Reading.
                $fanName = [string](Get-RedfishValue -InputObject $fan -Names @('FanName', 'Name') -Default "Fan $($i + 1)")
                $readingField = if ($fan.PSObject.Properties['Reading']) { 'Reading' } else { 'CurrentReading' }
                $reading = Get-RedfishValue -InputObject $fan -Names @('Reading', 'CurrentReading') -Default $null
                if ($null -eq $reading) { continue }

                $pParams = $perfBase.Clone()
                $pParams['RestApiUrl'] = $thermalUrl
                $pParams['RestApiJsonPath'] = "`$.Fans[$i].$readingField"
                $items += New-DiscoveredItem `
                    -Name "Redfish - $label $fanName" `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams $pParams `
                    -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:fan:${i}" `
                    -Attributes $baseAttrs `
                    -Tags @('redfish', 'thermal', 'fan')

                if ($fan.Status) {
                    $aParams = $activeBase.Clone()
                    $aParams['RestApiUrl'] = $thermalUrl
                    $aParams['RestApiComparisonList'] = New-RedfishDownIfNot -JsonPath "['Fans'][$i]['Status']['Health']" -Expected 'OK'
                    $items += New-DiscoveredItem `
                        -Name "Redfish - $label $fanName Health" `
                        -ItemType 'ActiveMonitor' `
                        -MonitorType 'RestApi' `
                        -MonitorParams $aParams `
                        -UniqueKey "Redfish:${targetAddress}:chassis:${chassisId}:fan:${i}:health" `
                        -Attributes $baseAttrs `
                        -Tags @('redfish', 'thermal', 'fan')
                }
                $fanEmitted++
            }
        }
    }

    return $items
}

# ---- END OF SCRIPT (do not remove this line or the closing braces above)

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAr/hM3mjEOWXpi
# LQRvsaljRvv6j9sy+e627zfN2UWRnaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCH9g7nBleAZ1O6eh6GLaLxGmFIhZEB2LlMa2+JwGpBhjANBgkqhkiG9w0BAQEF
# AASCAgDqBRowPXHIxMmhy77zOyRSmoY5n+M0Bjhz32u/oyxlp6iT+Znh5qJCpqlk
# KMJH+gl/LvMiFeBoD7FMzNosr83WnVP8D0esTeXM+4Q0qBuyJYV1rT1v0FAF5dqY
# w22ek0GPwMMovjmaepcIHHLJHgAfTk5xazjmr4astJ0hYvyYTc86zgvFX4gP7yvK
# I15fLOuyU6REsqkBnstpREHDov11ydcveVUfaMjofVejTykdKKMrHlUNvl2Ob5vX
# AAMzvNiJGKuIqOuSSi9hSKUTsSkCJjtKSjn48YxwWlW8cI08fr+uF51+pj4Ztl84
# DdQuK+z8aMSRNLHk72sJqIUZ/jbhj96SIOoxo92vZpQMKt/G9JXdJVwIoHSNei1D
# JtuJCkVb1fAz1rDeD4BXHeYiULfTs7Zv1maUd80saWsRyys2kKXUmuGYErABApym
# 5KGB4hkLbnelwdcZwknG9WzGARjGwAeThbk30zLISttUYKmQF1bfqkfQQY6oIS/I
# x6OK/IzQShjsjx3xRz5Lq1H2udTx6RqO8TIxjzNrie/yxYhfSu/ja/LXrtVQMEsL
# 2Xrds8AeXkrV5MF4OIAsFpN+Ol+78hcr77q3jwY1MpxqxHClXjdof0n4IuQt+BHB
# 9/sF3OmZUGk+hCnzlIABWL8ztQzp3BBp2DJv/ILaA9z2T16qsKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjEwMDMxNTU2MTRaMC8GCSqGSIb3DQEJBDEiBCCo8+4P
# 9f74j9uaHDxnFiqHA4/3sffXyrp+RRvfYEXo6jANBgkqhkiG9w0BAQEFAASCAgBS
# fV6hHRqkDpFU30PayZkPw4sp6VhCbo6lGEY3ik4k1SB4m8yuB7s6dwnadlQrxiNW
# jFMV+z+C8X9w2g9c3P9wz9dV+KmXYSxKyeRnRfzKLb13wWhe1UQIuRRXD5E1MYGN
# YgDE5j2RT/iPBE6y5yqrlmJKaWJ6fhvv9Ec1C9GIz7bgjgu8EkFVmgs01ftBLvb3
# 3agaqf5L6oH+5WfFdXILx6K7eCs1UoNOGZxnCGTJAw6aDIkdeK7tOdvnpcA3ujfa
# 4LhjO8jVvp0pQwdzOyDlZzFdCmC19HEUaGYnyFH7USJ2GESX+2FRidlZWO3aLg6g
# Iv+B4whPNdrRpxpLZx8Pc3YjKv7GTJJIVFCv/PLuoO7k/6XB7xOBNcBBLq1HjXsS
# Re7WxPhiWfRI7ngRos7DSj5LFu3weURDjhx+z6Yfm7UZRMIpczUIsaMDVPiWybuT
# ErJqahs6Pe0/WS4WECob7+P9UixkLAX+AaeOU/cZTXRdLdfoCJEUSog0pDJh45KS
# 23ibFGat5APUyTNepwSwVDZcIZsgtB5bcOoPJ2AMyVVYltK/otfEWHOK/Od9N6hz
# +N0YtV6GqGzJl96re5ZLfxKgXk7Ye0389usmWiBqousxUZ3WCvNI/5FmrM7Qnh4s
# vCr4aOSpipVtc1B3oriDJUaS86wr/RtmXSZCmq2ATw==
# SIG # End signature block
