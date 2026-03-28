<#
.SYNOPSIS
    AWS discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers an AWS discovery provider that discovers EC2 instances,
    RDS instances, and load balancers, then builds a monitor plan
    suitable for WhatsUp Gold or standalone use.

    Two collection methods:
      [1] AWS.Tools PowerShell modules (requires AWS.Tools.EC2, etc.)
      [2] REST API direct (zero external dependencies, SigV4 signing)

    The method is selected by the caller via Credential.UseRestApi = $true/$false.

    Discovery discovers:
      - EC2 instances (IP, State, Type, Platform, VPC)
      - RDS instances (Endpoint, State, Engine, Class)
      - Elastic Load Balancers (DNS, State, Type, VPC)

    Authentication:
      AWS IAM Access Key + Secret Key stored in DPAPI vault.
      Supports multi-region discovery.

    Prerequisites:
      Module mode: AWS.Tools PowerShell modules installed
      REST mode: No external dependencies (uses SigV4 signing + Invoke-RestMethod)

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM
#>

# Ensure DiscoveryHelpers is available
if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $discoveryPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'DiscoveryHelpers.ps1'
    if (Test-Path $discoveryPath) {
        . $discoveryPath
    }
    else {
        throw "DiscoveryHelpers.ps1 not found. Load it before this provider."
    }
}

# Ensure AWSHelpers is available
$awsHelpersPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..\aws\AWSHelpers.ps1'
if (Test-Path $awsHelpersPath) {
    . $awsHelpersPath
}

# ============================================================================
# AWS Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'AWS' `
    -MatchAttribute 'DiscoveryHelper.AWS' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()

        # --- Resolve credential ---
        $accessKey = $null
        $secretKey = $null
        $region    = 'us-east-1'

        if ($ctx.Credential) {
            if ($ctx.Credential.AccessKey) {
                $accessKey = $ctx.Credential.AccessKey
                $secretKey = $ctx.Credential.SecretKey
                if ($ctx.Credential.Region) { $region = $ctx.Credential.Region }
            }
            elseif ($ctx.Credential -is [PSCredential]) {
                # Convention: Username = AccessKey, Password = SecretKey
                $accessKey = $ctx.Credential.UserName
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ctx.Credential.Password)
                try { $secretKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
        }

        if (-not $accessKey -or -not $secretKey) {
            Write-Warning "No valid AWS credential available."
            return $items
        }

        # Determine collection method
        $useRest = $false
        if ($ctx.Credential -and $ctx.Credential.UseRestApi) {
            $useRest = $ctx.Credential.UseRestApi
        }

        # Parse region from target if provided
        $targets = if ($ctx.DeviceIP -is [System.Collections.IEnumerable] -and $ctx.DeviceIP -isnot [string]) {
            @($ctx.DeviceIP)
        } else {
            @($ctx.DeviceIP)
        }
        # Targets can be region names or 'all' to scan every enabled region
        $regions = @()
        $scanAll = $false
        foreach ($t in $targets) {
            if ($t -match '^[a-z]{2}-[a-z]+-\d+$') {
                $regions += $t
            }
            elseif ($t -eq 'all') {
                $scanAll = $true
            }
        }
        if ($regions.Count -eq 0 -and -not $scanAll) { $regions = @($region) }

        # ================================================================
        # Phase 1: Authenticate and enumerate resources
        # ================================================================
        $connectRegion = if ($regions.Count -gt 0) { $regions[0] } else { $region }
        try {
            if ($useRest) {
                Connect-AWSProfileREST -AccessKey $accessKey -SecretKey $secretKey -Region $connectRegion
            }
            else {
                Connect-AWSProfile -AccessKey $accessKey -SecretKey $secretKey -Region $connectRegion
            }
            Write-Verbose "Connected to AWS region ${connectRegion}$(if ($useRest) { ' (REST)' } else { ' (Module)' })"
        }
        catch {
            Write-Warning "Failed to connect to AWS: $_"
            return $items
        }

        # If scanning all regions, enumerate enabled regions now
        if ($scanAll) {
            Write-Verbose "Enumerating all enabled AWS regions..."
            try {
                $allRegions = if ($useRest) { Get-AWSRegionListREST } else { Get-AWSRegionList }
                $regions = @($allRegions | Select-Object -ExpandProperty RegionName | Sort-Object)
                Write-Verbose "Found $($regions.Count) enabled regions"
            }
            catch {
                Write-Warning "Could not enumerate regions: $_. Falling back to $connectRegion"
                $regions = @($connectRegion)
            }
        }

        $resourceMap = @{}  # uniqueKey -> @{ ... }

        foreach ($regionName in $regions) {
            Write-Verbose "Scanning region: $regionName"

            # EC2 Instances
            try {
                $ec2s = if ($useRest) { Get-AWSEC2InstancesREST -Region $regionName } else { Get-AWSEC2Instances -Region $regionName }
                foreach ($ec2 in $ec2s) {
                    $resKey = "ec2:${regionName}:$($ec2.InstanceId)"
                    $ip = $ec2.PublicIP
                    if (-not $ip -or $ip -eq 'N/A') { $ip = $ec2.PrivateIP }
                    if ($ip -eq 'N/A') { $ip = $null }

                    $resourceMap[$resKey] = @{
                        Name     = if ($ec2.Name -and $ec2.Name -ne 'N/A') { $ec2.Name } else { $ec2.InstanceId }
                        Type     = 'EC2'
                        State    = "$($ec2.State)"
                        IP       = $ip
                        PrivateIP= "$($ec2.PrivateIP)"
                        Region   = $regionName
                        AZ       = "$($ec2.AvailabilityZone)"
                        InstType = "$($ec2.InstanceType)"
                        Platform = "$($ec2.Platform)"
                        VpcId    = "$($ec2.VpcId)"
                        InstId   = "$($ec2.InstanceId)"
                    }
                }
            }
            catch { Write-Warning "Error enumerating EC2 in $regionName : $_" }

            # RDS Instances
            try {
                $rdss = if ($useRest) { Get-AWSRDSInstancesREST -Region $regionName } else { Get-AWSRDSInstances -Region $regionName }
                foreach ($rds in $rdss) {
                    $resKey = "rds:${regionName}:$($rds.DBInstanceIdentifier)"
                    $ip = $null
                    try {
                        if ($rds.Endpoint) {
                            $resolved = [System.Net.Dns]::GetHostAddresses($rds.Endpoint) | Select-Object -First 1
                            if ($resolved) { $ip = $resolved.IPAddressToString }
                        }
                    }
                    catch { }

                    $resourceMap[$resKey] = @{
                        Name     = "$($rds.DBInstanceIdentifier)"
                        Type     = 'RDS'
                        State    = "$($rds.DBInstanceStatus)"
                        IP       = $ip
                        PrivateIP= $null
                        Region   = $regionName
                        AZ       = "$($rds.AvailabilityZone)"
                        InstType = "$($rds.DBInstanceClass)"
                        Platform = "$($rds.Engine) $($rds.EngineVersion)"
                        VpcId    = "$($rds.VpcId)"
                        InstId   = "$($rds.DBInstanceIdentifier)"
                    }
                }
            }
            catch { Write-Warning "Error enumerating RDS in $regionName : $_" }

            # Load Balancers
            try {
                $elbs = if ($useRest) { Get-AWSLoadBalancersREST -Region $regionName } else { Get-AWSLoadBalancers -Region $regionName }
                foreach ($elb in $elbs) {
                    $resKey = "elb:${regionName}:$($elb.LoadBalancerName)"
                    $ip = $null
                    try {
                        if ($elb.DNSName) {
                            $resolved = [System.Net.Dns]::GetHostAddresses($elb.DNSName) | Select-Object -First 1
                            if ($resolved) { $ip = $resolved.IPAddressToString }
                        }
                    }
                    catch { }

                    $resourceMap[$resKey] = @{
                        Name     = "$($elb.LoadBalancerName)"
                        Type     = 'ELB'
                        State    = if ($elb.State) { "$($elb.State)" } else { 'active' }
                        IP       = $ip
                        PrivateIP= $null
                        Region   = $regionName
                        AZ       = ($elb.AvailabilityZones -join ', ')
                        InstType = "$($elb.Type)"
                        Platform = 'N/A'
                        VpcId    = "$($elb.VpcId)"
                        InstId   = "$($elb.LoadBalancerName)"
                    }
                }
            }
            catch { Write-Warning "Error enumerating ELB in $regionName : $_" }
        }

        Write-Verbose "Topology: $($resourceMap.Count) resources across $($regions.Count) region(s)"

        # ================================================================
        # Phase 2: Build discovery plan
        # ================================================================
        $baseAttrs = @{
            'DiscoveryHelper.AWS' = 'true'
            'DiscoveryHelper.AWS.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
        }

        foreach ($resKey in @($resourceMap.Keys | Sort-Object)) {
            $res = $resourceMap[$resKey]
            $resName = $res.Name

            $resAttrs = $baseAttrs.Clone()
            $resAttrs['AWS.DeviceType']    = $res.Type
            $resAttrs['AWS.ResourceName']  = $resName
            $resAttrs['AWS.InstanceId']    = $res.InstId
            $resAttrs['AWS.Region']        = $res.Region
            $resAttrs['AWS.AZ']            = $res.AZ
            $resAttrs['AWS.InstanceType']  = $res.InstType
            $resAttrs['AWS.State']         = $res.State
            $resAttrs['AWS.VpcId']         = $res.VpcId
            if ($res.IP) { $resAttrs['AWS.IPAddress'] = $res.IP }
            if ($res.PrivateIP) { $resAttrs['AWS.PrivateIP'] = $res.PrivateIP }
            if ($res.Platform) { $resAttrs['AWS.Platform'] = $res.Platform }

            $items += New-DiscoveredItem `
                -Name "AWS - $($res.Type) Status" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Monitors AWS $($res.Type) $resName state"
                } `
                -UniqueKey "AWS:$($res.Region):$($res.Type):${resName}:active:status" `
                -Attributes $resAttrs `
                -Tags @('aws', $res.Type, $resName, $res.Region)

            $items += New-DiscoveredItem `
                -Name "AWS - $($res.Type) Metrics" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "CloudWatch metrics for $resName"
                } `
                -UniqueKey "AWS:$($res.Region):$($res.Type):${resName}:perf:metrics" `
                -Attributes $resAttrs `
                -Tags @('aws', $res.Type, $resName, $res.Region)
        }

        return $items
    }

# ==============================================================================
# Export-AWSDiscoveryDashboardHtml
# ==============================================================================
function Export-AWSDiscoveryDashboardHtml {
    <#
    .SYNOPSIS
        Generates an AWS dashboard HTML file from resource data.
    .DESCRIPTION
        Reads the AWS dashboard template, injects column definitions
        and row data as JSON, and writes the final HTML to OutputPath.
    .PARAMETER DashboardData
        Array of PSCustomObject rows from Get-AWSDashboard.
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title shown in header and browser tab.
    .PARAMETER TemplatePath
        Path to AWS-Dashboard-Template.html.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'AWS Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot 'AWS-Dashboard-Template.html'
        if (-not (Test-Path $TemplatePath)) {
            $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'aws\AWS-Dashboard-Template.html'
        }
    }
    if (-not (Test-Path $TemplatePath)) {
        Write-Error "Template not found: $TemplatePath"
        return
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '(?<=[a-z])([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'State') { $col.formatter = 'formatState' }
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
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $parentDir = Split-Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Dashboard written to: $OutputPath"
    return $OutputPath
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAlBn/Rg3PraVPM
# 569tgfpgBHfWQP5y7CTxmPajxtDfE6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgO5wI6oMULolINnraTthtomRWeJJd9pH2
# iH0qAqUHQU4wDQYJKoZIhvcNAQEBBQAEggIAwONSTvEiRRXWsAVOxHntH6HSbC7u
# NFowS3MtTr6bTxhKtrt2t7ajmicRrx45IygtT8rj/43Zrbp43BOfL7/Ut60n3+2v
# u2H/tZYApnpQwENLiCAAKU5PNSuQ/HEA1ts2O1FsYKuU6YJElVi9Yr6Vr2SKyj+X
# bolqusDzjShjUE9FMktv+0acNED9FuMDmdt43NytXXT/OH1xibodCD7K1cMkDrF3
# v62dcq4TwBlEFwETvDbIUFjnSVe/vg3DKMjXFfNEYKJ1EufVEa8O8nbmq0qH9rMX
# /L+ebYcshHVbUqxMuIu6iu+v8YA/4VIutBd99URA5od47KrW5GZZm4kkU60ewNFa
# c4bIL6oEtdcWajZs049dnN8Gemo738n/eeSXVF7vyazC2KkINSl7LDdD7d/bxgIS
# 8Aliqi9j5WvcdhvzRHi4lxKTSr0i3VWqHqM9bEVrWeDoXzOSs78+N6o2PEixdfvw
# NruQbWVC/yVQRRAU9YYEQ9yuZathe9GHS1toIq7qpteffvukMib8Z2OG/dEREItQ
# LwaiBe34jkVaCcSY5xXNosWa8Z7ycAozHe4Yk0H04S7jkAmLqsRT4wG6h+n1iOLW
# N4PXMIDB0JSVkOElyPOdm6uyOMYpdWQeH7Dbu4DRjoeN8y29hbTdl1EY4bJnUiyu
# 2SPJn+6e8vxygrg=
# SIG # End signature block
