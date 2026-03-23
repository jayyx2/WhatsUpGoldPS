<#
.SYNOPSIS
    Azure discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers an Azure discovery provider that discovers subscriptions,
    resource groups, and resources, then builds a monitor plan suitable
    for WhatsUp Gold or standalone use.

    Two collection methods supported:
      [1] Az PowerShell modules -- uses Az.Accounts, Az.Resources, etc.
      [2] REST API direct -- zero external dependencies (Invoke-RestMethod)

    The method is selected by the caller via Credential.UseRestApi = $true/$false.

    Discovery discovers:
      - Azure subscriptions and resource groups
      - Resources (VMs, SQL, App Services, etc.) with provisioning state
      - Resource IPs (public/private for VMs, DNS for services)

    Authentication:
      Service Principal (TenantId + ApplicationId + ClientSecret).
      Stored in DPAPI vault as encrypted bundle.

    Prerequisites:
      1. Service principal with Reader role on target subscriptions
      2. Azure AD app registration with client secret
      3. For Az module mode only:
         Install-Module -Name Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Monitor -Scope CurrentUser -Force

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 and AzureHelpers.ps1 loaded first
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

# Ensure AzureHelpers is available
$azureHelpersPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..\azure\AzureHelpers.ps1'
if (Test-Path $azureHelpersPath) {
    . $azureHelpersPath
}

# ============================================================================
# Azure Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'Azure' `
    -MatchAttribute 'DiscoveryHelper.Azure' `
    -AuthType 'BearerToken' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $false `
    -DiscoverScript {
        param($ctx)

        $items = @()

        # --- Resolve credential ---
        $tenantId = $null
        $appId    = $null
        $secret   = $null

        if ($ctx.Credential) {
            if ($ctx.Credential.TenantId) {
                $tenantId = $ctx.Credential.TenantId
                $appId    = $ctx.Credential.ApplicationId
                $secret   = $ctx.Credential.ClientSecret
            }
            elseif ($ctx.Credential -is [PSCredential]) {
                # Convention: Username = "TenantId|ApplicationId", Password = ClientSecret
                $parts = $ctx.Credential.UserName -split '\|'
                if ($parts.Count -ge 2) {
                    $tenantId = $parts[0]
                    $appId    = $parts[1]
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ctx.Credential.Password)
                    try { $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                }
            }
        }

        if (-not $tenantId -or -not $appId -or -not $secret) {
            Write-Warning "No valid Azure service principal credential available."
            return $items
        }

        # Determine collection method
        $useRest = $false
        if ($ctx.Credential -and $ctx.Credential.UseRestApi) {
            $useRest = $ctx.Credential.UseRestApi
        }

        # ================================================================
        # Phase 1: Authenticate and enumerate resources
        # ================================================================
        try {
            Write-Host "  Authenticating to Azure tenant $tenantId..." -ForegroundColor DarkGray
            if ($useRest) {
                Connect-AzureServicePrincipalREST -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret | Out-Null
            }
            else {
                Connect-AzureServicePrincipal -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret | Out-Null
            }
            Write-Host "  Authenticated." -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "Failed to authenticate to Azure: $_"
            return $items
        }

        $resourceMap = @{}  # resourceId -> @{ ... }

        try {
            Write-Host "  Listing subscriptions..." -ForegroundColor DarkGray
            if ($useRest) {
                $subscriptions = Get-AzureSubscriptionsREST | Where-Object { $_.State -eq 'Enabled' }
            }
            else {
                $subscriptions = Get-AzureSubscriptions | Where-Object { $_.State -eq 'Enabled' }
            }
            # If target specified, filter to specific subscriptions
            if ($ctx.DeviceIP -and $ctx.DeviceIP -ne $tenantId) {
                $targetSubs = @($ctx.DeviceIP -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($targetSubs.Count -gt 0 -and $targetSubs[0] -ne $tenantId) {
                    $subscriptions = $subscriptions | Where-Object {
                        $_.SubscriptionId -in $targetSubs -or $_.SubscriptionName -in $targetSubs
                    }
                }
            }
            Write-Host "  Subscriptions: $(@($subscriptions).Count)" -ForegroundColor DarkGray

            foreach ($sub in $subscriptions) {
                Write-Host "    Subscription: $($sub.SubscriptionName)" -ForegroundColor DarkGray
                if (-not $useRest) {
                    Set-AzContext -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue | Out-Null
                }

                try {
                    if ($useRest) {
                        $rgs = Get-AzureResourceGroupsREST -SubscriptionId $sub.SubscriptionId
                    }
                    else {
                        $rgs = Get-AzureResourceGroups
                    }
                }
                catch {
                    Write-Warning "Failed to list RGs for $($sub.SubscriptionName): $_"
                    continue
                }
                Write-Host "      Resource groups: $(@($rgs).Count)" -ForegroundColor DarkGray

                foreach ($rg in $rgs) {
                    try {
                        if ($useRest) {
                            $resources = Get-AzureResourcesREST -SubscriptionId $sub.SubscriptionId -ResourceGroupName $rg.ResourceGroupName
                        }
                        else {
                            $resources = Get-AzureResources -ResourceGroupName $rg.ResourceGroupName
                        }
                    }
                    catch {
                        Write-Warning "Failed to list resources in $($rg.ResourceGroupName): $_"
                        continue
                    }
                    if (@($resources).Count -gt 0) {
                        Write-Host "      $($rg.ResourceGroupName): $(@($resources).Count) resources" -ForegroundColor DarkGray
                    }

                    foreach ($r in $resources) {
                        $ip = $null
                        try {
                            if ($useRest) {
                                $ip = Resolve-AzureResourceIPREST -Resource $r -SubscriptionId $sub.SubscriptionId
                            }
                            else {
                                $ip = Resolve-AzureResourceIP -Resource $r
                            }
                        }
                        catch { }

                        $resourceMap[$r.ResourceId] = @{
                            Name         = $r.ResourceName
                            ResourceId   = $r.ResourceId
                            Type         = ($r.ResourceType -split '/')[-1]
                            FullType     = $r.ResourceType
                            State        = $r.ProvisioningState
                            IP           = $ip
                            Location     = $r.Location
                            Subscription = $sub.SubscriptionName
                            SubId        = $sub.SubscriptionId
                            RG           = $rg.ResourceGroupName
                            Kind         = $r.Kind
                            Sku          = $r.Sku
                            Tags         = if ($r.Tags) { $r.Tags } else { '' }
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "Error during Azure enumeration: $_"
        }

        Write-Host "  Total resources: $($resourceMap.Count)" -ForegroundColor DarkGray

        # ================================================================
        # Phase 2: Build discovery plan
        # ================================================================
        $baseAttrs = @{
            'Azure.TenantId' = $tenantId
            'DiscoveryHelper.Azure' = 'true'
            'DiscoveryHelper.Azure.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
        }

        foreach ($resId in @($resourceMap.Keys | Sort-Object)) {
            $res = $resourceMap[$resId]
            $resName = $res.Name

            $resAttrs = $baseAttrs.Clone()
            $resAttrs['Azure.DeviceType']    = $res.Type
            $resAttrs['Azure.ResourceName']  = $resName
            $resAttrs['Azure.ResourceType']  = $res.FullType
            $resAttrs['Azure.Location']      = $res.Location
            $resAttrs['Azure.Subscription']  = $res.Subscription
            $resAttrs['Azure.SubscriptionId']= $res.SubId
            $resAttrs['Azure.ResourceGroup'] = $res.RG
            $resAttrs['Azure.State']         = $res.State
            if ($res.IP) { $resAttrs['Azure.IPAddress'] = $res.IP }
            if ($res.Kind) { $resAttrs['Azure.Kind'] = $res.Kind }
            if ($res.Sku)  { $resAttrs['Azure.Sku']  = $res.Sku }
            if ($res.Tags) { $resAttrs['Azure.Tags'] = $res.Tags }

            # WUG Cloud Resource Monitor attributes
            $resAttrs['SYS:AzureResourceID'] = $resId
            $shortType = ($res.FullType -split '/')[-1]
            $resAttrs['SYS:CloudResourceID'] = "AzureRM/$($res.Location)/$shortType/$($res.SubId)/$resName"

            $items += New-DiscoveredItem `
                -Name "Azure - $($res.Type) Status" `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Monitors Azure $($res.Type) $resName state"
                } `
                -UniqueKey "Azure:$($res.SubId):${resName}:active:status" `
                -Attributes $resAttrs `
                -Tags @('azure', $res.Type, $resName, $res.Location)

            # Performance monitor for resources that support metrics
            $items += New-DiscoveredItem `
                -Name "Azure - $($res.Type) Metrics" `
                -ItemType 'PerformanceMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Azure Monitor metrics for $resName"
                } `
                -UniqueKey "Azure:$($res.SubId):${resName}:perf:metrics" `
                -Attributes $resAttrs `
                -Tags @('azure', $res.Type, $resName, $res.Location)
        }

        return $items
    }

# ==============================================================================
# Export-AzureDiscoveryDashboardHtml
# ==============================================================================
function Export-AzureDiscoveryDashboardHtml {
    <#
    .SYNOPSIS
        Generates an Azure dashboard HTML file from resource data.
    .DESCRIPTION
        Reads the Azure dashboard template, injects column definitions
        and row data as JSON, and writes the final HTML to OutputPath.
    .PARAMETER DashboardData
        Array of PSCustomObject rows from Get-AzureDashboard.
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title shown in header and browser tab.
    .PARAMETER TemplatePath
        Path to Azure-Dashboard-Template.html.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Azure Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'azure\\Azure-Dashboard-Template.html'
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
        if ($prop.Name -eq 'ProvisioningState') { $col.formatter = 'formatState' }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = ConvertTo-Json -InputObject @($DashboardData) -Depth 5 -Compress

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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBx3E/8RdXLiM0c
# FD4Ltc2M4AtmTocir/MfD7jZzWosnqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgSnLWcUjWbZaocO7d49BKnyQtBfaZkQFk
# mtfOwjqHOLQwDQYJKoZIhvcNAQEBBQAEggIA0ubnjtLM49Qup4IglCyM84HIEZ+m
# +K7yW3+xWcM8S1CrzrgqdDy3i58+Hq0kId/m/f9bwcIYTtB3EGnKi4BkGjgPdgjv
# h55qEiThfnbDqg6oZWhhvDMrFqk+Q98lNpcVEnG9i1rJMJxJHMOHToFvMJHtO/po
# JLwOMg6jNZY/gx3xcXlfRteHo8W6XEIik3aH6itFw2mkiWQlDk2ftn6Z5pkT1XnS
# N9EwmuQa69oJwceZDwJCLjGUc5IQReolTLvgrfiPuK34xskrTl098ZRwpLHwISZ7
# 0aM/VMeQ5omPkxVBiUN2mzkzwvL0beo2joKUiXbd7TmfdLD4QtWviMbnFiOXvtI2
# nNuGTAFGwRJfkUNOc+Qfj8JKZ8eQwBgvIUHESSzWng9goVGpJaWdnkohLmTFBbhs
# hrH8r5yzUwKrwcfhV2GNAa5EZ8811+qafvejNL/KVW5abFHnIs6dHvd4WPPXiARf
# TwbD0HD/R0lPGZC0w8OqANwG57uDj4OO8p5qXE41fdM9IY3fkHB/jeC7MOkW2tAg
# mmiEh1g9dfVxfysIP/r9EnAuUIrAlqciWyZfSUYc6JLF9GXe6rqrYyj1tQcCOpWv
# NoOw1nGuwgGJIQ8+I4lTZztP0dHlzZPySOlpRRsiRgk4sO1wxhMQ9v/EGehL6xBX
# uAcoaCarPcoO94s=
# SIG # End signature block
