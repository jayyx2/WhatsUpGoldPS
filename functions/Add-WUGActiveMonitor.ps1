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
# MIIVkQYJKoZIhvcNAQcCoIIVgjCCFX4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUmZ4YFleKLRIQERZt7QYrV1SI
# njygghH5MIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
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
# 1FiAhORFe1rYMIIGGjCCBAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG
# 9w0BAQwFADBWMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk
# MS0wKwYDVQQDEyRTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYw
# HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1Ymxp
# YyBDb2RlIFNpZ25pbmcgQ0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIB
# igKCAYEAmyudU/o1P45gBkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxD
# eEDIArCS2VCoVk4Y/8j6stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk
# 9vT0k2oWJMJjL9G//N523hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7Xw
# iunD7mBxNtecM6ytIdUlh08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ
# 0arWZVeffvMr/iiIROSCzKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZX
# nYvZQgWx/SXiJDRSAolRzZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+t
# AfiWu01TPhCr9VrkxsHC5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvr
# n35XGf2RPaNTO2uSZ6n9otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn
# 3UayWW9bAgMBAAGjggFkMIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaR
# XBeF5jAdBgNVHQ4EFgQUDyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYD
# VR0gBBQwEjAGBgRVHSAAMAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRw
# Oi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RS
# NDYuY3JsMHsGCCsGAQUFBwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAj
# BggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEM
# BQADggIBAAb/guF3YzZue6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXK
# ZDk8+Y1LoNqHrp22AKMGxQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWk
# vfPkKaAQsiqaT9DnMWBHVNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3d
# MapandPfYgoZ8iDL2OR3sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwF
# kvjFV3jS49ZSc4lShKK6BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZa
# PATHvNIzt+z1PHo35D/f7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8b
# kinLrYrKpii+Tk7pwL7TjRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7Ew
# oIJB0kak6pSzEu4I64U6gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TW
# SenLbjBQUGR96cFr6lEUfAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg
# 51Tbnio1lB93079WPFnYaOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoU
# KD85gnJ+t0smrWrb8dee2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGZDCCBMyg
# AwIBAgIRAOiFGyv/M0cNjSrz4OIyh7EwDQYJKoZIhvcNAQEMBQAwVDELMAkGA1UE
# BhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGln
# byBQdWJsaWMgQ29kZSBTaWduaW5nIENBIFIzNjAeFw0yMzA0MTkwMDAwMDBaFw0y
# NjA3MTgyMzU5NTlaMFUxCzAJBgNVBAYTAlVTMRQwEgYDVQQIDAtDb25uZWN0aWN1
# dDEXMBUGA1UECgwOSmFzb24gQWxiZXJpbm8xFzAVBgNVBAMMDkphc29uIEFsYmVy
# aW5vMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtiQNNQXoaqTtyDXo
# ylbCknGkvbHdB46M9bXHhYoOmMrtoJUyoph/Z6/ZeeN/Ao6XNcfp+NoDH50uQs2u
# LWVFq9brDqt3dE5YyhTjklvFL3tSfjwtH/x8aQ2yPIRN/CAg5oL/BKMwToKOJT5v
# 6wx1Ux4IkWb8tR/ID07hNd3JNrHr1bJZLthNhfMLLeSm9djqp4BfekV6bRHjNIk4
# qT4XzYp1gmvHufPpm7dXRwm1+Oufdw0Xd8kL/q7z5CIfUJDBprpn41eZb9Ut4qn/
# 1YOlz/Ud5UzzFjTtiBMyI5NdrfNe61N8WMn9kOHZQP4tW0aRX4xFXMUImSXUCp0J
# and4TpNLa/G8UyN0WcYDi0YAvJgPYYHJyZq3jFj+AsF2VCil9d6TKs61/6oklLAf
# jL3J+yxxhKPaSSAYDCLWVuM5+Lj8xm3+dxEFFpz31DkgXYJEQHZG/3Oy5IYXNRzT
# 1pVKs0v7XaKSO/k8zbGK+6hHJF6bpgZVEjjaCZ9ldc7pBW4LAatJkVkmX/rrdzlR
# qO80mKKbDF0iDxRGgXMTbr3GUF7+mHVxLA6bxpsrG4FWv+7j9ysB/Ye/VnhVP04h
# hCEh+Qefak4NuvhjEaocmaGB4+8CN+qJsEjY2rVKOXGM+ABGEzufIHHjHM7TTuOQ
# cpy8D22cGdG8TzdsC9a7iGHfnsECAwEAAaOCAa4wggGqMB8GA1UdIwQYMBaAFA8q
# yyCHKLjsb0iuK1SmKaoXpM0MMB0GA1UdDgQWBBSR7lSM0bm2siNLX8PNkO0P+O4r
# vTAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEF
# BQcDAzBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDAjAlMCMGCCsGAQUFBwIBFhdo
# dHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAEwSQYDVR0fBEIwQDA+oDyg
# OoY4aHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25p
# bmdDQVIzNi5jcmwweQYIKwYBBQUHAQEEbTBrMEQGCCsGAQUFBzAChjhodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNy
# dDAjBggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wIwYDVR0RBBww
# GoEYamFzb24uYWxiZXJpbm9AZ21haWwuY29tMA0GCSqGSIb3DQEBDAUAA4IBgQBE
# 9BBR9K/oaqEFq+B2vVA7hL9vK04FdmmqNZxUYBmf+aMDO8fZcWqaS1G4EBX3iM8w
# LKd4MEyjGH+O541I7zgWQ/c1f9yP72i5mNnp5jF2ePDpvRluKTZp77Hn9lG9f/nU
# c4LPFBV+cASXH8uDlj97dDmiiZJ/mZbYBRdXLi/0T4lkkXGboYe3SFoKD0K1cfAb
# QvKZIeBeRAsaIEJ5WgzQcxmH9VGDXxEDhXnN9VCvKBDcFsefxGiha0ovWOLbuq5K
# R9InZmHbP9X76gKRsbo4bwjuEnvALX3PfInF+A1pHNUCC0RB4lYp5qDt7JpowecL
# poD+OafTlSV4SNA9IFBUHzkmqaWuXjtpW5zVRvdKwrAA5laQw5jbdqjxtNZbgW1+
# lbVjD9rYYz+fwlr1MuvsX64Zar8Gcmbd0irbnxVpKpzVjJ5oLQTUpgRefqvMOUiV
# vtuKq53CiVkiIpv50bQtdV56CPUl5WrnEtzZW3K0FYnFzrW4ZLBKjE5+dovDTn8x
# ggMCMIIC/gIBATBpMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBS
# MzYCEQDohRsr/zNHDY0q8+DiMoexMAkGBSsOAwIaBQCgcDAQBgorBgEEAYI3AgEM
# MQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUjVXPQxfcsrvGJTV16S77GHKw
# iHQwDQYJKoZIhvcNAQEBBQAEggIAEjVoSvTAh6GhFnqypn6XzWu3UM9bRoGEM4nK
# eCqJngoPTM0A4cfzijTcIbZ2oe23Qt5nJlqq7veSdNK6y/sBdLgF+gMSngJTzye+
# 5g/IT5JDRBngM7PztNRc5wsR+tMtnFxoi0YofkWG5rTIOgulkFxPi4guMsflVhfX
# pe6mVU0IRSAyN2pHisdj0d2f3DQhXhTKDzmi7wO4lhNIpNMKqVIvEFVZOMqPecNa
# mwVnzPRvodtqzfwEzOs4RthqGaZY2x3yiLf43nA4vU25Yucu2EpY4873RdbIxb5M
# P3nTPWj33EsdSi7n+D+6Sf3BTQkmteXV5YXi1aEjl6B4Y82zhYhmZGz2WP7bp8Ig
# vbuBJO2OiiWLpNfDGo438E1LXvfenV1YZvucE9d/s/0HcfYfzT6MKu56ZfSmBbtk
# Dp0HgYHPd9GdV/Udg4QBQAHzbLcJw/PzUUTlbvvFX+WZfOiRJTVLHBc7ortux8Ry
# srylESD1eCFrE7y14ZOtJP3qoLbnBEeC+T2L0WT/l2cpb3pcZkkONRHMGXvHNMFM
# 3V8d6Nf8T4SrnTC0EpPElWAei5Dx8eRzP8sKOupnqeRNsHPKNqynH4eDIKorqfif
# ip2IMbNkGYJ0h0b+ZA9EWnIOS8WrXeorrbHU53tAeAUL6o/AclbOIFGoenqacVgN
# asf1eow=
# SIG # End signature block
