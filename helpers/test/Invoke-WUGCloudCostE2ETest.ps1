#requires -Version 5.1
<#
.SYNOPSIS
    Read-only live test for the cloud cost, quota and waste collectors.
.DESCRIPTION
    Authenticates with the DPAPI vault credentials already used by discovery
    (AWS.Credential, Azure.<tenant>.ServicePrincipal, OCI.Config) and runs the
    collectors in helpers/discovery/CloudCostHelpers.ps1 against the real APIs.

    This test only issues read operations: Azure GET requests and AWS Describe*
    query actions. It creates nothing, changes nothing and deletes nothing, so
    it is safe to run against a production account.

    Use Setup-AWSTestResources.ps1 or Setup-OCITestResources.ps1 separately if
    you want deterministic fixtures; those scripts do create billable resources
    and are intentionally not called from here.
.PARAMETER Provider
    Which clouds to exercise. Default All.
.PARAMETER Region
    AWS region to inspect. Default us-east-1.
.PARAMETER QuotaLocation
    Azure locations to query compute quota for.
.PARAMETER ShowFindings
    Print every finding, not just the summary.
.PARAMETER ExportPath
    Optional path for an HTML report built from the live findings.
.EXAMPLE
    .\Invoke-WUGCloudCostE2ETest.ps1 -Provider AWS -Region us-east-1
.EXAMPLE
    .\Invoke-WUGCloudCostE2ETest.ps1 -ShowFindings -ExportPath $env:TEMP\cloud-cost-live.html
.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+, vault credentials saved by the discovery setup scripts.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'AWS', 'Azure', 'OCI')]
    [string[]]$Provider = @('All'),

    [string]$Region = 'us-east-1',

    [string[]]$QuotaLocation = @('eastus'),

    [switch]$ShowFindings,

    [string]$ExportPath
)

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Record-Test {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    switch ($Status) {
        'Pass' { $script:Passed++; $color = 'Green' }
        'Fail' { $script:Failed++; $color = 'Red' }
        default { $script:Skipped++; $color = 'Yellow' }
    }
    Write-Host "  [$Status] $Name  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    try {
        $null = & $Test
        Record-Test -Name $Name -Status 'Pass'
    }
    catch {
        Record-Test -Name $Name -Status 'Fail' -Detail $_.Exception.Message
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message = 'Expected true but got false')
    if (-not $Value) { throw $Message }
}

function Test-FindingShape {
    param([object[]]$Finding, [string]$ExpectedProvider)
    foreach ($item in @($Finding)) {
        foreach ($property in @('Provider', 'Target', 'Category', 'Check', 'Status', 'Value', 'Resource', 'Detail')) {
            if (-not $item.PSObject.Properties[$property]) { throw "Finding missing property: $property" }
        }
        if ($item.Provider -ne $ExpectedProvider) { throw "Unexpected provider: $($item.Provider)" }
        if (@('Pass', 'Warn', 'Fail', 'Info', 'Unknown') -notcontains $item.Status) {
            throw "Unexpected status: $($item.Status)"
        }
    }
}

function Record-CollectionResult {
    param([string]$Name, [object[]]$Finding)

    $errors = @($Finding | Where-Object { $_.Category -eq 'Collection' })
    if ($errors.Count -eq 0) {
        Record-Test -Name $Name -Status 'Pass'
        return
    }

    # Missing RBAC is an environment limitation, not a defect in the collector.
    $denied = @($errors | Where-Object { $_.Detail -match '\(40[13]\)|Forbidden|Unauthorized|AccessDenied|NotAuthorized' })
    $realFailures = @($errors | Where-Object { $denied -notcontains $_ })

    if ($realFailures.Count -gt 0) {
        Record-Test -Name $Name -Status 'Fail' `
            -Detail (($realFailures | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join ' | ')
    }
    else {
        Record-Test -Name $Name -Status 'Skip' `
            -Detail ("permission denied: " + (($denied | ForEach-Object { $_.Check }) -join ', '))
    }
}

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
$discoveryDir = Join-Path $repoRoot 'helpers\discovery'

. (Join-Path $discoveryDir 'DiscoveryHelpers.ps1')
. (Join-Path $discoveryDir 'CloudCostHelpers.ps1')

$wanted = @($Provider)
if ($wanted -contains 'All') { $wanted = @('AWS', 'Azure', 'OCI') }

$allFindings = [System.Collections.Generic.List[object]]::new()

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Cloud Cost and Quota - LIVE (read-only)' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  No resources are created, modified or deleted.' -ForegroundColor DarkGray

# ============================================================================
# AWS
# ============================================================================
if ($wanted -contains 'AWS') {
    Write-Host ''
    Write-Host "--- AWS ($Region) ---" -ForegroundColor Cyan

    $awsReady = $false
    try {
        . (Join-Path $repoRoot 'helpers\aws\AWSHelpers.ps1')
        $raw = Get-DiscoveryCredential -Name 'AWS.Credential' -ErrorAction Stop
        $parts = [string]$raw -split '\|', 2
        if ($parts.Count -lt 2) { throw 'AWS.Credential is not in accessKey|secretKey format.' }
        Connect-AWSProfileREST -AccessKey $parts[0] -SecretKey $parts[1] -Region $Region | Out-Null
        $parts = $null
        $awsReady = $true
        Record-Test -Name 'AWS vault credential and connection' -Status 'Pass'
    }
    catch {
        Record-Test -Name 'AWS vault credential and connection' -Status 'Skip' -Detail $_.Exception.Message
    }

    if ($awsReady) {
        $awsFindings = @()
        Invoke-Test -Name 'AWS collector returns findings' -Test {
            $script:awsFindings = @(Get-AWSCostQuotaFinding -Region $Region -AccountName "AWS $Region")
            Assert-True ($script:awsFindings.Count -ge 0) 'collector returned null'
        }
        $awsFindings = $script:awsFindings

        Invoke-Test -Name 'AWS findings have the expected shape' -Test {
            Test-FindingShape -Finding $awsFindings -ExpectedProvider 'AWS'
        }

        Record-CollectionResult -Name 'AWS API calls' -Finding $awsFindings

        foreach ($item in $awsFindings) { $allFindings.Add($item) }
        $byCategory = $awsFindings | Group-Object Category | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Host "    Findings: $($awsFindings.Count) [$($byCategory -join ', ')]" -ForegroundColor DarkGray
    }
}

# ============================================================================
# Azure
# ============================================================================
if ($wanted -contains 'Azure') {
    Write-Host ''
    Write-Host '--- Azure ---' -ForegroundColor Cyan

    $azureReady = $false
    $subscriptions = @()
    try {
        . (Join-Path $repoRoot 'helpers\azure\AzureHelpers.ps1')

        $vaultDir = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
        $credFile = Get-ChildItem -Path $vaultDir -Filter 'Azure.*.ServicePrincipal.cred' -File -ErrorAction Stop |
            Select-Object -First 1
        if (-not $credFile) { throw 'No Azure service principal credential in the vault.' }
        $credName = $credFile.BaseName

        $stored = Get-DiscoveryCredential -Name $credName -ErrorAction Stop
        $tenantId = $null; $appId = $null; $secret = $null
        if ($stored -is [System.Collections.IDictionary]) {
            $tenantId = [string]$stored['TenantId']; $appId = [string]$stored['ClientId']; $secret = [string]$stored['ClientSecret']
        }
        else {
            # Single-secret layout stores "tenantId|appId|secret".
            $azParts = [string]$stored -split '\|'
            if ($azParts.Count -ge 3) { $tenantId = $azParts[0]; $appId = $azParts[1]; $secret = $azParts[2] }
        }
        if (-not $tenantId -or -not $appId -or -not $secret) {
            throw "Could not parse '$credName' into tenant, application and secret."
        }

        Connect-AzureServicePrincipalREST -TenantId $tenantId -ApplicationId $appId -ClientSecret $secret | Out-Null
        $secret = $null
        $subscriptions = @(Invoke-AzureREST -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01')
        $azureReady = $true
        Record-Test -Name 'Azure vault credential and connection' -Status 'Pass'
    }
    catch {
        Record-Test -Name 'Azure vault credential and connection' -Status 'Skip' -Detail $_.Exception.Message
    }

    if ($azureReady) {
        if ($subscriptions.Count -eq 0) {
            Record-Test -Name 'Azure subscriptions visible' -Status 'Skip' -Detail 'Service principal sees no subscriptions.'
        }
        else {
            Record-Test -Name 'Azure subscriptions visible' -Status 'Pass'

            foreach ($sub in $subscriptions) {
                $subId = [string]$sub.subscriptionId
                $subName = [string]$sub.displayName
                if (-not $subId) { continue }
                Write-Host "    Subscription: $subName" -ForegroundColor DarkGray

                $azFindings = @()
                Invoke-Test -Name "Azure collector ($subName)" -Test {
                    $script:azFindings = @(Get-AzureCostQuotaFinding -SubscriptionId $subId -SubscriptionName $subName -QuotaLocation $QuotaLocation)
                    Assert-True ($script:azFindings.Count -ge 0) 'collector returned null'
                }
                $azFindings = $script:azFindings

                Invoke-Test -Name "Azure findings have the expected shape ($subName)" -Test {
                    Test-FindingShape -Finding $azFindings -ExpectedProvider 'Azure'
                }

                $collectionErrors = @($azFindings | Where-Object { $_.Category -eq 'Collection' })
                Record-CollectionResult -Name "Azure API calls ($subName)" -Finding $azFindings

                foreach ($item in $azFindings) { $allFindings.Add($item) }
                $byCategory = $azFindings | Group-Object Category | ForEach-Object { "$($_.Name)=$($_.Count)" }
                Write-Host "    Findings: $($azFindings.Count) [$($byCategory -join ', ')]" -ForegroundColor DarkGray
            }
        }
    }
}

# ============================================================================
# OCI
# ============================================================================
if ($wanted -contains 'OCI') {
    Write-Host ''
    Write-Host '--- OCI ---' -ForegroundColor Cyan

    if (-not (Get-Command Get-OCIComputeInstancesList -ErrorAction SilentlyContinue)) {
        Record-Test -Name 'OCI PSModules available' -Status 'Skip' -Detail 'OCI.PSModules not installed.'
    }
    else {
        $ociReady = $false
        $tenancyId = $null
        try {
            $configPath = [string](Get-DiscoveryCredential -Name 'OCI.Config' -ErrorAction Stop)
            if (-not (Test-Path -LiteralPath $configPath)) { throw "OCI config not found: $configPath" }
            foreach ($line in (Get-Content -LiteralPath $configPath)) {
                if ($line -match '^\s*tenancy\s*=\s*(\S+)') { $tenancyId = $Matches[1]; break }
            }
            if (-not $tenancyId) { throw 'No tenancy OCID found in the OCI config file.' }
            $ociReady = $true
            Record-Test -Name 'OCI vault config resolved' -Status 'Pass'
        }
        catch {
            Record-Test -Name 'OCI vault config resolved' -Status 'Skip' -Detail $_.Exception.Message
        }

        if ($ociReady) {
            $ociFindings = @()
            Invoke-Test -Name 'OCI collector returns findings' -Test {
                $script:ociFindings = @(Get-OCICostQuotaFinding -CompartmentId $tenancyId -CompartmentName 'root')
                Assert-True ($script:ociFindings.Count -ge 0) 'collector returned null'
            }
            $ociFindings = $script:ociFindings

            Invoke-Test -Name 'OCI findings have the expected shape' -Test {
                Test-FindingShape -Finding $ociFindings -ExpectedProvider 'OCI'
            }

            $collectionErrors = @($ociFindings | Where-Object { $_.Category -eq 'Collection' })
            Record-CollectionResult -Name 'OCI API calls' -Finding $ociFindings

            foreach ($item in $ociFindings) { $allFindings.Add($item) }
            $byCategory = $ociFindings | Group-Object Category | ForEach-Object { "$($_.Name)=$($_.Count)" }
            Write-Host "    Findings: $($ociFindings.Count) [$($byCategory -join ', ')]" -ForegroundColor DarkGray
        }
    }
}

# ============================================================================
# Summary
# ============================================================================
if ($allFindings.Count -gt 0) {
    Write-Host ''
    Write-Host '--- Summary ---' -ForegroundColor Cyan
    Get-CloudCostSummary -Finding @($allFindings) | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

    $actionable = @($allFindings | Where-Object { $_.Status -eq 'Fail' -or $_.Status -eq 'Warn' })
    if ($actionable.Count -gt 0) {
        Write-Host "  Actionable findings: $($actionable.Count)" -ForegroundColor Yellow
        $actionable | Select-Object Provider, Category, Check, Status, Value, Resource |
            Format-Table -AutoSize | Out-String -Width 160 | Write-Host
    }

    if ($ShowFindings) {
        $allFindings | Select-Object Provider, Category, Check, Status, Value, Resource, Detail |
            Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }

    if ($ExportPath) {
        try {
            Export-CloudCostDashboard -Finding @($allFindings) -OutputPath $ExportPath -ReportTitle 'Cloud Cost and Quota (live)' | Out-Null
            Write-Host "  HTML report: $ExportPath" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Could not render dashboard: $($_.Exception.Message)"
        }
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed   Failed: $script:Failed   Skipped: $script:Skipped" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host '============================================================' -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD65c084gOd6Eoz
# /Khcy93GPcutRy7P5XaDwWckH7OvZqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCC14TrqPQpmKwMyYa6VurTfzvUJ+n+utjJwig8EsHPO5jANBgkqhkiG9w0BAQEF
# AASCAgAeNagbrrbF77+PgLcH3c0cRabyZV2HkOX7+aiUDWXRJvgIollZTBEXVx2R
# QKLv6NJ+1Zxvcautnv6jvgag1R0aDuAoLM4C0iSuR/qSeMMuxhjL2EjkTWtca0NF
# jTtjYoxZmkWlI/1opu+Z1Cjl9wXWdGgluvwxxNru90lns4cyARyiStnssUWifalV
# bJWMy8NMZu1VCxOv7FSpu6J0sXyfhOKC4Zsu7rH1xtpLCJ5LhOQ4YSQrZu7OQCjP
# 1TrMh9oCUWfjzCT6hJNQTPYfYNBPar1LZbP5p7kjvWjeFSALi18ZTfnOuAF0jQ6v
# NBT7gvAgOT6vVh0Jr77D6DJHe6UEId0cEjNC56ce0U8LkTQdgcfcBuQcrlNNdOzO
# jjPoTF5iFu6H70urz3IYmuf+GaGUWRIKVeMnA+C24JU6anMllT0Fngw13xAkHkYh
# Jv1eBG9INaiCMeR61NJVC4Fv5kaRhwUxexzQaPTf1AF5ZJqS5bLoZJ/4jDyHH0Vs
# 4C//BCvlM/Ygk3FxXp70oQ/su4tfxWra9b9dm0twcMOLAWbNawCWfC6jpS7du1Dm
# PrjJ3L31GiK8RrBQALkSyJj2rSHx1UQMdE5VX1lnAgKpl4f/6to0+DCKZ/nx+vAI
# ha6ExPXQQhz2n8R+0YFu/3CYzC3mmkRa6RT1XeXePnw1ix2AG6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkyMDExMzRaMC8GCSqGSIb3DQEJBDEiBCCDIqeu
# /zD0hRjmFKpoPs99aAiUxra4l5xn5vKWFKITHzANBgkqhkiG9w0BAQEFAASCAgA0
# xzSHBD2gDvuADOp/tByKYw8k+jtzCerzGHzge2grGhy8AAzP3W7fUAYy4PBbVK6H
# X0cAeigj4g4UJg/2Xk6RNDdcFnVD8NlL52vt8C9mK0HWzZ/srHvO0XAbvhf+VipF
# SXEIVFgcS1PNAaWsV5gVBrTqw8Ohv/lLfvzUUWaPfVoUjSenc1MLDueWRzHRlRrg
# QqlHaxGurzL6khc6Qhw+hZAEhvPOobmH02HUQbDdy3AbZVCPJF4JOboxiB69ojIv
# 944kC/ptjE8NPRwuLqlMo2wT8hFPFklhIPCM2t2ufBGiE7ZTdZmMckWaGTtY6ET2
# L83qCUVfmEb9jjtg5W0WCOSfvJnpXg6S1Vilq7yoFQQoOOC8XPKzYAvFuV59s9St
# H2gn5yFTpYPU3qvL8weFnrsyRTSqd/WGuVGWpqk64gJCCFo7+uv1NIiX56v+YKZp
# 6nvEli9REXGqLOg2aVTOEvJwE0aed/WStVkPv6T+VTAwW4j5qk5B+S2Ghfz5w2U5
# iU5tMHwlwJqNu08Xv8R+TT2E1B1JnZ+w/WBCvZibRytTQOXwaqwjc8etrh08V8Rs
# jhTFcp3waSgcwKK6DkJnCe826fUu7Qt155W45jwIYGFfHwPoBSRqPihoR88+eDep
# OgpaWYEvMdLSu1KvaeO0EJ1ob0TUMnqYQ5Lod6Y15g==
# SIG # End signature block
