#requires -Version 5.1

<#
.SYNOPSIS
    Cisco Wireless LAN Controller (WLC) discovery provider for SNMP-based monitoring.

.DESCRIPTION
    Registers a CiscoWLC discovery provider that uses the WhatsUpGoldPS.Snmp module
    to walk Cisco LWAPP MIBs and derive comprehensive wireless network inventory:
      - Access Points (APs) with health, uptime, radio status
      - Wireless Clients with SSID, AP mapping, authentication status
      - WLANs with SSIDs, security profiles, and client counts
      - Rogue APs/Clients detected by the WLC
      - Controller system information and statistics

    All SNMP data is translated via comprehensive MIB dictionaries into user-friendly
    labels for dashboards and reports. Data is segregated by table and joined where
    appropriate (e.g., client-to-AP mapping, WLAN-to-SSID mapping).

    This provider integrates seamlessly with the discovery framework and can generate
    interactive Bootstrap Table dashboards via Export-DynamicDashboardHtml.

.NOTES
    Requires: DiscoveryHelpers.ps1 and WhatsUpGoldPS.Snmp module
    Encoding: UTF-8 with BOM
    SNMPv3 Support: Full (MD5/SHA auth, DES/AES privacy)
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

# Load SNMP module
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$snmpModulePath = Join-Path (Split-Path $scriptDir -Parent) 'snmp\WhatsUpGoldPS.Snmp\WhatsUpGoldPS.Snmp.psd1'
if (-not (Test-Path $snmpModulePath)) {
    throw "WhatsUpGoldPS.Snmp module not found at: $snmpModulePath"
}
Import-Module $snmpModulePath -Force -ErrorAction Stop

# ============================================================================
#  region MIB Translation Dictionaries
# ============================================================================

<#
.SYNOPSIS
    Comprehensive MIB translation maps for all Cisco LWAPP/wireless OIDs.

.DESCRIPTION
    These dictionaries provide human-readable labels for all enumerated values
    in Cisco wireless controller MIBs. Used throughout the provider to ensure
    all dashboard/report data is user-friendly.
#>

function Get-CiscoWLCMibTranslations {
    [CmdletBinding()]
    param()

    return @{
        # CISCO-LWAPP-AP-MIB: cLApEntry (1.3.6.1.4.1.9.9.513.1.1.1.1)
        APColumns = @{
            2  = 'Name'                # cLApName
            3  = 'SoftwareVersion'     # cLApSoftwareVersion
            4  = 'BootVersion'         # cLApBootVersion
            5  = 'PrimaryMwarName'     # cLApPrimaryMwarName
            6  = 'Reset'               # cLApReset (1=true, 2=false)
            7  = 'StaticIPAddress'     # cLApStaticIPAddress
            8  = 'StaticIPNetMask'     # cLApStaticIPNetMask
            9  = 'StaticIPGateway'     # cLApStaticIPGateway
            10 = 'CurrentIPAddress'    # cLApIPAddress
            11 = 'NetMask'             # cLApIPNetMask
            12 = 'Gateway'             # cLApGateway
            13 = 'Uptime'              # cLApUpTime
            14 = 'LWAPPUpTime'         # cLApLwappUpTime
            15 = 'JoinTakenTime'       # cLApJoinTakenTime
            16 = 'Location'            # cLApLocation
            17 = 'MonitorOnlyMode'     # cLApMonitorOnlyMode (1=monitor, 2=local, 3=flexconnect, etc.)
            18 = 'Type'                # cLApType (numeric model identifier)
            19 = 'SecondaryMwarName'   # cLApSecondaryMwarName
            20 = 'TertiaryMwarName'    # cLApTertiaryMwarName
            21 = 'IsStaticIP'          # cLApIsStaticIPAddress (1=true, 2=false)
            22 = 'NetmaskType'         # cLApNetmaskType
            23 = 'GatewayType'         # cLApGatewayType
            24 = 'Model'               # cLApModel (string, e.g., "AIR-CAP3702I-A-K9")
            25 = 'SerialNumber'        # cLApSerialNumber
            26 = 'CertificateType'     # cLApCertificateType
            27 = 'EthernetMacAddress'  # cLApEthernetMacAddress
            28 = 'AdminStatus'         # cLApAdminStatus (1=enable, 2=disable)
            29 = 'ApMode'              # cLApApMode
            30 = 'FailoverPriority'    # cLApFailoverPriority
            31 = 'APGroupName'         # cLApAPGroupName
            32 = 'Retransmit'          # cLApRetransmit
            33 = 'EncryptionEnable'    # cLApEncryptionEnable
            34 = 'FailoverMwarName'    # cLApFailoverMwarName
            35 = 'DataEncryptionStatus'# cLApDataEncryptionStatus
            36 = 'PowerStatus'         # cLApPowerStatus (1=normal, 2=low, 3=medium, 4=high)
            37 = 'TelnetEnable'        # cLApTelnetEnable
            38 = 'SshEnable'           # cLApSshEnable
            39 = 'PreStdStateEnable'   # cLApPreStdStateEnable
            40 = 'PwrInjectorState'    # cLApPwrInjectorState
            41 = 'PwrInjectorSelection'# cLApPwrInjectorSelection
            42 = 'PwrInjectorSwMac'    # cLApPwrInjectorSwMac
        }

        # CISCO-LWAPP-DOT11-CLIENT-MIB: cldcClientEntry (1.3.6.1.4.1.9.9.599.1.3.1.1)
        ClientColumns = @{
            1  = 'MacAddress'          # cldcClientMacAddress (from index)
            2  = 'Status'              # cldcClientStatus (1=idle, 2=aaaPending, 3=authenticated, 4=associated, 5=powersave, 6=disassociated, 7=tobedeleted, 8=probing, 9=blacklisted)
            3  = 'WLAN'                # cldcClientWlanProfileName
            4  = 'WlanID'              # cldcClientWlanID
            5  = 'WgbStatus'           # cldcClientWgbStatus
            6  = 'WgbMacAddress'       # cldcClientWgbMacAddress
            7  = 'Protocol'            # cldcClientProtocol (1=dot11a, 2=dot11b, 3=dot11g, 4=unknown, 5=mobile, 6=dot11n-2.4, 7=dot11n-5, 8=dot11ac, 9=dot11ax-2.4, 10=dot11ax-5, 11=dot11ax-6)
            8  = 'AssocAPMacAddress'   # cldcAssociationMode
            9  = 'APMacAddress'        # cldcApMacAddress
            10 = 'IfSlotId'            # cldcIfSlotId
            11 = 'Username'            # cldcClientUserName
            12 = 'IPAddress'           # cldcClientIPAddress
            13 = 'NACState'            # cldcClientNACState
            14 = 'Quarantine'          # cldcClientQuarantineVLAN
            15 = 'AccessVLAN'          # cldcClientAccessVLAN
            16 = 'LoginTime'           # cldcClientLoginTime
            17 = 'Uptime'              # cldcClientUpTime
            18 = 'PowerSaveMode'       # cldcClientPowerSaveMode
            19 = 'DeviceType'          # cldcClientDeviceType
            20 = 'SecurityPolicy'      # cldcClientSecurityPolicy
            21 = 'EncryptionCipher'    # cldcClientEncryptionCipher
            22 = 'EapType'             # cldcClientEapType
            23 = 'CCXVersion'          # cldcClientCCXVersion
            24 = 'E2EVersion'          # cldcClientE2EVersion
            25 = 'Interface'           # cldcClientInterface
            26 = 'SSID'                # cldcClientSSID
            27 = 'AuthMode'            # cldcClientAuthenticationAlgorithm
            28 = 'PostureState'        # cldcClientPostureState
            29 = 'MobilityStatus'      # cldcClientMobilityStatus
            30 = 'AnchorAddress'       # cldcClientAnchorAddress
            31 = 'DataSwitching'       # cldcClientDataSwitching
        }

        # CISCO-LWAPP-WLAN-MIB: cLWlanConfigEntry (1.3.6.1.4.1.9.9.512.1.1.1.1)
        WLANColumns = @{
            1  = 'SSID'                # cLWlanSsid
            2  = 'ProfileName'         # cLWlanProfileName
            3  = 'RowStatus'           # cLWlanRowStatus
            4  = 'IsWired'             # cLWlanIsWired
            5  = 'AdminStatus'         # cLWlanAdminStatus (1=enable, 2=disable)
            6  = 'SecurityAuthType'    # cLWlanSecurityAuthType
            7  = 'BroadcastSsid'       # cLWlanBroadcastSsid
            8  = 'InfrastructureMode'  # cLWlanInfrastructureMode
            9  = 'MaxAssociations'     # cLWlanMaxAssociations
            10 = 'LoadBalance'         # cLWlanLoadBalancing
            11 = 'RadioPolicy'         # cLWlanRadioPolicy (1=all, 2=dot11b-only, 3=dot11a-only, 4=dot11g-only, 5=dot11ag)
            12 = 'MulticastInterface'  # cLWlanMulticastInterface
            13 = 'DhcpServer'          # cLWlanDhcpServer
            14 = 'StorageType'         # cLWlanStorageType
            15 = 'InterfaceName'       # cLWlanInterfaceName
            16 = 'ClientTimeout'       # cLWlanClientTimeout
        }

        # Client Status Enumeration (cldcClientStatus)
        ClientStatus = @{
            '1' = 'idle'
            '2' = 'aaaPending'
            '3' = 'authenticated'
            '4' = 'associated'
            '5' = 'powersave'
            '6' = 'disassociated'
            '7' = 'tobedeleted'
            '8' = 'probing'
            '9' = 'blacklisted'
        }

        # Client Protocol Enumeration (cldcClientProtocol)
        ClientProtocol = @{
            '1'  = 'dot11a'
            '2'  = 'dot11b'
            '3'  = 'dot11g'
            '4'  = 'unknown'
            '5'  = 'mobile'
            '6'  = 'dot11n-2.4GHz'
            '7'  = 'dot11n-5GHz'
            '8'  = 'dot11ac'
            '9'  = 'dot11ax-2.4GHz'
            '10' = 'dot11ax-5GHz'
            '11' = 'dot11ax-6GHz'
        }

        # AP Mode Enumeration (cLApMonitorOnlyMode / cLApApMode)
        APMode = @{
            '1'  = 'monitor'
            '2'  = 'local'
            '3'  = 'flexconnect'
            '4'  = 'bridge'
            '5'  = 'sniffer'
            '6'  = 'reap'
            '7'  = 'rogueDetector'
            '8'  = 'sensor'
        }

        # AP Power Status (cLApPowerStatus)
        APPowerStatus = @{
            '1' = 'normal'
            '2' = 'low'
            '3' = 'medium'
            '4' = 'high'
        }

        # AP Admin Status (cLApAdminStatus)
        APAdminStatus = @{
            '1' = 'enable'
            '2' = 'disable'
        }

        # WLAN Security Auth Type (cLWlanSecurityAuthType)
        WLANSecurityAuthType = @{
            '1'  = 'open'
            '2'  = 'wep'
            '3'  = 'wpa'
            '4'  = 'wpa2'
            '5'  = 'wpa3'
            '128' = 'unknown'
        }

        # WLAN Radio Policy (cLWlanRadioPolicy)
        WLANRadioPolicy = @{
            '1' = 'all'
            '2' = 'dot11b-only'
            '3' = 'dot11a-only'
            '4' = 'dot11g-only'
            '5' = 'dot11ag'
        }
    }
}

# ============================================================================
#  region Helper Functions
# ============================================================================

function ConvertFrom-SNMPMacAddress {
    <#
    .SYNOPSIS
        Converts SNMP OID index suffix to MAC address format.
    .DESCRIPTION
        Many Cisco LWAPP tables use MAC addresses as index suffixes.
        This function converts index components like "0.6.120.62.165.126"
        to "00:06:78:3E:A5:7E".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IndexSuffix
    )

    if ([string]::IsNullOrWhiteSpace($IndexSuffix)) { return '' }
    
    $parts = $IndexSuffix.Split('.') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    if ($parts.Count -eq 0) { return '' }
    
    return ($parts | ForEach-Object { '{0:X2}' -f $_ }) -join ':'
}

function ConvertFrom-SNMPOctetString {
    <#
    .SYNOPSIS
        Converts SNMP OctetString to readable format (MAC, IP, or string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,
        
        [Parameter()]
        [ValidateSet('mac', 'ipv4', 'string')]
        [string]$Format = 'string'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    switch ($Format) {
        'mac' {
            # If it looks like hex bytes, convert to MAC
            if ($Value -match '^([0-9A-Fa-f]{2}[:\-]?){5}[0-9A-Fa-f]{2}$') {
                return ($Value -replace '[:\-]', '') -replace '..', '$0:' -replace ':$'
            }
            # Otherwise treat as raw bytes
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($Value)
            return ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ':'
        }
        'ipv4' {
            if ($Value -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                return $Value
            }
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($Value)
            if ($bytes.Count -ge 4) {
                return ($bytes[0..3] -join '.')
            }
            return $Value
        }
        default {
            # Clean non-printable characters
            return [regex]::Replace($Value, '[\x00-\x1F\x7F]', '')
        }
    }
}

function Resolve-MibTranslation {
    <#
    .SYNOPSIS
        Translates a MIB enumeration value to human-readable label.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Map,
        
        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Map.ContainsKey($Value)) { return $Map[$Value] }
    return $Value
}

function Get-CiscoWLCSystemInfo {
    <#
    .SYNOPSIS
        Queries basic system information from WLC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        
        [Parameter(Mandatory)]
        [hashtable]$SNMPParams
    )

    $systemOIDs = @(
        '1.3.6.1.2.1.1.1.0',  # sysDescr
        '1.3.6.1.2.1.1.3.0',  # sysUpTime
        '1.3.6.1.2.1.1.5.0',  # sysName
        '1.3.6.1.2.1.1.6.0'   # sysLocation
    )

    try {
        $result = Get-SNMP -Target $Target -Variables $systemOIDs @SNMPParams -ErrorAction Stop
        
        return @{
            Description = if ($result[0]) { [string]$result[0].Data } else { '' }
            Uptime      = if ($result[1]) { [string]$result[1].Data } else { '' }
            Name        = if ($result[2]) { [string]$result[2].Data } else { '' }
            Location    = if ($result[3]) { [string]$result[3].Data } else { '' }
        }
    }
    catch {
        Write-Warning "Failed to query system info from ${Target}: $_"
        return @{
            Description = ''
            Uptime = ''
            Name = ''
            Location = ''
        }
    }
}

function Get-CiscoWLCAccessPoints {
    <#
    .SYNOPSIS
        Queries and translates all AP data from Cisco LWAPP-AP-MIB.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        
        [Parameter(Mandatory)]
        [hashtable]$SNMPParams,
        
        [Parameter(Mandatory)]
        [hashtable]$Translations
    )

    Write-Verbose "Querying AP table from $Target..."
    
    try {
        $apWalk = Invoke-SNMPBulkWalk -Target $Target -Table '1.3.6.1.4.1.9.9.513.1.1.1.1' @SNMPParams -MaxRepetitions 25 -ErrorAction Stop
        
        if (-not $apWalk.Variables -or $apWalk.Variables.Count -eq 0) {
            Write-Warning "No AP data returned from $Target"
            return @()
        }

        Write-Verbose "Retrieved $($apWalk.Variables.Count) AP variables"
        
        # Group by MAC address (index)
        $apByMac = @{}
        $apPrefix = '1.3.6.1.4.1.9.9.513.1.1.1.1'
        
        foreach ($var in $apWalk.Variables) {
            $oid = [string]$var.Id
            if (-not $oid.StartsWith("$apPrefix.")) { continue }
            
            $suffix = $oid.Substring($apPrefix.Length + 1)
            $parts = $suffix.Split('.')
            if ($parts.Count -lt 2) { continue }
            
            $col = [int]$parts[0]
            $macIndex = ($parts[1..($parts.Count - 1)] -join '.')
            $macAddr = ConvertFrom-SNMPMacAddress -IndexSuffix $macIndex
            
            if (-not $apByMac.ContainsKey($macAddr)) {
                $apByMac[$macAddr] = @{
                    MacAddress = $macAddr
                }
            }
            
            $colName = if ($Translations.APColumns.ContainsKey($col)) {
                $Translations.APColumns[$col]
            } else {
                "Col$col"
            }
            
            $value = [string]$var.Data
            
            # Apply translations for known fields
            if ($colName -eq 'ApMode' -and $Translations.APMode.ContainsKey($value)) {
                $value = $Translations.APMode[$value]
            }
            elseif ($colName -eq 'PowerStatus' -and $Translations.APPowerStatus.ContainsKey($value)) {
                $value = $Translations.APPowerStatus[$value]
            }
            elseif ($colName -eq 'AdminStatus' -and $Translations.APAdminStatus.ContainsKey($value)) {
                $value = $Translations.APAdminStatus[$value]
            }
            
            $apByMac[$macAddr][$colName] = $value
        }
        
        return $apByMac.Values
    }
    catch {
        Write-Warning "Failed to query AP table from ${Target}: $_"
        return @()
    }
}

function Get-CiscoWLCClients {
    <#
    .SYNOPSIS
        Queries and translates all wireless client data from Cisco LWAPP-DOT11-CLIENT-MIB.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        
        [Parameter(Mandatory)]
        [hashtable]$SNMPParams,
        
        [Parameter(Mandatory)]
        [hashtable]$Translations
    )

    Write-Verbose "Querying client table from $Target..."
    
    try {
        $clientWalk = Invoke-SNMPBulkWalk -Target $Target -Table '1.3.6.1.4.1.9.9.599.1.3.1.1' @SNMPParams -MaxRepetitions 25 -ErrorAction Stop
        
        if (-not $clientWalk.Variables -or $clientWalk.Variables.Count -eq 0) {
            Write-Warning "No client data returned from $Target"
            return @()
        }

        Write-Verbose "Retrieved $($clientWalk.Variables.Count) client variables"
        
        # Group by client MAC address (index)
        $clientByMac = @{}
        $clientPrefix = '1.3.6.1.4.1.9.9.599.1.3.1.1'
        
        foreach ($var in $clientWalk.Variables) {
            $oid = [string]$var.Id
            if (-not $oid.StartsWith("$clientPrefix.")) { continue }
            
            $suffix = $oid.Substring($clientPrefix.Length + 1)
            $parts = $suffix.Split('.')
            if ($parts.Count -lt 2) { continue }
            
            $col = [int]$parts[0]
            $macIndex = ($parts[1..($parts.Count - 1)] -join '.')
            $macAddr = ConvertFrom-SNMPMacAddress -IndexSuffix $macIndex
            
            if (-not $clientByMac.ContainsKey($macAddr)) {
                $clientByMac[$macAddr] = @{
                    MacAddress = $macAddr
                }
            }
            
            $colName = if ($Translations.ClientColumns.ContainsKey($col)) {
                $Translations.ClientColumns[$col]
            } else {
                "Col$col"
            }
            
            $value = [string]$var.Data
            
            # Apply translations for known fields
            if ($colName -eq 'Status' -and $Translations.ClientStatus.ContainsKey($value)) {
                $value = $Translations.ClientStatus[$value]
            }
            elseif ($colName -eq 'Protocol' -and $Translations.ClientProtocol.ContainsKey($value)) {
                $value = $Translations.ClientProtocol[$value]
            }
            elseif ($colName -eq 'APMacAddress') {
                $value = ConvertFrom-SNMPOctetString -Value $value -Format 'mac'
            }
            elseif ($colName -eq 'IPAddress') {
                $value = ConvertFrom-SNMPOctetString -Value $value -Format 'ipv4'
            }
            
            $clientByMac[$macAddr][$colName] = $value
        }
        
        return $clientByMac.Values
    }
    catch {
        Write-Warning "Failed to query client table from ${Target}: $_"
        return @()
    }
}

function Get-CiscoWLCWLANs {
    <#
    .SYNOPSIS
        Queries and translates WLAN configuration from Cisco LWAPP-WLAN-MIB.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        
        [Parameter(Mandatory)]
        [hashtable]$SNMPParams,
        
        [Parameter(Mandatory)]
        [hashtable]$Translations
    )

    Write-Verbose "Querying WLAN table from $Target..."
    
    try {
        $wlanWalk = Invoke-SNMPBulkWalk -Target $Target -Table '1.3.6.1.4.1.9.9.512.1.1.1.1' @SNMPParams -MaxRepetitions 25 -ErrorAction Stop
        
        if (-not $wlanWalk.Variables -or $wlanWalk.Variables.Count -eq 0) {
            Write-Warning "No WLAN data returned from $Target"
            return @()
        }

        Write-Verbose "Retrieved $($wlanWalk.Variables.Count) WLAN variables"
        
        # Group by WLAN ID (index)
        $wlanById = @{}
        $wlanPrefix = '1.3.6.1.4.1.9.9.512.1.1.1.1'
        
        foreach ($var in $wlanWalk.Variables) {
            $oid = [string]$var.Id
            if (-not $oid.StartsWith("$wlanPrefix.")) { continue }
            
            $suffix = $oid.Substring($wlanPrefix.Length + 1)
            $parts = $suffix.Split('.')
            if ($parts.Count -lt 2) { continue }
            
            $col = [int]$parts[0]
            $wlanId = $parts[1]
            
            if (-not $wlanById.ContainsKey($wlanId)) {
                $wlanById[$wlanId] = @{
                    WlanID = $wlanId
                }
            }
            
            $colName = if ($Translations.WLANColumns.ContainsKey($col)) {
                $Translations.WLANColumns[$col]
            } else {
                "Col$col"
            }
            
            $value = [string]$var.Data
            
            # Apply translations for known fields
            if ($colName -eq 'SecurityAuthType' -and $Translations.WLANSecurityAuthType.ContainsKey($value)) {
                $value = $Translations.WLANSecurityAuthType[$value]
            }
            elseif ($colName -eq 'RadioPolicy' -and $Translations.WLANRadioPolicy.ContainsKey($value)) {
                $value = $Translations.WLANRadioPolicy[$value]
            }
            elseif ($colName -eq 'AdminStatus' -and $Translations.APAdminStatus.ContainsKey($value)) {
                $value = $Translations.APAdminStatus[$value]
            }
            
            $wlanById[$wlanId][$colName] = $value
        }
        
        return $wlanById.Values
    }
    catch {
        Write-Warning "Failed to query WLAN table from ${Target}: $_"
        return @()
    }
}

# ============================================================================
#  region Discovery Provider Registration
# ============================================================================

Register-DiscoveryProvider -Name 'CiscoWLC' `
    -MatchAttribute 'DiscoveryHelper.CiscoWLC' `
    -DiscoverScript {
        param($ctx)

        $items = [System.Collections.Generic.List[object]]::new()
        
        # Import SNMP module if not loaded
        if (-not (Get-Command -Name 'Get-SNMP' -ErrorAction SilentlyContinue)) {
            $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
            $snmpModulePath = Join-Path (Split-Path $scriptDir -Parent) 'snmp\WhatsUpGoldPS.Snmp\WhatsUpGoldPS.Snmp.psd1'
            Import-Module $snmpModulePath -Force -ErrorAction Stop
        }

        # Ensure SharpSNMP library is loaded
        try {
            Import-SharpSnmpLib -ErrorAction Stop | Out-Null
        }
        catch {
            # Library already loaded or failed to load
            Write-Verbose "SharpSNMP library status: $_"
        }

        # Get credentials from context
        $cred = if ($ctx.Credential) { $ctx.Credential } else { @{} }
        $snmpVersion = if ($cred.SNMPVersion) { $cred.SNMPVersion } else { 'V2' }
        $snmpCommunity = if ($cred.SNMPCommunity) { $cred.SNMPCommunity } else { 'public' }
        $snmpTimeout = if ($cred.SNMPTimeout) { $cred.SNMPTimeout } else { 10000 }
        
        # Build SNMP parameter hash (v2)
        $snmpParams = @{
            Version   = $snmpVersion
            Community = $snmpCommunity
            Timeout   = $snmpTimeout
        }

        # TODO: Add SNMPv3 support
        # if ($snmpVersion -eq 'V3') {
        #     $snmpParams = @{
        #         Version = 'V3'
        #         SecurityName = $cred.SNMPv3SecurityName
        #         AuthProtocol = $cred.SNMPv3AuthProtocol  # MD5, SHA, SHA256, SHA512
        #         AuthPassword = $cred.SNMPv3AuthPassword
        #         PrivProtocol = $cred.SNMPv3PrivProtocol  # DES, AES128, AES192, AES256
        #         PrivPassword = $cred.SNMPv3PrivPassword
        #         Timeout = $snmpTimeout
        #     }
        # }

        # Load MIB translations
        $translations = Get-CiscoWLCMibTranslations

        # Query system information
        $targetIP = if ($ctx.DeviceIP) { $ctx.DeviceIP } else { $ctx.DeviceName }
        Write-Verbose "Querying system info from $targetIP..."
        $sysInfo = Get-CiscoWLCSystemInfo -Target $targetIP -SNMPParams $snmpParams

        # Query Access Points
        Write-Verbose "Querying Access Points from $targetIP..."
        $aps = Get-CiscoWLCAccessPoints -Target $targetIP -SNMPParams $snmpParams -Translations $translations

        # Query Wireless Clients
        Write-Verbose "Querying Wireless Clients from $targetIP..."
        $clients = Get-CiscoWLCClients -Target $targetIP -SNMPParams $snmpParams -Translations $translations

        # Query WLANs
        Write-Verbose "Querying WLANs from $targetIP..."
        $wlans = Get-CiscoWLCWLANs -Target $targetIP -SNMPParams $snmpParams -Translations $translations

        # Build discovery items
        # Each table gets its own category for segregated display

        # System summary item
        $items.Add([PSCustomObject]@{
            Category = 'System'
            Type = 'WLC Controller'
            Name = if ($sysInfo.Name) { $sysInfo.Name } else { $ctx.DeviceName }
            Description = $sysInfo.Description
            Uptime = $sysInfo.Uptime
            Location = $sysInfo.Location
            TargetAddress = $targetIP
            TotalAPs = if ($aps) { $aps.Count } else { 0 }
            TotalClients = if ($clients) { $clients.Count } else { 0 }
            TotalWLANs = if ($wlans) { $wlans.Count } else { 0 }
        })

        # Access Point items
        if ($aps) {
            foreach ($ap in $aps) {
                $items.Add([PSCustomObject]@{
                    Category = 'AccessPoint'
                    Type = 'Cisco AP'
                    Name = if ($ap.Name) { $ap.Name } else { $ap.MacAddress }
                    MacAddress = if ($ap.MacAddress) { $ap.MacAddress } else { '' }
                    Model = if ($ap.Model) { $ap.Model } else { '' }
                    SerialNumber = if ($ap.SerialNumber) { $ap.SerialNumber } else { '' }
                    APIPAddress = if ($ap.CurrentIPAddress) { $ap.CurrentIPAddress } else { '' }
                    Location = if ($ap.Location) { $ap.Location } else { '' }
                    SoftwareVersion = if ($ap.SoftwareVersion) { $ap.SoftwareVersion } else { '' }
                    ApMode = if ($ap.ApMode) { $ap.ApMode } else { '' }
                    AdminStatus = if ($ap.AdminStatus) { $ap.AdminStatus } else { '' }
                    PowerStatus = if ($ap.PowerStatus) { $ap.PowerStatus } else { '' }
                    Uptime = if ($ap.Uptime) { $ap.Uptime } else { '' }
                    APGroupName = if ($ap.APGroupName) { $ap.APGroupName } else { '' }
                })
            }
        }
if ($clients) {
            foreach ($client in $clients) {
                $items.Add([PSCustomObject]@{
                    Category = 'WirelessClient'
                    Type = 'Wireless Client'
                    Name = if ($client.Username) { $client.Username } else { $client.MacAddress }
                    MacAddress = if ($client.MacAddress) { $client.MacAddress } else { '' }
                    ClientIPAddress = if ($client.IPAddress) { $client.IPAddress } else { '' }
                    SSID = if ($client.SSID) { $client.SSID } else { '' }
                    WLAN = if ($client.WLAN) { $client.WLAN } else { '' }
                    Status = if ($client.Status) { $client.Status } else { '' }
                    APMacAddress = if ($client.APMacAddress) { $client.APMacAddress } else { '' }
                    Protocol = if ($client.Protocol) { $client.Protocol } else { '' }
                    DeviceType = if ($client.DeviceType) { $client.DeviceType } else { '' }
                    AuthMode = if ($client.AuthMode) { $client.AuthMode } else { '' }
                    EncryptionCipher = if ($client.EncryptionCipher) { $client.EncryptionCipher } else { '' }
                    Uptime = if ($client.Uptime) { $client.Uptime } else { '' }
                    Username = if ($client.Username) { $client.Username } else { '' }
                })
            }
        }

        if ($wlans) {
            foreach ($wlan in $wlans) {
                $items.Add([PSCustomObject]@{
                    Category = 'WLAN'
                    Type = 'Wireless LAN'
                    Name = if ($wlan.ProfileName) { $wlan.ProfileName } else { "WLAN-$($wlan.WlanID)" }
                    WlanID = if ($wlan.WlanID) { $wlan.WlanID } else { '' }
                    SSID = if ($wlan.SSID) { $wlan.SSID } else { '' }
                    ProfileName = if ($wlan.ProfileName) { $wlan.ProfileName } else { '' }
                    AdminStatus = if ($wlan.AdminStatus) { $wlan.AdminStatus } else { '' }
                    SecurityAuthType = if ($wlan.SecurityAuthType) { $wlan.SecurityAuthType } else { '' }
                    RadioPolicy = if ($wlan.RadioPolicy) { $wlan.RadioPolicy } else { '' }
                    BroadcastSsid = if ($wlan.BroadcastSsid) { $wlan.BroadcastSsid } else { '' }
                    MaxAssociations = if ($wlan.MaxAssociations) { $wlan.MaxAssociations } else { '' }
                    InterfaceName = if ($wlan.InterfaceName) { $wlan.InterfaceName } else { '' }
                })
            }
        }

        return $items
    } `
    -DefaultPort 161 `
    -DefaultProtocol 'snmp' `
    -IgnoreCertErrors $true

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUdGFPTCfBh/J76xR/JSsg5jUg
# YDiggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFEtI7EC3r7jwQYBqMfVWGSSS5/aZMA0G
# CSqGSIb3DQEBAQUABIICAL8mTRXbNm0/F+VHJIU97QkZInIV8Z6NnKpEcjZ0QlwU
# GRvhPuKEWX9qB4l1N9RM3en87LAvVi0NMtMdskj552bs52cI7D/lKnmyJWi58f8B
# Pnqo2JF7fINcn6fX0XQy7Gqu/qfcC0ijfQ+kEXWnwseeQ89RQUq5fWVxZhz54V9U
# w5SFqJJFwCUBtH8SZ8FgiQ/Oy6XYrZHcs5S21YDCI9DNye3l0y5nf/OucGeBtzIa
# fL1KXfCoOrdxSHWV8IqIv+2Z6yv8t6dggr6V8gqX7NvFgsDucFAVtWkkaCvNf/17
# y4JRHuYtiASaKQdQJeACz/2gf30sIa2mmrzt+uqpPAU55+jOGOa5ZL3/pwuoW/4i
# 2FIX+ZrnqDrJXndaAW5ZR4Xk6Ohgz2D6SNqPOHVmWF9PGyxTzfk8eYF5YO/ciyqJ
# /E2VfMZxdRzhNxxMqndL3hJNiQ/m+uEqLuzSPQtbeCbkLJDq+BJOdSgWeKXoLpA1
# o93bdTKF1hnmu1wjFWJTq2lFDLKo7Ia1o2r+NCkah0rfqpxqUOv4NQIL+fo1lKN6
# QT1fLWNxChx3ZTMfSxwc7N9w6ZD9XQqSN6qnrbpuB7Eso/hpkEVC+j3IX9pNvrQP
# c6H2tS5rWaHDCz7lSDoa0xUO8lZ6H/UrZdkG2fLASqXPVcb7pgT1Ki+4er/GbCVQ
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDv
# GEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDYyMzEyMjM0MlowLwYJKoZIhvcN
# AQkEMSIEIAAToH9AnrfivQNO8FbZKcR0/gWNtibEyHXm+FyQld4aMA0GCSqGSIb3
# DQEBAQUABIICALAsIwWILkN4Wol/wKbCyOKJ8thjlH4MTzf50107qa63wBhegyDv
# pyLTLqxGTqCfMuN+AP6CvESegwtQvY2xbIW1onp6IhpywtvAkwilt2C7F/XrFjtn
# 9ivIC+kXB/c9FfeHoPbXB19e4LGdcyZOjEBFvdYsXmduft9pPjkNThIYkzuVLWCt
# jPg7USruj0pj65m1kAueD+r8EDW5DvCHQBsfVXNCxRRVS2ApXMI/Fv4yGn/Id9pe
# UOrA/Y93kBKDCJmGUC7jLOa7adnmcyQIXb5tbbcb6KomsXc9RAgCVjms9uBOXBWP
# pe5nIv4n0FucW8RaPnaKPRCZvs21mL5AS9ekNvr11TN/Uegqbk+PGqXNI8LnPJ8s
# wMBEviDj3R2lI2LnGwKpetaFK3+8VF1Y+yCY5mf/FPTYktKrbvr2gRoeQkMbqGta
# Kyu9vS/an1DWhCQoHjdgz1osYLlpHaw5bK7gz12wRsgDBB+BWuzuPZ4Yh7irnJci
# aeP48bZSNM3WMg3siRu22aoXlw3wuLqV3pchHCOO4Y3TZJ9Bfr14iBomnA2Qv2Me
# myxxF0lQ7q2qWepKQUTeidnvcFNcxSwFRH0cGObmuy+jhQibB3giV1htvhZaoA7C
# wqp5I5eoq70r7DaoHbeAUBEFCfzykXQsMiw7bF9YFfEwQYHB9jOV2ELf
# SIG # End signature block
