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
#   snmpv1   → CredSnmpV1:ReadCommunity, WriteCommunity
#   snmpv2   → CredSnmpV2:ReadCommunity, WriteCommunity
#   snmpv3   → CredSnmpV3:Username, Context, AuthPassword, AuthProtocol, EncryptPassword, EncryptProtocol
#   windows  → CredWindows:DomainAndUserid, Password
#   ssh      → CredSSH:Username, Password, ConfirmPassword, EnablePassword, ConfirmEnablePassword, Timeout, Port
#   ado      → CredADO:Username, Password
#   aws      → CredAWS:AccessKeyID, SecureAccessKey
#   azure    → CredAzure:SecureKey, TenantID, ClientID, EnrollmentNumber, EnrollmentAccessKey
#   redfish  → CredRedfishBmc:Username, Password, Protocol, Port, Timeout, Retries, IgnoreCertificateErrors
#   restapi  → CredRestAPI:Username, Password, Authtype, GrantType, AuthorizeUrl, TokenUrl,
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
    (restapi) OAuth2 grant type. 1=Password, 2=AuthorizationCode. Default: empty.

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
        # ── Common parameters (all typed parameter sets) ─────────────────────
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

        # ── SNMP v1 / v2 parameters ─────────────────────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV1')]
        [Parameter(Mandatory = $true, ParameterSetName = 'snmpV2')]
        [string]$SnmpReadCommunity,

        [Parameter(ParameterSetName = 'snmpV1')]
        [Parameter(ParameterSetName = 'snmpV2')]
        [string]$SnmpWriteCommunity = '',

        # ── SNMP v3 parameters ───────────────────────────────────────────────
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

        # ── Windows parameters ───────────────────────────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'windows')]
        [string]$WindowsUser,

        [Parameter(Mandatory = $true, ParameterSetName = 'windows')]
        [string]$WindowsPassword,

        # ── SSH parameters ───────────────────────────────────────────────────
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

        # ── ADO parameters ───────────────────────────────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'ado')]
        [string]$AdoUsername,

        [Parameter(Mandatory = $true, ParameterSetName = 'ado')]
        [string]$AdoPassword,

        # ── AWS parameters ───────────────────────────────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'aws')]
        [string]$AwsAccessKeyID,

        [Parameter(Mandatory = $true, ParameterSetName = 'aws')]
        [string]$AwsSecureAccessKey,

        # ── Azure parameters ─────────────────────────────────────────────────
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

        # ── Redfish parameters ───────────────────────────────────────────────
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

        # ── REST API parameters ──────────────────────────────────────────────
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

        # ── Generic / ByBody fallback ────────────────────────────────────────
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
                $bags = @(
                    @{ name = 'CredRestAPI:Username';                              value = "$RestApiUsername" }
                    @{ name = 'CredRestAPI:Password';                              value = "$RestApiPassword" }
                    @{ name = 'CredRestAPI:Authtype';                              value = "$RestApiAuthType" }
                    @{ name = 'CredRestAPI:GrantType';                             value = "$RestApiGrantType" }
                    @{ name = 'CredRestAPI:AuthorizeUrl';                          value = "$RestApiAuthorizeUrl" }
                    @{ name = 'CredRestAPI:TokenUrl';                              value = "$RestApiTokenUrl" }
                    @{ name = 'CredRestAPI:ClientId';                              value = "$RestApiClientId" }
                    @{ name = 'CredRestAPI:ClientSecret';                          value = "$RestApiClientSecret" }
                    @{ name = 'CredRestAPI:Scope';                                 value = "$RestApiScope" }
                    @{ name = 'CredRestAPI:OptionalParams';                        value = "$RestApiOptionalParams" }
                    @{ name = 'CredRestAPI:PwdGrantUserName';                      value = "$RestApiPwdGrantUserName" }
                    @{ name = 'CredRestAPI:PwdGrantPassword';                      value = "$RestApiPwdGrantPassword" }
                    @{ name = 'CredRestAPI:IgnoreCertificateErrorsForOAuth2Token'; value = "$RestApiIgnoreCertErrors" }
                    @{ name = 'CredRestAPI:RefreshToken';                          value = "$RestApiRefreshToken" }
                )
            }

            'ByProperties' {
                $bags = $PropertyBags
            }

            'ByBody' {
                # Body is already set — skip property-bag build
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
                    'ByProperties' { $Type     }
                    default        { $PSCmdlet.ParameterSetName }
                }
                propertyBags = if ($bags) { $bags } else { @() }
            }
            $Body = $credentialObject | ConvertTo-Json -Depth 5
        }

        Write-Debug "POST URI: $uri"
        Write-Debug "Body: $Body"

        if (-not $PSCmdlet.ShouldProcess($Name, 'Add credential')) { return }

        try {
            $result = Get-WUGAPIResponse -Uri $uri -Method 'POST' -Body $Body
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAEi69z8ktEz8YL
# 8w1hk6t47UJG3oKH8P2vMHUn/JeavKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgti/gDPJ2SFCJJ8tuvP6if6uXhwm/HRvR
# 8pQsJYPcFoUwDQYJKoZIhvcNAQEBBQAEggIAZzIIokfrJRBtwlW53UO4X9ucx3hF
# yj7oSlLh2nksjUbFNT0Tko7DStGAC02MPy7cwccadR8TJvdlK61o7VQWA12EE9nz
# xOGH9ZgIugBwVuVYw3niB7gb31LY7RefdcOfp9ZP2pCAKh92um8xMQ1/pFcgNA9k
# sU8wLEVnDCbp24q2lUlUqy56STX9gZS+leVxBIfs7y+AFy69nBGb3b577asat/nS
# i1DjETSz2gqmrfUjZqiKMG6VATaP2JIhaOr2w6U8TIAaukwXEh+idnUxrHo2DRW1
# GDInw5CpFP2AD9BQit4CfguQ3Xt1HyyH+o/uMGYxFs2W5uOiRczzHiqq4lVfpVrl
# w3fZlX08W5hPWdQ0tbN3BaOaAsZAh/ODrJ2z2U1WOtBcTkZ2y3dCVcrfa/WeF2Lf
# n/atpoW39BE3/9b6SlNaWHkjFeJn9ieboXyy6Ne7QLBo11DEsmu4e/N5YZH1zYzP
# W+L27EJ7m+iYOqOjpgl0bUNuspGGsnQLl3eErFC1fC84F/dcHqYTstQMoQI5buvM
# 4LvPVsWvdhfnxECdpfsKoHACrv8Tk/RY+SSPmZhwW/J/SL4hCvYFRn3GIY6n8IwW
# sah/IrI939J9jTMHV8BR4mTFyvnpp7U0rf1+709VDBEVtVzQtMUoSw7Xop7n/GX4
# xZCbGbFpvXvijpE=
# SIG # End signature block
