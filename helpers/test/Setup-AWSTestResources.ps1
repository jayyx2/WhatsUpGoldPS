<#
.SYNOPSIS
    Creates minimal AWS test resources for WUG AWS discovery E2E testing.

.DESCRIPTION
    Creates one EC2 instance (t3.micro), one RDS instance (db.t3.micro MySQL),
    and one Application Load Balancer in the specified region.

    Uses the project's Invoke-AWSREST function (no AWS CLI required).
    Requires AWS credentials with EC2, RDS, ELBv2 write permissions.
    The default vault user (whatsupgold-test) is read-only; provide
    -Credential for a user with write access.

    Safe to re-run: handles duplicate resource errors gracefully.

.PARAMETER Region
    AWS region. Default: us-east-1

.PARAMETER Credential
    PSCredential where UserName = Access Key ID, Password = Secret Access Key.
    If omitted, uses the DPAPI-encrypted vault credential (AWS.Credential).

.EXAMPLE
    $cred = Get-Credential -Message 'AWS Access Key (user) + Secret Key (password)'
    .\Setup-AWSTestResources.ps1 -Credential $cred

.EXAMPLE
    .\Setup-AWSTestResources.ps1 -Region us-west-2

.NOTES
    Resources created (all tagged wug-test=true):
      EC2:  wug-test-ec2   (t3.micro, Amazon Linux 2023)
      RDS:  wug-test-rds   (db.t3.micro, MySQL 8)
      ALB:  wug-test-alb   (Application LB, HTTP:80)
      SG:   wug-test-sg    (ICMP + TCP 80 + TCP 3306)
      TG:   wug-test-tg    (HTTP target group -> EC2)

    Estimated cost: ~$0.05/hr total. Tear down after testing.
#>
[CmdletBinding()]
param(
    [string]$Region = 'us-east-1',
    [PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent

# Dot-source dependencies
$awsHelpersPath = Join-Path (Split-Path $scriptDir -Parent) 'aws\AWSHelpers.ps1'
. $awsHelpersPath
$discoveryHelpersPath = Join-Path (Split-Path $scriptDir -Parent) 'discovery\DiscoveryHelpers.ps1'
. $discoveryHelpersPath

# Resolve credentials from PSCredential or vault
if (-not $Credential) {
    try {
        $raw = Get-DiscoveryCredential -Name 'AWS.Credential'
        $parts = $raw -split '\|', 2
        $secSK = ConvertTo-SecureString $parts[1] -AsPlainText -Force
        $Credential = New-Object PSCredential($parts[0], $secSK)
        Write-Host "Using vault credential (AccessKey: $($Credential.UserName))" -ForegroundColor Cyan
    }
    catch {
        throw "No -Credential provided and vault credential not found: $_"
    }
}

$bstrSK = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrSK) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrSK) }

Connect-AWSProfileREST -AccessKey $Credential.UserName -SecretKey $plainSK -Region $Region
$plainSK = $null

$ec2Ver = '2016-11-15'
$rdsVer = '2014-10-31'
$elbVer = '2015-12-01'

Write-Host ""
Write-Host "=== WUG AWS Test Resource Setup ===" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------
# 1. Find default VPC
# ---------------------------------------------------------------
Write-Host "Finding default VPC..." -ForegroundColor Yellow
$vpcResp = Invoke-AWSREST -Service ec2 -Action DescribeVpcs -Version $ec2Ver -Region $Region -Parameters @{
    'Filter.1.Name' = 'is-default'; 'Filter.1.Value.1' = 'true'
}
$vpcs = @($vpcResp.DescribeVpcsResponse.vpcSet.item)
if ($vpcs.Count -eq 0) { throw "No default VPC in $Region. Create one first." }
$vpcId = $vpcs[0].vpcId
$vpcCidr = $vpcs[0].cidrBlock
Write-Host "  VPC: $vpcId ($vpcCidr)" -ForegroundColor Green

# ---------------------------------------------------------------
# 2. Get subnets (need 2 AZs for ALB)
# ---------------------------------------------------------------
Write-Host "Finding subnets..." -ForegroundColor Yellow
$subResp = Invoke-AWSREST -Service ec2 -Action DescribeSubnets -Version $ec2Ver -Region $Region -Parameters @{
    'Filter.1.Name' = 'vpc-id'; 'Filter.1.Value.1' = $vpcId
}
$allSubnets = @($subResp.DescribeSubnetsResponse.subnetSet.item)
$azGroups = $allSubnets | Group-Object availabilityZone | Select-Object -First 2
if ($azGroups.Count -lt 2) { throw "Need 2+ AZs for ALB, found $($azGroups.Count)." }
$subnet1 = $azGroups[0].Group[0].subnetId
$subnet2 = $azGroups[1].Group[0].subnetId
Write-Host "  Subnet 1: $subnet1 ($($azGroups[0].Name))" -ForegroundColor Green
Write-Host "  Subnet 2: $subnet2 ($($azGroups[1].Name))" -ForegroundColor Green

# ---------------------------------------------------------------
# 3. Create security group
# ---------------------------------------------------------------
Write-Host "Creating security group 'wug-test-sg'..." -ForegroundColor Yellow
$sgId = $null
try {
    $sgResp = Invoke-AWSREST -Service ec2 -Action CreateSecurityGroup -Version $ec2Ver -Region $Region -Method POST -Parameters @{
        GroupName        = 'wug-test-sg'
        GroupDescription = 'WUG discovery test resources'
        VpcId            = $vpcId
    }
    $sgId = $sgResp.CreateSecurityGroupResponse.groupId
    Write-Host "  Created SG: $sgId" -ForegroundColor Green
}
catch {
    if ("$_" -match 'InvalidGroup\.Duplicate') {
        $existSg = Invoke-AWSREST -Service ec2 -Action DescribeSecurityGroups -Version $ec2Ver -Region $Region -Parameters @{
            'Filter.1.Name' = 'group-name'; 'Filter.1.Value.1' = 'wug-test-sg'
            'Filter.2.Name' = 'vpc-id'; 'Filter.2.Value.1' = $vpcId
        }
        $sgId = $existSg.DescribeSecurityGroupsResponse.securityGroupInfo.item.groupId
        Write-Host "  SG already exists: $sgId" -ForegroundColor Yellow
    }
    else { throw }
}

# Add ingress rules (ICMP for ping, HTTP for ALB, MySQL for RDS - VPC only)
foreach ($rule in @(
    @{ Protocol = 'icmp'; From = '-1'; To = '-1'; Cidr = '0.0.0.0/0' },
    @{ Protocol = 'tcp';  From = '80'; To = '80'; Cidr = '0.0.0.0/0' },
    @{ Protocol = 'tcp';  From = '3306'; To = '3306'; Cidr = $vpcCidr }
)) {
    try {
        Invoke-AWSREST -Service ec2 -Action AuthorizeSecurityGroupIngress -Version $ec2Ver -Region $Region -Method POST -Parameters @{
            GroupId                            = $sgId
            'IpPermissions.1.IpProtocol'       = $rule.Protocol
            'IpPermissions.1.FromPort'         = $rule.From
            'IpPermissions.1.ToPort'           = $rule.To
            'IpPermissions.1.IpRanges.1.CidrIp' = $rule.Cidr
        } | Out-Null
    }
    catch {
        if ("$_" -match 'InvalidPermission\.Duplicate') { continue }
        Write-Warning "Ingress rule ($($rule.Protocol):$($rule.From)): $_"
    }
}

# ---------------------------------------------------------------
# 4. Find latest Amazon Linux 2023 AMI
# ---------------------------------------------------------------
Write-Host "Looking up latest Amazon Linux 2023 AMI..." -ForegroundColor Yellow
$amiResp = Invoke-AWSREST -Service ec2 -Action DescribeImages -Version $ec2Ver -Region $Region -Parameters @{
    'Owner.1'          = 'amazon'
    'Filter.1.Name'    = 'name';         'Filter.1.Value.1' = 'al2023-ami-2023*-kernel-6.1-x86_64'
    'Filter.2.Name'    = 'state';        'Filter.2.Value.1' = 'available'
    'Filter.3.Name'    = 'architecture'; 'Filter.3.Value.1' = 'x86_64'
}
$images = @($amiResp.DescribeImagesResponse.imagesSet.item)
if ($images.Count -eq 0) { throw "No Amazon Linux 2023 AMI found in $Region." }
$latest = $images | Sort-Object -Property creationDate -Descending | Select-Object -First 1
$amiId = $latest.imageId
Write-Host "  AMI: $amiId ($($latest.name))" -ForegroundColor Green

# ---------------------------------------------------------------
# 5. Launch EC2 instance
# ---------------------------------------------------------------
Write-Host "Launching EC2 instance (t3.micro)..." -ForegroundColor Yellow
$ec2Id = $null
try {
    $ec2Resp = Invoke-AWSREST -Service ec2 -Action RunInstances -Version $ec2Ver -Region $Region -Method POST -Parameters @{
        ImageId                              = $amiId
        InstanceType                         = 't3.micro'
        MinCount                             = '1'
        MaxCount                             = '1'
        'SecurityGroupId.1'                  = $sgId
        SubnetId                             = $subnet1
        'TagSpecification.1.ResourceType'    = 'instance'
        'TagSpecification.1.Tag.1.Key'       = 'Name'
        'TagSpecification.1.Tag.1.Value'     = 'wug-test-ec2'
        'TagSpecification.1.Tag.2.Key'       = 'wug-test'
        'TagSpecification.1.Tag.2.Value'     = 'true'
    }
    $ec2Id = $ec2Resp.RunInstancesResponse.instancesSet.item.instanceId
    Write-Host "  EC2: $ec2Id" -ForegroundColor Green
}
catch {
    Write-Warning "EC2 launch failed: $_"
    # Check if one already exists
    $existEc2 = Invoke-AWSREST -Service ec2 -Action DescribeInstances -Version $ec2Ver -Region $Region -Parameters @{
        'Filter.1.Name' = 'tag:Name'; 'Filter.1.Value.1' = 'wug-test-ec2'
        'Filter.2.Name' = 'instance-state-name'; 'Filter.2.Value.1' = 'running'
    }
    $existInst = $existEc2.DescribeInstancesResponse.reservationSet.item.instancesSet.item
    if ($existInst) {
        $ec2Id = $existInst.instanceId
        Write-Host "  EC2 already exists: $ec2Id" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------
# 6. Create RDS instance
# ---------------------------------------------------------------
Write-Host "Creating RDS instance (db.t3.micro, MySQL)..." -ForegroundColor Yellow
Write-Host "  This takes 5-10 minutes to become available." -ForegroundColor DarkGray
try {
    Invoke-AWSREST -Service rds -Action CreateDBInstance -Version $rdsVer -Region $Region -Method POST -Parameters @{
        DBInstanceIdentifier          = 'wug-test-rds'
        DBInstanceClass               = 'db.t3.micro'
        Engine                        = 'mysql'
        MasterUsername                 = 'admin'
        MasterUserPassword            = ('wugT' + [guid]::NewGuid().ToString('N').Substring(0,16))
        AllocatedStorage              = '20'
        'VpcSecurityGroupIds.member.1' = $sgId
        MultiAZ                       = 'false'
        'Tags.member.1.Key'           = 'wug-test'
        'Tags.member.1.Value'         = 'true'
    } | Out-Null
    Write-Host "  RDS: wug-test-rds (creating...)" -ForegroundColor Green
}
catch {
    if ("$_" -match 'DBInstanceAlreadyExists') {
        Write-Host "  RDS: wug-test-rds (already exists)" -ForegroundColor Yellow
    }
    else { throw }
}

# ---------------------------------------------------------------
# 7. Create Application Load Balancer
# ---------------------------------------------------------------
Write-Host "Creating ALB..." -ForegroundColor Yellow
$albArn = $null
$albDns = $null
try {
    $albResp = Invoke-AWSREST -Service elasticloadbalancing -Action CreateLoadBalancer -Version $elbVer -Region $Region -Method POST -Parameters @{
        Name                       = 'wug-test-alb'
        'Subnets.member.1'         = $subnet1
        'Subnets.member.2'         = $subnet2
        'SecurityGroups.member.1'  = $sgId
        Type                       = 'application'
        'Tags.member.1.Key'        = 'wug-test'
        'Tags.member.1.Value'      = 'true'
    }
    $albArn = $albResp.CreateLoadBalancerResponse.CreateLoadBalancerResult.LoadBalancers.member.LoadBalancerArn
    $albDns = $albResp.CreateLoadBalancerResponse.CreateLoadBalancerResult.LoadBalancers.member.DNSName
    Write-Host "  ALB: $albDns" -ForegroundColor Green
}
catch {
    if ("$_" -match 'DuplicateLoadBalancerName') {
        $existAlb = Invoke-AWSREST -Service elasticloadbalancing -Action DescribeLoadBalancers -Version $elbVer -Region $Region -Parameters @{
            'Names.member.1' = 'wug-test-alb'
        }
        $albArn = $existAlb.DescribeLoadBalancersResponse.DescribeLoadBalancersResult.LoadBalancers.member.LoadBalancerArn
        $albDns = $existAlb.DescribeLoadBalancersResponse.DescribeLoadBalancersResult.LoadBalancers.member.DNSName
        Write-Host "  ALB already exists: $albDns" -ForegroundColor Yellow
    }
    else { throw }
}

# ---------------------------------------------------------------
# 8. Create target group + listener
# ---------------------------------------------------------------
Write-Host "Creating target group + listener..." -ForegroundColor Yellow
$tgArn = $null
try {
    $tgResp = Invoke-AWSREST -Service elasticloadbalancing -Action CreateTargetGroup -Version $elbVer -Region $Region -Method POST -Parameters @{
        Name                    = 'wug-test-tg'
        Protocol                = 'HTTP'
        Port                    = '80'
        VpcId                   = $vpcId
        TargetType              = 'instance'
        'Tags.member.1.Key'     = 'wug-test'
        'Tags.member.1.Value'   = 'true'
    }
    $tgArn = $tgResp.CreateTargetGroupResponse.CreateTargetGroupResult.TargetGroups.member.TargetGroupArn
}
catch {
    if ("$_" -match 'DuplicateTargetGroupName') {
        $existTg = Invoke-AWSREST -Service elasticloadbalancing -Action DescribeTargetGroups -Version $elbVer -Region $Region -Parameters @{
            'Names.member.1' = 'wug-test-tg'
        }
        $tgArn = $existTg.DescribeTargetGroupsResponse.DescribeTargetGroupsResult.TargetGroups.member.TargetGroupArn
        Write-Host "  Target group already exists" -ForegroundColor Yellow
    }
    else { throw }
}

# Register EC2 in target group
if ($ec2Id -and $tgArn) {
    try {
        Invoke-AWSREST -Service elasticloadbalancing -Action RegisterTargets -Version $elbVer -Region $Region -Method POST -Parameters @{
            TargetGroupArn      = $tgArn
            'Targets.member.1.Id' = $ec2Id
        } | Out-Null
    }
    catch { Write-Verbose "Register target: $_" }
}

# Create listener
if ($albArn -and $tgArn) {
    try {
        Invoke-AWSREST -Service elasticloadbalancing -Action CreateListener -Version $elbVer -Region $Region -Method POST -Parameters @{
            LoadBalancerArn                          = $albArn
            Protocol                                 = 'HTTP'
            Port                                     = '80'
            'DefaultActions.member.1.Type'            = 'forward'
            'DefaultActions.member.1.TargetGroupArn'  = $tgArn
        } | Out-Null
        Write-Host "  Target group + listener created" -ForegroundColor Green
    }
    catch {
        if ("$_" -match 'DuplicateListener') {
            Write-Host "  Listener already exists" -ForegroundColor Yellow
        }
        else { Write-Warning "Listener: $_" }
    }
}

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== Test Resources Created ===" -ForegroundColor Cyan
Write-Host "  EC2 Instance:    $ec2Id" -ForegroundColor White
Write-Host "  RDS Instance:    wug-test-rds (allow 5-10 min)" -ForegroundColor White
Write-Host "  ALB:             wug-test-alb ($albDns)" -ForegroundColor White
Write-Host "  Security Group:  $sgId" -ForegroundColor White
Write-Host "  Region:          $Region" -ForegroundColor White
Write-Host ""
Write-Host "  After RDS is available, run the discovery:" -ForegroundColor Yellow
Write-Host "    .\helpers\discovery\Setup-AWS-Discovery.ps1 -Region $Region" -ForegroundColor White
Write-Host ""
Write-Host "  To tear down when done:" -ForegroundColor Yellow
Write-Host "    .\helpers\test\Teardown-AWSTestResources.ps1 -Region $Region" -ForegroundColor White
Write-Host "  (RDS password was randomly generated - not needed for teardown)" -ForegroundColor DarkGray

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBy2E84BQcq3zLW
# EtIqYW8EYX9j2vKhZdPDqDjctdu59KCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAKL4cbWHhv7hr7nfJzVf5uhDinuBjBSmCsaUKUkI10+zANBgkqhkiG9w0BAQEF
# AASCAgA+cixECE3MUdtar52X0yQUe2wKyyysu0Xk3jElTzfFM8uAInVq7rICEzLA
# 2BMf/ZIcL0GeCJEjNv1GUnehJPPo9AG3uRlk8H18iXq3PgafI8DpOyr3RGShlu7g
# 2xanj0Kfu9OOqskbBnyYFTidVFdO7gcmbZMoHZwtfS4Y3YNGCx6yRXM+3S4vwma4
# 4JxUG4uyc8q8xJtIKRjX3fMKOmO1BdEVeeBqemhcifWsoLArb6SK8JcphKjCt+Ut
# 7Cd8OawYSlE/t1nK7vyS1ei1ulvsDkAF+tFKl/VDamb6z8WWxvlZbAEABEZiINME
# KBvp8NVXygFg9FuXfRAvyIdI2Hdnl6q0wmZ0LiKXjEd7pSH5+b6fX9/JoQinf0JL
# NBt96uRzjAcNPLhUMK2dvn9QDM6QJG+GedQHKBUBN6Bwi9PEExbP+zRi+yvt/BTm
# YONTYS+f0sIwC9hez6pb1LtPuTvbFO4r+10r4cJZ/1bx2wx26Udt2kdiLs8IqpOR
# Rs2zPTCdY2Ew6IrRGZygC8gZ6SNfT83/l2r/BSOkxkkp8A+T2aPUZ/Df2IUEgt6a
# MOufpveuGHSSGTsVu62HtsZzHC/AgTuZi2QRkXJTjSnEXTVnDcHoUZO/uCNNTqpG
# phyryhypS9qDdPKvSGyZlmDlfqQzAuyMT4U1qup0YSTGhpnO2aGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDAwNDNaMC8GCSqGSIb3DQEJBDEiBCCbmEcT
# m4ybhD52KH4fiT3ShDFHETZYtUM/wg9lsEcrgDANBgkqhkiG9w0BAQEFAASCAgC+
# GUMYxpYJjZDL6O+gpm5k8uijA9A1nDUmTCuhmcYr82MZ+B/by/86DDqjOYEy/kSf
# 7+MTscTFj54fhcVeVqsQOpUU3flAjMjIC0e7EEFHjRnimdKddPc8EFcDf5o2UTU9
# VRLKrOg7VakX4k/a4d4RuXDSsSN+v9o6UFmfkSnJUn6cwowGklz4sDKLgaxeCpNF
# mM5eJXBpoRAxbhuplCFcXhqjPlPo9FT+IpqJaegnC3oBkO/R0RGUrCsztZgEZQr4
# o5RQ8xmjLCAibhOVAIcNc15FQvRGhwDf4g7YFxU9BuxGob1j/J/AxeIMw8hmKM56
# KP5fdGBhxdsMRkukhuKWX2r+bwMph2ZZDFh/FKt4DiXAriLzzK9Cf6fywhzOHeiE
# pidK3gQDGM4QAikhpQyJiwbjzwHgxp6qEV25ty7kbePUHiJh3hW40JDpw5zXhkhZ
# G3PTaseHUWda9VIB2Qq04+qsDkiTXi9xyCoFDLbpUFuMvi/xW44YZMyl/X+eqQiD
# gSqvejQWp1bj0E96+6Eau4w+MSnQnTC6CkIDsbVIN1wHF+FHOl0nl4zkWqvLOmKq
# eu+4PqRLXb34zIWOrdwNAT7+urx0V61UOchasirQJx3YZ6VV/YKxf7/LGogVw2fj
# a+xFNMdHWGjrKuQxe+ztGCOJJUijanBqE9xvaEMhGw==
# SIG # End signature block
