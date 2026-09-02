#requires -Version 5.1

function ConvertFrom-BgpSshOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Output,
        [Parameter(Mandatory = $true)] [string]$Target
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $section = ''
    $localAs = $null
    $routerId = $null
    $currentPeer = $null
    foreach ($line in @($Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match 'show ip bgp summary') { $section = 'Summary'; continue }
        if ($trimmed -match 'show ip bgp neighbors') { $section = 'Neighbors'; continue }
        if ($trimmed -match 'show ip bgp(?:\s*$|\s+\|)') { $section = 'Routes'; continue }
        if (-not $trimmed) { continue }

        if ($section -eq 'Summary') {
            if ($trimmed -match 'BGP router identifier\s+(\S+),\s+local AS number\s+(\d+)') {
                $routerId = $Matches[1]; $localAs = [int]$Matches[2]; continue
            }
            if ($trimmed -match 'local AS number\s+(\d+)') { $localAs = [int]$Matches[1]; continue }
            if ($trimmed -match '^BGP table version is\s+(\d+)') {
                $rows.Add([pscustomobject][ordered]@{
                    Source = 'SSH'; Target = $Target; RecordType = 'Summary'; Status = 'Collected'
                    LocalAs = $localAs; RouterId = $routerId; TableVersion = [int]$Matches[1]
                }); continue
            }
            if ($trimmed -match '^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)$') {
                $peerAddress = $Matches[1]
                $version = [int]$Matches[2]
                $remoteAs = [int]$Matches[3]
                $msgReceived = [int]$Matches[4]
                $msgSent = [int]$Matches[5]
                $tableVersion = [int]$Matches[6]
                $inQueue = [int]$Matches[7]
                $outQueue = [int]$Matches[8]
                $uptime = $Matches[9]
                $stateOrPrefixes = $Matches[10]
                $state = if ($stateOrPrefixes -match '^\d+$') { 'Established' } else { $stateOrPrefixes }
                $prefixesReceived = if ($stateOrPrefixes -match '^\d+$') { [int]$stateOrPrefixes } else { 0 }
                $rows.Add([pscustomobject][ordered]@{
                    Source = 'SSH'; Target = $Target; RecordType = 'Peer'; Status = if ($state -eq 'Established') { 'Healthy' } else { 'Critical' }
                    PeerAddress = $peerAddress; Version = $version; RemoteAs = $remoteAs
                    MsgReceived = $msgReceived; MsgSent = $msgSent; TblVersion = $tableVersion
                    InQ = $inQueue; OutQ = $outQueue; Uptime = $uptime
                    State = $state; PrefixesReceived = $prefixesReceived
                    LocalAs = $localAs; RouterId = $routerId
                }); continue
            }
        }
        elseif ($section -eq 'Neighbors') {
            if ($trimmed -match '^BGP neighbor is\s+(\S+),\s+remote AS (\d+)') {
                $currentPeer = $Matches[1]
                $rows.Add([pscustomobject][ordered]@{
                    Source = 'SSH'; Target = $Target; RecordType = 'PeerDetail'; Status = 'Collected'
                    PeerAddress = $Matches[1]; RemoteAs = [int]$Matches[2]; Detail = $trimmed
                }); continue
            }
            if ($trimmed -match '^BGP state = (\S+),.*') {
                $rows.Add([pscustomobject][ordered]@{
                    Source = 'SSH'; Target = $Target; RecordType = 'PeerDetail'; Status = $Matches[1]
                    PeerAddress = $currentPeer; State = $Matches[1]; Detail = $trimmed
                }); continue
            }
            if ($trimmed -match '^(?:Last read|Last written)\s+(\S+)') { continue }
            if ($trimmed -match '^(\d+) network entries using') {
                $rows.Add([pscustomobject][ordered]@{
                    Source = 'SSH'; Target = $Target; RecordType = 'PeerDetail'; Status = 'Collected'
                    PeerAddress = $currentPeer; PrefixesReceived = [int]$Matches[1]; Detail = $trimmed
                }); continue
            }
        }
        elseif ($section -eq 'Routes') {
            if ($trimmed -match '^(?:Status codes:|Path:|Origin codes:|BGP table version|Displayed|Total number)') { continue }
            if ($trimmed -match '^[*> ]+([0-9a-fA-F:.]+(?:/\d+))\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(\S+)') {
                $rows.Add([pscustomobject][ordered]@{
                    Source = 'SSH'; Target = $Target; RecordType = 'Route'; Status = 'Installed'
                    Prefix = $Matches[1]; NextHop = $Matches[2]; Metric = $Matches[3]; LocalPreference = [int]$Matches[4]
                    Weight = $Matches[5]; Path = $Matches[6]
                }); continue
            }
        }
    }
    return @($rows)
}

function Merge-BgpPeerData {
    [CmdletBinding()]
    param(
        [object[]]$SnmpPeers = @(),
        [object[]]$SshRows = @()
    )
    $sshPeers = @($SshRows | Where-Object { $_.RecordType -eq 'Peer' -and $_.PeerAddress })
    $sshDetails = @($SshRows | Where-Object { $_.RecordType -eq 'PeerDetail' -and $_.PeerAddress })
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($peer in @($SnmpPeers)) {
        $match = @($sshPeers | Where-Object { [string]$_.PeerAddress -eq [string]$peer.PeerAddress } | Select-Object -First 1)
        $detail = @($sshDetails | Where-Object { [string]$_.PeerAddress -eq [string]$peer.PeerAddress } | Select-Object -First 1)
        $row = [ordered]@{}
        foreach ($property in $peer.PSObject.Properties) { $row[$property.Name] = $property.Value }
        if ($match) {
            $row['SshState'] = $match[0].State
            $row['PrefixesReceived'] = $match[0].PrefixesReceived
            $row['MsgReceived'] = $match[0].MsgReceived
            $row['MsgSent'] = $match[0].MsgSent
            $row['Uptime'] = $match[0].Uptime
        }
        if ($detail) { $row['SshDetail'] = $detail[0].Detail }
        $merged.Add([pscustomobject]$row)
    }
    foreach ($peer in $sshPeers) {
        if (-not (@($SnmpPeers | Where-Object { [string]$_.PeerAddress -eq [string]$peer.PeerAddress }))) { $merged.Add($peer) }
    }
    return @($merged)
}

function Get-BgpSshInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [string]$Username,
        [string]$Password,
        [System.Security.SecureString]$SecurePassword,
        [int]$Port = 22,
        [int]$TimeoutSeconds = 30,
        [string]$SshModulePath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psm1')
    )
    if (-not (Test-Path -LiteralPath $SshModulePath)) { throw "SSH module not found: $SshModulePath" }
    Import-Module -Name $SshModulePath -Force -ErrorAction Stop
    $splat = @{ HostName = $Target; Port = $Port; Username = $Username; TimeoutSeconds = $TimeoutSeconds }
    if ($Password) { $splat['Password'] = $Password }
    if ($SecurePassword) { $splat['SecurePassword'] = $SecurePassword }
    $session = New-SshSession @splat
    try {
        $commands = @('show ip bgp summary', 'show ip bgp', 'show ip bgp neighbors')
        $output = [System.Collections.Generic.List[string]]::new()
        foreach ($command in $commands) {
            $result = Invoke-SshCommand -Session $session -Command $command -TimeoutSeconds $TimeoutSeconds
            [void]$output.Add($command)
            [void]$output.Add($result.Output)
        }
        return @(ConvertFrom-BgpSshOutput -Output ($output -join "`r`n") -Target $Target)
    }
    finally { Close-SshSession -Session $session }
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA/HHLsg4dsGi/G
# gbs+BEMFZCATUr12GMbpVaEI2aFfiaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgDR0WkA839/F944dNDAhd0wfv3ubwBI/y
# k/o+hwkRrlcwDQYJKoZIhvcNAQEBBQAEggIASkdPqguqz8L2TPK1bA3LmrSK+H0j
# +avoxqzV9dthsD67+yKiLDjPOSdi5TBwuRpBewrKDI+9B6VyAx3U2SYu6Dkt9PBV
# 0zMKsuHT0/FosE4sJlE1kZmF+TLnPVPL5r8iaB1PbXMnsyyAI+Nm3XnLPcXQlJH1
# v/kwZikKoYFUqvWsciIAGl5vju/p1Qygjjk/T3C2/tAqU0MqH6aRbDRCy/7QnpaV
# 3Y9IndFuyX7vFGTQB2IGLWoEtjupMig7II1zgiSAcyHk356L77O6B+QnmN9a0bz8
# W6u6CxBi4Pp+wJPWi+iyNP4K4ECQhkSNgBJTUjQVEI9lrikgnHhHxMZHqpV1pnvS
# dxPACr3dAYFM6Ie+oYNJ/I/n+sc2o9Xg6pXlAMJO4w0wsYUi6Cvtca6Ay8GZWCyW
# /HCUgpcQTmnufLrAjKaGY8UE1mQGdQMRdO9BHAU30GN/INfXzwMR1MM6d1Ue+eMo
# 00onYmK/BssgZH3+OlcQ32oEc7hunUlCk3bJAtlfwEbCzd1/lDHeUqIcEeyXWtY1
# wR2uq5Px0A9fk6p/VqU9hgeBgZ+99GvQoGSRHvKhyxCKd8orhl30KDJUvjqY2/Ar
# +9TSy6Nl+orAnoUsHGSDthfQZle5l+oBSWeixxcvYm5gb5nltCG3zGD6hU4dIJm9
# opA8NLCgUMz1Z4g=
# SIG # End signature block
