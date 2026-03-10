# =============================================================================
# Certificate Discovery Helpers for WhatsUpGoldPS
# Scans IP addresses across multiple TCP ports to discover TLS certificates
# and produce dashboard-ready data — similar to the F5 BIG-IP helpers.
#
# No additional modules required — uses .NET TcpClient + SslStream directly.
#
# Typical workflow:
#   1. Get-CertificateInfo     (discovers certs across IPs + ports)
#   2. Get-CertificateDashboard (enriches with WUG device data, computes expiry)
#   3. Export-CertificateDashboardHtml (renders an HTML report from template)
# =============================================================================

# ---------------------------------------------------------------------------
# Get-CertificateInfo
# ---------------------------------------------------------------------------
function Get-CertificateInfo {
    <#
    .SYNOPSIS
        Discovers TLS certificates by connecting to IP:port combinations.
    .DESCRIPTION
        For each IP address and TCP port combination, opens a TLS connection,
        retrieves the remote certificate, and returns rich certificate metadata.
        Failures are logged as warnings and skipped gracefully.
    .PARAMETER IPAddresses
        Array of IP addresses or hostnames to scan.
    .PARAMETER TcpPorts
        Array of TCP ports to try for each address. Defaults to 443, 8443.
    .PARAMETER ConnectTimeoutMs
        TCP connection timeout in milliseconds. Defaults to 5000.
    .EXAMPLE
        Get-CertificateInfo -IPAddresses "10.0.0.1"
        # Scans 10.0.0.1 on default ports (443, 8443).
    .EXAMPLE
        Get-CertificateInfo -IPAddresses "10.0.0.1","10.0.0.2" -TcpPorts 443,8443,4443
        # Scans two hosts across three ports (6 total connection attempts).
    .EXAMPLE
        Get-CertificateInfo -IPAddresses (Get-Content .\hosts.txt) -ConnectTimeoutMs 3000
        # Reads IPs from a file and uses a 3-second timeout per connection.
    .EXAMPLE
        $certs = Get-CertificateInfo -IPAddresses "webserver01" -TcpPorts 443
        $certs | Select-Object IPAddress, Port, Subject, ExpirationDate
        # Scan a single host and display key fields.
    .EXAMPLE
        # Pull device IPs from WhatsUp Gold and scan them
        $devices = Get-WUGDevice -View overview
        Get-CertificateInfo -IPAddresses $devices.networkAddress -TcpPorts 443,8443
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$IPAddresses,

        [Parameter()]
        [int[]]$TcpPorts = @(443, 8443),

        [Parameter()]
        [int]$ConnectTimeoutMs = 5000
    )

    $results = @()

    foreach ($IPAddress in $IPAddresses) {
        Write-Host "Processing: $IPAddress" -ForegroundColor Cyan
        foreach ($port in $TcpPorts) {
            $tcpClient = $null
            $sslStream = $null

            try {
                # Connect with timeout
                $tcpClient = [System.Net.Sockets.TcpClient]::new()
                $connectTask = $tcpClient.ConnectAsync($IPAddress, [int]$port)
                if (-not $connectTask.Wait($ConnectTimeoutMs)) {
                    throw "Timeout after ${ConnectTimeoutMs}ms connecting to ${IPAddress}:${port}"
                }

                # SSL stream with permissive validation (read cert only)
                $sslStream = [System.Net.Security.SslStream]::new(
                    $tcpClient.GetStream(),
                    $false,
                    { param($sender, $cert, $chain, $errors) $true }
                )

                # Authenticate (TLS 1.2)
                $sslStream.AuthenticateAsClient(
                    $IPAddress,
                    $null,
                    [System.Security.Authentication.SslProtocols]::Tls12,
                    $false
                )

                # Grab and normalize certificate to X509Certificate2
                $remoteCert = $sslStream.RemoteCertificate
                if ($null -eq $remoteCert) { throw "Failed to retrieve certificate from ${IPAddress}:${port}" }
                $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($remoteCert)

                # Extract SAN (Subject Alternative Names)
                $sanExt = $certificate.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }
                $san = if ($sanExt) { $sanExt.Format(0) } else { "" }

                # Extract certificate information
                $certObj = [PSCustomObject][ordered]@{
                    IPAddress      = $IPAddress
                    Port           = [int]$port
                    Subject        = $certificate.Subject
                    Issuer         = $certificate.Issuer
                    ExpirationDate = $certificate.NotAfter
                    EffectiveDate  = $certificate.NotBefore
                    Thumbprint     = $certificate.Thumbprint
                    SerialNumber   = $certificate.SerialNumber
                    SAN            = $san
                    KeyAlgorithm   = $certificate.GetKeyAlgorithm()
                    KeyLength      = if ($certificate.PublicKey.Key) {
                        try { $certificate.PublicKey.Key.KeySize } catch { 0 }
                    } else { 0 }
                    SignatureAlgorithm = $certificate.SignatureAlgorithm.FriendlyName
                    Version        = $certificate.Version
                    Format         = $certificate.GetFormat()
                    Extensions     = if ($certificate.Extensions) {
                        ($certificate.Extensions | ForEach-Object { "$($_.Oid.FriendlyName): $($_.Format(0))" }) -join '; '
                    } else { "None" }
                }

                $results += $certObj
                Write-Host "  Found cert on port ${port}: $($certificate.Subject)" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Failed ${IPAddress}:${port} - $($_.Exception.Message)"
            }
            finally {
                if ($sslStream) { $sslStream.Dispose() }
                if ($tcpClient) { $tcpClient.Dispose() }
            }
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Get-CertificateDashboard
# ---------------------------------------------------------------------------
function Get-CertificateDashboard {
    <#
    .SYNOPSIS
        Builds enriched dashboard data from raw certificate scan results.
    .DESCRIPTION
        Takes the output of Get-CertificateInfo, computes days until expiration,
        assigns a health status (Critical/Warning/Healthy/Unknown), and
        optionally enriches each row with WhatsUp Gold device data if connected.
    .PARAMETER CertificateData
        Array of objects from Get-CertificateInfo.
    .PARAMETER WarningDays
        Certificates expiring within this many days are flagged as Warning.
        Defaults to 90.
    .PARAMETER CriticalDays
        Certificates expiring within this many days are flagged as Critical.
        Defaults to 30.
    .EXAMPLE
        $certs = Get-CertificateInfo -IPAddresses "10.0.0.1" -TcpPorts 443
        Get-CertificateDashboard -CertificateData $certs
        # Enriches raw cert data with default thresholds (Warning: 90d, Critical: 30d).
    .EXAMPLE
        $certs = Get-CertificateInfo -IPAddresses "10.0.0.1","10.0.0.2"
        Get-CertificateDashboard -CertificateData $certs -WarningDays 60 -CriticalDays 14
        # Uses custom thresholds: warn at 60 days, critical at 14 days.
    .EXAMPLE
        $certs = Get-CertificateInfo -IPAddresses "10.0.0.1"
        $dashboard = Get-CertificateDashboard -CertificateData $certs
        $dashboard | Where-Object { $_.Status -eq 'Critical' } | Format-Table IPAddress, Port, DaysUntilExpiry, Subject
        # Filter to only critical certificates and display as a table.
    .EXAMPLE
        # Full pipeline: scan → enrich → group by status
        $certs = Get-CertificateInfo -IPAddresses "10.0.0.1","10.0.0.2" -TcpPorts 443,8443
        $dashboard = Get-CertificateDashboard -CertificateData $certs
        $dashboard | Group-Object Status | Select-Object Name, Count
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CertificateData,
        [int]$WarningDays = 90,
        [int]$CriticalDays = 30
    )

    # Build a WUG device index if connected
    $deviceIndex = @{}
    if ($global:WUGBearerHeaders) {
        try {
            $wugDevices = Get-WUGDevice -View overview
            foreach ($dev in $wugDevices) {
                if ($dev.networkAddress) { $deviceIndex[$dev.networkAddress] = $dev }
            }
            Write-Verbose "Indexed $($deviceIndex.Count) WUG devices for enrichment."
        }
        catch {
            Write-Warning "Could not retrieve WUG devices for enrichment: $($_.Exception.Message)"
        }
    }

    $dashboard = @()

    foreach ($cert in $CertificateData) {
        # Compute expiration
        $exp = $null
        try { $exp = [datetime]$cert.ExpirationDate } catch { $exp = $null }
        $daysUntilExpiry = if ($exp) { [int][math]::Floor(($exp - (Get-Date)).TotalDays) } else { [int]::MaxValue }

        # Determine status
        $status = if ($daysUntilExpiry -eq [int]::MaxValue) {
            "Unknown"
        } elseif ($daysUntilExpiry -lt 0) {
            "Expired"
        } elseif ($daysUntilExpiry -le $CriticalDays) {
            "Critical"
        } elseif ($daysUntilExpiry -le $WarningDays) {
            "Warning"
        } else {
            "Healthy"
        }

        # Self-signed check
        $selfSigned = if ($cert.Subject -eq $cert.Issuer) { "Yes" } else { "No" }

        # Build the row
        $row = [ordered]@{
            IPAddress          = $cert.IPAddress
            Port               = $cert.Port
            Status             = $status
            DaysUntilExpiry    = if ($daysUntilExpiry -eq [int]::MaxValue) { "N/A" } else { $daysUntilExpiry }
            ExpirationDate     = if ($exp) { $exp.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
            EffectiveDate      = if ($cert.EffectiveDate) { ([datetime]$cert.EffectiveDate).ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
            Subject            = $cert.Subject
            Issuer             = $cert.Issuer
            SelfSigned         = $selfSigned
            SAN                = $cert.SAN
            Thumbprint         = $cert.Thumbprint
            SerialNumber       = $cert.SerialNumber
            KeyAlgorithm       = $cert.KeyAlgorithm
            KeyLength          = $cert.KeyLength
            SignatureAlgorithm = $cert.SignatureAlgorithm
            Version            = $cert.Version
        }

        # Enrich with WUG device data if available
        $dev = $null
        if ($cert.IPAddress -and $deviceIndex.ContainsKey($cert.IPAddress)) {
            $dev = $deviceIndex[$cert.IPAddress]
        }
        if ($dev) {
            $row["WUGDeviceId"]           = $dev.id
            $row["WUGDeviceName"]         = $dev.name
            $row["WUGHostName"]           = $dev.hostName
            $row["WUGRole"]               = $dev.role
            $row["WUGBrand"]              = $dev.brand
            $row["WUGOS"]                 = $dev.os
            $row["WUGBestState"]          = $dev.bestState
            $row["WUGWorstState"]         = $dev.worstState
            $row["WUGActiveMonitors"]     = $dev.totalActiveMonitors
            $row["WUGMonitorsDown"]       = $dev.totalActiveMonitorsDown
            $row["WUGNotes"]              = $dev.notes
            $row["WUGDescription"]        = $dev.description
        }
        else {
            $row["WUGDeviceId"]           = ""
            $row["WUGDeviceName"]         = ""
            $row["WUGHostName"]           = ""
            $row["WUGRole"]               = ""
            $row["WUGBrand"]              = ""
            $row["WUGOS"]                 = ""
            $row["WUGBestState"]          = ""
            $row["WUGWorstState"]         = ""
            $row["WUGActiveMonitors"]     = ""
            $row["WUGMonitorsDown"]       = ""
            $row["WUGNotes"]              = ""
            $row["WUGDescription"]        = ""
        }

        $dashboard += [PSCustomObject]$row
    }

    return $dashboard
}

# ---------------------------------------------------------------------------
# Export-CertificateDashboardHtml
# ---------------------------------------------------------------------------
function Export-CertificateDashboardHtml {
    <#
    .SYNOPSIS
        Renders certificate dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-CertificateDashboard and generates a
        Bootstrap-based HTML report with sortable, searchable, and
        exportable tables. Uses colour-coded status indicators for
        certificate expiration health.
    .PARAMETER DashboardData
        Array of objects from Get-CertificateDashboard.
    .PARAMETER OutputPath
        File path for the output HTML file.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Certificate Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        built-in template at helpers/certificates/Certificate-Dashboard-Template.html.
    .EXAMPLE
        $certs = Get-CertificateInfo -IPAddresses "10.0.0.1" -TcpPorts 443
        $dashboard = Get-CertificateDashboard -CertificateData $certs
        Export-CertificateDashboardHtml -DashboardData $dashboard -OutputPath "C:\Reports\certs.html"
        # Generates an HTML dashboard at the specified path.
    .EXAMPLE
        $certs = Get-CertificateInfo -IPAddresses "10.0.0.1","10.0.0.2"
        $dashboard = Get-CertificateDashboard -CertificateData $certs
        Export-CertificateDashboardHtml -DashboardData $dashboard -OutputPath "$env:TEMP\certs.html" -ReportTitle "Prod Certificate Audit"
        # Custom report title.
    .EXAMPLE
        # Full end-to-end: scan → enrich → HTML report → open in browser
        $certs = Get-CertificateInfo -IPAddresses (Get-Content .\hosts.txt) -TcpPorts 443,8443
        $dashboard = Get-CertificateDashboard -CertificateData $certs
        $outPath = "$env:TEMP\Certificate-Dashboard.html"
        Export-CertificateDashboardHtml -DashboardData $dashboard -OutputPath $outPath
        Start-Process $outPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Certificate Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Certificate-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    # Build column definitions for bootstrap-table
    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        # Apply formatters for status columns
        if ($prop.Name -eq 'Status') {
            $col.formatter = 'formatCertStatus'
        }
        if ($prop.Name -eq 'DaysUntilExpiry') {
            $col.formatter = 'formatDaysUntilExpiry'
        }
        if ($prop.Name -match 'WUGBestState|WUGWorstState') {
            $col.formatter = 'formatWugState'
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = $DashboardData | ConvertTo-Json -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Certificate Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCwtaOmZyGPAozz
# u1HUiRAPxcqjWsBibKCYH80LKJdRh6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgElNfTcFCu4y9r6f5HNYoobTQzMrhRRKi
# zle1trlrbEQwDQYJKoZIhvcNAQEBBQAEggIAyNbBvqI4PP2rV1IJT4M1JfySWz7G
# mzV7+FK/ICj5yHRz8JD7Pp+pMtgSJ5xawZ50uFVZRBQ7d4j0BG/4Xov4lPR+LL24
# ErxQtA7RvJfOYRQh/E88wJFvBkLnokawWkNgHR1RhHIcveovBF6mpNqNJWbKnVLm
# vjvRaaG7xBUqKPD9bVoUxX08Ibgwfr9eX0Kt4TzB12DuegHCLtY6Iaj0Bgog4XGA
# aF8ALYuoQ93u5/65hoA63TLuZDU2rlX6kNEsetNx0lulgbruc8yQH3mL58bC6NL4
# Ajp+s9zpwGDHoX5NCSJ00SUISHEhiUYlIknPMLyac3dwDbCtnqKex7X5K4LkdMQI
# TiTa8rhOR9onQVvOM/8JOuPVrMvXTSv04SLnHVjPSU9VQpsGHnkYtpJilQtRpDud
# sabXbtzrwiakb00vFCqiOcJH4MmKsMAC0W/94maZ4FLKF+O18eBT7AY4DYq0spuh
# FQFiWgwYVE91Qlazclg4X5VKI8UyG9bhM5z4uXYxWcPfMRENV1Bk6McBMTnhOpGV
# Yme9mBibcHa52DmD0bgtCeN2XOhXZsXz0Hzo4vn1zI90zcrQrBGnNrX8G/dmVgZS
# E+q6x01vlpum39LVHdezJfRJIKYDGXIJOVloZMIcPDycurlHIrIRtKuHxe1ua0Oy
# L8GQwD6hagG0PMw=
# SIG # End signature block
