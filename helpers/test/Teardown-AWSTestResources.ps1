<#
.SYNOPSIS
    Tears down AWS test resources created by Setup-AWSTestResources.ps1.

.DESCRIPTION
    Finds and deletes all wug-test-* resources:
      ALB listener, ALB, target group, RDS instance, EC2 instance, security group.

    Uses the project's Invoke-AWSREST function (no AWS CLI required).
    Safe to re-run: ignores resources that don't exist.

    Note: RDS deletion takes a few minutes. The security group cannot be deleted
    until all ENIs (from ALB/RDS) are released. If the SG delete fails, re-run
    the script after a few minutes.

.PARAMETER Region
    AWS region. Default: us-east-1.
    Use 'all' to scan every enabled region and tear down any wug-test resources found.

.PARAMETER AccessKey
    AWS access key ID. If omitted, uses the vault credential.

.PARAMETER SecretKey
    AWS secret access key. If omitted, uses the vault credential.

.EXAMPLE
    .\Teardown-AWSTestResources.ps1

.EXAMPLE
    .\Teardown-AWSTestResources.ps1 -Region all

.EXAMPLE
    $cred = Get-Credential -Message 'AWS Access Key (user) + Secret Key (password)'
    .\Teardown-AWSTestResources.ps1 -Region us-west-2 -Credential $cred
#>
[CmdletBinding()]
param(
    [ValidateSet(
        'all',
        'us-east-1','us-east-2','us-west-1','us-west-2',
        'af-south-1',
        'ap-east-1','ap-south-1','ap-south-2','ap-southeast-1','ap-southeast-2','ap-southeast-3','ap-southeast-4','ap-southeast-5','ap-northeast-1','ap-northeast-2','ap-northeast-3',
        'ca-central-1','ca-west-1',
        'eu-central-1','eu-central-2','eu-west-1','eu-west-2','eu-west-3','eu-south-1','eu-south-2','eu-north-1',
        'il-central-1',
        'me-south-1','me-central-1',
        'sa-east-1',
        'mx-central-1'
    )]
    [string]$Region = 'us-east-1',
    [PSCredential]$Credential
)

$ErrorActionPreference = 'Continue'
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

$ErrorActionPreference = 'Stop'
$bstrSK = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrSK) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrSK) }

Connect-AWSProfileREST -AccessKey $Credential.UserName -SecretKey $plainSK -Region 'us-east-1'
$plainSK = $null
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------
# Resolve region list
# ---------------------------------------------------------------
if ($Region -eq 'all') {
    Write-Host "Scanning all enabled regions for wug-test resources..." -ForegroundColor Cyan
    $regionList = @((Get-AWSRegionListREST) | ForEach-Object { $_.RegionName })
    Write-Host "  $($regionList.Count) regions to check" -ForegroundColor DarkGray
} else {
    $regionList = @($Region)
}

$ec2Ver = '2016-11-15'
$rdsVer = '2014-10-31'
$elbVer = '2015-12-01'

$totalCleaned = 0

foreach ($curRegion in $regionList) {

# Quick check: any wug-test resources in this region?
if ($Region -eq 'all') {
    $hasEC2 = $false; $hasRDS = $false; $hasELB = $false
    try {
        $ec2Check = Invoke-AWSREST -Service ec2 -Action DescribeInstances -Version $ec2Ver -Region $curRegion -Parameters @{
            'Filter.1.Name' = 'tag:wug-test'; 'Filter.1.Value.1' = 'true'
            'Filter.2.Name' = 'instance-state-name'
            'Filter.2.Value.1' = 'pending'; 'Filter.2.Value.2' = 'running'
            'Filter.2.Value.3' = 'stopping'; 'Filter.2.Value.4' = 'stopped'
        }
        $hasEC2 = [bool]$ec2Check.DescribeInstancesResponse.reservationSet.item
    } catch {}
    try {
        $rdsCheck = Invoke-AWSREST -Service rds -Action DescribeDBInstances -Version $rdsVer -Region $curRegion -Parameters @{
            DBInstanceIdentifier = 'wug-test-rds'
        }
        $hasRDS = [bool]$rdsCheck.DescribeDBInstancesResponse.DescribeDBInstancesResult.DBInstances.DBInstance
    } catch {}
    try {
        $elbCheck = Invoke-AWSREST -Service elasticloadbalancing -Action DescribeLoadBalancers -Version $elbVer -Region $curRegion -Parameters @{
            'Names.member.1' = 'wug-test-alb'
        }
        $hasELB = [bool]$elbCheck.DescribeLoadBalancersResponse.DescribeLoadBalancersResult.LoadBalancers.member
    } catch {}
    if (-not $hasEC2 -and -not $hasRDS -and -not $hasELB) {
        continue   # nothing here, skip silently
    }
}

Write-Host ""
Write-Host "=== WUG AWS Test Resource Teardown ===" -ForegroundColor Cyan
Write-Host "Region: $curRegion" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------
# 1. Delete ALB listeners + ALB
# ---------------------------------------------------------------
Write-Host "Looking for ALB 'wug-test-alb'..." -ForegroundColor Yellow
try {
    $albResp = Invoke-AWSREST -Service elasticloadbalancing -Action DescribeLoadBalancers -Version $elbVer -Region $curRegion -Parameters @{
        'Names.member.1' = 'wug-test-alb'
    }
    $albArn = $albResp.DescribeLoadBalancersResponse.DescribeLoadBalancersResult.LoadBalancers.member.LoadBalancerArn
    if ($albArn) {
        # Delete listeners first
        try {
            $listResp = Invoke-AWSREST -Service elasticloadbalancing -Action DescribeListeners -Version $elbVer -Region $curRegion -Parameters @{
                LoadBalancerArn = $albArn
            }
            $listeners = @($listResp.DescribeListenersResponse.DescribeListenersResult.Listeners.member)
            foreach ($l in $listeners) {
                if (-not $l.ListenerArn) { continue }
                Write-Host "  Deleting listener..." -ForegroundColor DarkGray
                Invoke-AWSREST -Service elasticloadbalancing -Action DeleteListener -Version $elbVer -Region $curRegion -Method POST -Parameters @{
                    ListenerArn = $l.ListenerArn
                } | Out-Null
            }
        }
        catch { Write-Verbose "Listener cleanup: $_" }

        Write-Host "  Deleting ALB..." -ForegroundColor Yellow
        Invoke-AWSREST -Service elasticloadbalancing -Action DeleteLoadBalancer -Version $elbVer -Region $curRegion -Method POST -Parameters @{
            LoadBalancerArn = $albArn
        } | Out-Null
        Write-Host "  Deleted ALB" -ForegroundColor Green
    }
}
catch {
    if ("$_" -match 'LoadBalancerNotFound') {
        Write-Host "  ALB not found (already deleted)" -ForegroundColor DarkGray
    }
    else { Write-Warning "ALB delete: $_" }
}

# ---------------------------------------------------------------
# 2. Delete target group
# ---------------------------------------------------------------
Write-Host "Looking for target group 'wug-test-tg'..." -ForegroundColor Yellow
try {
    $tgResp = Invoke-AWSREST -Service elasticloadbalancing -Action DescribeTargetGroups -Version $elbVer -Region $curRegion -Parameters @{
        'Names.member.1' = 'wug-test-tg'
    }
    $tgArn = $tgResp.DescribeTargetGroupsResponse.DescribeTargetGroupsResult.TargetGroups.member.TargetGroupArn
    if ($tgArn) {
        Write-Host "  Deleting target group..." -ForegroundColor Yellow
        Invoke-AWSREST -Service elasticloadbalancing -Action DeleteTargetGroup -Version $elbVer -Region $curRegion -Method POST -Parameters @{
            TargetGroupArn = $tgArn
        } | Out-Null
        Write-Host "  Deleted target group" -ForegroundColor Green
    }
}
catch {
    if ("$_" -match 'TargetGroupNotFound') {
        Write-Host "  Target group not found (already deleted)" -ForegroundColor DarkGray
    }
    else { Write-Warning "Target group delete: $_" }
}

# ---------------------------------------------------------------
# 3. Delete RDS instance
# ---------------------------------------------------------------
Write-Host "Looking for RDS 'wug-test-rds'..." -ForegroundColor Yellow
try {
    Invoke-AWSREST -Service rds -Action DeleteDBInstance -Version $rdsVer -Region $curRegion -Method POST -Parameters @{
        DBInstanceIdentifier = 'wug-test-rds'
        SkipFinalSnapshot    = 'true'
        DeleteAutomatedBackups = 'true'
    } | Out-Null
    Write-Host "  RDS deletion initiated (takes a few minutes)" -ForegroundColor Green
}
catch {
    if ("$_" -match 'DBInstanceNotFound') {
        Write-Host "  RDS not found (already deleted)" -ForegroundColor DarkGray
    }
    elseif ("$_" -match 'InvalidDBInstanceState') {
        Write-Host "  RDS already deleting" -ForegroundColor Yellow
    }
    else { Write-Warning "RDS delete: $_" }
}

# ---------------------------------------------------------------
# 4. Terminate EC2 instances
# ---------------------------------------------------------------
Write-Host "Looking for EC2 instances tagged 'wug-test'..." -ForegroundColor Yellow
try {
    $ec2Resp = Invoke-AWSREST -Service ec2 -Action DescribeInstances -Version $ec2Ver -Region $curRegion -Parameters @{
        'Filter.1.Name'    = 'tag:wug-test'
        'Filter.1.Value.1' = 'true'
        'Filter.2.Name'    = 'instance-state-name'
        'Filter.2.Value.1' = 'pending'
        'Filter.2.Value.2' = 'running'
        'Filter.2.Value.3' = 'stopping'
        'Filter.2.Value.4' = 'stopped'
    }
    $reservations = @($ec2Resp.DescribeInstancesResponse.reservationSet.item)
    $terminated = 0
    foreach ($res in $reservations) {
        if (-not $res) { continue }
        $instances = @($res.instancesSet.item)
        foreach ($inst in $instances) {
            if (-not $inst.instanceId) { continue }
            Write-Host "  Terminating $($inst.instanceId)..." -ForegroundColor Yellow
            try {
                Invoke-AWSREST -Service ec2 -Action TerminateInstances -Version $ec2Ver -Region $curRegion -Method POST -Parameters @{
                    'InstanceId.1' = $inst.instanceId
                } | Out-Null
                $terminated++
                Write-Host "  Terminated $($inst.instanceId)" -ForegroundColor Green
            }
            catch { Write-Warning "Terminate $($inst.instanceId): $_" }
        }
    }
    if ($terminated -eq 0) {
        Write-Host "  No running test instances found" -ForegroundColor DarkGray
    }
}
catch { Write-Warning "EC2 search: $_" }

# ---------------------------------------------------------------
# 5. Delete security group (may fail if ENIs not yet released)
# ---------------------------------------------------------------
Write-Host "Looking for security group 'wug-test-sg'..." -ForegroundColor Yellow
try {
    $sgResp = Invoke-AWSREST -Service ec2 -Action DescribeSecurityGroups -Version $ec2Ver -Region $curRegion -Parameters @{
        'Filter.1.Name' = 'group-name'; 'Filter.1.Value.1' = 'wug-test-sg'
    }
    $sgs = @($sgResp.DescribeSecurityGroupsResponse.securityGroupInfo.item)
    foreach ($sg in $sgs) {
        if (-not $sg.groupId) { continue }
        Write-Host "  Deleting SG $($sg.groupId)..." -ForegroundColor Yellow
        try {
            Invoke-AWSREST -Service ec2 -Action DeleteSecurityGroup -Version $ec2Ver -Region $curRegion -Method POST -Parameters @{
                GroupId = $sg.groupId
            } | Out-Null
            Write-Host "  Deleted SG" -ForegroundColor Green
        }
        catch {
            if ("$_" -match 'DependencyViolation') {
                Write-Host "  SG still in use (ALB/RDS ENIs not released yet)" -ForegroundColor Yellow
                Write-Host "  Re-run this script in a few minutes to delete it." -ForegroundColor Yellow
            }
            else { Write-Warning "SG delete: $_" }
        }
    }
    if ($sgs.Count -eq 0 -or -not $sgs[0].groupId) {
        Write-Host "  SG not found (already deleted)" -ForegroundColor DarkGray
    }
}
catch { Write-Warning "SG search: $_" }

$totalCleaned++

Write-Host ""
Write-Host "=== Teardown Complete ($curRegion) ===" -ForegroundColor Cyan
Write-Host "  RDS deletion takes a few minutes to finish." -ForegroundColor DarkGray
Write-Host "  If the security group failed, re-run after ALB/RDS fully delete." -ForegroundColor DarkGray

}  # end foreach region

if ($Region -eq 'all') {
    Write-Host ""
    if ($totalCleaned -eq 0) {
        Write-Host "No wug-test resources found in any region. You're clean!" -ForegroundColor Green
    } else {
        Write-Host "Cleaned wug-test resources in $totalCleaned region(s)." -ForegroundColor Green
    }
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD2iTbmK3nUXwM5
# SvOaar9UOPT0ARdq8pH3pgzMdHMRg6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAj7cD3l0xW0NA2/Zdlr1Hq33Ik30I22ezDsLtuXvcT7jANBgkqhkiG9w0BAQEF
# AASCAgDrneBNmEOxGXn6AsXZrJ/xzg04hFmgKnvzu+21Y1Eg1ZejYbTcWznK5eKn
# 5URfnUTA2IZXCqM26kmVVaxxw/a3+xVazsXaANZsGwMw9obvU1iRPiGqWRWcXNt1
# EA1JgEwvVPyoSv4Ug/krFiuck4R1hcPumijMixdsNX4Lo/DQ4kzy2V3r0NlBe/yK
# +LFiuDfK6IlXYaghqka+7nABJMlMXJckUCT6YLqdeUqrIrHDKVMp6RoVMuiuOzYH
# LPWWd6lDPZ3VGcN5KpSldV3HNe+C8qaHWIkSV0tVdJZIixnIF6TSO37xlYaR7TYu
# eLAyh2mucwHb1pv30UdEGjKoRhNxXA6fylbdKkT0W+B4lDiHwbsC+Yaswzqusr6V
# W4Kc2X09SfcPW3gxmn+coHUNITTNefwjMckGbUkw7ha4Ytl8oVXBdoFx1Q8KFO3A
# kQnPxjxO4lVZdLa6g34CrjmQt2/nT4f+c/Qvp7OLYyXb2P+uKB6J3fbc885Nn1GR
# CEBFpb1CrhcxtKDW+x6a0lD2k5OvBcMI/f4/YdqYuOmgwWdA9AAkJwk1nK22Q64U
# Ti9Kjzw2uCyfEXI6/ufBein68wQ2tVjlu2JQYIyVUOEIJBf9QT+lbMPmtq2abRpK
# c1Zl0uoBUY1k+kz7l/EhTqMmhGRVCyY2M3O00hpx9gY05/B7NqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA1MjQxNzQyMDVaMC8GCSqGSIb3DQEJBDEiBCA2ENxD
# kIjlGirFI9nuj0UqSg2V73l/y+x3kkmNGf3RLTANBgkqhkiG9w0BAQEFAASCAgC9
# lXJkr1VQ15kVPeHQCVThfxkXA920zqI3ZVeKdXxMqsCSC52+Khfmp+n++VO0YwFJ
# pHiI5jsWP4egacYrIdydXqkiAxYze76mdRgUUAhHgmXfvxA1XjqTbtb+WlL6Je/g
# D4bW27yrLZWVWua4vgSxZz5WveKOoWQzdM9Vj8gT+gKc5PqEWRgYJPPyUx0n8Tae
# kiBr6sdRk8zv5iiDpfvvZSozQwaR7lCvg3ZEVqRljfkmd33JmudZ8/r/SZdicN2z
# eRNUiefKbbNRdWoFgAk7tH8u/Vz7rMr2RdDpoRjmePC1VKqKzZwseJyFMm9JsIBO
# 0YEEQ1el0lKD1bqNPoZr2pwcdcNC4Nue774NqwryMpVPATu9H7LNLlQXbwDoYm/p
# yAC0aOfypzVnRnW/s2qr/unN1Ach4EiWRlwShXRsMcul6Om/C+yx978Y+VOzQyfs
# mrqvtj0GmHMxMiE4DK2BTlqKw8m4HwoyJ8Urxm5aKhO5YieHhWQakGyzmXMAUckH
# +6MzAkG+chFqIRwvg3U4HH67jjP4qy5dvPVktWaXNa1EYZLyPo+ope9ENNFkuXHn
# Cl1mrM6RPoNYSwWuqAurSunUPj525ArRzLDaNjragZKfvnJAiXJvoaGKiYFbN98D
# Dv82uUnONDa9N/7IzwVt58COWf+d+TtKONcKXe8hJA==
# SIG # End signature block
