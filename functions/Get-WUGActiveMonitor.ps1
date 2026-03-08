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

.PARAMETER AllMonitors
Return all monitors (deprecated API parameter). Valid values: "true", "false".

.PARAMETER Limit
Maximum number of results per page. Valid range: 0-250.

.PARAMETER activeObj
Internal use — the active monitor object being processed.

.PARAMETER active
Internal use — the active monitor entry being processed.

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

        [ValidateSet("true", "false")]
        [string]$AllMonitors,

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
        [string]$EnabledOnly = "true",

        [ValidateRange(0, 250)][int]$Limit
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
            if ($AllMonitors)            { $templateQS += "allMonitors=$AllMonitors&" }
            if ($Search)                { $templateQS += "search=$Search&" }
            if ($PageId)                { $templateQS += "pageId=$PageId&" }
            if ($Limit)                 { $templateQS += "limit=$Limit&" }
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
            if ($Limit)          { $qs += "limit=$Limit&" }
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
        if ($Limit)          { $assignQS += "limit=$Limit&" }
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBpze5si5Sv6Flz
# OyyFi+9KdgeNMubMCFa5JUvQBBgrh6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg79zhb/3Wfkcmx7LoJb4oIk7f1yl2CMPQ
# Am7PuyVvBT0wDQYJKoZIhvcNAQEBBQAEggIAOxff+lImc3I+GLT/uTSj70XbajTj
# V+vbqftyTxJzGNi4ZWJCjXt+NVZr3zJDTD4C/e6eQ95gMKuNJRPig17ux1tYnFLu
# QXZOi8AkHzyBoZ5tnAWkt1cR2ffT3cXqIu9PgSrLKvAsWKuvx1FyllWOKyHrK7jH
# DMWQOIUIvacpLbA/8/p9TCJs0AVjsTlthqxr5g3jMnr8b95wJeTtTX0OUu8SQMq9
# wMczhBVpd8A/aVElcCW2OvalXSm/fhRaEKfkah0Eq7BhuVwxLxbMlpt0pUgH6lcY
# c1GlEIrk1YsqyaSVG40AaDPhcrgM23hVLEVt3Y1IKIAOzq5nKkiMHP/1MABur1a/
# 1fu05AtivyWsKc0wuYNxWq7B8Jt/FdeBZxXxdd7kl+QumEYmB1TLT0lrX7uShPYm
# Vx0rpFlZO3s+thwf9QocdcZljUMsDelZQ3kzOcEBEYUDaiJqNPTTWh/NKnw5Pp19
# 5x3xnvZ6N8DGrw/bTCt1QJrj/9JIFnh/iFMQEj+xkWSaZUQnj3VhehnWu0sIaYDH
# 1xZpd396cGvcvH/GiZ1skkmqNR8Q3O0uquJaKEbJGiS8KIvDPP8H/cGH687/YlxO
# JZhPmnBZyjTVJqZVoWyyYwBrTbM9ffLYwiGr0AwcyvJD+5sgdaxebvKR3oI9vnFg
# X/jkztnZRfLbCo4=
# SIG # End signature block
