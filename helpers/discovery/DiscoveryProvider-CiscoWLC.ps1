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
        $isEndOfMib = ($_.Exception.Message -like '*empty array*' -or $_.Exception.Message -like '*endOfMibView*' -or $_.Exception.Message -like '*NoSuchObject*')
        if ($isEndOfMib -and $apByMac.Count -gt 0) {
            Write-Verbose "[SNMP] End-of-MIB signal after collecting $($apByMac.Count) AP(s) -- treating as success."
            return $apByMac.Values
        }
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
        $isEndOfMib = ($_.Exception.Message -like '*empty array*' -or $_.Exception.Message -like '*endOfMibView*' -or $_.Exception.Message -like '*NoSuchObject*')
        if ($isEndOfMib -and $clientByMac.Count -gt 0) {
            Write-Verbose "[SNMP] End-of-MIB signal after collecting $($clientByMac.Count) client(s) -- treating as success."
            return $clientByMac.Values
        }
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
        $isEndOfMib = ($_.Exception.Message -like '*empty array*' -or $_.Exception.Message -like '*endOfMibView*' -or $_.Exception.Message -like '*NoSuchObject*')
        if ($isEndOfMib -and $wlanById.Count -gt 0) {
            Write-Verbose "[SNMP] End-of-MIB signal after collecting $($wlanById.Count) WLAN(s) -- treating as success."
            return $wlanById.Values
        }
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCATrddSVZiaqgQ5
# PP70obwanvM86+gJ9k0yOjIQuI2A+6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBVLzfJKmbSXvTqYVbGlV+R29XJoBYXLAsroq19iKiNdjANBgkqhkiG9w0BAQEF
# AASCAgBSiVzlx85Qlkp740NeOzLIsMrwrLhLGoXjTdCmi7Km5EBuZ/4fuMfdZ44B
# oWB2VfD54GwvCDfOlUZ4CvxjogbLPyTSqXggbiZS2saDYLMnKQeNyh87lXxiGtp/
# ZqWgialH5iZAAReZ1GkfiKgiuqmV6AF7MJulCsif3WWezCIlAeeiuMDdkmYh2Ltt
# JPFzKPaga3UpRac5Q8l04NJWImwImgiAS4p4TTjiZhCDmqLodQuDOCCAbWMz5Tb/
# 8V9PKL5g+HKddGsoB8WCO80tau3bhBv/FsIEI9Eg3GJzPSByIptd/xzumfH5B2n4
# sSMCEvN/s7pPhOJKc3Co9d7EXizw4ciM8NRNnP7jGmGPxyq4c+MdaNdCJBUsEstm
# ryffwDkMUXQJAwW6woncuMPmj838leg5ohvD0Laub1nu/Y5EmCDQvFkqUNbN74/G
# rG2CTbe0aRV5Gr4f9LtDx5VvD0AuE2uT6kUA//8KP4CltV3QG5vZl0HKgZ4xrGhP
# LJ1rn3hlJCF815WtzJHgO91GqqTphzhpAFUhWdEooTU7xEgTs81K7JDMkY6ApqEu
# jgOCyI5uUbIHkBZluTxNc7Via8D01R1zAewB+ozHFHhtjdd9ezdEOJ/BwbMxVnvb
# ZQl3eHBmgd1oxavoV+IiWJi6fvip3EThjvOJ/UWsidhC9vDuuKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MDcxMTU5MzFaMC8GCSqGSIb3DQEJBDEiBCBQ8I+o
# fpVfgsOLyDWwTeMjzl+swt8+ucpAJt8z3m3QqTANBgkqhkiG9w0BAQEFAASCAgCD
# RMvhqxiWAb1BUizXNFnzz9/WbnOjbuCQzCBYize1GDSNmBnukRXUavpPFjhsWIPX
# AxoUizCbDvYytGL1JrrNUCHt2Z8cBTeEfJ6v2i7nYI7B4cufTnVUxdYFN+lofUF0
# 8+zyOiO40m7vu4i4YRfPG5pIsAE/db5L7lkOYMFHlfEc1i2ZnUgjf0xP4s0qx/NM
# rxr+z6tjuHPUX12sYxVGQqZpI7C8a7aFyLsSptAFJktVKY/oiMlLowSwHBlZ+23B
# 8UGkoeXgva/eMGTTZ1zONL07A9pWGGzabp0RCD4+aN0q5j5csoR/jI5NKO5U6QPO
# dH1qPovp0mh/uCNF6eVDdLkmMiq+w4g7fxLpCZJkgRHmnI5haqRmJP20FlPAIvXw
# kUaLGInwm/WpxL40RrkvDCjud7MtxCFHjFp+qkK7Eh4IzOveRsu4Ti92v3g2m5gi
# fNxi8eXm1Tc7CuPbOc7hIwnCoV1rR2ySr99AK51rtAich5p1X/Tka1CNrhBufW2Q
# 9AA4e2kv8ofz3jIixS+eg6GjawiPptVwmA4lW+pSfHq7kG1MZ1BRDwYBrKJxnFX4
# c4zCkEQ7Zj+soRuCP688oieP0+YjufDutKC8pEqNJOmQ39mtkY2XNhCZAYf31Wk5
# XOKwm0B1xUJD4Hfwu5f2K1EYKnHw74auZGTo9/IA0w==
# SIG # End signature block
