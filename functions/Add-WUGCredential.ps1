# ============================================================
# API Endpoint Reference
# Source: WhatsUpGold 2024 REST API Spec v0.3
#
# Create credential in library:
#   POST /api/v1/credentials/-
#   Body schema: CredentialAdd
#     - name         (string, required)  Display name
#     - description  (string, optional)  Description
#     - type         (string, required)  Credential type
#     - propertyBags (array,  required)  [ { name: string, value: string }, ... ]
#   Success response: Result[Credential]
#     - data.idMap.resultId = new credential ID
#
# Property bag name prefixes by type:
#   snmpv1   -> CredSnmpV1:ReadCommunity, WriteCommunity
#   snmpv2   -> CredSnmpV2:ReadCommunity, WriteCommunity
#   snmpv3   -> CredSnmpV3:Username, Context, AuthPassword, AuthProtocol, EncryptPassword, EncryptProtocol
#   windows  -> CredWindows:DomainAndUserid, Password
#   ssh      -> CredSSH:Username, Password, ConfirmPassword, EnablePassword, ConfirmEnablePassword, Timeout, Port
#   ado      -> CredADO:Username, Password
#   aws      -> CredAWS:AccessKeyID, SecureAccessKey
#   azure    -> CredAzure:SecureKey, TenantID, ClientID, EnrollmentNumber, EnrollmentAccessKey
#   redfish  -> CredRedfishBmc:Username, Password, Protocol, Port, Timeout, Retries, IgnoreCertificateErrors
#   restapi  -> CredRestAPI:Username, Password, Authtype, GrantType, AuthorizeUrl, TokenUrl,
#              ClientId, ClientSecret, Scope, OptionalParams, PwdGrantUserName, PwdGrantPassword,
#              IgnoreCertificateErrorsForOAuth2Token, RefreshToken
# ============================================================
<#
.SYNOPSIS
    Creates a new credential in the WhatsUp Gold credential library.

.DESCRIPTION
    Add-WUGCredential creates a credential via POST /api/v1/credentials/-. Each credential
    type has its own parameter set with named parameters for every property bag field, so
    users do not need to construct property-bag arrays manually. A -Body parameter set is
    available for unsupported or custom types.

.PARAMETER Name
    Display name for the credential. Required for all typed parameter sets.

.PARAMETER Description
    Optional description for the credential.

.PARAMETER Type
    The type of credential to create. Required. Each type maps to its own parameter set.
    Valid values: snmpV1, snmpV2, snmpV3, windows, ado, ssh, aws, azure, redfish, restapi.

.PARAMETER SnmpReadCommunity
    (snmpV1/snmpV2) SNMP read community string. Required.

.PARAMETER SnmpWriteCommunity
    (snmpV1/snmpV2) SNMP write community string. Default: empty.

.PARAMETER SnmpV3Username
    (snmpV3) SNMPv3 username. Required.

.PARAMETER SnmpV3Context
    (snmpV3) SNMPv3 context. Default: empty.

.PARAMETER SnmpV3AuthPassword
    (snmpV3) Authentication password. Required.

.PARAMETER SnmpV3AuthProtocol
    (snmpV3) Authentication protocol. 1=MD5, 3=SHA. Default: 1.

.PARAMETER SnmpV3EncryptPassword
    (snmpV3) Encryption password. Default: empty.

.PARAMETER SnmpV3EncryptProtocol
    (snmpV3) Encryption protocol. 1=DES, 3=AES128. Default: 1.

.PARAMETER WindowsUser
    (windows) Domain\\User or .\\User format. Required.

.PARAMETER WindowsPassword
    (windows) Password. Required.

.PARAMETER SshUsername
    (ssh) SSH username. Required.

.PARAMETER SshPassword
    (ssh) SSH password. Required.

.PARAMETER SshEnablePassword
    (ssh) Enable/sudo password. Default: empty.

.PARAMETER SshTimeout
    (ssh) Connection timeout in seconds. Default: 10.

.PARAMETER SshPort
    (ssh) SSH port. Default: 22.

.PARAMETER AdoUsername
    (ado) ADO username. Required.

.PARAMETER AdoPassword
    (ado) ADO password. Required.

.PARAMETER AwsAccessKeyID
    (aws) AWS access key ID. Required.

.PARAMETER AwsSecureAccessKey
    (aws) AWS secret access key. Required.

.PARAMETER AzureSecureKey
    (azure) Azure client secret / secure key. Required.

.PARAMETER AzureTenantID
    (azure) Azure tenant GUID. Required.

.PARAMETER AzureClientID
    (azure) Azure client/application GUID. Required.

.PARAMETER AzureEnrollmentNumber
    (azure) Azure enrollment number. Default: empty.

.PARAMETER AzureEnrollmentAccessKey
    (azure) Azure enrollment access key. Default: empty.

.PARAMETER RedfishUsername
    (redfish) Redfish BMC username. Required.

.PARAMETER RedfishPassword
    (redfish) Redfish BMC password. Required.

.PARAMETER RedfishProtocol
    (redfish) Protocol. Default: HTTPS.

.PARAMETER RedfishPort
    (redfish) Port. Default: 443.

.PARAMETER RedfishTimeout
    (redfish) Timeout in seconds. Default: 15.

.PARAMETER RedfishRetries
    (redfish) Number of retries. Default: 3.

.PARAMETER RedfishIgnoreCertErrors
    (redfish) Ignore SSL certificate errors. Default: True.

.PARAMETER RestApiUsername
    (restapi) REST API username (for basic auth). Default: empty.

.PARAMETER RestApiPassword
    (restapi) REST API password (for basic auth). Default: empty.

.PARAMETER RestApiAuthType
    (restapi) Auth type. 0=Basic, 1=OAuth2. Default: 0.

.PARAMETER RestApiGrantType
    (restapi) OAuth2 grant type. 0=ClientCredentials, 1=Password, 2=AuthorizationCode. Default: empty.

.PARAMETER RestApiAuthorizeUrl
    (restapi) OAuth2 authorization URL. Default: empty.

.PARAMETER RestApiTokenUrl
    (restapi) OAuth2 token URL. Default: empty.

.PARAMETER RestApiClientId
    (restapi) OAuth2 client ID. Default: empty.

.PARAMETER RestApiClientSecret
    (restapi) OAuth2 client secret. Default: empty.

.PARAMETER RestApiScope
    (restapi) OAuth2 scope. Default: empty.

.PARAMETER RestApiOptionalParams
    (restapi) Optional parameters JSON. Default: empty.

.PARAMETER RestApiPwdGrantUserName
    (restapi) OAuth2 password grant username. Default: empty.

.PARAMETER RestApiPwdGrantPassword
    (restapi) OAuth2 password grant password. Default: empty.

.PARAMETER RestApiIgnoreCertErrors
    (restapi) Ignore OAuth2 token cert errors. Default: empty.

.PARAMETER RestApiRefreshToken
    (restapi) OAuth2 refresh token. Default: empty.

.PARAMETER PropertyBags
    An array of property bag hashtables for unsupported types. Use with -Type.

.PARAMETER Body
    A raw JSON body string for full control over the request payload.

.EXAMPLE
    Add-WUGCredential -Name "SNMP Public" -Type snmpV2 -SnmpReadCommunity "public"

.EXAMPLE
    Add-WUGCredential -Name "WinAdmin" -Type windows -WindowsUser ".\\administrator" -WindowsPassword "P@ssw0rd"

.EXAMPLE
    Add-WUGCredential -Name "Linux SSH" -Type ssh -SshUsername "admin" -SshPassword "secret" -SshPort 2222

.EXAMPLE
    Add-WUGCredential -Name "SNMPv3 Auth" -Type snmpV3 -SnmpV3Username "monitor" -SnmpV3AuthPassword "authpass" -SnmpV3AuthProtocol 3

.EXAMPLE
    Add-WUGCredential -Name "Azure SP" -Type azure -AzureSecureKey "key" -AzureTenantID "tid" -AzureClientID "cid"

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: POST /api/v1/credentials/-
    Spec: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/whatsupgold2024-0-3.json
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS
#>
function Add-WUGCredential {
    [CmdletBinding(DefaultParameterSetName = 'snmpV2', SupportsShouldProcess = $true)]
    param(
        # -- Common parameters (all typed parameter sets) ---------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV1')]
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV2')]
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV3')]
        [Parameter(Mandatory = $true, ParameterSetName = 'windows')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ssh')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ado')]
        [Parameter(Mandatory = $true, ParameterSetName = 'aws')]
        [Parameter(Mandatory = $true, ParameterSetName = 'azure')]
        [Parameter(Mandatory = $true, ParameterSetName = 'redfish')]
        [Parameter(Mandatory = $true, ParameterSetName = 'restapi')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByProperties')]
        [string]$Name,

        [Parameter(ParameterSetName = 'snmpV1')]
        [Parameter(ParameterSetName = 'snmpV2')]
        [Parameter(ParameterSetName = 'snmpV3')]
        [Parameter(ParameterSetName = 'windows')]
        [Parameter(ParameterSetName = 'ssh')]
        [Parameter(ParameterSetName = 'ado')]
        [Parameter(ParameterSetName = 'aws')]
        [Parameter(ParameterSetName = 'azure')]
        [Parameter(ParameterSetName = 'redfish')]
        [Parameter(ParameterSetName = 'restapi')]
        [Parameter(ParameterSetName = 'ByProperties')]
        [string]$Description,

        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV1')]
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV2')]
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV3')]
        [Parameter(Mandatory = $true, ParameterSetName = 'windows')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ssh')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ado')]
        [Parameter(Mandatory = $true, ParameterSetName = 'aws')]
        [Parameter(Mandatory = $true, ParameterSetName = 'azure')]
        [Parameter(Mandatory = $true, ParameterSetName = 'redfish')]
        [Parameter(Mandatory = $true, ParameterSetName = 'restapi')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByProperties')]
        [ValidateSet('snmpV1', 'snmpV2', 'snmpV3', 'windows', 'ado', 'telnet', 'ssh', 'vmware', 'jmx', 'smis', 'aws', 'azure', 'meraki', 'restapi', 'ubiquiti', 'redfish')]
        [string]$Type,

        # -- SNMP v1 / v2 parameters -----------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV1')]
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV2')]
        [string]$SnmpReadCommunity,

        [Parameter(ParameterSetName = 'snmpV1')]
        [Parameter(ParameterSetName = 'snmpV2')]
        [string]$SnmpWriteCommunity = '',

        # -- SNMP v3 parameters -----------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV3')]
        [string]$SnmpV3Username,

        [Parameter(ParameterSetName = 'snmpV3')]
        [string]$SnmpV3Context = '',

        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV3')]
        [string]$SnmpV3AuthPassword,

        [Parameter(ParameterSetName = 'snmpV3')]
        [ValidateSet('1', '3')]
        [string]$SnmpV3AuthProtocol = '1',

        [Parameter(ParameterSetName = 'snmpV3')]
        [string]$SnmpV3EncryptPassword = '',

        [Parameter(ParameterSetName = 'snmpV3')]
        [ValidateSet('1', '3')]
        [string]$SnmpV3EncryptProtocol = '1',

        # -- Windows parameters -----------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'windows')]
        [string]$WindowsUser,

        [Parameter(Mandatory = $true, ParameterSetName = 'windows')]
        [string]$WindowsPassword,

        # -- SSH parameters ---------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'ssh')]
        [string]$SshUsername,

        [Parameter(Mandatory = $true, ParameterSetName = 'ssh')]
        [string]$SshPassword,

        [Parameter(ParameterSetName = 'ssh')]
        [string]$SshEnablePassword = '',

        [Parameter(ParameterSetName = 'ssh')]
        [string]$SshTimeout = '10',

        [Parameter(ParameterSetName = 'ssh')]
        [string]$SshPort = '22',

        # -- ADO parameters ---------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'ado')]
        [string]$AdoUsername,

        [Parameter(Mandatory = $true, ParameterSetName = 'ado')]
        [string]$AdoPassword,

        # -- AWS parameters ---------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'aws')]
        [string]$AwsAccessKeyID,

        [Parameter(Mandatory = $true, ParameterSetName = 'aws')]
        [string]$AwsSecureAccessKey,

        # -- Azure parameters -------------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'azure')]
        [string]$AzureSecureKey,

        [Parameter(Mandatory = $true, ParameterSetName = 'azure')]
        [string]$AzureTenantID,

        [Parameter(Mandatory = $true, ParameterSetName = 'azure')]
        [string]$AzureClientID,

        [Parameter(ParameterSetName = 'azure')]
        [string]$AzureEnrollmentNumber = '',

        [Parameter(ParameterSetName = 'azure')]
        [string]$AzureEnrollmentAccessKey = '',

        # -- Redfish parameters -----------------------------------------------
        [Parameter(Mandatory = $true, ParameterSetName = 'redfish')]
        [string]$RedfishUsername,

        [Parameter(Mandatory = $true, ParameterSetName = 'redfish')]
        [string]$RedfishPassword,

        [Parameter(ParameterSetName = 'redfish')]
        [string]$RedfishProtocol = 'HTTPS',

        [Parameter(ParameterSetName = 'redfish')]
        [string]$RedfishPort = '443',

        [Parameter(ParameterSetName = 'redfish')]
        [string]$RedfishTimeout = '15',

        [Parameter(ParameterSetName = 'redfish')]
        [string]$RedfishRetries = '3',

        [Parameter(ParameterSetName = 'redfish')]
        [string]$RedfishIgnoreCertErrors = 'True',

        # -- REST API parameters ----------------------------------------------
        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiUsername = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiPassword = '',

        [Parameter(ParameterSetName = 'restapi')]
        [ValidateSet('0', '1')]
        [string]$RestApiAuthType = '0',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiGrantType = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiAuthorizeUrl = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiTokenUrl = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiClientId = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiClientSecret = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiScope = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiOptionalParams = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiPwdGrantUserName = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiPwdGrantPassword = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiIgnoreCertErrors = '',

        [Parameter(ParameterSetName = 'restapi')]
        [string]$RestApiRefreshToken = '',

        # -- Generic / ByBody fallback ----------------------------------------
        [Parameter(ParameterSetName = 'ByProperties')]
        [object[]]$PropertyBags,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByBody')]
        [string]$Body
    )

    begin {
        Write-Debug "Starting Add-WUGCredential function. ParameterSet: $($PSCmdlet.ParameterSetName)"
        $uri = "${global:WhatsUpServerBaseURI}/api/v1/credentials/-"
    }

    process {
        # Build property bags from typed parameters
        $bags = $null

        switch ($PSCmdlet.ParameterSetName) {

            'snmpV1' {
                $bags = @(
                    @{ name = 'CredSnmpV1:ReadCommunity';  value = "$SnmpReadCommunity" }
                    @{ name = 'CredSnmpV1:WriteCommunity'; value = "$SnmpWriteCommunity" }
                )
            }

            'snmpV2' {
                $bags = @(
                    @{ name = 'CredSnmpV2:ReadCommunity';  value = "$SnmpReadCommunity" }
                    @{ name = 'CredSnmpV2:WriteCommunity'; value = "$SnmpWriteCommunity" }
                )
            }

            'snmpV3' {
                $bags = @(
                    @{ name = 'CredSnmpV3:Username';        value = "$SnmpV3Username" }
                    @{ name = 'CredSnmpV3:Context';         value = "$SnmpV3Context" }
                    @{ name = 'CredSnmpV3:AuthPassword';    value = "$SnmpV3AuthPassword" }
                    @{ name = 'CredSnmpV3:AuthProtocol';    value = "$SnmpV3AuthProtocol" }
                    @{ name = 'CredSnmpV3:EncryptPassword'; value = "$SnmpV3EncryptPassword" }
                    @{ name = 'CredSnmpV3:EncryptProtocol'; value = "$SnmpV3EncryptProtocol" }
                )
            }

            'windows' {
                $bags = @(
                    @{ name = 'CredWindows:DomainAndUserid'; value = "$WindowsUser" }
                    @{ name = 'CredWindows:Password';        value = "$WindowsPassword" }
                )
            }

            'ssh' {
                $enablePw = if ($SshEnablePassword) { $SshEnablePassword } else { $SshPassword }
                $bags = @(
                    @{ name = 'CredSSH:Username';              value = "$SshUsername" }
                    @{ name = 'CredSSH:Password';              value = "$SshPassword" }
                    @{ name = 'CredSSH:ConfirmPassword';       value = "$SshPassword" }
                    @{ name = 'CredSSH:EnablePassword';        value = "$enablePw" }
                    @{ name = 'CredSSH:ConfirmEnablePassword'; value = "$enablePw" }
                    @{ name = 'CredSSH:Timeout';               value = "$SshTimeout" }
                    @{ name = 'CredSSH:Port';                  value = "$SshPort" }
                )
            }

            'ado' {
                $bags = @(
                    @{ name = 'CredADO:Username'; value = "$AdoUsername" }
                    @{ name = 'CredADO:Password'; value = "$AdoPassword" }
                )
            }

            'aws' {
                $bags = @(
                    @{ name = 'CredAWS:AccessKeyID';     value = "$AwsAccessKeyID" }
                    @{ name = 'CredAWS:SecureAccessKey'; value = "$AwsSecureAccessKey" }
                )
            }

            'azure' {
                $bags = @(
                    @{ name = 'CredAzure:SecureKey';            value = "$AzureSecureKey" }
                    @{ name = 'CredAzure:TenantID';             value = "$AzureTenantID" }
                    @{ name = 'CredAzure:ClientID';             value = "$AzureClientID" }
                    @{ name = 'CredAzure:EnrollmentNumber';     value = "$AzureEnrollmentNumber" }
                    @{ name = 'CredAzure:EnrollmentAccessKey'; value = "$AzureEnrollmentAccessKey" }
                )
            }

            'redfish' {
                $bags = @(
                    @{ name = 'CredRedfishBmc:Username';              value = "$RedfishUsername" }
                    @{ name = 'CredRedfishBmc:Password';              value = "$RedfishPassword" }
                    @{ name = 'CredRedfishBmc:Protocol';              value = "$RedfishProtocol" }
                    @{ name = 'CredRedfishBmc:Port';                  value = "$RedfishPort" }
                    @{ name = 'CredRedfishBmc:Timeout';               value = "$RedfishTimeout" }
                    @{ name = 'CredRedfishBmc:Retries';               value = "$RedfishRetries" }
                    @{ name = 'CredRedfishBmc:IgnoreCertificateErrors'; value = "$RedfishIgnoreCertErrors" }
                )
            }

            'restapi' {
                # Build property bags conditionally based on auth type.
                # AuthType '0' = Basic/None (Username + Password only).
                # AuthType '1' = OAuth2 (needs token URL, client creds, etc.).
                # Sending empty OAuth2 bags with Basic auth causes 400 errors.
                $bags = @(
                    @{ name = 'CredRestAPI:Username'; value = "$RestApiUsername" }
                    @{ name = 'CredRestAPI:Password'; value = "$RestApiPassword" }
                    @{ name = 'CredRestAPI:Authtype'; value = "$RestApiAuthType" }
                )
                if ($RestApiAuthType -eq '1') {
                    # OAuth2 fields
                    $bags += @(
                        @{ name = 'CredRestAPI:GrantType';     value = "$RestApiGrantType" }
                        @{ name = 'CredRestAPI:AuthorizeUrl';  value = "$RestApiAuthorizeUrl" }
                        @{ name = 'CredRestAPI:TokenUrl';      value = "$RestApiTokenUrl" }
                        @{ name = 'CredRestAPI:ClientId';      value = "$RestApiClientId" }
                        @{ name = 'CredRestAPI:ClientSecret';  value = "$RestApiClientSecret" }
                        @{ name = 'CredRestAPI:Scope';         value = "$RestApiScope" }
                        @{ name = 'CredRestAPI:OptionalParams';        value = "$RestApiOptionalParams" }
                        @{ name = 'CredRestAPI:PwdGrantUserName';      value = "$RestApiPwdGrantUserName" }
                        @{ name = 'CredRestAPI:PwdGrantPassword';      value = "$RestApiPwdGrantPassword" }
                        @{ name = 'CredRestAPI:RefreshToken';          value = "$RestApiRefreshToken" }
                    )
                }
                # Always include cert-error flag with a valid default
                $certVal = if ($RestApiIgnoreCertErrors) { "$RestApiIgnoreCertErrors" } else { 'False' }
                $bags += @{ name = 'CredRestAPI:IgnoreCertificateErrorsForOAuth2Token'; value = $certVal }
            }

            'ByProperties' {
                $bags = $PropertyBags
            }

            'ByBody' {
                # Body is already set - skip property-bag build
            }
        }

        # Build JSON body from typed parameters
        if ($PSCmdlet.ParameterSetName -ne 'ByBody') {
            $credentialObject = @{
                name        = $Name
                description = if ($Description) { $Description } else { '' }
                type        = switch ($PSCmdlet.ParameterSetName) {
                    'snmpV1'       { 'snmpv1'  }
                    'snmpV2'       { 'snmpv2'  }
                    'snmpV3'       { 'snmpv3'  }
                    'restapi'      { 'rest api' }
                    'ByProperties' { $Type     }
                    default        { $PSCmdlet.ParameterSetName }
                }
                propertyBags = if ($bags) { $bags } else { @() }
            }
            $Body = $credentialObject | ConvertTo-Json -Depth 5
        }

        Write-Debug "POST URI: $uri"
        Write-Debug "Body: [REDACTED - credential payload]"

        if (-not $PSCmdlet.ShouldProcess($Name, 'Add credential')) { return }

        try {
            $result = Get-WUGAPIResponse -Uri $uri -Method 'POST' -Body $Body -MaxRetries 0 -ErrorAction Stop
            if ($result.data) {
                Write-Verbose "Successfully created credential."
                return $result.data
            }
            else {
                return $result
            }
        }
        catch {
            Write-Error "Error creating credential: $_"
        }
    }

    end {
        Write-Debug "Completed Add-WUGCredential function."
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAHmzGhuc2SPYFU
# /2r/s4wYZ7Y3TY0GsnJFOpRUi73iu6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBq
# sZpXkZlDQNO/r3KE7a6d53QIxELacdOb13oLlQvRWDANBgkqhkiG9w0BAQEFAASC
# AgADoiDnHoK0IAcC3mqrK7G9i/B8dJPGPe4AiDZu5R6jnEIQKb99Awj9mVAsHM9o
# amiTOo8AoeVI/oy44/tmnTXf6I7gbtJve/11wR46uUl21meJPDf0pTY6OyDVkp7G
# j79R6wpmQpXZH5V7KIzo/ZmaoV6zpg/VOkjtjQDlgMPY6Ro9UXPLQ9uGuOBu7jD7
# +tQlMLx+XtBjBLXhCJlOttuoox/TcIiklMaoF2bLhJK/rTH9rGF9aAS4xXuhSUMy
# xMy50cG+ehMVTEax+TS7yD2UJCq6DUwQtSgIX0I2nl4vAdryI6KhwcfEcW+dBmTY
# yPFZXFLjXMwSIPdw0Latg/ckj2XVriv7fQA8W5PWiGrVVZ8I/GXbvk97qPzsmtpD
# TP42wopdPlvGZ8An7RlOps+ONEGdOElYhaNupdahXIpM5MCZ5JxeA7Xyq3SksTBj
# Voj6GwhJf2Ad/VL/X9cSgtDjiYXRbQBN81tKPPabIBS0xrrwtH8GVw+Ln7iI2x8p
# GTOdY5SqPrf+T1i13zQkfO4h+aSemqsfdMb6gBdx0+JcEZdLiMrcpp7HNHSRmgdu
# pALedFdRL0HQ0GCnFD4Lc1NzeHEE7nhZ+uAuiFeCNwD/Mi4wW36SbQn3NG4Oy462
# FEq32LPu9X/CzGDj4PRaHMHw8b6llhxotjtqjsweI6pFHKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MjZaMC8GCSqGSIb3DQEJBDEiBCDXtpZd+OKT
# ARh//A22aBIgXtppDBiC6FltSaJJ5gUB2TANBgkqhkiG9w0BAQEFAASCAgCvjAAC
# rWn8HgtcCkEqXP5wekCF3RElwBzQmF7F1moZMJHRdFBdfruRq8Cuuman2LtlAhti
# 1Vg8kYlEoAhncsxBhVdfMMHXTy6cZyGnDxYo0ZY6q1z+hkXHb3/h5QotVmP9T2lC
# IH1bjavR1Z9C6wBa7O/jr52OFQi42gdyq0EbOl9pg/PgUiHdkCeAJogSA//pVNfN
# gtuWKgRGxf7Cgqdel/PV4JLffTEO73UF5Knql5WI8RCX03l236aptJEOm+qlbFUD
# F/6WXJHO1TgE1DPrCYM+7KOgTtXxeFAFjPBmhpigcOhYbDkdV8ucZ5jHPgmfmWBp
# EWsG83/MZlb4Q/BcNah8p8lU6NbDtDRFcsIIErpbdzKzoQ5m6cMDczHxvbOv7kii
# +E50bMSQrOgEz80byDnr4Pw5ansknXOxl3PT2IsBdtFQjJz1WXQAkX+BKYNR8rcx
# jLMISy7a8por//LG5RGUzMJ3eD+W+RHWeUOj+IPCzhdF5QjVea+qkWy83SCJ2El0
# xWvj7dj1PE0MHW3I0Lmo6t9Y8JSHLttIEL1JBjBglzICFo86yj+geXreQ9IYgCV+
# fgCMsPkat9Ino8HyUmr0oNsou6B9DnbssgnDrzFwNufgBh3lBEyEfoVgIrcXOw5b
# Fai0fRcSD4PryquPNG41JSiz9wop9fbxq4Ymrg==
# SIG # End signature block
