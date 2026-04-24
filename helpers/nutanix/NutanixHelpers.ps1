function Initialize-SSLBypass {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
        $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
    }
    else {
        # Compiled callback -- avoids scriptblock delegate marshaling failures
        # under rapid sequential requests in PS 5.1
        if (-not ([System.Management.Automation.PSTypeName]'SSLValidator').Type) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SSLValidator {
    private static bool OnValidateCertificate(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) {
        return true;
    }
    public static void OverrideValidation() {
        ServicePointManager.ServerCertificateValidationCallback =
            new RemoteCertificateValidationCallback(OnValidateCertificate);
        ServicePointManager.Expect100Continue = false;
        ServicePointManager.DefaultConnectionLimit = 64;
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
    }
}
"@
        }
        [SSLValidator]::OverrideValidation()
    }
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
    .EXAMPLE
        $cred = Get-Credential
        $headers = Connect-NutanixCluster -Server "https://192.168.1.50:9440" -Credential $cred
        Authenticates to the Nutanix Prism API and returns authorization headers.
    .EXAMPLE
        $headers = Connect-NutanixCluster -Server "https://prism.lab.local:9440" -Credential (Get-Credential)
        Connects to Prism Central and stores the auth headers for subsequent API calls.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    $pair = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $pair = $null

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
    .EXAMPLE
        $headers = Connect-NutanixCluster -Server "https://192.168.1.50:9440" -Credential $cred
        Get-NutanixCluster -Server "https://192.168.1.50:9440" -Headers $headers
        Returns cluster name, version, node count, and other cluster-level details.
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
    .EXAMPLE
        $hosts = Get-NutanixHosts -Server "https://192.168.1.50:9440" -Headers $headers
        Returns all hypervisor hosts in the Nutanix cluster.
    .EXAMPLE
        Get-NutanixHosts -Server $server -Headers $headers | ForEach-Object { $_.name }
        Lists the names of all hosts in the cluster.
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
    .EXAMPLE
        $vms = Get-NutanixVMs -Server "https://192.168.1.50:9440" -Headers $headers
        Returns all VMs in the Nutanix cluster including NIC and disk configurations.
    .EXAMPLE
        Get-NutanixVMs -Server $server -Headers $headers | Where-Object { $_.power_state -eq "on" }
        Returns only powered-on VMs.
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
    .EXAMPLE
        $hosts = Get-NutanixHosts -Server $server -Headers $headers
        Get-NutanixHostDetail -HostEntity $hosts[0]
        Returns CPU, memory, storage, and network details for the first host.
    .EXAMPLE
        Get-NutanixHosts -Server $server -Headers $headers | ForEach-Object { Get-NutanixHostDetail -HostEntity $_ }
        Returns detailed information for every host in the cluster.
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
    .EXAMPLE
        $vms = Get-NutanixVMs -Server $server -Headers $headers
        Get-NutanixVMDetail -VMEntity $vms[0]
        Returns detailed information (IP, CPU, memory, disks) for the first VM.
    .EXAMPLE
        $hosts = Get-NutanixHosts -Server $server -Headers $headers
        $lookup = @{}; $hosts | ForEach-Object { $lookup[$_.uuid] = $_.name }
        $vms | ForEach-Object { Get-NutanixVMDetail -VMEntity $_ -HostLookup $lookup }
        Returns VM details with host names resolved via lookup table.
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

function Get-NutanixDashboard {
    <#
    .SYNOPSIS
        Builds a flat dashboard view combining Nutanix cluster, hosts, and VMs.
    .DESCRIPTION
        Queries the Nutanix Prism API for cluster info, hosts, and VMs,
        then returns a unified collection of objects suitable for an
        interactive Bootstrap Table dashboard. Each row represents a VM
        enriched with host CPU/memory usage and cluster context.
    .PARAMETER Server
        The Prism base URI (e.g. https://192.168.1.50:9440).
    .PARAMETER Headers
        Auth headers hashtable obtained from Connect-NutanixCluster.
    .EXAMPLE
        $headers = Connect-NutanixCluster -Server "https://192.168.1.50:9440" -Credential $cred
        Get-NutanixDashboard -Server "https://192.168.1.50:9440" -Headers $headers

        Returns a flat dashboard view of all VMs across the specified cluster.
    .EXAMPLE
        $dashboard = Get-NutanixDashboard -Server $server -Headers $headers
        $dashboard | Where-Object { $_.PowerState -eq "on" }

        Retrieves the dashboard and filters for powered-on VMs.
    .EXAMPLE
        $cred = Get-Credential
        $headers = Connect-NutanixCluster -Server "https://prism01:9440" -Credential $cred
        $data = Get-NutanixDashboard -Server "https://prism01:9440" -Headers $headers
        Export-NutanixDashboardHtml -DashboardData $data -OutputPath "C:\Reports\nutanix.html"
        Start-Process "C:\Reports\nutanix.html"

        End-to-end: authenticate, gather data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains VM details enriched with host and cluster context: VMName,
        PowerState, IPAddress, Host, HostIP, HostCPUUsage, HostMemUsage, ClusterName,
        ClusterVersion, NumCPU, CoresPerVcpu, MemoryGB, DiskCount, DiskTotalGB, NicCount,
        VLanIds, NetworkNames, GuestOS, ProtectionDomain, NgtEnabled, MachineType, Description.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, network access to Nutanix Prism API (port 9440).
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $cluster = Get-NutanixCluster -Server $Server -Headers $Headers
    $hosts = Get-NutanixHosts -Server $Server -Headers $Headers
    $vms = Get-NutanixVMs -Server $Server -Headers $Headers

    # Build host lookup
    $hostLookup = @{}
    $hostDetails = @{}
    foreach ($h in $hosts) {
        $hostLookup[$h.uuid] = $h.name
        $hostDetails[$h.uuid] = Get-NutanixHostDetail -HostEntity $h
    }

    $results = @()
    foreach ($vm in $vms) {
        $vmDetail = Get-NutanixVMDetail -VMEntity $vm -HostLookup $hostLookup
        $hd = if ($hostDetails.ContainsKey($vm.host_uuid)) { $hostDetails[$vm.host_uuid] } else { $null }

        $results += [PSCustomObject]@{
            VMName           = $vmDetail.Name
            PowerState       = $vmDetail.PowerState
            IPAddress        = $vmDetail.IPAddress
            Host             = $vmDetail.Host
            HostIP           = if ($hd) { $hd.HypervisorIP } else { "N/A" }
            HostCPUUsage     = if ($hd) { $hd.CPUUsagePct } else { "N/A" }
            HostMemUsage     = if ($hd) { $hd.MemUsagePct } else { "N/A" }
            ClusterName      = $cluster.ClusterName
            ClusterVersion   = $cluster.ClusterVersion
            NumCPU           = $vmDetail.NumCPU
            CoresPerVcpu     = $vmDetail.NumCoresPerVcpu
            MemoryGB         = $vmDetail.MemoryGB
            DiskCount        = $vmDetail.DiskCount
            DiskTotalGB      = $vmDetail.DiskTotalGB
            NicCount         = $vmDetail.NicCount
            VLanIds          = $vmDetail.VLanIds
            NetworkNames     = $vmDetail.NetworkNames
            GuestOS          = $vmDetail.GuestOS
            ProtectionDomain = $vmDetail.ProtectionDomain
            NgtEnabled       = $vmDetail.NgtEnabled
            MachineType      = $vmDetail.MachineType
            Description      = $vmDetail.Description
        }
    }

    return $results
}

function Export-NutanixDashboardHtml {
    <#
    .SYNOPSIS
        Renders Nutanix dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-NutanixDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-NutanixDashboard containing VM and cluster details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Nutanix Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        Nutanix-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-NutanixDashboard -Server $server -Headers $headers
        Export-NutanixDashboardHtml -DashboardData $data -OutputPath "C:\Reports\nutanix.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-NutanixDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\nutanix.html" -ReportTitle "Production Nutanix"

        Exports with a custom report title.
    .EXAMPLE
        $headers = Connect-NutanixCluster -Server $server -Credential $cred
        $data = Get-NutanixDashboard -Server $server -Headers $headers
        Export-NutanixDashboardHtml -DashboardData $data -OutputPath "C:\Reports\nutanix.html"
        Start-Process "C:\Reports\nutanix.html"

        Full pipeline: authenticate, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Nutanix-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Nutanix Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Nutanix-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'PowerState') {
            $col.formatter = 'formatPowerState'
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
    Write-Verbose "Nutanix Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBxUzaVNgS33W67
# /9d7g2Rmq5mK/gcPmGJ0jAzqLLbMmaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCDiqwWs9t3IYkojJNHGPuWc+4w+w4bFcPxFiGmSAwo3cTANBgkqhkiG9w0BAQEF
# AASCAgCzD2fN8Zf2+QixN8Lh1pQPH59np1GBuc70lsRT4gEBPHn8S198RjsssIn6
# iMK1JUzDn5+pybbsZd/EAxtL39U4a264q+i6YRICbgvk4CMTEm0OoBOHoJcquZRR
# VtSgC8hk3ZoKq3WSkhes6tRjkIKK2OtaxsAG4PZBOk83YyW7+rxGLPTc+6Y5+JQK
# plVYdKPeXwhgAALWzTQUohcdveqtT1Jzzwv8NVrWDI99SFrBCDZ298OMY2k8Y/DG
# ReRPMg/obHrcsQLK1+2S8bPl3F8uE2hk8ohFdOifC/oN7tUAZD/dR1dxdjR+TQwn
# GJPdzjlJfOP3dGY7wm0e7odwoxSQQCYu/MUUk0eMfZdYdrlZIYciaCW8EDut6xMk
# TSTJm1GoNO8nHKlz20sE+DxTY9jOHhXnBAoIBkNjAlSFdkNehMaqKe62kIdQcOEd
# Ij8GRGSgflpkW1Y6+zDzxpr9u7Ag+82TiD+TdvLQyfJOBbHfPeYy98imj9oIDkUo
# rxKeJNIMmXCdsCddZAiZIf1QfP0nE1mqnUGlNpCjkNB8p1X9ewJ16uWdRZRDpJPh
# UdNuC6K0T3USU6NjG4dzFvsuqGGg+mG0WOh0dYlFchc4I3LlPrTq36WB3EaaqZWn
# 8ZcYuhvRHOU1kjwQExw3GPdITbjqmMvQcbq6+9FyzttnY2FgjaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDE2MzFaMC8GCSqGSIb3DQEJBDEiBCDLiICY
# V+j3ZJgxEJB4mTlOpIZjHRE93o2dO2vEFigfBjANBgkqhkiG9w0BAQEFAASCAgAl
# hz85T5jmPrxU48iy+zUMgsac2cLyhnclMMt9XYkCYkfnF/Ba0Mj2/yvj0gT9evJU
# au3aYnEST2kn5/di1whivcwbdnq8Z9WHjOa/i3zYagqFmR0SDie+H12jSCraYHKC
# Ho6Wm+Jvuz752KLswKss2h3YTGoFpk3wQfcWDAZX6jonq4Z3S7jloeUZf4n/YbvX
# SQzm70Ta8rSvhuf+C+R215oN0mq1pE14fHn7d0FEDc7I6PNg8yHQsFjhLe2TWmoM
# 3nlfIr+WQCzMMbIkkzDD8qfBqisa4zvRpG1pgA+GKarWRL3ChMUjLTPcvJq3exDS
# Y5dZZp3G5Ae0Vf4lEnCZ4t+OPndCwwGaOmQVgGx4vnOa7cRRbfqZ6RRsUamJkih5
# F7HfHV1YxYCpxHyiEme2/+8Ee16cV67os52dmJblRNwxNo+unRLjLeGCrTklx1p9
# js/kg6ry4lXgp3nxzuHYcSuKsh+ejcbyF9EJeXwxTNBFetKEnvxwAcqH1vDaHeH3
# ecEI0iziIMRT+d3npEyH+JASxwcN1iVLMLePKDfIQEWoTITrywpnu016QpU5zzwd
# qn94hZEoHZMqvL2hBSHPuBmevETG10pBWw3kKUzlGC1c+0GEjGhfUsINqzGp+AFh
# GZbbD78eg21nuHMBaYkA3ZQZ3mPqrYGaWaEvYcAr6w==
# SIG # End signature block
