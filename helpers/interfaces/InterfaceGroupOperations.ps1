#requires -Version 5.1
. (Join-Path $PSScriptRoot 'InterfaceGroupingHelpers.ps1')

function Test-InterfaceGroupReadiness {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [switch]$CheckApi,
        [switch]$TestWriteAccess
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $settings = $null
    try {
        $settings = Read-InterfaceGroupProfile -Path $ProfilePath -ErrorAction Stop
        $checks.Add([pscustomobject]@{ Check='Profile'; Status='Passed'; Detail='Schema, scopes and parameter values are valid.' })
    }
    catch {
        Write-Warning "Profile validation failed: $($_.Exception.Message)"
        $checks.Add([pscustomobject]@{ Check='Profile'; Status='Failed'; Detail=$_.Exception.Message })
    }
    $required = @('Example-InterfaceGrouping.ps1','Invoke-InterfaceGroupProfile.ps1','InterfaceGroupPolicyHelpers.ps1','Interface-Group-Details.html','InterfaceDashboardAssets.ps1')
    if ($settings.UseSnmp) { $required += 'InterfaceGroupSnmpHelpers.ps1' }
    foreach ($file in $required) {
        $exists = Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf
        $checks.Add([pscustomobject]@{ Check="Dependency: $file"; Status=$(if ($exists) { 'Passed' } else { 'Failed' }); Detail=$(if ($exists) { 'Present.' } else { 'Required file is missing.' }) })
    }
    if ($settings.ReviewPath) {
        try {
            $decisions=@(Import-Csv -LiteralPath $settings.ReviewPath -ErrorAction Stop)
            foreach ($row in $decisions) {
                foreach ($column in @('InterfaceKey','InterfaceComment','InterfaceName','Groups','Exclude','Apply')) {
                    if (-not $row.PSObject.Properties[$column]) { throw "Review CSV lacks required column: $column" }
                }
                if ([string]$row.Apply -notmatch '^(True|False)$' -or [string]$row.Exclude -notmatch '^(True|False)$') { throw 'Review flags must be True or False.' }
            }
            $checks.Add([pscustomobject]@{Check='Review decisions';Status='Unverified';Detail='CSV is readable and flags/columns checked; pin identity requires fresh collection.'})
        }
        catch { Write-Warning "Review readiness failed: $($_.Exception.Message)";$checks.Add([pscustomobject]@{Check='Review decisions';Status='Failed';Detail=$_.Exception.Message}) }
    }
    $vault = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
    if ($global:WhatsUpServerBaseURI -and $global:WUGBearerHeaders) {
        $checks.Add([pscustomobject]@{ Check='WUG connection'; Status='Passed'; Detail='Current session exists; API access not inferred.' })
    }
    else {
        $exists = Test-Path -LiteralPath (Join-Path $vault 'WUG.Server.cred') -PathType Leaf
        $checks.Add([pscustomobject]@{ Check='WUG connection'; Status=$(if ($exists) { 'Unverified' } else { 'Failed' }); Detail=$(if ($exists) { 'Saved entry exists; decryption and API access require CheckApi.' } else { 'Connect-WUGServer is needed: no session or saved WUG.Server entry.' }) })
    }
    if ($settings.UseSnmp) {
        for ($index=0;$index -lt $settings.SnmpCredentialNames.Count;$index++) {
            $name=$settings.SnmpCredentialNames[$index]
            $status = 'Unverified'; $detail = 'Metadata only; no secret decryption or device probe.'
            $failureDetail = 'Cannot read the selected local vault file; check that it exists and is accessible.'
            try {
                $path = Join-Path $vault "$name.cred"
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                $failureDetail = 'Credential must be a regular local file, not a directory or reparse point.'
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Credential must be a regular local file.' }
                $failureDetail = 'Vault metadata is unreadable or invalid JSON; inspect or recreate the entry using discovery-vault tools.'
                $metadata = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $failureDetail = 'Vault expiry metadata is invalid; re-save the credential using discovery-vault tools.'
                if ($metadata.ExpiresUtc) { $expires = [DateTimeOffset]::Parse($metadata.ExpiresUtc) }
                $failureDetail = 'Selected credential is expired; rotate/re-save it using discovery-vault tools.'
                if ($metadata.ExpiresUtc -and $expires -le [DateTimeOffset]::UtcNow) { throw 'Selected credential is expired.' }
                $failureDetail = 'Vault credential type must be Single (legacy entries may omit Type) or Bundle.'
                if ($metadata.Type -and $metadata.Type -notin @('Single','Bundle')) { throw 'Unsupported credential type.' }
                $fields = @($metadata.FieldNames)
                $requiredFields = @('Community')
                if ($settings.SnmpCredentialVersions[$index] -eq 'V3') { $requiredFields = @('Username','AuthProtocol','PrivacyProtocol') }
                if ($metadata.Type -eq 'Bundle') {
                    foreach ($field in $requiredFields) {
                        if ($fields -notcontains $field) {
                            $failureDetail = "Selected $($settings.SnmpCredentialVersions[$index]) credential requires vault field '$field'."
                            if ($field -eq 'Community' -and $fields -contains 'Username' -and $fields -contains 'AuthProtocol') {
                                $failureDetail += ' This entry has SNMPv3 fields: select V3, or choose a V1/V2 community credential.'
                            }
                            else { $failureDetail += ' Re-save it with the required fields or choose a matching credential/version.' }
                            throw 'Required vault field is missing.'
                        }
                    }
                }
                elseif ($settings.SnmpCredentialVersions[$index] -eq 'V3') {
                    $failureDetail = 'SNMPv3 requires a Bundle with Username, AuthProtocol and PrivacyProtocol; select V1/V2 for a Single community entry or create a V3 bundle.'
                    throw 'SNMPv3 requires a bundled credential.'
                }
            }
            catch {
                $status = 'Failed'; $detail = $failureDetail
                Write-Warning "SNMP readiness '$name': $detail"
            }
            $checks.Add([pscustomobject]@{ Check="SNMP credential: $name ($($settings.SnmpCredentialVersions[$index]))"; Status=$status; Detail=$detail })
        }
        $archive = Join-Path $PSScriptRoot '..\snmp\WhatsUpGoldPS.Snmp'
        $archives = @(Get-ChildItem -LiteralPath $archive -Filter '*.zip' -File -Recurse -ErrorAction Stop)
        $checks.Add([pscustomobject]@{ Check='Bundled SNMP library'; Status=$(if ($archives.Count) { 'Passed' } else { 'Failed' }); Detail='Archive presence only; the existing loader validates its pinned hash at runtime.' })
    }
    if ($settings.CancellationPath) {
        $signalled=Test-Path -LiteralPath $settings.CancellationPath
        $checks.Add([pscustomobject]@{Check='Cancellation signal';Status=$(if ($signalled) {'Failed'} else {'Passed'});Detail=$(if ($signalled) {'Signal is present; remove it explicitly before a new run.'} else {'No cancellation signal is present.'})})
    }
    $output = $null
    if ($settings) {
        $output = $settings.OutputDirectory
        if (-not $output) {
            $mode = 'NamedGroups'; if ($settings.Mode) { $mode = $settings.Mode }
            if ($mode -eq 'IntelligentGroups') { $strategy='Prefix'; if ($settings.Strategy) { $strategy=$settings.Strategy }; $mode += "-$strategy" }
            $output = Join-Path $env:ProgramData "WhatsUpGoldPS\Output\InterfaceGroups\$mode"
        }
        $targets = [ordered]@{ Output=$output }
        if ($settings.PublishToWug) {
            $console = $settings.NmConsolePath
            if (-not $console) {
                $console = @((Join-Path ${env:ProgramFiles(x86)} 'Ipswitch\WhatsUp\Html\NmConsole'), (Join-Path $env:ProgramFiles 'Ipswitch\WhatsUp\Html\NmConsole')) |
                    Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
            }
            try {
                if (-not $console) { throw 'No local NmConsole installation; supply NmConsolePath or run on the WUG host.' }
                $config = [xml](Get-Content -LiteralPath (Join-Path $console 'web.config') -Raw -ErrorAction Stop)
                $auth = $config.SelectSingleNode('/configuration/system.web/authentication')
                if (-not $auth -or $auth.GetAttribute('mode') -ne 'Forms') { throw 'Parent must declare Forms authentication; inherited setups need administrator review.' }
                $pack=$settings.PackName
                if (-not $pack) {
                    $mode='NamedGroups';if ($settings.Mode) {$mode=$settings.Mode}
                    if ($mode -eq 'IntelligentGroups') {$strategy='Prefix';if ($settings.Strategy){$strategy=$settings.Strategy};$mode += "-$strategy"}
                    $pack="interfaces-$mode"
                }
                $destination=Join-Path $console "dashboards\$pack"
                if (Test-Path -LiteralPath $destination) {
                    $owned=Join-Path $destination 'web.config'
                    if (-not (Test-Path -LiteralPath $owned -PathType Leaf) -or -not [IO.File]::ReadAllText($owned).Contains('<!-- WhatsUpGoldPS owned dashboard pack: inherited WUG Forms authentication required. -->')) { throw 'Existing publishing destination is not helper-owned; choose a new PackName.' }
                }
                $targets.Publishing = $destination
                $checks.Add([pscustomobject]@{ Check='Publishing configuration'; Status='Passed'; Detail='Local parent declares Forms; IIS access/authentication is not verified.' })
            }
            catch {
                Write-Warning "Publishing preflight failed: $($_.Exception.Message)"
                $checks.Add([pscustomobject]@{ Check='Publishing configuration'; Status='Failed'; Detail=$_.Exception.Message })
            }
        }
        foreach ($target in $targets.Keys) {
            $directory = [IO.Path]::GetFullPath($targets[$target])
            $requested = $directory
            while (-not (Test-Path -LiteralPath $directory)) { $directory = Split-Path $directory -Parent; if (-not $directory) { throw "No existing ancestor for $requested" } }
            $status='Unverified'; $detail='Write access not tested. Use -TestWriteAccess for a temporary file probe.'
            $ancestor=$directory;$unsafe=$false
            while ($ancestor) {
                $item=Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
                if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $unsafe=$true;break }
                $ancestor=Split-Path $ancestor -Parent
            }
            if ($unsafe) {
                $checks.Add([pscustomobject]@{Check="$target path";Status='Failed';Detail='Output/publishing target must have regular directory ancestors, not reparse points or files.'})
                continue
            }
            if ($TestWriteAccess -and $PSCmdlet.ShouldProcess($directory, 'Create and remove temporary readiness write probe')) {
                $probe=Join-Path $directory ('.interface-readiness-' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    $stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    $stream.Dispose()
                    $status='Passed'; $detail="Write probe passed in $directory."
                    if ($directory -ne $requested) { $status='Unverified'; $detail += ' Target does not exist; inherited target permissions and directory creation remain unverified.' }
                }
                catch { $status='Failed'; $detail="Write probe failed ($($_.Exception.GetType().Name))."; Write-Warning "$target readiness: $detail" }
                finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction Stop } }
            }
            $checks.Add([pscustomobject]@{ Check="$target write access"; Status=$status; Detail=$detail })
        }
        if ($CheckApi -and -not $WhatIfPreference) {
            try {
                Connect-InterfaceGroupServer -ErrorAction Stop
                $scope=@{}; foreach ($key in @('DeviceId','AllDevices','GroupId','ReturnHierarchy')) { if ($settings.ContainsKey($key)) { $scope[$key]=$settings[$key] } }
                $ids=@(Resolve-InterfaceGroupDevice @scope -ErrorAction Stop)
                $null=Get-WUGDevice -DeviceId $ids[0] -View basic -ErrorAction Stop
                $checks.Add([pscustomobject]@{ Check='API read'; Status='Passed'; Detail="Scope resolves $($ids.Count) devices and first device read passed; monitor/report permissions are not proven." })
            }
            catch { Write-Warning "API preflight failed ($($_.Exception.GetType().Name)); check connection and scope permissions."; $checks.Add([pscustomobject]@{ Check='API read';Status='Failed';Detail="Read failed ($($_.Exception.GetType().Name))." }) }
        }
        else { $checks.Add([pscustomobject]@{ Check='API read'; Status='Unverified'; Detail='No network probe performed. Use -CheckApi; WhatIf suppresses connection/probe.' }) }
    }
    $checks.Add([pscustomobject]@{ Check='Server E2E'; Status='Unverified'; Detail='Live SNMP, IIS Forms authentication and scheduled identity access require separate verification.' })
    [pscustomobject]@{ ProfilePath=[IO.Path]::GetFullPath($ProfilePath); ReadyToAttempt=(@($checks | Where-Object Status -eq Failed).Count -eq 0); FullyVerified=$false; OutputDirectory=$output; Checks=@($checks) }
}

function Get-InterfaceGroupStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilePath,[string]$LogDirectory,[switch]$IncludeScheduledTasks)
    $full=(Get-Item -LiteralPath $ProfilePath -ErrorAction Stop).FullName
    $settings=Read-InterfaceGroupProfile -Path $full
    if (-not $LogDirectory) { $LogDirectory=Get-InterfaceGroupLogDirectory -ProfilePath $full }
    $latest=$null; $success=$null; $failure=$null
    if (Test-Path -LiteralPath $LogDirectory -PathType Container) {
        $latestPath=Join-Path $LogDirectory 'latest-result.json'
        if (Test-Path -LiteralPath $latestPath) { $latest=Get-Content -LiteralPath $latestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        $successPath=Join-Path $LogDirectory 'last-success.json'
        if (Test-Path -LiteralPath $successPath) { $success=Get-Content -LiteralPath $successPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        $failurePath=Join-Path $LogDirectory 'last-failure.json'
        if (Test-Path -LiteralPath $failurePath) { $failure=Get-Content -LiteralPath $failurePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        foreach ($record in @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'run-*.json' -File -ErrorAction Stop | Sort-Object Name -Descending)) {
            if ($record.Name -notmatch '^run-[0-9T]+-[a-f0-9]{32}\.json$') { continue }
            $data=Get-Content -LiteralPath $record.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($data.ProfilePath -ine $full) { continue }
            if (-not $success -and $data.Success -and -not $data.PreviewOnly) { $success=$data }
            if (-not $failure -and -not $data.Success) { $failure=$data }
            if ($success -and $failure) { break }
        }
    }
    $age=$null
    if ($success) { $age=[Math]::Round(([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($success.FinishedUtc)).TotalMinutes,2) }
    $dashboard=$null
    if ($success.IndexPath -and (Test-Path -LiteralPath $success.IndexPath -PathType Leaf)) { $dashboard=Get-Item -LiteralPath $success.IndexPath -Force -ErrorAction Stop }
    $tasks=@()
    if ($IncludeScheduledTasks) {
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'ScheduledTasks cmdlets are unavailable; omit IncludeScheduledTasks or use Windows Task Scheduler.' }
        $tasks=@(foreach ($task in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.Description -eq "WhatsUpGoldPS InterfaceGroups profile refresh; profile=$full" })) {
            $info=Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            [pscustomobject]@{TaskName=$task.TaskName;TaskPath=$task.TaskPath;State=$task.State;LogonType=$task.Principal.LogonType;LastRunTime=$info.LastRunTime;NextRunTime=$info.NextRunTime;LastTaskResult=$info.LastTaskResult}
        })
    }
    [pscustomobject]@{
        ProfilePath=$full;LogDirectory=$LogDirectory;LatestRun=$latest;LastSuccessfulExport=$success;LatestFailure=$failure
        ExportAgeMinutes=$age;Health=$success.Health;SnmpCoverage=$success.SnmpCoverage;Publication=$success.Publication
        DashboardExists=($null -ne $dashboard);DashboardAgeMinutes=$(if ($dashboard) {[Math]::Round(([DateTime]::UtcNow-$dashboard.LastWriteTimeUtc).TotalMinutes,2)} else {$null})
        ScheduledTasks=$tasks;TaskStatusChecked=[bool]$IncludeScheduledTasks;AuthenticationVerified=$false
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBES8Wc6r8Wt3d2
# 9Mlx7tW1F4yr2PRO/CFHGfvCIMN28qCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCA3
# t+WfrpgA1VSdu3nXswZl7LPgt1SC3HpP9OeWMmi8HDANBgkqhkiG9w0BAQEFAASC
# AgAS0SiKEFdKm0h5EFZgNCT4D1Khm87QNyFrD7C7mid2Cw2QJQRGGt9xK16eCRrN
# TISeJJmc1WHmWpmNr1lAo0FrdVwLn8+fFKQTrbttW5SEhOKizA8zsjCmuS9wDRzr
# Of//FItBnk8QFedNH6RMN6Ym12KliHY9a3FzyUYywvFSjRaGGOM2s0GSwuNsHzo+
# vjF40GDpc/L9J/uJNh7MlSjvrCpiCxqR/gfuCRJcdQE2M9pqy1l65Xpwm9/KRsHa
# xFVZywI8J444SVSqIJ7Zr58f9CC90feF2ijSFd8DBvbMBjwh+r/WugOgzbUO+tNg
# jf3wMPy5a9zwraBaJ1aS027M6PbR4WpZzUIzrkT2HkhBWcpvwCyH3VBNglJCIs23
# uxVCVdkMwhfddefMHklAK9wmDMaNGGUxhUGucOE7Ih6t5u02lb5oMclvyYvrDdmI
# 3LtJ/wuxp8y2eygdPvG8B+wEcnq2HE33zsTHEPe0T2BadR958cCfnHmpkTtvnqvD
# gvMztOm9DQmJLzymdSR0ff9/HJ0Hy4x2EdY7lWsWc1/uxIDKh0TDm4jrM/W3RGkm
# 1ewegAZornD12H9aO+r3bb9GBW6lVEh4lrC7T4CXJej6jQPCVAVrX4Vh+y3DVbDN
# hgeuYr1aa4+4aakTi/wW3FlSXdHJ4d7dF4dDMMRf0fNAbqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzNDZaMC8GCSqGSIb3DQEJBDEiBCAWboWivy8M
# 4lnJXhqZy8GrOvVKasm79qJpCsKkPvwnJjANBgkqhkiG9w0BAQEFAASCAgCDrWaa
# zoEDpw0uj0ThRfj9DIS6QT7ypwm7EDOaExmq1e3jd6cI1lRydrk9m16aleUiDkCU
# 9DmHe9cBXsJeoxeHneWgYvYuaFZeFrNMsAsIv71NxJsJIK7eUOwWP3tVj8A0gfD8
# nVORCLxK6BpUDuNzgo1NE90cuKSvSL49+WL8eeGlV7xsEByWkgkx7w600y3FAOM3
# XUUX3mMjKthBSJWYqz5pv4iu5G/YQ51bPPWPdaFsfN24xfwAGPnh0pG6sTYZNiiJ
# Qmxoz0/qW3VbGzbVPq88nz3WZcK1h2sfzWobXv3OyesVIkdkbvoIXhKYbDQkQNbE
# 6BKnzkdM3CpIMGsFGU0wPNeVWEIDmpcIqJYExOKcB/bE5KXU2k5R2yJDV2JPThc5
# 5ivfuxVETG5N3abVIwS5RoRuaC8ZAxNteQD6nVsQLZFnfTMkahHvMzjewCuN8Ncz
# GhxEGATxcOIsi4wzHffRVDNT1YO4oleBCAtu+O4u3KMrVs8G7htHdPn7AwdNHCRX
# T5NRDkhKdr1rQLp4/1LvwiuVLtX4owWqAkk7ukEryJKymsrrR3wqTVHiNsvoY3Ew
# njmvZbUFSY2WPJC9Rw95PmwsZcD1QcFakMM+OdueBHdyAUMvdRwZLd/vNJeEmaw7
# Zqiy0MA+e/jY+WsAgnmK7cLZwNM/ASz9TTx2lg==
# SIG # End signature block
