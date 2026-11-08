#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupOperations.ps1')
$root=Join-Path $env:TEMP ('WUG-InterfaceOperations-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$passed=0
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Invoke-Case { param([string]$Name,[scriptblock]$Body) & $Body; $script:passed++; "PASS: $Name" }
$savedLocal=$env:LOCALAPPDATA;$savedProgram=$env:ProgramData
$savedServer=$global:WhatsUpServerBaseURI;$savedHeaders=$global:WUGBearerHeaders;$savedExpiry=$global:expiry
try {
    $env:LOCALAPPDATA=Join-Path $root 'local';$env:ProgramData=Join-Path $root 'program'
    $global:WhatsUpServerBaseURI='https://offline.fixture';$global:WUGBearerHeaders=@{Authorization='Bearer fixture'};$global:expiry=(Get-Date).AddDays(1)
    $pack=Join-Path $root 'pack';$null=New-Item -ItemType Directory -Path $pack
    $profile=Join-Path $root 'profile.json'
    $null=Save-InterfaceGroupProfile -Path $profile -Settings @{DeviceId=@(1);Mode='AllInterfaces';OutputDirectory=$pack}
    Invoke-Case 'Readiness is metadata-only by default and never claims fully verified' {
        function Invoke-RestMethod { throw 'Unexpected network access' }
        $r=Test-InterfaceGroupReadiness -ProfilePath $profile
        Assert-True ($r.ReadyToAttempt -and -not $r.FullyVerified) 'Readiness must distinguish attempted from verified.'
        Assert-True (@($r.Checks | Where-Object Status -eq Unverified).Count -gt 0) 'Unverified checks must be visible.'
    }
    Invoke-Case 'Write probes clean up exact files and WhatIf creates nothing' {
        $r=Test-InterfaceGroupReadiness -ProfilePath $profile -TestWriteAccess
        Assert-True (@($r.Checks | Where-Object { $_.Check -eq 'Output write access' -and $_.Status -eq 'Passed' }).Count -eq 1) 'Writable target failed.'
        Assert-True (@(Get-ChildItem $pack -Force).Count -eq 0) 'Probe leaked a file.'
        $null=Test-InterfaceGroupReadiness -ProfilePath $profile -CheckApi -TestWriteAccess -WhatIf
        Assert-True (@(Get-ChildItem $pack -Force).Count -eq 0) 'WhatIf wrote a file.'
    }
    Invoke-Case 'Readiness reports invalid profile without success-shaped result' {
        $bad=Join-Path $root 'bad.json'
        [IO.File]::WriteAllText($bad,'{"SchemaVersion":1,"Settings":{"AllDevices":true,"Password":"fixture"}}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $bad -WarningAction SilentlyContinue
        Assert-True (-not $r.ReadyToAttempt) 'Bad profile marked ready.'
    }
    Invoke-Case 'SNMP metadata expiry and missing fields fail without decrypting secrets' {
        $vault=Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
        $null=New-Item -ItemType Directory -Path $vault -Force
        $snmp=Join-Path $root 'snmp.json'
        $null=Save-InterfaceGroupProfile -Path $snmp -Settings @{DeviceId=@(1);UseSnmp=$true;SnmpCredentialNames=@('Fixture.V3');SnmpCredentialVersions=@('V3');OutputDirectory=$pack}
        [IO.File]::WriteAllText((Join-Path $vault 'Fixture.V3.cred'),'{"Type":"Bundle","FieldNames":["Username"],"ExpiresUtc":"2000-01-01T00:00:00Z"}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp -WarningAction SilentlyContinue
        Assert-True (-not $r.ReadyToAttempt) 'Expired/incomplete entry marked ready.'
        [IO.File]::WriteAllText((Join-Path $vault 'Fixture.V3.cred'),'{"Type":"Bundle","FieldNames":["Username","AuthProtocol","PrivacyProtocol"]}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp
        Assert-True $r.ReadyToAttempt 'Valid credential metadata rejected.'
        Assert-True (@($r.Checks | Where-Object { $_.Check -like 'SNMP credential:*' -and $_.Status -eq 'Unverified' }).Count -eq 1) 'Secret/device access must remain unverified.'
        $thrown=$false
        try { $null=Save-InterfaceGroupProfile -Path $snmp -Settings @{DeviceId=@(1);UseSnmp=$true;SnmpCredentialNames=@('..\outside');SnmpCredentialVersions=@('V2')} } catch { $thrown=$true }
        Assert-True $thrown 'Path-like vault reference allowed.'
    }
    Invoke-Case 'SNMP readiness gives specific version and expiry fixes without exposing stored values' {
        $vault=Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
        $path=Join-Path $vault 'Fixture.Mismatch.cred'
        $snmp=Join-Path $root 'mismatch.json'
        $null=Save-InterfaceGroupProfile -Path $snmp -Settings @{DeviceId=@(1);UseSnmp=$true;SnmpCredentialNames=@('Fixture.Mismatch');SnmpCredentialVersions=@('V2');OutputDirectory=$pack}
        [IO.File]::WriteAllText($path,'{"Type":"Bundle","FieldNames":["Username","AuthProtocol","PrivacyProtocol"],"EncryptedFields":{"Username":"fixture-private-marker"}}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp -WarningAction SilentlyContinue
        $check=$r.Checks | Where-Object Check -like 'SNMP credential:*'
        Assert-True ($check.Status -eq 'Failed' -and $check.Detail -like "*Community*select V3*") 'V3-as-V2 rejection needs a specific fix.'
        Assert-True (($r | ConvertTo-Json -Depth 6) -notlike '*fixture-private-marker*') 'Readiness leaked stored data.'
        $null=Save-InterfaceGroupProfile -Path $snmp -Settings @{DeviceId=@(1);UseSnmp=$true;SnmpCredentialNames=@('Fixture.Mismatch');SnmpCredentialVersions=@('V3');OutputDirectory=$pack}
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp
        Assert-True $r.ReadyToAttempt 'Matching V3 metadata should be accepted without decrypting.'
        [IO.File]::WriteAllText($path,'{"Type":"Single","ExpiresUtc":"2000-01-01T00:00:00Z"}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp -WarningAction SilentlyContinue
        Assert-True (($r.Checks | Where-Object Check -like 'SNMP credential:*').Detail -like '*expired*rotate*') 'Expiry reason hidden.'
        [IO.File]::WriteAllText($path,'{"Type":"Bundle","ExpiresUtc":"fixture-private-invalid-date"}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp -WarningAction SilentlyContinue
        Assert-True (($r.Checks | Where-Object Check -like 'SNMP credential:*').Detail -like '*expiry metadata is invalid*') 'Invalid date reason hidden.'
        Assert-True (($r | ConvertTo-Json -Depth 6) -notlike '*fixture-private-invalid-date*') 'Exception text leaked invalid metadata.'
        [IO.File]::WriteAllText($path,'{"Type":"Single"}',[Text.UTF8Encoding]::new($true))
        $r=Test-InterfaceGroupReadiness -ProfilePath $snmp -WarningAction SilentlyContinue
        Assert-True (($r.Checks | Where-Object Check -like 'SNMP credential:*').Detail -like '*SNMPv3 requires a Bundle*') 'Single-as-V3 rejection needs a specific fix.'
    }
    Invoke-Case 'API preflight performs one device read and no monitors or report collection' {
        $calls=0
        function Get-WUGDevice { [CmdletBinding()]param($DeviceId,$View) $script:preflightCalls++; [pscustomobject]@{id=$DeviceId;displayName='Fixture'} }
        $script:preflightCalls=0
        $r=Test-InterfaceGroupReadiness -ProfilePath $profile -CheckApi
        Assert-True ($script:preflightCalls -eq 1) 'Preflight unexpectedly collected devices/reports.'
        Assert-True (@($r.Checks | Where-Object { $_.Check -eq 'API read' -and $_.Status -eq 'Passed' }).Count -eq 1) 'API preflight result missing.'
    }
    Invoke-Case 'Status preserves last successful export separately from failure and preview' {
        $logs=Join-Path $root 'logs';$null=New-Item -ItemType Directory -Path $logs
        $success=[pscustomobject]@{ProfilePath=$profile;Success=$true;PreviewOnly=$false;FinishedUtc=[DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o');Health=@{Interfaces=2};SnmpCoverage=@{'1'='Partial'};Publication=@{AuthenticationVerified=$false}}
        $failure=[pscustomobject]@{ProfilePath=$profile;Success=$false;PreviewOnly=$false;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error='fixture failure'}
        [IO.File]::WriteAllText((Join-Path $logs 'last-success.json'),($success | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $logs 'latest-result.json'),($failure | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $logs ('run-20260101T100000000-' + ('a'*32) + '.json')),($failure | ConvertTo-Json),[Text.UTF8Encoding]::new($true))
        $r=Get-InterfaceGroupStatus -ProfilePath $profile -LogDirectory $logs
        Assert-True ($r.ExportAgeMinutes -ge 10 -and $r.Health.Interfaces -eq 2) 'Export status lost after failure.'
        Assert-True ($r.LatestFailure.Error -eq 'fixture failure' -and -not $r.AuthenticationVerified) 'Failure/auth status misleading.'
    }
    Invoke-Case 'Status includes only exact owned profile tasks and actual task info' {
        function Get-ScheduledTask {
            [CmdletBinding()]param()
            [pscustomobject]@{TaskName='InterfaceGroups-Fixture';TaskPath='\WhatsUpGoldPS\';Description="WhatsUpGoldPS InterfaceGroups profile refresh; profile=$profile";State='Ready';Principal=@{LogonType='S4U'}}
            [pscustomobject]@{TaskName='Other';Description='Unowned'}
        }
        function Get-ScheduledTaskInfo { [CmdletBinding()]param($TaskName,$TaskPath) [pscustomobject]@{LastTaskResult=5;LastRunTime=(Get-Date);NextRunTime=(Get-Date).AddHours(1)} }
        $r=Get-InterfaceGroupStatus -ProfilePath $profile -IncludeScheduledTasks
        Assert-True ($r.ScheduledTasks.Count -eq 1 -and $r.ScheduledTasks[0].LastTaskResult -eq 5) 'Task status filtering/result incorrect.'
    }
    Invoke-Case 'Cancellation file stops before any API call and remains available for operator cleanup' {
        $signal=Join-Path $root 'cancel.signal';[IO.File]::WriteAllText($signal,'cancel')
        function Get-WUGDevice { throw 'API must not be reached' }
        $thrown=$false
        try { $null=Get-InterfaceGroupInventory -DeviceId 1 -CancellationPath $signal } catch { $thrown=$_.Exception -is [OperationCanceledException] }
        Assert-True $thrown 'Cancellation did not terminate explicitly.'
        Assert-True (Test-Path $signal) 'Cancellation file should not be removed by collector.'
    }
    Invoke-Case 'Collection uses existing transient retry count without leaking scoped defaults' {
        function Get-WUGDevice { [CmdletBinding()]param($DeviceId,$View) [pscustomobject]@{id=$DeviceId;displayName='Fixture'} }
        function Get-WUGDeviceReport { [CmdletBinding()]param($DeviceId,$ReportType,$Range,$Limit,$RangeN) }
        $script:reads=0;$script:sleeps=0
        function Start-Sleep { param($Seconds) $script:sleeps++ }
        function Invoke-RestMethod { [CmdletBinding()]param($Uri,$Method,$Headers,$Body) $script:reads++;if ($script:reads -eq 1) { throw [Net.WebException]::new('fixture timeout',[Net.WebExceptionStatus]::Timeout) };[pscustomobject]@{data=@();paging=@{}} }
        $before=$PSDefaultParameterValues['Get-WUGAPIResponse:MaxRetries']
        $null=Get-InterfaceGroupInventory -DeviceId 1 -ApiMaxRetries 1
        Assert-True ($script:reads -eq 2 -and $script:sleeps -eq 1) 'Transient retry policy was not honored.'
        Assert-True ($PSDefaultParameterValues['Get-WUGAPIResponse:MaxRetries'] -eq $before) 'Retry defaults leaked into caller.'
        $script:reads=0;$thrown=$false
        try { $null=Get-InterfaceGroupInventory -DeviceId 1 -ApiMaxRetries 0 } catch { $thrown=$true }
        Assert-True ($thrown -and $script:reads -eq 1) 'Retry disable did not work.'
    }
    Invoke-Case 'Group cards preserve zero vs unavailable, deduplicate overlaps and reject future/invalid rates' {
        $row=[pscustomobject]@{DeviceId=1;IfIndex=1;DeviceName='Fixture';InterfaceComment='GroupA';ActiveAssignmentIds=@('a');Status='Down';PollTimeUtc=[DateTime]::UtcNow.ToString('o');Freshness='Fresh';RxBps=0;TxBps=0}
        $future=[pscustomobject]@{DeviceId=1;IfIndex=2;DeviceName='Fixture';ActiveAssignmentIds=@();Status='Unmonitored';PollTimeUtc='future';Freshness='Future';RxBps=100;TxBps=200}
        $r=Get-InterfaceGroupCardSummary -Inventory @($row,$row,$future)
        Assert-True ($r.Monitored -eq 1 -and $r.Unmonitored -eq 1 -and $r.Down -eq 1) 'Card counts are incorrect.'
        Assert-True ($r.RateRows -eq 1 -and $r.RxBps -eq 0) 'Zero lost or future included.'
        Assert-True ((Get-InterfaceGroupCardSummary -Inventory @($future)).RxBps -eq $null) 'Unavailable traffic converted to zero.'
        $summary=Get-InterfaceGroupSelectionSummary -Inventory @($row,$future) -Groups @([pscustomobject]@{Name='A';Interfaces=@($row)},[pscustomobject]@{Name='B';Interfaces=@($row)})
        Assert-True ($summary.Unmatched -eq 1 -and $summary.Overlapping -eq 1 -and $summary.MembershipCount -eq 2) 'Review overlap/unmatched counts are incorrect.'
    }
    Invoke-Case 'Large inventory grouping and export meet explicit runtime, size and output-shape limits' {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $rows=@(foreach ($index in 1..2000) {
            [pscustomobject]@{DeviceId=1;IfIndex=$index;DeviceName='Large Fixture';InterfaceComment=('Group' + (($index-1)%16));InterfaceName='';Status='Up';ActiveAssignmentIds=@('a');PerformanceAssignmentIds=@('p');PerformanceEnabled=$true;PollTimeUtc=[DateTime]::UtcNow.ToString('o');RxBps=$index;TxBps=$index;Samples=@()}
        })
        $groups=@(Select-InterfaceGroups -Inventory $rows -GroupName @(0..15 | ForEach-Object { "Group$_" }) -MatchMode Exact)
        Assert-True ($groups.Count -eq 16 -and ($groups | Measure-Object InterfaceCount -Sum).Sum -eq 2000) 'Large grouping output is incorrect.'
        $large=Join-Path $root 'large';$null=Export-InterfaceGroupDashboards -Groups $groups -Inventory $rows -OutputDirectory $large
        $watch.Stop();$bytes=(Get-ChildItem -LiteralPath $large -File | Measure-Object Length -Sum).Sum
        Assert-True ($watch.Elapsed.TotalSeconds -lt 90) "2000-row/16-group export exceeded 90 seconds: $($watch.Elapsed.TotalSeconds)."
        Assert-True ($bytes -lt 50MB) "2000-row pack exceeded 50 MiB: $bytes."
        Assert-True (@(Get-ChildItem -LiteralPath $large -Filter 'group-*.html').Count -eq 16) 'Missing large group pages.'
        "METRIC: 2000 rows / 16 groups; $([Math]::Round($watch.Elapsed.TotalSeconds,2)) seconds; $([Math]::Round($bytes/1MB,2)) MiB."
    }
    "$passed operation tests passed."
}
finally {
    $env:LOCALAPPDATA=$savedLocal;$env:ProgramData=$savedProgram
    $global:WhatsUpServerBaseURI=$savedServer;$global:WUGBearerHeaders=$savedHeaders;$global:expiry=$savedExpiry
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD4P76XTO5MgJ64
# 8/k9qDQHW05HyDgptqUrpf4dfZhKR6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCC6
# CS9zO6F0WXslWG+COhBpulJdLXOU0t6lS/8m+QniHTANBgkqhkiG9w0BAQEFAASC
# AgBBlDJGyCsksW7iN+KvmTbY0TDmicKTZ7Qggj2eJT5vKOSSoKLXkOoNKz7PLM+4
# e3N08jYMoLAh+X/t3ShNWvms+dHZU/QP4Kg5lmwolFvwPPHb8QV9VWEUBrw772a6
# cSBQyC5fDOcLQFnQY2AM6+bmXJ5bZJu4RaOBF96WHGXow3+oQp+3TD5Tk29gpbkn
# adFDYX/w8S3+PHN1XrdCoB3iXjalTSrA2bLqYs5iFINX3rvL2mUIXiAkFwjfPyqo
# ZhOLlNEntT7xXt4B4ufdzfFOjMhd7CEELGdLhjTs3Nlpm4BNSi2kk/7XAKkTFdY/
# FKcCJOHM4BaYJE8iZClGr7UpoEvdcff2Otuk98l1sQHlQdNfBVv0oF8YTyMgDLU7
# Oi5HPuWsvy31cXSdbBMM/JL4f0gL1Fc4guA5/iVHxaVsRJhclq9RhbLzpw+DaTzW
# qvsNF4Ac0qmF4wd4jZO4m9w8jbq4rmGsFNbQxzxvFfEdoMyXJX3lEBzWidtvNz2+
# CGrb2FunqOXnRjutNxjGNJCNTwCy2esm9jrkNlvNrXs6okFqHSeZSc8HlM3wPbk7
# /Mfa+gLU7O/4Rg58KxsldeLHEyuP4DAvdNfSdreEk0g3Nq68ty+gCA7s6u0MplqE
# UGPPoLbDYP5JSGRRsC9lX9whvI5UpyGRP5sSCBoYrazCiKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxOTE4MzRaMC8GCSqGSIb3DQEJBDEiBCDhWFF3t3DV
# 6q7rKsweicgZTP9x5anRnQtGxUCGv08F4jANBgkqhkiG9w0BAQEFAASCAgBSP6Nf
# EN7UoLumnfpjtucXVBRc3Cl69HnwOFQTTjPaBGffdk0iCNi8UVoJtM9+NfZZP/VP
# J9fBgSwmmlY5QvOj1+Tr7yqyJeUDeFGrjuazAtfOqez8g/rjLaaIe8OJkN+7RZRi
# LF/bBL6a9qxej96YDbw2/C6AUE0w57FFn8JMcyBzHNSWM1Ezi/Qt4OR+46B+S7Qe
# rpp1kaNTSjlahN14fHdoJf7iLS2x3/cKlWlqc5mLx+lVHTlA7oPwzRVXLqZ3SGvn
# 7NU70O8fIdVFBXoQ4mk0t8ehrtjWB+jwmLhb53d5LEuyExSVSsCof0VLMhwzJWJw
# jrczqO6LFToicGML0XmXi78WoxTF7GUU4oPZ8Fej7Fj20HAYBXUX7o9rz5jQrvN9
# WaNmc7DBAJ+cAapGXOaH+QyHhpxHm4hiN8GefnQZ8Q+XWquq1KfX9eMbyTHZ6kCg
# 4s57RPAoqQEMgYl2XJ7TPgdUC7MhE8TVstNMi/jNFLezjQl8Ww9fIqU0E54vXfeH
# 6b0a8ShcxnBxkwi4ERDTzIsqxbymTFPSYI22vNCa0/TA67Ct24j4CZX5tp30wbyq
# EUKzYuP7uA/ilOFxpnPhrBh2M7kRcEae4qzCuYhpGTnDN7YBC5k6ybOjKVYVbDgg
# OAYRXgnyRTq7/GaRI7g4ra4C62w4chRywyA8gg==
# SIG # End signature block
