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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCBksyV6ClZ3wyJ
# QFzWVr7XCSACqEQD1Q1+5A7uBtkcp6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgYOIz0zhcpdoF2aPl5Enz5RKHcf6woTEE
# 1ZO8COJrpukwDQYJKoZIhvcNAQEBBQAEggIAxr8TAk3xLmc/kRp7bwM32TmRs+gj
# u5RYP9uflYynxhOmh5QOS1weSqxBY5Zxh4l2VlXPcL0fafTKKw50EoCtgT8H7cmD
# lPNkqjb+aC6RovEJNLt59IRDuhihHBfsFLunFTOwoDX9JWHe6U02uwaLNW6agCDA
# 2UWj1xpJQuN4AxJ010Sm2lALZ1WBqMXrkIHHphfH6tXd+0qmm5M6ZY+UdTmbWPOU
# v9Kd2hJ8zXbs7q4mVXSLTHr60r2s7rpQeUD06EPO9n15wj8CpOhHTruqxA4Lm+xe
# 4NNIrb9sj5QwJnRzrfLPiLgC44pocV/QXQvul49DIoHKoJPbeqTDqGG7afm018Tf
# lutBPKK0S20Tl6ptqbGdHAfrLuADfoCksrZdDTsmMgJ1lkV+Xx3rerX0yfuHxfma
# ykRC+oDE1q+m0VQLmbbH5kH82/TLbpKqS88gCQuocRRn794r8KCne1+SEhmzPzrW
# iKO5/0qR0G7qedJsaYY7pOEwS+BcOQHR/HSnLa3JDEzx6RNyYIShhekOlN8Jc3tt
# dpFfp3W4r/sgyw30LcQSrwAqdz4zTNDOXakGqr7luhmlRriRh/h8ib3FNxI+iY0/
# ow9w8i5wAL3/hA7To5FdhO4ypl7rkUTqRTl7uDPwiV3edieySZYjTbr6yefbCRkT
# 2QlKX2mt2sBZNpo=
# SIG # End signature block
