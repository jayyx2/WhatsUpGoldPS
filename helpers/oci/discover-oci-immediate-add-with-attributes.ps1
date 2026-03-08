# Configuration
$OCIConfigFile = ""                                             # Path to OCI config file (leave empty for default ~/.oci/config)
$OCIProfile    = "DEFAULT"                                      # OCI config profile name
$OCITenancyId  = "ocid1.tenancy.oc1..your-tenancy-ocid-here"   # Your tenancy OCID
$OCIRegions    = @("us-ashburn-1")                              # Regions to scan (add more as needed)
$WUGServer     = "192.168.1.250"

# Credentials
if (!$WUGCred) { $WUGCred = Get-Credential -Message "Enter credentials for WUG server" }

# Check if required modules are installed and loaded
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

$requiredOCIModules = @('OCI.PSModules.Identity', 'OCI.PSModules.Compute', 'OCI.PSModules.Core',
    'OCI.PSModules.Database', 'OCI.PSModules.Loadbalancer')
foreach ($mod in $requiredOCIModules) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        throw "Required module '$mod' is not installed. Run: Install-Module -Name OCI.PSModules -Scope CurrentUser -Force"
    }
    if (-not (Get-Module -Name $mod)) { Import-Module $mod }
}

# Load helper functions
. "$PSScriptRoot\OCIHelpers.ps1"

# ========================
# Validate OCI Connectivity
# ========================
Write-Host "`n=== Validating OCI Connectivity ===" -ForegroundColor Cyan
$ociSplat = @{}
if ($OCIConfigFile) { $ociSplat["ConfigFile"] = $OCIConfigFile }
if ($OCIProfile -and $OCIProfile -ne "DEFAULT") { $ociSplat["Profile"] = $OCIProfile }
Connect-OCIProfile @ociSplat

# ========================
# Get Compartments
# ========================
Write-Host "`n=== Listing Compartments ===" -ForegroundColor Cyan
$compartments = @(Get-OCICompartments -TenancyId $OCITenancyId @ociSplat)

# Include root compartment (tenancy itself)
$allCompartmentIds = @($OCITenancyId) + ($compartments | ForEach-Object { $_.CompartmentId })
Write-Host "  Found $($compartments.Count) sub-compartments + root = $($allCompartmentIds.Count) total" -ForegroundColor Gray

# ========================
# Discover Resources Across Regions & Compartments
# ========================
$allCompute = @()
$allDBSys   = @()
$allADB     = @()
$allLB      = @()

foreach ($region in $OCIRegions) {
    Write-Host "`n=== Region: $region ===" -ForegroundColor Cyan

    foreach ($cid in $allCompartmentIds) {
        $cidShort = $cid.Substring($cid.Length - [math]::Min(12, $cid.Length))
        Write-Host "  Compartment ...$cidShort" -ForegroundColor DarkGray

        # --- Compute Instances ---
        try {
            $instances = @(Get-OCIComputeInstances -CompartmentId $cid -Region $region @ociSplat)
            if ($instances.Count -gt 0) {
                Write-Host "    Compute: $($instances.Count) instances" -ForegroundColor Gray
                $allCompute += $instances
            }
        }
        catch {
            Write-Verbose "  Could not enumerate Compute in $cid : $($_.Exception.Message)"
        }

        # --- DB Systems ---
        try {
            $dbSystems = @(Get-OCIDBSystems -CompartmentId $cid -Region $region @ociSplat)
            if ($dbSystems.Count -gt 0) {
                Write-Host "    DB Systems: $($dbSystems.Count)" -ForegroundColor Gray
                $allDBSys += $dbSystems
            }
        }
        catch {
            Write-Verbose "  Could not enumerate DB Systems in $cid : $($_.Exception.Message)"
        }

        # --- Autonomous Databases ---
        try {
            $autonomousDBs = @(Get-OCIAutonomousDatabases -CompartmentId $cid -Region $region @ociSplat)
            if ($autonomousDBs.Count -gt 0) {
                Write-Host "    Autonomous DBs: $($autonomousDBs.Count)" -ForegroundColor Gray
                $allADB += $autonomousDBs
            }
        }
        catch {
            Write-Verbose "  Could not enumerate Autonomous DBs in $cid : $($_.Exception.Message)"
        }

        # --- Load Balancers ---
        try {
            $loadBalancers = @(Get-OCILoadBalancers -CompartmentId $cid -Region $region @ociSplat)
            if ($loadBalancers.Count -gt 0) {
                Write-Host "    Load Balancers: $($loadBalancers.Count)" -ForegroundColor Gray
                $allLB += $loadBalancers
            }
        }
        catch {
            Write-Verbose "  Could not enumerate Load Balancers in $cid : $($_.Exception.Message)"
        }
    }
}

# ========================
# Display Summary
# ========================
Write-Host "`n=== Discovery Summary ===" -ForegroundColor Cyan
Write-Host "  Compute Instances:    $($allCompute.Count)"
Write-Host "  DB Systems:           $($allDBSys.Count)"
Write-Host "  Autonomous Databases: $($allADB.Count)"
Write-Host "  Load Balancers:       $($allLB.Count)"

if ($allCompute.Count -gt 0) {
    Write-Host "`n=== Compute Instances ===" -ForegroundColor Cyan
    $allCompute | Format-Table Name, Shape, LifecycleState, Region, PublicIP, PrivateIP -AutoSize
}

if ($allDBSys.Count -gt 0) {
    Write-Host "`n=== DB Systems ===" -ForegroundColor Cyan
    $allDBSys | Format-Table Name, Shape, LifecycleState, Region, DatabaseEdition, NodeIPs -AutoSize
}

if ($allADB.Count -gt 0) {
    Write-Host "`n=== Autonomous Databases ===" -ForegroundColor Cyan
    $allADB | Format-Table Name, DbWorkload, LifecycleState, Region, CpuCoreCount, PrivateEndpointIp -AutoSize
}

if ($allLB.Count -gt 0) {
    Write-Host "`n=== Load Balancers ===" -ForegroundColor Cyan
    $allLB | Format-Table Name, ShapeName, LifecycleState, Region, PrimaryIP, IsPrivate -AutoSize
}

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

$added = 0; $skipped = 0

# --- Compute Instances ---
Write-Host "`n=== Adding Compute Instances to WUG ===" -ForegroundColor Cyan
foreach ($inst in $allCompute) {
    $ip = Resolve-OCIResourceIP -ResourceType Compute -Resource $inst

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping Compute $($inst.Name) ($($inst.InstanceId)) - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored Compute $($inst.Name) ($ip)"
        $skipped++
        continue
    }

    # Fetch monitoring metrics
    $metrics = Get-OCIMonitoringMetrics -CompartmentId $inst.CompartmentId -Namespace "oci_computeagent" `
        -ResourceId $inst.InstanceId -Region $inst.Region

    $attributes = @(
        @{ Name = "OCI_Type";              Value = "Compute Instance" }
        @{ Name = "OCI_InstanceId";        Value = "$($inst.InstanceId)" }
        @{ Name = "OCI_Shape";             Value = "$($inst.Shape)" }
        @{ Name = "OCI_LifecycleState";    Value = "$($inst.LifecycleState)" }
        @{ Name = "OCI_AvailabilityDomain"; Value = "$($inst.AvailabilityDomain)" }
        @{ Name = "OCI_FaultDomain";       Value = "$($inst.FaultDomain)" }
        @{ Name = "OCI_Region";            Value = "$($inst.Region)" }
        @{ Name = "OCI_CompartmentId";     Value = "$($inst.CompartmentId)" }
        @{ Name = "OCI_PublicIP";          Value = "$($inst.PublicIP)" }
        @{ Name = "OCI_PrivateIP";         Value = "$($inst.PrivateIP)" }
        @{ Name = "OCI_ImageId";           Value = "$($inst.ImageId)" }
        @{ Name = "OCI_TimeCreated";       Value = "$($inst.TimeCreated)" }
        @{ Name = "OCI_Tags";             Value = "$($inst.Tags)" }
        @{ Name = "OCI_LastSync";          Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "OCI_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "OCI Compute $($inst.Shape) | $($inst.Region) $($inst.AvailabilityDomain) | " +
            "FD: $($inst.FaultDomain) | Created: $($inst.TimeCreated) | " +
            "Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $inst.Name `
        -DeviceAddress $ip `
        -Brand "OCI Compute" `
        -OS "Oracle Linux" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added Compute $($inst.Name) ($ip)" -ForegroundColor Green
        $added++
    }
}

# --- DB Systems ---
Write-Host "`n=== Adding DB Systems to WUG ===" -ForegroundColor Cyan
foreach ($db in $allDBSys) {
    $ip = Resolve-OCIResourceIP -ResourceType DBSystem -Resource $db

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping DB System $($db.Name) ($($db.DBSystemId)) - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored DB System $($db.Name) ($ip)"
        $skipped++
        continue
    }

    $metrics = Get-OCIMonitoringMetrics -CompartmentId $db.CompartmentId -Namespace "oci_database" `
        -ResourceId $db.DBSystemId -Region $db.Region

    $attributes = @(
        @{ Name = "OCI_Type";               Value = "DB System" }
        @{ Name = "OCI_DBSystemId";         Value = "$($db.DBSystemId)" }
        @{ Name = "OCI_Shape";              Value = "$($db.Shape)" }
        @{ Name = "OCI_LifecycleState";     Value = "$($db.LifecycleState)" }
        @{ Name = "OCI_AvailabilityDomain"; Value = "$($db.AvailabilityDomain)" }
        @{ Name = "OCI_Region";             Value = "$($db.Region)" }
        @{ Name = "OCI_CompartmentId";      Value = "$($db.CompartmentId)" }
        @{ Name = "OCI_Hostname";           Value = "$($db.Hostname)" }
        @{ Name = "OCI_Domain";             Value = "$($db.Domain)" }
        @{ Name = "OCI_DatabaseEdition";    Value = "$($db.DatabaseEdition)" }
        @{ Name = "OCI_CpuCoreCount";       Value = "$($db.CpuCoreCount)" }
        @{ Name = "OCI_DataStorageGB";      Value = "$($db.DataStorageSizeInGBs)" }
        @{ Name = "OCI_NodeCount";          Value = "$($db.NodeCount)" }
        @{ Name = "OCI_DiskRedundancy";     Value = "$($db.DiskRedundancy)" }
        @{ Name = "OCI_LicenseModel";       Value = "$($db.LicenseModel)" }
        @{ Name = "OCI_Version";            Value = "$($db.Version)" }
        @{ Name = "OCI_TimeCreated";        Value = "$($db.TimeCreated)" }
        @{ Name = "OCI_LastSync";           Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "OCI_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "OCI DB System $($db.DatabaseEdition) $($db.Version) | $($db.Shape) | " +
            "$($db.Region) $($db.AvailabilityDomain) | CPUs: $($db.CpuCoreCount) | " +
            "Storage: $($db.DataStorageSizeInGBs) GB | Nodes: $($db.NodeCount) | " +
            "Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $db.Name `
        -DeviceAddress $ip `
        -Brand "OCI Database" `
        -OS "Oracle Database $($db.Version)" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added DB System $($db.Name) ($ip)" -ForegroundColor Green
        $added++
    }
}

# --- Autonomous Databases ---
Write-Host "`n=== Adding Autonomous Databases to WUG ===" -ForegroundColor Cyan
foreach ($adb in $allADB) {
    $ip = Resolve-OCIResourceIP -ResourceType AutonomousDB -Resource $adb

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping Autonomous DB $($adb.Name) ($($adb.AutonomousDbId)) - no resolvable IP (private endpoint required)"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored Autonomous DB $($adb.Name) ($ip)"
        $skipped++
        continue
    }

    $metrics = Get-OCIMonitoringMetrics -CompartmentId $adb.CompartmentId -Namespace "oci_autonomous_database" `
        -ResourceId $adb.AutonomousDbId -Region $adb.Region

    $attributes = @(
        @{ Name = "OCI_Type";               Value = "Autonomous Database" }
        @{ Name = "OCI_AutonomousDbId";     Value = "$($adb.AutonomousDbId)" }
        @{ Name = "OCI_DbWorkload";         Value = "$($adb.DbWorkload)" }
        @{ Name = "OCI_LifecycleState";     Value = "$($adb.LifecycleState)" }
        @{ Name = "OCI_Region";             Value = "$($adb.Region)" }
        @{ Name = "OCI_CompartmentId";      Value = "$($adb.CompartmentId)" }
        @{ Name = "OCI_CpuCoreCount";       Value = "$($adb.CpuCoreCount)" }
        @{ Name = "OCI_DataStorageTB";      Value = "$($adb.DataStorageSizeInTBs)" }
        @{ Name = "OCI_PrivateEndpointIp";  Value = "$($adb.PrivateEndpointIp)" }
        @{ Name = "OCI_IsFreeTier";         Value = "$($adb.IsFreeTier)" }
        @{ Name = "OCI_LicenseModel";       Value = "$($adb.LicenseModel)" }
        @{ Name = "OCI_DbVersion";          Value = "$($adb.DbVersion)" }
        @{ Name = "OCI_IsAutoScaling";      Value = "$($adb.IsAutoScalingEnabled)" }
        @{ Name = "OCI_IsDedicated";        Value = "$($adb.IsDedicated)" }
        @{ Name = "OCI_TimeCreated";        Value = "$($adb.TimeCreated)" }
        @{ Name = "OCI_LastSync";           Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "OCI_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "OCI Autonomous DB $($adb.DbWorkload) | $($adb.Region) | " +
            "OCPUs: $($adb.CpuCoreCount) | Storage: $($adb.DataStorageSizeInTBs) TB | " +
            "Version: $($adb.DbVersion) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $adb.Name `
        -DeviceAddress $ip `
        -Brand "OCI Autonomous DB" `
        -OS "Oracle Autonomous $($adb.DbWorkload)" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added Autonomous DB $($adb.Name) ($ip)" -ForegroundColor Green
        $added++
    }
}

# --- Load Balancers ---
Write-Host "`n=== Adding Load Balancers to WUG ===" -ForegroundColor Cyan
foreach ($lb in $allLB) {
    $ip = Resolve-OCIResourceIP -ResourceType LoadBalancer -Resource $lb

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping LB $($lb.Name) ($($lb.LoadBalancerId)) - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored LB $($lb.Name) ($ip)"
        $skipped++
        continue
    }

    $metrics = Get-OCIMonitoringMetrics -CompartmentId $lb.CompartmentId -Namespace "oci_lbaas" `
        -ResourceId $lb.LoadBalancerId -Region $lb.Region

    $attributes = @(
        @{ Name = "OCI_Type";              Value = "Load Balancer" }
        @{ Name = "OCI_LoadBalancerId";    Value = "$($lb.LoadBalancerId)" }
        @{ Name = "OCI_ShapeName";         Value = "$($lb.ShapeName)" }
        @{ Name = "OCI_LifecycleState";    Value = "$($lb.LifecycleState)" }
        @{ Name = "OCI_Region";            Value = "$($lb.Region)" }
        @{ Name = "OCI_CompartmentId";     Value = "$($lb.CompartmentId)" }
        @{ Name = "OCI_PrimaryIP";         Value = "$($lb.PrimaryIP)" }
        @{ Name = "OCI_AllIPs";            Value = "$($lb.AllIPs)" }
        @{ Name = "OCI_IsPrivate";         Value = "$($lb.IsPrivate)" }
        @{ Name = "OCI_BackendSets";       Value = "$($lb.BackendSetCount)" }
        @{ Name = "OCI_Listeners";         Value = "$($lb.ListenerCount)" }
        @{ Name = "OCI_TimeCreated";       Value = "$($lb.TimeCreated)" }
        @{ Name = "OCI_LastSync";          Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "OCI_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "OCI LB $($lb.ShapeName) | $($lb.Region) | Private: $($lb.IsPrivate) | " +
            "Backends: $($lb.BackendSetCount) | Listeners: $($lb.ListenerCount) | " +
            "Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $lb.Name `
        -DeviceAddress $ip `
        -Brand "OCI Load Balancer" `
        -OS "OCI LBaaS $($lb.ShapeName)" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added LB $($lb.Name) ($ip)" -ForegroundColor Green
        $added++
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Added:   $added"
Write-Host "  Skipped: $skipped"
Write-Host "  Total:   $($allCompute.Count + $allDBSys.Count + $allADB.Count + $allLB.Count)"

# Cleanup
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCmym16J4LDOYHv
# qfsAiUX8k4JipuQixrwLsKiB7z21pKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgTl603RkOQiAfRBSSZiIroSzT5Vk0/JPs
# Lb0s82K+DEAwDQYJKoZIhvcNAQEBBQAEggIATmNNgW8nKQFAWZyZQ5cVtxY51ZF7
# +0NJi4hEkU7UPSOYPU25wuCQ+gMWYY1VOl4emUKWWt48KByWk9L84ERxmGHCXg4w
# Aws5LtTWpE1Y6BfLpuhPS6i4AneoDk8YdDxS6UsgeCHY/EP7ZjsOn6k47xLw5qfT
# CiqUjUv2mfFb5/xw1d1ej3YrawyOZZ5rkAIKkiVICGwXA4YadHk5ojJe860ghXSI
# jucH7a2Fhpa40B1ci41CM2dH16IruFubn7NmIP1Rb/ruGIFeBPS7dj30TogaV5Vf
# zLNfbw4OKo3pBI3e6qzSNJQ9ESVYtvvB+wSB6RoIZ68BEPmRVcCkWxzfLGeW+nyg
# y/illRkcbtxnEvJBMhCY3IC2vMB/KrD/SP5jHTFV/yZV2aifr8183nf2ndYdRTnK
# gaemFk8u1TzCk2LM69tEO8iSsgRefUO0+TbSexCUrVG23KnnjjSo6L7AOUHKfam3
# sazuSmoyLkOGtjt6RGwu97h4l6m2KPREmDxOuA+ubdKm5xaes5qusFBKU/oRayff
# sOhk8ijB5PNuRiM9rvfGcEziwB5JJnQ0TjFNoNXGAVlAOlu2DPVAYcJ7GSvyrNTL
# T3jjODH/oiRPHwOrsTjngy+R3eVNqtPD/wABCLdEy5cq8n+AYAC3NA32su2J/6Bm
# K/dk1S6S0RLUYB4=
# SIG # End signature block
