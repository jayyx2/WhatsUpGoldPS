# Configuration
$HypervHosts = @("192.168.1.10", "192.168.1.11")  # Hyper-V host IPs or hostnames
$WUGServer   = "192.168.74.74"

# Credentials
if (!$HypervCred) { $HypervCred = Get-Credential -Message "Enter credentials for Hyper-V host(s)" }
if (!$WUGCred)    { $WUGCred    = Get-Credential -Message "Enter credentials for WUG server" }

# Check if the WhatsUpGoldPS module is loaded
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

# Load helper functions
. "$PSScriptRoot\HypervHelpers.ps1"

# ========================
# Discover Hyper-V Hosts and VMs
# ========================
$hostResults = @()
$vmResults   = @()

foreach ($hvHost in $HypervHosts) {
    Write-Host "`n=== Connecting to Hyper-V host: $hvHost ===" -ForegroundColor Cyan
    try {
        $session = Connect-HypervHost -ComputerName $hvHost -Credential $HypervCred
    }
    catch {
        Write-Warning "Failed to connect to $hvHost : $_"
        continue
    }

    # Gather host detail
    $hostDetail = Get-HypervHostDetail -CimSession $session
    $hostResults += $hostDetail

    # Gather VMs
    $vms = Get-HypervVMs -CimSession $session
    foreach ($vm in $vms) {
        $vmDetail = Get-HypervVMDetail -CimSession $session -VM $vm
        $vmResults += $vmDetail
    }

    Remove-CimSession -CimSession $session
}

# Output results
Write-Host "`n=== Hyper-V Hosts ===" -ForegroundColor Cyan
$hostResults | Format-Table HostName, IPAddress, OSName, CPUSockets, CPUCores, RAM_TotalGB, Status -AutoSize

Write-Host "`n=== Hyper-V VMs ===" -ForegroundColor Cyan
$vmResults | Sort-Object Host, Name | Format-Table Name, IPAddress, Host, State, CPUCount, MemoryAssignedGB, DiskTotalGB -AutoSize

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# --- Hyper-V Hosts ---
Write-Host "`n=== Adding Hyper-V Hosts to WUG ===" -ForegroundColor Cyan
foreach ($host_ in $hostResults) {
    if ($host_.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping host $($host_.HostName) due to invalid IP: $($host_.IPAddress)"
        continue
    }

    if (Get-WUGDevice -SearchValue $host_.IPAddress -View id) {
        Write-Warning "Skipping already monitored host $($host_.HostName) ($($host_.IPAddress))"
        continue
    }

    # Build attributes from all properties
    $attributes = @(
        @{ Name = "HyperV_Type";         Value = "Hyper-V Host" }
        @{ Name = "HyperV_HostName";     Value = "$($host_.HostName)" }
        @{ Name = "HyperV_OSName";       Value = "$($host_.OSName)" }
        @{ Name = "HyperV_OSVersion";    Value = "$($host_.OSVersion)" }
        @{ Name = "HyperV_OSBuild";      Value = "$($host_.OSBuild)" }
        @{ Name = "HyperV_Manufacturer"; Value = "$($host_.Manufacturer)" }
        @{ Name = "HyperV_Model";        Value = "$($host_.Model)" }
        @{ Name = "HyperV_Domain";       Value = "$($host_.Domain)" }
        @{ Name = "HyperV_CPUModel";     Value = "$($host_.CPUModel)" }
        @{ Name = "HyperV_CPUSockets";   Value = "$($host_.CPUSockets)" }
        @{ Name = "HyperV_CPUCores";     Value = "$($host_.CPUCores)" }
        @{ Name = "HyperV_CPULogical";   Value = "$($host_.CPULogical)" }
        @{ Name = "HyperV_RAM_TotalGB";  Value = "$($host_.RAM_TotalGB)" }
        @{ Name = "HyperV_RAM_FreeGB";   Value = "$($host_.RAM_FreeGB)" }
        @{ Name = "HyperV_Uptime";       Value = "$($host_.Uptime)" }
    )

    $note = "Hyper-V Host | $($host_.OSName) | $($host_.Manufacturer) $($host_.Model) | " +
            "$($host_.CPUSockets)S/$($host_.CPUCores)C/$($host_.CPULogical)T | $($host_.RAM_TotalGB) GB RAM | " +
            "Domain: $($host_.Domain) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $host_.HostName `
        -DeviceAddress $host_.IPAddress `
        -Brand "Microsoft Hyper-V Host" `
        -OS $host_.OSName `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added Hyper-V host $($host_.HostName) ($($host_.IPAddress))" -ForegroundColor Green
    }
}

# --- Virtual Machines ---
Write-Host "`n=== Adding VMs to WUG ===" -ForegroundColor Cyan
foreach ($vm in $vmResults) {
    if ($vm.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping VM $($vm.Name) - invalid/missing IP: $($vm.IPAddress)"
        continue
    }

    if (Get-WUGDevice -SearchValue $vm.IPAddress -View id) {
        Write-Warning "Skipping already monitored VM $($vm.Name) ($($vm.IPAddress))"
        continue
    }

    $attributes = @(
        @{ Name = "HyperV_Type";             Value = "Virtual Machine" }
        @{ Name = "HyperV_Host";             Value = "$($vm.Host)" }
        @{ Name = "HyperV_State";            Value = "$($vm.State)" }
        @{ Name = "HyperV_Status";           Value = "$($vm.Status)" }
        @{ Name = "HyperV_Generation";       Value = "$($vm.Generation)" }
        @{ Name = "HyperV_Version";          Value = "$($vm.Version)" }
        @{ Name = "HyperV_CPUCount";         Value = "$($vm.CPUCount)" }
        @{ Name = "HyperV_CPUUsagePct";      Value = "$($vm.CPUUsagePct)" }
        @{ Name = "HyperV_MemoryAssignedGB"; Value = "$($vm.MemoryAssignedGB)" }
        @{ Name = "HyperV_MemoryStartupGB";  Value = "$($vm.MemoryStartupGB)" }
        @{ Name = "HyperV_DynamicMemory";    Value = "$($vm.DynamicMemory)" }
        @{ Name = "HyperV_DiskCount";        Value = "$($vm.DiskCount)" }
        @{ Name = "HyperV_DiskTotalGB";      Value = "$($vm.DiskTotalGB)" }
        @{ Name = "HyperV_NicCount";         Value = "$($vm.NicCount)" }
        @{ Name = "HyperV_SwitchNames";      Value = "$($vm.SwitchNames)" }
        @{ Name = "HyperV_VLanIds";          Value = "$($vm.VLanIds)" }
        @{ Name = "HyperV_SnapshotCount";    Value = "$($vm.SnapshotCount)" }
        @{ Name = "HyperV_Heartbeat";        Value = "$($vm.Heartbeat)" }
        @{ Name = "HyperV_ReplicationState"; Value = "$($vm.ReplicationState)" }
    )

    $note = "Hyper-V VM on $($vm.Host) | $($vm.CPUCount) vCPU, $($vm.MemoryAssignedGB) GB RAM | " +
            "Gen $($vm.Generation) v$($vm.Version) | Disks: $($vm.DiskCount) ($($vm.DiskTotalGB) GB) | " +
            "NICs: $($vm.NicCount) ($($vm.SwitchNames)) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $vm.Name `
        -DeviceAddress $vm.IPAddress `
        -Brand "Microsoft Hyper-V VM" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added VM $($vm.Name) ($($vm.IPAddress))" -ForegroundColor Green
    }
}

# Cleanup
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCKmMKwnHyGJT33
# A4XJ9NHb+3eFpl3HkjcofxW3ofZNiqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg1cAxKNAXLZYLp9WBXO7z2Ujz9un1cRGG
# ey9cVRhG5PUwDQYJKoZIhvcNAQEBBQAEggIA7xwYkz8nAx9pOhfUz6jHLpqi5kQ1
# 1+h0skStEX7mXT+V/V8jg7ukPQBXRLTWPlOI9W0PYUssOBC5ioZB5O3yoNY6U4+P
# U+4r/cxqCs3BAdp9hryBH8Iz10fcrhkn2W9VT4R0Tn9hVttMvqs/0cwSBO/+xDxD
# Tk5EIk1CP6ea+a5mE1iRMZY23jlkJ2yh8HhIpm6yd+oQBvmVQNrnG3epXCjqFTAE
# DBH+kxsJKzJ7pBDZ1prOiorchuOTBbxK3clCHMzeMxU2Vv/2LUrOLs6ht15nNMd/
# EkZ6R4odtL38usl3IlTM+7hyxhGdziLeoSxV+NzSqfdvZJZW4s7GU8n+SP7rU+Kc
# 30HoTuLoHLWAhIWgvYM43s5DCBR6bS4Aft2V4UMkqgUyGPIJigby21C5/+KatZY7
# sZAF07PliQ3pibQ1yYsCdqbA0Q5X0IILuyHlNCghsKb/tuOYLoK/zi0pyfR2UGlg
# Ag+bqdJP0mLqr9nCAKxHiwwf5t3ZbIce9W/cr9SdEaQFOt4r3C1xqdJpeFaxG/zL
# vSvq1uA+H5+ZyhANxf06hOeJSyGO+CN5itfLTFisqx0BytyxV+P1JHGD8EeKXOc5
# CF6Xn2+oZStDn6WiahC4YFy5ExTUkmROXI77kF2GjYXtYmJZ/bU7vtfDNjjCJ/w9
# os973fYhas4jbHk=
# SIG # End signature block
