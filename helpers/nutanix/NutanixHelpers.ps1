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
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB/UBvI/WLWx7Ha
# UytLAO8oCPfM3+mJqWD3XDB2xXOSTaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgY16Idi77vZXtWONoajuF4x3bA8TnTJo0
# RciBR5U829AwDQYJKoZIhvcNAQEBBQAEggIA2hD0A2TRFi/gCpjsD60z+vcrWP/k
# Iwdv1leshDQl5g/Wy1Du0kuLr95w0bm9DbsHwDK8MLhqG5cVKQ5X2Y6eYh1VBL69
# paV4cTABo+oLs/aM/Xi5yThxQvAfn9BVnR1/tlzqtsc3ivjcfkwESDhooclRiYi6
# C53vuEOVvUC6eglEwW4mRCscYfHKAwttIKO3M3utthDs4IedFlkDQ3Ea3WaKTGbx
# CoQCaOeebEYt0HhjuuEaz5tfMttvN7LId5uyUwXa2vDIsj1H9TjrpDtY6FVfAmXH
# EwpYk+BmUTqd8VuvbdLVEcxeTMjYHqicwxslQa1ZrHf9gBwWNZwccRNPmL2sHJv9
# LG1/I87OWlLeGnO276rYTV1PqfWAxOAfo7ioLyiKFjJXGF2ye+okco7yEvpr1TIl
# wRMZoOWY7dbpxAzrT0/Uq3jHTtaMgcw9HMQLc+L74s6Sttac5uPFfnhnniZppQhK
# IM7p84AoRWNbfg9S1LhtN+KhJEgtZANMXPJcxnZX0fko37yTuT+uP/9kQzFPoCkK
# 7eDlDzaaLiK/Gy48m+UDgLOHOfZtgZw1G1E5zSCEuQ5tRIahQCjNrBcH7WBDLfHz
# T8NELmuD1/BpFOqvv1V1I7rTyJlIOXV3B94N3ZpgzSbtSFN0qlh/s6lWoH1sh7eg
# YFvuB9KXv2CxwYI=
# SIG # End signature block
