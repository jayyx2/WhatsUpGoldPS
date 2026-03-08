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
