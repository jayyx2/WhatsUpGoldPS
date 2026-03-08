function Initialize-SSLBypass {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
        $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
    }
    else {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    Write-Warning "Ignoring SSL certificate validation errors. Use this option with caution."
}

function Connect-NutanixCluster {
    <#
    .SYNOPSIS
        Builds an authorization header for the Nutanix Prism REST API.
    .DESCRIPTION
        Takes a server URI and credential, returns a hashtable of headers
        used by all subsequent Nutanix API calls (Basic auth).
    .PARAMETER Server
        The base URI of Prism Element or Prism Central (e.g. https://192.168.1.50:9440).
    .PARAMETER Credential
        PSCredential for Prism authentication.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    $pair = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)

    $headers = @{
        Authorization  = "Basic $base64"
        "Content-Type" = "application/json"
        Accept         = "application/json"
    }

    # Validate connectivity
    try {
        Invoke-RestMethod -Uri "$Server/api/nutanix/v2.0/cluster" -Headers $headers -Method Get | Out-Null
        Write-Verbose "Connected to Nutanix cluster at $Server"
    }
    catch {
        throw "Failed to connect to Nutanix at $Server : $($_.Exception.Message)"
    }

    return $headers
}

function Get-NutanixCluster {
    <#
    .SYNOPSIS
        Returns cluster-level information from Prism.
    .PARAMETER Server
        The Prism base URI.
    .PARAMETER Headers
        Auth headers from Connect-NutanixCluster.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $cluster = Invoke-RestMethod -Uri "$Server/api/nutanix/v2.0/cluster" -Headers $Headers -Method Get

    [PSCustomObject]@{
        ClusterName      = "$($cluster.name)"
        ClusterUuid      = "$($cluster.uuid)"
        ClusterVersion   = "$($cluster.version)"
        HypervisorTypes  = ($cluster.hypervisor_types -join ", ")
        NumNodes         = "$($cluster.num_nodes)"
        ClusterExternalIP = if ($cluster.cluster_external_ipaddress) { "$($cluster.cluster_external_ipaddress)" } else { "N/A" }
        Timezone         = "$($cluster.timezone)"
        SupportVerbosity = "$($cluster.support_verbosity_type)"
    }
}

function Get-NutanixHosts {
    <#
    .SYNOPSIS
        Returns all hosts in the Nutanix cluster.
    .PARAMETER Server
        The Prism base URI.
    .PARAMETER Headers
        Auth headers from Connect-NutanixCluster.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    (Invoke-RestMethod -Uri "$Server/api/nutanix/v2.0/hosts" -Headers $Headers -Method Get).entities
}

function Get-NutanixVMs {
    <#
    .SYNOPSIS
        Returns all VMs in the Nutanix cluster.
    .PARAMETER Server
        The Prism base URI.
    .PARAMETER Headers
        Auth headers from Connect-NutanixCluster.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    (Invoke-RestMethod -Uri "$Server/api/nutanix/v2.0/vms/?include_vm_nic_config=true&include_vm_disk_config=true" -Headers $Headers -Method Get).entities
}

function Get-NutanixHostDetail {
    <#
    .SYNOPSIS
        Formats detailed information about a Nutanix AHV/ESXi host.
    .PARAMETER HostEntity
        A host object from Get-NutanixHosts.
    #>
    param(
        [Parameter(Mandatory)]$HostEntity
    )

    $h = $HostEntity

    # Controller VM IP (CVM)
    $cvmIP = if ($h.controller_vm_backplane_ip) { "$($h.controller_vm_backplane_ip)" } else { "N/A" }
    # Hypervisor IP
    $hypervisorIP = if ($h.hypervisor_address) { "$($h.hypervisor_address)" } else { "N/A" }
    # Management IP (IPMI)
    $ipmiIP = if ($h.ipmi_address) { "$($h.ipmi_address)" } else { "N/A" }

    # Stats
    $stats = $h.stats
    $cpuPct = if ($stats.'hypervisor_cpu_usage_ppm') { "{0:N1}%" -f ($stats.'hypervisor_cpu_usage_ppm' / 10000) } else { "N/A" }
    $memPct = if ($stats.'hypervisor_memory_usage_ppm') { "{0:N1}%" -f ($stats.'hypervisor_memory_usage_ppm' / 10000) } else { "N/A" }

    [PSCustomObject]@{
        Type             = "Nutanix Host"
        HostName         = if ($h.name) { "$($h.name)" } else { "N/A" }
        HostUuid         = "$($h.uuid)"
        HypervisorIP     = $hypervisorIP
        CvmIP            = $cvmIP
        IpmiIP           = $ipmiIP
        IPAddress        = $hypervisorIP
        HypervisorType   = if ($h.hypervisor_type) { "$($h.hypervisor_type)" } else { "N/A" }
        HypervisorVersion = if ($h.hypervisor_full_name) { "$($h.hypervisor_full_name)" } else { "N/A" }
        AcropolisVersion = if ($h.service_vmexternal_ip) { "$($h.service_vmexternal_ip)" } else { "N/A" }
        Serial           = if ($h.serial) { "$($h.serial)" } else { "N/A" }
        BlockModel       = if ($h.block_model_name) { "$($h.block_model_name)" } else { "N/A" }
        BlockSerial      = if ($h.block_serial) { "$($h.block_serial)" } else { "N/A" }
        CPUSockets       = "$($h.num_cpu_sockets)"
        CPUCores         = "$($h.num_cpu_cores)"
        CPUThreads       = "$($h.num_cpu_threads)"
        CPUModel         = if ($h.cpu_model) { "$($h.cpu_model)" } else { "N/A" }
        CPUFreqGHz       = if ($h.cpu_frequency_in_hz) { "{0:N2}" -f ($h.cpu_frequency_in_hz / 1000000000) } else { "N/A" }
        CPUUsagePct      = $cpuPct
        RAM_TotalGB      = "$([math]::Round($h.memory_capacity_in_bytes / 1GB, 2))"
        MemUsagePct      = $memPct
        NumVMs           = "$($h.num_vms)"
        NumDisks         = "$($h.num_disks)"
        StorageCapacityGB = if ($h.usage_stats.'storage.capacity_bytes') { "$([math]::Round([long]$h.usage_stats.'storage.capacity_bytes' / 1GB, 2))" } else { "N/A" }
        StorageUsedGB    = if ($h.usage_stats.'storage.usage_bytes') { "$([math]::Round([long]$h.usage_stats.'storage.usage_bytes' / 1GB, 2))" } else { "N/A" }
        BootTimeUsecs    = if ($h.boot_time_in_usecs) { "$($h.boot_time_in_usecs)" } else { "N/A" }
    }
}

function Get-NutanixVMDetail {
    <#
    .SYNOPSIS
        Formats detailed information about a Nutanix VM.
    .PARAMETER VMEntity
        A VM object from Get-NutanixVMs.
    .PARAMETER HostLookup
        A hashtable mapping host UUIDs to host names for display.
    #>
    param(
        [Parameter(Mandatory)]$VMEntity,
        [hashtable]$HostLookup = @{}
    )

    $vm = $VMEntity

    # IP addresses from NIC list
    $ipAddresses = @()
    if ($vm.vm_nics) {
        foreach ($nic in $vm.vm_nics) {
            if ($nic.ip_address) { $ipAddresses += $nic.ip_address }
            if ($nic.requested_ip_address) { $ipAddresses += $nic.requested_ip_address }
        }
    }
    $ip = $ipAddresses |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $ip) { $ip = "N/A" }

    # Disk info
    $diskCount = 0
    $totalDiskGB = 0
    if ($vm.vm_disk_info) {
        foreach ($disk in $vm.vm_disk_info) {
            if ($disk.disk_address.device_bus -ne "ide" -or !$disk.is_cdrom) {
                $diskCount++
                if ($disk.size) { $totalDiskGB += $disk.size / 1GB }
            }
        }
    }

    # NIC info
    $nicCount = if ($vm.vm_nics) { @($vm.vm_nics).Count } else { 0 }
    $vlanIds = ($vm.vm_nics | ForEach-Object { $_.vlan_id } | Where-Object { $_ } | Select-Object -Unique) -join ", "
    $networkNames = ($vm.vm_nics | ForEach-Object { $_.network_name } | Where-Object { $_ } | Select-Object -Unique) -join ", "

    # Host mapping
    $hostName = if ($HostLookup.ContainsKey($vm.host_uuid)) { $HostLookup[$vm.host_uuid] } else { "$($vm.host_uuid)" }

    # Stats
    $stats = $vm.stats
    $cpuPct = if ($stats.'hypervisor.cpu_ready_time_ppm') { "{0:N1}%" -f ($stats.'hypervisor.cpu_ready_time_ppm' / 10000) } else { "N/A" }

    [PSCustomObject]@{
        Name             = if ($vm.name) { "$($vm.name)" } else { "N/A" }
        VMId             = "$($vm.uuid)"
        Host             = "$hostName"
        HostUuid         = "$($vm.host_uuid)"
        IPAddress        = $ip
        PowerState       = if ($vm.power_state) { "$($vm.power_state)" } else { "N/A" }
        NumCPU           = "$($vm.num_vcpus)"
        NumCoresPerVcpu  = "$($vm.num_cores_per_vcpu)"
        MemoryGB         = "$([math]::Round($vm.memory_mb / 1024, 2))"
        DiskCount        = "$diskCount"
        DiskTotalGB      = "$([math]::Round($totalDiskGB, 2))"
        NicCount         = "$nicCount"
        VLanIds          = if ($vlanIds) { $vlanIds } else { "N/A" }
        NetworkNames     = if ($networkNames) { $networkNames } else { "N/A" }
        GuestOS          = if ($vm.guest_os) { "$($vm.guest_os)" } else { "N/A" }
        Description      = if ($vm.description) { "$($vm.description.Substring(0, [math]::Min(200, $vm.description.Length)))" } else { "" }
        ProtectionDomain = if ($vm.protection_domain_name) { "$($vm.protection_domain_name)" } else { "N/A" }
        Timezone         = if ($vm.timezone) { "$($vm.timezone)" } else { "N/A" }
        NgtEnabled       = if ($null -ne $vm.vm_features.AGENT_VM) { "$($vm.vm_features.AGENT_VM)" } else { "N/A" }
        MachineType      = if ($vm.machine_type) { "$($vm.machine_type)" } else { "N/A" }
    }
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDetuuU2E9iNFBZ
# S7XEenI0dm42rE3oaVwgHzIvP1YCbqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgIsNGUZ9q5P1zv3ySmaSNJ/cbpJ7p/LM7
# BGB5Ox8ilzEwDQYJKoZIhvcNAQEBBQAEggIA46Bua27Ttb3q1vTGjYCG3koV2g+u
# 94vHcaQ7bKPgBzVDYAqE1oogog/UZpk/OgOZxrhclKBr4inu3q79XE6tgnyRjRaM
# a/YdSMIDrnYUa8oXhWHr58slhUsw7GPNwN1h5LlYrzlO5w23m6ULYOHhJUpP2SxK
# ZjBIcuFWTI9O5JAIhgeOUHPt90/sdOgeH+ojRWiMIbOB8a70KCjD1yq1JMyBjDcl
# WHuimG0G7v9z6GZz/c7G3gtiRWnXEOi+eABxBvJsQTJcSXEP9o4e9oLeeFit/9us
# h1yxSytXWRu+5vISTtEHJCDqS/VtdHqc+KXBk/Rilx2KJzWNNC++uLSkYpM1E1Mk
# mBk91K2z1XkDLawmOq8lLhh3HjszqQu8YVAH7eVIZXaJYTMpYi25ja7jpjoCts3E
# yCQOc2X+fus4p0m+q7W40Ohpvgl46CSkNXtsXK+0dmLcyzHAs6kcXrFChAoIdYus
# yffjgAkiay6nJPbSA0WDbs6GGS8ezqBsMcMX21qeIP7GkWqoG4Rvx9Dfuh80ehEu
# CzzgT+gjupgOuQzTR+YGV7QwxSHLPAb82riNSYcvfhdldH2rHVs/XaY/Ni9+zx2J
# rkvSteOTxCrhs/mf2MpxRH4p0mI7XUh7eLO0aKVrVK7M1j5RWoYfK0JcHxB+R9zE
# Ae38aCJsbBy7j2E=
# SIG # End signature block
