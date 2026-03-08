# Configuration
$TenantId      = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # Azure AD tenant ID
$ApplicationId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # App Registration (client) ID
$ClientSecret  = "your-client-secret-here"               # Client secret value
$WUGServer     = "192.168.1.250"

# Credentials
if (!$WUGCred) { $WUGCred = Get-Credential -Message "Enter credentials for WUG server" }

# Check if required modules are installed and loaded
if (-not (Get-Module -Name WhatsUpGoldPS)) { Import-Module WhatsUpGoldPS }

$requiredAzModules = @('Az.Accounts', 'Az.Resources', 'Az.Monitor', 'Az.Compute', 'Az.Network')
foreach ($mod in $requiredAzModules) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        throw "Required module '$mod' is not installed. Run: Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force"
    }
    if (-not (Get-Module -Name $mod)) { Import-Module $mod }
}

# Load helper functions
. "$PSScriptRoot\AzureHelpers.ps1"

# ========================
# Connect to Azure
# ========================
Write-Host "`n=== Connecting to Azure ===" -ForegroundColor Cyan
Connect-AzureServicePrincipal -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret

# ========================
# Enumerate Subscriptions
# ========================
Write-Host "`n=== Azure Subscriptions ===" -ForegroundColor Cyan
$subscriptions = Get-AzureSubscriptions
$subscriptions | Format-Table SubscriptionName, SubscriptionId, State -AutoSize

# ========================
# Gather All Resources
# ========================
$allResourceDetails = @()

foreach ($sub in $subscriptions) {
    if ($sub.State -ne "Enabled") {
        Write-Warning "Skipping disabled subscription: $($sub.SubscriptionName)"
        continue
    }

    Write-Host "`n=== Subscription: $($sub.SubscriptionName) ===" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.SubscriptionId | Out-Null

    $resourceGroups = Get-AzureResourceGroups
    Write-Host "  Found $($resourceGroups.Count) resource groups" -ForegroundColor Gray

    foreach ($rg in $resourceGroups) {
        Write-Host "  --- Resource Group: $($rg.ResourceGroupName) ($($rg.Location)) ---" -ForegroundColor Yellow
        $resources = Get-AzureResources -ResourceGroupName $rg.ResourceGroupName

        if ($resources.Count -eq 0) {
            Write-Host "    (empty)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "    Found $($resources.Count) resources" -ForegroundColor Gray

        foreach ($r in $resources) {
            Write-Host "    Processing: $($r.ResourceName) [$($r.ResourceType)]" -ForegroundColor DarkGray
            $detail = Get-AzureResourceDetail `
                -Resource $r `
                -SubscriptionName $sub.SubscriptionName `
                -SubscriptionId $sub.SubscriptionId `
                -ResourceGroupName $rg.ResourceGroupName `
                -IncludeMetrics $true

            $allResourceDetails += $detail
        }
    }
}

Write-Host "`n=== Resource Summary ===" -ForegroundColor Cyan
Write-Host "  Total resources discovered: $($allResourceDetails.Count)"
$allResourceDetails |
    Group-Object ResourceType |
    Sort-Object Count -Descending |
    Format-Table @{L="Resource Type"; E={$_.Name}}, Count -AutoSize

# ========================
# Add to WhatsUp Gold
# ========================
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

Write-Host "`n=== Adding Azure Resources to WUG ===" -ForegroundColor Cyan
$added = 0; $skipped = 0

foreach ($detail in $allResourceDetails) {
    # Resolve IP address for this resource
    $resourceObj = [PSCustomObject]@{
        ResourceId   = $detail.ResourceId
        ResourceType = $detail.ResourceType
        ResourceName = $detail.ResourceName
    }
    $ip = Resolve-AzureResourceIP -Resource $resourceObj

    if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Warning "Skipping $($detail.ResourceName) [$($detail.ResourceType)] - no resolvable IP"
        $skipped++
        continue
    }

    if (Get-WUGDevice -SearchValue $ip -View id) {
        Write-Warning "Skipping already monitored resource $($detail.ResourceName) ($ip)"
        $skipped++
        continue
    }

    # Build attributes
    $attributes = @(
        @{ Name = "Azure_Type";              Value = "Azure Resource" }
        @{ Name = "Azure_ResourceId";        Value = "$($detail.ResourceId)" }
        @{ Name = "Azure_ResourceType";      Value = "$($detail.ResourceType)" }
        @{ Name = "Azure_ResourceName";      Value = "$($detail.ResourceName)" }
        @{ Name = "Azure_Subscription";      Value = "$($detail.SubscriptionName)" }
        @{ Name = "Azure_SubscriptionId";    Value = "$($detail.SubscriptionId)" }
        @{ Name = "Azure_ResourceGroup";     Value = "$($detail.ResourceGroupName)" }
        @{ Name = "Azure_Location";          Value = "$($detail.Location)" }
        @{ Name = "Azure_Kind";              Value = "$($detail.Kind)" }
        @{ Name = "Azure_Sku";               Value = "$($detail.Sku)" }
        @{ Name = "Azure_ProvisioningState"; Value = "$($detail.ProvisioningState)" }
        @{ Name = "Azure_Tags";              Value = "$($detail.Tags)" }
        @{ Name = "Azure_MetricCount";       Value = "$($detail.MetricCount)" }
        @{ Name = "Azure_LastSync";          Value = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" }
    )

    # Add individual metric values as attributes (up to 20)
    if ($detail.Metrics) {
        foreach ($m in $detail.Metrics) {
            $safeMetricName = $m.MetricName -replace '[^a-zA-Z0-9_]', '_'
            $attributes += @{
                Name  = "Azure_Metric_$safeMetricName"
                Value = "$($m.LastValue) $($m.Unit)"
            }
        }
    }

    # Determine a friendly brand/type for WUG
    $brandName = switch -Wildcard ($detail.ResourceType) {
        "Microsoft.Compute/virtualMachines"    { "Azure VM" }
        "Microsoft.Sql/servers*"               { "Azure SQL" }
        "Microsoft.Web/sites"                  { "Azure App Service" }
        "Microsoft.Storage/storageAccounts"    { "Azure Storage" }
        "Microsoft.Network/*"                  { "Azure Networking" }
        "Microsoft.ContainerService/*"         { "Azure AKS" }
        "Microsoft.KeyVault/*"                 { "Azure Key Vault" }
        "Microsoft.Cache/*"                    { "Azure Redis" }
        "Microsoft.ServiceBus/*"               { "Azure Service Bus" }
        "Microsoft.EventHub/*"                 { "Azure Event Hub" }
        default                                { "Azure Resource" }
    }

    $note = "Azure $($detail.ResourceType) | Sub: $($detail.SubscriptionName) | " +
            "RG: $($detail.ResourceGroupName) | Location: $($detail.Location) | " +
            "SKU: $($detail.Sku) | Metrics: $($detail.MetricCount) | " +
            "Added $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

    $newDeviceId = Add-WUGDeviceTemplate `
        -displayName $detail.ResourceName `
        -DeviceAddress $ip `
        -Brand $brandName `
        -OS $detail.ResourceType `
        -ActiveMonitors @("Ping") `
        -PerformanceMonitors @("CPU Utilization", "Memory Utilization", "Disk Utilization",
            "Interface Utilization", "Ping Latency and Availability") `
        -Attributes $attributes `
        -Note $note

    if ($newDeviceId) {
        Write-Host "  Added $($detail.ResourceName) ($ip) [$brandName]" -ForegroundColor Green
        $added++
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Added:   $added"
Write-Host "  Skipped: $skipped"
Write-Host "  Total:   $($allResourceDetails.Count)"

# Cleanup
if ($Global:WUGConnection) {
    Disconnect-WUGServer
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDl2LRRf+ZMlRCe
# xpaiLXK9Hd5+gwk5YxUYRBNi+ZOvcaCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgACp+3SsksbFf1bVI8hpKXyXs69Q/J77u
# wIERLm1AXAEwDQYJKoZIhvcNAQEBBQAEggIAGly55alC2hA6UnZ/ChAi61E3vU5J
# Gq+y6fYC3aVF7Q6m5ZTrlMx8Ge2seCuFAuXkzYq5oLm0XXLCRmNwusy2Hg+uGYd7
# FVMYElBDXeQno5OAUmFmenbgkK4B7D0AnxjZLMrraYPkKf5IPHBr9ljj7af2bN6P
# U7bSRR/8yy9dA2sgc203trIgbDQWoeIhu8V7GNiQwcsfYoiglPwA9GpcbTHD/9mn
# bFTPaVmGuD3UH2pLznt9izYh6qIkTTS5VTdpJGr7YaRQlyvv/8zwk5L+tSDCVXeT
# R98GhhbJ0YztlexbTh8vYUFkX6SOB6SsZgOVTCAXobKyL951bOKfaSDzfHt8NUaA
# 1Sg7Eurb6JdoRLGOFdLsg5jTgDs9TEbC2l0XJmNpu5I0qbdDiSISMPqXBRdVJLrQ
# 2idzfH8cBFJMy5Bu8fVGr9iMMvrZHG/baIVKBQBUP8C9/GwkapAwx0ph1ejIWZHw
# DbmVJBgSUqtz5v1JUihNfCW7bNMulZr7usHGMTys0aA172asP8VgbnN1K3nHFIE2
# CCOYWShiRbbDbRxjFGGrj18yVcBAHpZMWnUVlbzGMk/Rt1ZCnT3DqwQCdOFnFvE1
# iyFHwNiQAZp69xB+wQludBuCy9Sio3pGwk09bQz2FNnwlwuz5TXbv2ooXIWOheCc
# 9aWEl5jICOPuliI=
# SIG # End signature block
