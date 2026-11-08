# Private, data-only reader. See docs\zabbix-template-conversion.md for its current syntax coverage.
$yamlReaderDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $yamlReaderDir 'YamlNodes.ps1')
function Stop-ZabbixYaml {
    param($State, [string]$Message, [int]$Line = -1)
    if ($Line -lt 0) {
        $Line = $State.Index + 1
        if ($State.ContainsKey('DiagnosticLine')) { $Line = $State.DiagnosticLine }
    }
    throw "$($State.Source):${Line}: $Message"
}

function New-ZabbixMap {
    New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
}

function Get-ZabbixYamlAlias {
    param($State, [string]$Name)
    if (-not $State.Anchors.ContainsKey($Name)) { Stop-ZabbixYaml $State "Unknown YAML alias '$Name'." }
    $node = New-WUGYamlNode $State 'Alias' $Name
    $node.Target = $State.Anchors[$Name]
    return $node
}

function Get-ZabbixYamlIndent {
    param($State, [string]$Line)
    return $Line.Length - $Line.TrimStart(' ').Length
}

function Skip-ZabbixYamlBlank {
    param($State)
    while ($State.Index -lt $State.Lines.Count) {
        if ($State.Lines[$State.Index] -notmatch '^\s*(#.*)?$') { break }
        $State.Index++
    }
}

function Find-ZabbixYamlColon {
    param([string]$Text)
    $quote = [char]0
    $depth = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($quote -ne [char]0) {
            if ($quote -eq '"' -and $c -eq '\') { $i++; continue }
            if ($c -eq $quote) {
                if ($quote -eq "'" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++ }
                else { $quote = [char]0 }
            }
        }
        elseif ($c -eq '#' -and ($i -eq 0 -or $Text[$i - 1] -match '[ \t]')) { return -1 }
        elseif (($c -eq '&' -or $c -eq '!' -or $c -eq '*') -and $Text.Substring(0, $i).Trim() -match '^(?:[!&][^\s]+\s*)*$') {
            while ($i + 1 -lt $Text.Length -and $Text[$i + 1] -notmatch '[ \t]') { $i++ }
        }
        elseif (($c -eq "'" -or $c -eq '"') -and ($depth -gt 0 -or $Text.Substring(0, $i).Trim() -match '^(?:[!&][^\s]+\s*)*$')) { $quote = $c }
        elseif (($c -eq '[' -or $c -eq '{') -and ($depth -gt 0 -or $Text.Substring(0, $i).Trim() -match '^(?:[!&][^\s]+\s*)*$')) { $depth++ }
        elseif (($c -eq ']' -or $c -eq '}') -and $depth -gt 0) { $depth-- }
        elseif ($depth -eq 0 -and $c -eq ':' -and ($i + 1 -eq $Text.Length -or $Text[$i + 1] -match '[ \t]')) { return $i }
    }
    return -1
}

function Get-ZabbixYamlProperties {
    param($State, [string]$Text)
    $anchor = $null
    $tag = $null
    while ($Text -cmatch '^(?<property>&[^\s,\[\]{}]+|!<[^>]+>|![^\s,\[\]{}]*)(?:[ \t\r\n]+|(?=[,\]}])|$)') {
        $property = $Matches['property']
        $Text = $Text.Substring($Matches[0].Length)
        if ($property[0] -eq '&') {
            if ($null -ne $anchor) { Stop-ZabbixYaml $State 'A node cannot have two anchors.' }
            $anchor = $property.Substring(1)
        }
        else {
            if ($null -ne $tag) { Stop-ZabbixYaml $State 'A node cannot have two tags.' }
            if ($property -ceq '!') { $tag = '!'; continue }
            if ($property.StartsWith('!<')) { $tag = $property.Substring(2, $property.Length - 3) }
            else {
                $handle = '!'
                $suffix = $property.Substring(1)
                if ($property -cmatch '^(![^!]*!)(.*)$') { $handle = $Matches[1]; $suffix = $Matches[2] }
                if (-not $State.Tags.ContainsKey($handle)) { Stop-ZabbixYaml $State "Undefined YAML tag handle '$handle'." }
                $tag = $State.Tags[$handle] + $suffix
            }
            if ($tag -match '%(?![0-9a-fA-F]{2})') { Stop-ZabbixYaml $State 'Invalid percent escape in YAML tag.' }
            $tag = [Uri]::UnescapeDataString($tag)
        }
    }
    [PSCustomObject]@{ Text = $Text; Anchor = $anchor; Tag = $tag; Node = $null }
}

function Set-ZabbixYamlProperties {
    param($State, $Properties, [AllowNull()]$Value)
    if ($null -ne $Properties.Tag) {
        if ($null -ne $Value.Tag) { Stop-ZabbixYaml $State 'A node cannot have two tags.' }
        $Value.Tag = $Properties.Tag
    }
    if ($null -ne $Properties.Anchor) {
        if ($null -ne $Value.Anchor) { Stop-ZabbixYaml $State 'A node cannot have two anchors.' }
        $Value.Anchor = $Properties.Anchor
        $target = $Properties.Node
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -cne 'Id') { $target.($property.Name) = $property.Value }
        }
        return $target
    }
    return $Value
}

function Add-ZabbixYamlFlowLine {
    param($Flow)
    $state = $Flow.State
    if (-not $Flow.Multiline -or $state.Index -ge $state.Lines.Count) { return $false }
    $line = $state.Lines[$state.Index]
    if ($line -match '^(---|\.\.\.)(\s|$)') { Stop-ZabbixYaml $state 'Unterminated flow collection before document boundary.' ($state.Index + 1) }
    if ($line -notmatch '^[ \t]*(#.*)?$' -and (Get-ZabbixYamlIndent $state $line) -le $Flow.ParentIndent) {
        Stop-ZabbixYaml $state 'Flow continuation is not indented beyond its block parent.' ($state.Index + 1)
    }
    $Flow.Text += "`n" + $line
    $state.Index++
    return $true
}

function Skip-ZabbixYamlFlowSpace {
    param($Flow)
    while ($true) {
        if ($Flow.Index -ge $Flow.Text.Length) {
            if (Add-ZabbixYamlFlowLine $Flow) { continue }
            return
        }
        $c = $Flow.Text[$Flow.Index]
        if ($c -eq "`n") { $Flow.Line++ }
        elseif ($c -eq '#' -and ($Flow.Index -eq 0 -or [char]::IsWhiteSpace($Flow.Text[$Flow.Index - 1]))) {
            while ($Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -ne "`n") { $Flow.Index++ }
            continue
        }
        elseif (-not [char]::IsWhiteSpace($c)) { return }
        $Flow.Index++
    }
}

function Read-ZabbixYamlFlowNode {
    param($Flow, [int]$Depth, [switch]$Key)
    $state = $Flow.State
    if ($Depth -gt 64) { Stop-ZabbixYaml $state 'Maximum nesting depth (64) exceeded.' $Flow.Line }
    Skip-ZabbixYamlFlowSpace $Flow
    $state.DiagnosticLine = $Flow.Line
    if ($Flow.Index -ge $Flow.Text.Length) { Stop-ZabbixYaml $state 'Unterminated flow collection.' }
    $start = $Flow.Index
    $c = $Flow.Text[$start]
    if ($Key -and $c -eq ':' -and ($start + 1 -eq $Flow.Text.Length -or
        $Flow.Text[$start + 1] -match '[ \t\r\n,\[\]{}]')) { return New-WUGYamlNode $state 'Scalar' '' 'Plain' }
    if ($c -eq '&' -or $c -eq '!') {
        $properties = Get-ZabbixYamlProperties $state $Flow.Text.Substring($start)
        if ($null -eq $properties.Anchor -and $null -eq $properties.Tag) { Stop-ZabbixYaml $state 'Invalid YAML node property.' }
        $consumed = $Flow.Text.Length - $start - $properties.Text.Length
        $Flow.Line += ([regex]::Matches($Flow.Text.Substring($start, $consumed), '\n')).Count
        $Flow.Index += $consumed
        Skip-ZabbixYamlFlowSpace $Flow
        if ($Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -eq '*') { Stop-ZabbixYaml $state 'Aliases cannot have tags or anchors.' }
        Initialize-WUGYamlAnchor $state $properties
        $value = New-WUGYamlNode $state 'Scalar' '' 'Plain'
        if ($Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -cnotin @(',', ']', '}')) {
            $value = Read-ZabbixYamlFlowNode $Flow ($Depth + 1) -Key:$Key
        }
        return Set-ZabbixYamlProperties $state $properties $value
    }
    if ($c -eq '[' -or $c -eq '{') {
        $sequence = $c -eq '['
        $close = if ($sequence) { ']' } else { '}' }
        $Flow.Index++
        $nodeKind = 'Mapping'
        if ($sequence) { $nodeKind = 'Sequence' }
        $node = New-WUGYamlNode $state $nodeKind '' 'Flow'
        while ($true) {
            Skip-ZabbixYamlFlowSpace $Flow
            if ($Flow.Index -ge $Flow.Text.Length) { Stop-ZabbixYaml $state 'Unterminated flow collection.' $Flow.Line }
            if ($Flow.Text[$Flow.Index] -eq $close) { $Flow.Index++; break }
            $keyStart = $Flow.Index
            $keyLine = $Flow.Line
            $explicitPair = $Flow.Text.Substring($Flow.Index) -match '^\?(\s|$)'
            if ($explicitPair) { $Flow.Index++; Skip-ZabbixYamlFlowSpace $Flow; $keyStart = $Flow.Index }
            if ($explicitPair -and $Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -cin @(',', $close)) {
                $entry = New-WUGYamlNode $state 'Scalar' '' 'Plain'
            }
            else { $entry = Read-ZabbixYamlFlowNode $Flow ($Depth + 1) -Key }
            $keyEnd = $Flow.Index
            Skip-ZabbixYamlFlowSpace $Flow
            $pair = $Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -eq ':'
            if ($sequence -and $pair -and -not $explicitPair -and $Flow.Line -ne $keyLine) {
                Stop-ZabbixYaml $state 'Implicit mapping keys must fit on one line.' $Flow.Line
            }
            if (-not $sequence -or $pair -or $explicitPair) {
                $value = New-WUGYamlNode $state 'Scalar' '' 'Plain'
                if ($pair) {
                    $Flow.Index++
                    Skip-ZabbixYamlFlowSpace $Flow
                    if ($Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -cnotin @(',', $close)) {
                        $value = Read-ZabbixYamlFlowNode $Flow ($Depth + 1)
                    }
                }
                if ($sequence) {
                    $entryMap = New-WUGYamlNode $state 'Mapping' '' 'FlowPair'
                    $entryMap.Pairs.Add([PSCustomObject]@{ Key = $entry; Value = $value })
                    $node.Items.Add($entryMap)
                }
                else {
                    $node.Pairs.Add([PSCustomObject]@{ Key = $entry; Value = $value })
                }
            }
            else { $node.Items.Add($entry) }
            Skip-ZabbixYamlFlowSpace $Flow
            if ($Flow.Index -ge $Flow.Text.Length) { Stop-ZabbixYaml $state 'Unterminated flow collection.' $Flow.Line }
            $separator = $Flow.Text[$Flow.Index]
            if ($separator -eq $close) { $Flow.Index++; break }
            if ($separator -ne ',') { Stop-ZabbixYaml $state "Expected ',' or '$close' in flow collection." $Flow.Line }
            $Flow.Index++
        }
        return $node
    }
    if ($c -eq "'" -or $c -eq '"') {
        $Flow.Index++
        $closed = $false
        while ($true) {
            if ($Flow.Index -ge $Flow.Text.Length) {
                if (Add-ZabbixYamlFlowLine $Flow) { continue }
                break
            }
            $current = $Flow.Text[$Flow.Index]
            if ($current -eq "`n") { $Flow.Line++ }
            $Flow.Index++
            if ($c -eq '"' -and $current -eq '\') {
                if ($Flow.Index -ge $Flow.Text.Length) { [void](Add-ZabbixYamlFlowLine $Flow) }
                if ($Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -eq "`n") { $Flow.Line++ }
                $Flow.Index++
                continue
            }
            if ($current -eq $c) {
                if ($c -eq "'" -and $Flow.Index -lt $Flow.Text.Length -and $Flow.Text[$Flow.Index] -eq "'") { $Flow.Index++; continue }
                $closed = $true
                break
            }
        }
        if (-not $closed) { Stop-ZabbixYaml $state 'Unterminated quoted scalar.' $Flow.Line }
        $style = 'SingleQuoted'
        if ($c -eq '"') { $style = 'DoubleQuoted' }
        return New-WUGYamlNode $state 'Scalar' (ConvertFrom-ZabbixYamlQuoted $state $Flow.Text.Substring($start, $Flow.Index - $start)) $style
    }
    if ($c -cin @(',', ']', '}', '[', '{')) { Stop-ZabbixYaml $state 'Missing flow node or mismatched delimiter.' $Flow.Line }
    while ($true) {
        if ($Flow.Index -ge $Flow.Text.Length) {
            if (Add-ZabbixYamlFlowLine $Flow) { continue }
            break
        }
        $current = $Flow.Text[$Flow.Index]
        if ($current -cin @(',', '[', ']', '{', '}')) { break }
        if ($current -eq '#' -and ($Flow.Index -eq $start -or [char]::IsWhiteSpace($Flow.Text[$Flow.Index - 1]))) { break }
        if ($current -eq ':' -and ($Flow.Index + 1 -eq $Flow.Text.Length -or
            [char]::IsWhiteSpace($Flow.Text[$Flow.Index + 1]) -or $Flow.Text[$Flow.Index + 1] -cin @(',', '[', ']', '{', '}'))) {
            if ($Key) { break }
            Stop-ZabbixYaml $state 'A colon followed by separation is not allowed in a plain flow value.' $Flow.Line
        }
        if ($current -eq "`n") { $Flow.Line++ }
        $Flow.Index++
    }
    $raw = $Flow.Text.Substring($start, $Flow.Index - $start).Trim()
    if (-not $raw) { Stop-ZabbixYaml $state 'Missing flow scalar.' $Flow.Line }
    $raw = [regex]::Replace($raw, '[ \t]*\n[ \t]*(?:\n[ \t]*)*', {
        param($match)
        $breaks = ([regex]::Matches($match.Value, '\n')).Count
        if ($breaks -eq 1) { return ' ' }
        return "`n" * ($breaks - 1)
    })
    return ,(Read-ZabbixYamlScalar $state $raw ($Depth + 1) -Key:$Key)
}

function Read-ZabbixYamlFlow {
    param($State, [string]$Text, [int]$Depth, [switch]$Multiline, [int]$ParentIndent = -1)
    $line = $State.Index + 1
    if ($State.ContainsKey('DiagnosticLine')) { $line = $State.DiagnosticLine }
    $flow = @{ Text = $Text; Index = 0; Line = $line; State = $State; Multiline = [bool]$Multiline; ParentIndent = $ParentIndent }
    $value = Read-ZabbixYamlFlowNode $flow $Depth
    $tail = $flow.Text.Substring($flow.Index)
    if ($tail -notmatch '^(?:\s*|\s+#.*)$') { Stop-ZabbixYaml $State 'Unexpected content after flow collection.' $flow.Line }
    return ,$value
}

function ConvertFrom-ZabbixYamlQuoted {
    param($State, [string]$Text)
    $quote = $Text[0]
    $builder = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq "`n") {
            $breaks = 1
            while ($i + 1 -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i + 1])) {
                $i++
                if ($Text[$i] -eq "`n") { $breaks++ }
            }
            if ($breaks -eq 1) { [void]$builder.Append(' ') }
            else { [void]$builder.Append("`n" * ($breaks - 1)) }
            continue
        }
        if ($c -eq $quote) {
            if ($quote -eq "'" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
                [void]$builder.Append("'"); $i++; continue
            }
            $tail = $Text.Substring($i + 1)
            if ($tail -notmatch '^(?:\s*|\s+#.*)$') { Stop-ZabbixYaml $State 'Unexpected content after quoted scalar.' }
            return $builder.ToString()
        }
        if ($quote -eq '"' -and $c -eq '\') {
            $i++
            if ($i -ge $Text.Length) { Stop-ZabbixYaml $State 'Incomplete escape sequence.' }
            $escape = $Text[$i]
            if ($escape -eq "`n") {
                while ($i + 1 -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i + 1])) {
                    $i++
                    if ($Text[$i] -eq "`n") { [void]$builder.Append("`n") }
                }
                continue
            }
            $decoded = switch -CaseSensitive ($escape) {
                '0' { [char]0 } 'a' { [char]7 } 'b' { [char]8 } 't' { [char]9 } 'n' { [char]10 }
                'v' { [char]11 } 'f' { [char]12 } 'r' { [char]13 } 'e' { [char]27 } ' ' { ' ' }
                '"' { '"' } '/' { '/' } '\' { '\' } 'N' { [char]0x85 } '_' { [char]0xa0 }
                "`t" { [char]9 }
                'L' { [char]0x2028 } 'P' { [char]0x2029 } default { $null }
            }
            if ($null -ne $decoded) { [void]$builder.Append($decoded); continue }
            $length = switch -CaseSensitive ($escape) { 'x' { 2 } 'u' { 4 } 'U' { 8 } default { 0 } }
            if (-not $length -or $i + $length -ge $Text.Length) { Stop-ZabbixYaml $State 'Invalid quoted escape.' }
            $hex = $Text.Substring($i + 1, $length)
            if ($hex -notmatch '^[0-9a-fA-F]+$') { Stop-ZabbixYaml $State 'Invalid Unicode escape.' }
            $code = [Convert]::ToInt64($hex, 16)
            if ($code -gt 0x10ffff -or ($code -ge 0xd800 -and $code -le 0xdfff)) { Stop-ZabbixYaml $State 'Invalid Unicode code point.' }
            [void]$builder.Append([char]::ConvertFromUtf32([int]$code))
            $i += $length
        }
        else {
            if ($c -cin @(' ', "`t") -and $Text.Substring($i) -match '^[ \t]+\n') { continue }
            [void]$builder.Append($c)
        }
    }
    Stop-ZabbixYaml $State 'Unterminated quoted scalar.'
}

function Test-ZabbixYamlQuoteClosed {
    param([string]$Text)
    $quote = $Text[0]
    for ($i = 1; $i -lt $Text.Length; $i++) {
        if ($quote -eq '"' -and $Text[$i] -eq '\') { $i++; continue }
        if ($Text[$i] -eq $quote) {
            if ($quote -eq "'" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
            return $true
        }
    }
    return $false
}

function Read-ZabbixYamlScalar {
    param($State, [string]$Text, [int]$Depth, [switch]$Key)
    if ($Depth -gt 64) { Stop-ZabbixYaml $State 'Maximum nesting depth (64) exceeded.' }
    $Text = $Text.Trim()
    if (-not $Text -or $Text.StartsWith('#')) { return New-WUGYamlNode $State 'Scalar' '' 'Plain' }
    if ($Text[0] -eq "'" -or $Text[0] -eq '"') {
        $style = 'SingleQuoted'
        if ($Text[0] -eq '"') { $style = 'DoubleQuoted' }
        return New-WUGYamlNode $State 'Scalar' (ConvertFrom-ZabbixYamlQuoted $State $Text) $style
    }
    if ($Text -match '^\*([^\s,\[\]{}]+)(?:\s+#.*)?$') { return ,(Get-ZabbixYamlAlias $State $Matches[1]) }
    if ($Text[0] -cin @('&', '!')) {
        $properties = Get-ZabbixYamlProperties $State $Text
        if ($null -eq $properties.Anchor -and $null -eq $properties.Tag) { Stop-ZabbixYaml $State 'Invalid YAML node property.' }
        if ($properties.Text.StartsWith('*')) { Stop-ZabbixYaml $State 'Aliases cannot have tags or anchors.' }
        Initialize-WUGYamlAnchor $State $properties
        $value = Read-ZabbixYamlScalar $State $properties.Text ($Depth + 1)
        return ,(Set-ZabbixYamlProperties $State $properties $value)
    }
    if ($Text -match '^[,&*!%@`|\]}>]|^\?(\s|$)|^<<\s*:') {
        Stop-ZabbixYaml $State 'Invalid or unsupported YAML indicator.'
    }
    if ($Text[0] -eq '[' -or $Text[0] -eq '{') {
        return ,(Read-ZabbixYamlFlow $State $Text ($Depth + 1))
    }
    $Text = [regex]::Replace($Text, '\s+#.*$', '').TrimEnd()
    if ($Text -match ':\s|^-(\s|$)' -or (-not $Key -and $Text.EndsWith(':'))) { Stop-ZabbixYaml $State 'Invalid indicator in plain scalar.' }
    return New-WUGYamlNode $State 'Scalar' $Text 'Plain'
}

function Read-ZabbixYamlValue {
    param($State, [string]$Text, [int]$Indent, [int]$Depth, [switch]$NoAlias, [switch]$IndentlessSequence)
    if ($Depth -gt 64) { Stop-ZabbixYaml $State 'Maximum nesting depth (64) exceeded.' }
    $Text = $Text.TrimStart()
    if ($NoAlias -and $Text.StartsWith('*')) { Stop-ZabbixYaml $State 'Aliases cannot have tags or anchors.' }
    if ($Text -and $Text[0] -cin @('&', '!')) {
        $properties = Get-ZabbixYamlProperties $State $Text
        if ($null -eq $properties.Anchor -and $null -eq $properties.Tag) { Stop-ZabbixYaml $State 'Invalid YAML node property.' }
        if ($properties.Text.StartsWith('*')) { Stop-ZabbixYaml $State 'Aliases cannot have tags or anchors.' }
        Initialize-WUGYamlAnchor $State $properties
        $value = Read-ZabbixYamlValue $State $properties.Text $Indent ($Depth + 1) -NoAlias -IndentlessSequence:$IndentlessSequence
        return ,(Set-ZabbixYamlProperties $State $properties $value)
    }
    if (-not $Text -or $Text.StartsWith('#')) {
        Skip-ZabbixYamlBlank $State
        if ($State.Index -lt $State.Lines.Count) {
            $next = $State.Lines[$State.Index]
            $nextIndent = Get-ZabbixYamlIndent $State $next
            if ($nextIndent -gt $Indent -or ($IndentlessSequence -and $nextIndent -eq $Indent -and $next.TrimStart() -match '^-(\s|$)')) {
                return ,(Read-ZabbixYamlBlock $State $nextIndent ($Depth + 1) -NoAlias:$NoAlias -ParentIndent $Indent -IndentlessSequence:$IndentlessSequence)
            }
        }
        return New-WUGYamlNode $State 'Scalar' '' 'Plain'
    }
    if ($Text.TrimEnd() -match '^([|>])([+-]?)([1-9]?)(?:\s+#.*)?$' -or $Text.TrimEnd() -match '^([|>])([1-9])([+-]?)(?:\s+#.*)?$') {
        $style = $Text[0]
        $indicator = ($Text -split '\s', 2)[0]
        $chomp = if ($indicator.Contains('-')) { '-' } elseif ($indicator.Contains('+')) { '+' } else { '' }
        $digit = [regex]::Match($indicator, '[1-9]').Value
        $contentIndent = -1
        if ($digit) { $contentIndent = [Math]::Max(0, $Indent) + [int]$digit }
        $lines = [System.Collections.Generic.List[string]]::new()
        $leadingIndent = 0
        while ($State.Index -lt $State.Lines.Count) {
            $line = $State.Lines[$State.Index]
            $State.DiagnosticLine = $State.Index + 1
            if ($line -match '^(---|\.\.\.)([ \t]|$)') { break }
            $actual = $line.Length - $line.TrimStart(' ').Length
            if ($line -notmatch '^ *$') {
                if ($actual -le $Indent) {
                    if ($line.Substring($actual).StartsWith("`t")) { Stop-ZabbixYaml $State 'Tabs cannot indent block scalar content.' }
                    break
                }
                if ($contentIndent -lt 0) {
                    $contentIndent = $actual
                    if ($leadingIndent -gt $contentIndent) { Stop-ZabbixYaml $State 'Leading empty lines exceed the block scalar content indentation.' }
                }
                if ($actual -lt $contentIndent) {
                    if ($line.Substring($actual).StartsWith('#')) { break }
                    Stop-ZabbixYaml $State 'Invalid block scalar indentation.'
                }
                $lines.Add($line.Substring($contentIndent))
            }
            else {
                if ($contentIndent -lt 0) { $leadingIndent = [Math]::Max($leadingIndent, $actual); $lines.Add('') }
                else { $lines.Add($line.Substring([Math]::Min($contentIndent, $line.Length))) }
            }
            $State.Index++
        }
        $builder = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            [void]$builder.Append($lines[$i])
            $separator = "`n"
            if ($i + 1 -eq $lines.Count -and $State.Index -eq $State.Lines.Count -and -not $State.FinalBreak -and $lines[$i].Trim(' ').Length -gt 0) {
                $separator = ''
            }
            elseif ($style -eq '>' -and $i + 1 -lt $lines.Count -and $lines[$i] -and $lines[$i] -notmatch '^[ \t]') {
                if ($lines[$i + 1] -and $lines[$i + 1] -notmatch '^[ \t]') { $separator = ' ' }
                elseif (-not $lines[$i + 1]) {
                    $look = $i + 1
                    while ($look -lt $lines.Count -and -not $lines[$look]) { $look++ }
                    if ($look -lt $lines.Count -and $lines[$look] -notmatch '^[ \t]') { $separator = '' }
                }
            }
            [void]$builder.Append($separator)
        }
        $value = $builder.ToString()
        if ($chomp -eq '-') { $value = $value.TrimEnd("`n") }
        elseif ($chomp -ne '+' -and $value.EndsWith("`n")) {
            if ($value.Trim("`n").Length -eq 0) { $value = '' }
            else { $value = $value.TrimEnd("`n") + "`n" }
        }
        $nodeStyle = 'Literal'
        if ($style -eq '>') { $nodeStyle = 'Folded' }
        return New-WUGYamlNode $State 'Scalar' $value $nodeStyle
    }
    if ($Text[0] -eq '[' -or $Text[0] -eq '{') { return ,(Read-ZabbixYamlFlow $State $Text ($Depth + 1) -Multiline -ParentIndent $Indent) }
    if ($Text[0] -eq "'" -or $Text[0] -eq '"') {
        while (-not (Test-ZabbixYamlQuoteClosed $Text)) {
            if ($State.Index -ge $State.Lines.Count) { Stop-ZabbixYaml $State 'Unterminated quoted scalar.' }
            $next = $State.Lines[$State.Index]
            $State.DiagnosticLine = $State.Index + 1
            if ($next -match '^(---|\.\.\.)([ \t]|$)') { Stop-ZabbixYaml $State 'Document boundary inside quoted scalar.' }
            $nextIndent = $next.Length - $next.TrimStart(' ').Length
            if ($next.Trim() -and $nextIndent -le $Indent) {
                Stop-ZabbixYaml $State 'Invalid multiline quoted scalar indentation.'
            }
            $State.Index++
            $Text += "`n" + $next
        }
        return Read-ZabbixYamlScalar $State $Text ($Depth + 1)
    }
    $value = Read-ZabbixYamlScalar $State $Text ($Depth + 1)
    if ($value.Kind -ceq 'Scalar' -and $value.Style -ceq 'Plain' -and $Text -notmatch '^[\[\{*&]' -and $Text -notmatch '[ \t]+#') {
        $cursor = $State.Index
        $blanks = 0
        while ($cursor -lt $State.Lines.Count) {
            $line = $State.Lines[$cursor]
            if ($line -match '^(---|\.\.\.)(\s|$)') { break }
            if (-not $line.Trim()) { $blanks++; $cursor++; continue }
            if ($line.TrimStart().StartsWith('#')) { break }
            $actual = Get-ZabbixYamlIndent $State $line
            if ($actual -le $Indent) { break }
            $continuation = [regex]::Replace($line.Trim(), '\s+#.*$', '')
            if ($continuation -match ':[ \t]') { Stop-ZabbixYaml $State 'Invalid plain scalar continuation.' ($cursor + 1) }
            $separator = if ($blanks -gt 0) { "`n" * $blanks } else { ' ' }
            $value.Value += $separator + $continuation
            $cursor++
            $State.Index = $cursor
            $blanks = 0
            if ($line -match '[ \t]+#') { break }
        }
    }
    return ,$value
}

function Read-ZabbixYamlMapping {
    param($State, [int]$Indent, [int]$Depth, [string]$First = '')
    $map = New-WUGYamlNode $State 'Mapping' '' 'Block'
    $pending = $First.Length -gt 0
    while ($true) {
        if ($pending) { $text = $First; $pending = $false }
        else {
            Skip-ZabbixYamlBlank $State
            if ($State.Index -ge $State.Lines.Count) { break }
            $line = $State.Lines[$State.Index]
            $State.DiagnosticLine = $State.Index + 1
            $actual = Get-ZabbixYamlIndent $State $line
            if ($actual -lt $Indent -or $line -match '^(---|\.\.\.)(\s|$)') { break }
            if ($actual -eq $Indent -and $line.TrimStart() -match '^-(\s|$)') { break }
            if ($actual -ne $Indent) { Stop-ZabbixYaml $State 'Unexpected indentation or unsupported multiline plain scalar.' }
            $text = $line.Substring($Indent)
            if ($text.StartsWith("`t")) { Stop-ZabbixYaml $State 'Tabs cannot indent block mapping entries.' }
            $State.Index++
        }
        $explicitKey = $text -match '^\?(\s|$)'
        $keyText = $null
        $valueText = ''
        if ($explicitKey) {
            $keyText = $text.Substring(1).Trim()
            $keyPrefix = $text.Substring(1, $text.Length - $text.Substring(1).TrimStart().Length - 1)
            if ($keyPrefix.Contains("`t") -and ($keyText -match '^-(\s|$)' -or (Find-ZabbixYamlColon $keyText) -ge 0)) {
                Stop-ZabbixYaml $State 'Tabs cannot indent compact explicit keys.'
            }
            if ($keyText -match '^-(\s|$)') { $key = Read-ZabbixYamlSequence $State ($Indent + 2) ($Depth + 1) $keyText }
            elseif ((Find-ZabbixYamlColon $keyText) -ge 0) {
                $key = Read-ZabbixYamlMapping $State ($Indent + 2) ($Depth + 1) $keyText
            }
            else { $key = Read-ZabbixYamlValue $State $keyText $Indent ($Depth + 1) -IndentlessSequence:([string]::IsNullOrWhiteSpace($keyText) -or $keyText.StartsWith('#')) }
            Skip-ZabbixYamlBlank $State
            if ($State.Index -lt $State.Lines.Count) {
                $next = $State.Lines[$State.Index]
                if ((Get-ZabbixYamlIndent $State $next) -eq $Indent -and $next.Substring($Indent) -match '^:(\s|$)') {
                    $valueText = $next.Substring($Indent + 1)
                    $State.Index++
                }
            }
        }
        else {
            $colon = Find-ZabbixYamlColon $text
            if ($colon -lt 0) { Stop-ZabbixYaml $State 'Expected a mapping key followed by a colon.' }
            $keyText = $text.Substring(0, $colon).Trim()
            $valueText = $text.Substring($colon + 1)
            $key = Read-ZabbixYamlScalar $State $keyText ($Depth + 1) -Key
        }
        if ($valueText.TrimStart() -match '^-(\s|$)') {
            if (-not $explicitKey) { Stop-ZabbixYaml $State 'Compact block values require an explicit key.' }
            if ($valueText.Substring(0, $valueText.Length - $valueText.TrimStart().Length).Contains("`t")) { Stop-ZabbixYaml $State 'Tabs cannot indent compact explicit values.' }
            $value = Read-ZabbixYamlSequence $State ($Indent + 2) ($Depth + 1) $valueText.TrimStart()
        }
        elseif ($explicitKey -and $valueText.TrimStart() -notmatch '^[\[{]' -and (Find-ZabbixYamlColon $valueText.TrimStart()) -ge 0) {
            if ($valueText.Substring(0, $valueText.Length - $valueText.TrimStart().Length).Contains("`t")) { Stop-ZabbixYaml $State 'Tabs cannot indent compact explicit values.' }
            $value = Read-ZabbixYamlMapping $State ($Indent + 2) ($Depth + 1) $valueText.TrimStart()
        }
        else { $value = Read-ZabbixYamlValue $State $valueText $Indent ($Depth + 1) -IndentlessSequence }
        $map.Pairs.Add([PSCustomObject]@{ Key = $key; Value = $value })
    }
    return ,$map
}

function Read-ZabbixYamlBlock {
    param($State, [int]$Indent, [int]$Depth, [switch]$NoAlias, [int]$ParentIndent = [int]::MinValue, [switch]$IndentlessSequence)
    if ($Depth -gt 64) { Stop-ZabbixYaml $State 'Maximum nesting depth (64) exceeded.' }
    Skip-ZabbixYamlBlank $State
    if ($State.Index -ge $State.Lines.Count) { return New-WUGYamlNode $State 'Scalar' '' 'Plain' }
    $first = $State.Lines[$State.Index].Substring($Indent)
    if ($first -notmatch '^-(\s|$)') {
        $nodeText = $first
        if ($first -match '^[!&]') { $nodeText = (Get-ZabbixYamlProperties $State $first).Text }
        if ($first -match '^\?(\s|$)' -or (Find-ZabbixYamlColon $first) -ge 0) {
            return ,(Read-ZabbixYamlMapping $State $Indent $Depth)
        }
        $State.DiagnosticLine = $State.Index + 1
        $State.Index++
        $valueIndent = $ParentIndent
        if ($valueIndent -eq [int]::MinValue) { $valueIndent = $Indent - 1 }
        return ,(Read-ZabbixYamlValue $State $first $valueIndent ($Depth + 1) -NoAlias:$NoAlias -IndentlessSequence:$IndentlessSequence)
    }
    return ,(Read-ZabbixYamlSequence $State $Indent $Depth)
}

function Read-ZabbixYamlSequence {
    param($State, [int]$Indent, [int]$Depth, [string]$First = '')
    if ($Depth -gt 64) { Stop-ZabbixYaml $State 'Maximum nesting depth (64) exceeded.' }
    $sequenceNode = New-WUGYamlNode $State 'Sequence' '' 'Block'
    $items = $sequenceNode.Items
    $pending = $First.Length -gt 0
    while ($pending -or $State.Index -lt $State.Lines.Count) {
        if ($pending) { $text = $First; $pending = $false }
        else {
            Skip-ZabbixYamlBlank $State
            if ($State.Index -ge $State.Lines.Count) { break }
            $line = $State.Lines[$State.Index]
            $State.DiagnosticLine = $State.Index + 1
            $actual = Get-ZabbixYamlIndent $State $line
            if ($actual -lt $Indent) { break }
            $text = $line.Substring($actual)
            if ($actual -eq $Indent -and $text -notmatch '^-(\s|$)') { break }
            if ($actual -ne $Indent) { Stop-ZabbixYaml $State 'Unexpected sequence indentation.' }
            $State.Index++
        }
        $rest = $text.Substring(1).TrimStart()
        $entryIndent = $Indent + $text.Length - $rest.Length
        $body = $rest
        $properties = $null
        if ($rest -match '^[!&]') { $properties = Get-ZabbixYamlProperties $State $rest; $body = $properties.Text }
        $compactMap = $body -notmatch '^[\[{]' -and ((Find-ZabbixYamlColon $body) -ge 0 -or $body -match '^\?(\s|$)')
        $compactSequence = $body -match '^-(\s|$)'
        if ($compactMap -or $compactSequence) {
            if ($text.Substring(1, $text.Length - $rest.Length - 1).Contains("`t")) { Stop-ZabbixYaml $State 'Tabs cannot indent compact collections.' }
            if ($compactMap) { $value = Read-ZabbixYamlMapping $State $entryIndent ($Depth + 1) $rest }
            else {
                if ($null -ne $properties) { Stop-ZabbixYaml $State 'Compact sequences cannot have node properties; put properties on the preceding line.' }
                $value = Read-ZabbixYamlSequence $State $entryIndent ($Depth + 1) $body
            }
            $items.Add($value)
        }
        else { $items.Add((Read-ZabbixYamlValue $State $rest $Indent ($Depth + 1))) }
    }
    return $sequenceNode
}

function Read-WUGYamlStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Source = '<input>',
        [ValidateSet('Failsafe', 'JSON', 'Core')][string]$Schema = 'Core',
        [switch]$SyntaxOnly
    )
    if ($Text.Length -gt 16777216) { throw "${Source}: YAML input exceeds the 16 Mi-character limit." }
    $invalid = [regex]::Match($Text, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x84\x86-\x9f\ufffe\uffff]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]')
    if ($invalid.Success) {
        $line = 1 + ([regex]::Matches($Text.Substring(0, $invalid.Index), '\r\n|\r|\n')).Count
        throw "${Source}:${line}: YAML contains a non-printable character or unpaired surrogate."
    }
    $lines = [regex]::Split($Text.TrimStart([char]0xfeff), '\r\n|\n|\r')
    $finalBreak = $Text -match '[\r\n]$'
    if ($finalBreak) { $lines = @($lines | Select-Object -SkipLast 1) }
    $state = @{
        Lines = $lines
        FinalBreak = $finalBreak
        Index = 0
        Source = $Source
        Anchors = New-ZabbixMap
        Tags = New-ZabbixMap
        NextNodeId = 0
    }
    $documents = [System.Collections.Generic.List[object]]::new()
    Skip-ZabbixYamlBlank $state
    while ($state.Index -lt $state.Lines.Count) {
        if ($state.Lines[$state.Index] -match '^\.\.\.(?:[ \t]*|[ \t]+#.*)$') {
            $state.Index++
            Skip-ZabbixYamlBlank $state
            continue
        }
        $state.Anchors = New-ZabbixMap
        $state.Tags = New-ZabbixMap
        $state.Tags.Add('!!', 'tag:yaml.org,2002:')
        $state.Tags.Add('!', '!')
        $directives = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        while ($state.Index -lt $state.Lines.Count -and $state.Lines[$state.Index].StartsWith('%')) {
            $directive = $state.Lines[$state.Index]
            $state.DiagnosticLine = $state.Index + 1
            if ($directive -cmatch '^%YAML[ \t]+([0-9]+\.[0-9]+)[ \t]*(?:[ \t]#.*)?$') {
                if (-not $directives.Add('YAML')) { Stop-ZabbixYaml $state 'Duplicate YAML version directive.' }
                $version = $Matches[1]
                if ($version -notmatch '^1\.') { Stop-ZabbixYaml $state 'Incompatible YAML major version.' }
                if ($version -cne '1.2') { Write-Warning "$Source uses YAML $version; applying YAML 1.2 syntax and the selected schema." }
            }
            elseif ($directive -cmatch '^%TAG[ \t]+(!|!!|![A-Za-z0-9-]+!)[ \t]+(\S+?)[ \t]*(?:[ \t]#.*)?$') {
                $handle = $Matches[1]
                $prefix = $Matches[2]
                if (-not $directives.Add("TAG:$handle")) { Stop-ZabbixYaml $state "Duplicate TAG directive for '$handle'." }
                if ($prefix -match '%(?![0-9a-fA-F]{2})') { Stop-ZabbixYaml $state 'Invalid percent escape in TAG directive.' }
                $state.Tags[$handle] = $prefix
            }
            elseif ($directive -cmatch '^%([A-Za-z0-9_-]+)(?:[ \t].*)?$' -and $Matches[1] -cnotin @('YAML', 'TAG')) {
                Write-Warning "$Source contains a reserved directive; ignoring it as required by YAML."
                [void]$directives.Add("RESERVED:$($state.Index)")
            }
            else { Stop-ZabbixYaml $state 'Invalid YAML directive.' }
            $state.Index++
            Skip-ZabbixYamlBlank $state
        }
        $hasStart = $state.Index -lt $state.Lines.Count -and $state.Lines[$state.Index] -match '^---(?:[ \t]+(.*))?$'
        if ($directives.Count -gt 0 -and -not $hasStart) { Stop-ZabbixYaml $state 'YAML directives require an explicit document start (---).' ($state.Index + 1) }
        if ($hasStart) {
            $content = $Matches[1]
            if ($content -and -not $content.StartsWith('#')) {
                if ((Find-ZabbixYamlColon $content) -ge 0) { Stop-ZabbixYaml $state 'A block mapping cannot begin on the document marker line.' ($state.Index + 1) }
                $state.Lines[$state.Index] = $content
            }
            else { $state.Index++ }
        }
        Skip-ZabbixYamlBlank $state
        $state.DiagnosticLine = $state.Index + 1
        $root = New-WUGYamlNode $state 'Scalar' '' 'Plain'
        if ($state.Index -lt $state.Lines.Count -and $state.Lines[$state.Index] -notmatch '^(---|\.\.\.)(\s|$)') {
            $root = Read-ZabbixYamlBlock $state (Get-ZabbixYamlIndent $state $state.Lines[$state.Index]) 0
        }
        $document = [PSCustomObject]@{ Root = $root; ExplicitStart = $hasStart; ExplicitEnd = $false }
        $documents.Add($document)
        if (-not $SyntaxOnly) { Resolve-WUGYamlGraph $root $Schema }
        Skip-ZabbixYamlBlank $state
        $ended = $false
        if ($state.Index -lt $state.Lines.Count -and $state.Lines[$state.Index] -match '^\.\.\.(\s|$)') {
            if ($state.Lines[$state.Index] -notmatch '^\.\.\.(?:[ \t]*|[ \t]+#.*)$') { Stop-ZabbixYaml $state 'Unexpected content after document end marker.' ($state.Index + 1) }
            $state.Index++
            $ended = $true
            $document.ExplicitEnd = $true
            Skip-ZabbixYamlBlank $state
        }
        if ($state.Index -lt $state.Lines.Count -and $state.Lines[$state.Index] -notmatch '^---(\s|$)' -and -not $ended) {
            Stop-ZabbixYaml $state 'Unexpected trailing content; expected a YAML document boundary.' ($state.Index + 1)
        }
    }
    [PSCustomObject]@{ Documents = $documents.ToArray(); Schema = $Schema; Source = $Source }
}

function Read-ZabbixYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Source = '<input>',
        [switch]$AllDocuments
    )
    $stream = Read-WUGYamlStream -Text $Text -Source $Source -SyntaxOnly
    if (-not $AllDocuments -and $stream.Documents.Count -gt 1) {
        throw "${Source}:$($stream.Documents[1].Root.Line): Additional YAML document: a Zabbix export must contain exactly one document."
    }
    $values = [System.Collections.Generic.List[object]]::new()
    $projection = @{ ExpandedNodes = 0; Active = [System.Collections.Generic.HashSet[int]]::new() }
    foreach ($document in $stream.Documents) { $values.Add((ConvertFrom-WUGYamlNode $document.Root $projection)) }
    if ($AllDocuments) { return ,$values.ToArray() }
    if ($values.Count -eq 0) { return $null }
    return ,$values[0]
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAK63se9o+WHqbr
# UeSIG0YfEta4k2duKrojEdRn5pEMPqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDmU8vK+8dySSKJlQpeyUc+Sz+X4QtEXMNbtPqX+1yDVDANBgkqhkiG9w0BAQEF
# AASCAgDUvq8dH5BtPcaBm79gmT3qlh8y6E09WTXNItbAy2H4OwhbC6q2TTOydjgt
# YOZC7/jZqUEy80+0FhEzCNsuPHDF+sKixZLC8eDog9yxHmAjAgoEzNd08nUHuUdL
# uaUfEdlBI2gJr1foFPQbE7giVJd1Z+FhWm8vA67+CWVbd5EIe9UfWZKZKOJkDmmm
# kYxGjNRCiGcwCBPMGUcRvWG88STKsNafR9M5Z4cEP8MFE+wraLYTBYBZQIbRfV8A
# 0TbVRgLULd7q7UsjcyGzbr2LC1elUmJw0Lm4tEaqd7hHUOzSSO3xKId3d4SYH6cv
# YqyPdkvHOf70n/En3VQq76dsDaIKOf7cwpVAsGNetLoEAv8tZE94wtSsxy7aWyMk
# e7JSQleVTtg9+3TWUUh+U0j/kB3+PcPWebcTbHr4gAsofedyi/olZ1hMktakTYCJ
# xVyHAZIRFjVOEXT5zeNlt2mRi/rO/M5+a0mv5QbtXsLYGJ8Nias/IsQcyDDEs7dw
# MJAW09eAXN4HB9kNJFsKiJNk59kCIEjL+h01mxYZfjPsbXOPmeah3T5zz7+lZnfF
# MoOUp/Msz0TUW9ioxtvyu7++WNQ9Baopkw8OYUxvlJGoMbt7NizVFp21F9nVmLTl
# O32SIl6nm/zOcPXDvF/pQG36HrhsBDxa73Wr3iPTBuZuqnHVSKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjEwMjIwMDM4MzlaMC8GCSqGSIb3DQEJBDEiBCDShQNB
# Wz2zjVkzrMohFxej8R1+mUfZfwSrGVWaO3nNdDANBgkqhkiG9w0BAQEFAASCAgCX
# O8htPLLDyj18ft3OZjtaenQISGU/4rjREGd0BKMvXrwS5cfMxQiN1+nUWUF+eYS1
# qlT01eq7U8L5KJNWTxcU82siFyKbV7I3UjktJ0B67DgOAyEzIiWjxFDCvHMkM4C+
# 8oK/Cw3s7p9DG/MGwMIOO0R7nBQI8dxfGfg09YOP0esNxRTaXNUJRB7cbLxTfFoG
# Ohy5iK8zOhzL1OqzEpP/mMYTttX/TDV79duzNVFoUXCH4OazwJvcjv4KmgvjR6jR
# xHrmzZNcdhi9w0/HLrq7cr1/kAvxY8NU1qC+LOQvWJDQbx5Xbxeoq7BugvdBd5pG
# W5pOxDfO+LVX+4ndDS5YgOJyEqUKDQWExRvC0ofIFNYIRThRdLVUoA/mx2xBG0FH
# R5pPKahhUfv8fDqWfWMoXc1GJBkuavpyBorDlIEW0MpuEqc4aIJL5KtbcdZqRT4b
# 3uQPlBOcrRSt7wD8e3MSXYw8Zxa9AUozibpi6XbjkkWWcx2H2PW1IouuY4hBWa16
# EYjNqDbIjo/2babUExpJvA96Z7UFEnjJCWRnkXEhEZGdzNKe6rWe8H2rJe/zTNUl
# py5AKkAt5WMAvmnv/ysz6IB8Me91Ch8MAiNKRfTSXVRZ0Jsfnzz5ojdvZK8XknC6
# ekSsVxtEZmIJmMOZhivwLbak1wbF4SzMCeg9nTjvjw==
# SIG # End signature block
