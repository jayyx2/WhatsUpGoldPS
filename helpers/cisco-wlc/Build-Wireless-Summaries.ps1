#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InputDirectory,
    [string]$OutputDirectory,
    [string]$MibDirectory = (Join-Path $PSScriptRoot 'mibs'),
    [string]$ManifestPath,
    [bool]$IncludeRogues = $true,
    [bool]$IncludeRfHealth = $true,
    [bool]$IncludeJoinTime = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set dynamic defaults if not provided
$discoveryOutputBase = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
if (-not $InputDirectory) {
    $InputDirectory = Join-Path $discoveryOutputBase 'full'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $discoveryOutputBase 'summary'
}
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $OutputDirectory 'wireless-summary-manifest.json'
}

# Ensure directories exist
foreach ($dir in @($InputDirectory, $OutputDirectory)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Load pre-baked MIB translation cache (no MIB file parsing required)
$mibCachePath = Join-Path $PSScriptRoot 'MibTranslationCache.ps1'
if (Test-Path -LiteralPath $mibCachePath) {
    . $mibCachePath
}

function Ensure-Directory {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-IndexToMac {
    param([AllowNull()] [string]$Index)

    if ([string]::IsNullOrWhiteSpace($Index)) { return '' }
    $parts = $Index.Split('.') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    if ($parts.Count -eq 0) { return '' }
    return ($parts | ForEach-Object { '{0:X2}' -f $_ }) -join ':'
}

function Convert-OctetTextToBytes {
    param([AllowNull()] [string]$RawText)

    $bytes = New-Object System.Collections.Generic.List[byte]
    if ([string]::IsNullOrEmpty($RawText)) {
        return ,([byte[]]$bytes.ToArray())
    }

    foreach ($ch in $RawText.ToCharArray()) {
        $bytes.Add([byte][int]$ch)
    }

    return ,([byte[]]$bytes.ToArray())
}

function Convert-OctetTextToMac {
    param([AllowNull()] [string]$RawText)

    $bytes = Convert-OctetTextToBytes -RawText $RawText
    $byteArray = @($bytes)
    if ($byteArray.Count -eq 0) { return '' }
    return ($byteArray | ForEach-Object { '{0:X2}' -f $_ }) -join ':'
}

function Convert-HexStringToMac {
    param([AllowNull()] [string]$Hex)

    if ([string]::IsNullOrWhiteSpace($Hex)) { return '' }
    $normalized = ($Hex -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized.Length -ne 12) { return '' }

    $parts = @()
    for ($i = 0; $i -lt 12; $i += 2) {
        $parts += $normalized.Substring($i, 2)
    }
    return ($parts -join ':')
}

function Convert-HexToAscii {
    param([AllowNull()] [string]$Hex)

    if ([string]::IsNullOrWhiteSpace($Hex)) { return '' }
    $normalized = ($Hex -replace '[^0-9A-Fa-f]', '')
    if ($normalized.Length -eq 0 -or $normalized.Length % 2 -ne 0) { return '' }

    $chars = @()
    for ($i = 0; $i -lt $normalized.Length; $i += 2) {
        $chars += [char][Convert]::ToByte($normalized.Substring($i, 2), 16)
    }
    return (-join $chars)
}

function Normalize-OctetDecodedText {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }

    $clean = [regex]::Replace($Value, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    return $clean.Trim()
}

function Resolve-OctetStringText {
    param(
        [AllowNull()] [string]$RawText,
        [AllowNull()] [string]$HexText
    )

    if (-not [string]::IsNullOrWhiteSpace($HexText)) {
        $decoded = Normalize-OctetDecodedText -Value (Convert-HexToAscii -Hex $HexText)
        if (-not [string]::IsNullOrWhiteSpace($decoded)) {
            return $decoded
        }
    }

    return (Normalize-OctetDecodedText -Value $RawText)
}

function Convert-InetAddressToFriendly {
    param(
        [AllowNull()] [string]$RawText,
        [string]$AddressType
    )

    if ([string]::IsNullOrEmpty($RawText)) {
        return ''
    }

    if ($RawText -match '^[0-9a-fA-F:.]+$') {
        return $RawText
    }

    $bytes = Convert-OctetTextToBytes -RawText $RawText
    $byteArray = @($bytes)
    if ($byteArray.Count -eq 0) {
        return ''
    }

    if ($AddressType -eq 'ipv4' -and $byteArray.Count -ge 4) {
        return ($byteArray[0..3] | ForEach-Object { [int]$_ }) -join '.'
    }

    if ($AddressType -eq 'ipv6' -and $byteArray.Count -ge 16) {
        return ([System.Net.IPAddress]::new($byteArray[0..15])).ToString()
    }

    if ($AddressType -eq 'dns') {
        $dnsPrintable = -join ($RawText.ToCharArray() | Where-Object {
            $code = [int]$_
            ($code -ge 32 -and $code -le 126)
        })
        return $dnsPrintable.Trim()
    }

    return ($byteArray | ForEach-Object { '{0:X2}' -f $_ }) -join ':'
}

function Get-InetAddressTypeLabel {
    param([string]$Code)
    switch ($Code) {
        '0' { 'unknown' }
        '1' { 'ipv4' }
        '2' { 'ipv6' }
        '3' { 'ipv4z' }
        '4' { 'ipv6z' }
        '16' { 'dns' }
        default { if ([string]::IsNullOrWhiteSpace($Code)) { '' } else { "inetAddrType-$Code" } }
    }
}

function Get-ClientStatusLabel {
    # CISCO-LWAPP-TC-MIB CLDot11ClientStatus (1-based)
    param([string]$Code)
    switch ($Code) {
        '1' { 'Idle' }           '2' { 'AAA Pending' }
        '3' { 'Authenticated' }  '4' { 'Associated' }
        '5' { 'Power Save' }     '6' { 'Disassociated' }
        '7' { 'To Be Deleted' }  '8' { 'Probing' }
        '9' { 'Excluded' }
        default { if ([string]::IsNullOrWhiteSpace($Code)) { '' } else { "Status-$Code" } }
    }
}

function Get-AirespaceClientStatusLabel {
    # AIRESPACE-WIRELESS-MIB bsnMobileStationStatus (0-based)
    param([string]$Code)
    switch ($Code) {
        '0' { 'Idle' }           '1' { 'AAA Pending' }
        '2' { 'Authenticated' }  '3' { 'Associated' }
        '4' { 'Power Save' }     '5' { 'Disassociated' }
        '6' { 'To Be Deleted' }  '7' { 'Probing' }
        '8' { 'Blacklisted' }
        default { if ([string]::IsNullOrWhiteSpace($Code)) { '' } else { "Status-$Code" } }
    }
}

function Get-Dot11ProtocolLabel {
    param([string]$Code)
    if (Get-Command -Name 'Get-CachedEnumLabel' -ErrorAction SilentlyContinue) {
        $label = Get-CachedEnumLabel -Entry 'cldcClientEntry' -Column 'cldcClientProtocol' -Value $Code
        if (-not [string]::IsNullOrWhiteSpace($label) -and $label -ne $Code) { return $label }
    }
    return $Code
}

function Get-ClientBestState {
    param([AllowNull()] [string]$Status)
    switch (([string]$Status).ToLowerInvariant()) {
        'authenticated' { 'healthy' }
        'associated' { 'healthy' }
        'idle' { 'warning' }
        'aaa-pending' { 'warning' }
        'powersave' { 'warning' }
        default { 'unknown' }
    }
}

function Resolve-MibPath {
    param(
        [Parameter(Mandatory)] [string]$MibDir,
        [Parameter(Mandatory)] [string]$MibName
    )

    $candidates = @(
        (Join-Path $MibDir "$MibName.my.txt"),
        (Join-Path $MibDir "$MibName.mib"),
        (Join-Path $MibDir "$MibName.my"),
        (Join-Path $MibDir $MibName)
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-EntryColumnMap {
    param(
        [AllowNull()] [string]$MibPath,
        [Parameter(Mandatory)] [string]$EntryName
    )

    # Try pre-loaded cache first (no MIB file needed)
    if (Get-Command -Name 'Get-CachedColumnMap' -ErrorAction SilentlyContinue) {
        $cached = Get-CachedColumnMap -Entry $EntryName
        if ($null -ne $cached -and $cached.Count -gt 0) {
            return $cached
        }
    }

    # Fall back to MIB file parsing
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($MibPath) -or -not (Test-Path -LiteralPath $MibPath)) {
        return $map
    }

    $content = Get-Content -LiteralPath $MibPath -Raw
    $pattern = "(?ms)^(?<name>[A-Za-z0-9-]+)\s+OBJECT-TYPE\s+.*?::=\s*\{\s*" + [regex]::Escape($EntryName) + "\s+(?<col>\d+)\s*\}"
    $matches = [regex]::Matches($content, $pattern)
    foreach ($m in $matches) {
        $col = [int]$m.Groups['col'].Value
        if (-not $map.ContainsKey($col)) {
            $map[$col] = $m.Groups['name'].Value
        }
    }
    return $map
}

function Add-RowField {
    param(
        [Parameter(Mandatory)] [hashtable]$Row,
        [Parameter(Mandatory)] [string]$Key,
        [AllowNull()] [string]$Value
    )
    $Row[$Key] = if ($null -eq $Value) { '' } else { [string]$Value }
}

function Build-TableRows {
    param(
        [Parameter(Mandatory)] [string]$JsonlPath,
        [Parameter(Mandatory)] [string]$EntryPrefix,
        [hashtable]$ColumnNameMap
    )

    $rowMap = @{}
    $reader = [System.IO.StreamReader]::new($JsonlPath)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $item = $line | ConvertFrom-Json
            $oid = [string]$item.OID
            if (-not $oid.StartsWith($EntryPrefix + '.')) { continue }

            $suffix = $oid.Substring($EntryPrefix.Length + 1)
            $parts = $suffix.Split('.')
            if ($parts.Count -lt 2) { continue }

            $col = [int]$parts[0]
            $idx = ($parts[1..($parts.Count - 1)] -join '.')

            if (-not $rowMap.ContainsKey($idx)) {
                $rowMap[$idx] = @{}
            }

            $row = $rowMap[$idx]
            Add-RowField -Row $row -Key ("Col$col") -Value ([string]$item.Value)

            $hexValue = ''
            if ($item.PSObject.Properties.Name -contains 'HexValue') {
                $hexValue = [string]$item.HexValue
            }
            if (-not [string]::IsNullOrWhiteSpace($hexValue)) {
                Add-RowField -Row $row -Key ("Col${col}__Hex") -Value $hexValue
            }

            if ($ColumnNameMap -and $ColumnNameMap.ContainsKey($col)) {
                $columnName = [string]$ColumnNameMap[$col]
                Add-RowField -Row $row -Key $columnName -Value ([string]$item.Value)
                if (-not [string]::IsNullOrWhiteSpace($hexValue)) {
                    Add-RowField -Row $row -Key ("${columnName}__Hex") -Value $hexValue
                }
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    return $rowMap
}

function Build-RootStatsSummary {
    param(
        [Parameter(Mandatory)] [string]$JsonlPath,
        [Parameter(Mandatory)] [string]$BaseOid,
        [Parameter(Mandatory)] [string]$RootName
    )

    $stats = @{}
    $reader = [System.IO.StreamReader]::new($JsonlPath)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $item = $line | ConvertFrom-Json
            $oid = [string]$item.OID
            if (-not $oid.StartsWith($BaseOid + '.')) { continue }

            $suffix = $oid.Substring($BaseOid.Length + 1)
            $parts = $suffix.Split('.')
            if ($parts.Count -eq 0) { continue }

            $tableKeyPartCount = [Math]::Min(4, $parts.Count)
            $tableKey = ($parts[0..($tableKeyPartCount - 1)] -join '.')
            if (-not $stats.ContainsKey($tableKey)) {
                $stats[$tableKey] = [PSCustomObject]@{
                    Root = $RootName
                    BaseOid = $BaseOid
                    TableRelativePath = $tableKey
                    TableOidPrefix = "$BaseOid.$tableKey"
                    VariableCount = 0
                    DistinctColumns = New-Object System.Collections.Generic.HashSet[string]
                    DistinctIndexes = New-Object System.Collections.Generic.HashSet[string]
                    Types = @{}
                }
            }

            $s = $stats[$tableKey]
            $s.VariableCount++

            $col = if ($parts.Count -ge 5) { $parts[4] } else { $parts[0] }
            $idx = if ($parts.Count -ge 6) { ($parts[5..($parts.Count - 1)] -join '.') } elseif ($parts.Count -gt 1) { ($parts[1..($parts.Count - 1)] -join '.') } else { '0' }

            $null = $s.DistinctColumns.Add([string]$col)
            $null = $s.DistinctIndexes.Add([string]$idx)

            $type = [string]$item.Type
            if (-not $s.Types.ContainsKey($type)) {
                $s.Types[$type] = 0
            }
            $s.Types[$type]++
        }
    }
    finally {
        $reader.Dispose()
    }

    $rows = foreach ($key in $stats.Keys) {
        $s = $stats[$key]
        [PSCustomObject]@{
            Root = $s.Root
            BaseOid = $s.BaseOid
            TableRelativePath = $s.TableRelativePath
            TableOidPrefix = $s.TableOidPrefix
            VariableCount = $s.VariableCount
            DistinctColumnCount = $s.DistinctColumns.Count
            DistinctIndexCount = $s.DistinctIndexes.Count
            TypeBreakdown = (($s.Types.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}:{1}" -f $_.Name, $_.Value }) -join '; ')
        }
    }

    return $rows | Sort-Object VariableCount -Descending
}

Ensure-Directory -Path $OutputDirectory

# Resolve MIB files from local /mibs directory (no downloads).
# These are optional when MibTranslationCache.ps1 is loaded (provides Get-CachedColumnMap).
$hasMibCache = [bool](Get-Command -Name 'Get-CachedColumnMap' -ErrorAction SilentlyContinue)
$apMib = Resolve-MibPath -MibDir $MibDirectory -MibName 'CISCO-LWAPP-AP-MIB'
$clientMib = Resolve-MibPath -MibDir $MibDirectory -MibName 'CISCO-LWAPP-DOT11-CLIENT-MIB'
$wlanMib = Resolve-MibPath -MibDir $MibDirectory -MibName 'CISCO-LWAPP-WLAN-MIB'

if (-not $hasMibCache) {
    if (-not $apMib) { Write-Warning "MIB not found: CISCO-LWAPP-AP-MIB in $MibDirectory" }
    if (-not $clientMib) { Write-Warning "MIB not found: CISCO-LWAPP-DOT11-CLIENT-MIB in $MibDirectory" }
    if (-not $wlanMib) { Write-Warning "MIB not found: CISCO-LWAPP-WLAN-MIB in $MibDirectory" }
}

$apColumnMap = Get-EntryColumnMap -MibPath $apMib -EntryName 'cLApEntry'
$clientColumnMap = Get-EntryColumnMap -MibPath $clientMib -EntryName 'cldcClientEntry'
$wlanColumnMap = Get-EntryColumnMap -MibPath $wlanMib -EntryName 'cLWlanConfigEntry'

$rootFiles = @(
    [PSCustomObject]@{ Root = 'ap'; BaseOid = '1.3.6.1.4.1.9.9.513'; Path = Join-Path $InputDirectory 'wireless-ap.jsonl' }
    [PSCustomObject]@{ Root = 'dot11-client'; BaseOid = '1.3.6.1.4.1.9.9.599'; Path = Join-Path $InputDirectory 'wireless-dot11-client.jsonl' }
    [PSCustomObject]@{ Root = 'wlan'; BaseOid = '1.3.6.1.4.1.9.9.512'; Path = Join-Path $InputDirectory 'wireless-wlan.jsonl' }
    [PSCustomObject]@{ Root = 'dot11'; BaseOid = '1.3.6.1.4.1.9.9.612'; Path = Join-Path $InputDirectory 'wireless-dot11.jsonl' }
    [PSCustomObject]@{ Root = 'rogue'; BaseOid = '1.3.6.1.4.1.9.9.610'; Path = Join-Path $InputDirectory 'wireless-rogue.jsonl' }
    [PSCustomObject]@{ Root = 'rf'; BaseOid = '1.3.6.1.4.1.9.9.778'; Path = Join-Path $InputDirectory 'wireless-rf.jsonl' }
    [PSCustomObject]@{ Root = 'mobility-ext'; BaseOid = '1.3.6.1.4.1.9.9.846'; Path = Join-Path $InputDirectory 'wireless-mobility-ext.jsonl' }
    [PSCustomObject]@{ Root = 'sys'; BaseOid = '1.3.6.1.4.1.9.9.618'; Path = Join-Path $InputDirectory 'wireless-sys.jsonl' }
    [PSCustomObject]@{ Root = 'airespace-client'; BaseOid = '1.3.6.1.4.1.14179.2.1.4'; Path = Join-Path $InputDirectory 'wireless-airespace-client.jsonl' }
)

$summaryArtifacts = @()
$apInventory = @()
$clientInventory = @()
$wlanInventory = @()

$airespaceInput = Join-Path $InputDirectory 'wireless-airespace-client.jsonl'
$clientInput = Join-Path $InputDirectory 'wireless-dot11-client.jsonl'

$dot11ClientByMac = @{}
if (Test-Path -LiteralPath $clientInput) {
    $clientEntryPrefix = '1.3.6.1.4.1.9.9.599.1.3.1.1'
    $dot11RowsForEnrichment = Build-TableRows -JsonlPath $clientInput -EntryPrefix $clientEntryPrefix -ColumnNameMap $clientColumnMap

    foreach ($idx in $dot11RowsForEnrichment.Keys) {
        $row = $dot11RowsForEnrichment[$idx]
        $clientMac = Convert-IndexToMac -Index $idx
        if ([string]::IsNullOrWhiteSpace($clientMac)) { continue }

        $ssidRaw = if ($row.ContainsKey('cldcClientSSID')) { $row['cldcClientSSID'] } else { '' }
        $ssidHex = if ($row.ContainsKey('cldcClientSSID__Hex')) { $row['cldcClientSSID__Hex'] } else { '' }
        $ssid = Resolve-OctetStringText -RawText $ssidRaw -HexText $ssidHex

        $profileRaw = if ($row.ContainsKey('cldcClientWlanProfileName')) { $row['cldcClientWlanProfileName'] } else { '' }
        $profileHex = if ($row.ContainsKey('cldcClientWlanProfileName__Hex')) { $row['cldcClientWlanProfileName__Hex'] } else { '' }
        $wlanProfile = Resolve-OctetStringText -RawText $profileRaw -HexText $profileHex

        $usernameRaw = if ($row.ContainsKey('cldcClientUsername')) { $row['cldcClientUsername'] } else { '' }
        $usernameHex = if ($row.ContainsKey('cldcClientUsername__Hex')) { $row['cldcClientUsername__Hex'] } else { '' }
        $username = Resolve-OctetStringText -RawText $usernameRaw -HexText $usernameHex
        $dot11StatusCode = if ($row.ContainsKey('cldcClientStatus')) { [string]$row['cldcClientStatus'] } else { '' }
        $dot11AuthModeCode = if ($row.ContainsKey('cldcClientAuthMode')) { [string]$row['cldcClientAuthMode'] } else { '' }
        $dot11ProtocolCode = if ($row.ContainsKey('cldcClientProtocol')) { [string]$row['cldcClientProtocol'] } else { '' }

        $dot11ClientByMac[$clientMac.ToUpperInvariant()] = [PSCustomObject]@{
            StatusCode = $dot11StatusCode
            Status = Get-ClientStatusLabel -Code $dot11StatusCode
            WlanProfileName = $wlanProfile
            SSID = $ssid
            Username = $username
            AccessVLAN = if ($row.ContainsKey('cldcClientAccessVLAN')) { [string]$row['cldcClientAccessVLAN'] } else { '' }
            Channel = if ($row.ContainsKey('cldcClientChannel')) { [string]$row['cldcClientChannel'] } else { '' }
            AuthModeCode = $dot11AuthModeCode
            AuthMode = Get-CachedEnumLabel -Entry 'cldcClientEntry' -Column 'cldcClientAuthMode' -Value $dot11AuthModeCode
            ProtocolCode = $dot11ProtocolCode
            Protocol = Get-Dot11ProtocolLabel -Code $dot11ProtocolCode
            DeviceType = if ($row.ContainsKey('cldcClientDeviceType')) { [string]$row['cldcClientDeviceType'] } else { '' }
        }
    }

    Write-Host "Built dot11-client enrichment map: $($dot11ClientByMac.Count) rows" -ForegroundColor Cyan
}

foreach ($rf in $rootFiles) {
    if (-not (Test-Path -LiteralPath $rf.Path)) {
        Write-Warning "Skipping $($rf.Root): missing input $($rf.Path)"
        continue
    }

    $stats = Build-RootStatsSummary -JsonlPath $rf.Path -BaseOid $rf.BaseOid -RootName $rf.Root
    $csv = Join-Path $OutputDirectory ("wireless-$($rf.Root)-summary.csv")
    $json = Join-Path $OutputDirectory ("wireless-$($rf.Root)-summary.json")

    $stats | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    ($stats | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $json -Encoding UTF8

    $summaryArtifacts += [PSCustomObject]@{
        Name = "root-summary-$($rf.Root)"
        Root = $rf.Root
        Csv = $csv
        Json = $json
        Count = @($stats).Count
    }

    Write-Host "Built root summary for $($rf.Root): $(@($stats).Count) table groups" -ForegroundColor Green
}

# AP inventory summary (translated with cLApEntry labels).
$apInput = Join-Path $InputDirectory 'wireless-ap.jsonl'
if (Test-Path -LiteralPath $apInput) {
    $apEntryPrefix = '1.3.6.1.4.1.9.9.513.1.1.1.1'
    $apRows = Build-TableRows -JsonlPath $apInput -EntryPrefix $apEntryPrefix -ColumnNameMap $apColumnMap

    $apInventory = foreach ($idx in $apRows.Keys) {
        $row = $apRows[$idx]
        $type1 = if ($row.ContainsKey('cLApPrimaryControllerAddressType')) { $row['cLApPrimaryControllerAddressType'] } else { '' }
        $type2 = if ($row.ContainsKey('cLApSecondaryControllerAddressType')) { $row['cLApSecondaryControllerAddressType'] } else { '' }
        $type3 = if ($row.ContainsKey('cLApTertiaryControllerAddressType')) { $row['cLApTertiaryControllerAddressType'] } else { '' }
        $label1 = Get-InetAddressTypeLabel -Code $type1
        $label2 = Get-InetAddressTypeLabel -Code $type2
        $label3 = Get-InetAddressTypeLabel -Code $type3

        $domainRaw = if ($row.ContainsKey('cLApDomainName')) { $row['cLApDomainName'] } else { '' }
        $domainHex = if ($row.ContainsKey('cLApDomainName__Hex')) { $row['cLApDomainName__Hex'] } else { '' }
        $siteTagRaw = if ($row.ContainsKey('cLApSiteTagName')) { $row['cLApSiteTagName'] } else { '' }
        $siteTagHex = if ($row.ContainsKey('cLApSiteTagName__Hex')) { $row['cLApSiteTagName__Hex'] } else { '' }
        $rfTagRaw = if ($row.ContainsKey('cLApRfTagName')) { $row['cLApRfTagName'] } else { '' }
        $rfTagHex = if ($row.ContainsKey('cLApRfTagName__Hex')) { $row['cLApRfTagName__Hex'] } else { '' }
        $policyTagRaw = if ($row.ContainsKey('cLApPolicyTagName')) { $row['cLApPolicyTagName'] } else { '' }
        $policyTagHex = if ($row.ContainsKey('cLApPolicyTagName__Hex')) { $row['cLApPolicyTagName__Hex'] } else { '' }
        $filterNameRaw = if ($row.ContainsKey('cLApFilterName')) { $row['cLApFilterName'] } else { '' }
        $filterNameHex = if ($row.ContainsKey('cLApFilterName__Hex')) { $row['cLApFilterName__Hex'] } else { '' }
        $usbSerialRaw = if ($row.ContainsKey('cLApUsbSerialNumber')) { $row['cLApUsbSerialNumber'] } else { '' }
        $usbSerialHex = if ($row.ContainsKey('cLApUsbSerialNumber__Hex')) { $row['cLApUsbSerialNumber__Hex'] } else { '' }

        [PSCustomObject]@{
            APName = if ($row.ContainsKey('cLApName')) { $row['cLApName'] } else { '' }
            APMac = Convert-IndexToMac -Index $idx
            IndexSuffix = $idx
            Dot11Slots = if ($row.ContainsKey('cLApMaxNumberOfDot11Slots')) { $row['cLApMaxNumberOfDot11Slots'] } else { '' }
            ApUptime = if ($row.ContainsKey('cLApUpTime')) { $row['cLApUpTime'] } else { '' }
            ControllerUptimeSeen = if ($row.ContainsKey('cLLwappUpTime')) { $row['cLLwappUpTime'] } else { '' }
            LastChange = if ($row.ContainsKey('cLLwappJoinTakenTime')) { $row['cLLwappJoinTakenTime'] } else { '' }
            PrimaryControllerAddressType = $label1
            PrimaryControllerAddress = if ($row.ContainsKey('cLApPrimaryControllerAddress')) { Convert-InetAddressToFriendly -RawText $row['cLApPrimaryControllerAddress'] -AddressType $label1 } else { '' }
            SecondaryControllerAddressType = $label2
            SecondaryControllerAddress = if ($row.ContainsKey('cLApSecondaryControllerAddress')) { Convert-InetAddressToFriendly -RawText $row['cLApSecondaryControllerAddress'] -AddressType $label2 } else { '' }
            TertiaryControllerAddressType = $label3
            TertiaryControllerAddress = if ($row.ContainsKey('cLApTertiaryControllerAddress')) { Convert-InetAddressToFriendly -RawText $row['cLApTertiaryControllerAddress'] -AddressType $label3 } else { '' }
            DomainName = Resolve-OctetStringText -RawText $domainRaw -HexText $domainHex
            SiteTagName = Resolve-OctetStringText -RawText $siteTagRaw -HexText $siteTagHex
            RfTagName = Resolve-OctetStringText -RawText $rfTagRaw -HexText $rfTagHex
            PolicyTagName = Resolve-OctetStringText -RawText $policyTagRaw -HexText $policyTagHex
            FilterName = Resolve-OctetStringText -RawText $filterNameRaw -HexText $filterNameHex
            UsbSerialNumber = Resolve-OctetStringText -RawText $usbSerialRaw -HexText $usbSerialHex
            AdminStatus = if ($row.ContainsKey('cLApAdminStatus')) { if ($row['cLApAdminStatus'] -eq '1') { 'Up' } elseif ($row['cLApAdminStatus'] -eq '2') { 'Down' } else { [string]$row['cLApAdminStatus'] } } else { '' }
            PowerStatus = Get-CachedEnumLabel -Entry 'cLApEntry' -Column 'cLApPowerStatus' -Value $(if ($row.ContainsKey('cLApPowerStatus')) { $row['cLApPowerStatus'] } else { '' })
            CpuCurrentPct = if ($row.ContainsKey('cLApCpuCurrentUsage')) { $row['cLApCpuCurrentUsage'] } else { '' }
            CpuAvgPct = if ($row.ContainsKey('cLApCpuAverageUsage')) { $row['cLApCpuAverageUsage'] } else { '' }
            MemCurrentPct = if ($row.ContainsKey('cLApMemoryCurrentUsage')) { $row['cLApMemoryCurrentUsage'] } else { '' }
            MemAvgPct = if ($row.ContainsKey('cLApMemoryAverageUsage')) { $row['cLApMemoryAverageUsage'] } else { '' }
            FailoverPriority = Get-CachedEnumLabel -Entry 'cLApEntry' -Column 'cLApFailoverPriority' -Value $(if ($row.ContainsKey('cLApFailoverPriority')) { $row['cLApFailoverPriority'] } else { '' })
            LastRebootReason = Get-CachedEnumLabel -Entry 'cLApEntry' -Column 'cLApLastRebootReason' -Value $(if ($row.ContainsKey('cLApLastRebootReason')) { $row['cLApLastRebootReason'] } else { '' })
            SubMode = Get-CachedEnumLabel -Entry 'cLApEntry' -Column 'cLApSubMode' -Value $(if ($row.ContainsKey('cLApSubMode')) { $row['cLApSubMode'] } else { '' })
            AntennaBandMode = Get-CachedEnumLabel -Entry 'cLApEntry' -Column 'cLApAntennaBandMode' -Value $(if ($row.ContainsKey('cLApAntennaBandMode')) { $row['cLApAntennaBandMode'] } else { '' })
            AssocClientCount = if ($row.ContainsKey('cLApAssociatedClientCount')) { $row['cLApAssociatedClientCount'] } else { '' }
            ActiveClientCount = if ($row.ContainsKey('cLApActiveClientCount')) { $row['cLApActiveClientCount'] } else { '' }
            JoinTime = if ($IncludeJoinTime -and $row.ContainsKey('cLLwappJoinTakenTime')) { $row['cLLwappJoinTakenTime'] } else { '' }
        }
    }

    $apInventory = $apInventory | Sort-Object APName, APMac
    $apCsv = Join-Path $OutputDirectory 'wireless-ap-inventory-summary.csv'
    $apJson = Join-Path $OutputDirectory 'wireless-ap-inventory-summary.json'
    $apInventory | Export-Csv -LiteralPath $apCsv -NoTypeInformation -Encoding UTF8
    ($apInventory | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $apJson -Encoding UTF8

    $summaryArtifacts += [PSCustomObject]@{ Name = 'ap-inventory'; Root = 'ap'; Csv = $apCsv; Json = $apJson; Count = @($apInventory).Count }
    Write-Host "Built AP inventory summary: $(@($apInventory).Count) rows" -ForegroundColor Green
}

# Client inventory summary - prefer AIRESPACE bsnMobileStationTable for direct AP base MAC + SSID joins.
if (Test-Path -LiteralPath $airespaceInput) {
    # AIRESPACE bsnMobileStationTable: indexed by client MAC (6 bytes in OID suffix)
    # Col 2=IP, 3=username, 4=AP base MAC, 5=slot, 7=SSID, 9=status, 11=mobilityStatus,
    # 25=protocol, 27=interface, 29=vlanId, 30=policyType, 31=encryption, 32=eapType
    $bsnEntryPrefix = '1.3.6.1.4.1.14179.2.1.4.1'
    $bsnRows = Build-TableRows -JsonlPath $airespaceInput -EntryPrefix $bsnEntryPrefix -ColumnNameMap @{}

    $clientInventory = foreach ($idx in $bsnRows.Keys) {
        $row = $bsnRows[$idx]
        $clientMac = Convert-IndexToMac -Index $idx
        $enriched = $null
        $enrichedKey = $clientMac.ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($enrichedKey) -and $dot11ClientByMac.ContainsKey($enrichedKey)) {
            $enriched = $dot11ClientByMac[$enrichedKey]
        }

        # Col 4 = AP base MAC (OctetString, 6 bytes) - use hex field for reliable decoding
        $apMacHex = if ($row.ContainsKey('Col4__Hex')) { $row['Col4__Hex'] } else { '' }
        $apMacText = if ($row.ContainsKey('Col4')) { $row['Col4'] } else { '' }
        $resolvedApMac = if (-not [string]::IsNullOrWhiteSpace($apMacHex)) { Convert-HexStringToMac -Hex $apMacHex } else { Convert-OctetTextToMac -RawText $apMacText }

        # Col 6 = WLAN Index (bsnMobileStationEssIndex, INTEGER) - for WLAN profile lookup
        $wlanIndex = if ($row.ContainsKey('Col6')) { $row['Col6'] } else { '' }

        # Col 7 = SSID (OctetString, ASCII text)
        $ssidHex = if ($row.ContainsKey('Col7__Hex')) { $row['Col7__Hex'] } else { '' }
        $ssidRaw = if ($row.ContainsKey('Col7')) { $row['Col7'] } else { '' }
        $ssid = Resolve-OctetStringText -RawText $ssidRaw -HexText $ssidHex

        # Col 27 = WLAN Profile name (from bsnMobileStationInterface column)
        $profileHex = if ($row.ContainsKey('Col27__Hex')) { $row['Col27__Hex'] } else { '' }
        $profileRaw = if ($row.ContainsKey('Col27')) { $row['Col27'] } else { '' }
        $wlanProfile = Resolve-OctetStringText -RawText $profileRaw -HexText $profileHex

        # Col 2 = IP, Col 3 = Username, Col 5 = slot, Col 23 = status text
        $ipRaw = if ($row.ContainsKey('Col2')) { $row['Col2'] } else { '' }
        $usernameRaw = if ($row.ContainsKey('Col3')) { $row['Col3'] } else { '' }
        $usernameHex = if ($row.ContainsKey('Col3__Hex')) { $row['Col3__Hex'] } else { '' }
        $username = Resolve-OctetStringText -RawText $usernameRaw -HexText $usernameHex
        $slot = if ($row.ContainsKey('Col5')) { $row['Col5'] } else { '' }
        $statusText = if ($row.ContainsKey('Col23')) { $row['Col23'] } else { '' }
        $statusHex = if ($row.ContainsKey('Col23__Hex')) { $row['Col23__Hex'] } else { '' }
        $statusDecoded = Resolve-OctetStringText -RawText $statusText -HexText $statusHex

        # Col 9 = bsnMobileStationStatus (0-based INTEGER enum), Col 25 = protocol, Col 30 = policy type, Col 31 = encryption
        $airespaceStatusCode  = if ($row.ContainsKey('Col9'))  { $row['Col9'] }  else { '' }
        $airespaceProtocol    = if ($row.ContainsKey('Col25')) { $row['Col25'] } else { '' }
        $airespasePolicyType  = if ($row.ContainsKey('Col30')) { $row['Col30'] } else { '' }
        $airespaceEncryption  = if ($row.ContainsKey('Col31')) { $row['Col31'] } else { '' }
        $airespaseMobility    = if ($row.ContainsKey('Col11')) { $row['Col11'] } else { '' }

        [PSCustomObject]@{
            ClientMac = $clientMac
            IndexSuffix = $idx
            WlanIndex = $wlanIndex
            StatusCode = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.StatusCode)) { $enriched.StatusCode } else { $airespaceStatusCode }
            Status = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.Status)) {
                $enriched.Status
            } elseif (-not [string]::IsNullOrWhiteSpace($statusDecoded)) {
                $statusDecoded
            } else {
                Get-AirespaceClientStatusLabel -Code $airespaceStatusCode
            }
            WlanProfileName = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.WlanProfileName)) { $enriched.WlanProfileName } else { $wlanProfile }
            SSID = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.SSID)) { $enriched.SSID } else { $ssid }
            Username = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.Username)) { $enriched.Username } else { $username }
            APMac = $resolvedApMac
            APSlot = $slot
            ClientIP = $ipRaw
            AccessVLAN = if ($null -ne $enriched) { [string]$enriched.AccessVLAN } else { '' }
            Channel = if ($null -ne $enriched) { [string]$enriched.Channel } else { '' }
            AuthMode = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.AuthMode)) { $enriched.AuthMode } else { '' }
            Protocol = if ($null -ne $enriched -and -not [string]::IsNullOrWhiteSpace($enriched.Protocol)) {
                $enriched.Protocol
            } else {
                Get-Dot11ProtocolLabel -Code $airespaceProtocol
            }
            MobilityStatus = Get-CachedEnumLabel -Entry 'bsnMobileStationEntry' -Column 'bsnMobileStationMobilityStatus' -Value $airespaseMobility
            PolicyType = Get-CachedEnumLabel -Entry 'bsnMobileStationEntry' -Column 'bsnMobileStationPolicyType' -Value $airespasePolicyType
            Encryption = Get-CachedEnumLabel -Entry 'bsnMobileStationEntry' -Column 'bsnMobileStationEncryptionCypher' -Value $airespaceEncryption
            DeviceType = if ($null -ne $enriched) { [string]$enriched.DeviceType } else { '' }
        }
    }

    $clientInventory = $clientInventory | Sort-Object SSID, WlanProfileName, ClientMac
    $clientCsv = Join-Path $OutputDirectory 'wireless-client-inventory-summary.csv'
    $clientJson = Join-Path $OutputDirectory 'wireless-client-inventory-summary.json'
    $clientInventory | Export-Csv -LiteralPath $clientCsv -NoTypeInformation -Encoding UTF8
    ($clientInventory | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $clientJson -Encoding UTF8

    $summaryArtifacts += [PSCustomObject]@{ Name = 'client-inventory'; Root = 'airespace-client'; Csv = $clientCsv; Json = $clientJson; Count = @($clientInventory).Count }
    Write-Host "Built client inventory (AIRESPACE bsnMobileStation, direct AP base MAC joins): $(@($clientInventory).Count) rows" -ForegroundColor Green

} elseif (Test-Path -LiteralPath $clientInput) {
    # Fallback: CISCO-LWAPP-DOT11-CLIENT-MIB (gives BSSID, not AP base MAC)
    $clientEntryPrefix = '1.3.6.1.4.1.9.9.599.1.3.1.1'
    $clientRows = Build-TableRows -JsonlPath $clientInput -EntryPrefix $clientEntryPrefix -ColumnNameMap $clientColumnMap

    $clientInventory = foreach ($idx in $clientRows.Keys) {
        $row = $clientRows[$idx]
        $statusCode = if ($row.ContainsKey('cldcClientStatus')) { $row['cldcClientStatus'] } else { '' }
        $apMacHex = if ($row.ContainsKey('cldcApMacAddress__Hex')) { $row['cldcApMacAddress__Hex'] } else { '' }
        $apMacText = if ($row.ContainsKey('cldcApMacAddress')) { $row['cldcApMacAddress'] } else { '' }
        $resolvedApMac = if (-not [string]::IsNullOrWhiteSpace($apMacHex)) { Convert-HexStringToMac -Hex $apMacHex } else { Convert-OctetTextToMac -RawText $apMacText }

        $ssidRaw = if ($row.ContainsKey('cldcClientSSID')) { $row['cldcClientSSID'] } else { '' }
        $ssidHex = if ($row.ContainsKey('cldcClientSSID__Hex')) { $row['cldcClientSSID__Hex'] } else { '' }
        $ssid = Resolve-OctetStringText -RawText $ssidRaw -HexText $ssidHex

        $profileRaw = if ($row.ContainsKey('cldcClientWlanProfileName')) { $row['cldcClientWlanProfileName'] } else { '' }
        $profileHex = if ($row.ContainsKey('cldcClientWlanProfileName__Hex')) { $row['cldcClientWlanProfileName__Hex'] } else { '' }
        $wlanProfile = Resolve-OctetStringText -RawText $profileRaw -HexText $profileHex

        $usernameRaw = if ($row.ContainsKey('cldcClientUsername')) { $row['cldcClientUsername'] } else { '' }
        $usernameHex = if ($row.ContainsKey('cldcClientUsername__Hex')) { $row['cldcClientUsername__Hex'] } else { '' }
        $username = Resolve-OctetStringText -RawText $usernameRaw -HexText $usernameHex

        [PSCustomObject]@{
            ClientMac = Convert-IndexToMac -Index $idx
            IndexSuffix = $idx
            StatusCode = $statusCode
            Status = Get-ClientStatusLabel -Code $statusCode
            WlanProfileName = $wlanProfile
            SSID = $ssid
            Username = $username
            APMac = $resolvedApMac
            APSlot = ''
            ClientIP = if ($row.ContainsKey('cldcClientIPAddress')) { Convert-InetAddressToFriendly -RawText $row['cldcClientIPAddress'] -AddressType 'ipv4' } else { '' }
            AccessVLAN = if ($row.ContainsKey('cldcClientAccessVLAN')) { $row['cldcClientAccessVLAN'] } else { '' }
            Channel = if ($row.ContainsKey('cldcClientChannel')) { $row['cldcClientChannel'] } else { '' }
            AuthMode = if ($row.ContainsKey('cldcClientAuthMode')) { $row['cldcClientAuthMode'] } else { '' }
            DeviceType = if ($row.ContainsKey('cldcClientDeviceType')) { $row['cldcClientDeviceType'] } else { '' }
        }
    }

    $clientInventory = $clientInventory | Sort-Object SSID, WlanProfileName, ClientMac
    $clientCsv = Join-Path $OutputDirectory 'wireless-client-inventory-summary.csv'
    $clientJson = Join-Path $OutputDirectory 'wireless-client-inventory-summary.json'
    $clientInventory | Export-Csv -LiteralPath $clientCsv -NoTypeInformation -Encoding UTF8
    ($clientInventory | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $clientJson -Encoding UTF8

    $summaryArtifacts += [PSCustomObject]@{ Name = 'client-inventory'; Root = 'dot11-client'; Csv = $clientCsv; Json = $clientJson; Count = @($clientInventory).Count }
    Write-Host "Built client inventory (LWAPP fallback, BSSID-based AP MAC): $(@($clientInventory).Count) rows" -ForegroundColor Green
}

# WLAN inventory summary (translated with cLWlanConfigEntry labels).
$wlanInput = Join-Path $InputDirectory 'wireless-wlan.jsonl'
if (Test-Path -LiteralPath $wlanInput) {
    $wlanEntryPrefix = '1.3.6.1.4.1.9.9.512.1.1.1.1'
    $wlanRows = Build-TableRows -JsonlPath $wlanInput -EntryPrefix $wlanEntryPrefix -ColumnNameMap $wlanColumnMap

    $wlanInventory = foreach ($idx in $wlanRows.Keys) {
        $row = $wlanRows[$idx]
        [PSCustomObject]@{
            WlanIndex = if ($row.ContainsKey('cLWlanIndex')) { $row['cLWlanIndex'] } else { $idx }
            IndexSuffix = $idx
            ProfileName = if ($row.ContainsKey('cLWlanProfileName')) { $row['cLWlanProfileName'] } else { '' }
            SSID = if ($row.ContainsKey('cLWlanSsid')) { $row['cLWlanSsid'] } else { '' }
            RowStatus = if ($row.ContainsKey('cLWlanRowStatus')) { $row['cLWlanRowStatus'] } else { '' }
            IsWired = if ($row.ContainsKey('cLWlanIsWired')) { $row['cLWlanIsWired'] } else { '' }
            NACSupport = if ($row.ContainsKey('cLWlanNACSupport')) { $row['cLWlanNACSupport'] } else { '' }
            MaxClientsAllowedPerRadio = if ($row.ContainsKey('cLWlanMaxClientsAllowedPerRadio')) { $row['cLWlanMaxClientsAllowedPerRadio'] } else { '' }
            LoadBalancingEnable = if ($row.ContainsKey('cLWlanLoadBalancingEnable')) { $row['cLWlanLoadBalancingEnable'] } else { '' }
            BandSelectEnable = if ($row.ContainsKey('cLWlanBandSelectEnable')) { $row['cLWlanBandSelectEnable'] } else { '' }
        }
    }

    $wlanInventory = $wlanInventory | Sort-Object WlanIndex
    
    # Enrich client inventory with WLAN Profile Names using WLAN Index lookup
    if ($null -ne $clientInventory) {
        $wlanLookup = @{}
        foreach ($wlan in $wlanInventory) {
            $key = [string]$wlan.WlanIndex
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $wlanLookup[$key] = $wlan.ProfileName
            }
        }
        
        if ($wlanLookup.Count -gt 0) {
            $clientInventory = $clientInventory | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_.WlanProfileName) -and -not [string]::IsNullOrWhiteSpace($_.WlanIndex)) {
                    $wlanKey = [string]$_.WlanIndex
                    if ($wlanLookup.ContainsKey($wlanKey)) {
                        $_ | Add-Member -MemberType NoteProperty -Name 'WlanProfileName' -Value $wlanLookup[$wlanKey] -Force
                    }
                }
                $_
            }
        }
    }
    
    $wlanCsv = Join-Path $OutputDirectory 'wireless-wlan-inventory-summary.csv'
    $wlanJson = Join-Path $OutputDirectory 'wireless-wlan-inventory-summary.json'
    $wlanInventory | Export-Csv -LiteralPath $wlanCsv -NoTypeInformation -Encoding UTF8
    ($wlanInventory | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $wlanJson -Encoding UTF8

    $summaryArtifacts += [PSCustomObject]@{ Name = 'wlan-inventory'; Root = 'wlan'; Csv = $wlanCsv; Json = $wlanJson; Count = @($wlanInventory).Count }
    Write-Host "Built WLAN inventory summary: $(@($wlanInventory).Count) rows" -ForegroundColor Green
}

# Rogue AP proximity summary (optional, -IncludeRogues)
$rogueProximity = @()
if ($IncludeRogues -and (Test-Path -LiteralPath (Join-Path $InputDirectory 'wireless-rogue.jsonl'))) {
    $rogueLines = [System.IO.File]::ReadAllLines((Join-Path $InputDirectory 'wireless-rogue.jsonl'))
    $rogues = @{}
    foreach ($line in $rogueLines) {
        $obj = $line | ConvertFrom-Json
        # cLRogueAPDetectingAPEntry = 1.3.6.1.4.1.9.9.610.1.1.8.1.1
        if ($obj.OID.StartsWith('1.3.6.1.4.1.9.9.610.1.1.8.1.1.')) {
            $remainder = $obj.OID.Substring('1.3.6.1.4.1.9.9.610.1.1.8.1.1.'.Length)
            $parts = $remainder -split '\.'
            $col = [int]$parts[0]
            $rogueIndex = ($parts[1..6]) -join '.'
            
            if (-not $rogues.ContainsKey($rogueIndex)) { $rogues[$rogueIndex] = @{ RSSI = @(); SSID = ''; Channel = ''; ClassType = ''; State = ''; DetectCount = 0 } }
            if ($col -eq 1) { $rogues[$rogueIndex]['DetectCount']++ }
            if ($col -eq 3) { $rogues[$rogueIndex]['Channel'] = [string]$obj.Value }
            if ($col -eq 6) { $rogues[$rogueIndex]['SSID'] = [string]$obj.Value }
            if ($col -eq 8) { $rogues[$rogueIndex]['RSSI'] += [int]([string]$obj.Value) }
        }
    }
    
    $rogueProximity = $rogues.GetEnumerator() | ForEach-Object {
        $rssiList = $_.Value['RSSI']
        $bestRSSI = if ($rssiList.Count -gt 0) { ($rssiList | Measure-Object -Maximum).Maximum } else { -999 }
        [PSCustomObject]@{
            RogueMacIndex = $_.Key
            SSID = $_.Value['SSID']
            Channel = [string]$_.Value['Channel']
            BestRSSI = [string]$bestRSSI
            DetectingAPCount = [string]$_.Value['DetectCount']
        }
    } | Sort-Object { [int]$_.BestRSSI } -Descending
    
    if ($rogueProximity.Count -gt 0) {
        $rogueCsv = Join-Path $OutputDirectory 'wireless-rogue-proximity-summary.csv'
        $rogueJson = Join-Path $OutputDirectory 'wireless-rogue-proximity-summary.json'
        $rogueProximity | Export-Csv -LiteralPath $rogueCsv -NoTypeInformation -Encoding UTF8
        ($rogueProximity | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $rogueJson -Encoding UTF8
        $summaryArtifacts += [PSCustomObject]@{ Name = 'rogue-proximity'; Root = 'rogue'; Csv = $rogueCsv; Json = $rogueJson; Count = @($rogueProximity).Count }
        Write-Host "Built rogue proximity summary: $(@($rogueProximity).Count) rows" -ForegroundColor Green
    }
}

# RF group health summary (optional, -IncludeRfHealth)
$rfHealth = @()
if ($IncludeRfHealth -and (Test-Path -LiteralPath (Join-Path $InputDirectory 'wireless-rf.jsonl'))) {
    $rfLines = [System.IO.File]::ReadAllLines((Join-Path $InputDirectory 'wireless-rf.jsonl'))
    $rfGroups = @{}
    # Table 778.1.1.2.1 = RF group stats (64 columns, indexed by group name)
    $rfBase = '1.3.6.1.4.1.9.9.778.1.1.2.1'
    
    foreach ($line in $rfLines) {
        $obj = $line | ConvertFrom-Json
        if ($obj.OID.StartsWith($rfBase + '.')) {
            $remainder = $obj.OID.Substring(($rfBase + '.').Length)
            $parts = $remainder -split '\.'
            $col = [int]$parts[0]
            $groupNameLen = [int]$parts[1]
            $groupNameBytes = $parts[2..($groupNameLen + 1)]
            $groupName = ($groupNameBytes | ForEach-Object { [char][int]$_ }) -join ''
            
            if (-not $rfGroups.ContainsKey($groupName)) {
                $rfGroups[$groupName] = @{ Name = $groupName; Channels = ''; Utilization = ''; NoiseFloor = ''; TxPower = ''; ClientCount = '' }
            }
            
            # Col 2=group name, 43=channel list, others are power/utilization/noise
            if ($col -eq 43) { $rfGroups[$groupName]['Channels'] = [string]$obj.Value }
        }
    }
    
    if ($rfGroups.Count -gt 0) {
        $rfHealth = $rfGroups.Values | Sort-Object Name
        $rfCsv = Join-Path $OutputDirectory 'wireless-rf-health-summary.csv'
        $rfJson = Join-Path $OutputDirectory 'wireless-rf-health-summary.json'
        $rfHealth | Export-Csv -LiteralPath $rfCsv -NoTypeInformation -Encoding UTF8
        ($rfHealth | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $rfJson -Encoding UTF8
        $summaryArtifacts += [PSCustomObject]@{ Name = 'rf-health'; Root = 'rf'; Csv = $rfCsv; Json = $rfJson; Count = @($rfHealth).Count }
        Write-Host "Built RF group health summary: $(@($rfHealth).Count) rows" -ForegroundColor Green
    }
}

$topSsids = @()
if (@($clientInventory).Count -gt 0) {
    $topSsids = $clientInventory |
        Group-Object SSID |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
        Sort-Object Count -Descending |
        Select-Object -First 25 @{ n = 'SSID'; e = { $_.Name } }, @{ n = 'ClientCount'; e = { $_.Count } }
}

$clientsByAp = @{}
foreach ($client in @($clientInventory)) {
    $apMacKey = ([string]$client.APMac).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($apMacKey)) { continue }

    if (-not $clientsByAp.ContainsKey($apMacKey)) {
        $clientsByAp[$apMacKey] = New-Object System.Collections.Generic.List[object]
    }

    $clientsByAp[$apMacKey].Add($client)
}

$apOperational = foreach ($ap in @($apInventory)) {
    $apMacKey = ([string]$ap.APMac).ToUpperInvariant()
    $apClients = @()
    if (-not [string]::IsNullOrWhiteSpace($apMacKey) -and $clientsByAp.ContainsKey($apMacKey)) {
        $apClients = @($clientsByAp[$apMacKey].ToArray())
    }

    $ssidGroups = @(
        $apClients |
            Group-Object SSID |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
            Sort-Object Count -Descending
    )
    $statusGroups = @(
        $apClients |
            Group-Object Status |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
            Sort-Object Count -Descending
    )
    $topSsid = if ($ssidGroups.Count -gt 0) { [string]$ssidGroups[0].Name } else { '' }
    $topClientStatus = if ($statusGroups.Count -gt 0) { [string]$statusGroups[0].Name } else { '' }

    [PSCustomObject]@{
        APName = [string]$ap.APName
        APMac = [string]$ap.APMac
        Dot11Slots = [string]$ap.Dot11Slots
        ClientCount = @($apClients).Count
        DistinctSsidCount = @($ssidGroups).Count
        TopSSID = $topSsid
        TopClientStatus = $topClientStatus
        BestState = if (@($apClients).Count -gt 0) { 'active' } else { 'idle' }
        ClientHealthState = Get-ClientBestState -Status $topClientStatus
        ControllerPrimary = [string]$ap.PrimaryControllerAddress
        ControllerSecondary = [string]$ap.SecondaryControllerAddress
        ControllerTertiary = [string]$ap.TertiaryControllerAddress
        SiteTagName = [string]$ap.SiteTagName
        RfTagName = [string]$ap.RfTagName
        PolicyTagName = [string]$ap.PolicyTagName
        DomainName = [string]$ap.DomainName
        FilterName = [string]$ap.FilterName
        UsbSerialNumber = [string]$ap.UsbSerialNumber
        ApUptime = [string]$ap.ApUptime
        ControllerUptimeSeen = [string]$ap.ControllerUptimeSeen
        LastChange = [string]$ap.LastChange
        AdminStatus = [string]$ap.AdminStatus
        PowerStatus = [string]$ap.PowerStatus
        FailoverPriority = [string]$ap.FailoverPriority
        LastRebootReason = [string]$ap.LastRebootReason
        SubMode = [string]$ap.SubMode
        AntennaBandMode = [string]$ap.AntennaBandMode
        CpuCurrentPct = [string]$ap.CpuCurrentPct
        CpuAvgPct = [string]$ap.CpuAvgPct
        MemCurrentPct = [string]$ap.MemCurrentPct
        MemAvgPct = [string]$ap.MemAvgPct
        AssocClientCount = [string]$ap.AssocClientCount
        ActiveClientCount = [string]$ap.ActiveClientCount
    }
}

$apOperational = @($apOperational | Sort-Object -Property @(
    @{ Expression = 'ClientCount'; Descending = $true },
    @{ Expression = 'APName'; Descending = $false }
))

$dashboardData = [PSCustomObject]@{
    GeneratedAt = (Get-Date).ToString('o')
    Kpis = [PSCustomObject]@{
        APCount = @($apInventory).Count
        ClientCount = @($clientInventory).Count
        WlanCount = @($wlanInventory).Count
        RootSummaryCount = @($summaryArtifacts | Where-Object { $_.Name -like 'root-summary-*' }).Count
    }
    TopSsids = $topSsids
    ApOperational = $apOperational
    ArtifactIndex = $summaryArtifacts
}

$dashboardDataPath = Join-Path $OutputDirectory 'wireless-dashboard-datasets.json'
($dashboardData | ConvertTo-Json -Depth 20) | Out-File -LiteralPath $dashboardDataPath -Encoding UTF8

$summaryArtifacts += [PSCustomObject]@{
    Name = 'dashboard-datasets'
    Root = 'all'
    Count = @($topSsids).Count
    Csv = ''
    Json = $dashboardDataPath
}

$manifest = [PSCustomObject]@{
    InputDirectory = $InputDirectory
    OutputDirectory = $OutputDirectory
    MibDirectory = $MibDirectory
    GeneratedAt = (Get-Date).ToString('o')
    MibFilesUsed = [PSCustomObject]@{
        AP = $apMib
        Dot11Client = $clientMib
        Wlan = $wlanMib
    }
    Artifacts = $summaryArtifacts
}

($manifest | ConvertTo-Json -Depth 20) | Out-File -LiteralPath $ManifestPath -Encoding UTF8

Write-Host ''
Write-Host 'Wireless summary build complete.' -ForegroundColor Green
Write-Host "Manifest: $ManifestPath" -ForegroundColor Green
Write-Host 'Artifacts:' -ForegroundColor Cyan
$summaryArtifacts | Select-Object Name, Root, Count, Csv, Json | Format-Table -AutoSize
# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+hlK57fG4/aOv
# N3XArWRkCINgtE+cZHiOkhPZJGif/qCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCD1YWML9+vc38VQshTbdMA7zDGex1183VlXUQz2By7OIDANBgkqhkiG9w0BAQEF
# AASCAgAtabRiRHzBMdMSOESGbb817f8o3duSTZDCIC1v9zZhZi6FborfqDHd6JYw
# Rd0SHqFcAiSJE7pmJyrGeiFQ69tys0ZUVKLuoLbEhWUrWQqGWZyz0u0kc2J4IwRJ
# 86WFEeoV0NoA/vRS6DwFc4X3DTkPQJbp8wcgmZoDZwnSCfZE/svR+6JsGKmum9tX
# W+xN8jMwAFJp2h6jDyaGnWtMnz13ol1bZwaPHvoVoR0wuFW14X6Cpy83FDFOG2nW
# BkaI8KgfLAJEOZ5BqID4AZxe6XrBsUZZ4NHwopvhIs8Bq1KceDwnDLbyFdOJglmx
# +6ivTSowWrOjsBdyNkUy/90LWyl2XKGX5QB57YRqWfSa17wx/OXerxxDrGM/7s+i
# dhucAWfO6MNg/5d+mOZADASHBbitL28uMKx/U/vCeAZ8afA6MnCVZHJuucxzCSqE
# E6NRKTvdUPgPYMKofs7qgAb8W7dSU16wxUfbSakW9HWQQquurWBZu0Bs572z++xI
# JHFNg/JNoYxHMx5xuYvQB3zZ+HOZOMQM8dbq7sYgO4kSzfdwdLbn2w54hpbRma7X
# RIWxNgbtvNPNX0TMXlmL8I4TxsfBC+DpyfBqisImyHQsMBIb8VvLQcE+6X1vTCGd
# aOE6r6EqT50g4P5Rjtzfc/rqcxDiy7rCoxLeW/iQJj6uoTW9z6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA2MjUxNjA1MzhaMC8GCSqGSIb3DQEJBDEiBCDJNEb7
# QMQHRdf7+9oASVxZMWdGYOpV1zznQ4iKhOU74TANBgkqhkiG9w0BAQEFAASCAgBg
# vCdllN7Zn/ZHr/nEPPY7YSrd97PMltWFH8pApL4YxdCXTojsijuq7BrSu8AnJM2a
# hh+F2Z97dMRQ4cQ6mlW1WU+sRZ3bUOiOHe4/IPm+1PUq6JdrOChvCBINxdKBWfPt
# k2umXqymKwjyzmUswCzgAovTnfuw76phspeu6w9XGS6+2dUCm0Dw+Xpm0BaQ/SER
# VMVIgaXVFg/ojW+k1KmaRpBBZsmWWIcq0f4/xyA+rQGsU4jDVR6A9BtP+M67pvvD
# oZ0RfKsx/O8CewK3hyZ/mUzvUzSwk+jSrndLvuDZZ6G2K6bE4d8r4nWCFmBQFYU5
# lqbpg+e6goHCY7h1jNeiJqsm5Y0aDt8J/hXj3o8EZ/m0HgOhmSh6G3UKqlOZ1hH/
# N7MAtx2ud7I3DNs65lHmKEREJNI3BHt6yz/M00rJLF9kpPbPibgcJc2cTmzAd1QF
# /rNHVrvIE2k9f+cmooYTfEcJl6ODMaOHFeT7cI4dB4hB585RCyeaJPeb6JXBsobJ
# zSLTAE4vb1Uhn1Hwn6je7XnuZEjFfQggrKY+SxmlQnL154xkqISRP2+RjPB6rGSn
# S5+PVlMnun+1yWsV3omSj3dXjVfZ1vzXsL3Qn9ySRb1wD4CU0TQR2t/UQ3oMo4A/
# TjocSbJb9hAVSL373NSqaqE3iVbJJuu2/8Ms30wMfQ==
# SIG # End signature block
