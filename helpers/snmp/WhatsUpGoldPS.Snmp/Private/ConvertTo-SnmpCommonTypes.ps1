function ConvertTo-SnmpVersionCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Version
    )

    if ($Version -is [Lextm.SharpSnmpLib.VersionCode]) {
        return $Version
    }

    switch ($Version.ToString().ToUpperInvariant()) {
        'V1' { return [Lextm.SharpSnmpLib.VersionCode]::V1 }
        'V2' { return [Lextm.SharpSnmpLib.VersionCode]::V2 }
        'V3' { return [Lextm.SharpSnmpLib.VersionCode]::V3 }
        default { throw "Unsupported SNMP version: $Version" }
    }
}

function ConvertTo-SnmpOctetString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($Value -is [Lextm.SharpSnmpLib.OctetString]) {
        return $Value
    }

    return [Lextm.SharpSnmpLib.OctetString]::new([string]$Value)
}

function ConvertTo-SnmpObjectIdentifierInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($Value -is [Lextm.SharpSnmpLib.ObjectIdentifier]) {
        return $Value
    }

    return [Lextm.SharpSnmpLib.ObjectIdentifier]::new([string]$Value)
}

function ConvertTo-SnmpIpEndPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Target,

        [int]$Port = 161
    )

    if ($Target -is [System.Net.IPEndPoint]) {
        return $Target
    }

    if ($Target -is [System.Net.IPAddress]) {
        return [System.Net.IPEndPoint]::new($Target, $Port)
    }

    return [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse([string]$Target), $Port)
}

function ConvertTo-SnmpEndPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Target,

        [int]$Port = 162
    )

    if ($Target -is [System.Net.EndPoint]) {
        return $Target
    }

    if ($Target -is [System.Net.IPAddress]) {
        return [System.Net.IPEndPoint]::new($Target, $Port)
    }

    return [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse([string]$Target), $Port)
}

function ConvertTo-SnmpVariableList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Variables
    )

    $result = [System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]]::new()

    foreach ($item in $Variables) {
        if ($item -is [Lextm.SharpSnmpLib.Variable]) {
            $result.Add($item)
            continue
        }

        if ($item -is [string]) {
            $result.Add([Lextm.SharpSnmpLib.Variable]::new(
                [Lextm.SharpSnmpLib.ObjectIdentifier]::new($item)
            ))
            continue
        }

        if ($item -is [hashtable]) {
            if (-not $item.ContainsKey('OID')) {
                throw 'Hashtable variable entries must include an OID key.'
            }

            $oid = ConvertTo-SnmpObjectIdentifierInternal -Value $item.OID
            if ($item.ContainsKey('Data')) {
                if (-not ($item.Data -is [Lextm.SharpSnmpLib.ISnmpData])) {
                    throw 'Hashtable Data value must implement Lextm.SharpSnmpLib.ISnmpData.'
                }
                $result.Add([Lextm.SharpSnmpLib.Variable]::new($oid, $item.Data))
            }
            else {
                $result.Add([Lextm.SharpSnmpLib.Variable]::new($oid))
            }
            continue
        }

        throw "Unsupported variable entry type: $($item.GetType().FullName)"
    }

    return ,$result
}

function ConvertTo-SnmpWalkMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Mode
    )

    if ($Mode -is [Lextm.SharpSnmpLib.Messaging.WalkMode]) {
        return $Mode
    }

    return [Lextm.SharpSnmpLib.Messaging.WalkMode]::$Mode
}

function Wait-SnmpTaskResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task]$Task,

        [switch]$Wait
    )

    if ($Wait) {
        return $Task.GetAwaiter().GetResult()
    }

    return $Task
}

function Get-SnmpLibraryAvailabilityInternal {
    [CmdletBinding()]
    param()

    $isSharpSnmpLibLoaded = [bool]('Lextm.SharpSnmpLib.Variable' -as [type])
    $isSharpSnmpProMibLoaded = [bool]('Lextm.SharpSnmpPro.Mib.Module' -as [type])

    $resolverMode =
        if ($isSharpSnmpProMibLoaded) { 'SharpSnmpPro' }
        else { 'BuiltIn' }

    $proAssemblyCount =
        if (Get-Variable -Name SharpSnmpLibLoadInfo -Scope Script -ErrorAction SilentlyContinue) {
            @($script:SharpSnmpLibLoadInfo.SharpSnmpProDlls).Count
        }
        else {
            0
        }

    [PSCustomObject]@{
        SharpSnmpLibLoaded        = $isSharpSnmpLibLoaded
        SharpSnmpProMibLoaded     = $isSharpSnmpProMibLoaded
        MibResolverMode           = $resolverMode
        SharpSnmpProAssemblyCount = $proAssemblyCount
    }
}
