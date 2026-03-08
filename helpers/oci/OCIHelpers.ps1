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
        config file — this function only verifies it works.
    .PARAMETER ConfigFile
        Path to the OCI config file. Defaults to ~/.oci/config.
    .PARAMETER Profile
        The profile name in the config file. Defaults to DEFAULT.
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

    $splat = @{ ErrorAction = "Stop" }
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
    #>
    param(
        [Parameter(Mandatory)][string]$TenancyId,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $TenancyId; ErrorAction = "Stop" }
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
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop" }
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
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop" }
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
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop" }
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
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [string]$Region,
        [string]$ConfigFile,
        [string]$Profile
    )

    $splat = @{ CompartmentId = $CompartmentId; ErrorAction = "Stop" }
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
    #>
    param(
        [Parameter(Mandatory)][string]$CompartmentId,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ResourceId,
        [string[]]$MetricNames,
        [string]$Region
    )

    if (-not (Get-Command oci -ErrorAction SilentlyContinue)) {
        Write-Verbose "OCI CLI not available — skipping metrics collection"
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

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBmKb+CLc4qIc55
# 26FJmKFGLdugiic90r8z/2fyZqf23aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgyzPwTwZDt8/lorvAPVzN5j0f9gyFB5g6
# uSLlmdsU/1gwDQYJKoZIhvcNAQEBBQAEggIABctZOmgK5gNAyFhEY7eBEynfRZwc
# IqqIe0V2VDqhVbTkGno5mfQW1AWm4B/6LNKd+ttKdbzRCEtg4ujOAXczuRStFgjI
# nxYpchfs8p/9hh+bYWC1VIpi7nooJ2qsQPjbwDetp/fQ90rgWRUSfkSp18wVHlJN
# uufiktSWLoiyXsvGdKlIx1OyE19IyEP75d3aNsDs8pl/Q7jAgdHuy+9XaVX2DdEO
# M4fPu5+YWFz1TgRrWt5ftO7sak2ZxmC6cGbK5UCnPSGZUmY4cA44a31/ZA9zFSii
# OVoGkFr0EMOlGvlJyVG7g7nZjwag0fYKCylq1uZL1Ra21kyc/DzxstSNqCWK3yzJ
# l0n3lnj+5KFyJlSkGlf28U+bOAQLShJJWpGZsz25eB+xTs54/lL/JAvID/isj0dR
# VBDuxSIPIBwmLMRp08N9YXj7R+WcXtftodBIfyT2EPOF92Sy791qW5YnFmjqpwJU
# 3lJPDGgpFGagYL+uFbo/W4zRImpkwltylXN4OFbvRtWEaLigEW32sSw8gY5S/Hga
# iJkqo83DYlu5h2i4V6y/5669cvMMtWkAMm5gnnjrGt0W9XR3t8TeksxoBjG6PgbO
# TJd+MFHgH5+ygzHVLnSxltdgW50ylr+O9erovPo8XaH/DRJi0OIQJPIQeG7xKCpA
# 25JqDf5VXOrgIYA=
# SIG # End signature block
