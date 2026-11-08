#requires -Version 5.1
<#
.SYNOPSIS
    Runs bounded offline dashboard publishing reliability regressions.
.DESCRIPTION
    Exercises staged validation, partial promotion/deletion rollback, recoverable
    rollback failure, interrupted-process recovery and cross-process locking.
    Uses an isolated fixture beneath the repository; no WUG or IIS is required.
.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -File .\helpers\test\Invoke-WUGDashboardPublishingReliabilityTest.ps1
.NOTES
    Throws on failure, bounds child-process waits and removes its owned fixture.
    Does not prove live IIS authentication or whole-pack atomicity.
.LINK
    ..\reports\DashboardPublishingHelpers.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\reports\DashboardPublishingHelpers.ps1')).Path
. $helper
$root = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ('.publishing-test-' + [guid]::NewGuid().ToString('N'))
$console = Join-Path $root 'Html\NmConsole'
$old = Join-Path $root 'profile-old'
$next = Join-Path $root 'profile-next'
$destination = Join-Path $console 'dashboards\reliability'
$savedProgramData = $env:ProgramData
$env:ProgramData = Join-Path $root 'ProgramData'
$storage = Join-Path $env:ProgramData 'WhatsUpGoldPS\DashboardPublishing'
$script:passed = 0
$script:fault = ''
$script:fired = $false
$script:restoreFailure = $false
$script:children = [Collections.Generic.List[object]]::new()
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected error '$Pattern', got '$message'."
}
function Write-Fixture {
    param([string]$Path, [string]$Value)
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($true))
}
function New-Pack {
    param([string]$Path, [int]$Count, [string]$Version)
    $null = New-Item -ItemType Directory -Path $Path -Force
    $groups = @(for ($i = 1; $i -le $Count; $i++) {
        Write-Fixture (Join-Path $Path ('group-{0:D2}.html' -f $i)) "<html>$Version group $i</html>"
        [pscustomobject]@{ Name = "Group$i" }
    })
    Write-Fixture (Join-Path $Path 'groups.json') (ConvertTo-Json -InputObject $groups)
    Write-Fixture (Join-Path $Path 'index.html') "<html>$Version index</html>"
}
function Get-Snapshot {
    param([string]$Path)
    (@(Get-ChildItem -LiteralPath $Path -File | Sort-Object Name | ForEach-Object {
        $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n")
}
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ($script:restoreFailure -and $LiteralPath -like '*\backup\*') { throw 'Injected restore failure' }
    $match = ($script:fault -eq 'stage-copy' -and $Destination -like '*\stage\*') -or
        ($script:fault -eq 'backup-copy' -and $Destination -like '*\backup\*') -or
        ($script:fault -eq 'promote-copy' -and $LiteralPath -like '*\stage\index.html')
    if ($match -and -not $script:fired) { $script:fired = $true; throw "Injected $script:fault failure" }
    if ($Destination -like '*\stage\*') {
        Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path $Destination -Parent) 'web.config')) 'Stage protection must precede HTML.'
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
    if ($script:fault -eq 'stage-hash' -and $Destination -like '*\stage\group-01.html' -and -not $script:fired) {
        $script:fired = $true
        Write-Fixture $Destination 'corrupted stage'
    }
    if ($script:fault -eq 'promote-hash' -and $LiteralPath -like '*\stage\index.html' -and -not $script:fired) {
        $script:fired = $true
        Write-Fixture $Destination 'corrupted promotion'
    }
}
function Remove-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    if ($script:fault -eq 'obsolete-delete' -and $LiteralPath -eq (Join-Path $destination 'group-03.html') -and -not $script:fired) {
        $script:fired = $true
        throw 'Injected obsolete deletion failure'
    }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
}
function Invoke-Case {
    param([string]$Name, [scriptblock]$Action)
    $script:fault = ''; $script:fired = $false; $script:restoreFailure = $false
    & $Action
    $script:passed++
    Write-Output "PASS: $Name"
}
function Start-FixtureProcess {
    param([string]$Code)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden
    $script:children.Add($process)
    $process
}
function Wait-FixtureProcess {
    param($Process, [int]$ExpectedExit = 0)
    if (-not $Process.WaitForExit(15000)) { throw 'Child process exceeded its 15-second bound.' }
    Assert-True ($Process.ExitCode -eq $ExpectedExit) "Child exit code: $($Process.ExitCode), expected $ExpectedExit."
}
try {
    $null = New-Item -ItemType Directory -Path $console -Force
    $null = New-Item -ItemType Directory -Path $env:ProgramData -Force
    Write-Fixture (Join-Path $console 'web.config') '<configuration><system.web><authentication mode="Forms" /></system.web></configuration>'
    $parentHash = (Get-FileHash -LiteralPath (Join-Path $console 'web.config')).Hash
    New-Pack $old 3 'old'
    New-Pack $next 1 'new'
    Invoke-Case 'WhatIf writes nothing' {
        Copy-WUGDashboardPack -SourcePath $old -NmConsolePath $console -PackName reliability -WhatIf | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $console 'dashboards'))) 'WhatIf created a web directory.'
        Assert-True (-not (Test-Path -LiteralPath $storage)) 'WhatIf created recovery state.'
    }
    Invoke-Case 'Initial complete protected publish excludes JSON' {
        $result = Copy-WUGDashboardPack -SourcePath $old -NmConsolePath $console -PackName reliability
        Assert-True ($result.FilesCopied -eq 4) 'Wrong initial file count.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $destination 'groups.json'))) 'Published raw JSON.'
    }
    Write-Fixture (Join-Path $destination 'custom.html') 'unrelated content'
    $baseline = Get-Snapshot $destination
    foreach ($faultName in @('stage-copy', 'stage-hash', 'backup-copy', 'promote-copy', 'promote-hash', 'obsolete-delete')) {
        Invoke-Case "$faultName leaves last-known-good unchanged" {
            $script:fault = $faultName
            Assert-Throws { Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName reliability } 'Injected|verification failed'
            Assert-True $script:fired 'Fault injection was not reached.'
            Assert-True ((Get-Snapshot $destination) -ceq $baseline) 'Last-known-good pack changed.'
        }
    }
    Invoke-Case 'Restore failure is explicit and retry recovers across profiles' {
        $script:fault = 'promote-copy'; $script:restoreFailure = $true
        Assert-Throws { Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName reliability } 'ROLLBACK FAILED.*Injected restore failure'
        $pending = @(Get-ChildItem -LiteralPath $storage -Filter pending.txt -Recurse)
        Assert-True ($pending.Count -eq 1) 'Failed recovery did not retain the journal.'
        $script:restoreFailure = $false; $script:fault = 'stage-copy'; $script:fired = $false
        Assert-Throws { Copy-WUGDashboardPack -SourcePath $old -NmConsolePath $console -PackName reliability } 'Injected stage-copy'
        Assert-True ((Get-Snapshot $destination) -ceq $baseline) 'Retry did not restore the complete old pack.'
        Assert-True (-not (Test-Path -LiteralPath $pending[0].FullName)) 'Recovery journal not cleared.'
    }
    Invoke-Case 'Terminated publisher is recovered before new staging' {
        $code = @'
$ErrorActionPreference = 'Stop'
. '__HELPER__'
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
    if ($LiteralPath -like '*\stage\group-01.html') { [Environment]::Exit(77) }
}
Copy-WUGDashboardPack -SourcePath '__SOURCE__' -NmConsolePath '__CONSOLE__' -PackName reliability | Out-Null
'@
        $process = Start-FixtureProcess ($code.Replace('__HELPER__', $helper.Replace("'", "''")).Replace('__SOURCE__', $next.Replace("'", "''")).Replace('__CONSOLE__', $console.Replace("'", "''")))
        Wait-FixtureProcess $process 77
        $script:fault = 'stage-copy'
        Assert-Throws { Copy-WUGDashboardPack -SourcePath $old -NmConsolePath $console -PackName reliability } 'Injected stage-copy'
        Assert-True ((Get-Snapshot $destination) -ceq $baseline) 'Interrupted pack not recovered.'
    }
    Invoke-Case 'Exclusive lock spans source profiles and processes, with bounded rejection' {
        $ready = Join-Path $root 'lock-ready.txt'
        $release = Join-Path $root 'lock-release.txt'
        $code = @'
$hash = [Security.Cryptography.SHA256]::Create()
$key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath('__DEST__').TrimEnd('\').ToUpperInvariant()))).Replace('-', '')
$hash.Dispose()
$mutex = [Threading.Mutex]::new($false, "Global\WhatsUpGoldPS-Dashboard-$key")
try {
    if (-not $mutex.WaitOne(0)) { exit 9 }
    [IO.File]::WriteAllText('__READY__', 'ready')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists('__RELEASE__') -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    $mutex.ReleaseMutex()
}
finally { $mutex.Dispose() }
'@
        $process = Start-FixtureProcess ($code.Replace('__DEST__', $destination.Replace("'", "''")).Replace('__READY__', $ready.Replace("'", "''")).Replace('__RELEASE__', $release.Replace("'", "''")))
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $ready) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path -LiteralPath $ready) 'Lock process did not become ready.'
        $clock.Restart()
        foreach ($profile in @($old, $next)) {
            Assert-Throws { Copy-WUGDashboardPack -SourcePath $profile -NmConsolePath $console -PackName reliability } 'already being published'
        }
        Assert-True ($clock.Elapsed.TotalSeconds -lt 3) 'Contending publish was not bounded.'
        Assert-True ((Get-Snapshot $destination) -ceq $baseline) 'Contending publish changed files.'
        Write-Fixture $release 'release'
        Wait-FixtureProcess $process
    }
    Invoke-Case 'Successful retry removes obsolete pages and preserves unrelated files and parent' {
        $result = Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName reliability
        Assert-True ($result.ObsoletePagesRemoved -eq 2) 'Wrong obsolete count.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'index.html')) -ceq '<html>new index</html>') 'Wrong new index.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'custom.html')) -ceq 'unrelated content') 'Unrelated file changed.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $console 'web.config')).Hash -eq $parentHash) 'Parent configuration changed.'
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $console 'dashboards') -Filter '*.json' -Recurse).Count -eq 0) 'JSON reached the web.'
    }
    Invoke-Case 'Failed first promotion leaves only verified protection and supports retry' {
        $first = Join-Path $console 'dashboards\first-failure'
        $script:fault = 'promote-copy'
        Assert-Throws { Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName first-failure } 'previous managed pack restored'
        Assert-True (@(Get-ChildItem -LiteralPath $first).Count -eq 1) 'Failed first publish left HTML.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $first 'web.config')).Contains('runAllManagedModulesForAllRequests="true"')) 'Failed first publish lost static protection.'
        $script:fault = ''
        $result = Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName first-failure
        Assert-True ($result.FilesCopied -eq 2) 'First-publish retry failed.'
    }
    Invoke-Case 'Directory disguised as obsolete generated page is rejected before staging' {
        $bad = Join-Path $destination 'group-99.html'
        $null = New-Item -ItemType Directory -Path $bad
        try {
            Assert-Throws { Copy-WUGDashboardPack -SourcePath $old -NmConsolePath $console -PackName reliability } 'unexpected type|regular'
        }
        finally { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $bad -Force }
    }
    Invoke-Case 'Reparse destination is rejected without touching its target' {
        $target = Join-Path $root 'junction-target'
        $junction = Join-Path $console 'dashboards\linked-pack'
        $null = New-Item -ItemType Directory -Path $target
        Write-Fixture (Join-Path $target 'sentinel.html') 'untouched'
        $null = New-Item -ItemType Junction -Path $junction -Target $target
        try {
            Assert-Throws { Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName linked-pack } 'reparse point'
            Assert-True ([IO.File]::ReadAllText((Join-Path $target 'sentinel.html')) -ceq 'untouched') 'Junction target changed.'
        }
        finally { [IO.Directory]::Delete($junction) }
    }
    Invoke-Case 'Unowned destination rejected without changes' {
        $unowned = Join-Path $console 'dashboards\unowned'
        $null = New-Item -ItemType Directory -Path $unowned
        Write-Fixture (Join-Path $unowned 'index.html') 'not ours'
        Assert-Throws { Copy-WUGDashboardPack -SourcePath $next -NmConsolePath $console -PackName unowned } 'cannot find|Cannot find|owned dashboard'
        Assert-True ([IO.File]::ReadAllText((Join-Path $unowned 'index.html')) -ceq 'not ours') 'Unowned destination was changed.'
    }
    Write-Output "Dashboard publishing reliability: $script:passed passed."
}
finally {
    $env:ProgramData = $savedProgramData
    foreach ($process in $script:children) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $root) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBgsvOGOY6kh8yi
# 3j0+goAKpq2kPtFnzjbjlCPojWHZDKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBe
# Se9rdoyIUFdfObbPC2mGPZi1CaRP/4vOkSOvgg3W7TANBgkqhkiG9w0BAQEFAASC
# AgC+uajuHSPaFAnqeLzE0zYCOEu28tBPZRQVxtvHP7udpEQNZBemWTzoOxAjK7ET
# 4XXA7itew0KjXGlBeZHyIjWRH5bgI21AmC8+d+AhZ5/FkrpzH6klk65GvSJf4G8c
# q5R3ZHebT41rI5iwurK89ldHeu5ZEO5G0ke5WWv9Hr5ET2m5PxfXypShsbiME489
# 1o/rfo8d5xw8DAyXuhBoe9IU19CFmJRBgIvv58db+2sf4/K5IZzXi/cFspGSum/F
# TvLEgR4GTb/TqCa1rap63V8j9Knyhhqr734WvfAH4K5dUrg1sLsPXwCx/9YE5Bep
# wiAvfOPvdw66fNpYBsMpucoK5CNhu5EhjKWEun+wpU2bF9TTCLxLgfDlW0nDzGAF
# ZRmdwcEewDcizb/cGySifvoQe+5x41KJEuDyr5YgNK3dxRYYpllJRVKnLjn40s+g
# qsmdkBGHB1KUzu+xx72QfKIJMbmCJTaf5MANHmKtG0A+VlwcbYNS+xFNMbfBjKLn
# +YS3c7ZVZSKukwbuWKVySrbiSlm3fmRt/YOpdux4wr7cQPLy6YmSvj6bpjc+U4DA
# qrfg/yCZ3etO1xBDWd921KjDda2N71ck4lYq4xotS629XTS+ziyGWIXHfgKA+qAq
# aCzwVFwUCxUrtIfuOdoyXGxiySbCuAH85fxKIdujnznoY6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxOTA5NDZaMC8GCSqGSIb3DQEJBDEiBCDoVoRti8Ni
# yI3zWVpXtitpY3NKSnMQ16NlUOPufwIZrjANBgkqhkiG9w0BAQEFAASCAgAL7Wdp
# kLK+/yiiSFi2v/1zYNYrZKL94dafhm3DEBmg774O+0djGQR+nXtErb/OZPw6aFtU
# QyMZT9b6tNys4q/loz3IhmhEor1EiAzL9Qv2XVSds2t6YDcY21QbG8+sPVHylU3g
# tXhjmYG8AvSRdmV7kZ68RGl8D3fE2a6VG8jYl95sFruBONYSfIA30elG7DJeLJwS
# tiRYAduh+FwZjrbCLOdBXzCj45PCRYc3rKVQeWZqfyTafhB1zZOm/4r0QL3yQC/C
# v/dS4n8XvjylyM2SF3osMLQBBfDNWTYL4n9NaYvNzk7FGQzUrBtr91ayxkiPK4vj
# esFbuj/nTKaTkA2JhuenCfkc/Vst4ACQYIuXIuwCcWKWBgh8dY/uA8xFox90Qp54
# SPAAber/TG91L+7Foug+EF7g2Z9CnhEGXyszYl9oBK9vY5wQf27T8sBEK1jMy7p2
# O8w8fU5wDXyOBnDyobeWezmejdH9Z+r2E9uITFoMRsnJy6dOhhM28POh1D8ju5CF
# yAUeOhlsD6ar2gNV6q8uOfgxRM1RnCJkjfx6a8Z6TLeDWvQgwqS5p28pDDYUPpwR
# 4YPrHzfwnbSIt/JPB6tnYSXJV1ezjMPUUPMJo3QjOqEaZ05b8Bthx9WzFoP2HBLG
# Cex2aMeOG0JoO3NJYE7WtWmPLNED7XmyMZPHkA==
# SIG # End signature block
