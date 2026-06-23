function New-SnmpMibKnownOidMapInternal {
    [CmdletBinding()]
    param()

    return @{
        'iso'         = '1'
        'org'         = '1.3'
        'dod'         = '1.3.6'
        'internet'    = '1.3.6.1'
        'directory'   = '1.3.6.1.1'
        'mgmt'        = '1.3.6.1.2'
        'mib-2'       = '1.3.6.1.2.1'
        'transmission'= '1.3.6.1.2.1.10'
        'private'     = '1.3.6.1.4'
        'enterprises' = '1.3.6.1.4.1'
        'snmpV2'      = '1.3.6.1.6'
        'snmpModules' = '1.3.6.1.6.3'
    }
}

function Initialize-SnmpMibStateInternal {
    [CmdletBinding()]
    param()

    if (Get-Variable -Name SnmpMibState -Scope Script -ErrorAction SilentlyContinue) {
        return
    }

    $defaultPaths = @(
        (Join-Path $PSScriptRoot '..\..\..\mibs'),
        (Join-Path $PSScriptRoot '..\..\..\examples\mibs')
    )

    $resolvedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $defaultPaths) {
        $resolved = Resolve-SnmpMibPathInternal -Path $path -MustExist:$false
        if ($resolved -and -not $resolvedPaths.Contains($resolved)) {
            $resolvedPaths.Add($resolved)
        }
    }

    $nameToOid = New-SnmpMibKnownOidMapInternal
    $oidToName = @{}
    foreach ($entry in $nameToOid.GetEnumerator()) {
        $oidToName[$entry.Value] = $entry.Key
    }

    $script:SnmpMibState = @{
        SearchPaths = $resolvedPaths
        NameToOid   = $nameToOid
        OidToName   = $oidToName
        Edges       = @{}
        LoadedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
}

function Resolve-SnmpMibPathInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$MustExist
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        return $null
    }

    if (-not ([System.IO.Path]::IsPathRooted($expanded))) {
        $expanded = Join-Path (Get-Location).Path $expanded
    }

    $fullPath = [System.IO.Path]::GetFullPath($expanded)
    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath)) {
        throw "Path does not exist: $Path"
    }

    return $fullPath
}

function Get-SnmpMibSearchPathInternal {
    [CmdletBinding()]
    param()

    Initialize-SnmpMibStateInternal
    return @($script:SnmpMibState.SearchPaths)
}

function Set-SnmpMibSearchPathInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [switch]$Append
    )

    Initialize-SnmpMibStateInternal

    $target =
        if ($Append) { $script:SnmpMibState.SearchPaths }
        else { [System.Collections.Generic.List[string]]::new() }

    foreach ($item in $Path) {
        $resolved = Resolve-SnmpMibPathInternal -Path $item -MustExist
        if (-not $target.Contains($resolved)) {
            $target.Add($resolved)
        }
    }

    $script:SnmpMibState.SearchPaths = $target
}

function Get-SnmpMibCandidateFilesInternal {
    [CmdletBinding()]
    param(
        [string[]]$Path,
        [bool]$Recurse
    )

    Initialize-SnmpMibStateInternal

    $paths =
        if ($Path -and $Path.Count -gt 0) { $Path }
        else { Get-SnmpMibSearchPathInternal }

    $pathFromUser = $Path -and $Path.Count -gt 0

    $patterns = '*.mib', '*.txt', '*.my', '*.asn1'
    $files = [System.Collections.Generic.List[string]]::new()

    $shouldRecurse =
        if ($PSBoundParameters.ContainsKey('Recurse')) { $Recurse }
        else { $true }

    foreach ($pathItem in $paths) {
        if (-not (Test-Path -LiteralPath $pathItem)) {
            if ($pathFromUser) {
                throw "Path does not exist: $pathItem"
            }
            continue
        }

        $resolvedPath = Resolve-SnmpMibPathInternal -Path $pathItem -MustExist:$pathFromUser
        if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
            $files.Add($resolvedPath)
            continue
        }

        foreach ($pattern in $patterns) {
            $items = Get-ChildItem -Path $resolvedPath -Filter $pattern -File -ErrorAction SilentlyContinue -Recurse:$shouldRecurse
            foreach ($file in $items) {
                if (-not $files.Contains($file.FullName)) {
                    $files.Add($file.FullName)
                }
            }
        }
    }

    return @($files)
}

function Register-SnmpMibEdgeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Parent,
        [Parameter(Mandatory)]
        [int]$SubId
    )

    Initialize-SnmpMibStateInternal
    $script:SnmpMibState.Edges[$Name] = [PSCustomObject]@{
        Parent = $Parent
        SubId  = $SubId
    }
}

function Import-SnmpMibTextInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Initialize-SnmpMibStateInternal

    $withoutComments = [System.Text.RegularExpressions.Regex]::Replace($Text, '(?m)--.*$', '')

    $definitionRegex = [regex]'(?ms)^\s*(?<name>[A-Za-z][\w-]*)\b[^\r\n]*(?:OBJECT\s+IDENTIFIER|OBJECT-TYPE|OBJECT-IDENTITY|MODULE-IDENTITY|NOTIFICATION-TYPE|TRAP-TYPE|OBJECT-GROUP|NOTIFICATION-GROUP)[\s\S]*?::=\s*\{\s*(?<parent>[A-Za-z][\w-]*|\d+(?:\.\d+)*)\s+(?<subid>\d+)\s*\}'
    $inlineOidRegex = [regex]'(?im)^\s*(?<name>[A-Za-z][\w-]*)\s*::=\s*\{\s*(?<parent>[A-Za-z][\w-]*|\d+(?:\.\d+)*)\s+(?<subid>\d+)\s*\}'

    $allHits = @()
    $allHits += $definitionRegex.Matches($withoutComments)
    $allHits += $inlineOidRegex.Matches($withoutComments)

    foreach ($hit in $allHits) {
        $symbolName = $hit.Groups['name'].Value
        $parentName = $hit.Groups['parent'].Value
        $subId = [int]$hit.Groups['subid'].Value
        Register-SnmpMibEdgeInternal -Name $symbolName -Parent $parentName -SubId $subId
    }

    Resolve-SnmpMibEdgesInternal
}

function Resolve-SnmpMibEdgesInternal {
    [CmdletBinding()]
    param()

    Initialize-SnmpMibStateInternal

    $changed = $true
    $loopCount = 0

    while ($changed -and $loopCount -lt 50) {
        $changed = $false
        $loopCount++

        foreach ($entry in $script:SnmpMibState.Edges.GetEnumerator()) {
            $name = $entry.Key
            if ($script:SnmpMibState.NameToOid.ContainsKey($name)) {
                continue
            }

            $parent = $entry.Value.Parent
            $parentOid = $null

            if ($script:SnmpMibState.NameToOid.ContainsKey($parent)) {
                $parentOid = $script:SnmpMibState.NameToOid[$parent]
            }
            elseif ($parent -match '^\d+(?:\.\d+)*$') {
                $parentOid = $parent
            }

            if (-not $parentOid) {
                continue
            }

            $oid = "$parentOid.$($entry.Value.SubId)"
            $script:SnmpMibState.NameToOid[$name] = $oid
            if (-not $script:SnmpMibState.OidToName.ContainsKey($oid)) {
                $script:SnmpMibState.OidToName[$oid] = $name
            }
            $changed = $true
        }
    }
}

function Import-SnmpMibFilesInternal {
    [CmdletBinding()]
    param(
        [string[]]$Path,
        [bool]$Recurse
    )

    Initialize-SnmpMibStateInternal

    $files = Get-SnmpMibCandidateFilesInternal -Path $Path -Recurse:$Recurse
    $loaded = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $files) {
        if ($script:SnmpMibState.LoadedFiles.Contains($file)) {
            continue
        }

        $content = Get-Content -Path $file -Raw -ErrorAction Stop
        Import-SnmpMibTextInternal -Text $content
        $script:SnmpMibState.LoadedFiles.Add($file) | Out-Null
        $loaded.Add($file)
    }

    return ,@($loaded)
}

function Resolve-SnmpOidFromNameInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [bool]$AutoLoad
    )

    Initialize-SnmpMibStateInternal

    if ($AutoLoad) {
        Import-SnmpMibFilesInternal | Out-Null
    }

    if (-not $script:SnmpMibState.NameToOid.ContainsKey($Name)) {
        throw "MIB symbol not found: $Name"
    }

    return $script:SnmpMibState.NameToOid[$Name]
}

function Resolve-SnmpNameFromOidInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Oid,
        [bool]$AutoLoad
    )

    Initialize-SnmpMibStateInternal

    if ($AutoLoad) {
        Import-SnmpMibFilesInternal | Out-Null
    }

    if ($script:SnmpMibState.OidToName.ContainsKey($Oid)) {
        return $script:SnmpMibState.OidToName[$Oid]
    }

    $parts = $Oid -split '\.'
    for ($i = $parts.Count - 1; $i -gt 0; $i--) {
        $candidate = ($parts[0..($i - 1)] -join '.')
        if ($script:SnmpMibState.OidToName.ContainsKey($candidate)) {
            $suffix = $parts[$i..($parts.Count - 1)] -join '.'
            return "$($script:SnmpMibState.OidToName[$candidate]).$suffix"
        }
    }

    throw "OID not found in loaded MIB data: $Oid"
}

function Get-SnmpMibSymbolInternal {
    [CmdletBinding()]
    param(
        [string]$NameLike,
        [bool]$AutoLoad
    )

    Initialize-SnmpMibStateInternal

    if ($AutoLoad) {
        Import-SnmpMibFilesInternal | Out-Null
    }

    $entries = foreach ($entry in $script:SnmpMibState.NameToOid.GetEnumerator()) {
        [PSCustomObject]@{
            Name = $entry.Key
            Oid  = $entry.Value
        }
    }

    if ($NameLike) {
        return $entries | Where-Object { $_.Name -like $NameLike } | Sort-Object Name
    }

    return $entries | Sort-Object Name
}
