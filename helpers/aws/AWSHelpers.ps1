# =============================================================================
# AWS Helpers for WhatsUpGoldPS
#
# Two collection methods supported:
#   [1] AWS.Tools PowerShell modules (AWS.Tools.EC2, CloudWatch, RDS, etc.)
#   [2] Direct REST API calls (zero external dependencies -- uses SigV4 signing)
#
# Functions suffixed with "REST" use the AWS REST/Query API directly.
# Functions without the suffix use the AWS.Tools cmdlets.
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
    .EXAMPLE
        Connect-AWSProfile -AccessKey "AKIAIOSFODNN7EXAMPLE" -SecretKey "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" -Region "us-east-1"
        Authenticates to AWS using an IAM access key pair in the us-east-1 region.
    .EXAMPLE
        Connect-AWSProfile -ProfileName "MyStoredProfile" -Region "eu-west-1"
        Authenticates using a previously stored credential profile and sets the default region to eu-west-1.
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
    .EXAMPLE
        Get-AWSRegionList
        Returns all enabled AWS regions with their endpoint URLs.
    .EXAMPLE
        Get-AWSRegionList | Where-Object { $_.RegionName -like "us-*" }
        Returns only US-based AWS regions.
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
    .EXAMPLE
        Get-AWSEC2Instances
        Returns all EC2 instances in the default region.
    .EXAMPLE
        Get-AWSEC2Instances -Region "us-west-2"
        Returns all EC2 instances in the us-west-2 region.
    .EXAMPLE
        Get-AWSEC2Instances -Region "eu-west-1" | Where-Object { $_.State -eq "running" }
        Returns only running EC2 instances in the eu-west-1 region.
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
    .EXAMPLE
        Get-AWSRDSInstances
        Returns all RDS database instances in the default region.
    .EXAMPLE
        Get-AWSRDSInstances -Region "us-east-1"
        Returns all RDS instances in us-east-1 with endpoint, engine, and status details.
    .EXAMPLE
        Get-AWSRDSInstances | Where-Object { $_.Engine -eq "mysql" }
        Returns only MySQL RDS instances.
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
    .EXAMPLE
        Get-AWSLoadBalancers
        Returns all ALB and NLB load balancers in the default region.
    .EXAMPLE
        Get-AWSLoadBalancers -Region "us-west-2"
        Returns all load balancers in us-west-2 with DNS names, type, and state.
    .EXAMPLE
        Get-AWSLoadBalancers | Where-Object { $_.Type -eq "application" }
        Returns only Application Load Balancers.
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
    .EXAMPLE
        Get-AWSCloudWatchMetrics -Namespace "AWS/EC2" -DimensionName "InstanceId" -DimensionValue "i-0123456789abcdef0"
        Returns default EC2 metrics (CPUUtilization, NetworkIn, etc.) for the specified instance.
    .EXAMPLE
        Get-AWSCloudWatchMetrics -Namespace "AWS/RDS" -DimensionName "DBInstanceIdentifier" -DimensionValue "mydb" -Region "us-east-1"
        Returns default RDS metrics for the specified database in us-east-1.
    .EXAMPLE
        Get-AWSCloudWatchMetrics -Namespace "AWS/EC2" -DimensionName "InstanceId" -DimensionValue "i-0123456789abcdef0" -MetricNames @("CPUUtilization")
        Returns only the CPUUtilization metric for the specified EC2 instance.
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
    .EXAMPLE
        $instances = Get-AWSEC2Instances
        $ip = Resolve-AWSResourceIP -ResourceType "EC2" -Resource $instances[0]
        Resolves the IP address for the first EC2 instance (prefers public IP).
    .EXAMPLE
        $rds = Get-AWSRDSInstances
        Resolve-AWSResourceIP -ResourceType "RDS" -Resource $rds[0]
        Resolves the IP address for an RDS instance by performing DNS lookup on its endpoint.
    .EXAMPLE
        $elbs = Get-AWSLoadBalancers
        Resolve-AWSResourceIP -ResourceType "ELB" -Resource $elbs[0]
        Resolves the IP address for a load balancer by performing DNS lookup on its DNS name.
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

function Get-AWSDashboard {
    <#
    .SYNOPSIS
        Builds a unified dashboard view of AWS EC2, RDS, and ELB resources.
    .DESCRIPTION
        Queries each specified region for EC2 instances, RDS databases, and ELBv2
        load balancers then returns a flat collection suitable for Bootstrap Table
        display. Each row represents a resource with resolved IP addresses,
        instance type, platform, VPC, and monitoring status.
    .PARAMETER Regions
        Array of AWS region names to query (e.g. "us-east-1","eu-west-1").
        Defaults to the current default region if omitted.
    .PARAMETER IncludeRDS
        Include RDS instances in the results. Defaults to $true.
    .PARAMETER IncludeELB
        Include ELBv2 load balancers in the results. Defaults to $true.
    .EXAMPLE
        Get-AWSDashboard

        Returns all EC2, RDS, and ELB resources in the current default region.
    .EXAMPLE
        Get-AWSDashboard -Regions "us-east-1","us-west-2" -IncludeRDS $false

        Returns EC2 and ELB resources across two regions.
    .EXAMPLE
        Connect-AWSProfile -ProfileName "prod"
        $data = Get-AWSDashboard -Regions "us-east-1","eu-west-1"
        Export-AWSDashboardHtml -DashboardData $data -OutputPath "C:\Reports\aws.html"
        Start-Process "C:\Reports\aws.html"

        End-to-end: authenticate, gather data across regions, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains resource details: ResourceType, Name, State, IPAddress,
        PrivateIP, Region, AvailabilityZone, InstanceType, Platform, VpcId, DiskCount,
        LaunchTime, Monitoring, Tags.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, AWS.Tools PowerShell modules (AWS.Tools.EC2, AWS.Tools.RDS, AWS.Tools.ElasticLoadBalancingV2).
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [string[]]$Regions,
        [bool]$IncludeRDS = $true,
        [bool]$IncludeELB = $true
    )

    if (-not $Regions) { $Regions = @((Get-DefaultAWSRegion).Region) }

    $results = @()
    foreach ($region in $Regions) {
        # EC2
        try {
            $instances = Get-AWSEC2Instances -Region $region
            foreach ($inst in $instances) {
                $ip = Resolve-AWSResourceIP -ResourceType "EC2" -Resource $inst
                $results += [PSCustomObject]@{
                    ResourceType     = "EC2"
                    Name             = $inst.Name
                    State            = $inst.State
                    IPAddress        = if ($ip) { $ip } else { "N/A" }
                    PrivateIP        = $inst.PrivateIP
                    Region           = $inst.Region
                    AvailabilityZone = $inst.AvailabilityZone
                    InstanceType     = $inst.InstanceType
                    Platform         = $inst.Platform
                    VpcId            = $inst.VpcId
                    DiskCount        = $inst.DiskCount
                    LaunchTime       = $inst.LaunchTime
                    Monitoring       = $inst.Monitoring
                    Tags             = $inst.Tags
                }
            }
        }
        catch { Write-Warning "EC2 query failed for ${region}: $($_.Exception.Message)" }

        # RDS
        if ($IncludeRDS) {
            try {
                $rdsInstances = Get-AWSRDSInstances -Region $region
                foreach ($db in $rdsInstances) {
                    $ip = Resolve-AWSResourceIP -ResourceType "RDS" -Resource $db
                    $results += [PSCustomObject]@{
                        ResourceType     = "RDS"
                        Name             = $db.DBInstanceId
                        State            = $db.Status
                        IPAddress        = if ($ip) { $ip } else { "N/A" }
                        PrivateIP        = "N/A"
                        Region           = $db.Region
                        AvailabilityZone = $db.AvailabilityZone
                        InstanceType     = $db.DBInstanceClass
                        Platform         = "$($db.Engine) $($db.EngineVersion)"
                        VpcId            = $db.VpcId
                        DiskCount        = $db.AllocatedStorageGB
                        LaunchTime       = "N/A"
                        Monitoring       = "N/A"
                        Tags             = ""
                    }
                }
            }
            catch { Write-Warning "RDS query failed for ${region}: $($_.Exception.Message)" }
        }

        # ELB
        if ($IncludeELB) {
            try {
                $lbs = Get-AWSLoadBalancers -Region $region
                foreach ($lb in $lbs) {
                    $ip = Resolve-AWSResourceIP -ResourceType "ELB" -Resource $lb
                    $results += [PSCustomObject]@{
                        ResourceType     = "ELB"
                        Name             = $lb.LoadBalancerName
                        State            = $lb.State
                        IPAddress        = if ($ip) { $ip } else { "N/A" }
                        PrivateIP        = "N/A"
                        Region           = $lb.Region
                        AvailabilityZone = $lb.AvailabilityZones
                        InstanceType     = "$($lb.Type)/$($lb.Scheme)"
                        Platform         = "ELBv2"
                        VpcId            = $lb.VpcId
                        DiskCount        = "N/A"
                        LaunchTime       = "N/A"
                        Monitoring       = "N/A"
                        Tags             = ""
                    }
                }
            }
            catch { Write-Warning "ELB query failed for ${region}: $($_.Exception.Message)" }
        }
    }

    return $results
}

function Export-AWSDashboardHtml {
    <#
    .SYNOPSIS
        Renders AWS dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-AWSDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-AWSDashboard containing EC2, RDS, and ELB details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "AWS Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        AWS-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-AWSDashboard -Regions "us-east-1"
        Export-AWSDashboardHtml -DashboardData $data -OutputPath "C:\Reports\aws.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-AWSDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\aws.html" -ReportTitle "Production AWS"

        Exports with a custom report title.
    .EXAMPLE
        Connect-AWSProfile -ProfileName "prod"
        $data = Get-AWSDashboard -Regions "us-east-1"
        Export-AWSDashboardHtml -DashboardData $data -OutputPath "C:\Reports\aws.html"
        Start-Process "C:\Reports\aws.html"

        Full pipeline: authenticate, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, AWS-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "AWS Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "AWS-Dashboard-Template.html"
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
        if ($prop.Name -eq 'State') {
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
    Write-Verbose "AWS Dashboard HTML written to $OutputPath"
}

# =============================================================================
# REST API Collection Method (zero external dependencies)
# Uses AWS Query/REST API with SigV4 signing via Invoke-RestMethod
# =============================================================================

# Script-scoped credential cache for REST API calls
if (-not (Get-Variable -Name '_AWSRESTAccessKey' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:_AWSRESTAccessKey = $null
    $script:_AWSRESTSecretKey = $null
    $script:_AWSRESTRegion = $null
}

function _AWSHMACSHA256 {
    # Internal helper -- computes HMAC-SHA256
    param([byte[]]$Key, [string]$Message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $Key
    return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message))
}

function _AWSSigV4Sign {
    <#
    .SYNOPSIS
        Internal helper -- generates AWS SigV4 Authorization header components.
    .DESCRIPTION
        Implements the AWS Signature Version 4 signing process for REST API requests.
        Returns a hashtable with the required Authorization header and other headers.
    #>
    param(
        [string]$AccessKey,
        [string]$SecretKey,
        [string]$Region,
        [string]$Service,
        [string]$Method = 'GET',
        [string]$Uri,
        [string]$Body = '',
        [hashtable]$Headers = @{},
        [string]$ContentType = ''
    )

    $now = [DateTime]::UtcNow
    $dateStamp = $now.ToString('yyyyMMdd')
    $amzDate = $now.ToString('yyyyMMddTHHmmssZ')

    $parsedUri = [System.Uri]$Uri
    $canonicalUri = $parsedUri.AbsolutePath
    if (-not $canonicalUri) { $canonicalUri = '/' }
    $canonicalQuery = if ($parsedUri.Query) { $parsedUri.Query.TrimStart('?') } else { '' }
    # Sort query parameters
    if ($canonicalQuery) {
        $qparts = $canonicalQuery -split '&' | Sort-Object
        $canonicalQuery = $qparts -join '&'
    }

    $payloadHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Body)
        )
    ).Replace('-', '').ToLower()

    $allHeaders = @{
        'host'                 = $parsedUri.Host
        'x-amz-date'          = $amzDate
        'x-amz-content-sha256' = $payloadHash
    }
    if ($ContentType) { $allHeaders['content-type'] = $ContentType }
    foreach ($k in $Headers.Keys) { $allHeaders[$k.ToLower()] = $Headers[$k] }

    $sortedHeaderNames = $allHeaders.Keys | Sort-Object
    $canonicalHeaders = ($sortedHeaderNames | ForEach-Object { "$($_):$($allHeaders[$_])" }) -join "`n"
    $canonicalHeaders += "`n"
    $signedHeaders = ($sortedHeaderNames) -join ';'

    $canonicalRequest = @($Method, $canonicalUri, $canonicalQuery, $canonicalHeaders, $signedHeaders, $payloadHash) -join "`n"

    $credentialScope = "$dateStamp/$Region/$Service/aws4_request"
    $stringToSign = @(
        'AWS4-HMAC-SHA256'
        $amzDate
        $credentialScope
        [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($canonicalRequest)
            )
        ).Replace('-', '').ToLower()
    ) -join "`n"

    $kDate    = _AWSHMACSHA256 -Key ([System.Text.Encoding]::UTF8.GetBytes("AWS4$SecretKey")) -Message $dateStamp
    $kRegion  = _AWSHMACSHA256 -Key $kDate -Message $Region
    $kService = _AWSHMACSHA256 -Key $kRegion -Message $Service
    $kSigning = _AWSHMACSHA256 -Key $kService -Message 'aws4_request'

    $signature = [System.BitConverter]::ToString(
        (_AWSHMACSHA256 -Key $kSigning -Message $stringToSign)
    ).Replace('-', '').ToLower()

    $authHeader = "AWS4-HMAC-SHA256 Credential=$AccessKey/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"

    return @{
        Authorization          = $authHeader
        'x-amz-date'           = $amzDate
        'x-amz-content-sha256' = $payloadHash
        'host'                 = $parsedUri.Host
    }
}

function Invoke-AWSREST {
    <#
    .SYNOPSIS
        Internal helper -- calls an AWS REST/Query API endpoint with SigV4.
    .PARAMETER Service
        AWS service name (e.g., ec2, rds, elasticloadbalancing, monitoring).
    .PARAMETER Action
        The API action name.
    .PARAMETER Parameters
        Additional query parameters as a hashtable.
    .PARAMETER Region
        AWS region. Uses cached region if not specified.
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER Version
        API version string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Service,
        [string]$Action,
        [hashtable]$Parameters = @{},
        [string]$Region,
        [string]$Method = 'GET',
        [string]$Version
    )

    if (-not $script:_AWSRESTAccessKey) {
        throw "AWS REST credentials not set. Call Connect-AWSProfileREST first."
    }
    if (-not $Region) { $Region = $script:_AWSRESTRegion }

    $host_ = "$Service.$Region.amazonaws.com"
    $queryParams = @{}
    if ($Action) { $queryParams['Action'] = $Action }
    if ($Version) { $queryParams['Version'] = $Version }
    foreach ($k in $Parameters.Keys) { $queryParams[$k] = $Parameters[$k] }

    $queryString = ($queryParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$([uri]::EscapeDataString($_.Name))=$([uri]::EscapeDataString($_.Value))"
    }) -join '&'

    $uri = "https://${host_}/?${queryString}"

    $sigHeaders = _AWSSigV4Sign -AccessKey $script:_AWSRESTAccessKey `
        -SecretKey $script:_AWSRESTSecretKey `
        -Region $Region -Service $Service `
        -Method $Method -Uri $uri

    $reqHeaders = @{
        'Authorization'          = $sigHeaders.Authorization
        'x-amz-date'            = $sigHeaders.'x-amz-date'
        'x-amz-content-sha256'  = $sigHeaders.'x-amz-content-sha256'
    }

    $resp = Invoke-RestMethod -Uri $uri -Method $Method -Headers $reqHeaders -ErrorAction Stop
    return $resp
}

function Connect-AWSProfileREST {
    <#
    .SYNOPSIS
        Stores AWS credentials for REST API calls and validates connectivity.
    .PARAMETER AccessKey
        AWS IAM Access Key ID.
    .PARAMETER SecretKey
        AWS IAM Secret Access Key.
    .PARAMETER Region
        Default AWS region. Defaults to us-east-1.
    .EXAMPLE
        Connect-AWSProfileREST -AccessKey 'AKIA...' -SecretKey 'wJalr...' -Region 'us-east-1'
    #>
    param(
        [Parameter(Mandatory)][string]$AccessKey,
        [Parameter(Mandatory)][string]$SecretKey,
        [string]$Region = 'us-east-1'
    )

    $script:_AWSRESTAccessKey = $AccessKey
    $script:_AWSRESTSecretKey = $SecretKey
    $script:_AWSRESTRegion = $Region

    # Validate with a lightweight call
    try {
        $resp = Invoke-AWSREST -Service 'ec2' -Action 'DescribeRegions' -Version '2016-11-15' -Region $Region
        Write-Verbose "AWS REST authenticated. Found $(@($resp.DescribeRegionsResponse.regionInfo.item).Count) regions."
    }
    catch {
        $script:_AWSRESTAccessKey = $null
        $script:_AWSRESTSecretKey = $null
        throw "Failed to validate AWS credentials via REST: $($_.Exception.Message)"
    }
}

function Get-AWSRegionListREST {
    <#
    .SYNOPSIS
        Returns all AWS regions via REST API.
    .EXAMPLE
        Get-AWSRegionListREST
    #>

    $resp = Invoke-AWSREST -Service 'ec2' -Action 'DescribeRegions' -Version '2016-11-15'
    foreach ($r in $resp.DescribeRegionsResponse.regionInfo.item) {
        [PSCustomObject]@{
            RegionName = "$($r.regionName)"
            Endpoint   = "$($r.regionEndpoint)"
        }
    }
}

function Get-AWSEC2InstancesREST {
    <#
    .SYNOPSIS
        Returns all EC2 instances in a region via REST API.
    .PARAMETER Region
        AWS region to query.
    .EXAMPLE
        Get-AWSEC2InstancesREST -Region 'us-east-1'
    #>
    param([string]$Region)

    $params = @{}
    $resp = Invoke-AWSREST -Service 'ec2' -Action 'DescribeInstances' -Version '2016-11-15' -Region $Region -Parameters $params
    $reservations = $resp.DescribeInstancesResponse.reservationSet.item
    if (-not $reservations) { return @() }

    foreach ($res in @($reservations)) {
        foreach ($inst in @($res.instancesSet.item)) {
            $nameTag = ''
            $allTags = ''
            if ($inst.tagSet -and $inst.tagSet.item) {
                $tags = @($inst.tagSet.item)
                $nameObj = $tags | Where-Object { $_.key -eq 'Name' } | Select-Object -First 1
                if ($nameObj) { $nameTag = "$($nameObj.value)" }
                $allTags = ($tags | ForEach-Object { "$($_.key)=$($_.value)" }) -join '; '
            }
            $sgNames = ''; $sgIds = ''
            if ($inst.groupSet -and $inst.groupSet.item) {
                $sgs = @($inst.groupSet.item)
                $sgNames = ($sgs | ForEach-Object { $_.groupName }) -join ', '
                $sgIds = ($sgs | ForEach-Object { $_.groupId }) -join ', '
            }
            $diskCount = 0
            if ($inst.blockDeviceMapping -and $inst.blockDeviceMapping.item) {
                $diskCount = @($inst.blockDeviceMapping.item).Count
            }
            [PSCustomObject]@{
                InstanceId       = "$($inst.instanceId)"
                Name             = $nameTag
                InstanceType     = "$($inst.instanceType)"
                State            = "$($inst.instanceState.name)"
                Region           = if ($Region) { $Region } else { $script:_AWSRESTRegion }
                AvailabilityZone = "$($inst.placement.availabilityZone)"
                VpcId            = "$($inst.vpcId)"
                SubnetId         = "$($inst.subnetId)"
                PublicIP         = if ($inst.ipAddress) { "$($inst.ipAddress)" } else { '' }
                PrivateIP        = if ($inst.privateIpAddress) { "$($inst.privateIpAddress)" } else { '' }
                PublicDnsName    = "$($inst.dnsName)"
                PrivateDnsName   = "$($inst.privateDnsName)"
                Platform         = if ($inst.platformDetails) { "$($inst.platformDetails)" } else { if ($inst.platform) { "$($inst.platform)" } else { 'Linux/UNIX' } }
                Architecture     = "$($inst.architecture)"
                ImageId          = "$($inst.imageId)"
                KeyName          = "$($inst.keyName)"
                LaunchTime       = "$($inst.launchTime)"
                SecurityGroups   = $sgNames
                SecurityGroupIds = $sgIds
                DiskCount        = $diskCount
                RootDeviceType   = "$($inst.rootDeviceType)"
                Tags             = $allTags
                IAMRole          = if ($inst.iamInstanceProfile) { "$($inst.iamInstanceProfile.arn)" } else { '' }
                Monitoring       = "$($inst.monitoring.state)"
            }
        }
    }
}

function Get-AWSRDSInstancesREST {
    <#
    .SYNOPSIS
        Returns all RDS instances in a region via REST API.
    .PARAMETER Region
        AWS region to query.
    .EXAMPLE
        Get-AWSRDSInstancesREST -Region 'us-east-1'
    #>
    param([string]$Region)

    $resp = Invoke-AWSREST -Service 'rds' -Action 'DescribeDBInstances' -Version '2014-10-31' -Region $Region
    $instances = $resp.DescribeDBInstancesResponse.DescribeDBInstancesResult.DBInstances.DBInstance
    if (-not $instances) { return @() }

    foreach ($db in @($instances)) {
        [PSCustomObject]@{
            DBInstanceId       = "$($db.DBInstanceIdentifier)"
            Engine             = "$($db.Engine)"
            EngineVersion      = "$($db.EngineVersion)"
            DBInstanceClass    = "$($db.DBInstanceClass)"
            Status             = "$($db.DBInstanceStatus)"
            Endpoint           = if ($db.Endpoint -and $db.Endpoint.Address) { "$($db.Endpoint.Address)" } else { 'N/A' }
            Port               = if ($db.Endpoint -and $db.Endpoint.Port) { "$($db.Endpoint.Port)" } else { '' }
            Region             = if ($Region) { $Region } else { $script:_AWSRESTRegion }
            AvailabilityZone   = "$($db.AvailabilityZone)"
            MultiAZ            = "$($db.MultiAZ)"
            StorageType        = "$($db.StorageType)"
            AllocatedStorageGB = "$($db.AllocatedStorage)"
            VpcId              = if ($db.DBSubnetGroup -and $db.DBSubnetGroup.VpcId) { "$($db.DBSubnetGroup.VpcId)" } else { '' }
            PubliclyAccessible = "$($db.PubliclyAccessible)"
            StorageEncrypted   = "$($db.StorageEncrypted)"
            DBName             = "$($db.DBName)"
            MasterUsername     = "$($db.MasterUsername)"
            BackupRetention    = "$($db.BackupRetentionPeriod)"
            ARN                = "$($db.DBInstanceArn)"
        }
    }
}

function Get-AWSLoadBalancersREST {
    <#
    .SYNOPSIS
        Returns all ELBv2 load balancers in a region via REST API.
    .PARAMETER Region
        AWS region to query.
    .EXAMPLE
        Get-AWSLoadBalancersREST -Region 'us-east-1'
    #>
    param([string]$Region)

    $resp = Invoke-AWSREST -Service 'elasticloadbalancing' -Action 'DescribeLoadBalancers' -Version '2015-12-01' -Region $Region
    $lbs = $resp.DescribeLoadBalancersResponse.DescribeLoadBalancersResult.LoadBalancers.member
    if (-not $lbs) { return @() }

    foreach ($lb in @($lbs)) {
        $azList = ''
        if ($lb.AvailabilityZones -and $lb.AvailabilityZones.member) {
            $azList = (@($lb.AvailabilityZones.member) | ForEach-Object { $_.ZoneName }) -join ', '
        }
        [PSCustomObject]@{
            LoadBalancerName = "$($lb.LoadBalancerName)"
            Type             = "$($lb.Type)"
            Scheme           = "$($lb.Scheme)"
            State            = if ($lb.State) { "$($lb.State.Code)" } else { 'N/A' }
            DNSName          = "$($lb.DNSName)"
            Region           = if ($Region) { $Region } else { $script:_AWSRESTRegion }
            VpcId            = "$($lb.VpcId)"
            AvailabilityZones = $azList
            ARN              = "$($lb.LoadBalancerArn)"
        }
    }
}

function Get-AWSCloudWatchMetricsREST {
    <#
    .SYNOPSIS
        Returns CloudWatch metric statistics via REST API.
    .PARAMETER Namespace
        CloudWatch namespace (e.g., AWS/EC2, AWS/RDS).
    .PARAMETER DimensionName
        Dimension name (e.g., InstanceId, DBInstanceIdentifier).
    .PARAMETER DimensionValue
        Dimension value.
    .PARAMETER MetricNames
        Optional array of metric names to query.
    .PARAMETER Region
        AWS region.
    .EXAMPLE
        Get-AWSCloudWatchMetricsREST -Namespace 'AWS/EC2' -DimensionName 'InstanceId' -DimensionValue 'i-12345' -Region 'us-east-1'
    #>
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$DimensionName,
        [Parameter(Mandatory)][string]$DimensionValue,
        [string[]]$MetricNames,
        [string]$Region
    )

    $defaultMetrics = @{
        'AWS/EC2'             = @('CPUUtilization','NetworkIn','NetworkOut','DiskReadOps','DiskWriteOps','StatusCheckFailed')
        'AWS/RDS'             = @('CPUUtilization','FreeableMemory','ReadIOPS','WriteIOPS','DatabaseConnections','FreeStorageSpace')
        'AWS/ELB'             = @('RequestCount','HealthyHostCount','UnHealthyHostCount','Latency')
        'AWS/ApplicationELB'  = @('RequestCount','TargetResponseTime','HealthyHostCount','UnHealthyHostCount')
        'AWS/NetworkELB'      = @('ActiveFlowCount','NewFlowCount','ProcessedBytes','HealthyHostCount','UnHealthyHostCount')
    }

    if (-not $MetricNames) {
        $MetricNames = if ($defaultMetrics.ContainsKey($Namespace)) { $defaultMetrics[$Namespace] } else { @('CPUUtilization') }
    }

    $metrics = @()
    $endTime = [DateTime]::UtcNow
    $startTime = $endTime.AddHours(-1)

    foreach ($metricName in $MetricNames) {
        try {
            $params = @{
                'Namespace'                          = $Namespace
                'MetricName'                         = $metricName
                'StartTime'                          = $startTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                'EndTime'                            = $endTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                'Period'                             = '300'
                'Statistics.member.1'                = 'Average'
                'Dimensions.member.1.Name'           = $DimensionName
                'Dimensions.member.1.Value'          = $DimensionValue
            }

            $resp = Invoke-AWSREST -Service 'monitoring' -Action 'GetMetricStatistics' -Version '2010-08-01' -Region $Region -Parameters $params
            $datapoints = $resp.GetMetricStatisticsResponse.GetMetricStatisticsResult.Datapoints.member
            $lastValue = 'N/A'
            $unit = 'N/A'
            if ($datapoints) {
                $sorted = @($datapoints) | Sort-Object { [datetime]$_.Timestamp }
                $latest = $sorted | Select-Object -Last 1
                if ($latest.Average) {
                    $lastValue = "$([math]::Round([double]$latest.Average, 4))"
                }
                if ($latest.Unit) { $unit = "$($latest.Unit)" }
            }

            $metrics += [PSCustomObject]@{
                MetricName = $metricName
                Namespace  = $Namespace
                LastValue  = $lastValue
                Unit       = $unit
            }
        }
        catch {
            Write-Verbose "Could not retrieve CloudWatch metric $metricName via REST: $($_.Exception.Message)"
        }
    }

    return $metrics
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAW35JSUcCTAYWh
# LEkWaRauswvrCJAA4YAeD7yzpwTvJqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgKmaaYzq0TjNVeBPh84tcpyjsisKqmU4V
# q64QD81oHXMwDQYJKoZIhvcNAQEBBQAEggIAWonRpkJ/MVlGvPwwTctfo9SQYEn5
# eC+FPB7kE/uk414We9wzGiMlPp3j5zmHFWXnPm5Z8+w9qSkF555s03ULlzXQ9UUR
# 3vC8YDBu/LwxIOd0zqDubhHH6MLeRbpnDgbSNXeqCigO/oLvd8qQgwT2lPX4sW+n
# /NEkWMArUh2ToSWLLY7iRs6ZmTaL5kHVBRhDU8rPy1zR4oLkoQpK6jQHVZTSfwof
# oX44O/dmuJgA1QZ+w/hVN03XqyLDbsoWA+HLzCDTOrvI6z7cpwwdGJR9XJhbH3PS
# beXCtYZHa4QzaO8kP4a4ggKQ+2hQ1e2ZoId9VRTmR4WBSPEm/CYuCQ0xGBaJ2faH
# vCK2In8SU0ujMlVDC1cuLFDhAp2+dqmXOROf/LiMjvZJNM200dwLHwaGIUIh/HTw
# S84wURjDZtYH6fBWXehQRxBUkx+5CLlWWxtlEe7/a5ru0aJrDKIqHjRtZyVXQKoH
# m6eDLj0X6IqQYvGj+92PIWZJcFWPqttLCbpjX3IEPclHBvacddYWbhfN0DjLY9s7
# 008lh1DHM36avQxr6dVakeYXxodJIbrjL/SO+v9OdsdQgeVooCFdOS/F6N1qLps6
# tI264NL9qfsuz2YxCN+djYcMiFkvbFjZ23qGXiPIpQmiREzBIcjoMrfUGT/ObEwj
# Zc642mSaXA0y65I=
# SIG # End signature block
