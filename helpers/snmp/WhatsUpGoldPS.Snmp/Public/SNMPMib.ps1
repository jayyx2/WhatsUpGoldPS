function Get-SNMPMibSearchPath {
    [CmdletBinding()]
    param()

    return Get-SnmpMibSearchPathInternal
}

function Set-SNMPMibSearchPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [switch]$Append,
        [switch]$PassThru
    )

    Set-SnmpMibSearchPathInternal -Path $Path -Append:$Append

    if ($PassThru) {
        return Get-SnmpMibSearchPathInternal
    }
}

function Import-SNMPMib {
    [CmdletBinding()]
    param(
        [string[]]$Path,
        [bool]$Recurse
    )

    $shouldRecurse =
        if ($PSBoundParameters.ContainsKey('Recurse')) { $Recurse }
        else { $true }

    $loaded = Import-SnmpMibFilesInternal -Path $Path -Recurse:$shouldRecurse

    $loadedArray = @($loaded)

    return [PSCustomObject]@{
        LoadedFileCount = $loadedArray.Count
        LoadedFiles     = $loadedArray
    }
}

function Resolve-SNMPOidName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [bool]$SkipAutoLoad,
        [switch]$AsObjectIdentifier
    )

    $skipAutoLoadValue =
        if ($PSBoundParameters.ContainsKey('SkipAutoLoad')) { $SkipAutoLoad }
        else { $false }

    $autoLoad = -not $skipAutoLoadValue
    $oid = Resolve-SnmpOidFromNameInternal -Name $Name -AutoLoad:$autoLoad
    if ($AsObjectIdentifier) {
        return [Lextm.SharpSnmpLib.ObjectIdentifier]::new($oid)
    }

    return $oid
}

function Resolve-SNMPOidNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Oid,

        [bool]$SkipAutoLoad
    )

    $skipAutoLoadValue =
        if ($PSBoundParameters.ContainsKey('SkipAutoLoad')) { $SkipAutoLoad }
        else { $false }

    $autoLoad = -not $skipAutoLoadValue
    return Resolve-SnmpNameFromOidInternal -Oid $Oid -AutoLoad:$autoLoad
}

function Get-SNMPMibSymbol {
    [CmdletBinding()]
    param(
        [string]$NameLike,
        [bool]$SkipAutoLoad
    )

    $skipAutoLoadValue =
        if ($PSBoundParameters.ContainsKey('SkipAutoLoad')) { $SkipAutoLoad }
        else { $false }

    $autoLoad = -not $skipAutoLoadValue
    return Get-SnmpMibSymbolInternal -NameLike $NameLike -AutoLoad:$autoLoad
}
