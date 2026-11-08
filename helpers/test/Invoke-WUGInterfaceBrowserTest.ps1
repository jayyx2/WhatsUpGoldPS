#requires -Version 5.1
<#
.SYNOPSIS
    Runs offline browser regressions for interface dashboards and review pages.
.DESCRIPTION
    Builds a deterministic dashboard and graphical review from local mock
    inventory, then drives both pages in headless Chromium with Playwright.
    No WUG connection, live API, local web server, or external network access is
    used. The unique fixture directory is always removed after the run.
.PARAMETER PlaywrightModulePath
    Optional path to an installed Playwright or Playwright Core module directory
    or entry file. If omitted, Node.js resolves the package from the repository.
.PARAMETER BrowserExecutablePath
    Optional path to Chromium, Chrome, or Edge when Playwright's own browser is
    not installed.
.EXAMPLE
    powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceBrowserTest.ps1
.EXAMPLE
    powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceBrowserTest.ps1 `
        -PlaywrightModulePath C:\tools\node_modules\playwright `
        -BrowserExecutablePath 'C:\Program Files\Google\Chrome\Application\chrome.exe'
.NOTES
    Requires Node.js, Playwright (or Playwright Core), and a Chromium-compatible
    browser. To bootstrap without changing package manifests:
    npm install --no-save --package-lock=false playwright
    npx playwright install chromium
    Throws on missing prerequisites or failed assertions.
.LINK
    ..\..\docs\interface-grouping.md
#>
[CmdletBinding()]
param(
    [string]$PlaywrightModulePath,
    [string]$BrowserExecutablePath
)

$ErrorActionPreference = 'Stop'

if ($PlaywrightModulePath -and -not (Test-Path -LiteralPath $PlaywrightModulePath)) {
    throw "Playwright module path does not exist: $PlaywrightModulePath"
}
if ($BrowserExecutablePath -and -not (Test-Path -LiteralPath $BrowserExecutablePath -PathType Leaf)) {
    throw "Browser executable path does not exist: $BrowserExecutablePath"
}

$node = Get-Command -Name node.exe -ErrorAction SilentlyContinue
if (-not $node) {
    throw 'Node.js is required. Install Node.js, then install Playwright using the bootstrap steps in this script help.'
}

$runDirectory = Join-Path $PSScriptRoot ('.wug-interface-browser-test-' + [guid]::NewGuid().ToString('N'))
$dashboardPath = $null
$reviewPath = Join-Path $runDirectory 'interface-review.html'
$fixtureOwned = $false

function Get-VerifiedCloudPlaceholderAncestors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $fsutil = Get-Command -Name fsutil.exe -ErrorAction Stop
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            if (-not $item.PSIsContainer) {
                throw "Refusing to mock a non-directory reparse point: $current"
            }
            foreach ($propertyName in @('LinkType', 'Target')) {
                $property = $item.PSObject.Properties[$propertyName]
                if ($property -and $property.Value) {
                    throw "Refusing to mock a linked ancestor '$current' ($propertyName=$($property.Value))."
                }
            }
            $query = @(& $fsutil.Source reparsepoint query $current 2>&1)
            $tagMatch = [regex]::Match(($query -join "`n"), 'Reparse Tag Value\s*:\s*0x(?<tag>[0-9a-fA-F]{8})')
            if (-not $tagMatch.Success) {
                throw "Could not verify the reparse tag for ancestor: $current"
            }
            $tag = [Convert]::ToUInt32($tagMatch.Groups['tag'].Value, 16)
            $cloudTagMask = [Convert]::ToUInt32('FFFF0FFF', 16)
            $cloudTag = [Convert]::ToUInt32('9000001A', 16)
            if (($tag -band $cloudTagMask) -ne $cloudTag) {
                throw "Refusing to mock non-OneDrive reparse ancestor '$current' (tag 0x$($tag.ToString('x8')))."
            }
            $null = $paths.Add([IO.Path]::GetFullPath($item.FullName))
        }
        $parent = Split-Path $current -Parent
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return ,$paths
}

function Export-InterfaceBrowserReviewFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Inventory,
        [Parameter(Mandatory)][object[]]$Groups,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$MockedAncestors
    )

    function Get-Item {
        [CmdletBinding()]
        param([string[]]$Path, [string[]]$LiteralPath, [switch]$Force)

        $arguments = @{}
        foreach ($name in $PSBoundParameters.Keys) { $arguments[$name] = $PSBoundParameters[$name] }
        $items = Microsoft.PowerShell.Management\Get-Item @arguments
        foreach ($item in $items) {
            $fullName = [IO.Path]::GetFullPath($item.FullName)
            if (-not $MockedAncestors.Contains($fullName)) {
                Write-Output $item
                continue
            }
            $properties = [ordered]@{}
            foreach ($property in $item.PSObject.Properties) {
                $properties[$property.Name] = $property.Value
            }
            $properties['Attributes'] = $item.Attributes -band (-bnot [IO.FileAttributes]::ReparsePoint)
            Write-Output ([pscustomobject]$properties)
        }
    }

    try {
        Export-InterfaceGroupBrowserReview -Inventory $Inventory -Groups $Groups `
            -Path $Path -Confirm:$false
    }
    finally {
        Remove-Item -LiteralPath Function:\Get-Item -Force -ErrorAction SilentlyContinue
    }
}

try {
    . (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupingHelpers.ps1')
    . (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupBrowserReview.ps1')

    $deviceId = 818
    $deviceName = 'Browser-Fixture-Router'
    $interfaceIndexes = @(3, 1, 2, 9)
    $monitors = @(
        foreach ($index in $interfaceIndexes) {
            $comment = if ($index -eq 9) { 'Unassigned uplink' } else { "BrowserRegression eth$($index - 1)" }
            [pscustomobject]@{
                id = "fixture-active-$index"
                type = 'active'
                monitorTypeClassId = 'd6d02d69-a418-483a-93ea-20dd2af2d135'
                active = [pscustomobject]@{ argument = [string]$index; comment = $comment }
                status = 'Up at least 5 min'
                enabled = $true
            }
        }
    )

    $traffic = @(
        foreach ($index in $interfaceIndexes) {
            $rx = switch ($index) {
                1 { 1000 }
                2 { 5000 }
                3 { 2000 }
                9 { 300 }
            }
            $tx = switch ($index) {
                1 { 1200 }
                2 { 6000 }
                3 { 2500 }
                9 { 400 }
            }
            $name = if ($index -eq 9) { 'eth9' } else { "eth$($index - 1)" }
            [pscustomobject]@{
                interfaceId = "fixture-wug-$index"
                interfaceName = "GigabitEthernet $name ($index)"
                pollTimeUtc = '2026-11-08T12:00:00Z'
                rxSpeedAvg = $rx
                txSpeedAvg = $tx
                rxPercentAvg = [Math]::Min(99, [Math]::Round($rx / 100, 1))
                txPercentAvg = [Math]::Min(99, [Math]::Round($tx / 100, 1))
                timeFromLastPollSeconds = 20
                series = @(
                    [pscustomobject]@{
                        pollTimeUtc = '2026-11-08T11:58:00Z'; rxSpeedAvg = [Math]::Max(1, $rx - 200)
                        txSpeedAvg = [Math]::Max(1, $tx - 300); rxPercentAvg = 20; txPercentAvg = 30
                    },
                    [pscustomobject]@{
                        pollTimeUtc = '2026-11-08T11:59:00Z'; rxSpeedAvg = [Math]::Max(1, $rx - 100)
                        txSpeedAvg = [Math]::Max(1, $tx - 150); rxPercentAvg = 25; txPercentAvg = 35
                    },
                    [pscustomobject]@{
                        pollTimeUtc = '2026-11-08T12:00:00Z'; rxSpeedAvg = $rx
                        txSpeedAvg = $tx; rxPercentAvg = [Math]::Min(99, [Math]::Round($rx / 100, 1))
                        txPercentAvg = [Math]::Min(99, [Math]::Round($tx / 100, 1))
                    }
                )
            }
        }
    )

    $inventory = @(ConvertTo-InterfaceGroupInventory -DeviceId $deviceId -DeviceName $deviceName `
        -Monitors $monitors -Traffic $traffic)
    $groups = @(Select-InterfaceGroups -Inventory $inventory -GroupName 'BrowserRegression' -MatchMode Token)
    if ($groups.Count -ne 1 -or $groups[0].Interfaces.Count -ne 3) {
        throw 'The deterministic fixture did not produce the expected three grouped dashboard interfaces.'
    }

    if (Test-Path -LiteralPath $runDirectory) {
        throw "Refusing to overwrite an existing browser fixture directory: $runDirectory"
    }
    New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    $fixtureOwned = $true
    $null = Write-InterfaceGroupDashboardStage -Groups $groups -Inventory $inventory `
        -OutputDirectory $runDirectory -RangeLabel 'Browser regression fixture' -StaleAfterMinutes 525600
    $dashboardFiles = @(Get-ChildItem -LiteralPath $runDirectory -Filter 'group-*.html' -File)
    if ($dashboardFiles.Count -ne 1) {
        throw "Expected one generated interface dashboard, found $($dashboardFiles.Count)."
    }
    $dashboardPath = $dashboardFiles[0].FullName

    $mockedAncestors = Get-VerifiedCloudPlaceholderAncestors -Path $PSScriptRoot
    $null = Export-InterfaceBrowserReviewFixture -Inventory $inventory -Groups $groups `
        -Path $reviewPath -MockedAncestors $mockedAncestors
    if (-not (Test-Path -LiteralPath $dashboardPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
        throw 'Dashboard or graphical review fixture generation failed.'
    }

    $javascriptPath = Join-Path $PSScriptRoot 'Invoke-WUGInterfaceBrowserTest.js'
    if (-not (Test-Path -LiteralPath $javascriptPath -PathType Leaf)) {
        throw "Browser regression runner is missing: $javascriptPath"
    }
    $nodeArguments = @($javascriptPath, '--dashboard', $dashboardPath, '--review', $reviewPath)
    if ($PlaywrightModulePath) {
        $nodeArguments += @('--playwright-module', $PlaywrightModulePath)
    }
    if ($BrowserExecutablePath) {
        $nodeArguments += @('--browser-executable', $BrowserExecutablePath)
    }
    & $node.Source @nodeArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Playwright browser regression runner failed with exit code $LASTEXITCODE."
    }
}
finally {
    if ($fixtureOwned -and (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        $expectedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
        $fullRunDirectory = [IO.Path]::GetFullPath($runDirectory)
        if (-not $fullRunDirectory.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($fullRunDirectory) -notlike '.wug-interface-browser-test-*') {
            throw "Refusing to remove unexpected fixture directory: $fullRunDirectory"
        }
        Remove-Item -LiteralPath $fullRunDirectory -Recurse -Force -ErrorAction Stop
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC8d5LuTVBRbhlh
# i3mBuTmItV58/1cNroFK4/HaR69kEqCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDq
# NEg+Ndv8vBgbYQu9+nXQYWPTCUprx2rAVUY0o+1W0DANBgkqhkiG9w0BAQEFAASC
# AgCoF91/hTP3DDwETy/t5WIeHSNP1IX4vG5AUd4EWi0FZWNAceDVHBbxvXipA/JW
# go57eltm349heSSs1Hx5FYbnC0K8/7VM21NvLjh6qp4RE9pHe0uurD7Qm7+dSD+N
# FH5GgZBS7X3TDvHKazgcW+yWSKE9ENQqmwM0Q1L7jRkiQ2+CGLORcl4hO+QMkcgF
# IL8clXgMQ6xBsuefaQ9AGr3MHlWrLw5PKxVEl73dZJAhGj8DDT969pG1nu1cPgZy
# OJEpjw5cxozsjTCB2xdziWevYJ6HeH0ET5aQUgK/yWsol8JTLQE2wOTBY+3npk+G
# 8vyRst6VDjGMJaZT5nAcfCA+drQOJeZFwCnqZj/pTzGsxzDsYmFzqq2iZN2s2X3N
# 7lR4hb8O1w8IZyhR+G2EMIJ5ejr9eRTBqmBk0n48z9BLVWaQYpkfCATODGhH8WvS
# CxXxg6Sd+/UwhdRDRYEgJU7bIzKPWQZcWRGjkn0PNlDQRdcAyfZu6q1UKlvHkBvr
# nYORfFbGnt9UenLgbU3nc3Lx94LM/thbor/yfZKczm0MK7FV4PZMwL4hM+DTVAG1
# vIsO1yb760sFvT3qlZ5R9pquSDCqS46qqiTkH0Z6QNC0BzcRmImX+ikmsmVThFiJ
# 6/w5N6bz2pEIU60QKhyGV8dLNkJMiJeOY1xCI2QAYh4tNKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxOTA5NTVaMC8GCSqGSIb3DQEJBDEiBCBSkoYAeU2D
# 2hQnohSKyGiBEhGS6WRi4JZt10Ha+nGhGTANBgkqhkiG9w0BAQEFAASCAgAk22CY
# MI6whYrRUS+ef0da3PxJECTSWzzTo3DYxGfIOYXZ8U+/7kmgEXIaI+ZVYXyA/CVK
# S2TKpLWBfRg2D/cjzO8jVvPUvq4J6Cg1/zicCGi5J60kFfTTAyr6PtnToZ9yC5Gn
# XiYOtIR6QIw37/cbvY2ox46wnm6Bk1FtkRpFomGJtk1/3xOtr6EFjHRcfk3lONKz
# OZvFSSf8rhfrevIO9WHvd0UkhmEs3Rvl5RAsLaJyeDS8+LhvHZg6xo+C0S6AAN4C
# ukLs86tf8YFUy0A1RnulxeoUH/aGrkhutkbiL+1YWK+uut9FEMXmu4Ao6aXubdEK
# kpvCM5obFNtkaeOLK/ULvIy4ysFCchqdk9mcWdUcPABqJb5NaNNaYXetPZ3M7frU
# mJ5WI6QIaxTZd7wcsaWFmXFecXw6FCUdhqKWrx4imYcDEypU1wQVs3B7bpfeEsKo
# OIsKTIQqC8CY95tJlofDGXz/EFjeCibVjQ6IgX9vBAmOzNjgSgmQadZ27k2KbZ/4
# Z9inJ7LWkU/wLH/NABXIsbMFfQbrDr6276l+cuYC1XQq8Iq5TcviyOdrkICNMpYc
# dVF0NejqGyyzO1xnjmbhDV8J5Z4se2jIesLwgxXxUEoQGZDZ0NGX73eqtn7xgrMV
# 3Ke05n7YLtdRTiJNKnin3u+UF2cyA2RCIZ397Q==
# SIG # End signature block
