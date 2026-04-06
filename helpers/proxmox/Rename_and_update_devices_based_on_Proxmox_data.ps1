# Specify the hostname or IP and port of your Proxmox server
$ProxmoxHost = "192.168.1.39"
$ProxmoxPort = "8006"
$ProxmoxUri = "https://${ProxmoxHost}:${ProxmoxPort}"

# Check if the WhatsUpGoldPS module is loaded, and if not, import it
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

# Load helper functions
. "$PSScriptRoot\ProxmoxHelpers.ps1"

# Load vault functions for credential resolution
$discoveryHelpersPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) { . $discoveryHelpersPath }

# Resolve credentials from vault
$ProxmoxCred = Resolve-DiscoveryCredential -Name "Proxmox.$ProxmoxHost.Credential" -CredType PSCredential -ProviderLabel 'Proxmox' -AutoUse
if (-not $ProxmoxCred) { throw "Proxmox credentials are required. Store them in the vault first." }
$ProxmoxUsername = $ProxmoxCred.UserName
$ProxmoxPassword = $ProxmoxCred.GetNetworkCredential().Password
$WUGCred = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -ProviderLabel 'WhatsUp Gold' -AutoUse
if (-not $WUGCred) { throw "WhatsUp Gold credentials are required. Store them in the vault first." }
$WUGServer = $WUGCred.UserName

# Ignore SSL cert validation (self-signed)
Initialize-SSLBypass

# Authenticate to Proxmox
$cookie = Connect-ProxmoxServer -Server $ProxmoxUri -Username $ProxmoxUsername -Password $ProxmoxPassword

# Connect to WUG
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# Get list of nodes and gather host + VM data
$nodes = Get-ProxmoxNodes -Server $ProxmoxUri -Cookie $cookie

$hostResults = foreach ($node in $nodes) {
    Get-ProxmoxNodeDetail -Server $ProxmoxUri -Cookie $cookie -Node $node.node
}

$vmResults = foreach ($node in $nodes) {
    $vms = Get-ProxmoxVMs -Server $ProxmoxUri -Cookie $cookie -Node $node.node
    foreach ($vm in $vms) {
        Get-ProxmoxVMDetail -Server $ProxmoxUri -Cookie $cookie -Node $node.node -VMID $vm.vmid
    }
}

# Output gathered data
Write-Host "`n=== Proxmox Hosts ===" -ForegroundColor Cyan
$hostResults | Format-Table NodeName, IPAddress, Status, CPUCores, RAM_Total, PVEVersion -AutoSize

Write-Host "`n=== Proxmox VMs ===" -ForegroundColor Cyan
$vmResults | Sort-Object Node, VMID | Format-Table Name, IPAddress, Status, Node, CPUs, RAM_Total -AutoSize

# Update each Proxmox host in WUG
Write-Host "`n=== Updating existing WUG devices (Hosts) ===" -ForegroundColor Cyan
$updated = 0; $skipped = 0

foreach ($host_ in $hostResults) {
    if ($host_.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping host $($host_.NodeName) - no valid IPv4 address"
        $skipped++
        continue
    }

    # Look up existing device in WUG by IP
    $device = Get-WUGDevice -SearchValue $host_.IPAddress -View id
    if (-not $device) {
        Write-Warning "Skipping $($host_.NodeName) ($($host_.IPAddress)) - not found in WUG"
        $skipped++
        continue
    }
    $DeviceID = $device.id | Select-Object -First 1

    Write-Host "Updating host $($host_.NodeName) ($($host_.IPAddress)) - Device ID: $DeviceID" -ForegroundColor Yellow

    # Update display name and note
    $note = "Proxmox sync $((Get-Date).ToString('yyyy-MM-dd HH:mm')) | " +
            "PVE $($host_.PVEVersion) | Kernel: $($host_.KernelVersion) | " +
            "CPU: $($host_.CPUModel) ($($host_.CPUSockets)S/$($host_.CPUCores)C/$($host_.CPUThreads)T) | " +
            "RAM: $($host_.RAM_Used) / $($host_.RAM_Total) | " +
            "RootFS: $($host_.RootFS_Used) / $($host_.RootFS_Total) | " +
            "Load: $($host_.LoadAvg1) $($host_.LoadAvg5) $($host_.LoadAvg15)"

    Set-WUGDeviceProperties -DeviceId $DeviceID -DisplayName $host_.NodeName -note $note

    # Update attributes
    $attributes = @{
        "Proxmox_Type"          = "Host"
        "Proxmox_NodeName"      = "$($host_.NodeName)"
        "Proxmox_NodeID"        = "$($host_.NodeID)"
        "Proxmox_Status"        = "$($host_.Status)"
        "Proxmox_Uptime"        = "$($host_.Uptime)"
        "Proxmox_PVEVersion"    = "$($host_.PVEVersion)"
        "Proxmox_KernelVersion" = "$($host_.KernelVersion)"
        "Proxmox_CPUModel"      = "$($host_.CPUModel)"
        "Proxmox_CPUSockets"    = "$($host_.CPUSockets)"
        "Proxmox_CPUCores"      = "$($host_.CPUCores)"
        "Proxmox_CPUThreads"    = "$($host_.CPUThreads)"
        "Proxmox_CPUPercent"    = "$($host_.CPUPercent)"
        "Proxmox_RAM_Used"      = "$($host_.RAM_Used)"
        "Proxmox_RAM_Total"     = "$($host_.RAM_Total)"
        "Proxmox_RAM_Free"      = "$($host_.RAM_Free)"
        "Proxmox_Swap_Used"     = "$($host_.Swap_Used)"
        "Proxmox_Swap_Total"    = "$($host_.Swap_Total)"
        "Proxmox_RootFS_Used"   = "$($host_.RootFS_Used)"
        "Proxmox_RootFS_Total"  = "$($host_.RootFS_Total)"
        "Proxmox_RootFS_Free"   = "$($host_.RootFS_Free)"
        "Proxmox_LoadAvg1"      = "$($host_.LoadAvg1)"
        "Proxmox_LoadAvg5"      = "$($host_.LoadAvg5)"
        "Proxmox_LoadAvg15"     = "$($host_.LoadAvg15)"
        "Proxmox_LastSync"      = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    }

    foreach ($attr in $attributes.GetEnumerator()) {
        if ($attr.Value -and $attr.Value -ne "" -and $attr.Value -ne "N/A") {
            Set-WUGDeviceAttribute -DeviceId $DeviceID -Name $attr.Key -Value $attr.Value
        }
    }

    Write-Host "  Updated with $($attributes.Count) attributes" -ForegroundColor Green
    $updated++
}

# Update each Proxmox VM in WUG
Write-Host "`n=== Updating existing WUG devices (VMs) ===" -ForegroundColor Cyan

foreach ($vm in $vmResults) {
    if ($vm.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping VM $($vm.Name) - no valid IPv4 address"
        $skipped++
        continue
    }

    # Look up existing device in WUG by IP
    $device = Get-WUGDevice -SearchValue $vm.IPAddress -View id
    if (-not $device) {
        Write-Warning "Skipping $($vm.Name) ($($vm.IPAddress)) - not found in WUG"
        $skipped++
        continue
    }
    $DeviceID = $device.id | Select-Object -First 1

    Write-Host "Updating VM $($vm.Name) ($($vm.IPAddress)) - Device ID: $DeviceID" -ForegroundColor Yellow

    # Update display name and note
    $note = "Proxmox sync $((Get-Date).ToString('yyyy-MM-dd HH:mm')) | " +
            "VMID: $($vm.VMID) | Node: $($vm.Node) | Status: $($vm.Status) | " +
            "CPU: $($vm.CPUs) vCPUs ($($vm.CPUPercent)) | " +
            "RAM: $($vm.RAM_Used) / $($vm.RAM_Total) | " +
            "Disk: $($vm.Disk_Used) / $($vm.Disk_Total) | " +
            "Net In: $($vm.NetIn_KB), Out: $($vm.NetOut_KB)"

    Set-WUGDeviceProperties -DeviceId $DeviceID -DisplayName $vm.Name -note $note

    # Update attributes
    $attributes = @{
        "Proxmox_Type"       = "VM"
        "Proxmox_VMID"       = "$($vm.VMID)"
        "Proxmox_Name"       = "$($vm.Name)"
        "Proxmox_Node"       = "$($vm.Node)"
        "Proxmox_Status"     = "$($vm.Status)"
        "Proxmox_QMPStatus"  = "$($vm.QMPStatus)"
        "Proxmox_Uptime"     = "$($vm.Uptime)"
        "Proxmox_CPUPercent" = "$($vm.CPUPercent)"
        "Proxmox_CPUs"       = "$($vm.CPUs)"
        "Proxmox_RAM_Used"   = "$($vm.RAM_Used)"
        "Proxmox_RAM_Total"  = "$($vm.RAM_Total)"
        "Proxmox_Disk_Used"  = "$($vm.Disk_Used)"
        "Proxmox_Disk_Total" = "$($vm.Disk_Total)"
        "Proxmox_Disk_Read"  = "$($vm.Disk_Read)"
        "Proxmox_Disk_Write" = "$($vm.Disk_Write)"
        "Proxmox_NetIn_KB"   = "$($vm.NetIn_KB)"
        "Proxmox_NetOut_KB"  = "$($vm.NetOut_KB)"
        "Proxmox_Tags"       = "$($vm.Tags)"
        "Proxmox_HAGroup"    = "$($vm.HAGroup)"
        "Proxmox_HAState"    = "$($vm.HAState)"
        "Proxmox_HAManaged"  = "$($vm.HAManaged)"
        "Proxmox_LastSync"   = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    }

    foreach ($attr in $attributes.GetEnumerator()) {
        if ($attr.Value -and $attr.Value -ne "" -and $attr.Value -ne "N/A") {
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
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDVaLj5pr03no3c
# OXScBlu38uWSUi10jpeDFillTPFi+aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg1xObAL921lEmqqwmc/sxHVPNV93rTRmr
# 6TWL/6iFLUIwDQYJKoZIhvcNAQEBBQAEggIAJO34Ix/k0deP/UqZe9u1alxCIr+K
# mHl0/ogY/ldvsd8c+TAE593aXIzdrW9aHlmd1H+oFuJF8QN+9Xd39ZAgQxnLjNcm
# pGfzoIdzIjh4y5eHJtdOGa6LlmWY6i/C2NJ+WYCguutoAdTaLM2VtlPsFCYkUh+j
# rm4uSHoXLwQ0GGy36mWKjVZDpm4YZZkeRa6brH2d4QHMXIKYxsbPKJmiukYjZx5L
# AdC47CdT//idHaxdGPLW8UiHYxE+/zW3zYL9feSgHhylyJ8JAKC5dV+xXjCWXrJw
# qYrV/ON0BXZaXcTVVPpk6AVr3ECwPXKR76NtEQfPDud1QO8PRg67abfYIamHolH0
# difoGB2WjzljIQgmK98g8SJN9KteZgtFfnIObFe0MyEnnGVbGFW+0foqqugjgwDI
# 19Gq7aZwRwCEOmegAlj56CORJDvu2JENPrhPEUqAt8dNqy6D59TehqVuACiwEs8u
# TgKCy9BK0hFDlfyjwCzQ94eZAtuzHoUaWX7VoB+RmymNcYPaW+tMgnRRWnX5GuI5
# bTmzfqEToFbrbbDW/w/S6E8Ui3be5zvDU3VMO8UtpsQfO7qs4DI7V56VgwvQ3MZd
# /oVVOqndmfsoQolMuc4DlANo+HSV7IQqXDYCB2cc83sqsIvAyrDWVy0vuiKqPbIB
# DxZbDSf4wl9pN9o=
# SIG # End signature block
