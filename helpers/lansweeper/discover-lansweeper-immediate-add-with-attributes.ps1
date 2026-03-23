# ---------------------------------------------------------------------------
# discover-lansweeper-immediate-add-with-attributes.ps1
# Discovers assets from Lansweeper and adds them to WhatsUp Gold with
# custom attributes for Lansweeper metadata.
# ---------------------------------------------------------------------------
# Prerequisites:
#   - WhatsUpGoldPS module imported
#   - Lansweeper Personal Access Token (PAT) or OAuth credentials
# ---------------------------------------------------------------------------

param(
    [string]$WUGServer       = '192.168.1.250',
    [string]$LansweeperToken,
    [string]$LansweeperSiteId,
    [string[]]$AssetTypeFilter,
    [string]$WUGGroupName    = 'Lansweeper Assets',
    [switch]$IncludeMetrics
)

# ---- Load helpers ----
$helpersPath = Join-Path $PSScriptRoot 'LansweeperHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    Write-Error "LansweeperHelpers.ps1 not found at: $helpersPath"
    return
}
. $helpersPath

# ---- Authenticate to Lansweeper ----
if (-not $LansweeperToken) {
    $LansweeperToken = Read-Host -Prompt 'Enter your Lansweeper Personal Access Token'
}
if (-not $LansweeperToken) {
    Write-Error "A Lansweeper PAT is required."
    return
}
Connect-LansweeperPAT -Token $LansweeperToken

if (-not $script:LansweeperSession.Connected) {
    Write-Error "Failed to connect to Lansweeper."
    return
}

# ---- Authenticate to WhatsUp Gold ----
Write-Host "`nConnecting to WhatsUp Gold at $WUGServer..." -ForegroundColor Cyan
$WUGCred = Get-Credential -Message "Enter WhatsUp Gold credentials"
Connect-WUGServer -serverUri $WUGServer -Credential $WUGCred -Protocol https -IgnoreSSLErrors

# ---- Select Lansweeper site ----
if (-not $LansweeperSiteId) {
    $sites = Get-LansweeperSites
    if (-not $sites -or $sites.Count -eq 0) {
        Write-Error "No authorized Lansweeper sites found."
        return
    }
    Write-Host "`nAvailable Lansweeper sites:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $sites.Count; $i++) {
        Write-Host "  [$i] $($sites[$i].name) ($($sites[$i].id))"
    }
    $choice = Read-Host "Select site number"
    if ($choice -match '^\d+$') {
        $idx = [int]$choice
        if ($idx -ge 0 -and $idx -lt $sites.Count) {
            $LansweeperSiteId = $sites[$idx].id
        }
    }
    if (-not $LansweeperSiteId) {
        Write-Error "No site selected."
        return
    }
}

$siteInfo = Get-LansweeperSiteInfo -SiteId $LansweeperSiteId
Write-Host "Using Lansweeper site: $($siteInfo.name)" -ForegroundColor Green

# ---- Retrieve assets ----
Write-Host "`nRetrieving assets from Lansweeper..." -ForegroundColor Cyan

$assetFields = @(
    'assetBasicInfo.name',
    'assetBasicInfo.type',
    'assetBasicInfo.subType',
    'assetBasicInfo.typeGroup',
    'assetBasicInfo.ipAddress',
    'assetBasicInfo.mac',
    'assetBasicInfo.domain',
    'assetBasicInfo.description',
    'assetBasicInfo.firstSeen',
    'assetBasicInfo.lastSeen',
    'assetCustom.manufacturer',
    'assetCustom.model',
    'assetCustom.serialNumber',
    'assetCustom.dnsName',
    'assetCustom.stateName',
    'networks.ipAddressV4',
    'url'
)

$getParams = @{
    SiteId = $LansweeperSiteId
    Fields = $assetFields
    All    = $true
}

if ($AssetTypeFilter -and $AssetTypeFilter.Count -gt 0) {
    $conditions = @()
    foreach ($typeName in $AssetTypeFilter) {
        $conditions += @{ operator = 'EQUAL'; path = 'assetBasicInfo.type'; value = $typeName }
    }
    $getParams.Filters = @{ conjunction = 'OR'; conditions = $conditions }
}

$assets = Get-LansweeperAssets @getParams
Write-Host "Retrieved $($assets.Count) assets." -ForegroundColor Green

if (-not $assets -or $assets.Count -eq 0) {
    Write-Warning "No assets found matching criteria."
    return
}

# ---- Map Lansweeper asset types to WUG brand/OS ----
function Get-WUGBrandFromLansweeperType {
    param([string]$AssetType)
    switch -Wildcard ($AssetType) {
        'Windows'                   { return 'Microsoft' }
        'Server'                    { return 'Microsoft' }
        'Linux'                     { return 'Linux' }
        'Unix'                      { return 'Unix' }
        'ESXi server'               { return 'VMware' }
        'VMware*'                   { return 'VMware' }
        'Hyper-V*'                  { return 'Microsoft' }
        'Citrix*'                   { return 'Citrix' }
        'Apple Mac'                 { return 'Apple' }
        'Switch'                    { return 'Network' }
        'Router'                    { return 'Network' }
        'Firewall'                  { return 'Network' }
        'Wireless Access point'     { return 'Network' }
        'Printer'                   { return 'Printer' }
        'UPS'                       { return 'UPS' }
        'AWS EC2 Instance'          { return 'AWS' }
        'Azure Virtual Machine'     { return 'Azure' }
        'NAS'                       { return 'Storage' }
        'SAN'                       { return 'Storage' }
        'Load balancer'             { return 'Network' }
        default                     { return 'Other' }
    }
}

# ---- Add assets to WhatsUp Gold ----
$added = 0
$skipped = 0
$failed = 0

foreach ($asset in $assets) {
    $assetName = 'Unknown'
    $assetType = 'Unknown'
    $assetDesc = ''
    $assetDomain = ''
    $assetMac = ''
    $assetManufacturer = ''
    $assetModel = ''
    $assetSerial = ''

    if ($asset.assetBasicInfo) {
        $bi = $asset.assetBasicInfo
        if ($bi.name)        { $assetName   = "$($bi.name)" }
        if ($bi.type)        { $assetType   = "$($bi.type)" }
        if ($bi.description) { $assetDesc   = "$($bi.description)" }
        if ($bi.domain)      { $assetDomain = "$($bi.domain)" }
        if ($bi.mac)         { $assetMac    = "$($bi.mac)" }
    }
    if ($asset.assetCustom) {
        $ac = $asset.assetCustom
        if ($ac.manufacturer)  { $assetManufacturer = "$($ac.manufacturer)" }
        if ($ac.model)         { $assetModel        = "$($ac.model)" }
        if ($ac.serialNumber)  { $assetSerial       = "$($ac.serialNumber)" }
    }

    # Resolve IP address
    $ip = Resolve-LansweeperAssetIP -Asset $asset
    if (-not $ip) {
        Write-Warning "Skipping '$assetName' -- no IP address resolved."
        $skipped++
        continue
    }

    Write-Host "Adding: $assetName ($assetType) at $ip" -ForegroundColor White

    # Build custom attributes
    $assetKey = if ($asset.key) { "$($asset.key)" } else { '' }
    $assetUrl = if ($asset.url) { "$($asset.url)" } else { '' }
    $lastSeen = ''
    $firstSeen = ''
    if ($asset.assetBasicInfo) {
        if ($asset.assetBasicInfo.lastSeen) { $lastSeen = "$($asset.assetBasicInfo.lastSeen)" }
        if ($asset.assetBasicInfo.firstSeen) { $firstSeen = "$($asset.assetBasicInfo.firstSeen)" }
    }

    $attributes = @(
        @{ Name = 'Lansweeper_Source';       Value = 'Lansweeper' }
        @{ Name = 'Lansweeper_AssetKey';     Value = $assetKey }
        @{ Name = 'Lansweeper_AssetType';    Value = $assetType }
        @{ Name = 'Lansweeper_Site';         Value = "$($siteInfo.name)" }
        @{ Name = 'Lansweeper_SiteId';       Value = $LansweeperSiteId }
        @{ Name = 'Lansweeper_Domain';       Value = $assetDomain }
        @{ Name = 'Lansweeper_MAC';          Value = $assetMac }
        @{ Name = 'Lansweeper_Manufacturer'; Value = $assetManufacturer }
        @{ Name = 'Lansweeper_Model';        Value = $assetModel }
        @{ Name = 'Lansweeper_Serial';       Value = $assetSerial }
        @{ Name = 'Lansweeper_FirstSeen';    Value = $firstSeen }
        @{ Name = 'Lansweeper_LastSeen';     Value = $lastSeen }
        @{ Name = 'Lansweeper_Url';          Value = $assetUrl }
        @{ Name = 'Lansweeper_LastSync';     Value = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    )

    $brandName = Get-WUGBrandFromLansweeperType -AssetType $assetType

    $note = "Discovered by Lansweeper -- Site: $($siteInfo.name), Type: $assetType, Description: $assetDesc, Key: $assetKey"

    try {
        $newDeviceId = Add-WUGDeviceTemplate `
            -displayName $assetName `
            -DeviceAddress $ip `
            -Brand $brandName `
            -OS $assetType `
            -ActiveMonitors @('Ping') `
            -PerformanceMonitors @('Ping Latency and Availability') `
            -Attributes $attributes `
            -Note $note

        if ($newDeviceId) {
            Write-Host "  Added device ID: $newDeviceId" -ForegroundColor Green
            $added++
        } else {
            Write-Warning "  Failed to add '$assetName'."
            $failed++
        }
    }
    catch {
        Write-Warning "  Error adding '$assetName': $_"
        $failed++
    }
}

# ---- Summary ----
Write-Host "`n---- Discovery Summary ----" -ForegroundColor Cyan
Write-Host "  Total assets:  $($assets.Count)"
Write-Host "  Added to WUG:  $added"
Write-Host "  Skipped:       $skipped (no IP)"
Write-Host "  Failed:        $failed"

# ---- Cleanup ----
Disconnect-WUGServer
Disconnect-Lansweeper
Write-Host "`nDone." -ForegroundColor Green

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBrEe4WU5ywDoEZ
# ITc3afZubS4FzuRU+fc3coVUzNOtD6CCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgxnobMLSmu/6PGFt0vPCTBXn//lQqWPjI
# b1xHmDd8kCwwDQYJKoZIhvcNAQEBBQAEggIAfabLlLbm/Zz+go9WXE8PQol9vuWn
# YfV+W/+Uv82sjoWttM0vd46IlHb2YuyvcwBPF8mgD3q8v5rSQlXy7d32K7t/Tl5k
# c2BoR3zCxpcOTh4GxEW9Hv756elyeiaWEXqJM41Ynnl+IFSVSwbaPPs69LLDePfG
# JHMjn5DLVO3opOLdqkbHAjI4KE2rIhekKC8WqYIV9RB4vbC+eJhd2pTH0UgTAcIw
# k10QIuAUXXzQz48vjDprMXr5ZN4oviyhrfzKKoHhHU1cT4g2zaX/d61xQWdDriu3
# F/C84Ew/EXmwSEaN0t7yA+ewHN1Ng1RU0qTLRSnMmHYjUoOANXiFiJ3xVvvexBv0
# eUIlOub4NXXmnZbJMjITX5uxZ+KCGUWlZekWQ6WINJDW5NPdbTPoyro0OZX/a7kG
# f22bGF/56RhTMbb9OjduwBuY3Dg9tfTAE3PN6dvTbkaoPkVDABm4xdYOBZ/SqLTz
# fHoAV45VcGZWFe0yfbudinhJP4Fz0jBO6k+6Y0zNA5S5xZ5DXLQ9wdh+ZlbmeavD
# nsssBMWg/HUqGxqeK1zaL9K1d6kxsMXzWCvaUgQfRP9w6WtoPjY3YflUP4wdJmxp
# ca6CZ0BlGzxlbzyl2P62Wq64CX8El3lxTTwbkXE5ZXWKp0hFCHeDTeaKw5CvcRDT
# T+nLYdhvqzPZ/YY=
# SIG # End signature block
