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
    $headers = @{ Authorization = $AuthHeader; Accept = 'application/json' }
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
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUqPqAJHVMh5YZlmTr7/rMe+7P
# MPqggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG
# 9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkw
# FwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1
# cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBi
# MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
# d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3Qg
# RzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAi
# MGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnny
# yhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE
# 5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm
# 7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5
# w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsD
# dV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1Z
# XUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS0
# 0mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hk
# pjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m8
# 00ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+i
# sX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB
# /zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReui
# r/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0w
# azAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUF
# BzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVk
# SURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAG
# BgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9
# mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxS
# A8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/
# 6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSM
# b++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt
# 9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGGjCC
# BAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG9w0BAQwFADBWMQswCQYD
# VQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0
# aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAw
# WhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcg
# Q0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAmyudU/o1P45g
# BkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxDeEDIArCS2VCoVk4Y/8j6
# stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk9vT0k2oWJMJjL9G//N52
# 3hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7XwiunD7mBxNtecM6ytIdUl
# h08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ0arWZVeffvMr/iiIROSC
# zKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZXnYvZQgWx/SXiJDRSAolR
# zZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+tAfiWu01TPhCr9VrkxsHC
# 5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvrn35XGf2RPaNTO2uSZ6n9
# otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn3UayWW9bAgMBAAGjggFk
# MIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaRXBeF5jAdBgNVHQ4EFgQU
# DyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYDVR0gBBQwEjAGBgRVHSAA
# MAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRwOi8vY3JsLnNlY3RpZ28u
# Y29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYuY3JsMHsGCCsGAQUF
# BwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0
# aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAjBggrBgEFBQcwAYYXaHR0
# cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBAAb/guF3YzZu
# e6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXKZDk8+Y1LoNqHrp22AKMG
# xQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWkvfPkKaAQsiqaT9DnMWBH
# VNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3dMapandPfYgoZ8iDL2OR3
# sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwFkvjFV3jS49ZSc4lShKK6
# BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZaPATHvNIzt+z1PHo35D/f
# 7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8bkinLrYrKpii+Tk7pwL7T
# jRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7EwoIJB0kak6pSzEu4I64U6
# gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TWSenLbjBQUGR96cFr6lEU
# fAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg51Tbnio1lB93079WPFnY
# aOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoUKD85gnJ+t0smrWrb8dee
# 2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGPjCCBKagAwIBAgIQB5zg5NEUf4XN
# OXPPdi036zANBgkqhkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP
# U2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNp
# Z25pbmcgQ0EgUjM2MB4XDTI2MDIwOTAwMDAwMFoXDTI5MDQyMTIzNTk1OVowVTEL
# MAkGA1UEBhMCVVMxFDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNv
# biBBbGJlcmlubzEXMBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDzemjeAdcmFpCOW+UwY9yNFVf6XhE6x2+hGOAR
# xsbfAKfnk/lqRKSchLUWD8RJjSS9wN/AZIO5sMzxN/9TSue9GQQrgY0gJ+JkgyIC
# Ll2Z78gTvVtTkLOXeuzJSS1ABLn5dfLTq90k9Q3jvYEo0EgBOTapdEA8T55vdzmQ
# aJ/hc9wphPs9zMAHtoeCnbUQJwqsDPv1e4gXW8PiTsaJacfu0VYxsj66ExDSBt6X
# v4Srz2+dNZX/LgQAAy3Y2a+YqfLyFm3/Oe2MNQbtdJ1SOx1t3hPApef/3da4mx5c
# 080C37bVvpPg2hbCmQQS+epeGAJSFUbKzohNZHR2GMeiBqxAPNPUe/k2QPQ8xqsh
# Yr/apiQGy+Hw8HrQ3siKvjs7c9S7xHcvEXHdCQWPieEtHgxBSAN19DfFXC3gMGmy
# m/QI7pSl8FHqgiS7ze/QifdFE2W9viPrWpo9HZ/iCjBLCeL+BoMe9rMRa/ful84q
# HbU4OS7n9sXevj4YWpjsRdqcfSzm4QSyxDMkbAh2SM1WThSrvQaR0B+7nxgfkmvN
# E5YtP+ixMp/fmzGFotrbZ+pSzj04VzIkGqKEVKuqtrt/heEmj5cVRSyOziVTIWq+
# p1uo6AbxC0yT5gDUjIw0kRQ3x0QnRm2bC/5HhCyTcvo2XLRelb8UBIxTPP22s7uq
# mIawOwIDAQABo4IBiTCCAYUwHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhek
# zQwwHQYDVR0OBBYEFOmBdKNA+QFYSh21aHK/BmkiAYmwMA4GA1UdDwEB/wQEAwIH
# gDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEw
# NQYMKwYBBAGyMQECAQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5j
# b20vQ1BTMAgGBmeBDAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNl
# Y3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5Bggr
# BgEFBQcBAQRtMGswRAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdo
# dHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAYEABCLJuMZz
# nf7WTFaysIt3aAF7wsDgP0WEJxSQ+0f20kEbt8FxCuKPUiHn8ntfAf6uH4QZITQC
# bhL00ABn6m26caMNNyeT6w06dVjwlm1yl/Ds/bxliRcicURn7ZHc2eeyRNNLMpxD
# EvFwsCzvT99jMkfWfVEa6Yizyfa0I3xzG9QVHb2jWsqJpu2liwJw/l+45uqPLDU+
# QJ9XMBAKG+6G1gzOrF/d8KYcCTQSQLLR/Ts7Oi8CEjl+rCkuwipvTdyqfITlLntG
# RwLWXRZeqObtdsMvs84nhhCOdHypze+xXzShTlipUujicJQK3GxXoAeSvPS3BOYj
# UpmjN1TAdgA1dRRHIxkh8OJU4NVsfljADHZf+5273xcSfbrubTYk+eAdLPpWTvx8
# 7cF2EFHM3bBaJ96Y7Da7JPWZWpQYuUh5CLvheoO7VohL967VQKZiUZy5FK9l6tmu
# J27JVAreIyrOVF+FdZ0l/DjPvgF6MlRjvok4+8/qZelxPRsP03eliiirMIIGtDCC
# BJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcN
# MjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQg
# RzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URed
# Ta2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW
# 2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH
# ++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7
# RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBY
# qHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk8
# 1coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqU
# JfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3h
# j0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW/
# /1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyO
# Di7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIsp
# zOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
# BBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8u
# Zz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3
# BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDov
# L2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4IC
# AQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXj
# DNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoa
# lhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQY
# K9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId
# +ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQC
# qjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yo
# sn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ
# 1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk
# 43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEd
# mcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjl
# gp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQIC
# EAhP3DNPfkVO28MPj/mSGDUwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0y
# NjA4MDUwMDAwMDBaFw0zNzExMDQyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJT
# QTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI2IDEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC2e6byyf7NSvjUm0xls/04xjD4fAkOkbnGQi7+Wpx8
# 1iYxfzViaxSIctuH3KSl5YEYpMuFgGsA31N2D9ATMbfZdw5uaAhuWevQKhDdZIB4
# NnqcfpfpWQXJiQnDdAElETC+bhSEvNLGbA8DtwUpFMQ4yyYQSPqomT92osQAv6hB
# i47ATZS6JfVWe6XxhF4jJZ3iSAuf2Cros1czRSmWRHqMv9AfGZvp8ygYElhudpQj
# tcPpwoOl6QrZJUyV3iINvN4cO05prGV0fkjG426xDr2d3z9lcSIHkdvGPdGUrXdx
# fVbgOUVcp2/8ISEzwKPW++Wa+E2ujI91EZtukGWDJ/xZ27k3oHKEXBRGfRTqjOU+
# jE3ba/5++JSE/7oNHnjs5mekExYN96LV/mxUbCKJb8pBNY4r3uD7hEmk/M81XhVg
# wDA7aMzYC3LZBg9WY5BMmbSay5ecmtJuXaB/0nKWmQmVZeqTVDgsmzHP5MQuhAJk
# iWNuC9MmCg9TZHXbJ2/yLVSov9p16UDTLtT0+aa1vN71fHeu1qMLlLNB3WOB/ADC
# xr3S/1hxI92Z6jKgEED/btwIvbfuXkNNhg8MtDg43c4tMZae9FvqMOt/9PvmAxF9
# TNIsIFB8G6yb36ZJZGUL8N/pL971DyLXcK6HM5PYnH5X+eVtczhCgHCVQCF6XDAl
# PQIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUFMljijAu1Er7
# bpTz5uNAfvXszeIwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYD
# VR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcB
# AQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0G
# CCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYD
# VR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAjcU6YR6dUgrfmawJgH59KECxa9Ji8sEi2g10CBDaMiqsaxWyW5cwlT/6ZF5s
# FznazqVsoC85U9dqLOYqQwst+UQQoNlDHgKRLa3xoc+OReFreFhnTXSG0Vrd2E2C
# ZqUfm+5a+He1MJ/h+tNLuA+0Zzhn/Fo+FDYAHWZHx4R79ZsfRFYe9UiXpXBDf6Dk
# Uo183Y38NYmR/XfDYf7YZ+oR9t3flbDwK+hgGMs0gNNp1w9Z2CyOyI5or/sSwomA
# uNQ0hWC9xoU4stD8aWsD7RkcmgVRs6vlIk3zPKQ+ylcheWkMlj+CoVRlFE55pv0Z
# WCaFt04lwP/rdGHE9qEVQZtyRE42ox7oNgC/r+Y4bSlZ3dw9K2x1xLtu6PkPKeLB
# FjzKigwfqm3Hm+k/+lnME8F5kPZTgiy2HLEHklpryqs6QHnPXrRNeIzkAMyylnRN
# 8P0wmirS0WkU+ywpEWFZ4QNg+9xS43tTuW9x0eXh7NDc1P/sV+zWxHXKH8tFt1nc
# HdVzqrZaYPyYMLSn2TOXajveJW1L3joiQSPsWRGxkbDDW15jERFE4LvjnGu2O9zD
# 1nLJSMdlYZEikl4w2w+q4IN/R+TIe0H4ngCI1moJCTbevGH4punIxM1Uoi0nmX3Z
# K+XbRT01uowE5ViXWHng0RgsmrX/EdYUo80r3TfMlkD0/YMxggYzMIIGLwIBATBo
# MFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNV
# BAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+F
# zTlzz3YtN+swCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFOyKjvVOFjuy3blCtGYK7Zf+FlCtMA0G
# CSqGSIb3DQEBAQUABIICAACOtKzr3VXL/l/LPkSCAuk54y4HDH1nao7vHTC+3uCs
# NDNTjjj2IRHBsgYT2756WWj6qDtvlGubuM8CpxmC7203QdTFLAFDkwNUauI+BgeF
# GRbLIDFVOPRhXfno0nmbBP48DFKk1rl+CM59PGtG5j1tBJdyK9KBA3MLYnXnqy8A
# o/fciCB3NrkI1fEB7s9lLO6XeT4b+yVtnllJJbe9Zmy3NAJ2RGSp6NzR792I75yG
# 8iI7iJkCySQxskbjx/x3MqiCByLuPa291204201u/nRqMVbzLfNll2q8tOg3pR4y
# 146NH1v7M2JUJOOhM5BE6XeJdUWbcTxEcJoEUO7dxCZRy9xVsejKB8hmciF6t3FW
# es5Et8VQ4orQI5WoD3abE8UcNfdRK6FeDfbuPhSIx9BMI4l4cerXPbhBN1N+jWZQ
# 1w4Wslx/LOhBZR7nvZdc5Yyw94D+oooWqi6KN0UrBAPG/mviiB/zwAm7qFuHM5gQ
# zk2yAO8EqUJ3kVQvY3VxaGRtBgheWkt3SPvlly5Kswfwa37bAz3LCy3BlM33H0dB
# nDfaS1vZ+Xpeu7jjryZEoXdrhZanDH2VSSbb0cD1huNEu/F+dydT47BoIWNsaLoS
# XV0NxkozYTn+9Pd+63hbUkWdGySUWQIflWQ4l4dTSwxnEHpDDkZh4apYIfhQRjjL
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIwMjMxM1owLwYJKoZIhvcN
# AQkEMSIEIMS+2IXRMPzzgN2TVZDw367tOyOHCcd9MsPr85JcvB+MMA0GCSqGSIb3
# DQEBAQUABIICAJAdym44E7294s84+K8lLJP3B6mJKRRFjuvdFRLKjvl9gnwKRet0
# 0sEwPjH9IhJCD1AJ/lNuQYKa4AOykiQL4AblYdvn9m3bowqLGexXd9AsO1VHoekf
# 7kvttQx8/NuY3EJrl7nmytXG0SWKNu9CEhsaBDVYmshtN8hqE5wqy/o8xqiwgRXq
# QLRd5CAeMsLA1kNvKgNlmTSBeDnwKvfOJPNwaMcW+vAJyNxq5wkGMD8/1X1UiGDI
# WHuJF2X3MW9+qjYNpjwHoH4GEElryNBR1xpxSA9XJ+Z9qwmXKgNJ32MDwk0C8zi+
# cXBz4vdCLWK7U992zR3ApBh64/zDDlwcxDoCiClPeGR7GIE7jmnaCtkWj4LFIg+q
# kMT/tKzFpR3rXTsRt0a3c2JSUb9TKi+grbE8R6Tz/YWbc2Errgt65hw8D4yiwjoo
# 2bnG9IoZwJsF4AG+FVnMY4rjpo6+b7yCUfFdi9voa622w2q/GtGMxLcBWzagifKx
# Dl51ddsC7vhoGZsjMVVee7+J+40T9h/0o2NVGg8CeJCyIhNO4MTXXGrQSeCMFPEB
# 1bG5TMiMsKdsTZFxd8C1Xd/wHAbYFDD8opTnaW3wnX6gFVCRqi8HJQ2BGGd/8O3W
# ub1vrDNp71h1BvOM81Dm4v43g73OgP7KVFX76ozTc/LYmekniJ+9QZg0
# SIG # End signature block
