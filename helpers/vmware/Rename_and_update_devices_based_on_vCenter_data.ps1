# Specify the hostname or IP to your vCenter server(s)
$vCenterServer = "192.168.23.60"
#Specify the WhatsUp Gold IP Address or Hostname
$WUGServer = "192.168.1.250"

#Set your VMware Cred
if(!$VMwareCred){$VMwareCred = (Get-Credential -UserName "administrator@vsphere.local")}
#Set your WhatsUp Gold Cred
if(!$WUGCred){$WUGCred = (Get-Credential -UserName "admin")}

# Check if the WhatsUpGoldPS module is loaded, and if not, import it
if (-not (Get-Module -Name WhatsUpGoldPS)) {Import-Module WhatsUpGoldPS}
# Check if the VMware modules are loaded, and if not, import it
if (-not (Get-Module -Name VMware.Vim)) {Import-Module VMware.Vim}
if (-not (Get-Module -Name VMware.VimAutomation.Cis.Core)) {Import-Module VMware.VimAutomation.Cis.Core}
if (-not (Get-Module -Name VMware.VimAutomation.Common)) {Import-Module VMware.VimAutomation.Common}
if (-not (Get-Module -Name VMware.VimAutomation.Core)) {Import-Module VMware.VimAutomation.Core}
if (-not (Get-Module -Name VMware.VimAutomation.Sdk)) {Import-Module VMware.VimAutomation.Sdk}

Connect-VIServer $vCenterServer -Credential $VMwareCred
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# Gather VM guest info from vCenter
Write-Host "`n=== Gathering VM data from vCenter ===" -ForegroundColor Cyan
$vmData = foreach ($vm in (Get-VM)) {
    $guest = $vm | Get-VMGuest
    $ipAddr = $guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
    $nics = $vm | Get-NetworkAdapter
    $disks = $vm | Get-HardDisk

    [PSCustomObject]@{
        VmName           = $vm.Name
        IPAddress        = $ipAddr
        PowerState       = $vm.PowerState.ToString()
        ESXiHost         = $vm.VMHost.Name
        Cluster          = $vm.VMHost.Parent.Name
        OSFullName       = $guest.OSFullName
        GuestFamily      = $guest.GuestFamily
        GuestId          = $guest.GuestId
        ToolsStatus      = $vm.ExtensionData.Guest.ToolsStatus
        NumCPU           = $vm.NumCpu
        MemoryGB         = $vm.MemoryGB
        ProvisionedGB    = [math]::Round($vm.ProvisionedSpaceGB, 2)
        UsedSpaceGB      = [math]::Round($vm.UsedSpaceGB, 2)
        NicCount         = $nics.Count
        NicTypes         = ($nics.Type | Select-Object -Unique) -join ", "
        NetworkNames     = ($nics.NetworkName | Select-Object -Unique) -join ", "
        DiskCount        = $disks.Count
        DiskTotalGB      = [math]::Round(($disks | Measure-Object -Property CapacityGB -Sum).Sum, 2)
    }
}

$vmData | Format-Table VmName, IPAddress, PowerState, Cluster, ESXiHost, OSFullName, NumCPU, MemoryGB -AutoSize

# Update each VM in WUG
Write-Host "`n=== Updating existing WUG devices ===" -ForegroundColor Cyan
$updated = 0; $skipped = 0

foreach ($vm in $vmData) {
    if ($vm.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping $($vm.VmName) - no valid IPv4 address"
        $skipped++
        continue
    }

    # Look up existing device in WUG by IP
    $device = Get-WUGDevice -SearchValue $vm.IPAddress -View id
    if (-not $device) {
        Write-Warning "Skipping $($vm.VmName) ($($vm.IPAddress)) - not found in WUG"
        $skipped++
        continue
    }
    $DeviceID = $device.id | Select-Object -First 1

    Write-Host "Updating $($vm.VmName) ($($vm.IPAddress)) - Device ID: $DeviceID" -ForegroundColor Yellow

    # Update display name and note
    $note = "vCenter sync $((Get-Date).ToString('yyyy-MM-dd HH:mm')) | " +
            "$($vm.OSFullName) | $($vm.NumCPU) vCPU, $($vm.MemoryGB) GB RAM | " +
            "Host: $($vm.ESXiHost) | Cluster: $($vm.Cluster) | " +
            "Disk: $($vm.ProvisionedGB) GB provisioned, $($vm.UsedSpaceGB) GB used | " +
            "NICs: $($vm.NicCount) ($($vm.NetworkNames))"

    Set-WUGDeviceProperties -DeviceId $DeviceID -DisplayName $vm.VmName -note $note

    # Update attributes - each call creates or updates the named attribute
    $attributes = @{
        "vSphere_GuestOS"       = "$($vm.OSFullName)"
        "vSphere_GuestFamily"   = "$($vm.GuestFamily)"
        "vSphere_GuestId"       = "$($vm.GuestId)"
        "vSphere_ToolsStatus"   = "$($vm.ToolsStatus)"
        "vSphere_PowerState"    = "$($vm.PowerState)"
        "vSphere_ESXiHost"      = "$($vm.ESXiHost)"
        "vSphere_Cluster"       = "$($vm.Cluster)"
        "vSphere_NumCPU"        = "$($vm.NumCPU)"
        "vSphere_MemoryGB"      = "$($vm.MemoryGB)"
        "vSphere_ProvisionedGB" = "$($vm.ProvisionedGB)"
        "vSphere_UsedSpaceGB"   = "$($vm.UsedSpaceGB)"
        "vSphere_NicCount"      = "$($vm.NicCount)"
        "vSphere_NicTypes"      = "$($vm.NicTypes)"
        "vSphere_NetworkNames"  = "$($vm.NetworkNames)"
        "vSphere_DiskCount"     = "$($vm.DiskCount)"
        "vSphere_DiskTotalGB"   = "$($vm.DiskTotalGB)"
        "vSphere_LastSync"      = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    }

    foreach ($attr in $attributes.GetEnumerator()) {
        if ($attr.Value -and $attr.Value -ne "") {
            Set-WUGDeviceAttribute -DeviceId $DeviceID -Name $attr.Key -Value $attr.Value
        }
    }

    Write-Host "  Updated with $($attributes.Count) attributes" -ForegroundColor Green
    $updated++
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Updated: $updated devices"
Write-Host "  Skipped: $skipped devices"

# Cleanup
Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD5W0b2bo+MjNer
# p22VcVNe31voSqSooLsocZeE3jcf26CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgdoNyhBvUAKoSV7KR19ZN2wOkrRiipNnx
# ixHlEg06IyAwDQYJKoZIhvcNAQEBBQAEggIAy61AP6Pot6anQ9vId1MT+Y1OMNQs
# n6xbhbf+8VvWIahb5bK1vtzGR5blQ6dAa0ZPm6D7nNY961qcg1INZL4S9rwNArH6
# 6p17aKPhjxG/9xV7Jnn4CwcKoWYDTQckcDYa9V5cwlpDL6QJklGVLzjeSTEIavFs
# +5alhnZ5ioZSB1/GXODaxox4TbNoHbMwnZoJa2rCaWXZoYp+iDbMKTFPIPs2e1xM
# APBl+OOM43HA+35/Xu90QA2A5cyt3/5YLyz9eMskZ+7sA1rJd3u7fr7B30zADiuN
# kVxrpz7sHXktcgKl2JOrrJbO6aqHCe41HLgwIKCODHFgFLjOjelDz8cdLMRcVgym
# LvVPP+0XTIj1C2eL0MuaW5D/cbt6r4ZANCjadZsSnK919+a1jAJCPigPBbyN/HKu
# d7yb6dxLJo0n23wzxmv16b36A8nSuw+VqlfpHa9yIBufvWKh96kEX8OiihMdoMJW
# 7BJTMkCHTuCx49scdTEAyIGSk6AUn1CUgitDGkIelzOEYRpL7pQGEOFdJ/znbymQ
# KMjLn9fjPYs5BFgawf/x4A4Ms14DbLZdqvSzJup9oAvYHZqKZoGhbYxAb+tLql/u
# 0hMwfJEYBqX/NDqkOhNnvmy0SJMKwQP32+EWLtXM4q4lHgzTqAxxW12oyC0XTldc
# bZkKij/WzAJkRJ8=
# SIG # End signature block
