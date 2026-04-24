# Configuration
$AWSRegions = @("us-east-1")  # Regions to scan (add more as needed)

# Check if required modules are installed and loaded
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

$requiredAWSModules = @('AWS.Tools.Common', 'AWS.Tools.EC2', 'AWS.Tools.CloudWatch',
    'AWS.Tools.RDS', 'AWS.Tools.ElasticLoadBalancingV2')
foreach ($mod in $requiredAWSModules) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        throw "Required module '$mod' is not installed. Run: Install-Module -Name AWS.Tools.Installer -Scope CurrentUser -Force; Install-AWSToolsModule EC2, CloudWatch, RDS, ElasticLoadBalancingV2 -CleanUp"
    }
    if (-not (Get-Module -Name $mod)) { Import-Module $mod }
}

# Load helper functions
. "$PSScriptRoot\AWSHelpers.ps1"

# Load vault functions for credential resolution
$discoveryHelpersPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'discovery\DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) { . $discoveryHelpersPath }

# ========================
# Resolve credentials from vault
# ========================
$awsCred = Resolve-DiscoveryCredential -Name 'AWS.Credential' -CredType AWSKeys -ProviderLabel 'AWS' -AutoUse
if ($awsCred) {
    $AWSAccessKey = $awsCred.UserName
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($awsCred.Password)
    try { $AWSSecretKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
} else {
    throw "AWS credentials are required. Store them in the vault using Setup-AWS-Discovery.ps1"
}
$WUGCred = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -ProviderLabel 'WhatsUp Gold' -AutoUse
if (-not $WUGCred) { throw "WhatsUp Gold credentials are required. Store them in the vault first." }
$WUGServer = $WUGCred.UserName

# ========================
# Connect to AWS
# ========================
Write-Host "`n=== Connecting to AWS ===" -ForegroundColor Cyan
Connect-AWSProfile -AccessKey $AWSAccessKey -SecretKey $AWSSecretKey -Region $AWSRegions[0]
$AWSSecretKey = $null

# ========================
# Discover Resources Across Regions
# ========================
$allEC2  = @()
$allRDS  = @()
$allELB  = @()

foreach ($region in $AWSRegions) {
    Write-Host "`n=== Region: $region ===" -ForegroundColor Cyan

    # --- EC2 Instances ---
    Write-Host "  Gathering EC2 instances..." -ForegroundColor Gray
    try {
        $ec2Instances = @(Get-AWSEC2Instances -Region $region)
        Write-Host "    Found $($ec2Instances.Count) EC2 instances" -ForegroundColor Gray
        $allEC2 += $ec2Instances
    }
    catch {
        Write-Warning "  Could not enumerate EC2 in $region : $($_.Exception.Message)"
    }

    # --- RDS Instances ---
    Write-Host "  Gathering RDS instances..." -ForegroundColor Gray
    try {
        $rdsInstances = @(Get-AWSRDSInstances -Region $region)
        Write-Host "    Found $($rdsInstances.Count) RDS instances" -ForegroundColor Gray
        $allRDS += $rdsInstances
    }
    catch {
        Write-Warning "  Could not enumerate RDS in $region : $($_.Exception.Message)"
    }

    # --- Load Balancers ---
    Write-Host "  Gathering Load Balancers..." -ForegroundColor Gray
    try {
        $loadBalancers = @(Get-AWSLoadBalancers -Region $region)
        Write-Host "    Found $($loadBalancers.Count) load balancers" -ForegroundColor Gray
        $allELB += $loadBalancers
    }
    catch {
        Write-Warning "  Could not enumerate ELB in $region : $($_.Exception.Message)"
    }
}

# ========================
# Display Summary
# ========================
Write-Host "`n=== Discovery Summary ===" -ForegroundColor Cyan
Write-Host "  EC2 Instances:  $($allEC2.Count)"
Write-Host "  RDS Instances:  $($allRDS.Count)"
Write-Host "  Load Balancers: $($allELB.Count)"

if ($allEC2.Count -gt 0) {
    Write-Host "`n=== EC2 Instances ===" -ForegroundColor Cyan
    $allEC2 | Format-Table Name, InstanceId, InstanceType, State, Region, PublicIP, PrivateIP -AutoSize
}

if ($allRDS.Count -gt 0) {
    Write-Host "`n=== RDS Instances ===" -ForegroundColor Cyan
    $allRDS | Format-Table DBInstanceId, Engine, DBInstanceClass, Status, Region, Endpoint -AutoSize
}

if ($allELB.Count -gt 0) {
    Write-Host "`n=== Load Balancers ===" -ForegroundColor Cyan
    $allELB | Format-Table LoadBalancerName, Type, Scheme, State, Region, DNSName -AutoSize
}

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

$added = 0; $skipped = 0

# --- EC2 Instances ---
Write-Host "`n=== Adding EC2 Instances to WUG ===" -ForegroundColor Cyan
foreach ($inst in $allEC2) {
    $ip = Resolve-AWSResourceIP -ResourceType EC2 -Resource $inst

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping EC2 $($inst.Name) ($($inst.InstanceId)) - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored EC2 $($inst.Name) ($ip)"
        $skipped++
        continue
    }

    # Fetch CloudWatch metrics
    $metrics = Get-AWSCloudWatchMetrics -Namespace "AWS/EC2" -DimensionName "InstanceId" `
        -DimensionValue $inst.InstanceId -Region $inst.Region

    $attributes = @(
        @{ Name = "AWS_Type";              Value = "EC2 Instance" }
        @{ Name = "AWS_InstanceId";        Value = "$($inst.InstanceId)" }
        @{ Name = "AWS_InstanceType";      Value = "$($inst.InstanceType)" }
        @{ Name = "AWS_State";             Value = "$($inst.State)" }
        @{ Name = "AWS_Region";            Value = "$($inst.Region)" }
        @{ Name = "AWS_AvailabilityZone";  Value = "$($inst.AvailabilityZone)" }
        @{ Name = "AWS_VpcId";             Value = "$($inst.VpcId)" }
        @{ Name = "AWS_SubnetId";          Value = "$($inst.SubnetId)" }
        @{ Name = "AWS_PublicIP";          Value = "$($inst.PublicIP)" }
        @{ Name = "AWS_PrivateIP";         Value = "$($inst.PrivateIP)" }
        @{ Name = "AWS_PublicDnsName";     Value = "$($inst.PublicDnsName)" }
        @{ Name = "AWS_PrivateDnsName";    Value = "$($inst.PrivateDnsName)" }
        @{ Name = "AWS_Platform";          Value = "$($inst.Platform)" }
        @{ Name = "AWS_Architecture";      Value = "$($inst.Architecture)" }
        @{ Name = "AWS_ImageId";           Value = "$($inst.ImageId)" }
        @{ Name = "AWS_KeyName";           Value = "$($inst.KeyName)" }
        @{ Name = "AWS_LaunchTime";        Value = "$($inst.LaunchTime)" }
        @{ Name = "AWS_SecurityGroups";    Value = "$($inst.SecurityGroups)" }
        @{ Name = "AWS_DiskCount";         Value = "$($inst.DiskCount)" }
        @{ Name = "AWS_RootDeviceType";    Value = "$($inst.RootDeviceType)" }
        @{ Name = "AWS_Tags";             Value = "$($inst.Tags)" }
        @{ Name = "AWS_IAMRole";           Value = "$($inst.IAMRole)" }
        @{ Name = "AWS_Monitoring";        Value = "$($inst.Monitoring)" }
        @{ Name = "AWS_LastSync";          Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    # Add CloudWatch metric values as attributes
    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "AWS_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "EC2 $($inst.InstanceType) | $($inst.Region) $($inst.AvailabilityZone) | " +
            "VPC: $($inst.VpcId) | $($inst.Platform) $($inst.Architecture) | " +
            "Launched: $($inst.LaunchTime) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $inst.Name `
        -DeviceAddress $ip `
        -Brand "AWS EC2" `
        -OS $inst.Platform `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added EC2 $($inst.Name) ($ip)" -ForegroundColor Green
        $added++
    }
}

# --- RDS Instances ---
Write-Host "`n=== Adding RDS Instances to WUG ===" -ForegroundColor Cyan
foreach ($db in $allRDS) {
    $ip = Resolve-AWSResourceIP -ResourceType RDS -Resource $db

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping RDS $($db.DBInstanceId) - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored RDS $($db.DBInstanceId) ($ip)"
        $skipped++
        continue
    }

    # Fetch CloudWatch metrics
    $metrics = Get-AWSCloudWatchMetrics -Namespace "AWS/RDS" -DimensionName "DBInstanceIdentifier" `
        -DimensionValue $db.DBInstanceId -Region $db.Region

    $attributes = @(
        @{ Name = "AWS_Type";               Value = "RDS Instance" }
        @{ Name = "AWS_DBInstanceId";       Value = "$($db.DBInstanceId)" }
        @{ Name = "AWS_Engine";             Value = "$($db.Engine)" }
        @{ Name = "AWS_EngineVersion";      Value = "$($db.EngineVersion)" }
        @{ Name = "AWS_DBInstanceClass";    Value = "$($db.DBInstanceClass)" }
        @{ Name = "AWS_Status";             Value = "$($db.Status)" }
        @{ Name = "AWS_Endpoint";           Value = "$($db.Endpoint)" }
        @{ Name = "AWS_Port";               Value = "$($db.Port)" }
        @{ Name = "AWS_Region";             Value = "$($db.Region)" }
        @{ Name = "AWS_AvailabilityZone";   Value = "$($db.AvailabilityZone)" }
        @{ Name = "AWS_MultiAZ";            Value = "$($db.MultiAZ)" }
        @{ Name = "AWS_StorageType";        Value = "$($db.StorageType)" }
        @{ Name = "AWS_AllocatedStorageGB"; Value = "$($db.AllocatedStorageGB)" }
        @{ Name = "AWS_VpcId";              Value = "$($db.VpcId)" }
        @{ Name = "AWS_PubliclyAccessible"; Value = "$($db.PubliclyAccessible)" }
        @{ Name = "AWS_StorageEncrypted";   Value = "$($db.StorageEncrypted)" }
        @{ Name = "AWS_DBName";             Value = "$($db.DBName)" }
        @{ Name = "AWS_BackupRetention";    Value = "$($db.BackupRetention)" }
        @{ Name = "AWS_ARN";                Value = "$($db.ARN)" }
        @{ Name = "AWS_LastSync";           Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "AWS_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "RDS $($db.Engine) $($db.EngineVersion) | $($db.DBInstanceClass) | " +
            "$($db.Region) $($db.AvailabilityZone) | Storage: $($db.AllocatedStorageGB) GB $($db.StorageType) | " +
            "MultiAZ: $($db.MultiAZ) | Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $db.DBInstanceId `
        -DeviceAddress $ip `
        -Brand "AWS RDS" `
        -OS "$($db.Engine) $($db.EngineVersion)" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added RDS $($db.DBInstanceId) ($ip)" -ForegroundColor Green
        $added++
    }
}

# --- Load Balancers ---
Write-Host "`n=== Adding Load Balancers to WUG ===" -ForegroundColor Cyan
foreach ($lb in $allELB) {
    $ip = Resolve-AWSResourceIP -ResourceType ELB -Resource $lb

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping ELB $($lb.LoadBalancerName) - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored ELB $($lb.LoadBalancerName) ($ip)"
        $skipped++
        continue
    }

    # CloudWatch namespace varies by type
    $cwNamespace = switch ($lb.Type) {
        "application" { "AWS/ApplicationELB" }
        "network"     { "AWS/NetworkELB" }
        default       { "AWS/ELB" }
    }
    $metrics = Get-AWSCloudWatchMetrics -Namespace $cwNamespace -DimensionName "LoadBalancer" `
        -DimensionValue ($lb.ARN -split ':loadbalancer/' | Select-Object -Last 1) -Region $lb.Region

    $attributes = @(
        @{ Name = "AWS_Type";              Value = "Load Balancer" }
        @{ Name = "AWS_LoadBalancerName";  Value = "$($lb.LoadBalancerName)" }
        @{ Name = "AWS_LoadBalancerType";  Value = "$($lb.Type)" }
        @{ Name = "AWS_Scheme";            Value = "$($lb.Scheme)" }
        @{ Name = "AWS_State";             Value = "$($lb.State)" }
        @{ Name = "AWS_DNSName";           Value = "$($lb.DNSName)" }
        @{ Name = "AWS_Region";            Value = "$($lb.Region)" }
        @{ Name = "AWS_VpcId";             Value = "$($lb.VpcId)" }
        @{ Name = "AWS_AvailabilityZones"; Value = "$($lb.AvailabilityZones)" }
        @{ Name = "AWS_ARN";               Value = "$($lb.ARN)" }
        @{ Name = "AWS_LastSync";          Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    foreach ($m in $metrics) {
        $attributes += @{
            Name  = "AWS_Metric_$($m.MetricName)"
            Value = "$($m.LastValue) $($m.Unit)"
        }
    }

    $note = "$($lb.Type) LB $($lb.Scheme) | $($lb.Region) | " +
            "AZs: $($lb.AvailabilityZones) | VPC: $($lb.VpcId) | " +
            "Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $lb.LoadBalancerName `
        -DeviceAddress $ip `
        -Brand "AWS ELB" `
        -OS "$($lb.Type) Load Balancer" `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added ELB $($lb.LoadBalancerName) ($ip)" -ForegroundColor Green
        $added++
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Added:   $added"
Write-Host "  Skipped: $skipped"
Write-Host "  Total:   $($allEC2.Count + $allRDS.Count + $allELB.Count)"

# Cleanup
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDqe5HEV2Ecex+Q
# u0wzc24rgLnPOxKaeXVqtiUfvXosZ6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAjEierV7/ew7Xoh5zcl11d6jaCC0t+nqhGFj185QKsSTANBgkqhkiG9w0BAQEF
# AASCAgDX7uRFuFa3/RqEgOj9ssH46weg9fb1vUFAn5kV+8md0lvpCQ7Ga2iN5SWr
# XRP0QcKS5//vbxQkVUuTPXy8P62AkfD0SG0FaAgcxvNWAftrHOWBnSIzFBXtCZ7+
# de699maNv3q1LE7r55TpwrO3+7QSXw0JfEp1RRkf8ZqQa/xPTg6w1PYZBrBajvoH
# Hj1t8lZniXbgcfGGD5jQzPhD2LnIYxzqowFOAIb832h0cicQbhk8y+864ggDg1z4
# P5RFxCQBXeEkBMz02ZA6Ey2hx9hoizbXcw7h876If7TQRlmrE65nJUWM0DmQZqLF
# nP866EHLe9wieXicTeub/PKhiSbOb1lEw9VCow/YrIxBWGdLxv1WdxbGYQQjO8P1
# HqOM4/qdFBhbwd7z7K6PPNDmJCIlNkZTqzHaalW1sLWNqDOLFbKG436/kb3c45Ug
# zTpXU2l8E4JrOHLFmSz67Xe6QemTShd6k/2rDd/fdFmlYCzgU4ckgQL7peJvrjPd
# y28mw7weUjyzaucYxl7/1Rm/IKWvUge+/zE2MBn6L11zxh5MkrLm9X9oasVqbMRu
# ncZa7ZqxRAlRc6BRW97ADCYe5FTmC1zx0szwio1fkvou5JO6uNfCVVYJ5P976Iog
# +mYcrjU9bGDELm44wlhc2sBzXY8dnlLhDneBXq9w/l+NCxs07KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDAwMjdaMC8GCSqGSIb3DQEJBDEiBCA2h164
# lbaYyc0hf8KuXuMAKJxIBFBWeN+OZNFbO/R16DANBgkqhkiG9w0BAQEFAASCAgAa
# vGZ642/uIDSABNxX8U9s77gNysZ+VjY0zVRFHY9QHU48cZFA9JcAW/7+iS62zm6C
# DwRCNYroT+AZXaiyU2gNUAEgi6chvTCF2+jvCrfEnku1qsimKfpmb0WvOa99kbTD
# TdmVoW1ljH0BxB/ibUsJcUMeH3Y3ZVEuJa3Vff6uqIuHqOYF5UomJSYz/9fOeGR7
# K7FzxKI/DT7SGw5K0JtdlGmYch8jj1u5vx2Iys1rtM6O4l4n0ZmWWk57YK94mXrl
# cxGrKNKzksZQeIduy3s4j7dmjEJcZeEDrcjlTObbJKF+Kk3ijR5FfWxCcLBsUqT8
# QoLDF1dE181fn1M4vQXYkGgYEtUpVLezMpF3Tn4aJgA54BvhuPtWCdq8JdzaUSes
# Jdhpdbv0SjGnQO2Qej7hGi3JkCx9YqKVSg/7PVesJb92RVfX5gAABypjk8btuTum
# PUemHlF+o872c4yBgXK/zSTRZK1eaXv+ceQx6rFA52rw9iBzIFDC1Sy8iekgv/Wg
# JvHfl5xiAdaKQyoM9R2Hv7h5qlrLUrlEvevdXWVa6T/T8J4Uq87yZAH76dZtyCUQ
# 657nYpJgUXFKfOyuyM6u3ruGGFBQmVaZHA0o2DoedpE6SbFkIYWZlnBssAlipzXk
# Ujz1ymIDh74vDgQgUH2TnwxgQUAFlCgWINxuv2gjCg==
# SIG # End signature block
