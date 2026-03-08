# =============================================================================
# AWS Helpers for WhatsUpGoldPS
# Requires the AWS.Tools PowerShell modules. Install them first:
#   Install-Module -Name AWS.Tools.Installer -Scope CurrentUser -Force
#   Install-AWSToolsModule EC2, CloudWatch, RDS, ElasticLoadBalancingV2, S3, ECS, Lambda, ResourceGroupsTaggingAPI -CleanUp
# Or install individually:
#   Install-Module -Name AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.CloudWatch,
#       AWS.Tools.RDS, AWS.Tools.ElasticLoadBalancingV2,
#       AWS.Tools.ResourceGroupsTaggingAPI -Scope CurrentUser -Force
# =============================================================================

function Connect-AWSProfile {
    <#
    .SYNOPSIS
        Configures AWS credentials for the current session.
    .DESCRIPTION
        Sets up AWS credentials using an Access Key and Secret Key pair.
        Optionally sets the default region. Validates connectivity by
        calling Get-EC2Region.
    .PARAMETER AccessKey
        The AWS IAM access key ID.
    .PARAMETER SecretKey
        The AWS IAM secret access key.
    .PARAMETER Region
        The default AWS region (e.g. us-east-1). Defaults to us-east-1.
    .PARAMETER ProfileName
        Use a stored AWS credential profile instead of keys.
    #>
    param(
        [Parameter(ParameterSetName = "Keys", Mandatory)][string]$AccessKey,
        [Parameter(ParameterSetName = "Keys", Mandatory)][string]$SecretKey,
        [Parameter(ParameterSetName = "Profile", Mandatory)][string]$ProfileName,
        [string]$Region = "us-east-1"
    )

    if ($PSCmdlet.ParameterSetName -eq "Keys") {
        Set-AWSCredential -AccessKey $AccessKey -SecretKey $SecretKey -StoreAs "WhatsUpGoldPS_Session"
        Initialize-AWSDefaultConfiguration -ProfileName "WhatsUpGoldPS_Session" -Region $Region
    }
    else {
        Initialize-AWSDefaultConfiguration -ProfileName $ProfileName -Region $Region
    }

    # Validate connectivity
    try {
        Get-EC2Region -Region $Region -ErrorAction Stop | Out-Null
        Write-Verbose "Connected to AWS region $Region"
    }
    catch {
        throw "Failed to connect to AWS: $($_.Exception.Message)"
    }
}

function Get-AWSRegionList {
    <#
    .SYNOPSIS
        Returns all enabled AWS regions.
    .DESCRIPTION
        Wraps Get-EC2Region and returns a simplified collection.
    #>

    $regions = Get-EC2Region -ErrorAction Stop
    foreach ($r in $regions) {
        [PSCustomObject]@{
            RegionName = "$($r.RegionName)"
            Endpoint   = "$($r.Endpoint)"
        }
    }
}

function Get-AWSEC2Instances {
    <#
    .SYNOPSIS
        Returns all EC2 instances in the specified region.
    .DESCRIPTION
        Wraps Get-EC2Instance and returns a detailed collection of instance
        objects with key properties suitable for WUG device creation.
    .PARAMETER Region
        The AWS region to query. If omitted, uses the default region.
    #>
    param(
        [string]$Region
    )

    $splat = @{ ErrorAction = "Stop" }
    if ($Region) { $splat["Region"] = $Region }

    $reservations = Get-EC2Instance @splat
    foreach ($reservation in $reservations) {
        foreach ($inst in $reservation.Instances) {
            # Name tag
            $nameTag = ($inst.Tags | Where-Object { $_.Key -eq "Name" }).Value
            if (-not $nameTag) { $nameTag = $inst.InstanceId }

            # All tags as string
            $tagsStr = if ($inst.Tags) {
                ($inst.Tags | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
            } else { "" }

            # Security groups
            $sgNames = ($inst.SecurityGroups | ForEach-Object { $_.GroupName }) -join ", "
            $sgIds   = ($inst.SecurityGroups | ForEach-Object { $_.GroupId }) -join ", "

            # Block devices
            $diskCount = @($inst.BlockDeviceMappings).Count
            $rootDevice = "$($inst.RootDeviceType)"

            # Network
            $publicIP  = if ($inst.PublicIpAddress) { "$($inst.PublicIpAddress)" } else { "N/A" }
            $privateIP = if ($inst.PrivateIpAddress) { "$($inst.PrivateIpAddress)" } else { "N/A" }

            [PSCustomObject]@{
                InstanceId       = "$($inst.InstanceId)"
                Name             = $nameTag
                InstanceType     = "$($inst.InstanceType)"
                State            = "$($inst.State.Name)"
                Region           = if ($Region) { $Region } else { (Get-DefaultAWSRegion).Region }
                AvailabilityZone = "$($inst.Placement.AvailabilityZone)"
                VpcId            = "$($inst.VpcId)"
                SubnetId         = "$($inst.SubnetId)"
                PublicIP         = $publicIP
                PrivateIP        = $privateIP
                PublicDnsName    = if ($inst.PublicDnsName) { "$($inst.PublicDnsName)" } else { "N/A" }
                PrivateDnsName   = if ($inst.PrivateDnsName) { "$($inst.PrivateDnsName)" } else { "N/A" }
                Platform         = if ($inst.PlatformDetails) { "$($inst.PlatformDetails)" } else { "Linux/UNIX" }
                Architecture     = "$($inst.Architecture)"
                ImageId          = "$($inst.ImageId)"
                KeyName          = if ($inst.KeyName) { "$($inst.KeyName)" } else { "N/A" }
                LaunchTime       = "$($inst.LaunchTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                SecurityGroups   = $sgNames
                SecurityGroupIds = $sgIds
                DiskCount        = "$diskCount"
                RootDeviceType   = $rootDevice
                Tags             = $tagsStr
                IAMRole          = if ($inst.IamInstanceProfile) { "$($inst.IamInstanceProfile.Arn)" } else { "N/A" }
                Monitoring       = "$($inst.Monitoring.State)"
            }
        }
    }
}

function Get-AWSRDSInstances {
    <#
    .SYNOPSIS
        Returns all RDS database instances in the specified region.
    .PARAMETER Region
        The AWS region to query.
    #>
    param(
        [string]$Region
    )

    $splat = @{ ErrorAction = "Stop" }
    if ($Region) { $splat["Region"] = $Region }

    $instances = Get-RDSDBInstance @splat
    foreach ($db in $instances) {
        $endpoint = if ($db.Endpoint) { "$($db.Endpoint.Address)" } else { "N/A" }
        $port     = if ($db.Endpoint) { "$($db.Endpoint.Port)" } else { "N/A" }

        [PSCustomObject]@{
            DBInstanceId      = "$($db.DBInstanceIdentifier)"
            Engine            = "$($db.Engine)"
            EngineVersion     = "$($db.EngineVersion)"
            DBInstanceClass   = "$($db.DBInstanceClass)"
            Status            = "$($db.DBInstanceStatus)"
            Endpoint          = $endpoint
            Port              = $port
            Region            = if ($Region) { $Region } else { (Get-DefaultAWSRegion).Region }
            AvailabilityZone  = "$($db.AvailabilityZone)"
            MultiAZ           = "$($db.MultiAZ)"
            StorageType       = "$($db.StorageType)"
            AllocatedStorageGB = "$($db.AllocatedStorage)"
            VpcId             = if ($db.DBSubnetGroup) { "$($db.DBSubnetGroup.VpcId)" } else { "N/A" }
            PubliclyAccessible = "$($db.PubliclyAccessible)"
            StorageEncrypted  = "$($db.StorageEncrypted)"
            DBName            = if ($db.DBName) { "$($db.DBName)" } else { "N/A" }
            MasterUsername    = "$($db.MasterUsername)"
            BackupRetention   = "$($db.BackupRetentionPeriod)"
            ARN               = "$($db.DBInstanceArn)"
        }
    }
}

function Get-AWSLoadBalancers {
    <#
    .SYNOPSIS
        Returns all ELBv2 (ALB/NLB) load balancers in the specified region.
    .PARAMETER Region
        The AWS region to query.
    #>
    param(
        [string]$Region
    )

    $splat = @{ ErrorAction = "Stop" }
    if ($Region) { $splat["Region"] = $Region }

    $lbs = Get-ELB2LoadBalancer @splat
    foreach ($lb in $lbs) {
        $dnsName = if ($lb.DNSName) { "$($lb.DNSName)" } else { "N/A" }
        $azs = ($lb.AvailabilityZones | ForEach-Object { $_.ZoneName }) -join ", "

        [PSCustomObject]@{
            LoadBalancerName = "$($lb.LoadBalancerName)"
            Type             = "$($lb.Type)"
            Scheme           = "$($lb.Scheme)"
            State            = "$($lb.State.Code)"
            DNSName          = $dnsName
            Region           = if ($Region) { $Region } else { (Get-DefaultAWSRegion).Region }
            VpcId            = "$($lb.VpcId)"
            AvailabilityZones = $azs
            ARN              = "$($lb.LoadBalancerArn)"
        }
    }
}

function Get-AWSCloudWatchMetrics {
    <#
    .SYNOPSIS
        Returns recent CloudWatch metric data for an AWS resource.
    .DESCRIPTION
        Queries CloudWatch for the specified namespace/dimensions and returns
        the latest data points for common metrics.
    .PARAMETER Namespace
        The CloudWatch namespace (e.g. AWS/EC2, AWS/RDS).
    .PARAMETER DimensionName
        The dimension name (e.g. InstanceId, DBInstanceIdentifier).
    .PARAMETER DimensionValue
        The dimension value (the resource ID).
    .PARAMETER MetricNames
        Array of metric names to retrieve. If omitted, uses defaults per namespace.
    .PARAMETER Region
        The AWS region.
    #>
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$DimensionName,
        [Parameter(Mandatory)][string]$DimensionValue,
        [string[]]$MetricNames,
        [string]$Region
    )

    # Default metrics per namespace
    if (-not $MetricNames) {
        $MetricNames = switch ($Namespace) {
            "AWS/EC2" { @("CPUUtilization", "NetworkIn", "NetworkOut", "DiskReadOps", "DiskWriteOps",
                          "StatusCheckFailed", "StatusCheckFailed_Instance", "StatusCheckFailed_System") }
            "AWS/RDS" { @("CPUUtilization", "FreeableMemory", "ReadIOPS", "WriteIOPS",
                          "DatabaseConnections", "FreeStorageSpace") }
            "AWS/ELB" { @("RequestCount", "HealthyHostCount", "UnHealthyHostCount", "Latency") }
            "AWS/ApplicationELB" { @("RequestCount", "TargetResponseTime", "HealthyHostCount",
                                     "UnHealthyHostCount", "HTTPCode_ELB_5XX_Count") }
            "AWS/NetworkELB" { @("ActiveFlowCount", "NewFlowCount", "ProcessedBytes",
                                 "HealthyHostCount", "UnHealthyHostCount") }
            default { @() }
        }
    }

    $dimension = [Amazon.CloudWatch.Model.Dimension]::new()
    $dimension.Name  = $DimensionName
    $dimension.Value = $DimensionValue

    $splat = @{ ErrorAction = "Stop" }
    if ($Region) { $splat["Region"] = $Region }

    $results = @()
    foreach ($metricName in $MetricNames) {
        try {
            $data = Get-CWMetricStatistic `
                -Namespace $Namespace `
                -MetricName $metricName `
                -Dimension $dimension `
                -StartTime (Get-Date).AddHours(-1) `
                -EndTime (Get-Date) `
                -Period 300 `
                -Statistic "Average" `
                @splat

            $lastValue = "N/A"
            if ($data.Datapoints) {
                $latest = $data.Datapoints | Sort-Object Timestamp | Select-Object -Last 1
                if ($null -ne $latest.Average) {
                    $lastValue = "$([math]::Round($latest.Average, 4))"
                }
            }

            $results += [PSCustomObject]@{
                MetricName = $metricName
                Namespace  = $Namespace
                LastValue  = $lastValue
                Unit       = if ($data.Datapoints) { "$($data.Datapoints[0].Unit)" } else { "N/A" }
            }
        }
        catch {
            Write-Verbose "Could not retrieve $metricName from $Namespace : $($_.Exception.Message)"
        }
    }

    return $results
}

function Resolve-AWSResourceIP {
    <#
    .SYNOPSIS
        Resolves an IP address for an AWS resource.
    .DESCRIPTION
        For EC2 instances returns the public IP (preferred) or private IP.
        For RDS instances resolves the endpoint FQDN via DNS.
        For load balancers resolves the DNS name.
    .PARAMETER ResourceType
        The type of resource: EC2, RDS, or ELB.
    .PARAMETER Resource
        The resource object from the corresponding Get-AWS* function.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("EC2", "RDS", "ELB")][string]$ResourceType,
        [Parameter(Mandatory)]$Resource
    )

    $ip = $null

    switch ($ResourceType) {
        "EC2" {
            if ($Resource.PublicIP -and $Resource.PublicIP -ne "N/A") {
                $ip = $Resource.PublicIP
            }
            elseif ($Resource.PrivateIP -and $Resource.PrivateIP -ne "N/A") {
                $ip = $Resource.PrivateIP
            }
        }
        "RDS" {
            if ($Resource.Endpoint -and $Resource.Endpoint -ne "N/A") {
                try {
                    $resolved = [System.Net.Dns]::GetHostAddresses($Resource.Endpoint) | Select-Object -First 1
                    if ($resolved) { $ip = $resolved.IPAddressToString }
                }
                catch {
                    Write-Verbose "Could not resolve RDS endpoint $($Resource.Endpoint): $($_.Exception.Message)"
                }
            }
        }
        "ELB" {
            if ($Resource.DNSName -and $Resource.DNSName -ne "N/A") {
                try {
                    $resolved = [System.Net.Dns]::GetHostAddresses($Resource.DNSName) | Select-Object -First 1
                    if ($resolved) { $ip = $resolved.IPAddressToString }
                }
                catch {
                    Write-Verbose "Could not resolve ELB DNS $($Resource.DNSName): $($_.Exception.Message)"
                }
            }
        }
    }

    return $ip
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCASM52ClaxWFKH+
# 30sFw6NR6mAgEONirYq0cq0v4XfS+qCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgbnFroQ9ufqY2m3F31ovyHAEgW7yr0Xf8
# HsQtW8SThGcwDQYJKoZIhvcNAQEBBQAEggIALeFtPGfDh2ecVi+iPFjfwEczlczh
# JjZxfeVaHYQMppkxwaqHMqH93OLpjYjY5prl6bla//aIAgiGKSWdNPEcyPc/A56k
# 2kRu3jZ1J81MW8MXAoq185JQ6PzPmzlvCoxsCg+Ow5/KJWK4HVIe1q1OH5MlKes0
# CssPN5QqLPVxjxHZA1Mu14YUTn3e74iq0cHUnW/Wq7XpRyYut60UWh8f1RE7rcta
# Ia8LejZFY3iOQUEAgk9bfyecUYqjG4Piagiv9zx7KeUmrL6Dv0Qhm/T9IPRlli1R
# 5TiSt1anfAMZWrDltqt02U/8knKyWYxN6CwKf3ZEGmdAFAOv+kq00XvqEA2JUqRz
# YLpovK8D/RdhuMNP3Oxm8pSX5D/ZuN8KhXAZAgbUG2P5oqveMINiCwE7q5Ygvbom
# DnhWbUtdh6zsNwFYcrOgzjuA2qUArXdFadSYEkrsyi7D/Kll5M77MqnEyEFlwmi+
# TIvLo9k+wIFi92YjDVjurBb+MkVPVHf7zG0FDe0MdnYvZSH6+x2SxnT0OZ2fIEHH
# yQ8QfPWlog3GJfVHeeQ91bJoWdHDXvwCR6dkckeNpSNpzLi1AXah1o/1bXLPEqnm
# Po9Qo2z1JvNKkVbIm345it9ZX5TWj7v2hjgD94qPAbf1uk4tcdJmzuGE7lZ7WKAB
# UhXc9OHv6jLzGXI=
# SIG # End signature block
