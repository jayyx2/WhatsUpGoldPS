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
        # end-of-MIB-view produces an empty-bytes error from SharpSnmpLib — this is normal
        # SNMP termination behavior, not a real failure. If we already have data, use it.
        $isEndOfMib = ($_.Exception.Message -like '*empty array*' -or
                       $_.Exception.Message -like '*endOfMibView*' -or
                       $_.Exception.Message -like '*NoSuchObject*')

        if ($isEndOfMib -and $null -ne $walkData -and $walkData.Count -gt 0) {
            Write-Verbose "[SNMP] End-of-MIB signal received after collecting $($walkData.Count) instance(s) -- treating as success."
        }
        else {
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+Dhg3eR69DnKY
# remEnq1txNtsIoOemstOtOJkfUg5saCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCPGHT+DVefFAL8SznE1Q1BpauokrGGZvBSL3pcj+pbyDANBgkqhkiG9w0BAQEF
# AASCAgBk41d507JSrFjU4uqTbOOcFJEGycXUj75SAFbWdMdDAGhFTCK1H10qLAzD
# QUqDZUyFrkjinIBkdNtxY5bGiKtJXYP2oC0avEG7gwwE4/TSN8hfa4mcpQaw+S0z
# mlvZ0Kyg/X57O4mwX8Q2vxBI/BWSMMSE+fpbO+VmkS9FSFYV2JrJGPRmwe9/hFYN
# 3Ka49MfaQkjqHRMtRx88/KAJ5rFtxkKdMnP878JjEg/XXS90Ipz1uXxNjkMtfKpq
# 4ibhpkX1o4HNSlqN2ebIqaOxvrgDpVRO05Wx4K/Oa279z8mVuoJPMpOTkDDCDIvf
# ichPbAVoIG2JqYxuY5wTPOWb+SLuDYpe3/PtpFTsUNSj8YmKC5xhyB0LNDS6xs4e
# 4fm6nvWvN9h0qvnD0bE/wxKhm2jvE/juLH9RoPz5Y6BbPSdUflpT2TkVglMaLXmG
# YIBOnLHa1mk55QHf9iVipELAv1/RvES5YiOxrXTy9bJAxYp7qfvypMY1rG6WFTN8
# NW0lK3xwpW95oyenfbg6eeIjfIX0lxmWukBVueO/R0o2cm4Eso9xsnVJiicsMIoD
# zeTwNhsQfkpdOkdI9tzC2xR9b3XziohfXAowb3WqOk8gzL0yFBpFTYFy16rU7GU1
# 2/cuGCV6p2jK25lO8+m05aq7O3VyTat2MSls4VMVJFLcEDpqUKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MDcxMTU2NDVaMC8GCSqGSIb3DQEJBDEiBCCyW23N
# P9KU9LmixbVhu19htNsh9YEg/CV3qiSFyIKIlDANBgkqhkiG9w0BAQEFAASCAgBO
# 0Tz90yGADjFwOsQw/q0NH8lo9u6jp4c5m4A3AMunFfP8JOd9IyF/W8Y4dYXvXxja
# 9EauzjWAOUxYaLcw2CFPAqKRDyU8jnON3YWyZIFr/c/TM/J+0luoegOBr/ZvO56T
# YKTgz8hYrGpX4gb7+llLjaK3HhnDGTnyHLr/EYZbjiB++QdqPiOJ970bsQpQ/kIU
# Z+UR4p9C9EcvXF5kO95/nB639Jry5G65BvTfOLs/s4B3c9tyV30h3ltwPg9UvYjg
# 778LJ2s0RKzISzKMHgm+m0r/q++aM0W690LzsvLCTJ3G0YKdBBAw+LZGOslZqOV3
# AAuL56GMH+UxUf9S7ekfq+bQGkyf2exdUVoCRli5Gupi3EgklJyiIu7Ufrp017tN
# HVveAXZTlotnc0ISTdpDRyfQyiBVctRSZRRpTR0cWr9m/9XWZil5ttlUKGfkmzJc
# GhTa0+NE+rZ9B1RjxCvzJHlVKm8DGErGcqeg7Lerm3MXMdMItCoMPLRTPEJ5aLtX
# apnv2gZ+crwPx5pWTuBlGAAriRmrvGppv4vHQmhHXFDUqO/ZcMFP3wpBKJS+a4dE
# nDWNoz8mMCh+WOv55stQOqrIyjcVb4kiKwRzPgKg3VpqN50ZKKfvfQIQMtC3H9mE
# 6S9s28VoXgOvLro0BxGbipF0eqzyKgxGm8VO4kYaTQ==
# SIG # End signature block
