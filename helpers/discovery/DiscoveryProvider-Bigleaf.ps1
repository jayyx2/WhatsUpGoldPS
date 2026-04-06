<#
.SYNOPSIS
    Bigleaf Networks discovery provider for WAN/SD-WAN monitoring.

.DESCRIPTION
    Registers a Bigleaf discovery provider that queries the Bigleaf Cloud
    Connect REST API v2 to discover sites, circuits, and CPE devices, then
    builds a monitor plan.

    Active Monitors (up/down):
      - Per-site health via /v2/sites/{id}/status
      - Per-circuit connectivity via /v2/sites/{id}/circuits/status

    Performance Monitors (stats over time):
      - Site risk count via status endpoint
      - Circuit latency / jitter / packet-loss via circuit status

    Authentication:
      Bigleaf API uses HTTP Basic auth (username:password).
      Rate limit: 10 requests per minute.

    Prerequisites:
      1. Bigleaf Cloud Connect account with API access
      2. Bigleaf API credentials (username + password)
      3. Device attribute 'DiscoveryHelper.Bigleaf' = 'true'

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM
#>

# Ensure DiscoveryHelpers is available
if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $discoveryPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'DiscoveryHelpers.ps1'
    if (Test-Path $discoveryPath) {
        . $discoveryPath
    }
    else {
        throw "DiscoveryHelpers.ps1 not found. Load it before this provider."
    }
}

# Load Bigleaf helpers
$bigleafHelperPath = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'bigleaf\BigleafHelpers.ps1'
if (Test-Path $bigleafHelperPath) {
    . $bigleafHelperPath
}

# ============================================================================
# Bigleaf Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Bigleaf' `
    -MatchAttribute 'DiscoveryHelper.Bigleaf' `
    -AuthType 'BasicAuth' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $baseApi = 'https://api.bigleaf.net/v2'

        # Build auth header from credential
        $cred = $ctx.Credential
        if (-not $cred -or (-not $cred.Username -and -not $cred.PSCredential)) {
            Write-Warning "Bigleaf: No credentials provided."
            return $items
        }

        $username = $null
        $password = $null
        if ($cred.PSCredential) {
            $username = $cred.PSCredential.UserName
            $password = $cred.PSCredential.GetNetworkCredential().Password
        }
        elseif ($cred.Username) {
            $username = $cred.Username
            $password = $cred.Password
        }
        if (-not $username) {
            Write-Warning "Bigleaf: Could not extract credentials."
            return $items
        }

        $pair = "${username}:${password}"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
        $b64 = [System.Convert]::ToBase64String($bytes)
        $authHeaders = @{ Authorization = "Basic $b64" }

        # Helper to call Bigleaf API with rate-limit awareness
        function Invoke-BigleafREST {
            param([string]$Endpoint)
            $uri = "${baseApi}${Endpoint}"
            try {
                $resp = Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET -ErrorAction Stop
                return $resp
            }
            catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                    Write-Verbose "Bigleaf rate limit hit, waiting 10s..."
                    Start-Sleep -Seconds 10
                    return (Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET -ErrorAction Stop)
                }
                throw
            }
        }

        Write-Host "  Querying Bigleaf sites..." -ForegroundColor DarkGray

        # Get all sites
        $sitesResp = Invoke-BigleafREST -Endpoint '/sites'
        $sites = @()
        if ($sitesResp.data) { $sites = @($sitesResp.data) }
        elseif ($sitesResp -is [array]) { $sites = @($sitesResp) }

        Write-Host "  Found $($sites.Count) sites" -ForegroundColor DarkGray

        foreach ($site in $sites) {
            $siteId   = $site.id
            $siteName = $site.name
            if (-not $siteName) { $siteName = "Site-$siteId" }
            $siteIp   = $null

            # Common attributes for all items from this site
            $siteAttrs = @{
                'DiscoveryHelper.Bigleaf'  = 'true'
                'Bigleaf.SiteId'           = "$siteId"
                'Bigleaf.SiteName'         = $siteName
                'Bigleaf.DeviceType'       = 'Site'
                'Vendor'                   = 'Bigleaf'
                'Cloud Type'               = 'Bigleaf'
            }

            # Get site status
            $statusResp = $null
            try {
                Start-Sleep -Milliseconds 6500  # Respect rate limit
                $statusResp = Invoke-BigleafREST -Endpoint "/sites/$siteId/status"
            }
            catch {
                Write-Verbose "  Could not get status for site '$siteName': $_"
            }

            $siteStatus = 'unknown'
            if ($statusResp) {
                $statusData = if ($statusResp.data) { $statusResp.data } else { $statusResp }
                if ($statusData.status) { $siteStatus = $statusData.status }
                if ($statusData.ip) { $siteIp = $statusData.ip }
                $siteAttrs['Bigleaf.Status'] = $siteStatus
            }

            # Active Monitor: Site health
            $healthUrl = "${baseApi}/sites/${siteId}/status"
            $items += New-DiscoveredItem `
                -Name "Bigleaf Site Health - $siteName" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'RestApi' `
                -MonitorParams @{
                    RestApiUrl                    = $healthUrl
                    RestApiMethod                 = 'GET'
                    RestApiTimeoutMs              = 15000
                    RestApiUseAnonymous           = '0'
                    RestApiComparisonList         = "[{`"JsonPathQuery`":`"['data']['status']`",`"AttributeType`":1,`"ComparisonType`":3,`"CompareValue`":`"healthy`"}]"
                    RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                } `
                -UniqueKey "Bigleaf:${siteId}:active:health" `
                -Attributes $siteAttrs `
                -Tags @('bigleaf', 'site', $siteName)

            # Get circuit status for this site
            $circuitResp = $null
            try {
                Start-Sleep -Milliseconds 6500
                $circuitResp = Invoke-BigleafREST -Endpoint "/sites/$siteId/circuits/status"
            }
            catch {
                Write-Verbose "  Could not get circuits for site '$siteName': $_"
            }

            $circuits = @()
            if ($circuitResp) {
                if ($circuitResp.data) { $circuits = @($circuitResp.data) }
                elseif ($circuitResp -is [array]) { $circuits = @($circuitResp) }
            }

            foreach ($circuit in $circuits) {
                $circuitId   = $circuit.id
                $circuitName = if ($circuit.name) { $circuit.name } else { "Circuit-$circuitId" }
                $circuitType = if ($circuit.type) { $circuit.type } else { 'unknown' }

                $circAttrs = $siteAttrs.Clone()
                $circAttrs['Bigleaf.CircuitId']   = "$circuitId"
                $circAttrs['Bigleaf.CircuitName']  = $circuitName
                $circAttrs['Bigleaf.CircuitType']  = $circuitType
                $circAttrs['Bigleaf.DeviceType']   = 'Circuit'

                # Active Monitor: Circuit connectivity
                $circuitHealthUrl = "${baseApi}/sites/${siteId}/circuits/status"
                $items += New-DiscoveredItem `
                    -Name "Bigleaf Circuit Health - $siteName - $circuitName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'RestApi' `
                    -MonitorParams @{
                        RestApiUrl                    = $circuitHealthUrl
                        RestApiMethod                 = 'GET'
                        RestApiTimeoutMs              = 15000
                        RestApiUseAnonymous           = '0'
                        RestApiDownIfResponseCodeIsIn = '[401,403,404,500,502,503]'
                    } `
                    -UniqueKey "Bigleaf:${siteId}:circuit:${circuitId}:active:health" `
                    -Attributes $circAttrs `
                    -Tags @('bigleaf', 'circuit', $siteName, $circuitName)
            }

            # Get CPE/device status
            $deviceResp = $null
            try {
                Start-Sleep -Milliseconds 6500
                $deviceResp = Invoke-BigleafREST -Endpoint "/sites/$siteId/devices/status"
            }
            catch {
                Write-Verbose "  Could not get devices for site '$siteName': $_"
            }

            $devices = @()
            if ($deviceResp) {
                if ($deviceResp.data) { $devices = @($deviceResp.data) }
                elseif ($deviceResp -is [array]) { $devices = @($deviceResp) }
            }

            foreach ($dev in $devices) {
                $devId   = $dev.id
                $devName = if ($dev.name) { $dev.name } else { "Device-$devId" }
                $devType = if ($dev.type) { $dev.type } else { 'CPE' }
                $devIp   = if ($dev.ip) { $dev.ip } else { $null }

                $devAttrs = $siteAttrs.Clone()
                $devAttrs['Bigleaf.DeviceId']    = "$devId"
                $devAttrs['Bigleaf.DeviceName']  = $devName
                $devAttrs['Bigleaf.DeviceType']  = $devType
                if ($devIp) { $devAttrs['Bigleaf.IPAddress'] = $devIp }
            }
        }

        return $items
    }

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBMufiFOhsMoDQ0
# afXCuGm3PMGAFHBYK+6+RKjD2iiERKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgd3dNVyb1mOy7AXZAXvZRvIKWOr4JIExK
# kQYXp8q0P58wDQYJKoZIhvcNAQEBBQAEggIADACdiIyvRd3KLr3u9lFNp6Ep6qRN
# XnM36GvdPChRNlXLno5ldzvZLw/Jty0N9wbhT00SbYSfoFND7kMl9gzS8UbpaVCS
# oHeO4ZFTgTGurIkl1gkgFoQjB5qCLhM85emN8g/pDomq9AKQz84ANmQvlc4h+6IA
# h/DiWk+73B6lpu2Z1BDoD2FRYrvZKsW4WDgH8DNZRTAYQ0ud+rmaYzT8T23jwg4i
# XiuQ+AbYshd37Ycg7f4VfPwzLEv7DYlMpbMJNOWXiAaopGbwTGEl21jq4ajCraXw
# YQTyVzmouKkVGXjHm9Pe3/pGXK0NU1UXlkAdG+EeEaGMjWCcYalpiSgvmjbY78YC
# /urV3zol2MWt4f93lPAWO1xKPXYLnGHpuX2JeKV0pMHEo6UnyX8FHG1S2pl7ElPc
# usOazeoCI/aA3iZhG4WNSD+6wZ2EbwfvdpbGWqn9mVdL7YNUIbP+89BQuMXJIW71
# q3qRs/nOCBllVngNHYKXFzK6C1iLw5RyeZYBGUWYFS6zHedKatoQrJqsgAoAVYRw
# ovyzmECW1qkhTP76HP0YvEtk+jIVJftkc1Y0oRAUyyjmaSzBda1EL3e3vvOL2JJq
# t1DBO7/E69prrTQlN9WANnLgpwjlNFtwEXCEnKzMvTaXAxJjvqNWd5sx8XUrtreM
# O43ZK0Tu08SMvrQ=
# SIG # End signature block
