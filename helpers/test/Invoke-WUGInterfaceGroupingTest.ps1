#requires -Version 5.1
<#
.SYNOPSIS
    Runs offline interface grouping MVP regression tests.
.DESCRIPTION
    Uses canned WUG responses and mocked navigation writes; no lab connection needed.
.EXAMPLE
    powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceGroupingTest.ps1
.NOTES
    Throws on failures. Removes only its unique temporary report directory.
.LINK
    ..\..\docs\interface-grouping.md
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupingHelpers.ps1')
$script:passed = 0
$script:failed = 0
function Assert-Equal {
    param($Expected, $Actual)
    if ($Expected -ne $Actual) { throw "Expected '$Expected', got '$Actual'." }
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    try { & $Test; $script:passed++; Write-Output "PASS: $Name" }
    catch { $script:failed++; Write-Warning "FAIL: $Name - $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
function New-ActiveFixture {
    param([string]$Index, [string]$Comment, [string]$Status = 'Up at least 5 min', [bool]$Enabled = $true)
    [pscustomobject]@{
        id = "assignment-$Index"; type = 'active'
        monitorTypeClassId = 'd6d02d69-a418-483a-93ea-20dd2af2d135'
        active = [pscustomobject]@{ argument = $Index; comment = $Comment }
        status = $Status; enabled = $Enabled
    }
}
function New-TrafficFixture {
    param([string]$Index, [string]$Name)
    [pscustomobject]@{
        interfaceId = "wug-$Index"; interfaceName = "$Name ($Index)"
        pollTimeUtc = '2026-11-08T12:00:00Z'; rxSpeedAvg = 100; txSpeedAvg = 200
        rxPercentAvg = 81; txPercentAvg = 96; timeFromLastPollSeconds = 20
        series = @(
            [pscustomobject]@{ pollTimeUtc = '2026-11-08T11:59:00Z'; rxSpeedAvg = 0; txSpeedAvg = $null },
            [pscustomobject]@{ pollTimeUtc = '2026-11-08T12:00:00Z'; rxSpeedAvg = 100; txSpeedAvg = 200 }
        )
    }
}
$names = @(65..76 | ForEach-Object { 'Group' + [char]$_ })
$monitors = @()
$traffic = @()
for ($i = 0; $i -lt 12; $i++) {
    $monitors += New-ActiveFixture -Index ($i + 1) -Comment "customer $($names[$i]) uplink"
    $traffic += New-TrafficFixture -Index ($i + 1) -Name "eth$i"
}
$inventory = @(ConvertTo-InterfaceGroupInventory -DeviceId 818 -DeviceName Router -Monitors $monitors -Traffic $traffic)
$groups = @(Select-InterfaceGroups -Inventory $inventory -GroupName $names)
Invoke-Test 'Auto-detection discovers all 12 distinct Group labels' {
    $labels = @(Get-InterfaceGroupLabel -Inventory $inventory)
    Assert-Equal 12 $labels.Count
    Assert-Equal 'GroupA' $labels[0]
    Assert-Equal 'GroupL' $labels[11]
}
Invoke-Test 'Auto-detection deduplicates case and respects token boundaries' {
    $rows = @(
        [pscustomobject]@{ InterfaceComment = 'customer GroupA / groupa, Group12'; InterfaceName = 'port Group-Operations (7)' },
        [pscustomobject]@{ InterfaceComment = 'NotGroupB Group _GroupC Group-'; InterfaceName = $null }
    )
    $labels = @(Get-InterfaceGroupLabel -Inventory $rows)
    Assert-Equal 3 $labels.Count
    Assert-Equal $true ($labels -contains 'GroupA')
    Assert-Equal $true ($labels -contains 'Group12')
    Assert-Equal $true ($labels -contains 'Group-Operations')
}
Invoke-Test 'Auto-detection does not invent labels for unlabeled interfaces' {
    Assert-Equal 0 @(Get-InterfaceGroupLabel -Inventory @()).Count
    Assert-Equal 0 @(Get-InterfaceGroupLabel -Inventory @(
        [pscustomobject]@{ InterfaceComment = 'eno50'; InterfaceName = 'eno50 (7)' }
    )).Count
}
Invoke-Test 'Intelligent Prefix groups meaningful phrases and retains basic or unique names' {
    $descriptions = @('GigabitEthernet1/0/1 event-wireless-02 (10.1.1.1)',
        'TenGigabitEthernet1/0/2 EVENT-wireless-03 (10.1.1.2)', 'azf-finance',
        'azf-marketing', 'GigabitEthernet1/0/3', 'TenGigabitEthernet1/0/4',
        'vmbr0', 'vmbr1', 'Unique Customer')
    $rows = @(
        for ($i = 0; $i -lt $descriptions.Count; $i++) {
            [pscustomobject]@{ DeviceId = 1; IfIndex = "$i"; InterfaceComment = $descriptions[$i]; InterfaceName = "$($descriptions[$i]) ($i)" }
        }
    )
    $g = @(Select-IntelligentInterfaceGroup -Inventory $rows -Strategy Prefix)
    Assert-Equal 3 $g.Count
    Assert-Equal 2 ($g | Where-Object Name -eq 'event wireless').InterfaceCount
    Assert-Equal 2 ($g | Where-Object Name -eq 'azf').InterfaceCount
    Assert-Equal 5 ($g | Where-Object Name -eq 'Other Interfaces').InterfaceCount
    Assert-Equal 9 @($g | ForEach-Object { $_.Interfaces }).Count
    Assert-Equal 9 @($g | ForEach-Object { $_.Interfaces.IfIndex } | Select-Object -Unique).Count
}
Invoke-Test 'Intelligent Words supports overlap without duplicate counting per description' {
    $rows = @(
        [pscustomobject]@{ InterfaceComment = 'azf finance'; InterfaceName = 'azf finance (1)' },
        [pscustomobject]@{ InterfaceComment = 'azf marketing'; InterfaceName = 'azf marketing (2)' },
        [pscustomobject]@{ InterfaceComment = 'academy finance'; InterfaceName = 'academy finance (3)' },
        [pscustomobject]@{ InterfaceComment = 'Port 4'; InterfaceName = 'Port 4 (4)' }
    )
    $g = @(Select-IntelligentInterfaceGroup -Inventory $rows -Strategy Words)
    Assert-Equal 3 $g.Count
    Assert-Equal 2 ($g | Where-Object Name -eq azf).InterfaceCount
    Assert-Equal 2 ($g | Where-Object Name -eq finance).InterfaceCount
    Assert-Equal 1 ($g | Where-Object Name -eq 'Other Interfaces').InterfaceCount
}
Invoke-Test 'Intelligent grouping does not infer generic infrastructure labels or numeric suffixes' {
    $rows = @(
        foreach ($name in @('CPU Interface for Slot: 5 Port: 1', 'CPU Interface for Slot: 6 Port: 2',
                'Port 1', 'SFP 1', 'veth101i0', 'veth101i1', 'Loopback0', 'Null0',
                'GigabitEthernet1/0/1', 'TenGigabitEthernet1/0/2', 'eth0', 'eth1',
                'lo', 'lo', 'switch0.1', 'switch0.2')) {
            [pscustomobject]@{ InterfaceComment = $name; InterfaceName = $name }
        }
    )
    foreach ($strategy in @('Prefix', 'Words')) {
        $g = @(Select-IntelligentInterfaceGroup -Inventory $rows -Strategy $strategy)
        Assert-Equal 1 $g.Count
        Assert-Equal $rows.Count $g[0].InterfaceCount
    }
}
Invoke-Test 'Intelligent Prefix is stable across input order and counts actual interfaces' {
    $rows = @(
        [pscustomobject]@{ IfIndex = 1; InterfaceComment = 'GroupA primary'; InterfaceName = 'GroupA primary (1)' },
        [pscustomobject]@{ IfIndex = 2; InterfaceComment = 'GroupA backup'; InterfaceName = 'GroupA backup (2)' },
        [pscustomobject]@{ IfIndex = 3; InterfaceComment = 'GroupA other'; InterfaceName = 'GroupA other (3)' }
    )
    $g = @(Select-IntelligentInterfaceGroup -Inventory $rows)
    $reversed = @(Select-IntelligentInterfaceGroup -Inventory @($rows[2], $rows[1], $rows[0]))
    Assert-Equal ($g.Name -join ',') ($reversed.Name -join ',')
    Assert-Equal 3 $g[0].InterfaceCount
    Assert-Equal 'groupa' $g[0].Name
}
Invoke-Test 'Intelligent empty inventory produces an explicit empty Other group' {
    $g = @(Select-IntelligentInterfaceGroup -Inventory @())
    Assert-Equal 1 $g.Count
    Assert-Equal 'Other Interfaces' $g[0].Name
    Assert-Equal 0 $g[0].InterfaceCount
}
Invoke-Test '12 groups each contain exactly one interface and its own history' {
    Assert-Equal 12 $groups.Count
    for ($i = 0; $i -lt 12; $i++) {
        Assert-Equal 1 $groups[$i].InterfaceCount
        Assert-Equal ($i + 1) $groups[$i].Interfaces[0].IfIndex
        Assert-Equal 2 $groups[$i].Interfaces[0].Samples.Count
    }
}
Invoke-Test 'Two interfaces and cross-device ifIndex collisions stay separate' {
    $other = @(ConvertTo-InterfaceGroupInventory -DeviceId 819 -DeviceName Other `
        -Monitors @(New-ActiveFixture 1 'GROUPA backup') -Traffic @(New-TrafficFixture 1 eth1))
    $g = @(Select-InterfaceGroups -Inventory @($inventory + $other) -GroupName GroupA)
    Assert-Equal 2 $g[0].InterfaceCount
    Assert-Equal 819 $g[0].Interfaces[1].DeviceId
}
Invoke-Test 'Disabled monitor is not Up; missing traffic remains null' {
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router `
        -Monitors @(New-ActiveFixture 2 GroupA 'Up at least 5 min' $false))
    Assert-Equal Disabled $r[0].Status
    Assert-Equal $false $r[0].TrafficAvailable
    Assert-Equal $null $r[0].RxBps
}
Invoke-Test 'Traffic-only interface is Unknown and preserves zero versus missing samples' {
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router -Traffic @(New-TrafficFixture 7 GroupA))
    Assert-Equal Unknown $r[0].Status
    Assert-Equal 0 $r[0].Samples[0].RxBps
    Assert-Equal $null $r[0].Samples[0].TxBps
}
Invoke-Test 'WUG report ID is never used as ifIndex; malformed name cannot join' {
    $t = New-TrafficFixture 7 GroupA
    $t.interfaceName = 'GroupA no index'
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router `
        -Monitors @(New-ActiveFixture 7 GroupA Down) -Traffic @($t) -WarningAction SilentlyContinue)
    Assert-Equal 2 $r.Count
    Assert-Equal Down $r[0].Status
    Assert-Equal Unknown $r[1].Status
    Assert-Equal '' $r[1].IfIndex
}
Invoke-Test 'Literal substring names are not regex and empty groups remain' {
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router -Monitors @(New-ActiveFixture 1 'Group[A] GroupB'))
    $g = @(Select-InterfaceGroups -Inventory $r -GroupName 'Group[A]',GroupB,GroupC)
    Assert-Equal 1 $g[0].InterfaceCount
    Assert-Equal 1 $g[1].InterfaceCount
    Assert-Equal 0 $g[2].InterfaceCount
}
Invoke-Test 'Custom numeric monitor and library description do not match' {
    $m = New-ActiveFixture 1 Unrelated
    $m.monitorTypeClassId = 'custom'
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router -Monitors @($m))
    Assert-Equal 0 $r.Count
}
Invoke-Test 'Down wins across multiple active assignments for one interface' {
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router `
        -Monitors @((New-ActiveFixture 1 GroupA), (New-ActiveFixture 1 GroupA Down)))
    Assert-Equal 1 $r.Count
    Assert-Equal Down $r[0].Status
    Assert-Equal 2 $r[0].ActiveAssignmentIds.Count
}
Invoke-Test 'Performance collector is device-wide and its enabled state is independent of history' {
    $m = [pscustomobject]@{
        id = 'perf-1'; type = 'performance'; enabled = $false
        monitorTypeClassId = '3d199773-46ef-4cbb-b992-7076612c7668'
    }
    $r = @(ConvertTo-InterfaceGroupInventory -DeviceId 1 -DeviceName Router -Monitors @($m) `
        -Traffic @((New-TrafficFixture 1 GroupA), (New-TrafficFixture 2 GroupA)))
    Assert-Equal 'perf-1' $r[0].PerformanceAssignmentIds[0]
    Assert-Equal 'perf-1' $r[1].PerformanceAssignmentIds[0]
    Assert-Equal $false $r[0].PerformanceEnabled
    Assert-Equal $true $r[0].TrafficAvailable
}
$output = Join-Path $env:TEMP ('WUG-InterfaceGroupingTest-' + [guid]::NewGuid().ToString('N'))
$originalProgramData = $env:ProgramData
$env:ProgramData = Join-Path $output 'ProgramData'
try {
    $null = New-Item -ItemType Directory -Path $env:ProgramData -Force -ErrorAction Stop
    . (Join-Path $PSScriptRoot '..\interfaces\InterfaceGroupSnmpHelpers.ps1')
    Invoke-Test 'Generic SNMP credentials preserve explicit V1 V2 V3 and map vault protocol numbers' {
        $v1 = ConvertTo-InterfaceGroupSnmpCredential -Name fixture1 -Version V1 -Stored @{Community='fixture-community'}
        $v2 = ConvertTo-InterfaceGroupSnmpCredential -Name fixture2 -Version V2 -Stored 'fixture-community'
        $v3 = ConvertTo-InterfaceGroupSnmpCredential -Name fixture3 -Version V3 -Stored @{
            Username='fixture-user'; Context='fixture-context'; AuthProtocol=3; AuthPassword='fixture-auth'
            PrivacyProtocol=2; PrivacyPassword='fixture-privacy'
        }
        Assert-Equal V1 $v1.Parameters.Version
        Assert-Equal V2 $v2.Parameters.Version
        Assert-Equal V3 $v3.Parameters.Version
        Assert-Equal SHA256 $v3.Parameters.AuthProtocol
        Assert-Equal AES128 $v3.Parameters.PrivacyProtocol
        Assert-Equal fixture-context $v3.Parameters.Context
        foreach ($bad in @(
            @{ Username='u'; AuthProtocol=0; PrivacyProtocol=2; PrivacyPassword='p' },
            @{ Username='u'; AuthProtocol=3; PrivacyProtocol=0 },
            @{ Username='u'; AuthProtocol=99; PrivacyProtocol=0 }
        )) {
            $thrown = $false
            try { $null = ConvertTo-InterfaceGroupSnmpCredential -Name fixture -Version V3 -Stored $bad } catch { $thrown = $true }
            Assert-Equal $true $thrown
        }
    }
    Invoke-Test 'SNMP table joins raw descriptions by numeric ifIndex with Unicode and empty aliases intact' {
        $rows = @(
            [pscustomobject]@{OID='1.3.6.1.2.1.2.2.1.2.7';Value='eth7';Type='OctetString'},
            [pscustomobject]@{OID='.1.3.6.1.2.1.31.1.1.1.1.7';Value='port7';Type='OctetString'},
            [pscustomobject]@{OID='1.3.6.1.2.1.31.1.1.1.18.7';Value=('Group' + [char]0xE9);Type='OctetString'},
            [pscustomobject]@{OID='1.3.6.1.2.1.31.1.1.1.18.8';Value='';Type='OctetString'}
        )
        $ports = @(ConvertFrom-InterfaceGroupSnmpTable -Rows $rows)
        Assert-Equal 2 $ports.Count
        Assert-Equal port7 $ports[0].IfName
        Assert-Equal ('Group' + [char]0xE9) $ports[0].IfAlias
        Assert-Equal '' $ports[1].IfAlias
        $thrown = $false
        try { $null = ConvertFrom-InterfaceGroupSnmpTable -Rows @($rows + $rows[0]) } catch { $thrown = $true }
        Assert-Equal $true $thrown
    }
    Invoke-Test 'Bundled SNMP wrappers use Walk for V1, BulkWalk for V2 and preserve raw UTF8 text' {
        Initialize-InterfaceGroupSnmp
        function Invoke-SNMPWalk {
            [CmdletBinding()]param($Target,$Table,$Version,$Port,$Timeout,$Community)
            Assert-Equal V1 $Version
            [pscustomobject]@{ Variables=@([Lextm.SharpSnmpLib.Variable]::new(
                [Lextm.SharpSnmpLib.ObjectIdentifier]::new("$Table.1"),
                [Lextm.SharpSnmpLib.OctetString]::new([Text.Encoding]::UTF8.GetBytes('raw-' + [char]0xE9)))) }
        }
        function Invoke-SNMPBulkWalk {
            [CmdletBinding()]param($Target,$Table,$Version,$Port,$Timeout,$Community,$MaxRepetitions)
            Assert-Equal V2 $Version
            [pscustomobject]@{ Variables=@([Lextm.SharpSnmpLib.Variable]::new(
                [Lextm.SharpSnmpLib.ObjectIdentifier]::new("$Table.1"),
                [Lextm.SharpSnmpLib.OctetString]::new('v2-name'))) }
        }
        $v1 = @(Invoke-InterfaceGroupSnmpWalk -Target 127.0.0.1 -Oid '1.3.6.1.2.1.2.2.1.2' -Credential @{Version='V1';Community='fixture'})
        $v2 = @(Invoke-InterfaceGroupSnmpWalk -Target 127.0.0.1 -Oid '1.3.6.1.2.1.2.2.1.2' -Credential @{Version='V2';Community='fixture'})
        Assert-Equal ('raw-' + [char]0xE9) $v1[0].Value
        Assert-Equal v2-name $v2[0].Value
    }
    Invoke-Test 'SNMPv3 wrapper retains context and authNoPriv provider without dummy credentials' {
        Initialize-InterfaceGroupSnmp
        function Get-SNMPv3CachedDiscovery { [CmdletBinding()]param($Target,$Port,$Timeout) 'fixture-report' }
        function Invoke-SNMPBulkWalk {
            [CmdletBinding()]param($Target,$Table,$Version,$Port,$Timeout,$Community,$MaxRepetitions,$ContextName,$Privacy,$Report)
            Assert-Equal V3 $Version
            Assert-Equal fixture-user $Community
            Assert-Equal fixture-context $ContextName
            Assert-Equal fixture-report $Report
            Assert-Equal $true ($Privacy -is [Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider])
            [pscustomobject]@{Variables=@()}
        }
        $null = Invoke-InterfaceGroupSnmpWalk -Target 127.0.0.1 -Oid '1.3.6.1.2.1.2.2.1.2' -Credential @{
            Version='V3';Username='fixture-user';Context='fixture-context';AuthProtocol='SHA';AuthPassword='fixture-auth';PrivacyProtocol='None'
        }
    }
    Invoke-Test 'Ordered credentials stop after first interface read, retain WUG status and include Unmonitored SNMP-only ports' {
        $calls = [System.Collections.Generic.List[string]]::new()
        function Get-WUGDevice { [CmdletBinding()]param($DeviceId,$View) [pscustomobject]@{id=$DeviceId;networkAddress='127.0.0.1';displayName='Router'} }
        function Invoke-InterfaceGroupSnmpWalk {
            [CmdletBinding()]param($Target,$Oid,$Credential,$Port,$Timeout)
            $calls.Add("$($Credential.Version):$Oid")
            if ($Credential.Version -eq 'V1') { throw 'fixture-authentication-error' }
            [pscustomobject]@{OID="$Oid.1";Value='GroupA';Type='OctetString'}
            [pscustomobject]@{OID="$Oid.2";Value='GroupB';Type='OctetString'}
        }
        $rows = @(ConvertTo-InterfaceGroupInventory -DeviceId 818 -DeviceName Router -Monitors @(New-ActiveFixture 1 'stored-comment') -Traffic @())
        $credentials = @([pscustomobject]@{Name='first';Parameters=@{Version='V1'}},[pscustomobject]@{Name='second';Parameters=@{Version='V2'}},[pscustomobject]@{Name='third';Parameters=@{Version='V3'}})
        $enriched = @(Add-InterfaceGroupSnmpInventory -Inventory $rows -DeviceId 818 -Credentials $credentials -IncludeSnmpOnly -WarningAction SilentlyContinue)
        Assert-Equal 4 $calls.Count
        Assert-Equal 2 $enriched.Count
        Assert-Equal Up $enriched[0].Status
        Assert-Equal stored-comment $enriched[0].InterfaceComment
        Assert-Equal GroupA $enriched[0].IfAlias
        Assert-Equal second $enriched[0].SnmpCredentialName
        Assert-Equal Unmonitored $enriched[1].Status
        Assert-Equal 'SNMP-only' $enriched[1].InventorySource
        Assert-Equal $null $enriched[1].RxBps
        Assert-Equal 0 $enriched[1].Samples.Count
        Assert-Equal 1 (Select-InterfaceGroups -Inventory $enriched -GroupName GroupB -MatchMode Exact).InterfaceCount
        Assert-Equal 'GroupA,GroupB' (@(Get-InterfaceGroupLabel -Inventory $enriched) -join ',')
    }
    Invoke-Test 'SNMP exhaustion and incomplete IF-MIB warn with explicit flags or terminate by policy' {
        function Get-WUGDevice { [CmdletBinding()]param($DeviceId,$View) [pscustomobject]@{id=$DeviceId;networkAddress='127.0.0.1';displayName='Router'} }
        function Invoke-InterfaceGroupSnmpWalk { [CmdletBinding()]param($Target,$Oid,$Credential,$Port,$Timeout) throw 'fixture-secret-must-not-log' }
        $rows = @(ConvertTo-InterfaceGroupInventory -DeviceId 818 -DeviceName Router -Monitors @(New-ActiveFixture 1 'GroupA') -Traffic @())
        $credentials = @([pscustomobject]@{Name='fixture';Parameters=@{Version='V2'}})
        $warnings = @()
        $r = @(Add-InterfaceGroupSnmpInventory -Inventory $rows -DeviceId 818 -Credentials $credentials -WarningVariable warnings -WarningAction SilentlyContinue)
        Assert-Equal Failed $r[0].SnmpStatus
        Assert-Equal GroupA $r[0].InterfaceComment
        Assert-Equal $false (($warnings -join ',').Contains('fixture-secret-must-not-log'))
        $thrown = $false
        try { $null = Add-InterfaceGroupSnmpInventory -Inventory $rows -DeviceId 818 -Credentials $credentials -FailureAction Stop -WarningAction SilentlyContinue } catch { $thrown = $true }
        Assert-Equal $true $thrown
        function Invoke-InterfaceGroupSnmpWalk {
            [CmdletBinding()]param($Target,$Oid,$Credential,$Port,$Timeout)
            if ($Oid -eq '1.3.6.1.2.1.2.2.1.2') { [pscustomobject]@{OID="$Oid.1";Value='eth1';Type='OctetString'} }
        }
        $r = @(Add-InterfaceGroupSnmpInventory -Inventory $rows -DeviceId 818 -Credentials $credentials -WarningAction SilentlyContinue)
        Assert-Equal Partial $r[0].SnmpStatus
    }
    Invoke-Test 'SNMP profile validates aligned versions and stores only credential references' {
        $path = Join-Path $output 'snmp-profile.json'
        $settings = @{DeviceId=@(818);UseSnmp=$true;SnmpCredentialNames=@('Generic.V1','Generic.V2','Generic.V3');SnmpCredentialVersions=@('V1','V2','V3');IncludeSnmpOnly=$true}
        $null = Save-InterfaceGroupProfile -Path $path -Settings $settings
        $p = Read-InterfaceGroupProfile -Path $path
        Assert-Equal 3 $p.SnmpCredentialNames.Count
        Assert-Equal V3 $p.SnmpCredentialVersions[2]
        $settings.SnmpCredentialVersions = @('V2')
        $thrown = $false
        try { $null = Save-InterfaceGroupProfile -Path $path -Settings $settings } catch { $thrown = $true }
        Assert-Equal $true $thrown
    }
    Invoke-Test 'Grouping change snapshots detect additions removals aliases and membership without false first-run changes' {
        $a = [pscustomobject]@{DeviceId=1;IfIndex=1;DeviceName='Router';InterfaceComment='';InterfaceName='';IfAlias='GroupA'}
        $g = @(Select-InterfaceGroups -Inventory @($a) -GroupName GroupA,GroupB -MatchMode Token)
        $before = New-InterfaceGroupSnapshot -Inventory @($a) -Groups $g
        Assert-Equal 0 @(Compare-InterfaceGroupSnapshot -Current $before).Count
        $a.IfAlias = 'GroupB'
        $b = [pscustomobject]@{DeviceId=1;IfIndex=2;DeviceName='Router';InterfaceComment='GroupB';InterfaceName=''}
        $g = @(Select-InterfaceGroups -Inventory @($a,$b) -GroupName GroupA,GroupB -MatchMode Token)
        $after = New-InterfaceGroupSnapshot -Inventory @($a,$b) -Groups $g
        $changes = @(Compare-InterfaceGroupSnapshot -Current $after -Previous $before)
        Assert-Equal 2 $changes.Count
        Assert-Equal 'DescriptionsChanged;MembershipChanged' $changes[0].Change
        Assert-Equal Added $changes[1].Change
        $b | Add-Member -NotePropertyName SnmpStatus -NotePropertyValue Failed
        $final = New-InterfaceGroupSnapshot -Inventory @($b) -Groups @(Select-InterfaceGroups -Inventory @($b) -GroupName GroupB)
        $changes = @(Compare-InterfaceGroupSnapshot -Current $final -Previous $after)
        Assert-Equal Removed $changes[0].Change
        Assert-Equal $true $changes[0].UncertainSnmpCoverage
    }
    Invoke-Test 'Token matching prevents GroupA matching GroupAB and treats metacharacters literally' {
        $rows = @(
            [pscustomobject]@{ InterfaceComment = 'GroupA / customer'; InterfaceName = '' },
            [pscustomobject]@{ InterfaceComment = 'GroupAB'; InterfaceName = '' },
            [pscustomobject]@{ InterfaceComment = '_GroupA'; InterfaceName = '' },
            [pscustomobject]@{ InterfaceComment = 'Group[A]'; InterfaceName = '' }
        )
        Assert-Equal 1 (Select-InterfaceGroups -Inventory $rows -GroupName GroupA -MatchMode Token).InterfaceCount
        Assert-Equal 3 (Select-InterfaceGroups -Inventory $rows -GroupName GroupA -MatchMode Substring).InterfaceCount
        Assert-Equal 1 (Select-InterfaceGroups -Inventory $rows -GroupName 'Group[A]' -MatchMode Token).InterfaceCount
        Assert-Equal 0 (Select-InterfaceGroups -Inventory $rows -GroupName GroupA -MatchMode Exact).InterfaceCount
        Assert-Equal 1 (Select-InterfaceGroups -Inventory $rows -GroupName GroupAB -MatchMode Exact).InterfaceCount
    }
    Invoke-Test 'Freshness tests exact threshold, missing, invalid, future and historic data without fake zeros' {
        $rows = @(
            for ($i = 0; $i -lt 5; $i++) {
                [pscustomobject]@{ DeviceId = 1; IfIndex = "$($i + 1)"; Samples = @()
                    PollTimeUtc = @('2026-11-08T11:00:00Z', '2026-11-08T10:59:59Z', $null, 'invalid', '2026-11-08T12:06:00Z')[$i] }
            }
        )
        Add-InterfaceGroupFreshness -Inventory $rows -Now ([DateTimeOffset]'2026-11-08T12:00:00Z') -StaleAfterMinutes 60 -WarningAction SilentlyContinue
        Assert-Equal 'Fresh,Stale,Missing,Invalid,Future' ($rows.Freshness -join ',')
        Assert-Equal 60 $rows[0].AgeMinutes
        Assert-Equal $null $rows[2].AgeMinutes
        Assert-Equal '1:1' $rows[0].InterfaceKey
    }
    Invoke-Test 'Health counts unique interfaces across overlapping groups and separates missing from disabled collectors' {
        Add-InterfaceGroupFreshness -Inventory $inventory
        $h = Get-InterfaceGroupHealth -Inventory @($inventory + $inventory)
        Assert-Equal 12 $h.Interfaces
        Assert-Equal 12 $h.MissingPerformanceCollector
        Assert-Equal 0 $h.DisabledPerformanceCollector
    }
    Invoke-Test 'Freshness preserves typed JSON date milliseconds and timezone offsets' {
        $stamp = [DateTimeOffset]::Parse('2026-11-08T11:00:00.923-05:00')
        $rows = @(
            [pscustomobject]@{ DeviceId=1; IfIndex=1; PollTimeUtc=$stamp; Samples=@() },
            [pscustomobject]@{ DeviceId=1; IfIndex=2; PollTimeUtc=$stamp.UtcDateTime; Samples=@() },
            [pscustomobject]@{ DeviceId=1; IfIndex=3; PollTimeUtc=[DateTime]::SpecifyKind($stamp.UtcDateTime, [DateTimeKind]::Unspecified); Samples=@() }
        )
        Add-InterfaceGroupFreshness -Inventory $rows -Now $stamp.AddHours(1)
        foreach ($row in $rows) {
            Assert-Equal '2026-11-08T16:00:00.9230000Z' $row.LastSampleUtc
            Assert-Equal Fresh $row.Freshness
            Assert-Equal 60 $row.AgeMinutes
        }
    }
    Invoke-Test 'CSV decisions pin, merge, rename and exclude without losing uninstructed membership' {
        $d = @(New-InterfaceGroupReview -Inventory $inventory -Groups $groups)
        Assert-Equal 'False' $d[0].Apply
        $d[0].Apply = 'True'; $d[0].Groups = 'Customer Merge'
        $d[1].Apply = 'True'; $d[1].Groups = 'Customer Merge'
        $d[2].Apply = 'True'; $d[2].Exclude = 'True'
        $g = @(Set-InterfaceGroupReview -Inventory $inventory -Groups $groups -Decisions $d)
        Assert-Equal 2 ($g | Where-Object Name -eq 'Customer Merge').InterfaceCount
        Assert-Equal 0 @($g | Where-Object Name -eq GroupA).Count
        Assert-Equal 0 @($g | Where-Object Name -eq GroupC).Count
        Assert-Equal 1 ($g | Where-Object Name -eq GroupD).InterfaceCount
        $csv = Join-Path $output 'review.csv'
        $null = Export-InterfaceGroupReview -Decisions $d -Path $csv
        $loaded = @(Import-Csv -LiteralPath $csv)
        Assert-Equal 12 $loaded.Count
        Assert-Equal 2 (@(Set-InterfaceGroupReview -Inventory $inventory -Groups $groups -Decisions $loaded) | Where-Object Name -eq 'Customer Merge').InterfaceCount
    }
    Invoke-Test 'Pinned decisions reject duplicates, malformed flags and changed descriptions' {
        foreach ($scenario in @('Duplicate', 'Flag', 'Changed', 'BlankGroup')) {
            $d = @(New-InterfaceGroupReview -Inventory $inventory -Groups $groups)
            $d[0].Apply = 'True'
            switch ($scenario) {
                'Duplicate' { $d += $d[0] }
                'Flag' { $d[0].Exclude = 'maybe' }
                'Changed' { $d[0].InterfaceComment = 'changed ifIndex mapping' }
                'BlankGroup' { $d[0].Groups = '' }
            }
            $thrown = $false
            try { $null = Set-InterfaceGroupReview -Inventory $inventory -Groups $groups -Decisions $d } catch { $thrown = $true }
            Assert-Equal $true $thrown
        }
    }
    Invoke-Test 'Interactive review supports keep, merge, exclude and explicit confirmation' {
        $script:reviewAnswers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('Shared', '-', 'YES')) { $script:reviewAnswers.Enqueue($answer) }
        function Read-Host { param($Prompt) $script:reviewAnswers.Dequeue() }
        $d = @(New-InterfaceGroupReview -Inventory $inventory[0..1] -Groups $groups)
        $r = @(Invoke-InterfaceGroupReview -Decisions $d)
        Assert-Equal Shared $r[0].Groups
        Assert-Equal True $r[1].Exclude
        $script:reviewAnswers.Enqueue(''); $script:reviewAnswers.Enqueue('NO')
        $thrown = $false
        try { $null = Invoke-InterfaceGroupReview -Decisions @($d[0]) } catch { $thrown = $_.Exception.Message -like '*cancelled*' }
        Assert-Equal $true $thrown
    }
    Invoke-Test 'PreviewOnly returns CSV without modifying applied decisions; WhatIf writes nothing' {
        $preview = Join-Path $output 'preview-only.csv'
        $r = Update-InterfaceGroupSelection -Inventory $inventory -Groups $groups -OutputDirectory $output -PreviewOnly -PreviewPath $preview
        Assert-Equal 12 $r.Decisions.Count
        Assert-Equal $true (Test-Path -LiteralPath $r.PreviewPath)
        $before = (Get-FileHash $preview).Hash
        $r = Update-InterfaceGroupSelection -Inventory $inventory -Groups $groups -OutputDirectory $output -ReviewPath $preview -PreviewOnly
        Assert-Equal $before (Get-FileHash $preview).Hash
        $new = Join-Path $output 'whatif-review.csv'
        $null = Export-InterfaceGroupReview -Decisions $r.Decisions -Path $new -WhatIf
        Assert-Equal $false (Test-Path -LiteralPath $new)
    }
    Invoke-Test 'Profile roundtrip resolves relative paths and preserves booleans and arrays' {
        $profilePath = Join-Path $output 'profiles\example.json'
        $settings = @{ DeviceId = @(818, 819); Mode = 'NamedGroups'; GroupName = @('GroupA', 'GroupB'); MatchMode = 'Token'
            OutputDirectory = 'output'; ReviewPath = 'review.csv'; StaleAfterMinutes = 30; CreateWugGroups = $false }
        $null = Save-InterfaceGroupProfile -Path $profilePath -Settings $settings
        $p = Read-InterfaceGroupProfile -Path $profilePath
        Assert-Equal 2 $p.DeviceId.Count
        Assert-Equal $false $p.CreateWugGroups
        Assert-Equal (Join-Path $output 'profiles\output') $p.OutputDirectory
        $bytes = [IO.File]::ReadAllBytes($profilePath)
        Assert-Equal 'EF-BB-BF' ([BitConverter]::ToString($bytes[0..2]))
    }
    Invoke-Test 'Profiles reject secret settings, string booleans, invalid flags and conflicting scopes without replacing valid file' {
        $path = Join-Path $output 'profiles\valid.json'
        $null = Save-InterfaceGroupProfile -Path $path -Settings @{ AllDevices = $true; Mode = 'AllInterfaces' }
        $hash = (Get-FileHash $path).Hash
        foreach ($bad in @(
            @{ AllDevices = $true; Password = 'not-a-real-secret' },
            @{ AllDevices = 'false' },
            @{ AllDevices = $true; DeviceId = @(818) },
            @{ AllDevices = $true; MatchMode = 'bad' },
            @{ AllDevices = $true; RangeN = 0 },
            @{ AllDevices = $true; Review = $true }
        )) {
            $thrown = $false
            try { $null = Save-InterfaceGroupProfile -Path $path -Settings $bad } catch { $thrown = $true }
            Assert-Equal $true $thrown
            Assert-Equal $hash (Get-FileHash $path).Hash
        }
    }
    Invoke-Test 'Output run lock prevents overlapping manual or scheduled runs and releases reliably' {
        $path = Join-Path $output 'lock-test'
        $first = Open-InterfaceGroupRunLock -OutputDirectory $path
        try {
            $thrown = $false
            try { $second = Open-InterfaceGroupRunLock -OutputDirectory $path; $second.Dispose() } catch { $thrown = $_.Exception.Message -like '*run lock*' }
            Assert-Equal $true $thrown
        }
        finally { $first.Dispose() }
        $second = Open-InterfaceGroupRunLock -OutputDirectory $path
        $second.Dispose()
    }
    Invoke-Test 'Stable pages survive reordering and new categories with no name-collision shortcuts' {
        Assert-Equal (Get-WUGDashboardGroupPageName -Name GroupA) (Get-WUGDashboardGroupPageName -Name ' groupa ')
        Assert-Equal $false ((Get-WUGDashboardGroupPageName -Name 'a/b') -eq (Get-WUGDashboardGroupPageName -Name 'a-b'))
        $path = Join-Path $output 'stable'
        $null = Export-InterfaceGroupDashboards -Groups $groups -OutputDirectory $path
        $page = $groups[0].PageName
        $null = Export-InterfaceGroupDashboards -Groups @($groups[11], $groups[0]) -OutputDirectory $path
        Assert-Equal $page $groups[0].PageName
        $manifest = Get-Content (Join-Path $path 'groups.json') -Raw | ConvertFrom-Json
        Assert-Equal 2 @($manifest).Count
        Assert-Equal $true ([IO.File]::ReadAllText((Join-Path $path 'index.html')).Contains($page))
    }
    Invoke-Test 'Manifest rejects forged stable filenames and retains legacy pack support' {
        $path = Join-Path $output 'manifest'
        $null = New-Item -ItemType Directory -Path $path
        [IO.File]::WriteAllText((Join-Path $path 'groups.json'), '[{"Name":"GroupA","PageName":"../outside.html"}]')
        $thrown = $false
        try { $null = Get-WUGDashboardPackFiles -SourcePath $path } catch { $thrown = $true }
        Assert-Equal $true $thrown
        [IO.File]::WriteAllText((Join-Path $path 'groups.json'), '[{"Name":"GroupA"},{"Name":"GroupB"}]')
        Assert-Equal 'group-01.html,group-02.html,index.html' (@(Get-WUGDashboardPackFiles -SourcePath $path) -join ',')
    }
    function Invoke-EntryFixture {
        param([string]$Script, [hashtable]$Parameters, [switch]$FailApi,[System.Collections.Generic.List[string]]$Requests)
        $saved = @{}
        foreach ($name in @('WhatsUpServerBaseURI', 'WUGBearerHeaders', 'expiry')) {
            $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
            $saved[$name] = @{ Exists = $null -ne $variable; Value = $(if ($variable) { $variable.Value } else { $null }) }
        }
        try {
            $global:WhatsUpServerBaseURI = 'https://offline.fixture'
            $global:WUGBearerHeaders = @{ Authorization = 'Bearer fixture' }
            $global:expiry = (Get-Date).AddDays(1)
            function Invoke-RestMethod {
                [CmdletBinding()]
                param($Uri, $Method, $Headers, $Body)
                if ($null -ne $Requests) {$Requests.Add([string]$Uri)}
                if ($FailApi) { throw 'offline fixture API failure' }
                if ($Method -ne 'GET') { throw "Unexpected configuration write: $Method $Uri" }
                if ($Uri -match '/devices/818\?') { return [pscustomobject]@{ data = [pscustomobject]@{ id = 818; displayName = 'Fixture Router' } } }
                if ($Uri -match '/devices/818/monitors/') { return [pscustomobject]@{ data = @(New-ActiveFixture 1 'customer GroupA'); paging = @{} } }
                if ($Uri -match '/devices/818/reports/interface-traffic') { return [pscustomobject]@{ data = @(New-TrafficFixture 1 eth0); paging = @{} } }
                if ($Uri -match '/device-groups/-2/devices/-') { return [pscustomobject]@{ data = @{devices=@([pscustomobject]@{id=818;displayName='Fixture Router';networkAddress='127.0.0.1'})};paging=@{} } }
                throw "Unexpected fixture URL: $Uri"
            }
            & $Script @Parameters
        }
        finally {
            foreach ($name in $saved.Keys) {
                if ($saved[$name].Exists) { Set-Variable -Name $name -Value $saved[$name].Value -Scope Global }
                else { Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue }
            }
        }
    }
    Invoke-Test 'Both entry scripts honor PreviewOnly over publishing and WUG writes using real API wrappers' {
        foreach ($scriptName in @('Example-InterfaceGrouping', 'Invoke-InterfaceGrouping')) {
            $path = Join-Path $output "entry-preview\$scriptName"
            $r = Invoke-EntryFixture -Script (Join-Path $PSScriptRoot "..\interfaces\$scriptName.ps1") -Parameters @{
                DeviceId = @(818); GroupName = @('GroupA'); PreviewOnly = $true
                OutputDirectory = $path; PublishToWug = $true; CreateWugGroups = $true
            }
            Assert-Equal 1 $r.Health.Interfaces
            Assert-Equal 1 $r.Groups[0].InterfaceCount
            Assert-Equal $null $r.IndexPath
            Assert-Equal $null $r.Publication
            Assert-Equal $true (Test-Path -LiteralPath $r.PreviewPath)
            Assert-Equal $false (Test-Path -LiteralPath (Join-Path $path 'index.html'))
        }
    }
    Invoke-Test 'Both browser-review entry paths export HTML and CSV only, honoring WhatIf' {
        foreach ($scriptName in @('Example-InterfaceGrouping','Invoke-InterfaceGrouping')) {
            $path=Join-Path $output "browser-entry\$scriptName"
            $parameters=@{DeviceId=@(818);GroupName=@('GroupA');BrowserReview=$true;OutputDirectory=$path;PublishToWug=$true;CreateWugGroups=$true}
            $r=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot "..\interfaces\$scriptName.ps1") -Parameters $parameters
            Assert-Equal $true (Test-Path -LiteralPath $r.ReviewHtmlPath)
            Assert-Equal $true (Test-Path -LiteralPath $r.PreviewPath)
            Assert-Equal $null $r.IndexPath
            Assert-Equal $null $r.Publication
            Assert-Equal $false (Test-Path (Join-Path $path 'inventory-snapshot.json'))
            $parameters.WhatIf=$true;$parameters.OutputDirectory=Join-Path $output "browser-whatif\$scriptName"
            $r=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot "..\interfaces\$scriptName.ps1") -Parameters $parameters
            Assert-Equal $false (Test-Path $parameters.OutputDirectory)
        }
    }
    Invoke-Test 'Entry scripts reject incomplete SNMP options before accessing vault or connecting' {
        foreach ($scriptName in @('Example-InterfaceGrouping', 'Invoke-InterfaceGrouping')) {
            $thrown = $false
            try { & (Join-Path $PSScriptRoot "..\interfaces\$scriptName.ps1") -DeviceId 818 -UseSnmp } catch { $thrown = $_.Exception.Message -like '*aligned, nonempty*' }
            Assert-Equal $true $thrown
        }
    }
    Invoke-Test 'Wizard cancellation and WhatIf cause no prompts or persistent configuration writes' {
        $wizard = Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1'
        $path = Join-Path $output 'wizard-cancel'
        function Read-Host { param($Prompt) throw 'WhatIf must not prompt' }
        $null = & $wizard -ProfileDirectory $path -WhatIf -WarningAction SilentlyContinue
        Assert-Equal $false (Test-Path $path)
        function Read-Host { param($Prompt) 'Q' }
        $null = & $wizard -ProfileDirectory $path
        Assert-Equal $false (Test-Path $path)
    }
    Invoke-Test 'Wizard saves a reusable profile but does not generate dashboards without explicit approval' {
        $savedProgramData = $env:ProgramData
        try {
            $env:ProgramData = Join-Path $output 'wizard-programdata'
            $answers = [System.Collections.Generic.Queue[string]]::new()
            foreach ($answer in @('N','clickops','1','818','2','1','','N','N','N','3','N')) { $answers.Enqueue($answer) }
            function Read-Host { param($Prompt) if (-not $answers.Count) { throw "Unexpected prompt: $Prompt" }; $answers.Dequeue() }
            $profiles = Join-Path $env:ProgramData 'profiles'
            $null = Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ ProfileDirectory=$profiles;SkipSchedule=$true }
            Assert-Equal 0 $answers.Count
            $profile = Read-InterfaceGroupProfile -Path (Join-Path $profiles 'clickops.json')
            Assert-Equal AllInterfaces $profile.Mode
            Assert-Equal $true (Test-Path (Join-Path $profile.OutputDirectory 'clickops-preview.csv'))
            Assert-Equal $false (Test-Path (Join-Path $profile.OutputDirectory 'index.html'))
            Assert-Equal $false (Test-Path (Join-Path $profile.OutputDirectory 'inventory-snapshot.json'))
        }
        finally { $env:ProgramData = $savedProgramData }
    }
    Invoke-Test 'Wizard saves reusable phrase rules and approval reuses one collection rather than fetching again' {
        $profiles=Join-Path $output 'wizard-rules\profiles'
        $answers=[System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('N','rules-demo','1','818','5','Tunnels','GroupA','Contains','InterfaceComment','N','FirstMatch','1','','N','N','N','3','Y')) {$answers.Enqueue($answer)}
        function Read-Host {param($Prompt) if(-not $answers.Count){throw "Unexpected prompt: $Prompt"};$answers.Dequeue()}
        $requests=[System.Collections.Generic.List[string]]::new()
        $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true} -Requests $requests
        Assert-Equal 0 $answers.Count
        Assert-Equal 3 $requests.Count
        Assert-Equal 1 @($requests | Where-Object {$_ -like '*reports/interface-traffic*'}).Count
        $profile=Read-InterfaceGroupProfile -Path (Join-Path $profiles 'rules-demo.json')
        Assert-Equal Rules $profile.Mode
        Assert-Equal FirstMatch $profile.RuleMode
        Assert-Equal 'GroupA' $profile.Rules[0].Value
        $pack=Get-Content (Join-Path $profile.OutputDirectory 'groups.json') -Raw | ConvertFrom-Json
        Assert-Equal Tunnels $pack[0].Name
        Assert-Equal 1 $pack[0].InterfaceCount
        Assert-Equal $true (Test-Path (Join-Path $profile.OutputDirectory 'collected-inventory.json'))
    }
    Invoke-Test 'Wizard publishing accepts explicit NmConsole path or cancellation without saving a profile' {
        $profiles=Join-Path $output 'wizard-publishing\profiles'
        $console=Join-Path $output 'wizard-publishing\Html\NmConsole'
        $null=New-Item -ItemType Directory -Path $console -Force
        [IO.File]::WriteAllText((Join-Path $console 'web.config'),'<configuration><system.web><authentication mode="Forms" /></system.web></configuration>',[Text.UTF8Encoding]::new($true))
        $answers=[System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('N','publish-cancel','1','818','2','1','','N','N','Y','Q')) {$answers.Enqueue($answer)}
        function Read-Host {param($Prompt) if(-not $answers.Count){throw "Unexpected prompt: $Prompt"};$answers.Dequeue()}
        $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
        Assert-Equal 0 $answers.Count
        Assert-Equal $false (Test-Path (Join-Path $profiles 'publish-cancel.json'))
        foreach ($answer in @('N','publish-explicit','1','818','2','1','','N','N','Y',$console,'3','N')) {$answers.Enqueue($answer)}
        $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
        Assert-Equal 0 $answers.Count
        $profile=Read-InterfaceGroupProfile -Path (Join-Path $profiles 'publish-explicit.json')
        Assert-Equal $console $profile.NmConsolePath
        Assert-Equal $true $profile.PublishToWug
        Assert-Equal $false (Test-Path (Join-Path $profile.OutputDirectory 'index.html'))
    }
    Invoke-Test 'Wizard corrects saved publishing failures without restarting or silently changing the profile' {
        $profiles=Join-Path $output 'wizard-publish-repair\profiles'
        $console=Join-Path $output 'wizard-publish-repair\Html\NmConsole'
        $null=New-Item -ItemType Directory -Path $console -Force
        [IO.File]::WriteAllText((Join-Path $console 'web.config'),'<configuration><system.web><authentication mode="Forms" /></system.web></configuration>',[Text.UTF8Encoding]::new($true))
        foreach ($repair in @('1','2','Q')) {
            $profilePath=Join-Path $profiles 'repair.json'
            $packPath=Join-Path $output "wizard-repaired-$repair"
            $null=Save-InterfaceGroupProfile -Path $profilePath -Settings @{
                DeviceId=@(818);Mode='AllInterfaces';PublishToWug=$true;PackName='repair'
                NmConsolePath=(Join-Path $output 'missing-console');OutputDirectory=$packPath;CreateWugGroups=$true
            }
            $before=(Get-FileHash $profilePath).Hash
            $answers=[System.Collections.Generic.Queue[string]]::new()
            foreach ($answer in @('E','1','R',$repair)) {$answers.Enqueue($answer)}
            if ($repair -eq '2') {$answers.Enqueue($console)}
            if ($repair -ne 'Q') {foreach($answer in @('3','N')) {$answers.Enqueue($answer)}}
            function Read-Host {param($Prompt) if(-not $answers.Count){throw "Unexpected prompt: $Prompt"};$answers.Dequeue()}
            $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true} -WarningAction SilentlyContinue
            Assert-Equal 0 $answers.Count
            $profile=Read-InterfaceGroupProfile -Path $profilePath
            Assert-Equal $true $profile.CreateWugGroups
            if ($repair -eq 'Q') {
                Assert-Equal $before (Get-FileHash $profilePath).Hash
                Assert-Equal $false (Test-Path $packPath)
            }
            else {
                Assert-Equal $true (Test-Path (Join-Path $packPath 'repair-preview.csv'))
                Assert-Equal $false (Test-Path (Join-Path $packPath 'index.html'))
                if ($repair -eq '1') {
                    foreach ($key in @('PublishToWug','NmConsolePath','PackName')) {Assert-Equal $false $profile.ContainsKey($key)}
                }
                else {
                    Assert-Equal $true $profile.PublishToWug
                    Assert-Equal $console $profile.NmConsolePath
                }
            }
        }
    }
    Invoke-Test 'Wizard skipped SNMP credential cancels before saving and never probes devices' {
        $savedLocal=$env:LOCALAPPDATA
        $savedScope=$env:WUG_VAULT_SCOPE
        try {
            $env:LOCALAPPDATA=Join-Path $output 'wizard-skipped-vault'
            $env:WUG_VAULT_SCOPE='CurrentUser'
            . (Join-Path $PSScriptRoot '..\discovery\DiscoveryHelpers.ps1')
            $fixtureSecret=[Security.SecureString]::new()
            try {
                foreach ($character in 'offline-fixture-community'.ToCharArray()) { $fixtureSecret.AppendChar($character) }
                $null=Save-DiscoveryCredential -Name 'Fixture.Skip' -SecureSecret $fixtureSecret
            }
            finally { $fixtureSecret.Dispose() }
            $profiles=Join-Path $output 'wizard-skipped\profiles'
            $answers=[System.Collections.Generic.Queue[string]]::new()
            foreach ($answer in @('N','skipped','1','818','2','1','','Y','N','Fixture.Skip','V2','Y','1','','','Y','N')) {$answers.Enqueue($answer)}
            function Read-Host {param($Prompt) if(-not $answers.Count){throw "Unexpected prompt: $Prompt"};$answers.Dequeue()}
            $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
            Assert-Equal 0 $answers.Count
            Assert-Equal $false (Test-Path (Join-Path $profiles 'skipped.json'))
            Assert-Equal $true (Test-Path (Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault\Fixture.Skip.cred'))
        }
        finally {$env:LOCALAPPDATA=$savedLocal;$env:WUG_VAULT_SCOPE=$savedScope}
    }
    Invoke-Test 'Wizard applies CSV and interactive edits for this run even when operator declines saving them' {
        $savedProgramData = $env:ProgramData
        try {
            $env:ProgramData = Join-Path $output 'wizard-review-programdata'
            foreach ($reviewMode in @('1','2')) {
                $answers = [System.Collections.Generic.Queue[string]]::new()
                $name = "review-$reviewMode"
                foreach ($answer in @('N',$name,'1','818','2','1','','N','N','N',$reviewMode)) { $answers.Enqueue($answer) }
                if ($reviewMode -eq '1') { foreach ($answer in @('Y','N','Y')) { $answers.Enqueue($answer) } }
                else { foreach ($answer in @('Pinned','YES','N','Y')) { $answers.Enqueue($answer) } }
                function Read-Host { param($Prompt) if (-not $answers.Count) { throw "Unexpected prompt: $Prompt" }; $answers.Dequeue() }
                function Start-Process {
                    [CmdletBinding()]param($FilePath)
                    $decisions = @(Import-Csv -LiteralPath $FilePath)
                    $decisions[0].Groups = 'Pinned'
                    $decisions[0].Apply = 'True'
                    [IO.File]::WriteAllLines($FilePath, @($decisions | ConvertTo-Csv -NoTypeInformation), [Text.UTF8Encoding]::new($true))
                }
                $profiles = Join-Path $env:ProgramData 'profiles'
                $null = Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
                Assert-Equal 0 $answers.Count
                $profile = Read-InterfaceGroupProfile -Path (Join-Path $profiles "$name.json")
                Assert-Equal $false $profile.ContainsKey('ReviewPath')
                $pack = @(Get-Content (Join-Path $profile.OutputDirectory 'groups.json') -Raw | ConvertFrom-Json)
                Assert-Equal Pinned $pack[0].Name
                Assert-Equal 1 $pack[0].InterfaceCount
            }
        }
        finally { $env:ProgramData = $savedProgramData }
    }
    Invoke-Test 'Wizard browser decisions apply once and optionally persist for future runs' {
        $savedProgramData=$env:ProgramData
        try {
            $env:ProgramData=Join-Path $output 'wizard-browser-programdata'
            foreach ($persist in @('N','Y')) {
                $answers=[System.Collections.Generic.Queue[string]]::new()
                $name="browser-$persist"
                $download=Join-Path $env:ProgramData "$name-download.csv"
                foreach ($answer in @('N',$name,'1','818','2','1','','N','N','N','4',$download,$persist,'Y')) { $answers.Enqueue($answer) }
                function Read-Host { param($Prompt) if (-not $answers.Count) {throw "Unexpected prompt: $Prompt"};$answers.Dequeue() }
                function Start-Process {
                    [CmdletBinding()]param($FilePath)
                    Assert-Equal .html ([IO.Path]::GetExtension($FilePath))
                    $csv=Join-Path (Split-Path $FilePath -Parent) "$name-preview.csv"
                    $decisions=@(Import-Csv -LiteralPath $csv)
                    $decisions[0].Groups='Browser Pinned';$decisions[0].Apply='True'
                    [IO.File]::WriteAllLines($download,@($decisions | ConvertTo-Csv -NoTypeInformation),[Text.UTF8Encoding]::new($true))
                }
                $profiles=Join-Path $env:ProgramData 'profiles'
                $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
                Assert-Equal 0 $answers.Count
                $profile=Read-InterfaceGroupProfile -Path (Join-Path $profiles "$name.json")
                Assert-Equal ($persist -eq 'Y') $profile.ContainsKey('ReviewPath')
                $pack=Get-Content (Join-Path $profile.OutputDirectory 'groups.json') -Raw | ConvertFrom-Json
                Assert-Equal 'Browser Pinned' $pack[0].Name
                Assert-Equal 1 $pack[0].InterfaceCount
            }
        }
        finally {$env:ProgramData=$savedProgramData}
    }
    Invoke-Test 'Wizard edits and clones saved profiles without overwriting source or carrying stale review pins' {
        $profiles=Join-Path $output 'wizard-edit\profiles'
        $source=Join-Path $profiles 'original.json'
        $null=Save-InterfaceGroupProfile -Path $source -Settings @{DeviceId=@(818);Mode='AllInterfaces';OutputDirectory=(Join-Path $output 'wizard-edit\original');ReviewPath=(Join-Path $output 'missing-review.csv')}
        $answers=[System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('E','1','C','clone','2','1','GroupA','Token','S','3','N')) {$answers.Enqueue($answer)}
        function Read-Host { param($Prompt) if (-not $answers.Count) { throw "Unexpected prompt: $Prompt" };$answers.Dequeue() }
        $hash=(Get-FileHash $source).Hash
        $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true} -WarningAction SilentlyContinue
        Assert-Equal 0 $answers.Count
        Assert-Equal $hash (Get-FileHash $source).Hash
        $clone=Read-InterfaceGroupProfile -Path (Join-Path $profiles 'clone.json')
        Assert-Equal NamedGroups $clone.Mode
        Assert-Equal GroupA $clone.GroupName[0]
        Assert-Equal $false $clone.ContainsKey('ReviewPath')
        foreach ($answer in @('E','1','M','3','today','S','3','N')) {$answers.Enqueue($answer)}
        $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
        Assert-Equal 0 $answers.Count
        Assert-Equal today (Read-InterfaceGroupProfile -Path (Join-Path $profiles 'clone.json')).Range
    }
    Invoke-Test 'Wizard device browser lists names and rejects IDs absent from accessible results' {
        $profiles=Join-Path $output 'wizard-browse\profiles'
        $answers=[System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('N','browse','4','999')) {$answers.Enqueue($answer)}
        function Read-Host { param($Prompt) if (-not $answers.Count) { throw "Unexpected prompt: $Prompt" };$answers.Dequeue() }
        $thrown=$false
        try {$null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}}
        catch {$thrown=$_.Exception.Message -like '*not in the accessible list*'}
        Assert-Equal $true $thrown
        Assert-Equal $false (Test-Path (Join-Path $profiles 'browse.json'))
        foreach ($answer in @('N','browse','4','818','2','1','','N','N','N','3','N')) {$answers.Enqueue($answer)}
        $null=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Start-InterfaceGroupingSetup.ps1') -Parameters @{ProfileDirectory=$profiles;SkipSchedule=$true}
        Assert-Equal 818 (Read-InterfaceGroupProfile -Path (Join-Path $profiles 'browse.json')).DeviceId[0]
        Assert-Equal 0 $answers.Count
    }
    Invoke-Test 'Grouping change reports persist locally, publish-safe manifest stays HTML-only and preview preserves baseline' {
        $path = Join-Path $output 'change-pack'
        $null = Export-InterfaceGroupDashboards -Groups $groups -Inventory $inventory -OutputDirectory $path
        Assert-Equal '[]' ([regex]::Replace([IO.File]::ReadAllText((Join-Path $path 'changes.json')), '\s', ''))
        $baseline = Join-Path $path 'inventory-snapshot.json'
        $hash = (Get-FileHash $baseline).Hash
        $null = Update-InterfaceGroupSelection -Inventory $inventory -Groups $groups -OutputDirectory $path -PreviewOnly
        Assert-Equal $hash (Get-FileHash $baseline).Hash
        $null = Export-InterfaceGroupDashboards -Groups @($groups[0]) -Inventory $inventory -OutputDirectory $path
        Assert-Equal 11 @(Import-Csv (Join-Path $path 'changes.csv')).Count
        Assert-Equal $true ([IO.File]::ReadAllText((Join-Path $path 'index.html')).Contains('MembershipChanged'))
        Assert-Equal $false (@(Get-WUGDashboardPackFiles -SourcePath $path) -contains 'inventory-snapshot.json')
        Assert-Equal $false (@(Get-WUGDashboardPackFiles -SourcePath $path) -contains 'changes.csv')
        $null = Export-InterfaceGroupDashboards -Groups @() -Inventory @() -OutputDirectory (Join-Path $path 'empty')
    }
    Invoke-Test 'Grouping changes flag vanished SNMP-only ports as uncertain even when device has no WUG interfaces' {
        $row = [pscustomobject]@{DeviceId=1;IfIndex=1;DeviceName='Router';InterfaceComment='';InterfaceName='';IfAlias='GroupA';SnmpStatus='Complete'}
        $before = New-InterfaceGroupSnapshot -Inventory @($row) -Groups @(Select-InterfaceGroups -Inventory @($row) -GroupName GroupA) -SnmpCoverage @{'1'='Complete'}
        $after = New-InterfaceGroupSnapshot -Inventory @() -Groups @() -SnmpCoverage @{'1'='Failed'}
        $changes = @(Compare-InterfaceGroupSnapshot -Current $after -Previous $before)
        Assert-Equal 1 $changes.Count
        Assert-Equal Removed $changes[0].Change
        Assert-Equal $true $changes[0].UncertainSnmpCoverage
        $after.SnmpCoverage = $null
        Assert-Equal $true (Compare-InterfaceGroupSnapshot -Current $after -Previous $before).UncertainSnmpCoverage
    }
    Invoke-Test 'Unavailable SNMP fields retain approved pins with warnings; actual raw metadata changes require re-review' {
        $row = [pscustomobject]@{DeviceId=1;IfIndex=1;DeviceName='Router';InterfaceComment='stored';InterfaceName='';IfAlias='GroupA';SnmpStatus='Complete'}
        $g = @(Select-InterfaceGroups -Inventory @($row) -GroupName GroupA)
        $decision = @(New-InterfaceGroupReview -Inventory @($row) -Groups $g)[0]
        $decision.Apply = 'True'
        $row.IfAlias = $null; $row.SnmpStatus='Failed'
        $r = @(Set-InterfaceGroupReview -Inventory @($row) -Groups @() -Decisions @($decision) -WarningAction SilentlyContinue)
        Assert-Equal GroupA $r[0].Name
        $row.IfAlias='GroupB';$row.SnmpStatus='Complete'
        $thrown = $false
        try { $null = Set-InterfaceGroupReview -Inventory @($row) -Groups $g -Decisions @($decision) } catch { $thrown = $_.Exception.Message -like '*changed SNMP metadata*' }
        Assert-Equal $true $thrown
    }
    Invoke-Test 'Profile runner executes real entry point, persists success/failure records and rotates only owned logs' {
        $profile = Join-Path $output 'runner\profile.json'
        $destination = Join-Path $output 'runner\pack'
        $logs = Join-Path $output 'runner\logs'
        $null = Save-InterfaceGroupProfile -Path $profile -Settings @{ DeviceId = @(818); Mode = 'AllInterfaces'; OutputDirectory = $destination }
        $script = Join-Path $PSScriptRoot '..\interfaces\Invoke-InterfaceGroupProfile.ps1'
        $r = Invoke-EntryFixture -Script $script -Parameters @{ ProfilePath = $profile; LogDirectory = $logs; KeepLogs = 1 }
        Assert-Equal $true (Test-Path -LiteralPath $r.IndexPath)
        Assert-Equal 1 $r.Health.Interfaces
        $record = Get-Content (Join-Path $logs 'latest-result.json') -Raw | ConvertFrom-Json
        Assert-Equal $true $record.Success
        [IO.File]::WriteAllText((Join-Path $logs 'operator-note.log'), 'keep')
        $thrown = $false
        try { $null = Invoke-EntryFixture -Script $script -Parameters @{ ProfilePath = $profile; LogDirectory = $logs; KeepLogs = 1 } -FailApi }
        catch { $thrown = $true }
        Assert-Equal $true $thrown
        $record = Get-Content (Join-Path $logs 'latest-result.json') -Raw | ConvertFrom-Json
        Assert-Equal $false $record.Success
        Assert-Equal $true ($record.Error -like '*fixture API failure*')
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $logs -Filter 'run-*.json').Count
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $logs -Filter 'run-*.log').Count
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $logs 'operator-note.log'))
        $lock = Open-InterfaceGroupRunLock -OutputDirectory $destination
        $lock.Dispose()
    }
    Invoke-Test 'Profile runner graphical review does not advance successful generation state' {
        $path=Join-Path $output 'runner-browser'
        $profile=Join-Path $path 'profile.json'
        $null=Save-InterfaceGroupProfile -Path $profile -Settings @{DeviceId=@(818);Mode='AllInterfaces';OutputDirectory=(Join-Path $path 'pack')}
        $logs=Join-Path $path 'logs'
        $r=Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Invoke-InterfaceGroupProfile.ps1') -Parameters @{ProfilePath=$profile;BrowserReview=$true;LogDirectory=$logs}
        Assert-Equal $true (Test-Path -LiteralPath $r.ReviewHtmlPath)
        Assert-Equal $null $r.IndexPath
        $record=Get-Content (Join-Path $logs 'latest-result.json') -Raw | ConvertFrom-Json
        Assert-Equal $true $record.PreviewOnly
        Assert-Equal $false (Test-Path (Join-Path $logs 'last-success.json'))
    }
    Invoke-Test 'Profile runner WhatIf does not create logs, lock, reports or review CSV' {
        $profile = Join-Path $output 'runner-whatif\profile.json'
        $destination = Join-Path $output 'runner-whatif\pack'
        $logs = Join-Path $output 'runner-whatif\logs'
        $null = Save-InterfaceGroupProfile -Path $profile -Settings @{ DeviceId = @(818); Mode = 'AllInterfaces'; OutputDirectory = $destination }
        $null = Invoke-EntryFixture -Script (Join-Path $PSScriptRoot '..\interfaces\Invoke-InterfaceGroupProfile.ps1') -Parameters @{
            ProfilePath = $profile; LogDirectory = $logs; WhatIf = $true; PreviewOnly = $true
        }
        Assert-Equal $false (Test-Path -LiteralPath $destination)
        Assert-Equal $false (Test-Path -LiteralPath $logs)
    }
    Invoke-Test 'Scheduler uses signed File runner, explicit S4U, IgnoreNew, ownership and task-identity RunNow' {
        $profile = Join-Path $output 'schedule\profile.json'
        $null = Save-InterfaceGroupProfile -Path $profile -Settings @{ DeviceId = @(818); Mode = 'AllInterfaces' }
        $schedulerFixture = @{ Calls = [System.Collections.Generic.List[string]]::new(); Unowned = $false }
        function Get-ScheduledTask {
            [CmdletBinding()]param($TaskName, $TaskPath)
            if ($schedulerFixture.Unowned) { [pscustomobject]@{ TaskName = 'InterfaceGroups-Test'; TaskPath = '\WhatsUpGoldPS\'; Description = 'someone else' } }
        }
        function New-ScheduledTaskAction {
            [CmdletBinding()]param($Execute, $Argument, $WorkingDirectory)
            if ($Argument -notlike '*-File*Invoke-InterfaceGroupProfile.ps1*' -or $Argument -like '*Bypass*' -or $Argument -like '*EncodedCommand*') { throw 'Unexpected runner command' }
            $schedulerFixture.Calls.Add('Action')
            [pscustomobject]@{ Arguments = $Argument }
        }
        function New-ScheduledTaskTrigger {
            [CmdletBinding()]param([switch]$Once, [switch]$Daily, [switch]$AtStartup, $At, $RepetitionInterval)
            Assert-Equal 30 $RepetitionInterval.TotalMinutes
            [pscustomobject]@{}
        }
        function New-ScheduledTaskPrincipal {
            [CmdletBinding()]param($UserId, $LogonType, $RunLevel)
            Assert-Equal S4U $LogonType
            [pscustomobject]@{}
        }
        function New-ScheduledTaskSettingsSet {
            [CmdletBinding()]param([switch]$StartWhenAvailable, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $MultipleInstances, $ExecutionTimeLimit)
            Assert-Equal IgnoreNew $MultipleInstances
            [pscustomobject]@{}
        }
        function Register-ScheduledTask {
            [CmdletBinding()]param($TaskName, $TaskPath, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
            $schedulerFixture.Calls.Add('Register')
            Assert-Equal '\WhatsUpGoldPS\' $TaskPath
            [pscustomobject]@{ TaskName = $TaskName; Description = $Description }
        }
        function Start-ScheduledTask { [CmdletBinding()]param($TaskName, $TaskPath) $schedulerFixture.Calls.Add('Start') }
        $script = Join-Path $PSScriptRoot '..\interfaces\Register-InterfaceGroupScheduledTask.ps1'
        $null = & $script -Register -ProfilePath $profile -TaskName InterfaceGroups-Test -WhatIf
        Assert-Equal 0 $schedulerFixture.Calls.Count
        $null = & $script -Register -ProfilePath $profile -TaskName InterfaceGroups-Test -RunNow -WarningAction SilentlyContinue
        Assert-Equal 'Action,Register,Start' ($schedulerFixture.Calls -join ',')
        $schedulerFixture.Unowned = $true
        $thrown = $false
        try { $null = & $script -Register -ProfilePath $profile -TaskName InterfaceGroups-Test } catch { $thrown = $_.Exception.Message -like '*unowned*' }
        Assert-Equal $true $thrown
        $thrown = $false
        try { $null = & $script -Remove InterfaceGroups-Test } catch { $thrown = $_.Exception.Message -like '*unowned*' }
        Assert-Equal $true $thrown
    }
    Invoke-Test 'Dashboard pack has 12 linked pages, history, safe descriptions and BOM' {
        $inventory[0].DeviceName = '</script><script>alert("x")</script>'
        $groups = @(Select-InterfaceGroups -Inventory $inventory -GroupName $names)
        $index = Export-InterfaceGroupDashboards -Groups $groups -OutputDirectory $output
        Assert-Equal $true (Test-Path -LiteralPath $index)
        Assert-Equal 12 @(Get-ChildItem -LiteralPath $output -Filter 'group-*.html').Count
        $html = [IO.File]::ReadAllText((Join-Path $output (Get-WUGDashboardGroupPageName -Name GroupA)))
        Assert-Equal $false $html.Contains($inventory[0].DeviceName)
        Assert-Equal $true $html.Contains('escape: true')
        Assert-Equal $true $html.Contains('class="collapse show" id="detailsSection"')
        Assert-Equal $true $html.Contains('interface-chart')
        Assert-Equal $false $html.Contains('INTERFACE_GROUP_DATA')
        $saved = Get-Content (Join-Path $output 'groups.json') -Raw | ConvertFrom-Json
        Assert-Equal 12 @($saved).Count
        Assert-Equal 2 $saved[0].Interfaces[0].Samples.Count
        $bytes = [IO.File]::ReadAllBytes($index)
        Assert-Equal 'EF-BB-BF' ([BitConverter]::ToString($bytes[0..2]))
    }
    Invoke-Test 'Empty group produces explicit empty page, not a synthetic interface' {
        $empty = @(Select-InterfaceGroups -Inventory @() -GroupName GroupA)
        $null = Export-InterfaceGroupDashboards -Groups $empty -OutputDirectory $output
        Assert-Equal $true ([IO.File]::ReadAllText((Join-Path $output (Get-WUGDashboardGroupPageName -Name GroupA))).Contains('No matching interfaces'))
    }
    $console = Join-Path $output 'Html\NmConsole'
    $null = New-Item -ItemType Directory -Path $console
    [IO.File]::WriteAllText((Join-Path $console 'web.config'),
        '<configuration><system.web><authentication mode="Forms" /></system.web></configuration>')
    Invoke-Test 'Pack publisher WhatIf does not create directories or configuration' {
        $null = Copy-WUGDashboardPack -SourcePath $output -NmConsolePath $console -PackName 'test-pack' -WhatIf
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $console 'dashboards'))
    }
    Invoke-Test 'Publisher deploys static authentication first, copies HTML only and verifies hashes' {
        $result = Copy-WUGDashboardPack -SourcePath $output -NmConsolePath $console -PackName 'test-pack' -Confirm:$false
        Assert-Equal 2 $result.FilesCopied
        Assert-Equal $false $result.AuthenticationVerified
        Assert-Equal $true (Test-Path -LiteralPath $result.PublishedIndexPath)
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $result.PublishedPath 'groups.json'))
        $config = [xml][IO.File]::ReadAllText((Join-Path $result.PublishedPath 'web.config'))
        Assert-Equal '?' $config.configuration.'system.web'.authorization.deny.users
        Assert-Equal 'true' $config.configuration.'system.webServer'.modules.runAllManagedModulesForAllRequests
        Assert-Equal 'false' $config.configuration.'system.webServer'.directoryBrowse.enabled
        Assert-Equal '.json' $config.configuration.'system.webServer'.security.requestFiltering.fileExtensions.add.fileExtension
        Assert-Equal ((Get-FileHash (Join-Path $output 'index.html')).Hash) ((Get-FileHash $result.PublishedIndexPath).Hash)
        Add-Type -AssemblyName System.Web
        $map = New-Object System.Configuration.ExeConfigurationFileMap
        $map.ExeConfigFilename = Join-Path $result.PublishedPath 'web.config'
        $parsed = [System.Configuration.ConfigurationManager]::OpenMappedExeConfiguration($map,
            [System.Configuration.ConfigurationUserLevel]::None)
        $rules = $parsed.GetSection('system.web/authorization').Rules
        Assert-Equal Deny $rules[0].Action
        Assert-Equal '?' $rules[0].Users[0]
    }
    Invoke-Test 'Publisher preserves all 12 pages from the PowerShell 5.1 JSON manifest array' {
        $multi = Join-Path $output 'MultiPack'
        $null = Export-InterfaceGroupDashboards -Groups $groups -OutputDirectory $multi
        $r = Copy-WUGDashboardPack -SourcePath $multi -NmConsolePath $console -PackName 'multi-pack' -Confirm:$false
        Assert-Equal 13 $r.FilesCopied
        Assert-Equal 12 @(Get-ChildItem -LiteralPath $r.PublishedPath -Filter 'group-*.html').Count
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $r.PublishedPath (Get-WUGDashboardGroupPageName -Name GroupL)))
        function Invoke-WebRequest {
            [CmdletBinding()]
            param($Uri, $WebSession, [switch]$UseBasicParsing, $MaximumRedirection)
            [pscustomobject]@{ StatusCode = 401; Headers = @{} }
        }
        $checked = Test-WUGDashboardPackAccess -SourcePath $multi -ConsoleUri 'https://wug.example.com/NmConsole' `
            -PackName 'multi-pack' -WarningAction SilentlyContinue
        Assert-Equal 13 $checked.PagesChecked
        Assert-Equal $false $checked.AuthenticatedAccessVerified
    }
    Invoke-Test 'Publisher removes obsolete legacy and stable pages only inside owned destination' {
        $destination = Join-Path $console 'dashboards\test-pack'
        [IO.File]::WriteAllText((Join-Path $destination 'group-99.html'), 'old interface data')
        $obsoleteStable = Get-WUGDashboardGroupPageName -Name 'Removed Group'
        [IO.File]::WriteAllText((Join-Path $destination $obsoleteStable), 'old stable page')
        [IO.File]::WriteAllText((Join-Path $destination 'operator-note.txt'), 'keep')
        $result = Copy-WUGDashboardPack -SourcePath $output -NmConsolePath $console -PackName 'test-pack' -Confirm:$false
        Assert-Equal 2 $result.ObsoletePagesRemoved
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $destination 'group-99.html'))
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $destination $obsoleteStable))
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $destination 'operator-note.txt'))
    }
    Invoke-Test 'Unowned destination is not overwritten' {
        $destination = Join-Path $console 'dashboards\someone-else'
        $null = New-Item -ItemType Directory -Path $destination
        $thrown = $false
        try { Copy-WUGDashboardPack -SourcePath $output -NmConsolePath $console -PackName 'someone-else' -Confirm:$false | Out-Null }
        catch { $thrown = $_.Exception.Message -like '*not an owned*' }
        Assert-Equal $true $thrown
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $destination 'index.html'))
    }
    Invoke-Test 'Parent without declared Forms authentication is rejected before deployment' {
        $bad = Join-Path $output 'NotForms'
        $null = New-Item -ItemType Directory -Path $bad
        [IO.File]::WriteAllText((Join-Path $bad 'web.config'), '<configuration />')
        $thrown = $false
        try { Copy-WUGDashboardPack -SourcePath $output -NmConsolePath $bad -PackName 'test-pack' -Confirm:$false | Out-Null }
        catch { $thrown = $_.Exception.Message -like '*declare Forms authentication*' }
        Assert-Equal $true $thrown
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $bad 'dashboards'))
    }
    Invoke-Test 'Configuration deployment failure prevents any HTML copy' {
        function Deploy-DashboardWebConfig { throw 'fixture configuration write failure' }
        $thrown = $false
        try { Copy-WUGDashboardPack -SourcePath $output -NmConsolePath $console -PackName 'config-failure' -Confirm:$false | Out-Null }
        catch { $thrown = $_.Exception.Message -eq 'fixture configuration write failure' }
        Assert-Equal $true $thrown
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $console 'dashboards\config-failure\index.html'))
    }
    Invoke-Test 'Missing source pages fail before touching web destination' {
        $source = Join-Path $output 'InvalidPack'
        $null = New-Item -ItemType Directory -Path $source
        [IO.File]::WriteAllText((Join-Path $source 'groups.json'), '[{"Name":"missing"}]')
        $thrown = $false
        try { Copy-WUGDashboardPack -SourcePath $source -NmConsolePath $console -PackName 'missing-source' -Confirm:$false | Out-Null }
        catch { $thrown = $true }
        Assert-Equal $true $thrown
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $console 'dashboards\missing-source'))
    }
    Invoke-Test 'Actual access verification checks every page anonymously and with Forms session' {
        function Invoke-WebRequest {
            [CmdletBinding()]
            param($Uri, $WebSession, [switch]$UseBasicParsing, $MaximumRedirection)
            if ($WebSession) {
                $name = ([uri]$Uri).Segments[-1]
                [pscustomobject]@{ StatusCode = 200; Content = [IO.File]::ReadAllText((Join-Path $output $name)) }
            }
            else { [pscustomobject]@{ StatusCode = 302; Headers = @{ Location = '/NmConsole/Login.aspx?ReturnUrl=dashboard' } } }
        }
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $r = Test-WUGDashboardPackAccess -SourcePath $output -ConsoleUri 'https://wug.example.com/NmConsole' -PackName 'test-pack' -WebSession $session
        Assert-Equal 2 $r.PagesChecked
        Assert-Equal $true $r.AnonymousBlocked
        Assert-Equal $true $r.AuthenticatedAccessVerified
    }
    Invoke-Test 'Anonymous HTTP 200 or IIS configuration error fails verification' {
        foreach ($code in @(200, 500)) {
            function Invoke-WebRequest {
                [CmdletBinding()]
                param($Uri, $WebSession, [switch]$UseBasicParsing, $MaximumRedirection)
                [pscustomobject]@{ StatusCode = $code; Headers = @{} }
            }
            $thrown = $false
            try { Test-WUGDashboardPackAccess -SourcePath $output -ConsoleUri 'https://wug.example.com/NmConsole' -PackName 'test-pack' | Out-Null }
            catch { $thrown = $_.Exception.Message -like '*not safely blocked*' }
            Assert-Equal $true $thrown
        }
    }
    Invoke-Test 'Authenticated login page is not accepted as successful dashboard content' {
        function Invoke-WebRequest {
            [CmdletBinding()]
            param($Uri, $WebSession, [switch]$UseBasicParsing, $MaximumRedirection)
            if ($WebSession) { [pscustomobject]@{ StatusCode = 200; Content = '<html>Login</html>' } }
            else { [pscustomobject]@{ StatusCode = 401; Headers = @{} } }
        }
        $thrown = $false
        try {
            Test-WUGDashboardPackAccess -SourcePath $output -ConsoleUri 'https://wug.example.com/NmConsole' `
                -PackName 'test-pack' -WebSession (New-Object Microsoft.PowerShell.Commands.WebRequestSession) | Out-Null
        }
        catch { $thrown = $_.Exception.Message -like '*content mismatch*' }
        Assert-Equal $true $thrown
    }
}
finally {
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
    $env:ProgramData = $originalProgramData
}

# Mock the explicitly loaded WUG functions after testing pure transformations.
$global:WhatsUpServerBaseURI = 'https://test.invalid:9644'
$global:WUGBearerHeaders = @{ Authorization = 'test' }
Invoke-Test 'Existing WUG session avoids reconnection' {
    function Connect-WUGServer { throw 'Should not reconnect' }
    Connect-InterfaceGroupServer
}
Invoke-Test 'Disconnected session connects using saved vault and verifies session state' {
    $global:WhatsUpServerBaseURI = $null
    $global:WUGBearerHeaders = $null
    function Connect-WUGServer {
        param([switch]$AutoConnect)
        Assert-Equal $true $AutoConnect.IsPresent
        $global:WhatsUpServerBaseURI = 'https://test.invalid:9644'
        $global:WUGBearerHeaders = @{ Authorization = 'test' }
    }
    Connect-InterfaceGroupServer
    Assert-Equal $true ([bool]$global:WUGBearerHeaders)
}
Invoke-Test 'Missing vault connection fails explicitly with no success-shaped fallback' {
    $global:WhatsUpServerBaseURI = $null
    $global:WUGBearerHeaders = $null
    function Connect-WUGServer { throw 'No saved WUG connection in vault.' }
    $thrown = $false
    try { Connect-InterfaceGroupServer }
    catch { $thrown = $_.Exception.Message -eq 'No saved WUG connection in vault.' }
    Assert-Equal $true $thrown
    $global:WhatsUpServerBaseURI = 'https://test.invalid:9644'
    $global:WUGBearerHeaders = @{ Authorization = 'test' }
}
Invoke-Test 'Source groups include descendants only when requested and deduplicate devices' {
    function Get-WUGDevice {
        param($DeviceGroupID, $ReturnHierarchy, $View, $Limit)
        Assert-Equal true $ReturnHierarchy
        Assert-Equal id $View
        [pscustomobject]@{ id = 818 }
        [pscustomobject]@{ id = 819 }
    }
    $ids = @(Resolve-InterfaceGroupDevice -GroupId 41,70 -ReturnHierarchy)
    Assert-Equal 2 $ids.Count
}
Invoke-Test 'All-device scope uses All Devices and explicit hierarchy' {
    function Get-WUGDevice {
        param($DeviceGroupID, $ReturnHierarchy, $View, $Limit)
        Assert-Equal '-2' $DeviceGroupID
        Assert-Equal true $ReturnHierarchy
        [pscustomobject]@{ id = 818 }
    }
    Assert-Equal 818 @(Resolve-InterfaceGroupDevice -AllDevices)[0]
}
Invoke-Test 'Source group direct membership and empty scope are explicit' {
    function Get-WUGDevice {
        param($DeviceGroupID, $ReturnHierarchy, $View, $Limit)
        Assert-Equal false $ReturnHierarchy
    }
    $thrown = $false
    try { Resolve-InterfaceGroupDevice -GroupId 41 | Out-Null }
    catch { $thrown = $_.Exception.Message -like 'No accessible WUG devices*' }
    Assert-Equal $true $thrown
    Assert-Equal 2 @(Resolve-InterfaceGroupDevice -DeviceId 818,818,819).Count
}
$script:apiCalls = 0
function Get-WUGDevice { param($DeviceId, $DeviceGroupID, $View, $ReturnHierarchy)
    if ($DeviceId) { [pscustomobject]@{ id = $DeviceId; displayName = 'Router' } }
    else { foreach ($id in $script:members["$DeviceGroupID"]) { [pscustomobject]@{ id = $id } } }
}
function Get-WUGDeviceReport { param($DeviceId, $ReportType, $Range, $Limit, $RangeN)
    New-TrafficFixture 1 GroupA
}
function Get-WUGAPIResponse { param($Uri, $Method)
    $script:apiCalls++
    if ($Uri -match 'pageId=next') { [pscustomobject]@{ data = @(New-ActiveFixture 2 GroupB); paging = @{} } }
    else { [pscustomobject]@{ data = @(New-ActiveFixture 1 GroupA); paging = @{ nextPageId = 'next' } } }
}
Invoke-Test 'Collection follows monitor pagination and deduplicates device scope' {
    $r = @(Get-InterfaceGroupInventory -DeviceId 1,1 -Range lastPolled)
    Assert-Equal 2 $script:apiCalls
    Assert-Equal 2 $r.Count
}
Invoke-Test 'API errors terminate collection' {
    function Get-WUGAPIResponse { throw 'fixture API failure' }
    $thrown = $false
    try { Get-InterfaceGroupInventory -DeviceId 1 | Out-Null }
    catch { $thrown = $_.Exception.Message -eq 'fixture API failure' }
    Assert-Equal $true $thrown
}
$script:children = @{ '0' = @() }
$script:definitions = @{}
$script:members = @{}
$script:creates = 0
$script:adds = 0
function Get-WUGDeviceGroup {
    param($ConfigGroupId, [switch]$Children, [switch]$Definition)
    if ($Children) { $script:children["$ConfigGroupId"] }
    else { $script:definitions["$ConfigGroupId"] }
}
function Add-WUGDeviceGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param($ParentGroupId, $Name, $Description)
    $script:creates++
    $id = [string](100 + $script:creates)
    $g = [pscustomobject]@{ id = $id; name = $Name }
    $script:children["$ParentGroupId"] += $g
    $script:children[$id] = @()
    $script:members[$id] = @()
    $script:definitions[$id] = [pscustomobject]@{ description = $Description; groupType = 'static' }
    $g
}
function Add-WUGDeviceGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param($GroupId, $DeviceId)
    $script:adds++
    $script:members["$GroupId"] += $DeviceId
    [pscustomobject]@{ success = $true }
}
Invoke-Test 'WhatIf with missing folder causes no configuration writes' {
    $null = Sync-InterfaceNavigationGroups -Groups $groups -WhatIf -WarningAction SilentlyContinue
    Assert-Equal 0 $script:creates
    Assert-Equal 0 $script:adds
}
Invoke-Test 'Navigation creation is additive and idempotent for 12 groups' {
    $first = @(Sync-InterfaceNavigationGroups -Groups $groups -Confirm:$false)
    Assert-Equal 13 $script:creates
    Assert-Equal 12 $script:adds
    Assert-Equal 12 $first.Count
    $second = @(Sync-InterfaceNavigationGroups -Groups $groups -Confirm:$false)
    Assert-Equal 13 $script:creates
    Assert-Equal 12 $script:adds
    Assert-Equal 0 @($second | Where-Object AddedDevices -gt 0).Count
}
Invoke-Test 'Unowned existing folder is rejected' {
    $script:definitions['101'].description = 'belongs to someone else'
    $thrown = $false
    try { Sync-InterfaceNavigationGroups -Groups $groups -Confirm:$false | Out-Null }
    catch { $thrown = $_.Exception.Message -like '*not an owned*' }
    Assert-Equal $true $thrown
}
Write-Output "$script:passed passed; $script:failed failed."
if ($script:failed -gt 0) { throw 'Interface grouping regression tests failed.' }

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA5Qe1byIcEhZFn
# HxTY8AChobvcZJhJtTprrsWes/wfb6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCW
# Tvl1+FFubI9muryxqMyIcuf2eMi/eBe0Lh/m368h+zANBgkqhkiG9w0BAQEFAASC
# AgCE+CGbL9azmnark8/g98UQGuFHFtLHxTPMNwfXxNxxYyM9CQMQTq0bhiuzXSWe
# SjcrxPSsyTDX2fctD0BuTiUH1NazAy/pAGCH4KfENurHKMeXqD5EmKZg7me7ss4l
# ubuYsIT+dNRymvqtNok63E66pwhjC1lrRJCsICfe2VPO3Nn124XwUvDntKCPJJzj
# ZduN/zhZ6fDs18kVh3PwOG0ETTkvInEnXZdWVKP8N2G06pNut/unKsa6RqoCo58N
# 4PZi1Rp3x4TiRfhU86izLijGmp3B9pRprlFFcQHKJNv9Jl2X+IVVzGPMzMNqnDJS
# aFQ4ugxKbdl9iE3H9hBfhdBo6yXAjtRNaJI08VgoN3LT9SP8mla/bLiF/UMp9jn7
# 8NDy5QhsWPVJgedUsvN2nrVjkYlJEui1uPB8e3+e6Ol5R1vMkOgTbjzythV1Pypg
# abYMwfbe+KvxgE04kq61s/1H0vi5GtS5NxvaUe/debqUXPrELtWYs1gpVKQEZpWH
# 3UfRhmQZnZEsnsd69Jo5Gq8PEYq4RiniCl8XQZKyn0nHRDob0jU0Zotw1WaTRKsJ
# OVp9nX29q0Yr+ZxptNXegSOszOQM/YUoU9RpqBH7Mu3tmk0sQR3k2iJeLrBJ221u
# cISYlfllQGjIB8SVx2jECenGMsHaVpZdaUG/By+rGY2dF6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgyMTQzNTRaMC8GCSqGSIb3DQEJBDEiBCBv5DDj4vNy
# sKOEMfU1ZqjD+7bwz3vEvn+wiF3ngKrLxTANBgkqhkiG9w0BAQEFAASCAgB/6GMK
# e3oaD52GSNJyTuWZazNAzUsacXgz6X0J2A9GD1+Rv8o9d0Pr+mG+7YhNH83sbLlA
# 8ddwIA70fFfYLj9g/qe1TOcNV2MBhowRO9UTnJ5twcvFr2PvtONRK9irnN44gHm+
# oGgRidrg6YGLvrF9QNKdB51IdLzwWGgkyjzGFNFcVhu9oY78FzsI0gM6xhqnGsdW
# /REzEe30WjhKSp/eMnzjN83AsMJbWXgQcpTSEp5Xks6CwsEIzdiwGa8tPPK9pv7b
# ML5V/5XL7Bp28hIsT+GhVMg4WM47V0FBvoYwl3fHyurHEk3K8hEBU6YzRj+YYPwq
# 2NbTuOuaGO/7hWGWSV+KLdoqsXNA+VObg/J3kvT9kPlqq6fXD897n0LlCq/S8bz9
# J5f0kARw7p68IWsLsVKs4YlePq2kI5Dba2pDTtI69e/Z5Y5bHSP8lsgGHMQkMAzJ
# MfHmfcSl9yaL2GbzKfJF+Qe/0hsWbrGHnsIZfZgktU1N4XZZySym1XEUamY20I4K
# YuKM/yXi4a4ObmfVewNoD37Dit1B6mVxkGUe+ukWijXx44TeXFVKIa3Dt2LA8xrJ
# EmaqvdIvF4pAn/6dTPiaCJyk09ar0+erqrBz7nT6AHX2cPXUSQNhQzaP94CMjr5D
# De5oO0xP0dXqc7j7p9VTy/8j2YfwfU1nPBRlKw==
# SIG # End signature block
