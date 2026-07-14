#requires -Version 5.1

<#
.SYNOPSIS
    Pre-loaded Cisco wireless MIB translation cache - no MIB files required.

.DESCRIPTION
    All column maps and enum translations for Cisco wireless SNMP entry tables
    baked in directly from the official MIB definitions:
      - cLApEntry                    (CISCO-LWAPP-AP-MIB,             1.3.6.1.4.1.9.9.513.1.1.1.1)
      - cldcClientEntry              (CISCO-LWAPP-DOT11-CLIENT-MIB,   1.3.6.1.4.1.9.9.599.1.3.1.1)
      - cLWlanConfigEntry            (CISCO-LWAPP-WLAN-MIB,           1.3.6.1.4.1.9.9.512.1.1.1.1)
      - bsnMobileStationEntry        (AIRESPACE-WIRELESS-MIB,         1.3.6.1.4.1.14179.2.1.4.1)
      - cLRogueApEntry               (CISCO-LWAPP-ROGUE-MIB,          1.3.6.1.4.1.9.9.610.1.1.6.1.1)
      - cLRogueAPDetectingAPEntry    (CISCO-LWAPP-ROGUE-MIB,          1.3.6.1.4.1.9.9.610.1.1.8.1.1)

    MIB files in the sibling mibs/ directory are optional and used only as a
    fallback if a column number is not found in this cache.

.NOTES
    Encoding  : UTF-8 with BOM
    PowerShell: 5.1+
    Sources   : CISCO-LWAPP-AP-MIB, CISCO-LWAPP-DOT11-CLIENT-MIB,
                CISCO-LWAPP-WLAN-MIB, CISCO-LWAPP-TC-MIB,
                CISCO-LWAPP-ROGUE-MIB, AIRESPACE-WIRELESS-MIB
                (Cisco Systems copyright)
#>

Set-StrictMode -Version Latest

$script:OidToEntryColumn = $null

# Shared protocol labels reused across both dot11 MIBs
$script:Dot11ProtocolLabels = @{
    1 = '802.11a'; 2 = '802.11b'; 3 = '802.11g'; 4 = 'Unknown'; 5 = 'Mobile'
    6 = '802.11n (2.4 GHz)'; 7 = '802.11n (5 GHz)'; 8 = 'Ethernet'; 9 = '802.3'
    10 = '802.11ac (5 GHz)'; 11 = 'Wi-Fi 6 (5 GHz)'; 12 = 'Wi-Fi 6 (2.4 GHz)'; 13 = 'Wi-Fi 6 (6 GHz)'
}

# COLUMN MAPS: { entryName -> { colNumber -> columnName } }
$script:CiscoWirelessColumnMaps = @{
    'cLApEntry' = @{
        1=  'cLApSysMacAddress';      2=  'cLApIfMacAddress';           3=  'cLApMaxNumberOfDot11Slots'
        4=  'cLApEntPhysicalIndex';   5=  'cLApName';                   6=  'cLApUpTime'
        7=  'cLLwappUpTime';          8=  'cLLwappJoinTakenTime';        9=  'cLApMaxNumberOfEthernetSlots'
        10= 'cLApPrimaryControllerAddressType'; 11= 'cLApPrimaryControllerAddress'
        12= 'cLApSecondaryControllerAddressType'; 13= 'cLApSecondaryControllerAddress'
        14= 'cLApTertiaryControllerAddressType';  15= 'cLApTertiaryControllerAddress'
        16= 'cLApLastRebootReason';   18= 'cLApEncryptionEnable';        19= 'cLApFailoverPriority'
        20= 'cLApPowerStatus';        21= 'cLApTelnetEnable';            22= 'cLApSshEnable'
        23= 'cLApPreStdStateEnabled'; 24= 'cLApPwrInjectorStateEnabled'; 25= 'cLApPwrInjectorSelection'
        26= 'cLApPwrInjectorSwMacAddr'; 27= 'cLApWipsEnable';            28= 'cLApMonitorModeOptimization'
        29= 'cLApDomainName';         30= 'cLApNameServerAddressType';   31= 'cLApNameServerAddress'
        32= 'cLApAMSDUEnable';        33= 'cLApEncryptionSupported';     34= 'cLApRogueDetectionEnabled'
        35= 'cLApTcpMss';             36= 'cLApDataEncryptionStatus';    37= 'cLApNsiKey'
        38= 'cLApAdminStatus';        39= 'cLApPortNumber';              40= 'cLApRetransmitCount'
        41= 'cLApRetransmitTimeout';  42= 'cLApVenueConfigVenueGroup';   43= 'cLApVenueConfigVenueType'
        44= 'cLApVenueConfigVenueName'; 45= 'cLApVenueConfigLanguage';   46= 'cLApLEDState'
        47= 'cLApTrunkVlan';          48= 'cLApTrunkVlanStatus';         49= 'cLApLocation'
        50= 'cLApSubMode';            51= 'cLApAssocCount';              52= 'cLApAssocFailResourceCount'
        53= 'cLApRealTimeStatsModeEnabled'; 54= 'cLApAssociatedClientCount'; 55= 'cLApMemoryCurrentUsage'
        56= 'cLApMemoryAverageUsage'; 57= 'cLApCpuCurrentUsage';         58= 'cLApCpuAverageUsage'
        59= 'cLApUpgradeFromVersion'; 60= 'cLApUpgradeToVersion';        61= 'cLApUpgradeFailureCause'
        62= 'cLApMaxClientLimitNumberTrap'; 63= 'cLApMaxClientLimitCause'; 64= 'cLApMaxClientLimitSet'
        65= 'cLApFloorLabel';         66= 'cLApConnectCount';            67= 'cLApReassocSuccCount'
        68= 'cLApReassocFailCount';   69= 'cLAdjChannelRogueEnabled';    70= 'cLApAssocFailCountByRate'
        71= 'cLApAbnormalOfflineCount'; 72= 'cLApActiveClientCount';     73= 'cLApAssocFailCountForRssiLow'
        74= 'cLApSysNetId';           75= 'cLApAssocFailTimes';          76= 'cLApAntennaBandMode'
        77= 'cLApHeartBeatRspAvgTime'; 78= 'cLApEchoRequestCount';       79= 'cLApEchoResponseLossCount'
        80= 'cLApModuleInserted';     81= 'cLApEnableModule';            82= 'cLApIsUniversal'
        83= 'cLApUniversalPrimeStatus'; 84= 'cLApIsMaster';              85= 'cLApBleFWDownloadStatus'
        86= 'cLApDot11XorDartConnectorStatus'; 87= 'cLApCtsSxpDefaultPassword'; 88= 'cLApCtsSxpState'
        89= 'cLApCtsSxpMode';         90= 'cLApCtsSxpListenerMinHoldtime'; 91= 'cLApCtsSxpListenerMaxHoldtime'
        92= 'cLApCtsSxpReconcilePeriod'; 93= 'cLApCtsSxpRetryPeriod';   94= 'cLApCtsSxpSpeakerHoldTime'
        95= 'cLApCtsSxpSpeakerKeepAlive'; 96= 'cLApCtsInlineTagStatus'; 97= 'cLApCtsSgaclStatus'
        98= 'cLApCtsOverrideStatus';  103= 'cLApModeClear';              104= 'cLApSiteTagName'
        105= 'cLApRfTagName';         106= 'cLApPolicyTagName';          107= 'cLApTagSource'
        108= 'cLApUsbModuleName';     109= 'cLApUsbModuleState';         110= 'cLApUsbModuleProductId'
        111= 'cLApUsbDescription';    112= 'cLApUsbStateInfo';           113= 'cLApUsbOverride'
        114= 'cLApUsbSerialNumber';   115= 'cLApUsbMaxPower';            116= 'cLApLagConfigStatus'
        117= 'cLApMonitorModeOptStatus'; 118= 'cLApFilterName'
    }
    'cldcClientEntry' = @{
        1= 'cldcClientMacAddress';    2= 'cldcClientStatus';             3= 'cldcClientWlanProfileName'
        4= 'cldcClientWgbStatus';     5= 'cldcClientWgbMacAddress';      6= 'cldcClientProtocol'
        7= 'cldcAssociationMode';     8= 'cldcApMacAddress';             9= 'cldcIfType'
        10= 'cldcClientIPAddress';    11= 'cldcClientNacState';          12= 'cldcClientQuarantineVLAN'
        13= 'cldcClientAccessVLAN';   14= 'cldcClientLoginTime';         15= 'cldcClientUpTime'
        16= 'cldcClientPowerSaveMode'; 17= 'cldcClientCurrentTxRateSet'; 18= 'cldcClientDataRateSet'
        19= 'cldcClientHreapApAuth';  20= 'cldcClient80211uCapable';     21= 'cldcClientPostureState'
        22= 'cldcClientAclName';      23= 'cldcClientAclApplied';        24= 'cldcClientRedirectUrl'
        25= 'cldcClientAaaOverrideAclName'; 26= 'cldcClientAaaOverrideAclApplied'; 27= 'cldcClientUsername'
        28= 'cldcClientSSID';         29= 'cldcClientSecurityTagId';     30= 'cldcClientTypeKTS'
        31= 'cldcClientIpv6AclName';  32= 'cldcClientIpv6AclApplied';   33= 'cldcClientDataSwitching'
        34= 'cldcClientAuthentication'; 35= 'cldcClientChannel';         36= 'cldcClientAuthMode'
        37= 'cldcClientReasonCode';   38= 'cldcClientSessionID';         39= 'cldcClientApRoamMacAddress'
        40= 'cldcClientMdnsProfile';  41= 'cldcClientMdnsAdvCount';      42= 'cldcClientPolicyName'
        43= 'cldcClientAAARole';      44= 'cldcClientDeviceType';        45= 'cldcUserAuthType'
        46= 'cldcClientTunnelType';   47= 'cldcClientMaxDataRate';       48= 'cldcClientHtCapable'
        49= 'cldcClientVhtCapable';   50= 'cldcClientCurrentTxRate';     51= 'cldcClientiPSKTag'
        52= 'cldcClientMobileStPolicyType'
    }
    'cLWlanConfigEntry' = @{
        1= 'cLWlanIndex';    2= 'cLWlanRowStatus';       3= 'cLWlanProfileName';   4= 'cLWlanSsid'
        5= 'cLWlanDiagChan'; 6= 'cLWlanStorageType';      7= 'cLWlanIsWired';       8= 'cLWlanIngressInterface'
        9= 'cLWlanNACSupport'; 10= 'cLWlanWepKeyChange';  11= 'cLWlanChdEnable';    12= 'cLWlan802dot11anDTIM'
        13= 'cLWlan802dot11bgnDTIM'; 14= 'cLWlanLoadBalancingEnable'; 15= 'cLWlanBandSelectEnable'
        16= 'cLWlanPassiveClientEnable'; 17= 'cLWlanReAnchorRoamedVoiceClientsEnable'
        18= 'cLWlanMulticastInterfaceEnable'; 19= 'cLWlanMulticastInterface'; 20= 'cLWlanMulticastDirectEnable'
        21= 'cLWlanNACPostureSupport'; 22= 'cLWlanMaxClientsAccepted';   23= 'cLWlanScanDeferPriority'
        24= 'cLWlanScanDeferTime';    25= 'cLWlanLanSubType';            26= 'cLWlanWebAuthOnMacFilterFailureEnabled'
        27= 'cLWlanStaticIpTunnelingEnabled'; 28= 'cLWlanKtsCacSupportEnabled'; 29= 'cLWlanWifiDirectPolicyStatus'
        30= 'cLWlanWebAuthIPv6AclName'; 31= 'cLWlanHotSpot2Enabled';    32= 'cLWlanMaxClientsAllowedPerRadio'
        33= 'cLWlanDhcpDeviceProfiling'; 34= 'cLWlanMacAuthOverDot1xEnabled'; 35= 'cLWlanUserTimeout'
        36= 'cLWlanUserIdleThreshold'; 37= 'cLWlanHttpDeviceProfiling'; 38= 'cLWlanHotSpotClearConfig'
        39= 'cLWlanRadiusAuthFourthServer'; 40= 'cLWlanRadiusAuthFifthServer'; 41= 'cLWlanRadiusAuthSixthServer'
        42= 'cLWlanRadiusAcctFourthServer'; 43= 'cLWlanRadiusAcctFifthServer'; 44= 'cLWlanRadiusAcctSixthServer'
        64= 'cLWlanSelfAnchorEnabled'; 65= 'cLWlanUniversalAdmin';      66= 'cLWlan11acMuMimoEnabled'
        67= 'cLWlan11vDisassocImmiEnable'; 73= 'cLWlan11vDisassocTimer'; 74= 'cLWlan11vOpRoamDisassocTimer'
        84= 'cLWlan11kAssistedRoamingEnable'; 85= 'cLWlan11kNeighborListEnable'; 86= 'cLWlan11kDualbandNeigListEnable'
        87= 'cLWlan11vDMSEnable';     93= 'cLWlan11vBssTransEnable';    96= 'cLWlanEapProfileName'
        97= 'cLWlanSetEapProfileName'; 98= 'cLWlanMaxClientsAllowedPerAP'; 99= 'cLWlanMdnsMode'
        100= 'cLWlanOpportunisticKeyCaching'
    }
    'bsnMobileStationEntry' = @{
        1= 'bsnMobileStationMacAddress'; 2= 'bsnMobileStationIpAddress'; 3= 'bsnMobileStationUserName'
        4= 'bsnMobileStationAPMacAddr';  5= 'bsnMobileStationAPIfSlotId'; 6= 'bsnMobileStationEssIndex'
        7= 'bsnMobileStationSsid';       8= 'bsnMobileStationAID';        9= 'bsnMobileStationStatus'
        11= 'bsnMobileStationMobilityStatus'; 12= 'bsnMobileStationAnchorAddress'
        13= 'bsnMobileStationCFPollable'; 14= 'bsnMobileStationCFPollRequest'
        15= 'bsnMobileStationChannelAgilityEnabled'; 16= 'bsnMobileStationPBCCOptionImplemented'
        17= 'bsnMobileStationShortPreambleOptionImplemented'; 18= 'bsnMobileStationSessionTimeout'
        19= 'bsnMobileStationAuthenticationAlgorithm'; 20= 'bsnMobileStationWepState'
        21= 'bsnMobileStationPortNumber'; 22= 'bsnMobileStationDeleteAction'
        23= 'bsnMobileStationPolicyManagerState'; 24= 'bsnMobileStationSecurityPolicyStatus'
        25= 'bsnMobileStationProtocol'; 26= 'bsnMobileStationMirrorMode'; 27= 'bsnMobileStationInterface'
        28= 'bsnMobileStationApMode';   29= 'bsnMobileStationVlanId';     30= 'bsnMobileStationPolicyType'
        31= 'bsnMobileStationEncryptionCypher'; 32= 'bsnMobileStationEapType'; 33= 'bsnMobileStationCcxVersion'
        34= 'bsnMobileStationE2eVersion'; 42= 'bsnMobileStationStatusCode'; 43= 'bsnMobileStationAAAOverridePassphrase'
    }
    'cLRogueApEntry' = @{
        1= 'cLRogueApMACAddress'; 2= 'cLRogueApClassType'; 3= 'cLRogueApState'
        4= 'cLRogueApStorageType'; 5= 'cLRogueApRowStatus'
    }
    'cLRogueAPDetectingAPEntry' = @{
        1= 'cLRogueAPDetectingAPMacAddress';  2= 'cLRogueAPDetectingAPSlotId'
        3= 'cLRogueAPRadioType';               4= 'cLRogueAPDetectingAPName'
        5= 'cLRogueAPChannelNumber';           6= 'cLRogueAPSsid'
        7= 'cLRogueAPHiddenSsid';              8= 'cLRogueAPDetectingAPRSSI'
        9= 'cLRogueAPContainmentMode';         10= 'cLRogueAPContainmentChannelCount'
        11= 'cLRogueAPContainmentChannels';    12= 'cLRogueAPDetectingAPLastHeard'
        13= 'cLRogueAPDetectingAPWepMode';     14= 'cLRogueAPDetectingAPPreamble'
        15= 'cLRogueAPDetectingAPWpaMode';     16= 'cLRogueAPDetectingAPWpa2Mode'
        17= 'cLRogueAPDetectingAPFTMode';      18= 'cLRogueAPDetectingAPSNR'
        19= 'cLRogueAPChannelWidth';           20= 'cLRogueAPPhysicalAPSlot'
    }
}

# ENUM MAPS: { 'EntryName.ColumnName' -> { intValue -> humanReadableLabel } }
$script:CiscoWirelessEnumMaps = @{

    # cLApEntry
    'cLApEntry.cLApLastRebootReason' = @{
        0='None'; 1='802.11g Mode Change'; 2='IP Address Set'; 3='IP Address Reset'
        4='Reboot from Controller'; 5='DHCP Fallback Failure'; 6='Discovery Failure'
        7='No Join Response'; 8='Join Denied'; 9='No Config Response'
        10='Found Configured Controller'; 11='Image Upgrade Success'; 12='Image Opcode Invalid'
        13='Image Checksum Invalid'; 14='Image Data Timeout'; 15='Config File Invalid'
        16='Image Download Error'; 17='Reboot from Console'; 18='RAP Over-the-Air'
        19='Low Power'; 20='Crash'; 21='Power Spike'; 22='Power Loss'; 23='Power Source Change'
        24='Component Failure'; 25='Watchdog Timer Reset'; 26='LSC Enabled'; 27='LSC Disabled'
        28='LSC Provision Timeout'; 29='LSC Max Retries Reached'; 30='LSC Load Failure'
        31='LSC Join Failure'; 32='CAPWAP Timer Failure'; 33='Static IP Failover'
        34='VLAN Tag Failover'; 35='CAPWAP Discovery Request'; 36='CAPWAP Discovery Response'
        37='CAPWAP Join Request'; 38='CAPWAP Join Response'; 39='CAPWAP Config Status'
        40='CAPWAP Config Status Response'; 41='CAPWAP Config Update Request'
        42='CAPWAP Config Update Response'; 43='CAPWAP WTP Event Request'
        44='CAPWAP WTP Event Response'; 45='CAPWAP Change State Request'
        46='CAPWAP Change State Response'; 47='CAPWAP Echo Request'; 48='CAPWAP Echo Response'
        49='CAPWAP Image Data Request'; 50='CAPWAP Image Data Response'
        51='CAPWAP Reset Request'; 52='CAPWAP Reset Response'
        53='CAPWAP Primary Discovery Request'; 54='CAPWAP Primary Discovery Response'
        55='CAPWAP Data Transfer Request'; 56='CAPWAP Data Transfer Response'
        57='CAPWAP Clear Config Request'; 58='CAPWAP Clear Config Response'
        59='CAPWAP Mobile Config Request'; 60='CAPWAP Mobile Config Response'
        61='CAPWAP Path MTU Request'; 62='CAPWAP Path MTU Response'; 63='VLAN Tag Retry'
        64='IPv6 Address Set'; 65='Mode Change'; 66='Changed to CAPWAP Mode'
        67='Changed to EWC Mode'; 68='Erase Config Command'; 69='OEAP Mode Config Upload'
        70='LAG Config Change'; 71='FIPS Mode Change'; 72='Diminished Power Change'
        73='SLUB Debug'; 74='LSC Mode: CAPWAP'; 75='LSC Mode: 802.1X'; 76='LSC Mode: All'
        77='AP Type Changed to Cloud'; 78='DTLS Init Failure'; 79='PnP: No CAPWAP Back-off'
        80='Day-0 Config Failure'; 81='Day-1 Config Failure'; 82='PnP-Triggered Reload'
        83='Tri-Radio Support Change'; 84='Indoor Deployment'
        85='Changed from WGB to CAPWAP'; 86='Changed from Cloud to CAPWAP'; 87='Changed to WGB Mode'
    }
    'cLApEntry.cLApFailoverPriority'         = @{ 1='Low'; 2='Medium'; 3='High'; 4='Critical' }
    'cLApEntry.cLApPowerStatus'              = @{ 1='Low Power'; 2='15.4W PoE'; 3='16.8W PoE'; 4='Full Power'; 5='External Power'; 6='25.5W PoE'; 7='Mixed Mode' }
    'cLApEntry.cLApPwrInjectorSelection'     = @{ 1='Unknown'; 2='Installed'; 3='Override' }
    'cLApEntry.cLApMonitorModeOptimization'  = @{ 1='All'; 2='Tracking'; 3='WIPS'; 4='None' }
    'cLApEntry.cLApSubMode'                  = @{ 1='None'; 2='WIPS'; 3='PPPoE'; 4='PPPoE + WIPS' }
    'cLApEntry.cLApAntennaBandMode'          = @{ 1='N/A'; 2='Single Band'; 3='Dual Band' }
    'cLApEntry.cLApTagSource'                = @{ 1='None'; 2='Static'; 3='Filter Engine'; 4='PnP Server'; 5='Default'; 6='Location' }
    'cLApEntry.cLApVenueConfigVenueGroup'    = @{
        1='Unspecified'; 2='Assembly'; 3='Business'; 4='Educational'; 5='Factory / Industrial'
        6='Institutional'; 7='Mercantile'; 8='Residential'; 9='Storage'; 10='Utility / Misc'
        11='Vehicular'; 12='Outdoor'
    }
    'cLApEntry.cLApVenueConfigVenueType'     = @{
        1='Unspecified'; 2='Unspecified Assembly'; 3='Arena'; 4='Stadium'; 5='Passenger Terminal'
        6='Amphitheater'; 7='Amusement Park'; 8='Place of Worship'; 9='Convention Center'
        10='Library'; 11='Museum'; 12='Restaurant'; 13='Theater'; 14='Bar'; 15='Coffee Shop'
        16='Zoo / Aquarium'; 17='Emergency Coordination Center'; 18='Unspecified Business'
        19='Doctor / Dentist Office'; 20='Bank'; 21='Fire Station'; 22='Police Station'
        23='Post Office'; 24='Professional Office'; 25='R&D Facility'; 26='Attorney Office'
        27='Unspecified Educational'; 28='Primary School'; 29='Secondary School'
        30='University / College'; 31='Unspecified Factory/Industrial'; 32='Factory'
        33='Unspecified Institutional'; 34='Hospital'; 35='Long-Term Care Facility'
        36='Alcohol/Drug Rehab Center'; 37='Group Home'; 38='Prison / Jail'
        39='Unspecified Mercantile'; 40='Retail Store'; 41='Grocery Market'
        42='Automotive Service Station'; 43='Shopping Mall'; 44='Gas Station'
        45='Unspecified Residential'; 46='Private Residence'; 47='Hotel / Motel'
        48='Dormitory'; 49='Boarding House'; 50='Unspecified Storage'; 51='Unspecified Utility'
        52='Unspecified Vehicular'; 53='Automobile / Truck'; 54='Airplane'; 55='Bus'
        56='Ferry'; 57='Ship / Boat'; 58='Train'; 59='Motorbike'; 60='Unspecified Outdoor'
        61='Municipal Mesh Network'; 62='City Park'; 63='Rest Area'; 64='Traffic Control'
        65='Bus Stop'; 66='Kiosk'
    }

    # cldcClientEntry  (CLDot11ClientStatus from CISCO-LWAPP-TC-MIB)
    'cldcClientEntry.cldcClientStatus'       = @{ 1='Idle'; 2='AAA Pending'; 3='Authenticated'; 4='Associated'; 5='Power Save'; 6='Disassociated'; 7='To Be Deleted'; 8='Probing'; 9='Excluded' }
    'cldcClientEntry.cldcClientProtocol'     = $script:Dot11ProtocolLabels
    'cldcClientEntry.cldcAssociationMode'    = @{ 1='Unknown'; 2='WEP'; 3='WPA'; 4='WPA2' }
    'cldcClientEntry.cldcClientWgbStatus'    = @{ 1='Regular Client'; 2='WGB Client'; 3='WGB' }
    'cldcClientEntry.cldcClientNacState'     = @{ 1='Quarantine'; 2='Access' }
    'cldcClientEntry.cldcClientDataSwitching'= @{ 1='Unknown'; 2='Central'; 3='Local' }
    'cldcClientEntry.cldcClientAuthentication'=@{ 1='Unknown'; 2='Central'; 3='Local' }
    'cldcClientEntry.cldcClientAuthMode'     = @{ 0='None'; 1='PSK'; 2='RADIUS'; 3='CCKM'; 4='WAPI PSK'; 5='WAPI Certificate'; 6='FT 802.1X'; 7='FT PSK'; 8='PMF 802.1X'; 9='PMF PSK' }
    'cldcClientEntry.cldcClientReasonCode'   = @{
        1='Unspecified'; 2='Previous Auth Not Valid'; 3='Deauthentication (Leaving)'
        4='Inactivity Timeout'; 5='AP Busy'; 6='Class-2 Frame (Not Auth)'; 7='Class-2 Frame (Not Assoc)'
        8='STA Has Left'; 9='Association Without Auth'; 40='Invalid Information Element'
        41='Group Cipher Invalid'; 42='Unicast Cipher Invalid'; 43='AKMP Invalid'
        44='Unsupported RSN Version'; 45='Invalid RSN IE Capabilities'; 46='Cipher Suite Rejected'
        99='Missing Reason Code'; 101='Max Clients Reached'; 105='Max Clients on Radio'
        106='Max Clients on WLAN'; 200='Unspecified QoS Failure'; 201='QoS Policy Mismatch'
        202='Insufficient Bandwidth'; 203='Invalid QoS Parameters'
    }
    'cldcClientEntry.cldcUserAuthType'       = @{ 1='Open'; 2='WEP/PSK'; 3='Web Portal'; 4='SIM/PEAP'; 5='Other' }
    'cldcClientEntry.cldcClientTunnelType'   = @{ 1='Simple'; 2='PMIPv6'; 3='GTPv2'; 4='EoGRE' }
    'cldcClientEntry.cldcClientMobileStPolicyType' = @{ 0='802.1X'; 1='WPA'; 2='WPA2'; 3='WPA2 (VFF)'; 4='N/A'; 5='Unknown'; 6='WPA2 / WPA3'; 7='OSEN'; 8='OSEN within RSN' }

    # cLWlanConfigEntry
    'cLWlanConfigEntry.cLWlanRowStatus'             = @{ 1='Active'; 2='Not In Service'; 3='Not Ready'; 4='Create and Go'; 5='Create and Wait'; 6='Destroy' }
    'cLWlanConfigEntry.cLWlanLanSubType'             = @{ 1='Wireless LAN'; 2='Guest LAN'; 3='Remote LAN'; 4='Other' }
    'cLWlanConfigEntry.cLWlanWifiDirectPolicyStatus' = @{ 1='Disabled'; 2='Allow'; 3='Not Allow'; 4='X-Connect Not Allow' }
    'cLWlanConfigEntry.cLWlanMdnsMode'               = @{ 0='Bridge'; 1='Drop'; 2='Gateway' }

    # bsnMobileStationEntry
    'bsnMobileStationEntry.bsnMobileStationStatus'                    = @{ 0='Idle'; 1='AAA Pending'; 2='Authenticated'; 3='Associated'; 4='Power Save'; 5='Disassociated'; 6='To Be Deleted'; 7='Probing'; 8='Blacklisted' }
    'bsnMobileStationEntry.bsnMobileStationMobilityStatus'            = @{ 0='Unassociated'; 1='Local'; 2='Anchor'; 3='Foreign'; 4='Handoff'; 5='Unknown'; 6='Export Anchor'; 7='Export Foreign' }
    'bsnMobileStationEntry.bsnMobileStationProtocol'                  = $script:Dot11ProtocolLabels
    'bsnMobileStationEntry.bsnMobileStationAuthenticationAlgorithm'   = @{ 0='Open System'; 1='Shared Key'; 2='Unknown'; 128='Open + EAP' }
    'bsnMobileStationEntry.bsnMobileStationWepState'                  = @{ 1='Enabled'; 2='Disabled' }
    'bsnMobileStationEntry.bsnMobileStationSecurityPolicyStatus'      = @{ 0='Completed'; 1='Not Completed' }
    'bsnMobileStationEntry.bsnMobileStationApMode'                    = @{ 0='Local'; 1='Monitor'; 2='Remote'; 3='Rogue Detector' }
    'bsnMobileStationEntry.bsnMobileStationMirrorMode'                = @{ 0='Disabled'; 1='Enabled' }
    'bsnMobileStationEntry.bsnMobileStationPolicyType'                = @{ 0='802.1X'; 1='WPA'; 2='WPA2'; 3='WPA2 (VFF)'; 4='N/A'; 5='Unknown'; 6='WPA2 / WPA3'; 7='OSEN'; 8='OSEN within RSN' }
    'bsnMobileStationEntry.bsnMobileStationEncryptionCypher'          = @{ 0='CCMP (AES-128)'; 1='TKIP + MIC'; 2='WEP-40'; 3='WEP-104'; 4='WEP-128'; 5='None'; 6='TKIP+WEP-40'; 7='TKIP+WEP-104'; 8='GCMP-128'; 9='GCMP-256'; 10='CCMP-256'; 11='N/A'; 12='Unknown' }
    'bsnMobileStationEntry.bsnMobileStationEapType'                   = @{ 0='EAP-TLS'; 1='EAP-TTLS'; 2='PEAP'; 3='LEAP'; 4='SPEKE'; 5='EAP-FAST'; 6='N/A'; 7='Unknown' }
    'bsnMobileStationEntry.bsnMobileStationCcxVersion'                = @{ 0='Not Supported'; 1='CCXv1'; 2='CCXv2'; 3='CCXv3'; 4='CCXv4'; 5='CCXv5'; 6='CCXv6' }
    'bsnMobileStationEntry.bsnMobileStationE2eVersion'                = @{ 0='Not Supported'; 1='E2Ev1'; 2='E2Ev2' }

    # cLRogueApEntry  (CISCO-LWAPP-ROGUE-MIB — deprecated table, still walked on many controllers)
    'cLRogueApEntry.cLRogueApClassType' = @{ 1='Friendly'; 2='Malicious'; 3='Unclassified'; 4='Custom' }
    'cLRogueApEntry.cLRogueApState'     = @{
        1='Pending'; 2='Alert'; 3='Detected LRAD'; 4='Known'; 5='Acknowledge'
        6='Contained'; 7='Threat'; 8='Contained Pending'; 9='Known Contained'
        10='Trusted Missing'; 11='Initializing'
    }

    # cLRogueAPDetectingAPEntry  (CISCO-LWAPP-ROGUE-MIB — which APs heard the rogue, with RSSI/SNR)
    'cLRogueAPDetectingAPEntry.cLRogueAPRadioType' = @{
        1='802.11b'; 2='802.11a'; 3='802.11a/b/g/n'; 4='UWB'; 5='802.11g'
        6='802.11n (2.4 GHz)'; 7='802.11n (5 GHz)'; 8='Unknown'; 9='802.11ac'
        10='Wi-Fi 6 (2.4 GHz)'; 11='Wi-Fi 6 (5 GHz)'; 12='Wi-Fi 6 (6 GHz)'
    }
    'cLRogueAPDetectingAPEntry.cLRogueAPHiddenSsid'          = @{ 0='Disabled'; 1='Enabled' }
    'cLRogueAPDetectingAPEntry.cLRogueAPContainmentMode'     = @{
        0='Invalid'; 1='Deauth Broadcast'; 2='CFP'; 3='Client Containment'
        4='Ad Hoc Containment'; 5='Max'; 99='Unknown'
    }
    'cLRogueAPDetectingAPEntry.cLRogueAPDetectingAPWepMode'  = @{ 0='Disabled'; 1='Enabled' }
    'cLRogueAPDetectingAPEntry.cLRogueAPDetectingAPPreamble' = @{ 0='Long'; 1='Short'; 2='Not Supported' }
    'cLRogueAPDetectingAPEntry.cLRogueAPDetectingAPWpaMode'  = @{ 0='Disabled'; 1='Enabled' }
    'cLRogueAPDetectingAPEntry.cLRogueAPDetectingAPWpa2Mode' = @{ 0='Disabled'; 1='Enabled' }
    'cLRogueAPDetectingAPEntry.cLRogueAPDetectingAPFTMode'   = @{ 0='Disabled'; 1='Enabled' }
    'cLRogueAPDetectingAPEntry.cLRogueAPChannelWidth'        = @{
        1='5 MHz'; 2='10 MHz'; 3='20 MHz'; 4='+40 MHz (above)'; 5='+40 MHz (below)'
        6='+40+80 MHz (above/above)'; 7='+40+80 MHz (above/below)'
        8='+40+80 MHz (below/above)'; 9='+40+80 MHz (below/below)'
        10='160+40+80 (above/above/above)'; 11='160+40+80 (below/above/above)'
        12='160+40+80 (above/below/above)'; 13='160+40+80 (below/below/above)'
        14='160+40+80 (above/above/below)'; 15='160+40+80 (below/above/below)'
        16='160+40+80 (above/below/below)'; 17='160+40+80 (below/below/below)'
    }
}

# PUBLIC FUNCTIONS

function Get-CachedColumnMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Entry)
    if ($script:CiscoWirelessColumnMaps.ContainsKey($Entry)) {
        return $script:CiscoWirelessColumnMaps[$Entry]
    }
    return $null
}

function Get-CachedEnumLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$Column,
        [Parameter(Mandatory)][AllowNull()]$Value
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    $mapKey = "${Entry}.${Column}"
    $intVal = 0
    if (-not [int]::TryParse([string]$Value, [ref]$intVal)) { return [string]$Value }
    if ($script:CiscoWirelessEnumMaps.ContainsKey($mapKey)) {
        $map = $script:CiscoWirelessEnumMaps[$mapKey]
        if ($map.ContainsKey($intVal)) { return $map[$intVal] }
    }
    return [string]$Value
}

function Get-CachedEnumTranslation {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$OidBase,
        [Parameter(Mandatory)][AllowNull()]$Value
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    # Build OID->entry.column index on first use
    if ($null -eq $script:OidToEntryColumn) {
        $script:OidToEntryColumn = @{}
        $entryBaseOids = @{
            'cLApEntry'                 = '1.3.6.1.4.1.9.9.513.1.1.1.1'
            'cldcClientEntry'           = '1.3.6.1.4.1.9.9.599.1.3.1.1'
            'cLWlanConfigEntry'         = '1.3.6.1.4.1.9.9.512.1.1.1.1'
            'bsnMobileStationEntry'     = '1.3.6.1.4.1.14179.2.1.4.1'
            'cLRogueApEntry'            = '1.3.6.1.4.1.9.9.610.1.1.6.1.1'
            'cLRogueAPDetectingAPEntry' = '1.3.6.1.4.1.9.9.610.1.1.8.1.1'
        }
        foreach ($entry in $entryBaseOids.Keys) {
            $base = $entryBaseOids[$entry]
            $colMap = $script:CiscoWirelessColumnMaps[$entry]
            foreach ($col in $colMap.Keys) {
                $script:OidToEntryColumn["$base.$col"] = @{ Entry = $entry; Column = $colMap[$col] }
            }
        }
    }
    if ($script:OidToEntryColumn.ContainsKey($OidBase)) {
        $ec = $script:OidToEntryColumn[$OidBase]
        return Get-CachedEnumLabel -Entry $ec.Entry -Column $ec.Column -Value $Value
    }
    return [string]$Value
}

function Get-CachedOidName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Oid)
    if ([string]::IsNullOrWhiteSpace($Oid)) { return $null }
    $null = Get-CachedEnumTranslation -OidBase $Oid -Value 0   # init index
    if ($script:OidToEntryColumn.ContainsKey($Oid)) { return $script:OidToEntryColumn[$Oid].Column }
    return $null
}

function Clear-MibCache {
    [CmdletBinding()]
    param()
    $script:OidToEntryColumn = $null
    Write-Verbose 'MIB translation cache runtime index cleared.'
}

function Get-MibCacheStatistics {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()
    $colCount  = ($script:CiscoWirelessColumnMaps.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    $enumCount = $script:CiscoWirelessEnumMaps.Count
    $valCount  = ($script:CiscoWirelessEnumMaps.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    [PSCustomObject]@{ EntryTables = $script:CiscoWirelessColumnMaps.Count; TotalColumns = $colCount; EnumColumns = $enumCount; TotalEnumValues = $valCount }
}
# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC7KvK/CgUF7qik
# caWUyY0c7HCkTnCY3us5BjxokRMNI6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAedv1vEQ+oZUzis5qjFkb/dEKzfktC5NmESgRpAugkVTANBgkqhkiG9w0BAQEF
# AASCAgDop/dvhHPUfzAoB9v65yWyv6bqGuxLop32hivd+t1L8YARzXjvE6bbPH7D
# CZ4VIbvnb+hmhtvkDZkIeCHs/ANVzZgTIGjgX3azbJpLbgih8h1yIQJWO0F8Ywwg
# ls2GZqZI1yhL9JNJXpIdKqaz3NES5d6NmORc6uqEn5VmX+UA0Kek24tw3NzsHi4i
# JhsfwvEwqpxNh8uANL4Tg0nhRjoKgcah6QiKN2EVfvz/tfVlictqb/EOk+TqHvLD
# twKbrfWLI4KRNleFZmqpvDzkvIpoc7BmseVaqMm8PBlKbX1x/otB+RraCVDFNDrG
# Y8tMw0QCi1cTZYSmnlI2q+QsauJ8sziHTvDUPrYEDfjic+whHMTuqd3og1Im7mQu
# BNEIq6JDjkqkk1UMrP8maiVHV+wrEAk++0Pj1QJLH82+8fPZPRsG1WnklU5AuwKW
# aIUZblIsdqAUIkbMEd660lJf8i+Vv0BxviDWXoWjWx/Tq1lgqtjbCA0VojoTiWmR
# NUPlFmf2tUdqr6dcDohrgc4tTh159h51PZ3PlqV7/RkN18gogcm0UvFGYm6gIOog
# p0jVAbu99ZP/2ccFnEcWWaEGfnyJoQZnm/InmX19lTnah4vkpD0kLYnE1RkY1Vmk
# q11wYTY45bKFbnQrBDojmMCBa17tY5dSukbe7ozIQDHsTlkvgaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MTQwMDE5MDVaMC8GCSqGSIb3DQEJBDEiBCAgOwXx
# BWv++36JRr5A9q8JsW56cmGR3Ho5u1r00EBADzANBgkqhkiG9w0BAQEFAASCAgAd
# LGx1fkfEk1bwRvjBBwXt5Z5MHRKtX+ywJNcZn7PUmkVUJfzU+yYM1iJVmtcGGz+8
# dAaCr1AytbOrKk3+A69keUTr/yENkoDNZoBl4mlcGECjazpGyH4ZghGOMJLvzw+f
# XfJBM9mze9qw+Wwxca9KAMC4tD+h7VNRaFxxdARN7eIB+iew0Rqnwm2j7QJl+J+a
# z4FqGcamjCY95ecEMK99dXZhLxe6360dpmZl6NLIpYlxCw9ilQaO81CjBxjq9YVg
# wUPcxlPC4XnVwktHYj5KHLCJ5gUXRORPevxJoV9FgCC/JHhUTVDYYzuCzzDLRLJB
# LUJBIWMsafBppeLW3NjuNbG1NqX7qu8nksDCWHTdmQopsRtQMvSCPeIwrVytLwWB
# HZCmJ1styQ2kryuYQ9RyM9jgBvvnI3qcyDCT2YlavR3Eej5x1fh01423wOqqzWC8
# BZjf8Hx2Fgvb5zUL2PMQvRxMNeu9aD0bMnb/6wU+G8P2/I3lHoVykWpmu308ZdbY
# /gFjLa4hM5z0Imjxu8bdFjssDQrdMiGW/O2qmn1TFKz199JTKpwZeoN44+7h1mTP
# vhoc8Bt/2pgrHxGvEWUO0be2bbnBDMY2MOb5JyFcKF++n7++hcL9wMSN0FRncnC+
# dGSkSJaXntC4JLJDHB7ngjf7l9al8fP9HbYwhVPYfQ==
# SIG # End signature block
