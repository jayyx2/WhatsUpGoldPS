# =============================================================================
# OCI (Oracle Cloud Infrastructure) Helpers for WhatsUpGoldPS
# Requires the OCI PowerShell modules. Install them:
#   Install-Module -Name OCI.PSModules -Scope CurrentUser -Force
# Or install individual modules:
#   Install-Module -Name OCI.PSModules.Identity, OCI.PSModules.Compute,
#       OCI.PSModules.Core, OCI.PSModules.Database,
#       OCI.PSModules.Loadbalancer -Scope CurrentUser -Force
# For monitoring metrics, install the OCI CLI:
#   https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm
# Configure authentication (API key config file):
#   https://docs.oracle.com/en-us/iaas/Content/API/Concepts/sdkconfig.htm
# =============================================================================

function Connect-OCIProfile {
    <#
    .SYNOPSIS
        Validates OCI configuration and tests connectivity.
    .DESCRIPTION
        Checks that the OCI config file exists and validates connectivity
        by listing available OCI regions. Authentication is handled by the
        config file - this function only verifies it works.
    .PARAMETER ConfigFile
        Path to the OCI config file. Defaults to ~/.oci/config.
    .PARAMETER Profile
        The profile name in the config file. Defaults to DEFAULT.
    .EXAMPLE
        Connect-OCIProfile
        Validates the default OCI config file (~/.oci/config) with the DEFAULT profile.
    .EXAMPLE
        Connect-OCIProfile -ConfigFile "C:\oci\config" -Profile "production"
        Validates connectivity using a custom config file and the "production" profile.
    #>
    param(
        [string]$ConfigFile,
        [string]$Profile
    )

    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $env:USERPROFILE ".oci\config"
    }

    if (-not (Test-Path $ConfigFile)) {
        throw "OCI config file not found: $ConfigFile. See: https://docs.oracle.com/en-us/iaas/Content/API/Concepts/sdkconfig.htm"
    }

    $splat = @{ ErrorAction = "Stop"; FullResponse = $true }
    if ($ConfigFile) { $splat["ConfigFile"] = $ConfigFile }
    if ($Profile) { $splat["Profile"] = $Profile }

    try {
        $regions = Get-OCIIdentityRegionsList @splat
        $regionNames = ($regions.Items | ForEach-Object { $_.Name }) -join ", "
        Write-Verbose "Connected to OCI. Available regions: $regionNames"
    }
    catch {
        throw "Failed to connect to OCI: $($_.Exception.Message)"
    }
}

function Get-OCICompartments {
    <#
    .SYNOPSIS
        Returns all active compartments in a tenancy.
    .DESCRIPTION
        Lists child compartments under the specified tenancy OCID.
        Handles pagination automatically.
    .PARAMETER TenancyId
        The OCID of the tenancy (root compartment).
    .PARAMETER ConfigFile
        Path to the OCI config file.
    .PARAMETER Profile
        The profile name in the config file.
    .EXAMPLE
        Get-OCICompartments -TenancyId "ocid1.tenancy.oc1..aaaaaaaexample"
        Returns all active compartments in the tenancy using default config.
    .EXAMPLE
        Get-OCICompartments -TenancyId $tenancyId -ConfigFile "C:\oci\config" -Profile "dev"
        Returns compartments using a custom config file and profile.
    #>
    param(
        [Parameter(Mandatory)][string]$TenancyId,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $TenancyId; ErrorAction = "Stop"; FullResponse = $true }
    if ($ConfigFile) { $splat["ConfigFile"] = $ConfigFile }
    if ($Profile) { $splat["Profile"] = $Profile }

    $allItems = @()
    $response = Get-OCIIdentityCompartmentsList @splat
    $allItems += $response.Items
    while ($response.OpcNextPage) {
        $splat["Page"] = $response.OpcNextPage
        $response = Get-OCIIdentityCompartmentsList @splat
        $allItems += $response.Items
    }

    foreach ($c in $allItems) {
        if ("$($c.LifecycleState)" -ne "ACTIVE") { continue }
        [PSCustomObject]@{
            CompartmentId  = "$($c.Id)"
            Name           = "$($c.Name)"
            Description    = if ($c.Description) { "$($c.Description)" } else { "" }
            LifecycleState = "$($c.LifecycleState)"
            TimeCreated    = if ($c.TimeCreated) { "$($c.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "N/A" }
        }
    }
}

function Get-OCIComputeInstances {
    <#
    .SYNOPSIS
        Returns all compute instances in a compartment with IP addresses.
    .DESCRIPTION
        Lists compute instances and resolves their primary VNIC IP addresses
        via the VNIC attachment and VNIC detail APIs.
    .PARAMETER CompartmentId
        The OCID of the compartment.
    .PARAMETER Region
        Override the OCI region.
    .PARAMETER ConfigFile
        Path to the OCI config file.
    .PARAMETER Profile
        The profile name in the config file.
    .EXAMPLE
        Get-OCIComputeInstances -CompartmentId "ocid1.compartment.oc1..aaaaaaaexample"
        Returns all compute instances in the specified compartment.
    .EXAMPLE
        Get-OCIComputeInstances -CompartmentId $compartmentId -Region "us-ashburn-1"
        Returns compute instances in a specific region.
    .EXAMPLE
        Get-OCIComputeInstances -CompartmentId $compartmentId | Where-Object { $_.LifecycleState -eq "RUNNING" }
        Returns only running compute instances.
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop"; FullResponse = $true }
    if ($Region) { $splat["Region"] = $Region }
    if ($ConfigFile) { $splat["ConfigFile"] = $ConfigFile }
    if ($Profile) { $splat["Profile"] = $Profile }

    $allItems = @()
    $response = Get-OCIComputeInstancesList @splat
    $allItems += $response.Items
    while ($response.OpcNextPage) {
        $splat["Page"] = $response.OpcNextPage
        $response = Get-OCIComputeInstancesList @splat
        $allItems += $response.Items
    }

    foreach ($inst in $allItems) {
        $publicIP  = "N/A"
        $privateIP = "N/A"
        $vnicName  = "N/A"

        # Resolve IPs via VNIC attachments
        try {
            $vnicSplat = @{
                CompartmentId = $CompartmentId
                InstanceId    = $inst.Id
                ErrorAction   = "Stop"
            }
            if ($Region) { $vnicSplat["Region"] = $Region }
            if ($ConfigFile) { $vnicSplat["ConfigFile"] = $ConfigFile }
            if ($Profile) { $vnicSplat["Profile"] = $Profile }

            $vnicSplat['FullResponse'] = $true
            $vnicAttachments = Get-OCIComputeVnicAttachmentsList @vnicSplat
            foreach ($att in $vnicAttachments.Items) {
                if ("$($att.LifecycleState)" -ne "ATTACHED") { continue }

                $vnicGetSplat = @{ VnicId = $att.VnicId; ErrorAction = "Stop" }
                if ($Region) { $vnicGetSplat["Region"] = $Region }
                if ($ConfigFile) { $vnicGetSplat["ConfigFile"] = $ConfigFile }
                if ($Profile) { $vnicGetSplat["Profile"] = $Profile }

                $vnic = Get-OCIVirtualNetworkVnic @vnicGetSplat
                if ($vnic.PublicIp)  { $publicIP  = "$($vnic.PublicIp)" }
                if ($vnic.PrivateIp) { $privateIP = "$($vnic.PrivateIp)" }
                $vnicName = if ($vnic.DisplayName) { "$($vnic.DisplayName)" } else { "N/A" }

                if ($vnic.IsPrimary) { break }
            }
        }
        catch {
            Write-Verbose "Could not resolve VNIC for $($inst.DisplayName): $($_.Exception.Message)"
        }

        # Freeform tags
        $tags = if ($inst.FreeformTags -and $inst.FreeformTags.Count -gt 0) {
            ($inst.FreeformTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
        } else { "" }

        [PSCustomObject]@{
            Name               = if ($inst.DisplayName) { "$($inst.DisplayName)" } else { "$($inst.Id)" }
            InstanceId         = "$($inst.Id)"
            Shape              = "$($inst.Shape)"
            LifecycleState     = "$($inst.LifecycleState)"
            AvailabilityDomain = if ($inst.AvailabilityDomain) { "$($inst.AvailabilityDomain)" } else { "N/A" }
            FaultDomain        = if ($inst.FaultDomain) { "$($inst.FaultDomain)" } else { "N/A" }
            Region             = if ($Region) { $Region } else { "default" }
            CompartmentId      = "$($inst.CompartmentId)"
            PublicIP           = $publicIP
            PrivateIP          = $privateIP
            VnicName           = $vnicName
            ImageId            = if ($inst.ImageId) { "$($inst.ImageId)" } else { "N/A" }
            TimeCreated        = if ($inst.TimeCreated) { "$($inst.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "N/A" }
            Tags               = $tags
        }
    }
}

function Get-OCIDBSystems {
    <#
    .SYNOPSIS
        Returns all Oracle DB System instances in a compartment.
    .DESCRIPTION
        Lists DB Systems and attempts DNS resolution for node IP addresses.
    .PARAMETER CompartmentId
        The OCID of the compartment.
    .PARAMETER Region
        Override the OCI region.
    .PARAMETER ConfigFile
        Path to the OCI config file.
    .PARAMETER Profile
        The profile name in the config file.
    .EXAMPLE
        Get-OCIDBSystems -CompartmentId "ocid1.compartment.oc1..aaaaaaaexample"
        Returns all Oracle DB System instances in the compartment.
    .EXAMPLE
        Get-OCIDBSystems -CompartmentId $compartmentId -Region "us-phoenix-1"
        Returns DB Systems in a specific region.
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop"; FullResponse = $true }
    if ($Region) { $splat["Region"] = $Region }
    if ($ConfigFile) { $splat["ConfigFile"] = $ConfigFile }
    if ($Profile) { $splat["Profile"] = $Profile }

    $allItems = @()
    $response = Get-OCIDatabaseDbSystemsList @splat
    $allItems += $response.Items
    while ($response.OpcNextPage) {
        $splat["Page"] = $response.OpcNextPage
        $response = Get-OCIDatabaseDbSystemsList @splat
        $allItems += $response.Items
    }

    foreach ($db in $allItems) {
        # Attempt DNS resolution for node IP
        $nodeIPs = "N/A"
        if ($db.Hostname -and $db.Domain) {
            $fqdn = "$($db.Hostname).$($db.Domain)"
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($fqdn)
                if ($resolved) { $nodeIPs = ($resolved | ForEach-Object { $_.IPAddressToString }) -join ", " }
            }
            catch { }
        }

        # Scan IPs
        $scanIPs = if ($db.ScanIpIds -and $db.ScanIpIds.Count -gt 0) {
            ($db.ScanIpIds) -join ", "
        } else { "N/A" }

        [PSCustomObject]@{
            Name                 = if ($db.DisplayName) { "$($db.DisplayName)" } else { "$($db.Id)" }
            DBSystemId           = "$($db.Id)"
            Shape                = if ($db.Shape) { "$($db.Shape)" } else { "N/A" }
            LifecycleState       = "$($db.LifecycleState)"
            AvailabilityDomain   = if ($db.AvailabilityDomain) { "$($db.AvailabilityDomain)" } else { "N/A" }
            Region               = if ($Region) { $Region } else { "default" }
            CompartmentId        = "$($db.CompartmentId)"
            Hostname             = if ($db.Hostname) { "$($db.Hostname)" } else { "N/A" }
            Domain               = if ($db.Domain) { "$($db.Domain)" } else { "N/A" }
            NodeIPs              = $nodeIPs
            ScanIPs              = $scanIPs
            CpuCoreCount         = if ($db.CpuCoreCount) { "$($db.CpuCoreCount)" } else { "N/A" }
            DataStorageSizeInGBs = if ($db.DataStorageSizeInGBs) { "$($db.DataStorageSizeInGBs)" } else { "N/A" }
            NodeCount            = if ($db.NodeCount) { "$($db.NodeCount)" } else { "N/A" }
            DatabaseEdition      = if ($db.DatabaseEdition) { "$($db.DatabaseEdition)" } else { "N/A" }
            DiskRedundancy       = if ($db.DiskRedundancy) { "$($db.DiskRedundancy)" } else { "N/A" }
            LicenseModel         = if ($db.LicenseModel) { "$($db.LicenseModel)" } else { "N/A" }
            Version              = if ($db.Version) { "$($db.Version)" } else { "N/A" }
            TimeCreated          = if ($db.TimeCreated) { "$($db.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "N/A" }
        }
    }
}

function Get-OCIAutonomousDatabases {
    <#
    .SYNOPSIS
        Returns all Autonomous Database instances in a compartment.
    .PARAMETER CompartmentId
        The OCID of the compartment.
    .PARAMETER Region
        Override the OCI region.
    .PARAMETER ConfigFile
        Path to the OCI config file.
    .PARAMETER Profile
        The profile name in the config file.
    .EXAMPLE
        Get-OCIAutonomousDatabases -CompartmentId "ocid1.compartment.oc1..aaaaaaaexample"
        Returns all Autonomous Database instances in the compartment.
    .EXAMPLE
        Get-OCIAutonomousDatabases -CompartmentId $compartmentId | Where-Object { $_.DbWorkload -eq "OLTP" }
        Returns only OLTP Autonomous Database instances.
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop"; FullResponse = $true }
    if ($Region) { $splat["Region"] = $Region }
    if ($ConfigFile) { $splat["ConfigFile"] = $ConfigFile }
    if ($Profile) { $splat["Profile"] = $Profile }

    $allItems = @()
    $response = Get-OCIDatabaseAutonomousDatabasesList @splat
    $allItems += $response.Items
    while ($response.OpcNextPage) {
        $splat["Page"] = $response.OpcNextPage
        $response = Get-OCIDatabaseAutonomousDatabasesList @splat
        $allItems += $response.Items
    }

    foreach ($adb in $allItems) {
        $privateEndpointIp = if ($adb.PrivateEndpointIp) { "$($adb.PrivateEndpointIp)" } else { "N/A" }

        [PSCustomObject]@{
            Name                 = if ($adb.DisplayName) { "$($adb.DisplayName)" } else { "$($adb.Id)" }
            AutonomousDbId       = "$($adb.Id)"
            DbWorkload           = if ($adb.DbWorkload) { "$($adb.DbWorkload)" } else { "N/A" }
            LifecycleState       = "$($adb.LifecycleState)"
            Region               = if ($Region) { $Region } else { "default" }
            CompartmentId        = "$($adb.CompartmentId)"
            CpuCoreCount         = if ($adb.CpuCoreCount) { "$($adb.CpuCoreCount)" } else { "N/A" }
            DataStorageSizeInTBs = if ($adb.DataStorageSizeInTBs) { "$($adb.DataStorageSizeInTBs)" } else { "N/A" }
            PrivateEndpointIp    = $privateEndpointIp
            IsFreeTier           = if ($null -ne $adb.IsFreeTier) { "$($adb.IsFreeTier)" } else { "N/A" }
            LicenseModel         = if ($adb.LicenseModel) { "$($adb.LicenseModel)" } else { "N/A" }
            DbVersion            = if ($adb.DbVersion) { "$($adb.DbVersion)" } else { "N/A" }
            IsAutoScalingEnabled = if ($null -ne $adb.IsAutoScalingEnabled) { "$($adb.IsAutoScalingEnabled)" } else { "N/A" }
            IsDedicated          = if ($null -ne $adb.IsDedicated) { "$($adb.IsDedicated)" } else { "N/A" }
            TimeCreated          = if ($adb.TimeCreated) { "$($adb.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "N/A" }
        }
    }
}

function Get-OCILoadBalancers {
    <#
    .SYNOPSIS
        Returns all load balancers in a compartment.
    .PARAMETER CompartmentId
        The OCID of the compartment.
    .PARAMETER Region
        Override the OCI region.
    .PARAMETER ConfigFile
        Path to the OCI config file.
    .PARAMETER Profile
        The profile name in the config file.
    .EXAMPLE
        Get-OCILoadBalancers -CompartmentId "ocid1.compartment.oc1..aaaaaaaexample"
        Returns all load balancers in the compartment.
    .EXAMPLE
        Get-OCILoadBalancers -CompartmentId $compartmentId -Region "us-ashburn-1" | Where-Object { $_.LifecycleState -eq "ACTIVE" }
        Returns only active load balancers in us-ashburn-1.
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop"; FullResponse = $true }
    if ($Region) { $splat["Region"] = $Region }
    if ($ConfigFile) { $splat["ConfigFile"] = $ConfigFile }
    if ($Profile) { $splat["Profile"] = $Profile }

    $allItems = @()
    $response = Get-OCILoadbalancerLoadBalancersList @splat
    $allItems += $response.Items
    while ($response.OpcNextPage) {
        $splat["Page"] = $response.OpcNextPage
        $response = Get-OCILoadbalancerLoadBalancersList @splat
        $allItems += $response.Items
    }

    foreach ($lb in $allItems) {
        # IP addresses
        $ipAddresses = "N/A"
        $primaryIP   = "N/A"
        if ($lb.IpAddresses -and $lb.IpAddresses.Count -gt 0) {
            $ipAddresses = ($lb.IpAddresses | ForEach-Object { "$($_.IpAddress)" }) -join ", "
            $primaryIP = "$($lb.IpAddresses[0].IpAddress)"
        }

        [PSCustomObject]@{
            Name            = if ($lb.DisplayName) { "$($lb.DisplayName)" } else { "$($lb.Id)" }
            LoadBalancerId  = "$($lb.Id)"
            ShapeName       = if ($lb.ShapeName) { "$($lb.ShapeName)" } else { "N/A" }
            LifecycleState  = "$($lb.LifecycleState)"
            Region          = if ($Region) { $Region } else { "default" }
            CompartmentId   = "$($lb.CompartmentId)"
            PrimaryIP       = $primaryIP
            AllIPs          = $ipAddresses
            IsPrivate       = if ($null -ne $lb.IsPrivate) { "$($lb.IsPrivate)" } else { "N/A" }
            SubnetIds       = if ($lb.SubnetIds) { ($lb.SubnetIds) -join ", " } else { "N/A" }
            BackendSetCount = if ($lb.BackendSets) { "$($lb.BackendSets.Count)" } else { "0" }
            ListenerCount   = if ($lb.Listeners) { "$($lb.Listeners.Count)" } else { "0" }
            TimeCreated     = if ($lb.TimeCreated) { "$($lb.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "N/A" }
        }
    }
}

function Get-OCIMonitoringMetrics {
    <#
    .SYNOPSIS
        Returns recent OCI Monitoring metric data for a resource.
    .DESCRIPTION
        Uses the OCI CLI to query the Monitoring service for metric data.
        Requires the OCI CLI to be installed and configured.
    .PARAMETER CompartmentId
        The OCID of the compartment.
    .PARAMETER Namespace
        The metric namespace (e.g. oci_computeagent, oci_database, oci_lbaas).
    .PARAMETER ResourceId
        The OCID of the resource.
    .PARAMETER MetricNames
        Array of metric names to query. If omitted, uses defaults per namespace.
    .PARAMETER Region
        Override the OCI region.
    .EXAMPLE
        Get-OCIMonitoringMetrics -CompartmentId $compartmentId -Namespace "oci_computeagent" -ResourceId "ocid1.instance.oc1..aaaaaaaexample"
        Returns default compute metrics (CPU, memory, disk, network) for the specified instance.
    .EXAMPLE
        Get-OCIMonitoringMetrics -CompartmentId $compartmentId -Namespace "oci_lbaas" -ResourceId $lbId -MetricNames @("ActiveConnections")
        Returns only the ActiveConnections metric for a load balancer.
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ResourceId,
        [string[]]$MetricNames,
        [string]$Region
    )

    if (-not (Get-Command oci -ErrorAction SilentlyContinue)) {
        Write-Verbose "OCI CLI not available - skipping metrics collection"
        return @()
    }

    # Default metrics per namespace
    if (-not $MetricNames) {
        $MetricNames = switch ($Namespace) {
            "oci_computeagent" {
                @("CpuUtilization", "MemoryUtilization", "DiskBytesRead",
                  "DiskBytesWritten", "NetworksBytesIn", "NetworksBytesOut")
            }
            "oci_database" {
                @("CpuUtilization", "StorageUtilization")
            }
            "oci_autonomous_database" {
                @("CpuUtilization", "StorageUtilized", "CurrentLogons")
            }
            "oci_lbaas" {
                @("ActiveConnections", "BytesReceived", "BytesSent",
                  "HttpRequests", "ResponseTimeFirstByte")
            }
            default { @() }
        }
    }

    $startTime = (Get-Date).AddHours(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")
    $endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")

    $results = @()
    foreach ($metricName in $MetricNames) {
        try {
            $queryText = "${metricName}[1h]{resourceId = `"${ResourceId}`"}.mean()"

            $cliArgs = @(
                "monitoring", "metric-data", "summarize-metrics-data",
                "--compartment-id", $CompartmentId,
                "--namespace", $Namespace,
                "--query-text", $queryText,
                "--start-time", $startTime,
                "--end-time", $endTime,
                "--output", "json"
            )
            if ($Region) { $cliArgs += @("--region", $Region) }

            $json = & oci @cliArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "OCI CLI error for $metricName : $json"
                continue
            }

            $data = $json | ConvertFrom-Json
            $lastValue = "N/A"
            $unit = "N/A"

            if ($data.data -and $data.data.Count -gt 0) {
                $series = $data.data[0]
                $unit = if ($series.unit) { "$($series.unit)" } else { "N/A" }
                if ($series.'aggregated-datapoints' -and $series.'aggregated-datapoints'.Count -gt 0) {
                    $latest = $series.'aggregated-datapoints' | Select-Object -Last 1
                    if ($null -ne $latest.value) {
                        $lastValue = "$([math]::Round($latest.value, 4))"
                    }
                }
            }

            $results += [PSCustomObject]@{
                MetricName = $metricName
                Namespace  = $Namespace
                LastValue  = $lastValue
                Unit       = $unit
            }
        }
        catch {
            Write-Verbose "Could not retrieve metric $metricName : $($_.Exception.Message)"
        }
    }

    return $results
}

function Resolve-OCIResourceIP {
    <#
    .SYNOPSIS
        Resolves an IP address for an OCI resource.
    .DESCRIPTION
        For Compute returns public IP (preferred) or private IP.
        For DB Systems returns the first resolved node IP.
        For Autonomous Databases returns the private endpoint IP.
        For Load Balancers returns the primary IP.
    .PARAMETER ResourceType
        The type of resource: Compute, DBSystem, AutonomousDB, or LoadBalancer.
    .PARAMETER Resource
        The resource object from the corresponding Get-OCI* function.
    .EXAMPLE
        $instances = Get-OCIComputeInstances -CompartmentId $compartmentId
        $ip = Resolve-OCIResourceIP -ResourceType "Compute" -Resource $instances[0]
        Resolves the IP for the first compute instance (prefers public IP).
    .EXAMPLE
        $lbs = Get-OCILoadBalancers -CompartmentId $compartmentId
        Resolve-OCIResourceIP -ResourceType "LoadBalancer" -Resource $lbs[0]
        Returns the primary IP of the first load balancer.
    .EXAMPLE
        $dbs = Get-OCIAutonomousDatabases -CompartmentId $compartmentId
        Resolve-OCIResourceIP -ResourceType "AutonomousDB" -Resource $dbs[0]
        Returns the private endpoint IP of the first Autonomous Database.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("Compute", "DBSystem", "AutonomousDB", "LoadBalancer")][string]$ResourceType,
        [Parameter(Mandatory)]$Resource
    )

    $ip = $null

    switch ($ResourceType) {
        "Compute" {
            if ($Resource.PublicIP -and $Resource.PublicIP -ne "N/A") {
                $ip = $Resource.PublicIP
            }
            elseif ($Resource.PrivateIP -and $Resource.PrivateIP -ne "N/A") {
                $ip = $Resource.PrivateIP
            }
        }
        "DBSystem" {
            if ($Resource.NodeIPs -and $Resource.NodeIPs -ne "N/A") {
                $ip = ($Resource.NodeIPs -split ",")[0].Trim()
            }
            elseif ($Resource.Hostname -and $Resource.Hostname -ne "N/A" -and
                    $Resource.Domain -and $Resource.Domain -ne "N/A") {
                $fqdn = "$($Resource.Hostname).$($Resource.Domain)"
                try {
                    $resolved = [System.Net.Dns]::GetHostAddresses($fqdn)
                    if ($resolved) { $ip = $resolved[0].IPAddressToString }
                }
                catch { }
            }
        }
        "AutonomousDB" {
            if ($Resource.PrivateEndpointIp -and $Resource.PrivateEndpointIp -ne "N/A") {
                $ip = $Resource.PrivateEndpointIp
            }
        }
        "LoadBalancer" {
            if ($Resource.PrimaryIP -and $Resource.PrimaryIP -ne "N/A") {
                $ip = $Resource.PrimaryIP
            }
        }
    }

    return $ip
}

function Get-OCIDashboard {
    <#
    .SYNOPSIS
        Builds a unified dashboard view of OCI Compute, DB Systems, Autonomous DBs, and Load Balancers.
    .DESCRIPTION
        Iterates compartments and collects compute instances, DB systems, autonomous
        databases, and load balancers into a flat collection suitable for Bootstrap
        Table display. Each row contains resource type, name, lifecycle state,
        resolved IP, region, availability domain, shape, creation time, and tags.
    .PARAMETER TenancyId
        The OCID of the tenancy (root compartment).
    .PARAMETER CompartmentIds
        Optional array of compartment OCIDs to limit scope. If omitted, discovers
        and scans all active compartments under the tenancy.
    .PARAMETER Region
        OCI region override (e.g. us-ashburn-1). Uses the configured default if omitted.
    .PARAMETER ConfigFile
        Path to the OCI config file. Defaults to ~/.oci/config.
    .PARAMETER Profile
        The OCI config profile name to use. Defaults to DEFAULT.
    .PARAMETER IncludeDBSystems
        Include Oracle DB Systems in the results. Defaults to $true.
    .PARAMETER IncludeAutonomousDBs
        Include Autonomous Databases in the results. Defaults to $true.
    .PARAMETER IncludeLoadBalancers
        Include Load Balancers in the results. Defaults to $true.
    .EXAMPLE
        Get-OCIDashboard -TenancyId "ocid1.tenancy.oc1..aaaaaaaexample"

        Returns all resources across all active compartments.
    .EXAMPLE
        Get-OCIDashboard -TenancyId $tenancyId -CompartmentIds $compId -IncludeDBSystems $false

        Returns compute, autonomous DBs, and load balancers from a single compartment.
    .EXAMPLE
        Connect-OCIProfile -ConfigFile "~/.oci/config" -Profile "PROD"
        $data = Get-OCIDashboard -TenancyId $tenancyId -Region "us-ashburn-1"
        Export-OCIDashboardHtml -DashboardData $data -OutputPath "C:\Reports\oci.html"
        Start-Process "C:\Reports\oci.html"

        End-to-end: configure profile, gather data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains: ResourceType, Name, LifecycleState, IPAddress, PrivateIP,
        Region, AvailabilityDomain, Shape, TimeCreated, Tags.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, OCI.PSModules, OCI config file (~/.oci/config).
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [Parameter(Mandatory)][string]$TenancyId,
        [string[]]$CompartmentIds,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile,
        [bool]$IncludeDBSystems = $true,
        [bool]$IncludeAutonomousDBs = $true,
        [bool]$IncludeLoadBalancers = $true
    )

    $commonSplat = @{}
    if ($Region)     { $commonSplat["Region"] = $Region }
    if ($ConfigFile) { $commonSplat["ConfigFile"] = $ConfigFile }
    if ($Profile)    { $commonSplat["Profile"] = $Profile }

    if (-not $CompartmentIds) {
        try {
            $compartments = Get-OCICompartments -TenancyId $TenancyId @commonSplat
            $CompartmentIds = @($TenancyId) + @($compartments | Select-Object -ExpandProperty CompartmentId)
        }
        catch {
            Write-Warning "Failed to list compartments: $($_.Exception.Message)"
            $CompartmentIds = @($TenancyId)
        }
    }

    $results = @()
    foreach ($compId in $CompartmentIds) {
        # Compute
        try {
            $instances = Get-OCIComputeInstances -CompartmentId $compId @commonSplat
            foreach ($inst in $instances) {
                $ip = Resolve-OCIResourceIP -ResourceType "Compute" -Resource $inst
                $results += [PSCustomObject]@{
                    ResourceType       = "Compute"
                    Name               = $inst.Name
                    LifecycleState     = $inst.LifecycleState
                    IPAddress          = if ($ip) { $ip } else { "N/A" }
                    PrivateIP          = $inst.PrivateIP
                    Region             = $inst.Region
                    AvailabilityDomain = $inst.AvailabilityDomain
                    Shape              = $inst.Shape
                    TimeCreated        = $inst.TimeCreated
                    Tags               = $inst.Tags
                }
            }
        }
        catch { Write-Warning "Compute query failed for compartment ${compId}: $($_.Exception.Message)" }

        # DB Systems
        if ($IncludeDBSystems) {
            try {
                $dbs = Get-OCIDBSystems -CompartmentId $compId @commonSplat
                foreach ($db in $dbs) {
                    $ip = Resolve-OCIResourceIP -ResourceType "DBSystem" -Resource $db
                    $results += [PSCustomObject]@{
                        ResourceType       = "DBSystem"
                        Name               = $db.Name
                        LifecycleState     = $db.LifecycleState
                        IPAddress          = if ($ip) { $ip } else { "N/A" }
                        PrivateIP          = "N/A"
                        Region             = $db.Region
                        AvailabilityDomain = $db.AvailabilityDomain
                        Shape              = $db.Shape
                        TimeCreated        = $db.TimeCreated
                        Tags               = ""
                    }
                }
            }
            catch { Write-Warning "DB Systems query failed for compartment ${compId}: $($_.Exception.Message)" }
        }

        # Autonomous Databases
        if ($IncludeAutonomousDBs) {
            try {
                $adbs = Get-OCIAutonomousDatabases -CompartmentId $compId @commonSplat
                foreach ($adb in $adbs) {
                    $ip = Resolve-OCIResourceIP -ResourceType "AutonomousDB" -Resource $adb
                    $results += [PSCustomObject]@{
                        ResourceType       = "AutonomousDB"
                        Name               = $adb.Name
                        LifecycleState     = $adb.LifecycleState
                        IPAddress          = if ($ip) { $ip } else { "N/A" }
                        PrivateIP          = $adb.PrivateEndpointIp
                        Region             = $adb.Region
                        AvailabilityDomain = "N/A"
                        Shape              = "$($adb.CpuCoreCount) OCPUs"
                        TimeCreated        = $adb.TimeCreated
                        Tags               = ""
                    }
                }
            }
            catch { Write-Warning "Autonomous DB query failed for compartment ${compId}: $($_.Exception.Message)" }
        }

        # Load Balancers
        if ($IncludeLoadBalancers) {
            try {
                $lbs = Get-OCILoadBalancers -CompartmentId $compId @commonSplat
                foreach ($lb in $lbs) {
                    $ip = Resolve-OCIResourceIP -ResourceType "LoadBalancer" -Resource $lb
                    $results += [PSCustomObject]@{
                        ResourceType       = "LoadBalancer"
                        Name               = $lb.Name
                        LifecycleState     = $lb.LifecycleState
                        IPAddress          = if ($ip) { $ip } else { "N/A" }
                        PrivateIP          = "N/A"
                        Region             = $lb.Region
                        AvailabilityDomain = "N/A"
                        Shape              = $lb.ShapeName
                        TimeCreated        = $lb.TimeCreated
                        Tags               = ""
                    }
                }
            }
            catch { Write-Warning "Load Balancer query failed for compartment ${compId}: $($_.Exception.Message)" }
        }
    }

    return $results
}

function Export-OCIDashboardHtml {
    <#
    .SYNOPSIS
        Renders OCI dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-OCIDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-OCIDashboard containing Compute, DB System,
        Autonomous DB, and Load Balancer details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "OCI Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        OCI-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-OCIDashboard -TenancyId $tenancyId
        Export-OCIDashboardHtml -DashboardData $data -OutputPath "C:\Reports\oci.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-OCIDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\oci.html" -ReportTitle "Prod OCI"

        Exports with a custom report title.
    .EXAMPLE
        Connect-OCIProfile -Profile "PROD"
        $data = Get-OCIDashboard -TenancyId $tenancyId -Region "us-ashburn-1"
        Export-OCIDashboardHtml -DashboardData $data -OutputPath "C:\Reports\oci.html"
        Start-Process "C:\Reports\oci.html"

        Full pipeline: configure profile, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, OCI-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "OCI Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "OCI-Dashboard-Template.html"
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
        if ($prop.Name -eq 'LifecycleState') {
            $col.formatter = 'formatState'
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
    Write-Verbose "OCI Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCB2gDNBlhgvVEP
# 0N2jp2CK2ihrTEMqMloIm6Mv8Dog7aCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCr3t6usWuX5ejFEXqal94jctXM2ImqzPqSxbUT40XaRDANBgkqhkiG9w0BAQEF
# AASCAgDMM7qQ5uaeuobWP7qacl6OjG4vAc+V+a5CQM6J3ya6uFl197dseqG2XLpV
# XexeeXgPKgf0gLtJ0sJS4d2VryAcGs4x3eumN97mLb0s7WOwaSp46ep6BIdiIHQB
# /5vHJJQylBNBbyr7fUG62wS58JwTAS2zfWgmLO1gR4mVtFUN/rD10di+saiu8HpR
# 7PbpQfXEnZWqsqf0NQP/xm8MmKaNxAXRfHVNyUT4wpIpmX1i9ufqdGF2+kBLvAly
# bMVe/wZQ4dXJb5LrznIxAMtLPL6MGVSp/1mGGAnMk2pRRtdFhgHBMhcjOA/4RMiT
# B7fhi1uBY+Ph2WQKpDEDbtBdKXdpJYCNDz4uNB65QDZcPo1coZYexScPXW/zgZtQ
# BmVzodw2WPkBDlDmjDBsFWmSRVaVVrfkwzK9FZPrkQCQZN3/V0qZgr2oWcmlCzuj
# gUufiq2PH6L4++1GXclxnm08MH9PeM8/BX/YzVHlWu9CEB6Y6CdYkOyYXjvgZ94c
# 5g1hodcE4uDsWDYsICxolW+9RmMD+0auWScOEMyxHDIWwXGpcRSnQ+9VlilY6Uxs
# ROv604qbrmfinKBZbCw/UUrV7s0xHmptO2L4VyIeCqW6TeHS2hRGykGzz35JPKeH
# sfKL09sIANIKYXR+/fjV3ZFmj2oNeGn8sl5dE7FEXTO5dgcADKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjUyMDM3NDBaMC8GCSqGSIb3DQEJBDEiBCCjaGki
# DrmKHzJyzY2DykkVCCVMFiHrzp6UV0NPlb0M4zANBgkqhkiG9w0BAQEFAASCAgBA
# oLwvJJE9vhYzbg78F2w+6jNc/0lTrBshue8jVguz07U3s8aKQMnNB8IoNyD7xXTJ
# RCT7BwIsPQQxKj5UeyB7i9mb6zlpaucp/W/NszCFB2EF1w4+7/cebVzaCbDOmiwl
# MLPfYjCZdCdAKByyVD8O/f4tauSaArHptgh/XM/eBUIABbzvhMpNZqKYa/Ckp4kd
# EO1V6Nopd+kp6sejrKOQILtXHAuESKtECca4yAkLJYLc9Q1Uc7g2pSDwhw/lj9/B
# 05HsAZEaAhlE0fycj/oiJD7ajDMSUk+LA52XJ20AybOKoM0WpLtLC9R8w6iLLJ13
# mAReTBsOnCyHS/Jhn6hoszLmQ8ynbFzALlBJi7WF5LY0o1OMKnJhkGPUASbTkdwr
# 9PdSSuCmfcf5+2xktYtRKA1KZP7+AKUvnBSQ5cqNIRjrJNJ4p7zxNTz61BXDVZ1r
# Fumecdh3g/vly92zaFoMhXxY4B+TKQZHl+4B71JjEWNHNTlpgP7JHfZ54GlPl3f+
# lUOn2pVgnPWUaMw2ns6yYbIQZVzmNkWNp1GB6OGRlOEH6MWr0BB6Jd94gq0pyzUm
# y6ZUcLNlXt75tXyveIIBB59mJPzdY+I8lFozg4CFWt424+hy5Usxw5/FUHUoKkkw
# un4pSkVQOKiQGLPQ9Hi1SvdmOkz9S/b/NC6oVXaGfQ==
# SIG # End signature block
