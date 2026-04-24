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
                        ARN      = "$($elb.ARN)"
                    }
                }
            }
            catch { Write-Warning "Error enumerating ELB in $regionName : $_" }
        }

        Write-Verbose "Topology: $($resourceMap.Count) resources across $($regions.Count) region(s)"

        # ================================================================
        # Phase 2: Build discovery plan
        # ================================================================

        # CloudWatch metrics per resource type
        $cwMetrics = @{
            'EC2' = @{
                Namespace = 'AWS/EC2'
                DimName   = 'InstanceId'
                Metrics   = @(
                    @{ Name = 'CPUUtilization';    Stat = 'Average' }
                    @{ Name = 'NetworkIn';         Stat = 'Average' }
                    @{ Name = 'NetworkOut';        Stat = 'Average' }
                    @{ Name = 'DiskReadOps';       Stat = 'Average' }
                    @{ Name = 'DiskWriteOps';      Stat = 'Average' }
                    @{ Name = 'StatusCheckFailed'; Stat = 'Maximum' }
                )
            }
            'RDS' = @{
                Namespace = 'AWS/RDS'
                DimName   = 'DBInstanceIdentifier'
                Metrics   = @(
                    @{ Name = 'CPUUtilization';      Stat = 'Average' }
                    @{ Name = 'FreeableMemory';      Stat = 'Average' }
                    @{ Name = 'DatabaseConnections'; Stat = 'Average' }
                    @{ Name = 'ReadIOPS';            Stat = 'Average' }
                    @{ Name = 'WriteIOPS';           Stat = 'Average' }
                    @{ Name = 'FreeStorageSpace';    Stat = 'Average' }
                )
            }
            'ELB' = @{
                Namespace = 'AWS/ApplicationELB'
                DimName   = 'LoadBalancer'
                Metrics   = @(
                    @{ Name = 'RequestCount';          Stat = 'Sum' }
                    @{ Name = 'TargetResponseTime';    Stat = 'Average' }
                    @{ Name = 'HealthyHostCount';      Stat = 'Average' }
                    @{ Name = 'UnHealthyHostCount';    Stat = 'Average' }
                    @{ Name = 'ActiveConnectionCount'; Stat = 'Sum' }
                    @{ Name = 'HTTPCode_ELB_5XX_Count';Stat = 'Sum' }
                )
            }
        }

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

            # --- Active Monitor: Ping (if IP available) ---
            if ($res.IP) {
                $items += New-DiscoveredItem `
                    -Name "AWS - Ping $resName" `
                    -ItemType 'ActiveMonitor' `
                    -MonitorType 'Ping' `
                    -MonitorParams @{
                        Description = "Ping monitor for AWS $($res.Type) $resName ($($res.IP))"
                    } `
                    -UniqueKey "AWS:$($res.Region):$($res.Type):${resName}:active:ping" `
                    -Attributes $resAttrs `
                    -Tags @('aws', $res.Type, $resName, $res.Region)
            }

            # --- Performance Monitors: CloudWatch (per metric) ---
            $cwDef = $cwMetrics[$res.Type]
            if ($cwDef) {
                # Determine dimension value
                $dimValue = $res.InstId
                if ($res.Type -eq 'ELB' -and $res.ARN) {
                    # CloudWatch expects the ARN suffix after :loadbalancer/
                    $arnParts = $res.ARN -split ':loadbalancer/'
                    if ($arnParts.Count -ge 2) {
                        $dimValue = $arnParts[1]
                    }
                }

                foreach ($metric in $cwDef.Metrics) {
                    $items += New-DiscoveredItem `
                        -Name "AWS - $resName - $($metric.Name)" `
                        -ItemType 'PerformanceMonitor' `
                        -MonitorType 'CloudWatch' `
                        -MonitorParams @{
                            CloudWatchNamespace  = $cwDef.Namespace
                            CloudWatchMetric     = $metric.Name
                            CloudWatchRegion     = $res.Region
                            CloudWatchStatistic  = $metric.Stat
                            CloudWatchDimensions = "$($cwDef.DimName)=$dimValue"
                        } `
                        -UniqueKey "AWS:$($res.Region):$($res.Type):${resName}:perf:$($metric.Name)" `
                        -Attributes $resAttrs `
                        -Tags @('aws', $res.Type, $resName, $res.Region, $metric.Name)
                }
            }
        }

        $accessKey = $null
        $secretKey = $null
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
    if ($firstObj) {
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
    } else {
        # Empty dataset - provide default AWS resource columns
        $defaultFields = @('ResourceType','Name','State','IPAddress','PrivateIP','Region','AvailabilityZone','InstanceType','Platform','VpcId','InstanceId')
        foreach ($f in $defaultFields) {
            $col = @{
                field      = $f
                title      = ($f -creplace '(?<=[a-z])([A-Z])', ' $1').Trim()
                sortable   = $true
                searchable = $true
            }
            if ($f -eq 'State') { $col.formatter = 'formatState' }
            $columns += $col
        }
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    if ($DashboardData -and $DashboardData.Count -gt 0) {
        $dataJson = ConvertTo-Json -InputObject @($DashboardData) -Depth 5 -Compress
    } else {
        $dataJson = '[]'
    }

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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAGuav87Zn4CGDC
# rt5dsRqPHWS4MZhxd1VmekQdfYu7yaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCTpoRmmzH6O/ApBfnbExgvULSmm4GE42i16e45rMl41jANBgkqhkiG9w0BAQEF
# AASCAgB3BnHxq+NVphd+cGuC0Su+i0Ep9p1/J1lfRgo8ytMew4272rIOAkEZ8z2X
# 25IfsS3EWUFgqqRqt0qoaC9brJXPhiD68drSJV/qt/SM5x2z+RDqX7qvBWLysFNA
# I0NU1dPwjUil7rPpCCee9VcozO5QI5T+j9EoTMIrkAexdoag3Oe1CdqT3TVH2x9a
# a/o21DiUE7ZbSPk16F5hZW+BaB/WdxYBocTs5IeOdITR1Yi4XBN96cN0L5uhRwB/
# WGocQQOXy3aCkPYxwkee2XqhkIbUH2Zlmg2WSOx1hcvJLlUwpw5CsyCtLAZNM0Wx
# sW/y+ioS0X+jUUC8dLg2oJPnPhw409zSZ06qFc8XLQZoA1rvjlOENnZh1HI16AUV
# sGVjSnyXdYAlrBWFfIJHuXAsHZmGT5oARwvNpsYMIlpW6+z55hpTnJyThQCAp4pu
# L+tkTbfqyJOxSAuDBnKjCMPdrPDHOKFolI9QivR+X36mKSSzAltE+0/6oEwGeFFR
# e1h9+SjunK8HiJcKK5nOvy3dwuSQjVRu6jpVoi1Xikwm9VGTsn7yC7W1Gz8s/E+S
# v0RYU3RUwJrIUVNNniBMGnHyxDTlKFHxi7hVxotijCAD5YxtnHT5L49RIWtavu4F
# 8t6h8yrJVf/IPXQ9xQ4vh0rSu4yXanC74XVYxNi8IxAlLL43v6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MTkyMTA1MTJaMC8GCSqGSIb3DQEJBDEiBCD0bBIK
# 9kFvLSdsC6r+SfpCkxGs0s4IWLI9wyXRIdkjpjANBgkqhkiG9w0BAQEFAASCAgA/
# 5g8Fj6xa/Fw7CMdXQXdYtZQRcuNiph//DdyUO883TaJjvoOR7K5HpNxBm4W93t79
# ejdJMzlOXICiqn8z3O+U88gb29jLdA2uec9XMn9u282JR/EnWbdlMSRCsOwydLBu
# cubYP9u41Zwf2Vn6KZ9kn4MlZo6A3VB3/pHfFylokwr1V0YkOkie+7PBM9RkIToU
# q8GMO1ft8pXChHm/xze2YUk5NnpGCM4LXfMNSMlUEeuTxj6nG/u6TdzWG1PT6S28
# oIhXjpJelBIkIUgBqBBBoYYLW1QEjO+ojpXGzqyT4e8SITZ0+n6dryADlqSYJOIA
# QO0Y5OqF45iC6JG00wDJfAPTov3MJHjTsJkNZnMD4vJbvVI0p3G9JD4xGXqZdsel
# FwvLDQnUPdPOSy9/w7krFp3grwXp0m60GPZtbpYjo3f9e7SK8W0ugsJ2SL0JPv3a
# ChIYOW9Rk8DHuyMvocMOFfsyrBmCy5nKdehqDos+eMAyU+GCMLc3/O4+OEHJYShT
# YFTccKD4Ubyw3x2HdbSkV51NNZ/oujk05Q1uSVE2uqPxHIyhMBngnvtBEPsYLjIA
# hSacW7VQDorzC/4IepK61hNgumftjrFrulFgbUfpLPeS8uEl3ShzKCla+Qp/sgSb
# tbhtSV1nAhrXmf7lyVTv5WgqbkW8NljuE2E+Cm3o7A==
# SIG # End signature block
