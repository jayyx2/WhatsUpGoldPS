#requires -Version 5.1
<#
.SYNOPSIS
    Runs offline recovery and safety regressions for local interface dashboard exports.
.DESCRIPTION
    Uses a staged exporter fixture; no WUG connection or external services are used.
.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -File .\helpers\test\Invoke-WUGInterfaceLocalExportTest.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$assetsPath = Join-Path $PSScriptRoot '..\reports\DashboardPublishingHelpers.ps1'
. (Resolve-Path -LiteralPath $assetsPath).Path
. (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupLocalExport.ps1')

$root = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ('.interface-local-export-test-' + [guid]::NewGuid().ToString('N'))
$savedProgramData = $env:ProgramData
$env:ProgramData = Join-Path $root 'ProgramData'
$script:destination = Join-Path $root 'output'
$script:storage = $null
$script:fault = ''
$script:faultFired = $false
$script:restoreFaultFired = $false
$script:stageHook = $null
$script:stageSawBaseline = $false
$script:stageRun = 0
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected error matching '$Pattern'; got '$message'."
}

function Write-FixtureFile {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true))
}

function Write-InterfaceGroupDashboardStage {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Groups,
        [string]$OutputDirectory,
        [string]$RangeLabel,
        [AllowEmptyCollection()][object[]]$Inventory,
        [int]$StaleAfterMinutes,
        [hashtable]$SnmpCoverage,
        [hashtable]$CollectionContext,
        [string]$CancellationPath
    )
    $script:stageRun++
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'inventory-snapshot.json')) {
        $script:stageSawBaseline = $true
    }
    $manifestGroups = @()
    foreach ($group in $Groups) {
        $page = Get-WUGDashboardGroupPageName -Name $group.Name
        $group | Add-Member -NotePropertyName PageName -NotePropertyValue $page -Force
        Write-FixtureFile (Join-Path $OutputDirectory $page) "<html>group $script:stageRun</html>"
        $manifestGroups += $group
    }
    Write-FixtureFile (Join-Path $OutputDirectory 'index.html') "<html>index $script:stageRun</html>"
    Write-FixtureFile (Join-Path $OutputDirectory 'groups.json') (ConvertTo-Json -InputObject @($manifestGroups) -Depth 10)
    Write-FixtureFile (Join-Path $OutputDirectory 'changes.json') '[]'
    Write-FixtureFile (Join-Path $OutputDirectory 'changes.csv') '"Change"'
    Write-FixtureFile (Join-Path $OutputDirectory 'inventory-snapshot.json') '{"SchemaVersion":2,"Interfaces":[],"LastKnownInterfaces":[],"ContextFingerprint":"fixture"}'
    if ($script:stageHook) { & $script:stageHook }
}

function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ($script:fault -eq 'promote-and-restore' -and -not $script:faultFired -and
        $LiteralPath -like "$script:storage\run-*\*" -and $Destination -like "$script:destination\groups.json") {
        $script:faultFired = $true
        throw 'Injected local promotion failure'
    }
    if ($script:fault -eq 'promote-and-restore' -and $script:faultFired -and -not $script:restoreFaultFired -and
        $LiteralPath -like "$script:storage\backup-*\*") {
        $script:restoreFaultFired = $true
        throw 'Injected local rollback failure'
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Action)
    $script:fault = ''
    $script:faultFired = $false
    $script:restoreFaultFired = $false
    $script:stageHook = $null
    & $Action
    $script:passed++
    Write-Output "PASS: $Name"
}

try {
    $null = New-Item -ItemType Directory -Path $root -Force
    $script:storage = Join-Path $env:ProgramData ('WhatsUpGoldPS\InterfaceGroups\LocalExport\' +
        (Get-InterfaceGroupLocalExportHash -Path ([IO.Path]::GetFullPath($script:destination))))
    $group = [pscustomobject]@{ Name = 'Router Ports'; Interfaces = @() }
    $inventory = @()

    Invoke-Case 'WhatIf does not create destination or ProgramData state' {
        $result = Export-InterfaceGroupDashboards -Groups @($group) -Inventory @() `
            -OutputDirectory $script:destination -WhatIf
        Assert-True ($result -eq (Join-Path $script:destination 'index.html')) 'WhatIf returned the wrong index path.'
        Assert-True (-not (Test-Path -LiteralPath $script:destination)) 'WhatIf created the destination.'
        Assert-True (-not (Test-Path -LiteralPath $env:ProgramData)) 'WhatIf created local staging state.'
    }

    Invoke-Case 'Initial export and nonmanaged file preservation' {
        $null = New-Item -ItemType Directory -Path $script:destination -Force
        Write-FixtureFile (Join-Path $script:destination 'review.csv') 'keep review'
        Write-FixtureFile (Join-Path $script:destination 'unrelated.txt') 'keep unrelated'
        $result = Export-InterfaceGroupDashboards -Groups @($group) -Inventory $inventory `
            -OutputDirectory $script:destination -CollectionContext @{ DeviceId = 42 }
        Assert-True ($result -eq (Join-Path $script:destination 'index.html')) 'Export did not return final index path.'
        Assert-True ((Get-Content (Join-Path $script:destination 'review.csv') -Raw).Trim() -eq 'keep review') 'Review CSV changed.'
        Assert-True ((Get-Content (Join-Path $script:destination 'unrelated.txt') -Raw).Trim() -eq 'keep unrelated') 'Unrelated file changed.'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:destination 'inventory-snapshot.json')) 'Snapshot not promoted.'
    }

    $baselineIndex = (Get-FileHash -LiteralPath (Join-Path $script:destination 'index.html') -Algorithm SHA256).Hash
    Invoke-Case 'Prior snapshot is copied into stage for comparison' {
        $script:stageSawBaseline = $false
        $null = Export-InterfaceGroupDashboards -Groups @($group) -Inventory $inventory -OutputDirectory $script:destination
        Assert-True $script:stageSawBaseline 'The previous snapshot was not provided to the stage exporter.'
    }
    $baselineIndex = (Get-FileHash -LiteralPath (Join-Path $script:destination 'index.html') -Algorithm SHA256).Hash

    Invoke-Case 'Partial promotion rollback is retained and recovers on next call' {
        $script:fault = 'promote-and-restore'
        Assert-Throws {
            Export-InterfaceGroupDashboards -Groups @($group) -Inventory $inventory -OutputDirectory $script:destination
        } 'ROLLBACK FAILED.*Injected local rollback failure'
        Assert-True $script:faultFired 'Promotion failure was not injected.'
        Assert-True $script:restoreFaultFired 'Rollback failure was not injected.'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:storage 'pending.json')) 'Recovery journal was not retained.'
        $script:fault = ''
        $null = Export-InterfaceGroupDashboards -Groups @($group) -Inventory $inventory -OutputDirectory $script:destination
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:storage 'pending.json'))) 'Recovery journal was not cleared.'
        Assert-True ((Get-Content (Join-Path $script:destination 'review.csv') -Raw).Trim() -eq 'keep review') 'Recovery changed review CSV.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $script:destination 'index.html') -Algorithm SHA256).Hash -ne $baselineIndex) `
            'The subsequent successful export did not replace the previous index.'
    }

    Invoke-Case 'Cancellation after staging leaves current output unchanged' {
        $before = (Get-FileHash -LiteralPath (Join-Path $script:destination 'index.html') -Algorithm SHA256).Hash
        $signal = Join-Path $root 'cancel.signal'
        $script:stageHook = { Write-FixtureFile $signal 'cancel' }
        Assert-Throws {
            Export-InterfaceGroupDashboards -Groups @($group) -Inventory $inventory `
                -OutputDirectory $script:destination -CancellationPath $signal
        } 'cancelled by signal file'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $script:destination 'index.html') -Algorithm SHA256).Hash -eq $before) `
            'Cancellation modified the current output.'
    }

    Invoke-Case 'Unmarked managed filename is never overwritten' {
        $unmarked = Join-Path $root 'unmarked'
        $null = New-Item -ItemType Directory -Path $unmarked -Force
        Write-FixtureFile (Join-Path $unmarked 'index.html') 'unowned'
        Assert-Throws {
            Export-InterfaceGroupDashboards -Groups @($group) -Inventory $inventory -OutputDirectory $unmarked
        } 'Unmarked local destination already contains a managed filename'
        Assert-True ((Get-Content (Join-Path $unmarked 'index.html') -Raw).Trim() -eq 'unowned') 'Unowned file was changed.'
    }

    Invoke-Case 'Empty group set is supported for local exports' {
        $empty = Join-Path $root 'empty'
        $result = Export-InterfaceGroupDashboards -Groups @() -Inventory @() -OutputDirectory $empty
        Assert-True ($result -eq (Join-Path $empty 'index.html')) 'Empty export returned the wrong path.'
        $emptyManifest = [regex]::Replace((Get-Content (Join-Path $empty 'groups.json') -Raw), '\s', '')
        Assert-True ($emptyManifest -eq '[]') "Empty groups manifest is invalid: $emptyManifest"
    }

    . (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupingHelpers.ps1')
    Invoke-Case 'Real two-group export returns exactly one scalar final index path' {
        $rows = @(foreach ($i in 1..2) {
            [pscustomobject]@{
                DeviceId = 42; DeviceName = 'Fixture Router'; IfIndex = $i
                InterfaceName = "eth$i"; InterfaceComment = "Group$i"; Status = 'Up'
                ActiveAssignmentIds = @($i); TrafficInterfaceIds = @($i)
                TrafficAvailable = $true; PerformanceEnabled = $true
                RxBps = 1000; TxBps = 2000; RxPercent = 1; TxPercent = 2
                PollTimeUtc = [DateTime]::UtcNow.ToString('o'); Samples = @()
            }
        })
        $realGroups = @(Select-InterfaceGroups -Inventory $rows -GroupName Group1,Group2)
        $realPath = Join-Path $root 'real-two-groups'
        $result = @(Export-InterfaceGroupDashboards -Groups $realGroups -Inventory $rows -OutputDirectory $realPath)
        Assert-True ($result.Count -eq 1 -and $result[0] -is [string]) 'Real exporter emitted extra success output.'
        Assert-True ($result[0] -eq (Join-Path $realPath 'index.html')) 'Real exporter returned a staging path.'
        $bytes = [IO.File]::ReadAllBytes($result[0])
        Assert-True ([BitConverter]::ToString($bytes[0..2]) -eq 'EF-BB-BF') 'Final index lacks UTF-8 BOM.'
        Assert-True (@(Get-ChildItem -LiteralPath $realPath -Filter 'group-*.html').Count -eq 2) 'Real export did not generate two group pages.'
    }
    Invoke-Case 'Real 2000-interface 16-group export meets bounded size and duration' {
        $rows = @(foreach ($i in 1..2000) {
            [pscustomobject]@{
                DeviceId = 42; DeviceName = 'Scale Router'; IfIndex = $i
                InterfaceName = "eth$i"; InterfaceComment = ('Scale{0}' -f (($i - 1) % 16))
                Status = 'Up'; ActiveAssignmentIds = @($i); TrafficInterfaceIds = @($i)
                TrafficAvailable = $true; PerformanceEnabled = $true
                RxBps = 1000; TxBps = 2000; RxPercent = 1; TxPercent = 2
                PollTimeUtc = [DateTime]::UtcNow.ToString('o'); Samples = @()
            }
        })
        $scaleGroups = @(Select-InterfaceGroups -Inventory $rows -GroupName @(0..15 | ForEach-Object { "Scale$_" }))
        $scalePath = Join-Path $root 'real-scale'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = @(Export-InterfaceGroupDashboards -Groups $scaleGroups -Inventory $rows -OutputDirectory $scalePath)
        $watch.Stop()
        $size = (Get-ChildItem -LiteralPath $scalePath -File | Measure-Object -Property Length -Sum).Sum
        Assert-True ($result.Count -eq 1 -and $result[0] -is [string]) 'Scale export emitted extra success output.'
        Assert-True ($result[0] -eq (Join-Path $scalePath 'index.html')) 'Scale export returned a staging path.'
        Assert-True (@(Get-ChildItem -LiteralPath $scalePath -Filter 'group-*.html').Count -eq 16) 'Scale export did not generate 16 pages.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 90) "Scale export exceeded 90 seconds: $($watch.Elapsed.TotalSeconds)"
        Assert-True ($size -lt 50MB) "Scale export exceeded 50 MiB: $size bytes"
        Write-Output ('Scale: {0:N2}s, {1:N2} MiB' -f $watch.Elapsed.TotalSeconds, ($size / 1MB))
    }
    Invoke-Case 'Real machine ProgramData staging works without a user temporary root' {
        $machinePath = Join-Path $root 'machine-programdata'
        $machineStorage = Join-Path $savedProgramData ('WhatsUpGoldPS\InterfaceGroups\LocalExport\' +
            (Get-InterfaceGroupLocalExportHash -Path ([IO.Path]::GetFullPath($machinePath))))
        Assert-True (-not (Test-Path -LiteralPath $machineStorage)) 'Machine fixture recovery directory unexpectedly exists.'
        $fixtureProgramData = $env:ProgramData
        try {
            $env:ProgramData = $savedProgramData
            $result = @(Export-InterfaceGroupDashboards -Groups @() -Inventory @() -OutputDirectory $machinePath)
            Assert-True ($result.Count -eq 1 -and $result[0] -eq (Join-Path $machinePath 'index.html')) `
                'Machine ProgramData export returned unexpected output.'
            Assert-True (Test-Path -LiteralPath (Join-Path $machineStorage 'ownership.json')) `
                'Machine ProgramData ownership state was not created.'
        }
        finally {
            $env:ProgramData = $fixtureProgramData
            if (Test-Path -LiteralPath $machineStorage) {
                Remove-Item -LiteralPath $machineStorage -Recurse -Force -ErrorAction Stop
            }
        }
    }

    Write-Output "Passed $script:passed local interface export regression cases."
}
finally {
    $env:ProgramData = $savedProgramData
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAZRuTWLgyNLpHB
# HzklqYNs7VIbxCP5GaZZvhk/MhMqy6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCY
# svmrv5rvyCLljr1XQJyPzEA2eTcWC6/K300re1m3ujANBgkqhkiG9w0BAQEFAASC
# AgCkryNvhQsLR13+zI8oXbKC8QH8uCXG6MSo7fsRM2GpiQv0lfGBviPc2HL0mMWv
# UMvDXMTPrlCBFdxqLBmchuQkNjnnqb6px7Xhr2DGl3BTNCATomHv+eoMAWxW04mG
# jjeW6G7p2+RdMB6KyYdrAVXIJl7QTu3WluX/VxLFC+bsmezuML2+gLL7ARF7Ugb3
# 5Z6NsTaUQem6OQzU+Ey4xCsUItn+B09av3sTsl2rkr9DLrEmIaLm56ec5zW2THQb
# 8HbHrVN7h1IQm3prOXjFxUDstDUej6Cadw66Fj5JlEDankPLb2WQP7VdmnHJdHeS
# RlEJB25FhDq2F1NsNdXksy+FoBltEunGexqJQXj5gvkU10ytNR68NzA+/X7zp9J/
# eLxV020F4vofxjGAdqUkCQfQgHsXDDw/8J3Z3zpF+1OeslzNEUekvj2ewlgWMzn+
# nlp7PCf320GLT4sy9mmyuOH4zNVuW1pFeHZ7B3q7DwYM0VCXmKkQ4s3FFFzJbKUT
# 3P8w12Gm+LU0REh/788EofZBs0+vWHt3g8vn6J+7mWf+wpicbpcc00vyRGov8tgm
# kwfgyOFBfeXmia4d2R3XzqdRwS07wlGqWfsB8dwReuP0A/5sdlxqsNbXYGId2g8r
# fLnZagPhcOHxJdZys1r+PN1Z188G+gEyOgzk37aCDEFU2aGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxOTEwMDNaMC8GCSqGSIb3DQEJBDEiBCDivXfKIdmi
# x+s+hq2LG35sRveXKMC8H/ronB1k5vkvnjANBgkqhkiG9w0BAQEFAASCAgB7PNZm
# 7Z3GfcWZ/7EtrPXnME3ndPL3TXAlnVx69xxSWjxzGpj2BhKwFNtboKfGf7yYUy9w
# V4OjOEwcIZ+0QX//aZKs1sWRJoqqk+dSQc/UH4BH7ojUxOiXjAL67tYRy3Ih5vXh
# NUVPtLpxi4raRhZYiam6PxrjVchKF0iOqqTxFCBsKpXnyAW4mGkN+WEZjb8YpZcn
# +7qS+cLexyBmwg0p2W/9teVK6F001WwunpLjhYOCn/756kPB8TjCzTtwJFxJgMfi
# o3sp03uoyCur4SsbTmhzdr84is9OJSiALIL/MIYcS7wHU003IC0FyUiQvnGtPyRt
# /WHrQbTbIwVSENJ9GCLengO1rgHqFUHfljC3YMqDfv3EInyfmWTEUPlhSV7j5LV2
# fCh/fh63sIWQteZBWO97dJwEcyMJyteB38UcYmg/CoGGg4COgImiJkKqRgIi3VHq
# q/zNZfm+FMDDOHxm4Walg20jltAHvJsSoD75fL9WhiPGNEf4PM+wYeG3yG9nN1mU
# ewdAtUONZhMDct75tuj51tr1HR5NNhwvYAGvIbuZn/qxdZdYytgIkjGi072YZjEG
# q0rVCdO5bz5h40Yxz5sccrzfJW6G2vHsxVR4VlRG6FOMT7d0P9hTok5rmJWdy08v
# TneMYCqfD86Mu/n3wFz6Y0R89n//qr9kZsGS7w==
# SIG # End signature block
