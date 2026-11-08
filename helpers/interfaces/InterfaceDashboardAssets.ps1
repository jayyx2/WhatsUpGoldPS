function Get-OfflineInterfaceDashboardAssetMap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DependencyPath)

    $files = @{
        'https://cdn.jsdelivr.net/npm/bootstrap/dist/css/bootstrap.min.css'        = 'bootstrap.min.css'
        'https://cdn.jsdelivr.net/npm/bootstrap-table/dist/bootstrap-table.min.css' = 'bootstrap-table.min.css'
        'https://cdn.jsdelivr.net/npm/bootstrap-icons/font/bootstrap-icons.min.css' = 'bootstrap-icons.min.css'
        'https://cdn.jsdelivr.net/npm/jquery/dist/jquery.min.js'                    = 'jquery.min.js'
        'https://cdn.jsdelivr.net/npm/@popperjs/core/dist/umd/popper.min.js'        = 'popper.min.js'
        'https://cdn.jsdelivr.net/npm/bootstrap/dist/js/bootstrap.min.js'           = 'bootstrap.min.js'
        'https://cdn.jsdelivr.net/npm/bootstrap-table/dist/bootstrap-table.min.js' = 'bootstrap-table.min.js'
        'https://cdn.jsdelivr.net/npm/file-saver/dist/FileSaver.min.js'             = 'FileSaver.min.js'
        'https://cdn.jsdelivr.net/npm/xlsx/dist/xlsx.full.min.js'                   = 'xlsx.full.min.js'
        'https://cdn.jsdelivr.net/npm/html2canvas/dist/html2canvas.min.js'          = 'html2canvas.min.js'
    }

    $assets = @{}
    foreach ($url in $files.Keys) {
        $assets[$url] = [pscustomobject]@{
            Name = $files[$url]
            Path = Join-Path $DependencyPath $files[$url]
            Kind = if ($files[$url].EndsWith('.css', [StringComparison]::OrdinalIgnoreCase)) { 'Style' } else { 'Script' }
        }
    }
    return $assets
}

function Get-OfflineInterfaceDashboardFontData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DependencyPath,
        [Parameter(Mandatory)][string]$FontName
    )

    $fontPath = Join-Path (Join-Path $DependencyPath 'fonts') $FontName
    if (-not (Test-Path -LiteralPath $fontPath -PathType Leaf)) {
        throw "Required offline dashboard asset '$fontPath' is missing."
    }

    $extension = [IO.Path]::GetExtension($FontName).ToLowerInvariant()
    switch ($extension) {
        '.woff2' { $mimeType = 'font/woff2' }
        '.woff'  { $mimeType = 'font/woff' }
        default  { throw "Unsupported Bootstrap Icons font asset '$FontName'." }
    }
    $bytes = [IO.File]::ReadAllBytes($fontPath)
    return "data:$mimeType;base64,$([Convert]::ToBase64String($bytes))"
}

function ConvertTo-OfflineInterfaceDashboardHtml {
    <#
    .SYNOPSIS
        Inlines the approved dashboard framework assets into an interface group page.
    .DESCRIPTION
        Converts the shared dynamic-dashboard template's known Bootstrap, table,
        export, and icon CDN references to inline content from the repository's
        existing helpers\reports\dependency bundle. Bootstrap Icons fonts are
        embedded as data URIs. Unknown runtime resource references and missing
        bundle files are errors; this function never downloads assets.
    .PARAMETER Html
        Complete rendered interface group page.
    .PARAMETER DependencyPath
        Directory containing the existing dashboard dependency bundle. Defaults
        to helpers\reports\dependency relative to this script.
    .OUTPUTS
        System.String. A standalone HTML page with the existing table, status,
        detail, and export behavior intact.
    .NOTES
        Embedded vendor files retain their upstream license banners where present.
        License references for the bundled assets are included in the generated page.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
        [string]$DependencyPath
    )

    if (-not $PSBoundParameters.ContainsKey('DependencyPath') -or -not $DependencyPath) {
        $DependencyPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'reports\dependency'
    }
    $DependencyPath = [IO.Path]::GetFullPath($DependencyPath)
    $assetMap = Get-OfflineInterfaceDashboardAssetMap -DependencyPath $DependencyPath

    # A favicon is optional decoration and is not part of an offline report.
    $Html = [regex]::Replace($Html, '(?is)<link\b(?=[^>]*\brel\s*=\s*["''][^"'']*\bicon\b[^"'']*["''])[^>]*>', '')

    $Html = [regex]::Replace($Html, '(?is)<link\b[^>]*>', [System.Text.RegularExpressions.MatchEvaluator]{
        param($tagMatch)
        $tag = $tagMatch.Value
        $hrefMatch = [regex]::Match($tag, '(?is)\bhref\s*=\s*(["''])(?<url>.*?)\1')
        if (-not $hrefMatch.Success) { return $tag }
        $url = [System.Net.WebUtility]::HtmlDecode($hrefMatch.Groups['url'].Value)
        if ($assetMap.ContainsKey($url)) {
            $asset = $assetMap[$url]
            if ($asset.Kind -ne 'Style') {
                throw "Dashboard asset '$url' is not a stylesheet."
            }
            if (-not (Test-Path -LiteralPath $asset.Path -PathType Leaf)) {
                throw "Required offline dashboard asset '$($asset.Path)' is missing."
            }
            $css = [IO.File]::ReadAllText($asset.Path)
            $css = [regex]::Replace($css, 'url\((?<quote>["'']?)(?<path>[^)"'']+)\k<quote>\)', [System.Text.RegularExpressions.MatchEvaluator]{
                param($urlMatch)
                $resourcePath = $urlMatch.Groups['path'].Value.Trim()
                $fontPath = ($resourcePath -split '\?')[0]
                if ($fontPath -match '^(?:\.\./)?fonts/bootstrap-icons\.(?<ext>woff2?)$') {
                    $fontName = [IO.Path]::GetFileName($fontPath)
                    $fontData = Get-OfflineInterfaceDashboardFontData -DependencyPath $DependencyPath -FontName $fontName
                    return "url(`"$fontData`")"
                }
                if ($resourcePath -match '^(?i)(?:https?:)?//') {
                    throw "Unapproved remote CSS resource '$resourcePath'."
                }
                return $urlMatch.Value
            })
            if ($css -match '(?i)url\(\s*["'']?(?:https?:)?//') {
                throw "Stylesheet '$($asset.Name)' contains an unapproved remote resource."
            }
            return "<style data-offline-asset=`"$($asset.Name)`">`r`n$css`r`n</style>"
        }
        $relMatch = [regex]::Match($tag, '(?is)\brel\s*=\s*(["''])(?<rel>.*?)\1')
        if ($relMatch.Success -and $relMatch.Groups['rel'].Value -match '(?i)\bstylesheet\b') {
            throw "Unapproved stylesheet dependency '$url'."
        }
        if ($url -match '^(?i)(?:https?:)?//') {
            throw "Unapproved remote link dependency '$url'."
        }
        return $tag
    })

    $Html = [regex]::Replace($Html, '(?is)<script\b[^>]*>.*?</script\s*>', [System.Text.RegularExpressions.MatchEvaluator]{
        param($tagMatch)
        $tag = $tagMatch.Value
        $srcMatch = [regex]::Match($tag, '(?is)\bsrc\s*=\s*(["''])(?<url>.*?)\1')
        if (-not $srcMatch.Success) { return $tag }
        $url = [System.Net.WebUtility]::HtmlDecode($srcMatch.Groups['url'].Value)
        if (-not $assetMap.ContainsKey($url)) {
            throw "Unapproved script dependency '$url'."
        }
        $asset = $assetMap[$url]
        if ($asset.Kind -ne 'Script') {
            throw "Dashboard asset '$url' is not a script."
        }
        if (-not (Test-Path -LiteralPath $asset.Path -PathType Leaf)) {
            throw "Required offline dashboard asset '$($asset.Path)' is missing."
        }
        $script = [IO.File]::ReadAllText($asset.Path)
        if ($script -match '(?i)</script') {
            $script = [regex]::Replace($script, '(?i)</script', '<\/script')
        }
        return "<script data-offline-asset=`"$($asset.Name)`">`r`n$script`r`n</script>"
    })

    # Inline resources which were not explicitly approved would still make a
    # file:// report depend on a network or on an unbundled local file.
    $resourceTags = [regex]::Matches($Html, '(?is)<(?:script|img|iframe|source|video|audio|embed|object)\b[^>]*>')
    foreach ($tagMatch in $resourceTags) {
        $tag = $tagMatch.Value
        foreach ($attribute in @('src', 'poster', 'data')) {
            $attributeMatch = [regex]::Match($tag, "(?is)\b$attribute\s*=\s*(['""])(?<value>.*?)\1")
            if ($attributeMatch.Success -and $attributeMatch.Groups['value'].Value -notmatch '^(?i)data:') {
                throw "Unresolved $attribute resource '$($attributeMatch.Groups['value'].Value)'."
            }
        }
    }
    foreach ($pattern in @(
        '(?i)<link\b[^>]*\brel\s*=\s*["''][^"'']*\bstylesheet\b',
        '(?i)<script\b[^>]*\bsrc\s*='
    )) {
        $unresolved = [regex]::Match($Html, $pattern)
        if ($unresolved.Success) {
            throw "HTML still contains an unresolved dependency: $($unresolved.Value)"
        }
    }
    $htmlWithoutScripts = [regex]::Replace($Html, '(?is)<script\b[^>]*>.*?</script\s*>', '')
    foreach ($styleMatch in [regex]::Matches($htmlWithoutScripts, '(?is)<style\b[^>]*>(?<css>.*?)</style\s*>')) {
        $remoteCss = [regex]::Match($styleMatch.Groups['css'].Value, '(?i)@import\s+(?:url\()?["'']?(?:https?:)?//|url\(\s*["'']?(?:https?:)?//')
        if ($remoteCss.Success) {
            $styleAsset = [regex]::Match($styleMatch.Value, 'data-offline-asset="(?<name>[^"]+)"').Groups['name'].Value
            throw "HTML still contains an unresolved remote CSS dependency in '$styleAsset': $($remoteCss.Value)"
        }
    }

    $licenseNote = @'
<!--
Offline dashboard vendor assets (embedded from helpers/reports/dependency):
Bootstrap 5.3.8, Bootstrap Icons 1.13.1, Bootstrap Table 1.27.0, jQuery 4.0.0,
Popper 2.11.8, FileSaver.js, SheetJS XLSX 0.18.5, and html2canvas 1.4.1.
Upstream license notices are preserved where shipped in the asset files.
License references: Bootstrap and Bootstrap Icons (MIT, getbootstrap.com);
Bootstrap Table (MIT, github.com/wenzhixin/bootstrap-table); jQuery (MIT,
jquery.org/license); Popper (MIT, github.com/floating-ui/floating-ui);
FileSaver.js (MIT, github.com/eligrey/FileSaver.js); html2canvas (MIT,
github.com/niklasvh/html2canvas); SheetJS XLSX 0.18.5 (Apache-2.0,
npmjs.com/package/xlsx/v/0.18.5).
-->
'@
    $doctype = [regex]::Match($Html, '\A(?<doctype>\uFEFF?\s*<!doctype\b[^>]*>)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($doctype.Success) {
        $insertAt = $doctype.Index + $doctype.Length
        $Html = $Html.Insert($insertAt, "`r`n$licenseNote")
    }
    else {
        $Html = $licenseNote + "`r`n" + $Html
    }
    return $Html
}

function Copy-OfflineInterfaceDashboardAssets {
    <#
    .SYNOPSIS
        Copies the approved dashboard dependency bundle to a report asset folder.
    .DESCRIPTION
        Provides a local-file alternative for consumers that do not inline assets.
        The interface dashboard converter embeds its dependencies by default.
    .PARAMETER OutputDirectory
        Directory to receive the dashboard files and the fonts subdirectory.
    .PARAMETER DependencyPath
        Directory containing the existing dashboard dependency bundle. Defaults
        to helpers\reports\dependency relative to this script.
    .EXAMPLE
        Copy-OfflineInterfaceDashboardAssets -OutputDirectory C:\Reports\Interfaces\assets
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$DependencyPath
    )

    if (-not $PSBoundParameters.ContainsKey('DependencyPath') -or -not $DependencyPath) {
        $DependencyPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'reports\dependency'
    }
    $DependencyPath = [IO.Path]::GetFullPath($DependencyPath)
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $assetMap = Get-OfflineInterfaceDashboardAssetMap -DependencyPath $DependencyPath
    $sourcePaths = @($assetMap.Values | ForEach-Object { $_.Path })
    $sourcePaths += Join-Path (Join-Path $DependencyPath 'fonts') 'bootstrap-icons.woff2'
    $sourcePaths += Join-Path (Join-Path $DependencyPath 'fonts') 'bootstrap-icons.woff'
    foreach ($sourcePath in $sourcePaths) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required offline dashboard asset '$sourcePath' is missing."
        }
    }

    if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Copy offline dashboard assets')) {
        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
        }
        foreach ($sourcePath in $sourcePaths) {
            $targetDirectory = $OutputDirectory
            if ((Split-Path $sourcePath -Parent) -eq (Join-Path $DependencyPath 'fonts')) {
                $targetDirectory = Join-Path $OutputDirectory 'fonts'
                if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                    New-Item -ItemType Directory -Path $targetDirectory -Force -ErrorAction Stop | Out-Null
                }
            }
            Copy-Item -LiteralPath $sourcePath -Destination $targetDirectory -Force -ErrorAction Stop
        }
        $licensePath = Join-Path $OutputDirectory 'LICENSES.txt'
        $licenseText = @'
Offline interface dashboard dependencies copied from helpers/reports/dependency:

bootstrap.min.css, bootstrap.min.js: Bootstrap 5.3.8, MIT.
bootstrap-icons.min.css and fonts/bootstrap-icons.*: Bootstrap Icons 1.13.1, MIT.
bootstrap-table.min.css, bootstrap-table.min.js: Bootstrap Table 1.27.0, MIT.
jquery.min.js: jQuery 4.0.0, MIT.
popper.min.js: Popper 2.11.8, MIT.
FileSaver.min.js: FileSaver.js, MIT.
xlsx.full.min.js: SheetJS XLSX 0.18.5, Apache-2.0.
html2canvas.min.js: html2canvas 1.4.1, MIT.

Upstream notices are retained in the bundled files where present. License texts
and project information are available from the upstream repositories:
https://github.com/twbs/bootstrap
https://github.com/twbs/icons
https://github.com/wenzhixin/bootstrap-table
https://github.com/jquery/jquery
https://github.com/floating-ui/floating-ui
https://github.com/eligrey/FileSaver.js
https://github.com/niklasvh/html2canvas
https://www.npmjs.com/package/xlsx/v/0.18.5
'@
        [IO.File]::WriteAllText($licensePath, $licenseText, [Text.UTF8Encoding]::new($true))
    }
    return $OutputDirectory
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCxGB1+SJSo39ig
# G1iWHBnLNE7XZBjp0tJsc88uxNnPUKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDw
# wKxfu7ZQiHAyeEwuHB0cSOzMS1BYI0kPkYWpv5+f+jANBgkqhkiG9w0BAQEFAASC
# AgAQkUl//9h6+LZSOdctiksJTADFuMe/5DIxja6XFFmCu4ZF3NmX2jnG8AQRuxag
# JyIc7E2Hv9caM0EHj2GCf8/g7+mkMgZmmC0vICgPA/bw4zZPL/L/NJm1lMPoDgNg
# c4+bo1YA+P8IWPYFndgUwAQ90rmsulAGGB3nn6QjVBrdAhaB5DDSvf/DInaAVpwx
# l61E2qx0HQlQvEVOgDZC4miYI89yICUO/1h2c60bqEtiPtfjAqLApwOe/EdhPK80
# GSj6uOG1IyAduCyd3eyPbqw3kia6Wkmfhg4qxt9LhdT9RHZAb2DUcgfgUehxiOt7
# Crz23Wl7piADN+UsOt6zzl2E9xTW3Ifrs6o+fRM6yfTI/I7EWdnFe2CR9K77x3Tt
# 8s/NCvGjv15YOpWxin82G5jM5wvr5ldih6uwHN3xLZsFDdl0qbjuukxd8hNuBP+U
# bpN7SJU3V0YLkFdCaQ695Zc6iR1aXrZqsIrn7eya2TpUb4l/VcqzBpykGXC9KuNH
# LwlF/z+lGyx4sRmYIbTq4vXffASvOfugCoMTKbENl+JBL+Z+B6cVzrgiYqC3hT/B
# KxxyZqAom2sC43K1EdLU/mJv0gDxy3SY1iAIUbtfc0Xbzgi2/kVhgKi1y9FewKFe
# GYzH08NlzFWp7rf+3ylqE3J4VEjMQMStju0CcebyeglBaqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxOTA5MTNaMC8GCSqGSIb3DQEJBDEiBCAB4n/UUith
# ZWjcmJ1R7sbKvsHXnUV9FlRcadNxZyRqNzANBgkqhkiG9w0BAQEFAASCAgBeDA/A
# /EKjehD7BjzjduQ4Xrlb6CWZnhIPmpUJrmErUX08hX4dowHPw7LZV5gkFh+R29hv
# zx5RShkyPdPCbfP4DBbEeUkdDBO43C1m6pWYp+el9f4QQ0BKdLOsoLYgbHe1b245
# Lv8Bjkepiy3vkMXbIhTz9UohnAdlq2WqWMfl78xjuYbnkpu/IvKlIzW2l6uu3rFm
# G4Ujl3T08I4k4nYB31CcKB1s2xB2nYdkCLmNXn6JlnlpjWNkdsQufF04BGXt9iZN
# erk83fKH5y6YSA52i4TZfhMOxySqEufnyc2DYlOAWHe9LLJ0g0Slo5JZ16N9+H23
# fQbjkzF9TfV/ypxDiwVhlpbYqNUpfqTImVDDzrgSBK+vogEHljhPcvkGSHVw4+nS
# LkTlera9G6P4tyG73TK/YQjvF+xfOWLdD4XcIwBEoSrmqbg2GdaK7PUJWgcfwdu4
# pu3W2dfZlRwaebv1qBDV8j5CCHPW861UfRmDbXIq++cRYbKQJULI2vZAKKdvSMU2
# egAWrNVDXacOmmi5aZALr0KYa1XNHIu+o9gIbQo+cKXLqaZX+qYV49WQLEdoRF2s
# q5QjAHRgG/yC/cLaTNtotO2xfBg5eDulEK7oGIDkVIuQd3lOAh+fEAeb+/VgWmlm
# xHmGe01WReq7ZNa46tTr/IMt+SvkeEwYXkCdFg==
# SIG # End signature block
