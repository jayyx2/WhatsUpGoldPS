#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupingHelpers.ps1')
$root=Join-Path $env:TEMP ('WUG-InterfacePolicy-' + [guid]::NewGuid().ToString('N'))
$savedServer=$global:WhatsUpServerBaseURI
$savedHeaders=$global:WUGBearerHeaders
$savedExpiry=$global:expiry
$savedProgramData=$env:ProgramData
$passed=0
function Assert-Equal {param($Expected,$Actual) if($Expected -cne $Actual){throw "Expected '$Expected', received '$Actual'."}}
function Invoke-Case {param([string]$Name,[scriptblock]$Body) & $Body;$script:passed++;"PASS: $Name"}
function New-Row {param([int]$Index,[string]$Alias) [pscustomobject]@{DeviceId=818;IfIndex=[string]$Index;DeviceName='Fixture';InterfaceComment='';InterfaceName='';IfAlias=$Alias;IfName="eth$Index";IfDescr='';Status='Unknown';Traffic=$null}}
$rows=@((New-Row 1 'customer tunnel to branch'),(New-Row 2 'WAN customer'),(New-Row 3 'customer backup'),(New-Row 4 'unmatched'))
$rules=@(
    [pscustomobject]@{Name='Tunnels';Value='tunnel to';Match='Contains';Field='Any'},
    [pscustomobject]@{Name='WAN';Value='WAN';Match='StartsWith';Field='IfAlias'},
    [pscustomobject]@{Name='Backup';Value='backup';Match='EndsWith';Field='IfAlias'},
    [pscustomobject]@{Name='Customers';Value='customer';Match='Token';Field='Any'})
try {
    $env:ProgramData=Join-Path $root 'program'
    Invoke-Case 'Ordered rules match phrases at start, end and middle; unmatched stays visible' {
        $groups=@(Select-InterfaceGroupRules -Inventory $rows -Rules $rules)
        Assert-Equal 'Tunnels,WAN,Backup,Customers,Other Interfaces' (@($groups.Name) -join ',')
        Assert-Equal '1,1,1,0,1' (@($groups.InterfaceCount) -join ',')
        $overlap=@(Select-InterfaceGroupRules -Inventory $rows -Rules $rules -RuleMode Overlap)
        Assert-Equal 3 $overlap[3].InterfaceCount
        Assert-Equal 1 $overlap[4].InterfaceCount
    }
    Invoke-Case 'Literal matching never interprets user phrases as regex; duplicate rules do not duplicate membership' {
        Assert-Equal $true (Test-InterfaceGroupTextMatch -Text 'tunnel to foo' -Value 'TUNNEL TO' -Match StartsWith)
        Assert-Equal $true (Test-InterfaceGroupTextMatch -Text 'foo a.b' -Value 'a.b' -Match EndsWith)
        Assert-Equal $false (Test-InterfaceGroupTextMatch -Text 'foo axb' -Value 'a.b' -Match Contains)
        Assert-Equal $false (Test-InterfaceGroupTextMatch -Text 'customerAB' -Value 'customerA' -Match Token)
        Assert-Equal $true (Test-InterfaceGroupTextMatch -Text ' GroupA ' -Value GroupA -Match Exact)
        $duplicate=@($rules[0],$rules[0])
        $groups=@(Select-InterfaceGroupRules -Inventory $rows -Rules $duplicate -RuleMode Overlap)
        Assert-Equal 1 $groups[0].InterfaceCount
        foreach($bad in @(@{Name='';Value='x';Match='Contains'},@{Name='Other Interfaces';Value='x';Match='Contains'},@{Name='x';Value='x';Match='Regex'},@{Name='x';Value='x';Match='Contains';Field='Password'})){
            $thrown=$false
            try {Test-InterfaceGroupRules -Rules @($bad)} catch {$thrown=$true}
            Assert-Equal $true $thrown
        }
    }
    Invoke-Case 'Rules/profile JSON roundtrip preserves ordered matches and filter' {
        $path=Join-Path $root 'rules.json'
        $null=Save-InterfaceGroupProfile -Path $path -Settings @{AllDevices=$true;Mode='Rules';Rules=$rules;RuleMode='Overlap';DeviceFilter='SnmpAssigned'}
        $settings=Read-InterfaceGroupProfile -Path $path
        Assert-Equal SnmpAssigned $settings.DeviceFilter
        Assert-Equal Overlap $settings.RuleMode
        Assert-Equal 'Tunnels,WAN,Backup,Customers' (@($settings.Rules.Name) -join ',')
    }
    Invoke-Case 'Credential filter skips non-SNMP devices and checks each candidate exactly once' {
        $script:credentialCalls=@()
        function Get-WUGDeviceCredential {
            [CmdletBinding()]param($DeviceId,$Type,$View)
            Assert-Equal snmp $Type;Assert-Equal id $View
            $script:credentialCalls+= [int]$DeviceId
            if($DeviceId -eq '818'){[pscustomobject]@{id='fixture-snmp'}}
        }
        Assert-Equal '818' (@(Select-InterfaceGroupSnmpDevice -DeviceId 818,900,818) -join ',')
        Assert-Equal '818,900' ($script:credentialCalls -join ',')
        $thrown=$false
        try {Select-InterfaceGroupSnmpDevice -DeviceId 900} catch {$thrown=$_.Exception.Message -like '*No devices*'}
        Assert-Equal $true $thrown
    }
    Invoke-Case 'Credential query failures terminate instead of silently skipping devices' {
        function Get-WUGDeviceCredential {[CmdletBinding()]param($DeviceId,$Type,$View) throw 'fixture credential API failure'}
        $thrown=$false
        try {Select-InterfaceGroupSnmpDevice -DeviceId 818} catch {$thrown=$_.Exception.Message -eq 'fixture credential API failure'}
        Assert-Equal $true $thrown
    }
    $global:WhatsUpServerBaseURI='https://offline.fixture'
    $global:WUGBearerHeaders=@{Authorization='offline-fixture'}
    $global:expiry=(Get-Date).AddDays(1)
    $requestLog=[System.Collections.Generic.List[string]]::new()
    function Invoke-RestMethod {
        [CmdletBinding()]param($Uri,$Method,$Headers,$Body)
        $requestLog.Add([string]$Uri)
        if($Uri -match '/device-groups/-2/devices/-'){return [pscustomobject]@{data=@{devices=@([pscustomobject]@{id=818},[pscustomobject]@{id=900})};paging=@{}}}
        if($Uri -match '/devices/818/credentials/-'){return [pscustomobject]@{data=@([pscustomobject]@{id='fixture-snmp'})}}
        if($Uri -match '/devices/900/credentials/-'){return [pscustomobject]@{data=@()}}
        if($Uri -match '/devices/818\?'){return [pscustomobject]@{data=[pscustomobject]@{id=818;displayName='Fixture';networkAddress='127.0.0.1'}}}
        if($Uri -match '/devices/818/monitors/-'){return [pscustomobject]@{data=@();paging=@{}}}
        if($Uri -match '/devices/818/reports/interface-traffic'){return [pscustomobject]@{data=@();paging=@{}}}
        throw "Unexpected API request: $Uri"
    }
    Invoke-Case 'Real entry filters before monitor/report reads and cached approval issues zero collection requests' {
        $output=Join-Path $root 'live'
        $requestLog.Clear()
        $result=& (Join-Path $PSScriptRoot '..\interfaces\Example-InterfaceGrouping.ps1') -AllDevices -Mode AllInterfaces -DeviceFilter SnmpAssigned -PreviewOnly -OutputDirectory $output
        Assert-Equal 1 $result.DeviceCount
        Assert-Equal 1 $result.SkippedDeviceCount
        Assert-Equal 0 @($requestLog | Where-Object {$_ -match '/devices/900/' -and $_ -notmatch '/credentials/'}).Count
        Assert-Equal 6 $requestLog.Count
        Assert-Equal $true (Test-Path -LiteralPath $result.InventoryPath)
        $requestLog.Clear()
        $approval=& (Join-Path $PSScriptRoot '..\interfaces\Example-InterfaceGrouping.ps1') -AllDevices -Mode AllInterfaces -DeviceFilter SnmpAssigned -Collection $result.Collection -OutputDirectory $output
        Assert-Equal 0 $requestLog.Count
        Assert-Equal $true (Test-Path -LiteralPath $approval.IndexPath)
    }
    Invoke-Case 'Missing cache fails with explicit capture instructions before network access or logs' {
        $profile=Join-Path $root 'missing-cache-profile.json'
        $null=Save-InterfaceGroupProfile -Path $profile -Settings @{DeviceId=@(818);Mode='AllInterfaces'}
        $requestLog.Clear()
        $logs=Join-Path $root 'missing-cache-logs'
        $thrown=$false
        try {
            $null=& (Join-Path $PSScriptRoot '..\interfaces\Invoke-InterfaceGroupProfile.ps1') -ProfilePath $profile -InventoryPath (Join-Path $root 'missing-collection.json') -LogDirectory $logs
        }
        catch {$thrown=$_.Exception.Message -like '*Saved collection not found*PreviewOnly*'}
        Assert-Equal $true $thrown
        Assert-Equal 0 $requestLog.Count
        Assert-Equal $false (Test-Path $logs)
    }
    Invoke-Case 'Saved collection runs new rules entirely offline, retains observations and cannot publish' {
        $collection=[pscustomobject]@{SchemaVersion=1;Server='https://offline.fixture';CollectedUtc=[DateTime]::UtcNow.ToString('o');SourceScope=[pscustomobject]@{AllDevices=$true};DeviceIds=@(818);CandidateDeviceCount=2;DeviceFilter='SnmpAssigned';Range='lastPolled';RangeN=4;Inventory=$rows;SnmpCoverage=@{}}
        $cache=Join-Path $root 'collection\collected-inventory.json'
        $null=Export-InterfaceGroupCollection -Collection $collection -Path $cache
        $global:WhatsUpServerBaseURI=$null;$global:WUGBearerHeaders=$null
        $requestLog.Clear()
        $report=& (Join-Path $PSScriptRoot '..\interfaces\Example-InterfaceGrouping.ps1') -InventoryPath $cache -Mode Rules -Rules $rules -OutputDirectory (Join-Path $root 'offline')
        Assert-Equal 0 $requestLog.Count
        Assert-Equal 4 $report.Inventory.Count
        Assert-Equal 1 $report.Groups[0].InterfaceCount
        $snapshot=Get-Content (Join-Path (Split-Path $report.IndexPath -Parent) 'inventory-snapshot.json') -Raw | ConvertFrom-Json
        Assert-Equal 'https://offline.fixture' $snapshot.Server
        $profile=Join-Path $root 'offline-profile.json'
        $null=Save-InterfaceGroupProfile -Path $profile -Settings @{DeviceId=@(818);Mode='Rules';Rules=$rules;UseSnmp=$true;SnmpCredentialNames=@('Fixture.NotLoaded');SnmpCredentialVersions=@('V3');OutputDirectory=(Join-Path $root 'unused-live')}
        $logs=Join-Path $root 'offline-logs'
        $null=New-Item -ItemType Directory -Path $logs -Force
        $successPath=Join-Path $logs 'last-success.json'
        [IO.File]::WriteAllText($successPath,'{"Success":true,"IndexPath":"live-fixture"}',[Text.UTF8Encoding]::new($true))
        $before=(Get-FileHash $successPath).Hash
        $offline=& (Join-Path $PSScriptRoot '..\interfaces\Invoke-InterfaceGroupProfile.ps1') -ProfilePath $profile -InventoryPath $cache -LogDirectory $logs -PreviewOnly
        Assert-Equal 0 $requestLog.Count
        Assert-Equal 4 $offline.Inventory.Count
        Assert-Equal $before (Get-FileHash $successPath).Hash
        $latest=Get-Content (Join-Path $logs 'latest-result.json') -Raw | ConvertFrom-Json
        Assert-Equal $true $latest.Offline
        foreach($flags in @(@{PublishToWug=$true},@{CreateWugGroups=$true},@{OutputDirectory=(Split-Path $cache -Parent)})){
            $thrown=$false
            try {& (Join-Path $PSScriptRoot '..\interfaces\Example-InterfaceGrouping.ps1') -InventoryPath $cache -Mode AllInterfaces @flags} catch {$thrown=$true}
            Assert-Equal $true $thrown
        }
        $target=Join-Path $root 'whatif'
        $null=& (Join-Path $PSScriptRoot '..\interfaces\Example-InterfaceGrouping.ps1') -InventoryPath $cache -Mode Rules -Rules $rules -OutputDirectory $target -WhatIf
        Assert-Equal $false (Test-Path $target)
        $collection.Inventory=@($rows[0],$rows[0])
        $thrown=$false
        try {Export-InterfaceGroupCollection -Collection $collection -Path (Join-Path $root 'invalid.json')} catch {$thrown=$true}
        Assert-Equal $true $thrown
    }
    "$passed policy/efficiency cases passed."
}
finally {
    $env:ProgramData=$savedProgramData
    $global:WhatsUpServerBaseURI=$savedServer;$global:WUGBearerHeaders=$savedHeaders;$global:expiry=$savedExpiry
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBGX72gwKEGhE2e
# h9juM594TB8k83d4qYpoB8Wf8M4j+6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCB5
# UjJJkASEnxfhx+G15nH4fLzl7K1aXDl6ROo5wgeePzANBgkqhkiG9w0BAQEFAASC
# AgBBgpQ9xXSmBL+XvbegkG7rMj5mcqNN8Tg4XzMa80oHJPpgym9x8Oy2+I3quXmd
# PG77pg95bB7Y0lAkK1ppAf8PV2VLfCUVe28ySlvpLyZo7LSQAAD45DG/TV6vWGlc
# ilD5RdqvD2YDXd8mGELRd2gQ+9VGhsVBhZpz+bK2GU1EkvyPTPo4lvloRbaR8la6
# ulP3BEPs5tndGeGP05OIl3w62UTivHS64vvDgJXcsZW4kdb/ikC889udQkAbmOmx
# z2+tuDnzJEbpPjp06b0JogeVfYW+ylp76PWW81vPwtFBq+sia7YxJW1nDTpF6jqg
# eXeRnkXSIKDVkYfRuN11r2/ODwCxO12s4PhVwDY9OpzDqPCT8ZJ+4IJERbIVXy4A
# UzrGoNWMy+aIy2F4sNyTUjb2wVC1Z1Q6p/gde+/BL/+rokj181bitCSHJDgKMz+q
# IIqXp0QAmtdU/LwZIAD2LkDnejS8qI0++dILAAlcHpfAtyM0qP5UO+fM5zERiQ/g
# ARWStWcoBUVbObv50IrjdPlhnDuqDnY12CXP9pGjbHSPKC7wb+8q3fhJmSqqLpHG
# Fgw8wMAs/VFwTmbUKCyOgb3iJfyI3zVD0D2sE3hSDQoMW+o1M0c3+zI3zIhmEF4+
# h5Hpsh5g48xn8z1CelVrCvQAq8kYHNS5KeCF9L5r/T9kGqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTU5NTRaMC8GCSqGSIb3DQEJBDEiBCA5ah/re7Rj
# J8DycRjyYpUhaQtnxLqOhsYfOkuzClFoLzANBgkqhkiG9w0BAQEFAASCAgCO9PRy
# lxdZ6N7jQymO25Z96T/Olf1OxxxnDDlBxGibPEg9tVfr/F9/WA33cU8ESwRdxi/p
# deSWSpC7hwVRsDGyfOX52HrQV3ndv2h2pd7mcF0hF+pJBD+k5K/ELUOZ2kNa3Mvc
# V3Ke0j/n7RooNzxRrF4seQY83gL1Koh2TcN8dfaYxJU3+bibnVU/9UQ+EYMBETS6
# xbGQwe531O77BzqI5yyib9NZKN8a1NRv4zN5L68Sv9QD0NY6unC4f4tOIF09YiBT
# z7+0QqeS3gAXdaDm1LLVNcTSzYp97O6ZK4M3CWYThPL85q1POzRNQLdGqxWM71ZK
# 4Pyc8DRVZ4IJq0bePsB+QaJkaZGv5gwxYrC2icH9lrzIWHYLkZsbMZTdquNYIVvJ
# drHQKRSmEroP3h/XEmHDda6sXQgHqhVrYlk1rvjKtqsSZD4V3gYWMWVSUK6cvAlc
# JCmNT+tfdxGckRIR1mOBTFUCgl1DbhT1l5gg23zlEN2sTlv61r/BpdWa3Ezurzwf
# korO3+gwrwbfqgJEqIJ6oopuyVLlQ674c98QKDivQFJCDK0jf+TzEyzVes6EQCLn
# QTUwfwaPpXyf6myCvdU8imbTFrKaZp027yp/BkM+EweILg7cToNnrf0Se7DiD1X1
# xepOjjrWQHFe1E1CypO3tjCfQcfHgudujGEs5g==
# SIG # End signature block
