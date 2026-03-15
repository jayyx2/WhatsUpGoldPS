# ============================================================
# API Endpoint Reference
# Source: WhatsUpGold 2024 REST API
#
# Create passive monitor in library:
#    POST /api/v1/monitors/-
#    Body schema: MonitorAdd
#      - name            (string, required)  Display name of monitor
#      - description     (string, optional)  Description of monitor
#      - monitorTypeInfo (object, required)  { baseType: "passive", classId: "<GUID>" }
#      - propertyBags    (array,  optional)  [ { name: string, value: string }, ... ]
#      - useInDiscovery  (bool,   optional)  Default false
#    Success response: Result[ApplyTemplateResults]
#      - data.successful = 1
#      - data.idMap.resultId = new monitor library ID
#
# Assign monitor to device:
#    POST /api/v1/devices/{deviceId}/monitors/-
#    (See Add-WUGPassiveMonitorToDevice)
#
# Remove monitor assignment from device:
#    DELETE /api/v1/devices/{deviceId}/monitors/{assignmentId}
#    (See Remove-WUGDeviceMonitor)
#
# Remove monitor from library:
#    DELETE /api/v1/monitors/{monitorId}?type=passive
#    (See Remove-WUGActiveMonitor -Type passive)
# ============================================================
<#
.SYNOPSIS
    Creates a passive monitor in the WhatsUp Gold monitor library.

.DESCRIPTION
    Add-WUGPassiveMonitor creates a passive monitor of the specified type in the
    WhatsUp Gold monitor library via POST /api/v1/monitors/-. Supports three
    passive monitor types: SnmpTrap, Syslog, and WinEvent. Each type has its
    own parameter set with explicit named parameters matching the UI fields.

    Use Add-WUGPassiveMonitorToDevice to assign the created monitor to devices.

.PARAMETER Type
    The type of passive monitor to create. Valid values: SnmpTrap, Syslog, WinEvent.

.PARAMETER Name
    Display name for the monitor in the WUG library. Required.

.PARAMETER Description
    Optional description for the monitor. If omitted, auto-generated from Type.

.PARAMETER UseInDiscovery
    Whether the monitor should be used during device discovery. Default: false.

.PARAMETER SnmpTrapGenericType
    (SnmpTrap) Generic trap type. Maps to the 'Generic type (Major)' dropdown in the UI.
    Valid values: Any, ColdStart, WarmStart, LinkDown, LinkUp, AuthenticationFailure,
    EgpNeighborLoss, EnterpriseSpecific. Default: Any.

.PARAMETER SnmpTrapSpecificType
    (SnmpTrap) Specific trap type number (nMinor). Maps to the 'Specific type' field in
    the UI. Used alongside EnterpriseSpecific generic type. Default: '0'.

.PARAMETER SnmpTrapOID
    (SnmpTrap) Enterprise OID (sOID). The enterprise-specific OID for the trap, e.g.
    '1.3.6.1.4.1.9.9.13.1.4.1.3'. When provided, GenericType is automatically set to
    EnterpriseSpecific (nMajor=6) regardless of the -SnmpTrapGenericType value.

.PARAMETER SnmpTrapExpression
    (SnmpTrap) Regular expression or plain text to match against the trap payload.
    Required.

.PARAMETER SnmpTrapMatchCase
    (SnmpTrap) Whether the expression match is case sensitive. '1' = case sensitive,
    '0' = case insensitive. Default: '0'.

.PARAMETER SnmpTrapInvertResult
    (SnmpTrap) Whether to invert the match result (monitor is UP when expression
    does NOT match). '1' = invert, '0' = normal. Default: '0'.

.PARAMETER SyslogExpression
    (Syslog) Regular expression or plain text to match against syslog messages.
    Required.

.PARAMETER SyslogMatchCase
    (Syslog) Whether the expression match is case sensitive. '1' = case sensitive,
    '0' = case insensitive. Default: '0'.

.PARAMETER SyslogInvertResult
    (Syslog) Whether to invert the match result. '1' = invert, '0' = normal. Default: '0'.

.PARAMETER WinEventExpression
    (WinEvent) Regular expression or plain text to match against event log messages.
    Required.

.PARAMETER WinEventMatchCase
    (WinEvent) Whether the expression match is case sensitive. '1' = case sensitive,
    '0' = case insensitive. Default: '0'.

.PARAMETER WinEventInvertResult
    (WinEvent) Whether to invert the match result. '1' = invert, '0' = normal. Default: '0'.

.EXAMPLE
    Add-WUGPassiveMonitor -Type SnmpTrap -Name "Critical Trap Monitor" -SnmpTrapExpression "critical error"

    Creates an SNMP Trap passive monitor that matches 'critical error' (case insensitive)
    on any generic trap type.

.EXAMPLE
    Add-WUGPassiveMonitor -Type SnmpTrap -Name "Enterprise Trap" -SnmpTrapOID '1.3.6.1.4.1.9.9.13.1.4.1.3' -SnmpTrapSpecificType '1' -SnmpTrapExpression "match this" -SnmpTrapInvertResult '1'

    Creates an SNMP Trap monitor for Enterprise Specific traps (auto-detected from OID)
    with enterprise OID 1.3.6.1.4.1.9.9.13.1.4.1.3, specific type 1, matching
    'match this' case insensitively, with inverted result.

.EXAMPLE
    Add-WUGPassiveMonitor -Type SnmpTrap -Name "Cold Start Trap" -SnmpTrapGenericType ColdStart -SnmpTrapExpression ".*" -SnmpTrapMatchCase '1'

    Creates an SNMP Trap monitor for Cold Start traps with case-sensitive regex match.

.EXAMPLE
    Add-WUGPassiveMonitor -Type Syslog -Name "Syslog Error Monitor" -SyslogExpression "error|critical"

    Creates a Syslog passive monitor matching 'error' or 'critical'.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    API Endpoint: POST /api/v1/monitors/-
    Spec: https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/whatsupgold2024-0-3.json
    Module: WhatsUpGoldPS | https://github.com/jayyx2/WhatsUpGoldPS

    Supported Types: SnmpTrap, Syslog, WinEvent

    Removal: Use Remove-WUGActiveMonitor -Type passive to remove from library.
#>
function Add-WUGPassiveMonitor {
    [CmdletBinding(DefaultParameterSetName = 'SnmpTrap', SupportsShouldProcess = $true)]
    param(
        # ── Common parameters (all parameter sets) ───────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'SnmpTrap')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Syslog')]
        [Parameter(Mandatory = $true, ParameterSetName = 'WinEvent')]
        [ValidateSet('SnmpTrap', 'Syslog', 'WinEvent')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [bool]$UseInDiscovery = $false,

        # ── SNMP Trap parameters ─────────────────────────────────────────────
        [Parameter(ParameterSetName = 'SnmpTrap')]
        [ValidateSet('Any', 'ColdStart', 'WarmStart', 'LinkDown', 'LinkUp',
                     'AuthenticationFailure', 'EgpNeighborLoss', 'EnterpriseSpecific')]
        [string]$SnmpTrapGenericType = 'Any',

        [Parameter(ParameterSetName = 'SnmpTrap')]
        [string]$SnmpTrapSpecificType = '0',

        [Parameter(ParameterSetName = 'SnmpTrap')]
        [string]$SnmpTrapOID,

        [Parameter(Mandatory = $true, ParameterSetName = 'SnmpTrap')]
        [string]$SnmpTrapExpression,

        [Parameter(ParameterSetName = 'SnmpTrap')]
        [ValidateSet('0', '1')]
        [string]$SnmpTrapMatchCase = '0',

        [Parameter(ParameterSetName = 'SnmpTrap')]
        [ValidateSet('0', '1')]
        [string]$SnmpTrapInvertResult = '0',

        # ── Syslog parameters ─────────────────────────────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'Syslog')]
        [string]$SyslogExpression,

        [Parameter(ParameterSetName = 'Syslog')]
        [ValidateSet('0', '1')]
        [string]$SyslogMatchCase = '0',

        [Parameter(ParameterSetName = 'Syslog')]
        [ValidateSet('0', '1')]
        [string]$SyslogInvertResult = '0',

        # ── WinEvent parameters ────────────────────────────────────────────────
        [Parameter(Mandatory = $true, ParameterSetName = 'WinEvent')]
        [string]$WinEventExpression,

        [Parameter(ParameterSetName = 'WinEvent')]
        [ValidateSet('0', '1')]
        [string]$WinEventMatchCase = '0',

        [Parameter(ParameterSetName = 'WinEvent')]
        [ValidateSet('0', '1')]
        [string]$WinEventInvertResult = '0'
    )

    begin {
        Write-Debug "Initializing Add-WUGPassiveMonitor function with Type: $Type"
        $baseUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"
        $ClassId = ""
        $PropertyBags = @()
        $skipCreation = $false

        # Auto-generate description if not supplied
        if (-not $Description) {
            $Description = "$Type passive monitor created via Add-WUGPassiveMonitor"
        }

        # Check if the monitor already exists
        Write-Verbose "Checking if monitor with name '${Name}' already exists."
        $existingMonitorUri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-?type=passive&view=details&search=$([uri]::EscapeDataString(${Name}))"

        try {
            $existingMonitorResult = Get-WUGAPIResponse -Uri $existingMonitorUri -Method GET -ErrorAction Stop
            if ($existingMonitorResult.data.passiveMonitors | Where-Object { $_.name -eq $Name }) {
                Write-Warning "Monitor with the name '$Name' already exists. Skipping creation."
                $skipCreation = $true
                return
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Verbose "No existing monitor found with the name '$Name'. Proceeding with creation."
            }
            else {
                Write-Warning "Failed to check for existing monitors: $($_.Exception.Message)"
                return
            }
        }

        # Monitor-specific setup
        switch ($Type) {
            'SnmpTrap' {
                $ClassId = '805ebfde-caad-49d7-a81b-e26ba7725149'

                # Map friendly name to nMajor integer value
                $nMajorMap = @{
                    'Any'                   = '7'
                    'ColdStart'             = '0'
                    'WarmStart'             = '1'
                    'LinkDown'              = '2'
                    'LinkUp'                = '3'
                    'AuthenticationFailure' = '4'
                    'EgpNeighborLoss'       = '5'
                    'EnterpriseSpecific'    = '6'
                }
                # Auto-promote to EnterpriseSpecific when an OID is supplied
                if ($SnmpTrapOID -and $SnmpTrapGenericType -ne 'EnterpriseSpecific') {
                    Write-Verbose "SnmpTrapOID provided — auto-setting GenericType to EnterpriseSpecific."
                    $SnmpTrapGenericType = 'EnterpriseSpecific'
                }
                $nMajorValue = $nMajorMap[$SnmpTrapGenericType]

                # Build sExpressions XML — XML-escape the expression text
                $escapedExpr = [System.Security.SecurityElement]::Escape($SnmpTrapExpression)
                $expressionXml = "<Expressions>`r`n  <Expression sExpression=`"$escapedExpr`" bMatchCase=`"$SnmpTrapMatchCase`" bInvertResult=`"$SnmpTrapInvertResult`" />`r`n</Expressions>"

                $PropertyBags = @(
                    @{ "name" = "sExpressions"; "value" = $expressionXml },
                    @{ "name" = "nMajor"; "value" = $nMajorValue },
                    @{ "name" = "nMinor"; "value" = "$SnmpTrapSpecificType" }
                )

                # sOID is the enterprise-specific OID
                if ($SnmpTrapOID) {
                    $PropertyBags += @{ "name" = "sOID"; "value" = "$SnmpTrapOID" }
                }
            }

            'Syslog' {
                $ClassId = '186fa172-04fd-4ab7-a72b-91662b2792dc'
                $PropertyBags = @(
                    @{ "name" = "Message"; "value" = "$SyslogExpression" }
                )
            }

            'WinEvent' {
                $ClassId = '05b9e430-9400-479b-b375-8d5df4ecd419'
                $PropertyBags = @(
                    @{ "name" = "Condition"; "value" = "<Condition/>" }
                    @{ "name" = "Password";  "value" = " " }
                    @{ "name" = "Username";  "value" = " " }
                    @{ "name" = "Messages";  "value" = "$WinEventExpression" }
                )
            }
        }
    }

    process {
        if ($skipCreation) {
            Write-Warning "Skipping monitor creation."
            return
        }

        Write-Verbose "Creating $Type passive monitor: $Name"

        $payload = @{
            "allowSystemMonitorCreation" = $true
            "name"                       = $Name
            "description"                = $Description
            "monitorTypeInfo"            = @{
                "baseType" = "passive"
                "classId"  = $ClassId
            }
            "propertyBags"               = $PropertyBags
            "useInDiscovery"             = $UseInDiscovery
        }

        $jsonPayload = $payload | ConvertTo-Json -Compress -Depth 5
        Write-Debug "Create payload: $jsonPayload"

        if (-not $PSCmdlet.ShouldProcess("$Type passive monitor '$Name'", 'Create passive monitor')) { return }

        try {
            $createResult = Get-WUGAPIResponse -Uri $baseUri -Method "POST" -Body $jsonPayload

            if ($createResult.data.successful -eq 1) {
                $newMonitorId = $createResult.data.idMap.resultId
                Write-Verbose "Successfully created passive monitor '$Name' (library ID: $newMonitorId)."
                Write-Debug "Create result: $(ConvertTo-Json $createResult -Depth 10)"
                Write-Output ([PSCustomObject]@{
                    Type        = $Type
                    MonitorName = $Name
                    MonitorId   = $newMonitorId
                    Success     = $true
                })
            }
            else {
                Write-Warning "Failed to create passive monitor '$Name' in library."
                Write-Debug "Create result: $(ConvertTo-Json $createResult -Depth 10)"
                Write-Output ([PSCustomObject]@{
                    Type        = $Type
                    MonitorName = $Name
                    MonitorId   = $null
                    Success     = $false
                })
            }
        }
        catch {
            Write-Error "Error creating passive monitor '$Name': $($_.Exception.Message)"
        }
    }

    end {
        Write-Debug "Completed Add-WUGPassiveMonitor function."
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCx4n7xvTihpdcr
# z64Z7mREZhZsW+JlLnB37FYp509SHaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgyORYeNPsmIEOhaNlWhlAlDBU/xsQlyrH
# 5g/5pPP3wLcwDQYJKoZIhvcNAQEBBQAEggIALRK/3H8Iav+jPHotNotxTzaSiZ9+
# JQovyQO3IaMAYWqRk0AkJu2pN1/yziFXoq9dSx1/CxYjOFKvEag34Os3WcCx7XzH
# evmECXqdROHGNi70IG4XitrQ7EhJAD22a0U0OkHb+ZuqJSiIXKD2ZZ8lY41r/99F
# AQ86W1JtU0iAQ6Ntny6C62kyULb8GUyPXNuK35psQPFcO6UINrya5+3RbJMeHgTo
# zkVFYItOA2HKJpvcfYjP1Qf+COpnlIPOJRq0qOheJT/Szqjv+coaLGK2N2JD1t1g
# 6vrb9ZSU5UwgmdNcAJxosU/LHKTkhN/BoW56qgx6WpUFO2o3Jv213NpEGTnY+QFG
# hQNeYf+l6cDQzUP0yx0Mms0FxiYNHnGyHCPvebsn1VogvZPuEct7Td0whOfR2bd3
# tybzKGn6NL5cpnAoMg5jxs5xfS/edIuF2SYhRCEC5YsW9jepiI8/fs3xxWQPKXGS
# cIULwQ50fVt4PFD++CzJW8ftAurmKVIxU9OFKn8mD0pcBdNsQoYpeJ38tBr9fVoh
# Ha4Ij1zdQiEDRYjdlpVO2Ww/RX28YS+FLZnvQ337Pky9SoeqH6+8kw33l7MFr7mm
# w4Ow6fypfZDxfwWRiFOrUKiN+Q8oaoztRiIrbqeHz5/W+PVyg+Qv0fy574TKX2EO
# 3JfrN1J/zLPERzQ=
# SIG # End signature block
