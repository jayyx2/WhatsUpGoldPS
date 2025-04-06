<#
EXAMPLES
Add-WUGActiveMonitor -Type SNMP -Name 20241019-snmpmonitor-test-1-new -SnmpOID 1.3.6.1 -SnmpInstance 1 -SnmpCheckType constant -SnmpValue 9
Add-WUGActiveMonitor -Type Ping -Name "9999 ping" -PingPayloadSize 9999 -Timeout 10 -Retries 1
Add-WUGActiveMonitor -Type TcpIp -Name TestTCPIpMon-2024-10-19 -Timeout 5 -TcpIpPort 8443 -TcpIpProtocol SSL
Add-WUGActiveMonitor -Type Certificate -Name Certmo  ntest-20241020 -CertOption url -CertPath https://www.google.com/ -CertExpiresDays 10 -CertCheckUsage $true
Add-WUGActiveMonitor -Type WMIFormatted -Name "AD LDAP Bind Time RangeCheck" -WMIFormattedRelativePath "Win32_PerfFormattedData_NTDS_NTDS" -WMIFormattedPerformanceCounter "LDAP Bind Time (msec)" -WMIFormattedPerformanceInstance "NULL" -WMIFormattedCheckType "range" -WMIFormattedRangeLowValue 0 -WMIFormattedRangeHighValue 200 -WMIFormattedPropertyName "LDAPBindTime" -WMIFormattedComputerName "localhost"

#>
function Add-WUGActiveMonitor {
    [CmdletBinding(DefaultParameterSetName = 'Ping')]
    param(
        # Common Parameters
        [Parameter(Mandatory = $true, ParameterSetName = 'Ping')]
        [Parameter(Mandatory = $true, ParameterSetName = 'TcpIp')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ConstantOrRate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Process')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Service')]
        [Parameter(Mandatory = $true, ParameterSetName = 'WMIFormatted')]      
        [ValidateSet('Ping', 'TcpIp', 'SNMP', 'Process', 'Certificate', 'Service', 'WMIFormatted')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        # Shared Parameters
        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$Timeout = 5,

        [Parameter()]
        [ValidateRange(1, 5)]
        [int]$Retries = 1,

        # Service Monitor Parameters
        [Parameter(ParameterSetName = 'Service')]
        [string]$ServiceDisplayName,
        [Parameter(ParameterSetName = 'Service')]
        [string]$ServiceInternalName,
        [Parameter(ParameterSetName = 'Service')]
        [bool]$ServiceUseSNMP = $false,
        [Parameter(ParameterSetName = 'Service')]
        [int]$ServiceSNMPRetries = 1,
        [Parameter(ParameterSetName = 'Service')]
        [int]$ServiceSNMPTimeout = 3,
        [Parameter(ParameterSetName = 'Service')]
        [int]$ServiceRestartOnFailure = 0,

        # Ping Monitor Parameters
        [Parameter(ParameterSetName = 'Ping')]
        [ValidateRange(1, 65535)]
        [int]$PingPayloadSize = 32,

        # TCP/IP Monitor Parameters
        [Parameter(ParameterSetName = 'TcpIp')]
        [ValidateRange(1, 65535)]
        [int]$TcpIpPort,
        [Parameter(ParameterSetName = 'TcpIp')]
        [ValidateSet('TCP', 'UDP', 'SSL')]
        [string]$TcpIpProtocol,
        [Parameter(ParameterSetName = 'TcpIp')]
        [string]$TcpIpScript = "",

        # Certificate Monitor Parameters
        [Parameter(ParameterSetName = 'Certificate')]
        [ValidateSet('url', 'file')]
        [string]$CertOption,
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertPath, # URL or File Path
        [Parameter(ParameterSetName = 'Certificate')]
        [int]$CertExpiresDays = 5,
        [Parameter(ParameterSetName = 'Certificate')]
        [bool]$CertCheckUsage = $false,
        [Parameter(ParameterSetName = 'Certificate')]
        [bool]$CertCheckExpires = $true, # New parameter with default value
        [Parameter(ParameterSetName = 'Certificate')]
        [bool]$CertUseProxySettings = $false,
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertProxyServer = "",
        [Parameter(ParameterSetName = 'Certificate')]
        [int]$CertProxyPort = 0,
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertProxyUser = "",
        [Parameter(ParameterSetName = 'Certificate')]
        [string]$CertProxyPwd = "",

        # SNMP Monitor Parameters
        [Parameter(ParameterSetName = 'ConstantOrRate')]
        [Parameter(ParameterSetName = 'Range')]
        [string]$SnmpOID,
        [Parameter(ParameterSetName = 'ConstantOrRate')]
        [Parameter(ParameterSetName = 'Range')]
        [string]$SnmpInstance = "",
        [Parameter(ParameterSetName = 'ConstantOrRate')]
        [Parameter(ParameterSetName = 'Range')]
        [ValidateSet('constant', 'range', 'rateofchange')]
        [string]$SnmpCheckType,

        # Parameters for SNMP monitor constant or rateofchange
        [Parameter(ParameterSetName = 'ConstantOrRate', Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SnmpValue,
        # Parameters for SNMP monitor range check type
        [Parameter(ParameterSetName = 'Range', Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SnmpLowValue,
        [Parameter(ParameterSetName = 'Range', Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SnmpHighValue,

        # Process Monitor Parameters
        [Parameter(ParameterSetName = 'Process')]
        [string]$ProcessName,        
        [Parameter(ParameterSetName = 'Process')]
        [ValidateSet('true', 'false')]
        [string]$ProcessDownIfRunning = 'false',        
        [Parameter(ParameterSetName = 'Process')]
        [bool]$ProcessUseWMI = $false,
        
        # WMIFormatted Monitor Parameters
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedRelativePath,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedPerformanceCounter,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedPerformanceInstance,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedCheckType, # 'constant', 'range', or 'rateofchange'
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedConstantValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [bool]$WMIFormattedConstantUpIfMatch = $true,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedRangeLowValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedRangeHighValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [int]$WMIFormattedROCValue,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [bool]$WMIFormattedROCUpIfAbove = $true,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedPropertyName,
        [Parameter(ParameterSetName = 'WMIFormatted')]
        [string]$WMIFormattedComputerName
    )

    begin {
        Write-Debug "Initializing Add-WUGActiveMonitor function with Type: $Type"
        $baseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"
        $ClassId = ""
        $PropertyBags = @()
        $skipCreation = $false

        # Check if the monitor already exists
        Write-Verbose "Checking if monitor with name '${Name}' already exists."
        $existingMonitorUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-?type=active&view=details&search=$([uri]::EscapeDataString(${Name}))"

        try {
            $existingMonitorResult = Get-WUGAPIResponse -Uri $existingMonitorUri -Method GET -ErrorAction Stop
            if ($existingMonitorResult.data.activeMonitors | Where-Object { $_.name -eq $Name }) {
                Write-Host "Monitor with the name '$Name' already exists. Skipping creation." -ForegroundColor Yellow
                $skipCreation = $true
                return
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Host "No existing monitor found with the name '$Name'. Proceeding with creation." -ForegroundColor Green
            }
            else {
                Write-Warning "Failed to check for existing monitors: $($_.Exception.Message)"
                return
            }
        }

        # Monitor-specific setup
        switch ($Type) {
            'Ping' {
                $ClassId = '2655476e-36b0-455f-9cce-940b6f8e07bf'
                $PropertyBags = @(
                    @{ "name" = "Timeout"; "value" = "$Timeout" },
                    @{ "name" = "Retries"; "value" = "$Retries" },
                    @{ "name" = "PayloadSize"; "value" = "$PingPayloadSize" }
                )
            }
            'TcpIp' {
                $ClassId = '1ee6ecd4-4c17-4ccc-8ff8-3147f445943f'
                $PropertyBags = @(
                    @{ "name" = "Timeout"; "value" = "$Timeout" },
                    @{ "name" = "Protocol"; "value" = "$TcpIpProtocol" },
                    @{ "name" = "Port"; "value" = "$TcpIpPort" },
                    @{ "name" = "Script"; "value" = "$TcpIpScript" }
                )
            }
            'SNMP' {
                $ClassId = 'd6d02d69-a418-483a-93ea-20dd2af2d135'
                $SnmpCheckTypeValue = switch ($SnmpCheckType) {
                    'constant' { 0 }
                    'range' { 1 }
                    'rateofchange' { 2 }
                }

                if ($SnmpCheckType -eq 'range') {
                    $PropertyBags = @(
                        @{ "name" = "SNMP:CheckType"; "value" = "$SnmpCheckTypeValue" },
                        @{ "name" = "SNMP:OID"; "value" = "$SnmpOID" },
                        @{ "name" = "SNMP:Instance"; "value" = "$SnmpInstance" },
                        @{ "name" = "SNMP:Range-LowValue"; "value" = "$SnmpLowValue" },
                        @{ "name" = "SNMP:Range-HighValue"; "value" = "$SnmpHighValue" }
                    )
                }
                else {
                    $PropertyBags = @(
                        @{ "name" = "SNMP:CheckType"; "value" = "$SnmpCheckTypeValue" },
                        @{ "name" = "SNMP:OID"; "value" = "$SnmpOID" },
                        @{ "name" = "SNMP:Instance"; "value" = "$SnmpInstance" },
                        @{ "name" = "SNMP:Constant-Value"; "value" = "$SnmpValue" }
                    )
                }
            }
                'Process' {
                $ClassId = '92c56b83-d6a7-43a4-a094-8fe5f8fa4b2c'
                $ProcessRunningStatus = if ($ProcessDownIfRunning -eq 'true') { 1 } else { 4 }
                $ProcessThresholdsXml = @"
<?xml version="1.0" encoding="utf-16"?>
<ProcessThresholds xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Name>ProcessThresholds</Name>
  <Thresholds>
    <Threshold xsi:type="StatusThreshold">
      <Checked>true</Checked>
      <Type>1</Type>
      <RunningStatus>$ProcessRunningStatus</RunningStatus>
    </Threshold>
  </Thresholds>
</ProcessThresholds>
"@
                $PropertyBags = @(
                    @{ "name" = "MonProcess:ProcessName"; "value" = "$ProcessName" },
                    @{ "name" = "MonProcess:UseWMI"; "value" = "$ProcessUseWMI" },
                    @{ "name" = "MonProcess:SnmpNumRetries"; "value" = "$Retries" },
                    @{ "name" = "MonProcess:SnmpTimeoutMs"; "value" = ($Timeout * 1000) },
                    @{ "name" = "MonProcess:ProcessThresholds"; "value" = $ProcessThresholdsXml.Trim() }
                )
                }
        
            'Certificate' {
                $ClassId = 'de27943b-b036-4b6d-ae4c-1093b210c233'
                if($CertCheckUsage) {$CertCheckUsage = "true"} else {$CertCheckUsage = "false"}
                if($CertCheckExpires) {$CertCheckExpires = "true"} else {$CertCheckExpires = "false"}
                if($CertUseProxySettings) {$CertUseProxySettings = "true"} else {$CertUseProxySettings = "false"}
                $PropertyBags = @(
                    @{ "name" = "MonSSLCert:CertificateOption"; "value" = "$CertOption" },
                    @{ "name" = "MonSSLCert:Path"; "value" = "$CertPath" },
                    @{ "name" = "MonSSLCert:ExpiresDays"; "value" = "$CertExpiresDays" },
                    @{ "name" = "MonSSLCert:CheckUsage"; "value" = "$CertCheckUsage" },
                    @{ "name" = "MonSSLCert:UseProxySettings"; "value" = "$CertUseProxySettings" },
                    @{ "name" = "MonSSLCert:Timeout"; "value" = "$Timeout" }
                )
                if ($CertUseProxySettings) {
                    $PropertyBags += @(
                        @{ "name" = "MonSSLCert:ProxyServer"; "value" = "$CertProxyServer" },
                        @{ "name" = "MonSSLCert:ProxyPort"; "value" = "$CertProxyPort" },
                        @{ "name" = "MonSSLCert:ProxyUser"; "value" = "$CertProxyUser" },
                        @{ "name" = "MonSSLCert:ProxyPassword"; "value" = "$CertProxyPwd" }
                    )
                }
            }

            'Service' {
                $ClassId = '20816756-7dd5-4400-adb8-63d9c2147b97'
                $SNMPFlag = if ($ServiceUseSNMP) { 1 } else { 0 }

                $PropertyBags = @(
                    @{ "name" = "Cred:Type"; "value" = "1,2,4,8" },
                    @{ "name" = "NTSERVICE:RestartOnFailure"; "value" = "$ServiceRestartOnFailure" },
                    @{ "name" = "NTSERVICE:ServiceDisplayName"; "value" = "$ServiceDisplayName" },
                    @{ "name" = "NTSERVICE:ServiceInternalName"; "value" = "$ServiceInternalName" },
                    @{ "name" = "NTSERVICE:SNMPRetries"; "value" = "$ServiceSNMPRetries" },
                    @{ "name" = "NTSERVICE:SNMPTimeout"; "value" = "$ServiceSNMPTimeout" },
                    @{ "name" = "NTSERVICE:UseSNMP"; "value" = "$SNMPFlag" }
                )
            }
            
            'WMIFormatted' {
                $ClassId = "67a03c83-7166-405d-b9e7-0433b8b81a61"  # CLSID for WMIFormatted Monitor
                # Derive a friendly object name for the display
                if ($WMIFormattedRelativePath -like "Win32_PerfFormattedData_*_*") {
                    $objectName = $WMIFormattedRelativePath.Substring($WMIFormattedRelativePath.LastIndexOf("_") + 1)
                }
                else { 
                    $objectName = $WMIFormattedRelativePath
                }
                
                # If no instance is specified (or if user wants "NULL"), we display NULL
                if (-not $WMIFormattedPerformanceInstance -or $WMIFormattedPerformanceInstance -eq 'NULL') {
                    $actualInstance = 'NULL'
                }
                else {
                    $actualInstance = $WMIFormattedPerformanceInstance
                }

                # Use a single backslash for Displayname (objectName \ counter)
                $WMIFormattedDisplayName = "$objectName \ $WMIFormattedPerformanceCounter"

                # Handle missing numeric parameters cleanly
                $RangeLowValue = if ($PSBoundParameters.ContainsKey('WMIFormattedRangeLowValue')) { $WMIFormattedRangeLowValue } else { "" }
                $RangeHighValue = if ($PSBoundParameters.ContainsKey('WMIFormattedRangeHighValue')) { $WMIFormattedRangeHighValue } else { "" }
                $ConstantValue = if ($PSBoundParameters.ContainsKey('WMIFormattedConstantValue')) { $WMIFormattedConstantValue }  else { "" }
                $ROCValue = if ($PSBoundParameters.ContainsKey('WMIFormattedROCValue')) { $WMIFormattedROCValue }       else { "" }

                # Set CheckType based on input
                $CheckTypeValue = switch ($WMIFormattedCheckType) {
                    'constant' { "0" }
                    'range' { "1" }
                    'rateofchange' { "2" }
                }

                # Determine the ROC-UpIfAboveValue only if using rate-of-change
                if ($WMIFormattedCheckType -eq 'rateofchange') {
                    # If user provided WMIFormattedROCUpIfAbove, respect it; otherwise default to '0'
                    $ROCUpIfAboveValue = if ($PSBoundParameters.ContainsKey('WMIFormattedROCUpIfAbove')) {if ($WMIFormattedROCUpIfAbove) { "0" } else { "1" }} else {"0"}}
                else {
                    $ROCUpIfAboveValue = ""
                }

                # Determine ConstantUpIfMatchValue (defaults to "0" if not specified)
                $ConstantUpIfMatchValue = if ($PSBoundParameters.ContainsKey('WMIFormattedConstantUpIfMatch')) {
                    if ($WMIFormattedConstantUpIfMatch) { "0" } else { "1" }
                }
                else {
                    "0"
                }

                $PropertyBags = @(
                    @{ "name" = "WMI:Formatted-Counter-Displayname"; "value" = $WMIFormattedDisplayName },
                    @{ "name" = "WMI:Formatted-Counter-InstanceName"; "value" = $actualInstance },
                    @{ "name" = "WMI:Formatted-Counter-RelativePath"; "value" = $WMIFormattedRelativePath },
                    @{ "name" = "WMI:Formatted-Credential-Type"; "value" = "8" },
                    @{ "name" = "WMI:Formatted-Counter-Username"; "value" = "" },
                    @{ "name" = "WMI:Formatted-Counter-Password"; "value" = "" },
                    @{ "name" = "WMI:Formatted-Counter-ComputerName"; "value" = $WMIFormattedComputerName },
                    @{ "name" = "WMI:Formatted-Counter-PropertyName"; "value" = $WMIFormattedPropertyName },
                    @{ "name" = "WMI:Formatted-Range-LowValue"; "value" = $RangeLowValue },
                    @{ "name" = "WMI:Formatted-Range-HighValue"; "value" = $RangeHighValue },
                    @{ "name" = "WMI:Formatted-Rescan-Usage"; "value" = "0" },
                    @{ "name" = "WMI:Formatted-Counter-CheckType"; "value" = $CheckTypeValue },
                    @{ "name" = "WMI:Formatted-Constant-Value"; "value" = $ConstantValue },
                    @{ "name" = "WMI:Formatted-Constant-UpIfMatchValue"; "value" = $ConstantUpIfMatchValue },
                    @{ "name" = "WMI:Formatted-ROC-Value"; "value" = $ROCValue },
                    @{ "name" = "WMI:Formatted-ROC-UpIfAboveValue"; "value" = $ROCUpIfAboveValue }
                )
            }


        }

    }

            process {
                if ($skipCreation) {
                    Write-Host "Skipping monitor creation." -ForegroundColor Yellow
                    return
                }

                Write-Verbose "Creating monitor: $Name"
                $payload = @{
                    "allowSystemMonitorCreation" = $true
                    "name"                       = $Name
                    "description"                = "$Type Monitor created via Add-WUGActiveMonitor function"
                    "monitorTypeInfo"            = @{
                        "baseType" = "active"
                        "classId"  = $ClassId
                    }
                    "propertyBags"               = $PropertyBags
                    "useInDiscovery"             = $UseInDiscovery
                }

                $jsonPayload = $payload | ConvertTo-Json -Compress
                Write-Verbose "Posting payload: $jsonPayload"

                try {
                    $result = Get-WUGAPIResponse -Uri $baseUri -Method POST -Body $jsonPayload
                    if ($result.data.successful -eq 1) {
                        Write-Output "Successfully created $Type monitor: $Name"
                    }
                    else {
                        Write-Warning "Failed to create monitor template."
                    }
                }
                catch {
                    Write-Error "Error creating monitor template: $($_.Exception.Message)"
                }
                
            }
        

            end {
                Write-Debug "Add-WUGActiveMonitor function completed."
            }
        }
# SIG # Begin signature block
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBfpY5VAWFLXN/U
# xVIsQltXIITSh8noiuOclsg2jv/JaKCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# L9Uo2bC5a4CH2RwwggZkMIIEzKADAgECAhEA6IUbK/8zRw2NKvPg4jKHsTANBgkq
# hkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1p
# dGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgQ0EgUjM2
# MB4XDTIzMDQxOTAwMDAwMFoXDTI2MDcxODIzNTk1OVowVTELMAkGA1UEBhMCVVMx
# FDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNvbiBBbGJlcmlubzEX
# MBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQC2JA01BehqpO3INejKVsKScaS9sd0Hjoz1tceFig6Yyu2glTKimH9n
# r9l5438Cjpc1x+n42gMfnS5Cza4tZUWr1usOq3d0TljKFOOSW8Uve1J+PC0f/Hxp
# DbI8hE38ICDmgv8EozBOgo4lPm/rDHVTHgiRZvy1H8gPTuE13ck2sevVslku2E2F
# 8wst5Kb12OqngF96RXptEeM0iTipPhfNinWCa8e58+mbt1dHCbX46593DRd3yQv+
# rvPkIh9QkMGmumfjV5lv1S3iqf/Vg6XP9R3lTPMWNO2IEzIjk12t817rU3xYyf2Q
# 4dlA/i1bRpFfjEVcxQiZJdQKnQlqd3hOk0tr8bxTI3RZxgOLRgC8mA9hgcnJmreM
# WP4CwXZUKKX13pMqzrX/qiSUsB+Mvcn7LHGEo9pJIBgMItZW4zn4uPzGbf53EQUW
# nPfUOSBdgkRAdkb/c7Lkhhc1HNPWlUqzS/tdopI7+TzNsYr7qEckXpumBlUSONoJ
# n2V1zukFbgsBq0mRWSZf+ut3OVGo7zSYopsMXSIPFEaBcxNuvcZQXv6YdXEsDpvG
# mysbgVa/7uP3KwH9h79WeFU/TiGEISH5B59qTg26+GMRqhyZoYHj7wI36omwSNja
# tUo5cYz4AEYTO58gceMcztNO45BynLwPbZwZ0bxPN2wL1ruIYd+ewQIDAQABo4IB
# rjCCAaowHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhekzQwwHQYDVR0OBBYE
# FJHuVIzRubayI0tfw82Q7Q/47iu9MA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8E
# AjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEwNQYMKwYBBAGyMQEC
# AQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeB
# DAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNlY3RpZ28uY29tL1Nl
# Y3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5BggrBgEFBQcBAQRtMGsw
# RAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1Ymxp
# Y0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5z
# ZWN0aWdvLmNvbTAjBgNVHREEHDAagRhqYXNvbi5hbGJlcmlub0BnbWFpbC5jb20w
# DQYJKoZIhvcNAQEMBQADggGBAET0EFH0r+hqoQWr4Ha9UDuEv28rTgV2aao1nFRg
# GZ/5owM7x9lxappLUbgQFfeIzzAsp3gwTKMYf47njUjvOBZD9zV/3I/vaLmY2enm
# MXZ48Om9GW4pNmnvsef2Ub1/+dRzgs8UFX5wBJcfy4OWP3t0OaKJkn+ZltgFF1cu
# L/RPiWSRcZuhh7dIWgoPQrVx8BtC8pkh4F5ECxogQnlaDNBzGYf1UYNfEQOFec31
# UK8oENwWx5/EaKFrSi9Y4tu6rkpH0idmYds/1fvqApGxujhvCO4Se8Atfc98icX4
# DWkc1QILREHiVinmoO3smmjB5wumgP45p9OVJXhI0D0gUFQfOSappa5eO2lbnNVG
# 90rCsADmVpDDmNt2qPG01luBbX6VtWMP2thjP5/CWvUy6+xfrhlqvwZyZt3SKtuf
# FWkqnNWMnmgtBNSmBF5+q8w5SJW+24qrncKJWSIim/nRtC11XnoI9SXlaucS3Nlb
# crQVicXOtbhksEqMTn52i8NOfzGCAxswggMXAgEBMGkwVDELMAkGA1UEBhMCR0Ix
# GDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJs
# aWMgQ29kZSBTaWduaW5nIENBIFIzNgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJYIZI
# AWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAv
# BgkqhkiG9w0BCQQxIgQg6IK99Q3I8HNVXaST2FOBOZHFtMQ4uRWNQ+Z3JKNx0zIw
# DQYJKoZIhvcNAQEBBQAEggIAJ4+dSAudjM5ylbYfTlOtAEz+3Fe3dFC2q5vB3ujC
# O+utK1+oaBGOGAyu2oHrcS8Q0efU74H4li5fE68c9oXbBmA6Nz3w1K5R62auOprJ
# eUa6wtVKGbPqA95J3oxwmL08GQL6WP+8zqU0kFOoLOw/ey6FF3wTf+ijMki6Z0gF
# ELGuLSF2+eI/u5MiYchkDbIt4bNOQK2EaNOeuERyDMQEcTJwEwjm8mQN5QQrcc+s
# KTeiCnnRC/z5Zpw5nKoogl7SeU4b+JJWLMI37ZtYgQbgXqdLzQ3mygeRpUFhzRaf
# CkSPi48OITwt2sCDQgWSMWtfO7bKV/qkPDPg5E4DcE0BQZkyZBNXLU28HYTW5lR7
# iHuOqBJ4XJk+UFZrmIuC02g6hsuks57vjI0xp+vG+txGKdv/XY/xOZz4YTRi6XyW
# C38v2AHACf0Nd/1JwyA2kmqx3R3BvZN0j3sMQpIeLr5tbmwBdwKNSOK9miv4h2Jt
# wUMXbopWI460MpsZZqdjCEzL7PGV/KYUo35h0Edv7h8poiARwn5kWXP7TZ+3JD73
# 0s1dZCCDArxqLXMqzccXt3ckZOWaB9uDDP8X0AZwvfxTYIyxc+Gk2SnsF3SRDmlX
# Q2aJUnX0lhZqF/hh9wfMZHhVU5xeOJCI6KUwMNc9RD5rb53PYcsIMSSCbw+AyxyX
# WOM=
# SIG # End signature block
