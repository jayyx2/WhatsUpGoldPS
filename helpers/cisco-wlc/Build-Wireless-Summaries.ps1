#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InputDirectory = 'C:\temp\wireless-full',
    [string]$OutputDirectory = 'C:\temp\wireless-summary',
    [string]$MibDirectory = (Join-Path $PSScriptRoot 'mibs'),
    [string]$ManifestPath = 'C:\temp\wireless-summary\wireless-summary-manifest.json',
    [bool]$IncludeRogues = $true,
    [bool]$IncludeRfHealth = $true,
    [bool]$IncludeJoinTime = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUv/JbG212KPqek/pcUDHwlM3w
# 1aCggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# EAqA7xhLjfEFgtHEdqeVdGgwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0y
# NTA2MDQwMDAwMDBaFw0zNjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJT
# QTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI1IDEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDQRqwtEsae0OquYFazK1e6b1H/hnAKAd/KN8wZQjBj
# MqiZ3xTWcfsLwOvRxUwXcGx8AUjni6bz52fGTfr6PHRNv6T7zsf1Y/E3IU8kgNke
# ECqVQ+3bzWYesFtkepErvUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDMemQFoxQ2Dsw4
# vEjoT1FpS54dNApZfKY61HAldytxNM89PZXUP/5wWWURK+IfxiOg8W9lKMqzdIo7
# VA1R0V3Zp3DjjANwqAf4lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7XOc4zyh1uSqg
# r6UnbksIcFJqLbkIXIPbcNmA98Oskkkrvt6lPAw/p4oDSRZreiwB7x9ykrjS6GS3
# NR39iTTFS+ENTqW8m6THuOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07hqF+8CTXaETk
# VWz0dVVZw7knh1WZXOLHgDvundrAtuvz0D3T+dYaNcwafsVCGZKUhQPL1naFKBy1
# p6llN3QgshRta6Eq4B40h5avMcpi54wm0i2ePZD5pPIssoszQyF4//3DoK2O65Uc
# k5Wggn8O2klETsJ7u8xEehGifgJYi+6I03UuT1j7FnrqVrOzaQoVJOeeStPeldYR
# NMmSF3voIgMFtNGh86w3ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNVwppwn4D3/Pt5
# pwIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU5Dv88jHt/f3X
# 85FxYxlQQ89hjOgwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYD
# VR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcB
# AQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0G
# CCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYD
# VR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAZSqt8RwnBLmuYEHs0QhEnmNAciH45PYiT9s1i6UKtW+FERp8FgXRGQ/YAavX
# zWjZhY+hIfP2JkQ38U+wtJPBVBajYfrbIYG+Dui4I4PCvHpQuPqFgqp1PzC/ZRX4
# pvP/ciZmUnthfAEP1HShTrY+2DE5qjzvZs7JIIgt0GCFD9ktx0LxxtRQ7vllKluH
# WiKk6FxRPyUPxAAYH2Vy1lNM4kzekd8oEARzFAWgeW3az2xejEWLNN4eKGxDJ8WD
# l/FQUSntbjZ80FU3i54tpx5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8VMbtoRAmaasl
# NXdCG1+lqvP4FbrQ6IwSBXkZagHLhFU9HCrG/syTRLLhAezu/3Lr00GrJzPQFnCE
# H1Y58678IgmfORBPC1JKkYaEt2OdDh4GmO0/5cHelAK2/gTlQJINqDr6JfwyYHXS
# d+V08X1JUPvB4ILfJdmL+66Gp3CSBXG6IwXMZUXBhtCyIaehr0XkBoDIGMUG1dUt
# wq1qmcwbdUfcSYCn+OwncVUXf53VJUNOaMWMts0VlRYxe5nK+At+DI96HAlXHAL5
# SlfYxJ7La54i71McVWRP66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4uPcU3AWVPGrbn
# 5PhDBf3Froguzzhk++ami+r3Qrx5bIbY3TVzgiFI7Gq3zWcxggYzMIIGLwIBATBo
# MFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNV
# BAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+F
# zTlzz3YtN+swCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFM8vpjqnrnlCB5cWwDr5U/R2rOQ+MA0G
# CSqGSIb3DQEBAQUABIICAKeJu8YAEMdZND73a4Az3eCJZlghzT+QXuSrvklZAnp/
# A1UoNk3/aVPaoAe6ABXNIuFbtgCgQ+8W15b+fHnO00fzo2PLt6kS0yMQt94UaQlH
# IwOKkATCqt27XuQnr9NTBYsRh8RUOB3ftEGPiYqB+xK+mR9ukcXlKcsdH0NSdEoC
# /2VP03TUfbx6rwdnwIEC5Vj6rxHDi548azoh2ErHw7QubWl7vxzVZdkZzSKHL+AJ
# oZR+2G/jnZRL7CfqypkzCEy+zmXaN+YQaOvLe6n37CyPUIMtYL9kupBIYNOmJmfR
# cuvw+eozuZW7C7OkeUZ5qEOpUaEWg2wcj2APNc2sRLZUTQEOVUxtLaKJ3xbBbkkJ
# e+KxN0LkC60FNr0/GkK33aXak058+E/tNP5nEw+e9pDL8zCwIJIk4K2j1poPqHKq
# 0xjaGtYXQ1RzoGX3kCnwMumMIIDfa5uPYUVCzK3veQknBS5CmGTHFd61/+ngoqlf
# 1imp3eeIBbFDsWDvJMUbkNeIS4DS4wkaO7zahbQYU9rO3ANQPzAOe/uzntYM0d5D
# Yix5twkhHJw1H0gNW0ZxoOegpwQsgrpF9EWsPXEqajA6S2bKPJ9Nkt8j0SQPCGpZ
# IbOQwdmcV9zPSQcRqfg3SvkKIs8DG3txeMK3ENZXCDP9coVESBhMnwoWLKV2uBAS
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDv
# GEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDYyMzEyNDE0NlowLwYJKoZIhvcN
# AQkEMSIEIIQxpFKALDsIjH84/mFIp/d0TGbJFgJ7WXEHT9gigBRuMA0GCSqGSIb3
# DQEBAQUABIICAHYE9npUgt79JsPlY69wbXgiTCqJYocFENYP8zUNWLPECU8wWWXW
# Q3/ReJMx8/fqBbLuaZReaYyb3OETrsg1wP2mXiUgUi94SdvWK0S0RpY7SD+IM5Ku
# aaH6Rj8aUbyTv5JG1jXalCSuQi+1t+HBSLgsE9ZqbvbIhrhcaT4XbwwsdDwPRvkw
# HCAbrbKmVpCZ9ZvceLCA8Q5CE0Elj08HTc/hSvFrimMR5LScC6kOmGLMyFd7p7uA
# Lj61nxboZHpY8FSalwdqq8oIlx9Cio/eGkL/TJswrxHP8M/+yonP7/N0MDJKZ+t8
# uVZPThJUJc05CYiuUCMFZ5i1iCBFWBpwBXITsZkeOLNNpW4Ox15u8jxWN/uMozXi
# C+AaW7S0HhvMEAiUmpN63wNKfUIN/wuX9p2JwMpEztFIIyHZPTl47/+YG+qgBq/p
# QS8jiu1UTWy1CUSMl/uraL1o2XQRAOS8j6XPkTsg9skTIMwvfCyU0E9sJiZWWYAm
# B7gGlVyxoe/V2Wr/RiwxZZu6psB3YkDhbZZviR9JqdoeD+xfOfyHtHOFV2NbPblH
# m/+7lx1E00QC/qRpDUIbr1GcPwKevnVUupBJGwpaEP2g+0ZJ2QCCDXlP59rhUDxd
# 5qwBVFNRpkNWErv3klVEhQqv3n+Qs/r3oFhk61wRLC4sReT3NQkd0oDv
# SIG # End signature block
