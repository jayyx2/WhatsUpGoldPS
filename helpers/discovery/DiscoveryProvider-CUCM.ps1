<#
.SYNOPSIS
    Cisco Unified Communications Manager discovery provider for dashboards and WUG SNMP monitor plans.

.DESCRIPTION
    Registers a CUCM discovery provider that uses SharpSnmpLib SNMP module
    to walk Cisco's ccmPhoneTable and derive a framework-aligned WUG monitor plan.

    The provider exposes helper functions so setup scripts can:
      - collect the full phone inventory for dashboards and exports
      - build a shared SNMPTable monitor definition for phone registration status
      - stamp useful aggregate CUCM counts onto the target WUG device

.NOTES
    Requires: DiscoveryHelpers.ps1 loaded first, WhatsUpGoldPS.Snmp module
    Encoding: UTF-8 with BOM
#>

if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $discoveryPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'DiscoveryHelpers.ps1'
    if (Test-Path $discoveryPath) {
        . $discoveryPath
    }
    else {
        throw 'DiscoveryHelpers.ps1 not found. Load it before this provider.'
    }
}

# Load WhatsUpGoldPS.Snmp module
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$snmpModulePath = Join-Path (Split-Path $scriptDir -Parent) 'snmp\WhatsUpGoldPS.Snmp\WhatsUpGoldPS.Snmp.psd1'
if (-not (Get-Module -Name 'WhatsUpGoldPS.Snmp')) {
    if (Test-Path $snmpModulePath) {
        Import-Module $snmpModulePath -Force -ErrorAction Stop
        Write-Verbose "[CUCM] Loaded WhatsUpGoldPS.Snmp module"
    }
    else {
        throw "WhatsUpGoldPS.Snmp module not found at: $snmpModulePath"
    }
}

# Initialize SharpSnmpLib
if (Get-Command -Name 'Import-SharpSnmpLib' -ErrorAction SilentlyContinue) {
    Import-SharpSnmpLib -ErrorAction Stop | Out-Null
    Write-Verbose "[CUCM] SharpSnmpLib initialized"
}

# ============================================================================
# Shared OctetString decoder -- used by BOTH walk paths (SharpSnmpLib + COM API)
# so that binary SNMP columns produce identical output regardless of library.
#
# Column type map (script-scope so both functions can reference it):
#   MAC  -- 6-byte OctetString -> AA:BB:CC:DD:EE:FF
#   Date -- 8/11-byte DateAndTime -> YYYY-MM-DD HH:MM:SS
#   Inet -- 4-byte IPv4 or 16-byte IPv6 OctetString -> dotted / colon notation
# ============================================================================
$script:CUCMColumnDecodeType = @{
    '2'  = 'MAC'    # PhonePhysicalAddress
    '8'  = 'Date'   # PhoneTimeLastRegistered
    '12' = 'Date'   # PhoneTimeLastError
    '15' = 'Inet'   # PhoneInetAddress
    '17' = 'Date'   # PhoneTimeLastStatusUpdt
    '21' = 'Inet'   # PhoneInetAddressIPv4
    '22' = 'Inet'   # PhoneInetAddressIPv6
}

function ConvertFrom-CUCMSnmpOctetString {
    <#
    .SYNOPSIS
        Decodes a raw byte array from a binary SNMP OctetString column into a
        human-readable string. Returns $null if the byte count is not expected
        (caller should fall back to the raw string value).
    .PARAMETER Bytes
        Raw byte array extracted from the SNMP response.
    .PARAMETER ColumnType
        One of 'MAC', 'Date', or 'Inet' (from $script:CUCMColumnDecodeType).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [ValidateSet('MAC','Date','Inet')]
        [string]$ColumnType
    )

    switch ($ColumnType) {
        'MAC' {
            if ($Bytes.Count -eq 6) {
                return ($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ':'
            }
        }
        'Date' {
            if ($Bytes.Count -ge 8) {
                $year  = ([int]$Bytes[0] -shl 8) + [int]$Bytes[1]
                $month = [int]$Bytes[2]; $day  = [int]$Bytes[3]
                $hour  = [int]$Bytes[4]; $min  = [int]$Bytes[5]; $sec = [int]$Bytes[6]
                return ('{0}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}' -f $year,$month,$day,$hour,$min,$sec)
            }
        }
        'Inet' {
            if ($Bytes.Count -eq 4) {
                return "$($Bytes[0]).$($Bytes[1]).$($Bytes[2]).$($Bytes[3])"
            }
            if ($Bytes.Count -eq 16) {
                return ([System.Net.IPAddress]::new($Bytes)).ToString()
            }
        }
    }
    return $null   # unexpected byte count -- caller uses raw string
}

# ============================================================================
# Protocol code converters for WUG COM API (CoreAsp.SnmpRqst Initialize4)
# ============================================================================
function ConvertTo-CUCMComApiAuthCode {
    param([string]$Protocol)
    $map = @{
        'None'   = 0; 'MD5'    = 1; 'SHA'    = 3; 'SHA1'   = 3
        'SHA256' = 5; 'SHA384' = 6; 'SHA512' = 7
    }
    if ($map.ContainsKey($Protocol)) { return $map[$Protocol] }
    Write-Verbose "[COM] Unknown auth protocol '$Protocol', defaulting to None (0)"
    return 0
}

function ConvertTo-CUCMComApiPrivCode {
    param([string]$Protocol)
    $map = @{
        'None'      = 0; 'DES'    = 1; '3DES'  = 2; 'TripleDES' = 2
        'AES'       = 3; 'AES128' = 3; 'AES192' = 4; 'AES256'    = 5
    }
    if ($map.ContainsKey($Protocol)) { return $map[$Protocol] }
    Write-Verbose "[COM] Unknown priv protocol '$Protocol', defaulting to None (0)"
    return 0
}

# ============================================================================
# WUG COM API walk (CoreAsp.SnmpRqst) -- fallback when SharpSnmpLib fails.
# Returns the same walkData ordered hashtable consumed by Get-CUCMPhoneInventory
# Phase 2 (instance -> column -> string value, no binary decoding needed).
# ============================================================================
function Invoke-CUCMPhoneWalkComApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetAddress,

        [Parameter(Mandatory = $true)]
        [hashtable]$Credential
    )

    $snmpVersion   = if ($Credential.SnmpVersion)      { [int]$Credential.SnmpVersion }        else { 2 }
    $community     = if ($Credential.Community)         { [string]$Credential.Community }       else { '' }
    $username      = if ($Credential.Username)          { [string]$Credential.Username }        else { '' }
    $context       = if ($Credential.Context)           { [string]$Credential.Context }         else { '' }
    $authProtoName = if ($Credential.AuthProtocol)      { [string]$Credential.AuthProtocol }    else { 'None' }
    $privProtoName = if ($Credential.PrivacyProtocol)   { [string]$Credential.PrivacyProtocol } else { 'None' }
    $authPassword  = if ($Credential.AuthPassword)      { [string]$Credential.AuthPassword }    else { '' }
    $privPassword  = if ($Credential.PrivacyPassword)   { [string]$Credential.PrivacyPassword } else { '' }
    $snmpPort      = if ($Credential.Port)              { [int]$Credential.Port }               else { 161 }
    $timeoutMs     = if ($Credential.TimeoutMs)         { [int]$Credential.TimeoutMs }          else { 5000 }
    $retries       = if ($null -ne $Credential.Retries) { [int]$Credential.Retries }            else { 1 }

    $authCode = ConvertTo-CUCMComApiAuthCode -Protocol $authProtoName
    $privCode = ConvertTo-CUCMComApiPrivCode -Protocol $privProtoName

    $tableBaseOid = '1.3.6.1.4.1.9.9.156.1.2.1.1'

    Write-Host "    [COM API] Connecting via CoreAsp.SnmpRqst to ${TargetAddress}..." -ForegroundColor DarkGray
    Write-Verbose "[COM] Initialize4: Target=$TargetAddress  v=$snmpVersion  Port=$snmpPort  Timeout=${timeoutMs}ms"
    if ($snmpVersion -eq 3) {
        Write-Verbose "[COM] v3: Username=$username  AuthProto=$authProtoName ($authCode)  PrivProto=$privProtoName ($privCode)"
    }

    $snmpRequest = New-Object -ComObject 'CoreAsp.SnmpRqst'
    $initResult  = $snmpRequest.Initialize4(
        $TargetAddress, $snmpVersion, $community,
        $username, $context,
        $authCode, $authPassword,
        $privCode, $privPassword
    )
    if ($initResult.Failed) {
        throw "COM API Initialize4 failed for ${TargetAddress}: $($initResult.GetErrorMsg())"
    }

    if ($snmpRequest.SetTimeoutMs($timeoutMs).Failed) { Write-Warning 'COM API: SetTimeoutMs failed (non-fatal)' }
    if ($snmpRequest.SetNumRetries($retries).Failed)  { Write-Warning 'COM API: SetNumRetries failed (non-fatal)' }
    if ($snmpRequest.SetPort($snmpPort).Failed)        { Write-Warning 'COM API: SetPort failed (non-fatal)' }

    Write-Host "    [COM API] Walking ccmPhoneEntry subtree (GetNext loop)..." -ForegroundColor DarkGray
    $walkResponse = $snmpRequest.GetNext($tableBaseOid)
    if ($walkResponse.Failed) {
        throw "COM API: Initial GetNext failed for ${TargetAddress}: $($walkResponse.GetErrorMsg())"
    }

    $walkData  = [ordered]@{}
    $walkCount = 0

    # COM API GetValue() returns binary OctetStrings as raw byte strings (Latin1-encoded).
    # Use ConvertFrom-CUCMSnmpOctetString (shared decoder) with Latin1 byte extraction.

    while (-not $walkResponse.Failed) {
        $currentOid = ([string]$walkResponse.GetOid()).TrimStart('.')
        if (-not $currentOid.StartsWith("$tableBaseOid.")) {
            Write-Verbose "[COM] OID outside subtree -- walk complete: $currentOid"
            break
        }

        $suffix = $currentOid.Substring($tableBaseOid.Length + 1)
        $dotPos = $suffix.IndexOf('.')
        if ($dotPos -ge 0) {
            $colNum   = $suffix.Substring(0, $dotPos)
            $instance = $suffix.Substring($dotPos + 1)
            $value    = ''
            try { $value = [string]$walkResponse.GetValue() } catch { $value = '' }

            # Decode binary OctetString columns using shared decoder
            $decodeType = $script:CUCMColumnDecodeType[$colNum]
            if ($decodeType) {
                $raw     = [System.Text.Encoding]::Latin1.GetBytes($value)
                $decoded = ConvertFrom-CUCMSnmpOctetString -Bytes $raw -ColumnType $decodeType
                if ($null -ne $decoded) { $value = $decoded }
            }

            if (-not $walkData.Contains($instance)) { $walkData[$instance] = @{} }
            $walkData[$instance][$colNum] = $value

            $walkCount++
            if ($walkCount % 200 -eq 0) {
                Write-Host "    [COM API] $walkCount OIDs collected ($($walkData.Count) phones)..." -ForegroundColor DarkGray
            }
            Write-Verbose "[COM] OID $walkCount : col=$colNum instance=$instance value='$value'"
        }

        $walkResponse = $snmpRequest.GetNext($currentOid)
    }

    Write-Host "    [COM API] Walk complete: $walkCount OIDs, $($walkData.Count) phone instance(s)" -ForegroundColor Green
    Write-Verbose "[COM] Walk finished. OIDs=$walkCount  Instances=$($walkData.Count)"

    return $walkData
}

function Get-CUCMPhoneColumnMap {
    [CmdletBinding()]
    param()

    return [ordered]@{
        'CUCM.PhoneIndex'              = '1.3.6.1.4.1.9.9.156.1.2.1.1.1'
        'CUCM.PhonePhysicalAddress'    = '1.3.6.1.4.1.9.9.156.1.2.1.1.2'
        'CUCM.PhoneType'               = '1.3.6.1.4.1.9.9.156.1.2.1.1.3'
        'CUCM.PhoneDescription'        = '1.3.6.1.4.1.9.9.156.1.2.1.1.4'
        'CUCM.PhoneUserName'           = '1.3.6.1.4.1.9.9.156.1.2.1.1.5'
        'CUCM.PhoneIpAddress'          = '1.3.6.1.4.1.9.9.156.1.2.1.1.6'
        'CUCM.PhoneStatus'             = '1.3.6.1.4.1.9.9.156.1.2.1.1.7'
        'CUCM.PhoneTimeLastRegistered' = '1.3.6.1.4.1.9.9.156.1.2.1.1.8'
        'CUCM.PhoneE911Location'       = '1.3.6.1.4.1.9.9.156.1.2.1.1.9'
        'CUCM.PhoneLoadID'             = '1.3.6.1.4.1.9.9.156.1.2.1.1.10'
        'CUCM.PhoneLastError'          = '1.3.6.1.4.1.9.9.156.1.2.1.1.11'
        'CUCM.PhoneTimeLastError'      = '1.3.6.1.4.1.9.9.156.1.2.1.1.12'
        'CUCM.PhoneDevicePoolIndex'    = '1.3.6.1.4.1.9.9.156.1.2.1.1.13'
        'CUCM.PhoneInetAddressType'    = '1.3.6.1.4.1.9.9.156.1.2.1.1.14'
        'CUCM.PhoneInetAddress'        = '1.3.6.1.4.1.9.9.156.1.2.1.1.15'
        'CUCM.PhoneStatusReason'       = '1.3.6.1.4.1.9.9.156.1.2.1.1.16'
        'CUCM.PhoneTimeLastStatusUpdt' = '1.3.6.1.4.1.9.9.156.1.2.1.1.17'
        'CUCM.PhoneProductTypeIndex'   = '1.3.6.1.4.1.9.9.156.1.2.1.1.18'
        'CUCM.PhoneProtocol'           = '1.3.6.1.4.1.9.9.156.1.2.1.1.19'
        'CUCM.PhoneName'               = '1.3.6.1.4.1.9.9.156.1.2.1.1.20'
        'CUCM.PhoneInetAddressIPv4'    = '1.3.6.1.4.1.9.9.156.1.2.1.1.21'
        'CUCM.PhoneInetAddressIPv6'    = '1.3.6.1.4.1.9.9.156.1.2.1.1.22'
        'CUCM.PhoneIPv4Attribute'      = '1.3.6.1.4.1.9.9.156.1.2.1.1.23'
        'CUCM.PhoneIPv6Attribute'      = '1.3.6.1.4.1.9.9.156.1.2.1.1.24'
        'CUCM.PhoneActiveLoadID'       = '1.3.6.1.4.1.9.9.156.1.2.1.1.25'
        'CUCM.PhoneUnregReason'        = '1.3.6.1.4.1.9.9.156.1.2.1.1.26'
        'CUCM.PhoneRegFailReason'      = '1.3.6.1.4.1.9.9.156.1.2.1.1.27'
    }
}

function ConvertFrom-CUCMSnmpVarBindPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PayloadXml
    )

    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($PayloadXml)) {
        return $result
    }

    [xml]$xmlDoc = $PayloadXml
    $varBinds = @($xmlDoc.VarBindList.SnmpVarBind)
    foreach ($varBind in $varBinds) {
        if ($null -eq $varBind) { continue }

        $oid = [string]$varBind.sOid
        if ([string]::IsNullOrWhiteSpace($oid)) { continue }

        $hasError = "$($varBind.bHasError)" -eq 'true'
        if ($hasError) {
            $errorText = [string]$varBind.sError
            if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = 'SNMP error' }
            $result[$oid] = "N/A ($errorText)"
        }
        else {
            $result[$oid] = [string]$varBind.sValue
        }
    }

    return $result
}

function ConvertFrom-CUCMEnumValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [hashtable]$Map
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Map.ContainsKey($Value)) { return $Map[$Value] }
    return $Value
}

function ConvertFrom-CUCMDateValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    if ($Value -match '^(\d{4})-(\d{1,2})-(\d{1,2}),(\d{1,2}):(\d{1,2}):(\d{1,2})') {
        try {
            return (Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3]) -Hour ([int]$Matches[4]) -Minute ([int]$Matches[5]) -Second ([int]$Matches[6])).ToString('yyyy-MM-dd HH:mm:ss')
        }
        catch {
            return $Value
        }
    }

    return $Value
}

function Get-CUCMPhoneStatusCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PhoneRows
    )

    $counts = [ordered]@{
        total               = 0
        registered          = 0
        unregistered        = 0
        rejected            = 0
        partiallyregistered = 0
        unknown             = 0
    }

    foreach ($row in $PhoneRows) {
        $counts.total++
        $status = [string]$row.Status
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = 'unknown'
        }
        if ($counts.Contains($status)) {
            $counts[$status]++
        }
        else {
            $counts.unknown++
        }
    }

    return $counts
}

function Get-CUCMPhoneInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName,

        [Parameter(Mandatory = $true)]
        [string]$TargetAddress,

        [Parameter(Mandatory = $true)]
        [hashtable]$Credential
    )

    $snmpVersion = if ($Credential.SnmpVersion) { [int]$Credential.SnmpVersion } else { 2 }
    $community = if ($Credential.Community) { [string]$Credential.Community } else { '' }
    $username = if ($Credential.Username) { [string]$Credential.Username } else { '' }
    $context = if ($Credential.Context) { [string]$Credential.Context } else { '' }
    $authProtocol = if ($Credential.AuthProtocol) { [string]$Credential.AuthProtocol } else { 'None' }
    $authPassword = if ($Credential.AuthPassword) { [string]$Credential.AuthPassword } else { '' }
    $privacyProtocol = if ($Credential.PrivacyProtocol) { [string]$Credential.PrivacyProtocol } else { 'None' }
    $privacyPassword = if ($Credential.PrivacyPassword) { [string]$Credential.PrivacyPassword } else { '' }
    $snmpPort = if ($Credential.Port) { [int]$Credential.Port } else { 161 }
    $timeoutMs = if ($Credential.TimeoutMs) { [int]$Credential.TimeoutMs } else { 5000 }
    $retries = if ($null -ne $Credential.Retries) { [int]$Credential.Retries } else { 1 }

    $statusMap = @{
        '1' = 'unknown'
        '2' = 'registered'
        '3' = 'unregistered'
        '4' = 'rejected'
        '5' = 'partiallyregistered'
    }
    $protocolMap = @{
        '1' = 'unknown'
        '2' = 'sccp'
        '3' = 'sip'
    }
    $addressScopeMap = @{
        '0' = 'unknown'
        '1' = 'adminOnly'
        '2' = 'controlOnly'
        '3' = 'adminAndControl'
    }

    # CcmDevFailCauseCode — used by StatusReason, UnregReason, RegFailReason
    $causeCodeMap = @{
        '0'  = 'noError'
        '1'  = 'unknown'
        '2'  = 'noEntryInDatabase'
        '3'  = 'databaseConfigurationError'
        '4'  = 'deviceNameUnresolveable'
        '5'  = 'maxDevRegReached'
        '6'  = 'connectivityError'
        '7'  = 'initializationError'
        '8'  = 'deviceInitiatedReset'
        '9'  = 'callManagerReset'
        '10' = 'authenticationError'
        '11' = 'invalidX509NameInCertificate'
        '12' = 'invalidTLSCipher'
        '13' = 'directoryNumberMismatch'
        '14' = 'malformedRegisterMsg'
        '15' = 'protocolMismatch'
        '16' = 'deviceNotActive'
        '17' = 'registrationSequenceError'
        '18' = 'keepAliveTimeout'
        '19' = 'configurationMismatch'
        '20' = 'callManagerRestart'
        '21' = 'duplicateRegistration'
        '22' = 'callManagerApplyConfig'
        '23' = 'deviceNoResponse'
        '24' = 'emsLoginFailed'
        '25' = 'phoneDnDEnabled'
        '26' = 'sourceIPAddrChanged'
        '27' = 'sourcePortChanged'
        '28' = 'registrationRevoked'
        '29' = 'fallbackInitiated'
        '30' = 'fallbackCompleted'
    }

    # ccmPhoneType (column 3) — common Cisco phone type enum values
    $phoneTypeMap = @{
        '1'   = 'otherPhone'
        '2'   = 'cisco30SPPhone'
        '3'   = 'cisco12SPPhone'
        '4'   = 'cisco12SPPlusPhone'
        '5'   = 'cisco12SPhone'
        '6'   = 'cisco30VIPPhone'
        '30'  = 'cisco7960'
        '31'  = 'cisco7940'
        '61'  = 'cisco7935'
        '72'  = 'cisco7902'
        '73'  = 'cisco7912'
        '100' = 'cisco7961'
        '104' = 'ciscoSoftPhone'
        '115' = 'cisco6921'
        '119' = 'cisco7936'
        '124' = 'cisco7911'
        '148' = 'cisco7931'
        '165' = 'cisco7921'
        '196' = 'cisco8961'
        '254' = 'cisco7925'
        '255' = 'cisco7937'
        '279' = 'cisco6961'
        '282' = 'cisco6945'
        '284' = 'cisco6941'
        '285' = 'cisco6911'
        '302' = 'cisco7841'
        '307' = 'cisco7821'
        '308' = 'cisco7861'
        '334' = 'ciscoJabber'
        '335' = 'cisco8845'
        '336' = 'cisco8865'
        '365' = 'cisco7832'
        '562' = 'cisco8832'
        '621' = 'ciscoWebexDesk'
        '683' = 'ciscoDeskPhone9800'
    }

    $columns = Get-CUCMPhoneColumnMap
    $tableBaseOid = '1.3.6.1.4.1.9.9.156.1.2.1.1'

    # Build reverse lookup: column number string -> attribute name
    $columnToName = @{}
    foreach ($attrName in $columns.Keys) {
        $colNum = $columns[$attrName].Substring($tableBaseOid.Length + 1)
        $columnToName[$colNum] = $attrName
    }

    $phoneRows = [System.Collections.ArrayList]@()

    Write-Host "  Initiating SNMP walk: $TargetAddress (v$snmpVersion, port $snmpPort, timeout ${timeoutMs}ms)" -ForegroundColor Cyan

    # ---- Phase 1: Walk ccmPhoneEntry -- SharpSnmpLib, with WUG COM API fallback ----
    $walkData   = $null
    $walkMethod = 'SharpSnmpLib'
    try {
        Write-Verbose "[SNMP] Using SharpSnmpLib for CUCM table walk"
        Write-Verbose "[SNMP] Target=$TargetAddress  Version=$snmpVersion  Port=$snmpPort  Timeout=${timeoutMs}ms"
        if ($snmpVersion -eq 3) {
            Write-Verbose "[SNMP] v3 params: Username=$username  AuthProto=$authProtocol  PrivProto=$privacyProtocol"
        }

        Write-Host "    Bulk walking ccmPhoneEntry OID tree (SharpSnmpLib)..." -ForegroundColor DarkGray

        $walkParams = @{
            Target  = $TargetAddress
            Table   = $tableBaseOid
            Port    = $snmpPort
            Timeout = $timeoutMs
        }

        if ($snmpVersion -in @(1, 2)) {
            $walkParams['Version']   = "V$snmpVersion"
            $walkParams['Community'] = $community
            $walkResult = Invoke-SNMPBulkWalk @walkParams -ErrorAction Stop
        }
        else {
            $walkParams['Version']      = 'V3'
            $walkParams['Username']     = $username
            $walkParams['AuthProtocol'] = $authProtocol
            $walkParams['PrivProtocol'] = $privacyProtocol

            if ($authPassword -is [string] -and -not [string]::IsNullOrWhiteSpace($authPassword)) {
                $walkParams['AuthPassword'] = ConvertTo-SecureString -String $authPassword -AsPlainText -Force
            }
            elseif ($authPassword -is [System.Security.SecureString]) {
                $walkParams['AuthPassword'] = $authPassword
            }

            if ($privacyPassword -is [string] -and -not [string]::IsNullOrWhiteSpace($privacyPassword)) {
                $walkParams['PrivPassword'] = ConvertTo-SecureString -String $privacyPassword -AsPlainText -Force
            }
            elseif ($privacyPassword -is [System.Security.SecureString]) {
                $walkParams['PrivPassword'] = $privacyPassword
            }

            $walkResult = Invoke-SNMPBulkWalkFriendly @walkParams -ErrorAction Stop
        }

        Write-Verbose "[SNMP] Bulk walk completed. Variables retrieved: $($walkResult.Variables.Count)"
        Write-Host "    Walk response: $($walkResult.Variables.Count) variables -- processing..." -ForegroundColor DarkGray

        # Normalise into walkData (instance -> colNum -> value)
        $walkData  = [ordered]@{}
        $walkCount = 0

        foreach ($var in $walkResult.Variables) {
            $currentOid = $var.Id.ToString().TrimStart('.')
            if (-not $currentOid.StartsWith("$tableBaseOid.")) { continue }

            $suffix = $currentOid.Substring($tableBaseOid.Length + 1)
            $dotPos = $suffix.IndexOf('.')
            if ($dotPos -lt 0) { continue }

            $colNum   = $suffix.Substring(0, $dotPos)
            $instance = $suffix.Substring($dotPos + 1)

            # Decode binary OctetString columns using shared decoder
            if ($var.Data -is [Lextm.SharpSnmpLib.OctetString]) {
                $decodeType = $script:CUCMColumnDecodeType[$colNum]
                if ($decodeType) {
                    $raw     = $var.Data.GetRaw()
                    $decoded = ConvertFrom-CUCMSnmpOctetString -Bytes $raw -ColumnType $decodeType
                    $value   = if ($null -ne $decoded) { $decoded } else { [string]$var.Data }
                }
                else {
                    $value = [string]$var.Data
                }
            }
            else {
                $value = [string]$var.Data
            }

            if (-not $walkData.Contains($instance)) { $walkData[$instance] = @{} }
            $walkData[$instance][$colNum] = $value

            $walkCount++
            if ($walkCount -le 3 -or $walkCount % 500 -eq 0) {
                Write-Verbose "[SNMP] Walk progress: $walkCount OIDs (col=$colNum instance=$instance)"
            }
        }

        Write-Host "    SharpSnmpLib walk done: $walkCount OIDs, $($walkData.Count) phone instance(s)" -ForegroundColor Green
        Write-Verbose "[SNMP] Walk finished. OIDs processed: $walkCount  Unique instances: $($walkData.Count)"
    }
    catch {
        Write-Warning "SharpSnmpLib walk failed for ${TargetAddress}: $_ -- trying WUG COM API fallback"
        Write-Verbose "[SNMP] SharpSnmpLib error: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        $walkData = $null
        try {
            $walkData   = Invoke-CUCMPhoneWalkComApi -TargetAddress $TargetAddress -Credential $Credential
            $walkMethod = 'WUG COM API'
        }
        catch {
            Write-Warning "COM API fallback also failed for ${TargetAddress}: $_"
            Write-Verbose "[COM] Exception: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            Write-Verbose "[COM] Stack: $($_.ScriptStackTrace)"
        }
    }

    # ---- Phase 2: Assemble phone rows (runs regardless of which walk method succeeded) ----
    if ($null -ne $walkData -and $walkData.Count -gt 0) {
        Write-Host "  Assembling phone rows from $($walkData.Count) instance(s) [$walkMethod]..." -ForegroundColor DarkGray

        $rowCount = 0
        foreach ($instance in $walkData.Keys) {
            $instanceData = $walkData[$instance]
            $attributes   = [ordered]@{
                'DiscoveryHelper.CUCM' = 'true'
                'CUCM.CallManager'     = $DeviceName
                'CUCM.Target'          = $TargetAddress
                'CUCM.PhoneIndex'      = $instance
            }

            foreach ($colNum in $instanceData.Keys) {
                if (-not $columnToName.ContainsKey($colNum)) { continue }
                $attrName = $columnToName[$colNum]
                if ($attrName -eq 'CUCM.PhoneIndex') { continue }
                $value = $instanceData[$colNum]

                switch ($attrName) {
                    'CUCM.PhoneStatus'             { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $statusMap }
                    'CUCM.PhoneType'               { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $phoneTypeMap }
                    'CUCM.PhoneProtocol'           { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $protocolMap }
                    'CUCM.PhoneIPv4Attribute'      { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $addressScopeMap }
                    'CUCM.PhoneIPv6Attribute'      { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $addressScopeMap }
                    'CUCM.PhoneStatusReason'       { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $causeCodeMap }
                    'CUCM.PhoneUnregReason'        { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $causeCodeMap }
                    'CUCM.PhoneRegFailReason'      { $value = ConvertFrom-CUCMEnumValue -Value $value -Map $causeCodeMap }
                    'CUCM.PhoneTimeLastRegistered' { $value = ConvertFrom-CUCMDateValue -Value $value }
                    'CUCM.PhoneTimeLastError'      { $value = ConvertFrom-CUCMDateValue -Value $value }
                    'CUCM.PhoneTimeLastStatusUpdt' { $value = ConvertFrom-CUCMDateValue -Value $value }
                }

                $attributes[$attrName] = $value
            }

            $phoneName        = [string]$attributes['CUCM.PhoneName']
            $phoneDescription = [string]$attributes['CUCM.PhoneDescription']
            if ([string]::IsNullOrWhiteSpace($phoneName)) {
                $phoneName = "Phone-$instance"
                $attributes['CUCM.PhoneName'] = $phoneName
            }

            $displayName = $phoneName
            if (-not [string]::IsNullOrWhiteSpace($phoneDescription)) {
                $displayName = "$phoneName ($phoneDescription)"
            }

            $statusName = [string]$attributes['CUCM.PhoneStatus']
            if ([string]::IsNullOrWhiteSpace($statusName)) {
                $statusName = 'unknown'
                $attributes['CUCM.PhoneStatus'] = $statusName
            }

            [void]$phoneRows.Add([PSCustomObject]@{
                DeviceName  = $DeviceName
                Target      = $TargetAddress
                PhoneIndex  = $instance
                PhoneName   = $phoneName
                Description = $phoneDescription
                DisplayName = $displayName
                Status      = $statusName
                Attributes  = $attributes
            })

            $rowCount++
            if ($rowCount % 50 -eq 0) {
                Write-Host "    $rowCount phones assembled..." -ForegroundColor DarkGray
            }
            if ($rowCount -le 3 -or $rowCount % 100 -eq 0) {
                Write-Verbose "[SNMP] Row $rowCount : $phoneName  Status=$statusName  IP=$($attributes['CUCM.PhoneIpAddress'])"
            }
        }

        $phoneColor = if ($rowCount -gt 0) { 'Green' } else { 'Yellow' }
        Write-Host "  Done: $rowCount phone row(s) assembled" -ForegroundColor $phoneColor
        Write-Verbose "[SNMP] Total phone rows built: $rowCount"
    }
    else {
        Write-Warning "No phone data returned from SNMP walk for ${TargetAddress}"
    }

    return @($phoneRows)
}

function New-CUCMDiscoveryPlanFromPhoneInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DeviceId,

        [Parameter(Mandatory = $true)]
        [string]$DeviceName,

        [Parameter(Mandatory = $true)]
        [string]$TargetAddress,

        [Parameter(Mandatory = $true)]
        [object[]]$PhoneRows
    )

    if (-not $PhoneRows -or $PhoneRows.Count -eq 0) {
        return @()
    }

    $columns = Get-CUCMPhoneColumnMap
    $counts = Get-CUCMPhoneStatusCounts -PhoneRows $PhoneRows
    $attributes = [ordered]@{
        'DiscoveryHelper.CUCM' = 'true'
        'CUCM.Target' = $TargetAddress
        'CUCM.PhoneCount' = [string]$counts.total
        'CUCM.PhoneRegisteredCount' = [string]$counts.registered
        'CUCM.PhoneUnregisteredCount' = [string]$counts.unregistered
        'CUCM.PhoneRejectedCount' = [string]$counts.rejected
        'CUCM.PhonePartiallyRegisteredCount' = [string]$counts.partiallyregistered
        'CUCM.PhoneUnknownCount' = [string]$counts.unknown
        'CUCM.PhoneStatusSummary' = "registered=$($counts.registered); unregistered=$($counts.unregistered); rejected=$($counts.rejected); partiallyregistered=$($counts.partiallyregistered); unknown=$($counts.unknown)"
        'CUCM.InventoryTimestamp' = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $monitorParams = @{
        SnmpTableDiscOID = $columns['CUCM.PhoneIndex']
        SnmpTableDiscOperator = 'gt'
        SnmpTableDiscValue = '0'
        SnmpTableDiscCommentOID = $columns['CUCM.PhoneName']
        SnmpTableDiscIndexOID = $columns['CUCM.PhoneIndex']
        SnmpTableDiscCreates = 'true'
        SnmpTableMonitoredOID = $columns['CUCM.PhoneStatus']
        SnmpTableMonitorOperator = 'constant'
        SnmpTableMonitoredValue = '2'
        SnmpTableMonitorUpIfMatch = 'upifmatch'
    }

    $item = New-DiscoveredItem `
        -Name "CUCM Phone Registration Status [$DeviceName]" `
        -ItemType 'ActiveMonitor' `
        -MonitorType 'SNMPTable' `
        -MonitorParams $monitorParams `
        -UniqueKey "CUCM:$TargetAddress:monitor:registration" `
        -DeviceId $DeviceId `
        -Attributes $attributes `
        -Tags @('cucm', 'snmp', 'phone-registration')

    return @($item)
}

Register-DiscoveryProvider -Name 'CUCM' `
    -MatchAttribute 'DiscoveryHelper.CUCM' `
    -AuthType 'BasicAuth' `
    -DefaultPort 161 `
    -DefaultProtocol 'snmp' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $credential = $ctx.Credential
        if (-not $credential) {
            Write-Warning 'CUCM: No SNMP settings supplied.'
            return @()
        }

        $targetAddress = if ($credential.Address) { [string]$credential.Address } else { [string]$ctx.DeviceIP }
        if ([string]::IsNullOrWhiteSpace($targetAddress)) {
            Write-Warning 'CUCM: No target address supplied.'
            return @()
        }

        $phoneRows = Get-CUCMPhoneInventory -DeviceName $ctx.DeviceName -TargetAddress $targetAddress -Credential $credential
        return (New-CUCMDiscoveryPlanFromPhoneInventory -DeviceId $ctx.DeviceId -DeviceName $ctx.DeviceName -TargetAddress $targetAddress -PhoneRows $phoneRows)
    }

# ---- END OF SCRIPT (do not remove this line or the closing braces abov
# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU/ZPxV05wCpHVpm1eY1N5X6up
# 6KOggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFLoNlXdsaC7C1J7IXoPLuyk43MiMMA0G
# CSqGSIb3DQEBAQUABIICAAtLLUpZ3M3a7MBskT9lWN5g2WaypIBcK7jYfcuqh3xh
# BKjpMEo8jDT6/uGE57N3hrmoREf9J/rh7XNlbelsE40cxGcOHEeSbDIbz+ExnvCT
# NXl26nD5Wb6Z/ZCrNa+WPgAj/N3+30YzYgGNwhVuubybGAklFMWwWF7u2NA2lSKP
# Hw9cU5+zS+rOpJqj/X1iILKc2Sux9X72EUiOAE5KZEE7+CSf7UyEE2Z3IBVCogAL
# DhraDw5eq0Qtx9Z6kHWsh6D8yt2UiSr8XVeoXdF0H3SRajnBwLgnXfMR8xWcoMJi
# 1wvgRr2UJJnUOMa5G1XVlFIYzwwxgyR0q9lNZVWAV1gH0qcyD0bEN5V6wE5zgGml
# qzRp7AjP/k7y0dT8ZnaeMS7G+a/F1+pPuwqiOB4vA9Xdvt50tr3ZHJ7oP2pVlSWl
# lIg91U5OF558UEsNozMmNi8Y0/O6T1M/o3aG07Dlgglw0lptCYZ+HzR5k5BtJONK
# NwJ+DTFykg1wV0AX1nUtT0M36kibzFgKsIPZcVpUP8Pc5zJ8Iwlg1ndAlFAh6KP9
# DGFIpiBiIdyA7MGUXY+QcdRs3qP+kIxZ50owsY+x2dplBQJY5JbhOZLWgkkl/zGv
# j+R2ZQ8ttIwtLmLpfRiQUE1Z5TWM0gWb6bfyB7u63iCLRfL85pwP8YvpLpyeTN13
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDv
# GEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDYyMzEyMjMzNVowLwYJKoZIhvcN
# AQkEMSIEIC3J0590duhSWOd1UKOC4FRNL8Y5rig4hcyW5alv/6MXMA0GCSqGSIb3
# DQEBAQUABIICAFQTM4bFSkpcnyAfhyXr1etd8vUhEycz7HFq/48bBb6II699AHGm
# dRUETXPtlMBIEVFuwH8rukYdBAX66WTBrqoaF2yXK6A/pUvOgxWkdA7Ctf74kfnf
# ZfFOGso+R2AsXfWrISu5CcNhMVWkZ34tX1xJrMFTpt9rry5pFLRe7QTsSDf7+fI8
# JTrRLzj/oD1swq5RI7fADWJrwG4D3dLRd29Yd911ueJM4ElbYreOCl88+VCyCqS8
# SegDOeT0vILDSMR2uttstnDSf+GbNnm5SFspzQr+fCIt8oQ5zdx34JGDjNo373aE
# s+2WQJGoYuzNYqGdcQEsTFSPCwBYegj9J0I3en+THIq0iBMfEw1K8xz1bg1o0dhp
# RjvW9ow8i0lzhO+XLYvcqbb3A8lmSyxb8LffTlquI0Jm/UEoIPxIovcerttXXGDx
# L5/urOTNYuZWSeAshF1Q83V9Qo6hl2Nci6cnz//nrTeUlMBDnoi74rDhhRUYRH7A
# /wH+/iA4GlT6PrcTvxt/Zgst9y1aU25YUSy05WK4pI9Pki0XTAscuSkGTfN9qeoK
# rqzIUubugGd17sV7aINrO9Tt38sa8zGkTYqyWvwgDBxqpWny47uVSlQbjLUf/nxk
# lMYrcL/kQ6D7urbCWXJFTXKUNak/oLU4IV39P57xDh7R/qe7Sv6TUb4R
# SIG # End signature block
