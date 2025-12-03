<#
.SYNOPSIS
Get active monitor templates, global assignments, or device-specific assignments from WhatsUp Gold.

.DESCRIPTION
- Uses /api/v1/monitors/- for active monitor templates (returns .ActiveMonitorTemplates).
- Uses /api/v1/monitors/-/assignments/- for global monitor assignments.
- Uses /api/v1/devices/{deviceId}/monitors/- or /api/v1/devices/{deviceId}/monitors/{assignmentId} for device-specific assignments.
- Always returns a flat array of assignment objects, with assignment fields and matching monitor template fields (when available).
- For device-only queries, you get just device assignments.
- For global/IncludeAssignments queries, you get all assignments, each with their template info.
- Output is always suitable for piping to Where-Object { $_.comment -match 'dns' }.
- Parameters strictly match API support (see Swagger for each endpoint).

.PARAMETER View
Level of information returned for templates/assignments ("id","basic","info","summary","details" or assignment-appropriate values). Default = "info".

.PARAMETER IncludeDeviceMonitors
[templates only] Return device-specific monitors. Default = "false".

.PARAMETER IncludeSystemMonitors
[templates only] Return monitors owned by the system and cannot be modified. Default = "false".

.PARAMETER IncludeCoreMonitors
[templates only] Return core monitors. Default = "false".

.PARAMETER Search
Return only monitors/assignments containing this string in display name, description, or classId.

.PARAMETER PageId
Page to return (for paging).

.PARAMETER DeviceId
If specified, returns assignments for the given device. If AssignmentId is also specified, returns that specific assignment.

.PARAMETER AssignmentId
If specified with DeviceId, returns that specific assignment on the device.

.PARAMETER AssignmentView
Assignment info level ("id","minimum","basic","status"). Default="status".

.PARAMETER DeviceView
Assignment device info level for global assignments ("id","basic","card","overview"). Default="id".

.PARAMETER MonitorTypeId
[device assignments] Optional: filter by monitor type id.

.PARAMETER EnabledOnly
[device assignments] Optional: Only enabled assignments. Default="true".

.PARAMETER IncludeAssignments
If set, get both templates and global assignments (returns a flat list of assignments merged with template info).

.EXAMPLE
Get-WUGActiveMonitor -IncludeAssignments -Search "Ping"

.EXAMPLE
Get-WUGActiveMonitor -DeviceId 1234 -Search "CPU"

.EXAMPLE
Get-WUGActiveMonitor -DeviceId 1234 -AssignmentId 2345

.NOTES
Parameters and response structure strictly follow WhatsUp Gold API documentation,
and output is a flat list of assignments with template info merged in.
#>
function Get-WUGActiveMonitor {
    [CmdletBinding()]
    param(
        [ValidateSet("id", "basic", "info", "summary", "details")]
        [string]$View = "info",

        [ValidateSet("true", "false")]
        [string]$IncludeDeviceMonitors = "false",

        [ValidateSet("true", "false")]
        [string]$IncludeSystemMonitors = "false",

        [ValidateSet("true", "false")]
        [string]$IncludeCoreMonitors = "false",

        [string]$Search,
        [ValidateSet("true", "false")]
        [string]$PageId,

        [Parameter()][switch]$IncludeAssignments,
        [ValidateSet("id", "minimum", "basic", "status")]
        [string]$AssignmentView = "status",
        [ValidateSet("id", "basic", "card", "overview")]
        [string]$DeviceView = "overview",

        [string]$DeviceId,
        [string]$AssignmentId,
        [string]$MonitorTypeId,
        [ValidateSet("true", "false")]
        [string]$EnabledOnly = "true"
    )

    begin {
        if (-not $global:WUGBearerHeaders) {
            Write-Error "Authorization header not set. Please run Connect-WUGServer first."
            return
        }
        if (-not $global:WhatsUpServerBaseURI) {
            Write-Error "Base URI not found. Please run Connect-WUGServer first."
            return
        }
    }

    process {
        function Write-DebugActive {
            param($activeObj)
            Write-Verbose ("[DEBUG] .active = " + ($activeObj | ConvertTo-Json -Depth 5))
        }
        function Get-ActiveCommentArgument {
            param($active)
            $comment = $null
            $argument = $null
            if ($active) {
                if ($active -is [System.Collections.IDictionary]) {
                    $comment = $active["comment"]
                    $argument = $active["argument"]
                } elseif ($active -is [PSObject]) {
                    $comment = if ($active.PSObject.Properties['comment']) { $active.PSObject.Properties['comment'].Value } else { $null }
                    $argument = if ($active.PSObject.Properties['argument']) { $active.PSObject.Properties['argument'].Value } else { $null }
                }
                if (-not $comment -and $active.comment) { $comment = $active.comment }
                if (-not $argument -and $active.argument) { $argument = $active.argument }
            }
            return @($comment, $argument)
        }

        # Templates for merging with assignments (always fetched if IncludeAssignments or no DeviceId)
        $activeMonitors = @()
        if ($IncludeAssignments -or -not $DeviceId) {
            $templateQS = "type=active&"
            if ($View)                  { $templateQS += "view=$View&" }
            if ($IncludeDeviceMonitors) { $templateQS += "includeDeviceMonitors=$IncludeDeviceMonitors&" }
            if ($IncludeSystemMonitors) { $templateQS += "includeSystemMonitors=$IncludeSystemMonitors&" }
            if ($IncludeCoreMonitors)   { $templateQS += "includeCoreMonitors=$IncludeCoreMonitors&" }
            if ($Search)                { $templateQS += "search=$Search&" }
            if ($AllMonitors)           { $templateQS += "allMonitors=$AllMonitors&" }
            if ($PageId)                { $templateQS += "pageId=$PageId&" }
            $templateQS = $templateQS.TrimEnd('&')
            $templateURI = "${global:WhatsUpServerBaseURI}/api/v1/monitors/-"
            if ($templateQS) { $templateURI += "?$templateQS" }

            try {
                $templateResponse = Get-WUGAPIResponse -Uri $templateURI -Method GET
                if ($templateResponse.data -and $templateResponse.data.activeMonitors) {
                    $activeMonitors = $templateResponse.data.activeMonitors
                }
            } catch {
                Write-Error "Failed to retrieve active monitor templates: $_"
            }
        }

        # If DeviceId (device-specific assignments)
        if ($DeviceId) {
            $qs = "type=active&"
            if ($AssignmentView) { $qs += "view=$AssignmentView&" }
            if ($Search)         { $qs += "search=$Search&" }
            if ($MonitorTypeId)  { $qs += "monitorTypeId=$MonitorTypeId&" }
            if ($EnabledOnly)    { $qs += "enabledOnly=$EnabledOnly&" }
            if ($PageId)         { $qs += "pageId=$PageId&" }
            $qs = $qs.TrimEnd('&')

            if ($AssignmentId) {
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/$DeviceId/monitors/$AssignmentId"
                if ($qs) { $uri += "?$qs" }
                try {
                    $response = Get-WUGAPIResponse -Uri $uri -Method GET
                    if ($response.data) {
                        $comment = $null; $argument = $null
                        if ($response.data.active) {
                            $arr = Get-ActiveCommentArgument $response.data.active
                            $comment = $arr[0]; $argument = $arr[1]
                        }
                        # Merge with template (if available)
                        $tid = $response.data.monitorTypeId
                        $template = $null
                        if ($tid -and $activeMonitors) {
                            $template = $activeMonitors | Where-Object { $_.monitorId -eq $tid -or $_.id -eq $tid } | Select-Object -First 1
                        }
                        [PSCustomObject]@{
                            DeviceMonitorAssignmentId = $response.data.id
                            Description              = $response.data.description
                            Type                     = $response.data.type
                            MonitorTypeId            = $response.data.monitorTypeId
                            MonitorTypeClassId       = $response.data.monitorTypeClassId
                            MonitorTypeName          = $response.data.monitorTypeName
                            IsGlobal                 = $response.data.isGlobal
                            Status                   = $response.data.status
                            Enabled                  = $response.data.enabled
                            comment                  = $comment
                            argument                 = $argument
                            TemplateName             = $template.name
                            TemplateDescription      = $template.description
                            TemplateMonitorId        = $template.monitorId
                            TemplateId               = $template.id
                            TemplateClassId          = $template.monitorTypeClassId
                            TemplateInfo             = $template.monitorTypeInfo
                        }
                    }
                } catch {
                    Write-Error "Failed to retrieve assignment $AssignmentId for device ${DeviceId}: $_"
                }
                return
            } else {
                $uri = "${global:WhatsUpServerBaseURI}/api/v1/devices/$DeviceId/monitors/-"
                if ($qs) { $uri += "?$qs" }
                try {
                    $response = Get-WUGAPIResponse -Uri $uri -Method GET
                    if ($response.data) {
                        return $response.data | ForEach-Object {
                            $comment = $null; $argument = $null
                            if ($_.active) {
                                $arr = Get-ActiveCommentArgument $_.active
                                $comment = $arr[0]; $argument = $arr[1]
                            }
                            # Merge with template (if available)
                            $tid = $_.monitorTypeId
                            $template = $null
                            if ($tid -and $activeMonitors) {
                                $template = $activeMonitors | Where-Object { $_.monitorId -eq $tid -or $_.id -eq $tid } | Select-Object -First 1
                            }
                            [PSCustomObject]@{
                                DeviceMonitorAssignmentId = $_.id
                                Description              = $_.description
                                Type                     = $_.type
                                MonitorTypeId            = $_.monitorTypeId
                                MonitorTypeClassId       = $_.monitorTypeClassId
                                MonitorTypeName          = $_.monitorTypeName
                                IsGlobal                 = $_.isGlobal
                                Status                   = $_.status
                                Enabled                  = $_.enabled
                                comment                  = $comment
                                argument                 = $argument
                                TemplateName             = $template.name
                                TemplateDescription      = $template.description
                                TemplateMonitorId        = $template.monitorId
                                TemplateId               = $template.id
                                TemplateClassId          = $template.monitorTypeClassId
                                TemplateInfo             = $template.monitorTypeInfo
                            }
                        }
                    }
                } catch {
                    Write-Error "Failed to retrieve monitor assignments for device ${DeviceId}: $_"
                }
                return
            }
        }

        # Otherwise: global assignments (IncludeAssignments) - return flat merged list
        $assignQS = "type=active&"
        if ($AssignmentView) { $assignQS += "view=$AssignmentView&" }
        if ($DeviceView)     { $assignQS += "deviceView=$DeviceView&" }
        if ($Search)         { $assignQS += "search=$Search&" }
        if ($PageId)         { $assignQS += "pageId=$PageId&" }
        $assignQS = $assignQS.TrimEnd('&')
        $assignURI = "${global:WhatsUpServerBaseURI}/api/v1/monitors/-/assignments/-"
        if ($assignQS) { $assignURI += "?$assignQS" }

        $assignments = @()
        try {
            $assignmentsResponse = Get-WUGAPIResponse -Uri $assignURI -Method GET
            if ($assignmentsResponse.data) {
                $assignments = $assignmentsResponse.data
            }
        } catch {
            Write-Error "Failed to retrieve active monitor assignments: $_"
        }

        # Build a lookup hash for templates for join
        $templateMap = @{}
        foreach ($t in $activeMonitors) {
            $tid = $t.monitorId
            if (-not $tid -and $t.id) { $tid = $t.id }
            if ($tid) { $templateMap["$tid"] = $t }
        }

        foreach ($a in $assignments) {
            $comment = $null; $argument = $null
            if ($a.active) {
                $arr = Get-ActiveCommentArgument $a.active
                $comment = $arr[0]
                $argument = $arr[1]
            }
            $tid = $a.monitorTypeId
            $template = $null
            if ($tid -and $templateMap.ContainsKey("$tid")) {
                $template = $templateMap["$tid"]
            }
            [PSCustomObject]@{
                DeviceId          = $a.device.id
                DeviceName        = $a.device.name
                DeviceHostName    = $a.device.hostName
                DeviceAddress     = $a.device.networkAddress
                DeviceDescription = $a.device.description
                DeviceRole        = $a.device.role
                DeviceBrand       = $a.device.brand
                DeviceOS          = $a.device.os
                AssignmentId      = $a.id
                Description       = $a.description
                Status            = $a.status
                Type              = $a.type
                MonitorTypeId     = $a.monitorTypeId
                MonitorTypeClassId= $a.monitorTypeClassId
                MonitorTypeName   = $a.monitorTypeName
                Enabled           = $a.enabled
                IsGlobal          = $a.isGlobal
                comment           = $comment
                argument          = $argument
                TemplateName      = $template.name
                TemplateDescription = $template.description
                TemplateMonitorId = $template.monitorId
                TemplateId        = $template.id
                TemplateClassId   = $template.monitorTypeClassId
                TemplateInfo      = $template.monitorTypeInfo
            }
        }
    }
}
# SIG # Begin signature block
# MIIVvgYJKoZIhvcNAQcCoIIVrzCCFasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAKw3gdvDNmXw+o
# oWGSD91crt5RFe1wapljdmycrUFLLaCCEfkwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BgkqhkiG9w0BCQQxIgQgQWiHM5PuHUvzHVZQEqCeaTVEeIfaK5tmcfoQS84fpaEw
# DQYJKoZIhvcNAQEBBQAEggIAomMnaYwJmAbfa25LB2f/CI6XXbVPTHkymzOxg+8k
# 2m1qOCLvDem9+j83ErNU9mQ6KuKfxJxjqIwxQElt2xe4G1TSSSFRLF+avfpsZmZ3
# j34qlELU29gnRrupdII2ewJ6v5NloQ6521qgWrf8eggGXPYVJsLjWs8CAssIcPeY
# ZhfdE7bkU28jPF76cyal0osv397hQu40AyIa/x80ONP+50+Szkd5aiIpzoYPwbBg
# Lon1Ihxpgr5FUbMG7aGiwxhuV2IBJBOaH7wxiMbrMVkfTlEudqu8Q7Cog2XgZH0q
# BWvz3NNdRIL7mdz8PxHq2polG6Puf6tUBvo2Go+eJbDFm7Izl0NQIUPBEFiZPH/R
# oU2tUxk2ICDgbSX7GpQlomh7aTWV4KtC68NPVcoZnYWTsZLrIIZcKl5I7O0OX136
# cEwHi0ZhVKQKGks3E+seuscQWsfXxpyjK+MTvWdN04z+1SkKizD79r3gBbyx+a2f
# wTbbq5H7xyMWbV2UbrQ0ajyot1mcH61lCx+4ZzPsal8T+9D09sKh1DwZn0tN1ivh
# o7CXyZxHUGyOoEPRinK/5DQLaL+ZdBglxgZu7v/K4Nqy38P5oby7P0eZyP98OSoY
# T+P69Bf8ePc3RTT7ypgIH3NIzlTBATJjnwAUB14C1an38VOh/AtR4WHXiUuLUnfX
# 1o0=
# SIG # End signature block
